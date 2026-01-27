// swiftlint:disable file_length
import Foundation

/// Intermediate Representation of a Lottie animation
/// Provides a normalized, render-ready structure for the animation pipeline
public struct AnimIR: Sendable, Equatable {
    /// Animation metadata
    public let meta: Meta

    /// Root composition ID
    public let rootComp: CompID

    /// All compositions (root + precomps) keyed by ID
    public var comps: [CompID: Composition]

    /// Asset index (assetId -> relativePath)
    public let assets: AssetIndexIR

    /// Binding layer information
    public let binding: BindingInfo

    /// Path registry for GPU path rendering (masks and shapes)
    public var pathRegistry: PathRegistry

    /// Issues from the last renderCommands call (reset on each call)
    public private(set) var lastRenderIssues: [RenderIssue] = []

    public init(
        meta: Meta,
        rootComp: CompID,
        comps: [CompID: Composition],
        assets: AssetIndexIR,
        binding: BindingInfo,
        pathRegistry: PathRegistry = PathRegistry()
    ) {
        self.meta = meta
        self.rootComp = rootComp
        self.comps = comps
        self.assets = assets
        self.binding = binding
        self.pathRegistry = pathRegistry
    }

    /// Root composition ID constant
    public static let rootCompId: CompID = "__root__"

    // MARK: - Equatable (exclude lastRenderIssues from comparison)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.meta == rhs.meta &&
        lhs.rootComp == rhs.rootComp &&
        lhs.comps == rhs.comps &&
        lhs.assets == rhs.assets &&
        lhs.binding == rhs.binding &&
        lhs.pathRegistry == rhs.pathRegistry
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

// MARK: - Path Registration (Legacy)

extension AnimIR {
    /// Registers all paths (masks and shapes) in the PathRegistry.
    /// - Note: Deprecated no-op. Paths are now registered during compilation.
    ///   Use `AnimIRCompiler.compile(..., pathRegistry:)` for scene-level path registration.
    @available(*, deprecated, message: "Paths are now registered during compilation. Use AnimIRCompiler.compile(..., pathRegistry:)")
    public mutating func registerPaths() {
        // NO-OP: Paths are registered during compilation.
        // This method is kept only for API compatibility.
        // Do not call - use compile(..., pathRegistry:) instead.
    }

    /// Registers all paths into an external PathRegistry.
    ///
    /// - Note: This is **legacy/debug** behavior. Paths are now registered during compilation.
    ///   Use `AnimIRCompiler.compile(..., pathRegistry:)` for scene-level path registration.
    ///
    /// - Important: Best-effort legacy path registration. May silently skip untriangulatable
    ///   paths (when `PathResourceBuilder.build` returns nil). For guaranteed registration
    ///   with proper error handling, use `AnimIRCompiler.compile(..., pathRegistry:)`.
    ///
    /// - Parameter registry: External registry to register paths into
    @available(*, deprecated, message: "Paths are now registered during compilation. Use AnimIRCompiler.compile(..., pathRegistry:)")
    public mutating func registerPaths(into registry: inout PathRegistry) {
        // Collect keys in deterministic order to ensure consistent PathID assignment
        // Root composition first, then precomps sorted alphabetically
        let compIds = comps.keys.sorted { lhs, rhs in
            if lhs == AnimIR.rootCompId { return true }
            if rhs == AnimIR.rootCompId { return false }
            return lhs < rhs
        }

        for compId in compIds {
            guard let comp = comps[compId] else { continue }
            var updatedLayers: [Layer] = []

            for var layer in comp.layers {
                // Register mask paths
                var updatedMasks: [Mask] = []
                for var mask in layer.masks {
                    if mask.pathId == nil {
                        // Use dummy PathID for build, rely only on assignedId from register()
                        if let resource = PathResourceBuilder.build(from: mask.path, pathId: PathID(0)) {
                            let assignedId = registry.register(resource)
                            mask.pathId = assignedId
                        }
                    }
                    updatedMasks.append(mask)
                }

                // Register shape paths (for matte sources)
                var updatedContent = layer.content
                if case .shapes(var shapeGroup) = layer.content {
                    if shapeGroup.pathId == nil, let animPath = shapeGroup.animPath {
                        // Use dummy PathID for build, rely only on assignedId from register()
                        if let resource = PathResourceBuilder.build(from: animPath, pathId: PathID(0)) {
                            let assignedId = registry.register(resource)
                            shapeGroup.pathId = assignedId
                            updatedContent = .shapes(shapeGroup)
                        }
                    }
                }

                // Create updated layer with new masks and content
                layer = Layer(
                    id: layer.id,
                    name: layer.name,
                    type: layer.type,
                    timing: layer.timing,
                    parent: layer.parent,
                    transform: layer.transform,
                    masks: updatedMasks,
                    matte: layer.matte,
                    content: updatedContent,
                    isMatteSource: layer.isMatteSource
                )
                updatedLayers.append(layer)
            }

            // Update composition with updated layers
            let updatedComp = Composition(id: compId, size: comp.size, layers: updatedLayers)
            comps[compId] = updatedComp
        }

        // IMPORTANT: Do NOT copy registry to pathRegistry here.
        // This was the source of the duplication bug where each AnimIR
        // stored the entire merged registry.
        // Scene pipeline should use scene-level registry, not AnimIR.pathRegistry.
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
        let scaleX = scale.x / 100.0
        let scaleY = scale.y / 100.0

        // Build matrix: T(position) * R(rotation) * S(scale) * T(-anchor)
        return Matrix2D.translation(x: position.x, y: position.y)
            .concatenating(.rotationDegrees(rotation))
            .concatenating(.scale(x: scaleX, y: scaleY))
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
        // Handle matte consumer with scope-based structure
        if let matte = layer.matte {
            emitMatteScope(
                consumer: layer,
                consumerResolved: resolved,
                matte: matte,
                context: context,
                commands: &commands
            )
            return
        }

        // Regular layer (no matte)
        emitRegularLayerCommands(layer, resolved: resolved, context: context, commands: &commands)
    }

