import Foundation

/// Intermediate Representation of a Lottie animation
/// Provides a normalized, render-ready structure for the animation pipeline
public struct AnimIR: Sendable, Equatable {
    /// Animation metadata
    public let meta: Meta

    /// Root composition ID
    public let rootComp: CompID

    /// All compositions (root + precomps) keyed by ID
    public let comps: [CompID: Composition]

    /// Asset index (assetId -> relativePath)
    public let assets: AssetIndexIR

    /// Binding layer information
    public let binding: BindingInfo

    /// Issues from the last renderCommands call (reset on each call)
    public private(set) var lastRenderIssues: [RenderIssue] = []

    public init(
        meta: Meta,
        rootComp: CompID,
        comps: [CompID: Composition],
        assets: AssetIndexIR,
        binding: BindingInfo
    ) {
        self.meta = meta
        self.rootComp = rootComp
        self.comps = comps
        self.assets = assets
        self.binding = binding
    }

    /// Root composition ID constant
    public static let rootCompId: CompID = "__root__"

    // MARK: - Equatable (exclude lastRenderIssues from comparison)

    public static func == (lhs: AnimIR, rhs: AnimIR) -> Bool {
        lhs.meta == rhs.meta &&
        lhs.rootComp == rhs.rootComp &&
        lhs.comps == rhs.comps &&
        lhs.assets == rhs.assets &&
        lhs.binding == rhs.binding
    }
}

// MARK: - Local Frame Index

extension AnimIR {
    /// Converts scene frame index to local frame index for this animation
    /// Uses clamping policy: clamp to [0, op-1]
    public func localFrameIndex(sceneFrameIndex: Int) -> Int {
        let maxFrame = Int(meta.outPoint) - 1
        return max(0, min(sceneFrameIndex, maxFrame))
    }
}

// MARK: - Visibility

extension AnimIR {
    /// Checks if a layer is visible at the given frame
    /// Layer is visible if frame is in [ip, op)
    public static func isVisible(_ layer: Layer, at frame: Double) -> Bool {
        frame >= layer.timing.inPoint && frame < layer.timing.outPoint
    }
}

// MARK: - Transform Computation

extension AnimIR {
    /// Computes the local transformation matrix for a layer at the given frame
    /// Formula: T(position) * R(rotation) * S(scale) * T(-anchor)
    public static func computeLocalMatrix(transform: TransformTrack, at frame: Double) -> Matrix2D {
        let position = transform.position.sample(frame: frame)
        let rotation = transform.rotation.sample(frame: frame)
        let scale = transform.scale.sample(frame: frame)
        let anchor = transform.anchor.sample(frame: frame)

        // Normalize scale from percentage (100 = 1.0)
        let sx = scale.x / 100.0
        let sy = scale.y / 100.0

        // Build matrix: T(position) * R(rotation) * S(scale) * T(-anchor)
        return Matrix2D.translation(x: position.x, y: position.y)
            .concatenating(.rotationDegrees(rotation))
            .concatenating(.scale(x: sx, y: sy))
            .concatenating(.translation(x: -anchor.x, y: -anchor.y))
    }

    /// Computes the normalized opacity (0-1) for a layer at the given frame
    public static func computeOpacity(transform: TransformTrack, at frame: Double) -> Double {
        let rawOpacity = transform.opacity.sample(frame: frame)
        // Clamp to 0-100, then normalize to 0-1
        return max(0, min(rawOpacity, 100)) / 100.0
    }
}

// MARK: - Render Commands Generation

extension AnimIR {
    /// Generates render commands for the given frame index
    /// Commands are in animation local space (0..w, 0..h)
    ///
    /// - Parameter frameIndex: Scene frame number to render
    /// - Returns: Array of render commands in execution order
    /// - Note: Check `lastRenderIssues` after calling for any errors encountered
    public mutating func renderCommands(frameIndex: Int) -> [RenderCommand] {
        // Reset issues from previous call
        lastRenderIssues.removeAll(keepingCapacity: true)

        var commands: [RenderCommand] = []

        // Convert scene frame to local frame using clamping policy
        let localFrame = Double(localFrameIndex(sceneFrameIndex: frameIndex))

        // Begin root group
        commands.append(.beginGroup(name: "AnimIR:\(meta.sourceAnimRef)"))

        // Render root composition
        if let rootComposition = comps[rootComp] {
            renderComposition(
                rootComposition,
                frame: localFrame,
                parentWorldMatrix: .identity,
                parentWorldOpacity: 1.0,
                sceneFrameIndex: frameIndex,
                commands: &commands
            )
        }

        // End root group
        commands.append(.endGroup)

        return commands
    }

