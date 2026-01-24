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

    public static func == (lhs: Self, rhs: Self) -> Bool {
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

// MARK: - Render Context

extension AnimIR {
    /// Context for rendering operations - groups related parameters
    private struct RenderContext {
        let frame: Double
        let frameIndex: Int
        let parentWorld: Matrix2D
        let parentOpacity: Double
        let layerById: [LayerID: Layer]
        /// Stack of composition IDs currently being rendered (for cycle detection)
        let visitedComps: Set<CompID>
    }

    /// Resolved world transform for a layer
    private struct ResolvedTransform {
        let worldMatrix: Matrix2D
        let worldOpacity: Double
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
            let layerById = Dictionary(uniqueKeysWithValues: rootComposition.layers.map { ($0.id, $0) })
            let context = RenderContext(
                frame: localFrame,
                frameIndex: frameIndex,
                parentWorld: .identity,
                parentOpacity: 1.0,
                layerById: layerById,
                visitedComps: [rootComp]
            )
            renderComposition(rootComposition, context: context, commands: &commands)
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
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        // Process layers in order (as they appear in JSON)
        for layer in composition.layers {
            renderLayer(layer, context: context, commands: &commands)
        }
    }

    /// Renders a single layer
    private mutating func renderLayer(
        _ layer: Layer,
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        // Skip matte source layers - they don't render directly
        guard !layer.isMatteSource else { return }

        // Skip if layer is not visible at this frame
        guard Self.isVisible(layer, at: context.frame) else { return }

        // Compute world matrix and opacity with parenting
        guard let resolved = computeLayerWorld(layer, context: context) else { return }

        // Emit all commands for this layer
        emitLayerCommands(layer, resolved: resolved, context: context, commands: &commands)
    }

    /// Computes world transform for a layer considering parent chain
    private mutating func computeLayerWorld(
        _ layer: Layer,
        context: RenderContext
    ) -> ResolvedTransform? {
        guard let (matrix, opacity) = computeWorldTransform(
            for: layer,
            at: context.frame,
            baseWorldMatrix: context.parentWorld,
            baseWorldOpacity: context.parentOpacity,
            layerById: context.layerById,
            sceneFrameIndex: context.frameIndex
        ) else {
            return nil
        }
        return ResolvedTransform(worldMatrix: matrix, worldOpacity: opacity)
    }

    /// Emits render commands for a layer (group, transform, matte, masks, content)
    private mutating func emitLayerCommands(
        _ layer: Layer,
        resolved: ResolvedTransform,
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        commands.append(.beginGroup(name: "Layer:\(layer.name)(\(layer.id))"))
        commands.append(.pushTransform(resolved.worldMatrix))

        // Matte begin
        if let matte = layer.matte {
            switch matte.mode {
            case .alpha:
                commands.append(.beginMatteAlpha(sourceLayerId: matte.sourceLayerId))
            case .alphaInverted:
                commands.append(.beginMatteAlphaInverted(sourceLayerId: matte.sourceLayerId))
            }
        }

        // Masks begin
        for mask in layer.masks {
            if let staticPath = mask.path.staticPath {
                // Normalize opacity from 0..100 to 0..1, clamped
                let normalizedOpacity = min(1.0, max(0.0, mask.opacity / 100.0))
                commands.append(.beginMaskAdd(path: staticPath, opacity: normalizedOpacity))
            }
        }

        // Content
        renderLayerContent(layer, resolved: resolved, context: context, commands: &commands)

        // Masks end (LIFO)
        for _ in layer.masks { commands.append(.endMask) }

        // Matte end
        if layer.matte != nil { commands.append(.endMatte) }

        commands.append(.popTransform)
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
        resolved: ResolvedTransform,
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        switch layer.content {
        case .image(let assetId):
            commands.append(.drawImage(assetId: assetId, opacity: resolved.worldOpacity))

        case .precomp(let compId):
            // Cycle detection: check if we're already rendering this composition
            if context.visitedComps.contains(compId) {
                let stackPath = context.visitedComps.sorted().joined(separator: " → ")
                let issue = RenderIssue(
                    severity: .error,
                    code: RenderIssue.codePrecompCycle,
                    path: "anim(\(meta.sourceAnimRef)).layers[id=\(layer.id)].refId",
                    message: "Cycle detected: '\(compId)' already in render stack: [\(stackPath)]",
                    frameIndex: context.frameIndex
                )
                lastRenderIssues.append(issue)
                return
            }

            // Precomp not found
            guard let precomp = comps[compId] else {
                let issue = RenderIssue(
                    severity: .error,
                    code: RenderIssue.codePrecompAssetNotFound,
                    path: "anim(\(meta.sourceAnimRef)).layers[id=\(layer.id)].refId",
                    message: "Precomp '\(compId)' not found in compositions",
                    frameIndex: context.frameIndex
                )
                lastRenderIssues.append(issue)
                return
            }

            // Calculate child frame using Lottie st offset
            let childFrame = context.frame - layer.timing.startTime
            let childLayerById = Dictionary(uniqueKeysWithValues: precomp.layers.map { ($0.id, $0) })

            // Add current compId to visited stack for cycle detection
            var childVisited = context.visitedComps
            childVisited.insert(compId)

            // IMPORTANT: parentWorld = .identity because container transform is already
            // on the command stack via pushTransform(resolved.worldMatrix) above.
            // Children compute relative transforms within their composition.
            // Effective matrix = stack * childLocal (applied automatically by executor).
            // Opacity has no stack, so we pass it as a number.
            let childContext = RenderContext(
                frame: childFrame,
                frameIndex: context.frameIndex,
                parentWorld: .identity,
                parentOpacity: resolved.worldOpacity,
                layerById: childLayerById,
                visitedComps: childVisited
            )
            renderComposition(precomp, context: childContext, commands: &commands)

        case .shapes, .none:
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
