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

    /// Input geometry for mediaInput layer (PR-15)
    /// nil if no mediaInput layer exists in the animation
    public var inputGeometry: InputGeometryInfo?

    /// Issues from the last renderCommands call (reset on each call)
    public private(set) var lastRenderIssues: [RenderIssue] = []

    /// Cache for compContainsBinding() to avoid O(N^2) traversal in edit mode (PR-18)
    private var compContainsBindingCache: [CompID: Bool] = [:]

    public init(
        meta: Meta,
        rootComp: CompID,
        comps: [CompID: Composition],
        assets: AssetIndexIR,
        binding: BindingInfo,
        pathRegistry: PathRegistry = PathRegistry(),
        inputGeometry: InputGeometryInfo? = nil
    ) {
        self.meta = meta
        self.rootComp = rootComp
        self.comps = comps
        self.assets = assets
        self.binding = binding
        self.pathRegistry = pathRegistry
        self.inputGeometry = inputGeometry
    }

    /// Root composition ID constant
    public static let rootCompId: CompID = "__root__"

    // MARK: - Equatable (exclude lastRenderIssues from comparison)

    // Exclude lastRenderIssues and compContainsBindingCache from comparison
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.meta == rhs.meta &&
        lhs.rootComp == rhs.rootComp &&
        lhs.comps == rhs.comps &&
        lhs.assets == rhs.assets &&
        lhs.binding == rhs.binding &&
        lhs.pathRegistry == rhs.pathRegistry &&
        lhs.inputGeometry == rhs.inputGeometry
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
                    isMatteSource: layer.isMatteSource,
                    isHidden: layer.isHidden
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
        /// Binding layer ID (for inputClip detection)
        let bindingLayerId: LayerID
        /// Composition where binding layer resides
        let bindingCompId: CompID
        /// User transform applied to binding layer (PR-15: M(t) = A(t) ∘ U)
        let userTransform: Matrix2D
        /// Input geometry for mediaInput (nil if not present)
        let inputGeometry: InputGeometryInfo?
        /// Current composition ID (for same-comp check)
        let currentCompId: CompID
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
    /// - Parameters:
    ///   - frameIndex: Scene frame number to render
    ///   - userTransform: User pan/zoom/rotate transform applied to binding layer (PR-15).
    ///     Default is `.identity` (no user transform). The binding layer's world matrix becomes
    ///     `lottieWorld * userTransform`, i.e. animation is applied *after* user edits.
    /// - Returns: Array of render commands in execution order
    /// - Note: Check `lastRenderIssues` after calling for any errors encountered
    public mutating func renderCommands(
        frameIndex: Int,
        userTransform: Matrix2D = .identity
    ) -> [RenderCommand] {
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
                visitedComps: [rootComp],
                bindingLayerId: binding.boundLayerId,
                bindingCompId: binding.boundCompId,
                userTransform: userTransform,
                inputGeometry: inputGeometry,
                currentCompId: rootComp
            )
            renderComposition(rootComposition, context: context, commands: &commands)
        }

        // End root group
        commands.append(.endGroup)

        return commands
    }

    /// Convenience method that returns commands and issues without requiring var
    public func renderCommandsWithIssues(
        frameIndex: Int,
        userTransform: Matrix2D = .identity
    ) -> (commands: [RenderCommand], issues: [RenderIssue]) {
        var copy = self
        let commands = copy.renderCommands(frameIndex: frameIndex, userTransform: userTransform)
        return (commands, copy.lastRenderIssues)
    }

    // MARK: - Edit Mode Render (PR-18)

    /// Generates render commands for edit mode — only binding layer and its dependencies.
    ///
    /// Edit traversal renders the minimal subgraph needed to display the binding layer:
    /// - Binding layer itself (with inputClip, masks, userTransform)
    /// - Matte source layer (if binding layer is a matte consumer)
    /// - Precomp chain to reach binding layer (with their masks/mattes)
    /// - All other layers are skipped
    ///
    /// Invariant: layers are traversed in natural (JSON) order. Matte/mask scopes
    /// preserve source→consumer ordering within their scope.
    ///
    /// - Parameters:
    ///   - frameIndex: Frame index (typically editFrameIndex = 0)
    ///   - userTransform: User pan/zoom/rotate transform
    /// - Returns: Render commands for binding layer only
    public mutating func renderEditCommands(
        frameIndex: Int,
        userTransform: Matrix2D = .identity
    ) -> [RenderCommand] {
        lastRenderIssues.removeAll(keepingCapacity: true)

        var commands: [RenderCommand] = []
        let localFrame = Double(localFrameIndex(sceneFrameIndex: frameIndex))

        commands.append(.beginGroup(name: "AnimIR:\(meta.sourceAnimRef)(edit)"))

        if let rootComposition = comps[rootComp] {
            let layerById = Dictionary(uniqueKeysWithValues: rootComposition.layers.map { ($0.id, $0) })
            let context = RenderContext(
                frame: localFrame,
                frameIndex: frameIndex,
                parentWorld: .identity,
                parentOpacity: 1.0,
                layerById: layerById,
                visitedComps: [rootComp],
                bindingLayerId: binding.boundLayerId,
                bindingCompId: binding.boundCompId,
                userTransform: userTransform,
                inputGeometry: inputGeometry,
                currentCompId: rootComp
            )
            renderEditComposition(rootComposition, context: context, commands: &commands)
        }

        commands.append(.endGroup)
        return commands
    }

    /// Edit traversal: only processes layers that are part of the binding layer subgraph.
    private mutating func renderEditComposition(
        _ composition: Composition,
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        for layer in composition.layers {
            renderEditLayer(layer, context: context, commands: &commands)
        }
    }

    /// Edit layer filter: renders only layers needed for the binding layer.
    ///
    /// Decision tree:
    /// 1. Skip matte sources (rendered via emitMatteScope when their consumer is rendered)
    /// 2. Skip hidden layers (geometry only, e.g. mediaInput)
    /// 3. If this IS the binding layer (same comp, same id) → emit it (full render path)
    /// 4. If this is a precomp containing the binding layer → recurse into it
    /// 5. Otherwise → skip
    ///
    /// **Invariant (PR-18):** This method intentionally does NOT check layer visibility
    /// (`isVisible(at: frame)`). Edit mode renders the binding layer's "editing pose"
    /// regardless of animation timing — the binding layer must always be reachable
    /// even if it would be invisible at the current frame in playback mode.
    /// Do not add an isVisible guard here.
    private mutating func renderEditLayer(
        _ layer: Layer,
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        // Skip matte source layers (rendered via matte scope when consumer is emitted)
        guard !layer.isMatteSource else { return }

        // Skip hidden layers (geometry sources only, e.g. mediaInput)
        guard !layer.isHidden else { return }

        // Compute world transform (needed for both binding layer and precomp container)
        guard let resolved = computeLayerWorld(layer, context: context) else { return }

        // Case 1: This IS the binding layer — emit exactly as in full render
        if isBindingLayer(layer, context: context) {
            emitLayerCommands(layer, resolved: resolved, context: context, commands: &commands)
            return
        }

        // Case 2: This is a precomp that (transitively) contains the binding layer — recurse
        if case .precomp(let compId) = layer.content,
           compContainsBinding(compId) {

            // Cycle detection
            guard !context.visitedComps.contains(compId) else { return }
            guard let precomp = comps[compId] else { return }

            let childFrame = context.frame - layer.timing.startTime
            let childLayerById = Dictionary(uniqueKeysWithValues: precomp.layers.map { ($0.id, $0) })
            var childVisited = context.visitedComps
            childVisited.insert(compId)

            // If the precomp layer is a matte consumer, wrap in edit matte scope
            if let matte = layer.matte {
                emitEditPrecompMatteScope(
                    precompLayer: layer,
                    resolved: resolved,
                    matte: matte,
                    childFrame: childFrame,
                    childLayerById: childLayerById,
                    childVisited: childVisited,
                    precomp: precomp,
                    compId: compId,
                    context: context,
                    commands: &commands
                )
            } else {
                // Emit precomp container structure (group + transform + masks)
                commands.append(.beginGroup(name: "Layer:\(layer.name)(\(layer.id))(edit)"))
                commands.append(.pushTransform(resolved.worldMatrix))

                // Emit masks on precomp container (they affect binding layer visibility)
                var emittedMaskCount = 0
                for mask in layer.masks.reversed() {
                    if let pathId = mask.pathId {
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

                let childContext = RenderContext(
                    frame: childFrame,
                    frameIndex: context.frameIndex,
                    parentWorld: .identity,
                    parentOpacity: resolved.worldOpacity,
                    layerById: childLayerById,
                    visitedComps: childVisited,
                    bindingLayerId: context.bindingLayerId,
                    bindingCompId: context.bindingCompId,
                    userTransform: context.userTransform,
                    inputGeometry: context.inputGeometry,
                    currentCompId: compId
                )
                renderEditComposition(precomp, context: childContext, commands: &commands)

                for _ in 0..<emittedMaskCount { commands.append(.endMask) }
                commands.append(.popTransform)
                commands.append(.endGroup)
            }
            return
        }

        // Case 3: Not binding, not containing binding → skip
    }

    /// Emits matte scope for a precomp container in edit mode.
    /// The matte source is rendered normally (it's a dependency); the consumer side
    /// recurses into edit traversal to find the binding layer.
    private mutating func emitEditPrecompMatteScope(
        precompLayer: Layer,
        resolved: ResolvedTransform,
        matte: MatteInfo,
        childFrame: Double,
        childLayerById: [LayerID: Layer],
        childVisited: Set<CompID>,
        precomp: Composition,
        compId: CompID,
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        let renderMatteMode: RenderMatteMode
        switch matte.mode {
        case .alpha: renderMatteMode = .alpha
        case .alphaInverted: renderMatteMode = .alphaInverted
        case .luma: renderMatteMode = .luma
        case .lumaInverted: renderMatteMode = .lumaInverted
        }

        commands.append(.beginMatte(mode: renderMatteMode))

        // Matte source: render normally (it's a visual dependency)
        commands.append(.beginGroup(name: "matteSource"))
        if let sourceLayer = context.layerById[matte.sourceLayerId] {
            if let sourceResolved = computeLayerWorld(sourceLayer, context: context) {
                emitRegularLayerCommands(
                    sourceLayer,
                    resolved: sourceResolved,
                    context: context,
                    commands: &commands
                )
            }
        }
        commands.append(.endGroup)

        // Matte consumer: emit precomp container, recurse into edit traversal
        commands.append(.beginGroup(name: "matteConsumer"))
        commands.append(.pushTransform(resolved.worldMatrix))

        // Emit masks on precomp container
        var emittedMaskCount = 0
        for mask in precompLayer.masks.reversed() {
            if let pathId = mask.pathId {
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

        let childContext = RenderContext(
            frame: childFrame,
            frameIndex: context.frameIndex,
            parentWorld: .identity,
            parentOpacity: resolved.worldOpacity,
            layerById: childLayerById,
            visitedComps: childVisited,
            bindingLayerId: context.bindingLayerId,
            bindingCompId: context.bindingCompId,
            userTransform: context.userTransform,
            inputGeometry: context.inputGeometry,
            currentCompId: compId
        )
        renderEditComposition(precomp, context: childContext, commands: &commands)

        for _ in 0..<emittedMaskCount { commands.append(.endMask) }
        commands.append(.popTransform)
        commands.append(.endGroup)

        commands.append(.endMatte)
    }

    /// Checks if a composition (directly or transitively) contains the binding layer.
    /// Results are cached to avoid O(N^2) with deep nested precomps.
    private mutating func compContainsBinding(_ compId: CompID) -> Bool {
        if let cached = compContainsBindingCache[compId] { return cached }
        let result = computeCompContainsBinding(compId)
        compContainsBindingCache[compId] = result
        return result
    }

    private func computeCompContainsBinding(_ compId: CompID) -> Bool {
        guard let comp = comps[compId] else { return false }
        for layer in comp.layers {
            // Direct match: binding layer lives in this comp
            if layer.id == binding.boundLayerId && compId == binding.boundCompId {
                return true
            }
            // Transitive: a precomp in this comp may contain the binding layer
            if case .precomp(let childCompId) = layer.content {
                if childCompId == binding.boundCompId {
                    return true
                }
                // Check deeper nesting (non-mutating to avoid cache issues in recursion)
                if computeCompContainsBinding(childCompId) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Full Render Pipeline

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

        // Skip hidden layers (hd=true) - they are geometry sources only (e.g. mediaInput)
        guard !layer.isHidden else { return }

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

    /// Checks if this layer is the binding layer in the correct composition
    private func isBindingLayer(_ layer: Layer, context: RenderContext) -> Bool {
        layer.id == context.bindingLayerId && context.currentCompId == context.bindingCompId
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
    // swiftlint:disable:next function_body_length
    private mutating func emitRegularLayerCommands(
        _ layer: Layer,
        resolved: ResolvedTransform,
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        // PR-15: Check if this is the binding layer with inputClip
        let needsInputClip = isBindingLayer(layer, context: context) && context.inputGeometry != nil

        if needsInputClip, let inputGeo = context.inputGeometry {
            // === InputClip path for binding layer ===
            //
            // Structure (per ТЗ section 2.3):
            //   beginGroup(layer: media (inputClip))
            //     pushTransform(world(mediaInput, t))    ← mediaInput transform (fixed window)
            //     beginMask(mode: .intersect, pathId: mediaInputPathId)
            //     popTransform
            //     pushTransform(world(media, t) * userTransform)   ← media + user edits
            //       [masks + content]
            //     popTransform
            //     endMask
            //   endGroup

            commands.append(.beginGroup(name: "Layer:\(layer.name)(\(layer.id))(inputClip)"))

            // 1) Compute mediaInput world transform (fixed window, no userTransform)
            let inputLayerWorld = computeMediaInputWorld(inputGeo: inputGeo, context: context)

            // 2) Push mediaInput transform for the mask path
            commands.append(.pushTransform(inputLayerWorld))

            // 3) Begin inputClip mask (reuse beginMask with intersect mode)
            // TODO(PR-future): if animated mediaInput is allowed, change frame: 0 to context.frame
            //                   and update validator to permit animated mediaInput path.
            commands.append(.beginMask(
                mode: .intersect,
                inverted: false,
                pathId: inputGeo.pathId,
                opacity: 1.0,
                frame: 0  // mediaInput path is static (frame 0) per ТЗ
            ))

            // 4) Pop mediaInput transform
            commands.append(.popTransform)

            // 5) Push media world transform with userTransform: M(t) = A(t) ∘ U
            let mediaWorldWithUser = resolved.worldMatrix.concatenating(context.userTransform)
            commands.append(.pushTransform(mediaWorldWithUser))

            // 6) Layer masks (masksProperties) - applied inside inputClip scope
            var emittedMaskCount = 0
            for mask in layer.masks.reversed() {
                if let pathId = mask.pathId {
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

            // 7) Content (drawImage)
            renderLayerContent(layer, resolved: resolved, context: context, commands: &commands)

            // 8) End layer masks (LIFO)
            for _ in 0..<emittedMaskCount { commands.append(.endMask) }

            // 9) Pop media transform
            commands.append(.popTransform)

            // 10) End inputClip mask
            commands.append(.endMask)

            // 11) End group
            commands.append(.endGroup)
        } else {
            // === Standard path (non-binding layer or no inputGeometry) ===
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
    }

    /// Computes the world matrix for the mediaInput layer at the current frame.
    /// mediaInput world is fixed (no userTransform) — it defines the clip window.
    private mutating func computeMediaInputWorld(
        inputGeo: InputGeometryInfo,
        context: RenderContext
    ) -> Matrix2D {
        // Find the mediaInput layer in its composition
        guard let comp = comps[inputGeo.compId],
              let inputLayer = comp.layers.first(where: { $0.id == inputGeo.layerId }) else {
            return .identity
        }

        // Build a temporary layerById for the composition
        let layerById = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })

        // Compute world transform without userTransform
        guard let (matrix, _) = computeWorldTransform(
            for: inputLayer,
            at: context.frame,
            baseWorldMatrix: .identity,
            baseWorldOpacity: 1.0,
            layerById: layerById,
            sceneFrameIndex: context.frameIndex
        ) else {
            return .identity
        }

        return matrix
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
                visitedComps: childVisited,
                bindingLayerId: context.bindingLayerId,
                bindingCompId: context.bindingCompId,
                userTransform: context.userTransform,
                inputGeometry: context.inputGeometry,
                currentCompId: compId
            )
            renderComposition(precomp, context: childContext, commands: &commands)

        case .shapes(let shapeGroup):
            // Render shape as filled path (used for matte sources)
            if let pathId = shapeGroup.pathId {
                // PR-11: Sample and compose all group transforms from stack
                // Each transform is sampled at current frame, then matrices are multiplied
                var composedMatrix = Matrix2D.identity
                var composedOpacity = 1.0

                for gt in shapeGroup.groupTransforms {
                    composedMatrix = composedMatrix.concatenating(gt.matrix(at: context.frame))
                    composedOpacity *= gt.opacityValue(at: context.frame)
                }

                // Compute effective layer opacity including group opacity
                let effectiveOpacity = resolved.worldOpacity * composedOpacity

                // Push composed group transform onto stack (will be composed with layer transform)
                let hasGroupTransform = composedMatrix != .identity
                if hasGroupTransform {
                    commands.append(.pushTransform(composedMatrix))
                }

                // Draw fill first (if present)
                if shapeGroup.fillColor != nil {
                    commands.append(.drawShape(
                        pathId: pathId,
                        fillColor: shapeGroup.fillColor,
                        fillOpacity: shapeGroup.fillOpacity,
                        layerOpacity: effectiveOpacity,
                        frame: context.frame
                    ))
                }

                // Draw stroke on top (if present) - PR-10
                if let stroke = shapeGroup.stroke {
                    let strokeWidth = stroke.width.sample(frame: context.frame)
                    commands.append(.drawStroke(
                        pathId: pathId,
                        strokeColor: stroke.color,
                        strokeOpacity: stroke.opacity,
                        strokeWidth: strokeWidth,
                        lineCap: stroke.lineCap,
                        lineJoin: stroke.lineJoin,
                        miterLimit: stroke.miterLimit,
                        layerOpacity: effectiveOpacity,
                        frame: context.frame
                    ))
                }

                // Pop group transform
                if hasGroupTransform {
                    commands.append(.popTransform)
                }
            }

        case .none:
            break
        }
    }
}

// MARK: - Hit-Test API (PR-15)

extension AnimIR {
    /// Returns the mediaInput path in composition space for hit-testing.
    ///
    /// The path is sampled at the given frame (default: frame 0) and transformed
    /// by the mediaInput layer's world matrix, so it's in composition coordinates.
    ///
    /// - Parameter frame: Frame to sample the path at (default: 0 for static mediaInput)
    /// - Returns: Array of BezierPath vertices in composition space, or nil if no mediaInput
    public mutating func mediaInputPath(frame: Int = 0) -> BezierPath? {
        guard let inputGeo = inputGeometry else { return nil }

        // Get the static path from animPath
        guard let basePath = inputGeo.animPath.staticPath else { return nil }

        // Find the mediaInput layer and compute its world transform
        guard let comp = comps[inputGeo.compId],
              let inputLayer = comp.layers.first(where: { $0.id == inputGeo.layerId }) else {
            return basePath
        }

        let layerById = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })

        guard let (worldMatrix, _) = computeWorldTransform(
            for: inputLayer,
            at: Double(frame),
            baseWorldMatrix: .identity,
            baseWorldOpacity: 1.0,
            layerById: layerById,
            sceneFrameIndex: frame
        ) else {
            return basePath
        }

        // If world matrix is identity, return base path as-is
        if worldMatrix == .identity {
            return basePath
        }

        // Transform all path components by the world matrix
        let transformedVertices = basePath.vertices.map { worldMatrix.apply(to: $0) }
        let transformedIn = basePath.inTangents.map { worldMatrix.apply(to: $0) }
        let transformedOut = basePath.outTangents.map { worldMatrix.apply(to: $0) }

        return BezierPath(
            vertices: transformedVertices,
            inTangents: transformedIn,
            outTangents: transformedOut,
            closed: basePath.closed
        )
    }

    /// Returns the world matrix of the mediaInput layer at the given frame.
    /// Useful when the caller wants to transform the path themselves.
    ///
    /// - Parameter frame: Frame to compute transform at (default: 0)
    /// - Returns: World matrix of mediaInput layer, or nil if no mediaInput
    public mutating func mediaInputWorldMatrix(frame: Int = 0) -> Matrix2D? {
        guard let inputGeo = inputGeometry else { return nil }

        guard let comp = comps[inputGeo.compId],
              let inputLayer = comp.layers.first(where: { $0.id == inputGeo.layerId }) else {
            return nil
        }

        let layerById = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })

        guard let (worldMatrix, _) = computeWorldTransform(
            for: inputLayer,
            at: Double(frame),
            baseWorldMatrix: .identity,
            baseWorldOpacity: 1.0,
            layerById: layerById,
            sceneFrameIndex: frame
        ) else {
            return nil
        }

        return worldMatrix
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