    /// Convenience method that returns commands and issues without requiring var
    public func renderCommandsWithIssues(
        frameIndex: Int
    ) -> (commands: [RenderCommand], issues: [RenderIssue]) {
        var copy = self
        let commands = copy.renderCommands(frameIndex: frameIndex)
        return (commands, copy.lastRenderIssues)
    }

    /// Renders a composition recursively
    private mutating func renderComposition(
        _ composition: Composition,
        frame: Double,
        parentWorldMatrix: Matrix2D,
        parentWorldOpacity: Double,
        sceneFrameIndex: Int,
        commands: inout [RenderCommand]
    ) {
        // Build lookup for parent chain resolution within this composition
        let layerById = Dictionary(uniqueKeysWithValues: composition.layers.map { ($0.id, $0) })

        // Process layers in order (as they appear in JSON)
        for layer in composition.layers {
            renderLayer(
                layer,
                frame: frame,
                parentWorldMatrix: parentWorldMatrix,
                parentWorldOpacity: parentWorldOpacity,
                layerById: layerById,
                sceneFrameIndex: sceneFrameIndex,
                commands: &commands
            )
        }
    }

    /// Renders a single layer
    private mutating func renderLayer(
        _ layer: Layer,
        frame: Double,
        parentWorldMatrix: Matrix2D,
        parentWorldOpacity: Double,
        layerById: [LayerID: Layer],
        sceneFrameIndex: Int,
        commands: inout [RenderCommand]
    ) {
        // Skip matte source layers - they don't render directly
        if layer.isMatteSource {
            return
        }

        // Skip if layer is not visible at this frame
        guard Self.isVisible(layer, at: frame) else {
            return
        }

        // Compute world matrix and opacity with parenting
        // Returns nil if parent chain has errors - layer is skipped
        guard let (worldMatrix, worldOpacity) = computeWorldTransform(
            for: layer,
            at: frame,
            baseWorldMatrix: parentWorldMatrix,
            baseWorldOpacity: parentWorldOpacity,
            layerById: layerById,
            sceneFrameIndex: sceneFrameIndex
        ) else {
            // Parent chain error - layer and subtree are not rendered
            // Issue has already been recorded in computeWorldTransform
            return
        }

        // Begin layer group
        commands.append(.beginGroup(name: "Layer:\(layer.name)(\(layer.id))"))

        // Push computed world transform
        commands.append(.pushTransform(worldMatrix))

        // Handle matte - wrap content in matte begin/end
        if let matte = layer.matte {
            switch matte.mode {
            case .alpha:
                commands.append(.beginMatteAlpha(sourceLayerId: matte.sourceLayerId))
            case .alphaInverted:
                commands.append(.beginMatteAlphaInverted(sourceLayerId: matte.sourceLayerId))
            }
        }

        // Handle masks - apply before content
        let hasMasks = !layer.masks.isEmpty
        if hasMasks {
            for mask in layer.masks {
                if let staticPath = mask.path.staticPath {
                    commands.append(.beginMaskAdd(path: staticPath))
                }
            }
        }

        // Render content based on layer type
        renderLayerContent(
            layer,
            frame: frame,
            worldMatrix: worldMatrix,
            worldOpacity: worldOpacity,
            sceneFrameIndex: sceneFrameIndex,
            commands: &commands
        )

        // End masks (LIFO order)
        if hasMasks {
            for _ in layer.masks {
                commands.append(.endMask)
            }
        }

        // End matte
        if layer.matte != nil {
            commands.append(.endMatte)
        }

        // Pop transform
        commands.append(.popTransform)

        // End layer group
        commands.append(.endGroup)
    }

