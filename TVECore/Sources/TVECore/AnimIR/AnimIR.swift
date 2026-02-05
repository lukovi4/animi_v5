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

    // Exclude lastRenderIssues from comparison
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
        /// PR-26: Override clip from editVariant when active variant lacks mediaInput.
        let inputClipOverride: InputClipOverride?
        /// Current composition ID (for same-comp check)
        let currentCompId: CompID
        /// PR-28: Whether binding layer should be rendered.
        /// When `false`, binding layer is skipped entirely (no draw commands, no texture request).
        /// Controlled by ScenePlayer/SceneRenderPlan based on user media state.
        let bindingLayerVisible: Bool
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
    ///   - inputClipOverride: PR-26: Clip geometry + world matrix from the editVariant.
    ///     When the active variant lacks `inputGeometry` (anim-x without mediaInput),
    ///     this override supplies the clip window from the no-anim variant.
    ///   - bindingLayerVisible: PR-28: Whether to render the binding layer.
    ///     When `false`, the binding layer is skipped entirely — no draw commands are emitted
    ///     and no texture requests are made. Decor/shared layers render normally.
    ///     Default is `true` (binding layer renders as usual).
    /// - Returns: Array of render commands in execution order
    /// - Note: Check `lastRenderIssues` after calling for any errors encountered
    public mutating func renderCommands(
        frameIndex: Int,
        userTransform: Matrix2D = .identity,
        inputClipOverride: InputClipOverride? = nil,
        bindingLayerVisible: Bool = true
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
                inputClipOverride: inputClipOverride,
                currentCompId: rootComp,
                bindingLayerVisible: bindingLayerVisible
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
        userTransform: Matrix2D = .identity,
        inputClipOverride: InputClipOverride? = nil,
        bindingLayerVisible: Bool = true
    ) -> (commands: [RenderCommand], issues: [RenderIssue]) {
        var copy = self
        let commands = copy.renderCommands(
            frameIndex: frameIndex,
            userTransform: userTransform,
            inputClipOverride: inputClipOverride,
            bindingLayerVisible: bindingLayerVisible
        )
        return (commands, copy.lastRenderIssues)
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

        // PR-28: Skip binding layer when user media is not selected.
        // This prevents any draw commands and texture requests for the binding placeholder.
        if !context.bindingLayerVisible && isBindingLayer(layer, context: context) {
            return
        }

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
        commands: inout [RenderCommand],
        matteChainVisited: Set<LayerID> = []
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
        if context.layerById[matte.sourceLayerId] != nil {
            // PR-29: Delegate to helper that supports matte chains.
            // If the source is itself a consumer (chain), this recurses via emitMatteScope.
            emitLayerForMatteSource(
                layerId: matte.sourceLayerId,
                context: context,
                commands: &commands,
                visited: matteChainVisited
            )
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

    /// PR-29: Renders a matte source layer, supporting matte chains.
    ///
    /// If the source layer is itself a matte consumer (chain), this recurses
    /// through `emitMatteScope` to apply the nested matte before rendering.
    /// Otherwise, renders the source via `emitRegularLayerCommands`.
    ///
    /// Recursion is bounded by two mechanisms:
    /// 1. Compiler order check (`sourceArrayIndex < consumerArrayIndex`) guarantees DAG
    /// 2. Runtime `visited` set detects cycles defensively (future-proofing)
    private mutating func emitLayerForMatteSource(
        layerId: LayerID,
        context: RenderContext,
        commands: inout [RenderCommand],
        visited: Set<LayerID> = []
    ) {
        // Defensive cycle guard: should never trigger with compiler-validated IR,
        // but protects against manually-constructed or future-modified IR.
        guard !visited.contains(layerId) else {
            assertionFailure("Matte chain cycle detected at layerId=\(layerId)")
            lastRenderIssues.append(RenderIssue(
                severity: .error,
                code: RenderIssue.codeMatteChainCycle,
                path: "anim(\(meta.sourceAnimRef)).layers[id=\(layerId)]",
                message: "Matte chain cycle detected at layer id=\(layerId)",
                frameIndex: context.frameIndex
            ))
            return
        }

        guard let layer = context.layerById[layerId],
              let resolved = computeLayerWorld(layer, context: context) else { return }

        var nextVisited = visited
        nextVisited.insert(layerId)

        if let matte = layer.matte {
            // Matte chain: source is itself a consumer — recurse via emitMatteScope
            emitMatteScope(
                consumer: layer,
                consumerResolved: resolved,
                matte: matte,
                context: context,
                commands: &commands,
                matteChainVisited: nextVisited
            )
        } else {
            // Terminal source: render normally
            emitRegularLayerCommands(
                layer,
                resolved: resolved,
                context: context,
                commands: &commands
            )
        }
    }

    /// Emits render commands for a regular layer (without matte wrapping)
    // swiftlint:disable:next function_body_length
    private mutating func emitRegularLayerCommands(
        _ layer: Layer,
        resolved: ResolvedTransform,
        context: RenderContext,
        commands: inout [RenderCommand]
    ) {
        // PR-26: Effective input geometry — override from editVariant or own.
        let effectiveInputGeometry = context.inputClipOverride?.inputGeometry ?? context.inputGeometry

        // PR-15: Check if this is the binding layer with inputClip
        let needsInputClip = isBindingLayer(layer, context: context) && effectiveInputGeometry != nil

        // PR-22: Pre-compute inverse for scope-balanced inputClip emission.
        // The inverse compensates inputLayerWorld so content inside the mask scope
        // is not affected by the mask-positioning transform, while keeping all
        // push/pop transforms balanced within the mask scope boundary.
        let inputClipTransforms: (world: Matrix2D, inverse: Matrix2D)?
        if needsInputClip, let inputGeo = effectiveInputGeometry {
            // PR-26: Use pre-computed clipWorld from override when available.
            // The override is needed because the mediaInput layer may not exist
            // in the current AnimIR (anim-x variant), so computeMediaInputWorld
            // would fail to find the layer and return .identity (wrong position).
            let world: Matrix2D
            if let override = context.inputClipOverride {
                world = override.clipWorldMatrix
            } else {
                world = computeMediaInputWorld(inputGeo: inputGeo, context: context)
            }
            if let inv = world.inverse {
                inputClipTransforms = (world, inv)
            } else {
                inputClipTransforms = nil
                lastRenderIssues.append(RenderIssue(
                    severity: .warning,
                    code: RenderIssue.codeInputClipNonInvertible,
                    path: "anim(\(meta.sourceAnimRef)).layers[id=\(layer.id)]",
                    message: "inputLayerWorld not invertible (det\u{2248}0), skipping inputClip for layer \(layer.name)",
                    frameIndex: context.frameIndex
                ))
            }
        } else {
            inputClipTransforms = nil
        }

        if let inputGeo = effectiveInputGeometry, let clip = inputClipTransforms {
            // === InputClip path for binding layer (scope-balanced, PR-22) ===
            //
            // Structure (fixes cross-boundary transforms from original emission):
            //   beginGroup(layer: media (inputClip))
            //     pushTransform(inputLayerWorld)             ← outside scope
            //     beginMask(mode: .intersect, pathId: mediaInputPathId)
            //       pushTransform(inverse(inputLayerWorld))  ← compensation (balanced in scope)
            //       pushTransform(mediaWorld * userTransform)
            //         [content]                                 ← masks skipped (hardening)
            //       popTransform(mediaWorld)
            //       popTransform(inverse)                    ← balanced within scope
            //     endMask
            //     popTransform(inputLayerWorld)              ← outside scope, balanced
            //   endGroup

            commands.append(.beginGroup(name: "Layer:\(layer.name)(\(layer.id))(inputClip)"))

            // 1) Push inputLayerWorld (outside mask scope — positions the mask path)
            commands.append(.pushTransform(clip.world))

            // 2) Begin inputClip mask
            // TODO(PR-future): if animated mediaInput is allowed, change frame: 0 to context.frame
            //                   and update validator to permit animated mediaInput path.
            commands.append(.beginMask(
                mode: .intersect,
                inverted: false,
                pathId: inputGeo.pathId,
                opacity: 1.0,
                frame: 0  // mediaInput path is static (frame 0) per ТЗ
            ))

            // 3) Compensate: push inverse(inputLayerWorld) so content doesn't inherit
            //    the mask-positioning transform. This replaces the old cross-boundary
            //    popTransform that was inside the scope but closed an outer push.
            commands.append(.pushTransform(clip.inverse))

            // 4) Push media world transform with userTransform: M(t) = A(t) ∘ U
            let mediaWorldWithUser = resolved.worldMatrix.concatenating(context.userTransform)
            commands.append(.pushTransform(mediaWorldWithUser))

            // 5) Binding-layer masksProperties — SKIPPED (hardening).
            //
            // masksProperties sits inside pushTransform(mediaWorldWithUser), so the
            // mask moves WITH the photo when userTransform changes — "crop" effect.
            // The inputClip mask (step 2) is in comp-space and stays fixed — "clip".
            // Emitting masksProperties here would cause crop-vs-clip mismatch; the
            // inputClip is the authoritative viewport for the binding layer.
            if !layer.masks.isEmpty {
                lastRenderIssues.append(RenderIssue(
                    severity: .warning,
                    code: RenderIssue.codeBindingLayerMasksIgnored,
                    path: "anim(\(meta.sourceAnimRef)).layers[id=\(layer.id)]",
                    message: "Binding layer '\(layer.name)' has \(layer.masks.count) masksProperties — ignored; inputClip (mediaInput) is the authoritative clip",
                    frameIndex: context.frameIndex
                ))
            }

            // 6) Content (drawImage)
            renderLayerContent(layer, resolved: resolved, context: context, commands: &commands)

            // 8) Pop media transform
            commands.append(.popTransform)

            // 9) Pop inverse compensation (balanced within scope)
            commands.append(.popTransform)

            // 10) End inputClip mask
            commands.append(.endMask)

            // 11) Pop inputLayerWorld (outside scope — balanced with step 1)
            commands.append(.popTransform)

            // 12) End group
            commands.append(.endGroup)
        } else {
            // === Standard path (non-binding layer or no inputGeometry) ===
            commands.append(.beginGroup(name: "Layer:\(layer.name)(\(layer.id))"))

            // PR-25: Binding layer must apply userTransform even without inputClip.
            // Variants without mediaInput (inputGeometry == nil) still need user
            // pan/zoom/rotate — otherwise the transform "resets" on variant switch.
            let worldMatrix = isBindingLayer(layer, context: context)
                ? resolved.worldMatrix.concatenating(context.userTransform)
                : resolved.worldMatrix
            commands.append(.pushTransform(worldMatrix))

            // Masks — skip for binding layer (hardening, same rationale as inputClip path).
            // masksProperties inside pushTransform(worldMatrix+userTransform) would move
            // WITH the photo on user pan/zoom — "crop" effect instead of fixed "clip".
            var emittedMaskCount = 0
            if isBindingLayer(layer, context: context) {
                if !layer.masks.isEmpty {
                    lastRenderIssues.append(RenderIssue(
                        severity: .warning,
                        code: RenderIssue.codeBindingLayerMasksIgnored,
                        path: "anim(\(meta.sourceAnimRef)).layers[id=\(layer.id)]",
                        message: "Binding layer '\(layer.name)' has \(layer.masks.count) masksProperties — ignored; use mediaInput for clipping",
                        frameIndex: context.frameIndex
                    ))
                }
            } else {
                // Non-binding: emit in REVERSE order for correct AE application order.
                // AE applies masks top-to-bottom (index 0 first). With LIFO-nested structure,
                // reversed emission ensures masks are applied in AE order after unwrapping.
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
            }

            // Content
            renderLayerContent(layer, resolved: resolved, context: context, commands: &commands)

            // Masks end (LIFO) - match emitted masks only
            for _ in 0..<emittedMaskCount { commands.append(.endMask) }

            commands.append(.popTransform)
            commands.append(.endGroup)
        }
    }

    // MARK: - MediaInput Transform Helpers

    /// Resolves the accumulated transform of precomp containers from root to `targetCompId`.
    ///
    /// During render traversal the engine pushes container transforms onto the stack
    /// automatically.  For direct queries (hit-test, overlay, public API) we must
    /// resolve this chain explicitly.
    ///
    /// - Returns: Accumulated matrix (root → target), `.identity` when target is root,
    ///   or `nil` on parent-chain error.
    private mutating func resolvePrecompChainTransform(
        targetCompId: CompID,
        frame: Double,
        sceneFrameIndex: Int
    ) -> Matrix2D? {
        if targetCompId == AnimIR.rootCompId { return .identity }

        // Find the precomp container layer that references targetCompId
        for (compId, comp) in comps {
            for layer in comp.layers {
                guard case .precomp(let refCompId) = layer.content,
                      refCompId == targetCompId else { continue }

                // World transform of the container layer within its own comp
                let layerById = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })
                guard let (containerWorld, _) = computeWorldTransform(
                    for: layer,
                    at: frame,
                    baseWorldMatrix: .identity,
                    baseWorldOpacity: 1.0,
                    layerById: layerById,
                    sceneFrameIndex: sceneFrameIndex
                ) else {
                    return nil
                }

                // Recurse: the comp holding this container may itself be a precomp
                guard let parentChain = resolvePrecompChainTransform(
                    targetCompId: compId,
                    frame: frame,
                    sceneFrameIndex: sceneFrameIndex
                ) else {
                    return nil
                }

                return parentChain.concatenating(containerWorld)
            }
        }

        // Not found as a precomp target — treat as root-level
        return .identity
    }

    /// Composed matrix for the mediaInput layer **within its composition** (InComp).
    ///
    /// worldTransform (incl. parent chain) + groupTransforms.
    /// `baseWorldMatrix` allows the caller to inject outer context:
    ///   - `.identity` for render pipeline (precomp chain already on stack)
    ///   - precomp chain transform for hit-test / overlay / public API
    private mutating func computeMediaInputComposedMatrix(
        inputGeo: InputGeometryInfo,
        frame: Double,
        sceneFrameIndex: Int,
        baseWorldMatrix: Matrix2D = .identity
    ) -> Matrix2D? {
        guard let comp = comps[inputGeo.compId],
              let inputLayer = comp.layers.first(where: { $0.id == inputGeo.layerId }) else {
            return nil
        }

        let layerById = Dictionary(uniqueKeysWithValues: comp.layers.map { ($0.id, $0) })

        guard let (worldMatrix, _) = computeWorldTransform(
            for: inputLayer,
            at: frame,
            baseWorldMatrix: baseWorldMatrix,
            baseWorldOpacity: 1.0,
            layerById: layerById,
            sceneFrameIndex: sceneFrameIndex
        ) else {
            return nil
        }

        // Apply shape groupTransforms (PR-11 contract).
        // Paths are stored in LOCAL coords; group transforms are composed at sample time.
        switch inputLayer.content {
        case .shapes(let shapeGroup):
            var composed = worldMatrix
            for gt in shapeGroup.groupTransforms {
                composed = composed.concatenating(gt.matrix(at: frame))
            }
            return composed
        default:
            return worldMatrix
        }
    }

    /// Full composed matrix for mediaInput in **root composition space**.
    ///
    /// Resolves the precomp container chain, then delegates to the InComp helper.
    /// Used by `mediaInputPath` and `mediaInputWorldMatrix` (direct queries).
    private mutating func computeMediaInputComposedMatrixForRootSpace(
        inputGeo: InputGeometryInfo,
        frame: Double,
        sceneFrameIndex: Int
    ) -> Matrix2D? {
        guard let baseWorld = resolvePrecompChainTransform(
            targetCompId: inputGeo.compId,
            frame: frame,
            sceneFrameIndex: sceneFrameIndex
        ) else {
            return nil
        }

        return computeMediaInputComposedMatrix(
            inputGeo: inputGeo,
            frame: frame,
            sceneFrameIndex: sceneFrameIndex,
            baseWorldMatrix: baseWorld
        )
    }

    /// Computes the world matrix for the mediaInput layer at the current frame.
    /// mediaInput world is fixed (no userTransform) — it defines the clip window.
    /// Uses InComp helper (precomp chain is already on the render stack).
    private mutating func computeMediaInputWorld(
        inputGeo: InputGeometryInfo,
        context: RenderContext
    ) -> Matrix2D {
        computeMediaInputComposedMatrix(
            inputGeo: inputGeo,
            frame: context.frame,
            sceneFrameIndex: context.frameIndex
        ) ?? .identity
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
                inputClipOverride: context.inputClipOverride,
                currentCompId: compId,
                bindingLayerVisible: context.bindingLayerVisible
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
    /// Returns the mediaInput path in **root composition space** for hit-testing / overlay.
    ///
    /// The path is transformed by the full chain: precomp containers → layer world →
    /// groupTransforms.  This matches the geometry the render pipeline produces.
    ///
    /// - Parameter frame: Frame to sample the path at (default: 0 for static mediaInput)
    /// - Returns: BezierPath in root composition space, or nil if no mediaInput
    public mutating func mediaInputPath(frame: Int = 0) -> BezierPath? {
        guard let inputGeo = inputGeometry else { return nil }
        guard let basePath = inputGeo.animPath.staticPath else { return nil }

        guard let composedMatrix = computeMediaInputComposedMatrixForRootSpace(
            inputGeo: inputGeo,
            frame: Double(frame),
            sceneFrameIndex: frame
        ) else {
            return basePath
        }

        return basePath.applying(composedMatrix)
    }

    /// Returns the composed world matrix of the mediaInput layer in **root composition space**.
    ///
    /// Includes precomp container chain + layer world + groupTransforms.
    ///
    /// - Parameter frame: Frame to compute transform at (default: 0)
    /// - Returns: Composed matrix in root space, or nil if no mediaInput
    public mutating func mediaInputWorldMatrix(frame: Int = 0) -> Matrix2D? {
        guard let inputGeo = inputGeometry else { return nil }

        return computeMediaInputComposedMatrixForRootSpace(
            inputGeo: inputGeo,
            frame: Double(frame),
            sceneFrameIndex: frame
        )
    }

    /// Returns the **in-comp** world matrix of the mediaInput layer (PR-26).
    ///
    /// This is the mediaInput layer's world matrix **within its composition**,
    /// without the precomp container chain.  Used by `SceneRenderPlan` to
    /// pre-compute the clip world matrix for `InputClipOverride`.
    ///
    /// During render traversal the precomp container transform is already on the
    /// command stack, so the in-comp matrix is exactly what `computeMediaInputWorld`
    /// produces for the inputClip branch.
    ///
    /// - Parameter frame: Frame to compute transform at (default: 0)
    /// - Returns: In-comp composed matrix, or nil if no mediaInput
    mutating func mediaInputInCompWorldMatrix(frame: Int = 0) -> Matrix2D? {
        guard let inputGeo = inputGeometry else { return nil }

        return computeMediaInputComposedMatrix(
            inputGeo: inputGeo,
            frame: Double(frame),
            sceneFrameIndex: frame
        )
    }
}