    /// Emits scope-based matte structure with matteSource and matteConsumer groups
    private mutating func emitMatteScope(
        consumer: Layer,
        consumerResolved: ResolvedTransform,
        matte: MatteInfo,
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        // Map IR MatteMode to RenderCommand RenderMatteMode
        let renderMatteMode: RenderMatteMode
        switch matte.mode {
        case .alpha:
            renderMatteMode = .alpha
        case .alphaInverted:
            renderMatteMode = .alphaInverted
        case .luma:
            renderMatteMode = .luma
        case .lumaInverted:
            renderMatteMode = .lumaInverted
        }

        commands.append(.beginMatte(mode: renderMatteMode))

        // Emit matteSource group
        commands.append(.beginGroup(name: "matteSource"))
        if let sourceLayer = context.layerById[matte.sourceLayerId] {
            // Compute matte source world transform
            if let sourceResolved = computeLayerWorld(sourceLayer, context: context) {
                // Render matte source as regular layer (no matte wrapping for the source itself)
                emitRegularLayerCommands(
                    sourceLayer,
                    resolved: sourceResolved,
                    context: context,
                    commands: &commands
                )
            }
        } else {
            // Matte source layer not found - record issue
            let issue = RenderIssue(
                severity: .error,
                code: RenderIssue.codeMatteSourceNotFound,
                path: "anim(\(meta.sourceAnimRef)).layers[id=\(consumer.id)]",
                message: "Matte source layer id=\(matte.sourceLayerId) not found",
                frameIndex: context.frameIndex
            )
            lastRenderIssues.append(issue)
        }
        commands.append(.endGroup)

        // Emit matteConsumer group
        commands.append(.beginGroup(name: "matteConsumer"))
        emitRegularLayerCommands(
            consumer,
            resolved: consumerResolved,
            context: context,
            commands: &commands
        )
        commands.append(.endGroup)

        commands.append(.endMatte)
    }

    /// Emits render commands for a regular layer (without matte wrapping)
    private mutating func emitRegularLayerCommands(
        _ layer: Layer,
        resolved: ResolvedTransform,
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        commands.append(.beginGroup(name: "Layer:\(layer.name)(\(layer.id))"))
        commands.append(.pushTransform(resolved.worldMatrix))

        // Masks begin - emit in REVERSE order for correct AE application order.
        // AE applies masks top-to-bottom (index 0 first). With LIFO-nested structure,
        // reversed emission ensures masks are applied in AE order after unwrapping.
        var emittedMaskCount = 0
        for mask in layer.masks.reversed() {
            if let pathId = mask.pathId {
                // Normalize opacity from 0..100 to 0..1, clamped
                let normalizedOpacity = min(1.0, max(0.0, mask.opacity / 100.0))
                commands.append(.beginMask(
                    mode: mask.mode,
                    inverted: mask.inverted,
                    pathId: pathId,
                    opacity: normalizedOpacity,
                    frame: context.frame
                ))
                emittedMaskCount += 1
            }
        }

        // Content
        renderLayerContent(layer, resolved: resolved, context: context, commands: &commands)

        // Masks end (LIFO) - match emitted masks only
        for _ in 0..<emittedMaskCount { commands.append(.endMask) }

        commands.append(.popTransform)
        commands.append(.endGroup)
    }

    // Computes world transform for a layer considering parent chain.
    // Returns nil if parent chain has errors (PARENT_NOT_FOUND or PARENT_CYCLE).
    // swiftlint:disable:next function_parameter_count
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

        // Apply parent transforms in order (root parent first)
        // NOTE: Parenting chain affects ONLY transform, NOT opacity (per Lottie/AE semantics)
        for parentLayer in parentChain.reversed() {
            let parentLocal = Self.computeLocalMatrix(transform: parentLayer.transform, at: frame)
            worldMatrix = worldMatrix.concatenating(parentLocal)
        }

        // Apply this layer's local transform
        let localMatrix = Self.computeLocalMatrix(transform: layer.transform, at: frame)
        let localOpacity = Self.computeOpacity(transform: layer.transform, at: frame)

        worldMatrix = worldMatrix.concatenating(localMatrix)

        // Opacity formula: context.parentOpacity (from precomp recursion) * layerOpacity
        // Parenting chain does NOT affect opacity - only precomp container does
        let worldOpacity = baseWorldOpacity * localOpacity

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

    // Renders layer content based on type.
    // swiftlint:disable:next function_body_length
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

        case .shapes(let shapeGroup):
            // Render shape as filled path (used for matte sources)
            if let pathId = shapeGroup.pathId {
                commands.append(.drawShape(
                    pathId: pathId,
                    fillColor: shapeGroup.fillColor,
                    fillOpacity: shapeGroup.fillOpacity,
                    layerOpacity: resolved.worldOpacity,
                    frame: context.frame
                ))
            }

        case .none:
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