    /// Computes world transform for a layer considering parent chain
    /// Returns nil if parent chain has errors (PARENT_NOT_FOUND or PARENT_CYCLE)
    private mutating func computeWorldTransform(
        for layer: Layer,
        at frame: Double,
        baseWorldMatrix: Matrix2D,
        baseWorldOpacity: Double,
        layerById: [LayerID: Layer],
        sceneFrameIndex: Int
    ) -> (matrix: Matrix2D, opacity: Double)? {
        // Resolve parent chain, checking for errors
        let parentChainResult = resolveParentChain(
            for: layer,
            layerById: layerById,
            sceneFrameIndex: sceneFrameIndex
        )

        // If parent chain resolution failed, return nil
        guard let parentChain = parentChainResult else {
            return nil
        }

        // Start with base (from containing composition)
        var worldMatrix = baseWorldMatrix
        var worldOpacity = baseWorldOpacity

        // Apply parent transforms in order (root parent first)
        for parentLayer in parentChain.reversed() {
            let parentLocal = Self.computeLocalMatrix(transform: parentLayer.transform, at: frame)
            let parentOpacity = Self.computeOpacity(transform: parentLayer.transform, at: frame)
            worldMatrix = worldMatrix.concatenating(parentLocal)
            worldOpacity *= parentOpacity
        }

        // Apply this layer's local transform
        let localMatrix = Self.computeLocalMatrix(transform: layer.transform, at: frame)
        let localOpacity = Self.computeOpacity(transform: layer.transform, at: frame)

        worldMatrix = worldMatrix.concatenating(localMatrix)
        worldOpacity *= localOpacity

        return (worldMatrix, worldOpacity)
    }

    /// Resolves the parent chain for a layer (returns parents from immediate to root)
    /// Returns nil and records issue if PARENT_NOT_FOUND or PARENT_CYCLE detected
    private mutating func resolveParentChain(
        for layer: Layer,
        layerById: [LayerID: Layer],
        sceneFrameIndex: Int
    ) -> [Layer]? {
        var chain: [Layer] = []
        var visited = Set<LayerID>()
        var currentParentId = layer.parent

        while let parentId = currentParentId {
            // Detect cycles
            if visited.contains(parentId) {
                // Cycle detected - record issue and return nil
                let issue = RenderIssue(
                    severity: .error,
                    code: RenderIssue.codeParentCycle,
                    path: "anim(\(meta.sourceAnimRef)).layers[id=\(layer.id)]",
                    message: "Cycle detected in parent chain at parent id=\(parentId)",
                    frameIndex: sceneFrameIndex
                )
                lastRenderIssues.append(issue)
                return nil
            }
            visited.insert(parentId)

            guard let parentLayer = layerById[parentId] else {
                // Parent not found - record issue and return nil
                let issue = RenderIssue(
                    severity: .error,
                    code: RenderIssue.codeParentNotFound,
                    path: "anim(\(meta.sourceAnimRef)).layers[id=\(layer.id)]",
                    message: "Parent layer with id=\(parentId) not found in composition",
                    frameIndex: sceneFrameIndex
                )
                lastRenderIssues.append(issue)
                return nil
            }

            chain.append(parentLayer)
            currentParentId = parentLayer.parent
        }

        return chain
    }

    /// Renders layer content based on type
    private mutating func renderLayerContent(
        _ layer: Layer,
        frame: Double,
        worldMatrix: Matrix2D,
        worldOpacity: Double,
        sceneFrameIndex: Int,
        commands: inout [RenderCommand]
    ) {
        switch layer.content {
        case .image(let assetId):
            // Draw image with computed world opacity
            commands.append(.drawImage(assetId: assetId, opacity: worldOpacity))

        case .precomp(let compId):
            // Recursively render precomp composition
            if let precomp = comps[compId] {
                // Apply start time offset: childFrame = frame - st
                let childFrame = frame - layer.timing.startTime

                renderComposition(
                    precomp,
                    frame: childFrame,
                    parentWorldMatrix: worldMatrix,
                    parentWorldOpacity: worldOpacity,
                    sceneFrameIndex: sceneFrameIndex,
                    commands: &commands
                )
            }

        case .shapes:
            // Shape layers used as matte sources don't render directly
            break

        case .none:
            // Null layers have no visual content
            break
        }
    }
}

// MARK: - Lookup Helpers

extension AnimIR {
    /// Finds a layer by ID across all compositions
    public func findLayer(byId layerId: LayerID) -> (layer: Layer, compId: CompID)? {
        for (compId, comp) in comps {
            if let layer = comp.layers.first(where: { $0.id == layerId }) {
                return (layer, compId)
            }
        }
        return nil
    }

    /// Finds a layer by name across all compositions
    public func findLayer(byName name: String) -> (layer: Layer, compId: CompID)? {
        for (compId, comp) in comps {
            if let layer = comp.layers.first(where: { $0.name == name }) {
                return (layer, compId)
            }
        }
        return nil
    }

    /// Gets the root composition
    public var rootComposition: Composition? {
        comps[rootComp]
    }
}
