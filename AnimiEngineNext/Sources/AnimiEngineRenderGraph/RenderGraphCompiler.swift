import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §7, §7.1–§7.4 — the deterministic RenderGraph compiler (§17 step 9, corrective pass).
///
/// `compile(plan:input:configuration:)` is pure and deterministic: no IO, Metal call, mutable-project
/// or adapter lookup; it consumes only the `FramePlan`, the `ResolvedFrameInput` and the
/// `RenderConfiguration`, and returns a complete immutable `RenderGraph` — **after validating it**
/// (corrective #10). Corrective behaviours:
///   * **#2** fully explicit render-target flow (every pass names its source/target surface);
///   * **#3** the complete selected program is compiled from `rootCompID`, recursively expanding
///     precomps, preserving authored layer order, representing image/shape/none content, respecting
///     hidden/toggle state, and failing closed on unsupported content;
///   * **#4** authored image layers draw their pre-resolved asset pixels; the binding layer draws the
///     user media; a missing asset is a typed error;
///   * **#6** a matte source is rendered into an explicit surface and linked to its consumer;
///   * **#7 / CP4** scene-layer `blockToCanvas` mirrors the TVECore block transform:
///     identity when the authored animation spans the canvas, otherwise `animToInputContain`;
///   * **#9** dense unique composition orders and `SceneRole` vs body position are enforced.
public enum RenderGraphCompiler {

    public static func compile(
        plan: FramePlan,
        input: ResolvedFrameInput,
        configuration: RenderConfiguration
    ) throws -> RenderGraph {
        // Plan/configuration agreement (corrective #10): the frame plan's output grid must match the
        // configuration the graph targets.
        guard plan.output.canvas.width == configuration.output.canvas.width,
              plan.output.canvas.height == configuration.output.canvas.height,
              plan.output.frameRate.numerator == configuration.output.frameRate.numerator,
              plan.output.frameRate.denominator == configuration.output.frameRate.denominator else {
            throw RenderGraphError.validatorColorProfileMismatch(detail: "plan output != configuration output")
        }

        var ctx = CompileContext(input: input, configuration: configuration)

        // 1) Declare the sRGB output surface and the linear canvas is implicit-by-declaration: declare
        //    both offscreens explicitly (corrective #2 — no implicit surfaces).
        let canvasW = try canvasRaw(plan.output.canvas.width)
        let canvasH = try canvasRaw(plan.output.canvas.height)
        ctx.declareIntermediateSurface(RenderSurface.linearCanvas, width: canvasW, height: canvasH, configuration: configuration)
        ctx.declareFinalSRGBSurface(RenderSurface.sRGBSurface, width: canvasW, height: canvasH, configuration: configuration)

        // 2) Cleared background into the linear canvas.
        ctx.emit(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))

        // 3) Declare every resolved pixel input as a resource carrying its owned bytes (corrective #1).
        for pixel in input.pixelInputs {
            ctx.declarePixelResource(pixel)
        }
        // 3b) CP7.8: declare every DYNAMIC texture source (user video) as a value-only resource. The raw
        //     GPU texture is bound at execution; here we emit only the deterministic descriptor.
        for dyn in input.dynamicTextureInputs {
            try ctx.declareDynamicTextureResource(dyn)
        }

        // 4) Body.
        switch plan.body {
        case .single(let subplan):
            guard subplan.role == .sole else {
                throw RenderGraphError.inconsistentAnimationRequest(
                    sceneID: subplan.sceneID.raw, layerID: "", detail: "single body requires SceneRole .sole, got \(subplan.role)")
            }
            try compileScene(subplan, role: .sole, target: RenderSurface.linearCanvas, into: &ctx)
        case .transition(let transition):
            guard transition.outgoing.role == .outgoing, transition.incoming.role == .incoming else {
                throw RenderGraphError.inconsistentAnimationRequest(
                    sceneID: transition.outgoing.sceneID.raw, layerID: "",
                    detail: "transition requires outgoing/incoming roles")
            }
            let outgoingSurface = "surface\u{1F}outgoing\u{1F}\(transition.outgoing.sceneID.raw)"
            let incomingSurface = "surface\u{1F}incoming\u{1F}\(transition.incoming.sceneID.raw)"
            ctx.declareIntermediateSurface(outgoingSurface, width: canvasW, height: canvasH, configuration: configuration)
            ctx.declareIntermediateSurface(incomingSurface, width: canvasW, height: canvasH, configuration: configuration)
            // Render both complete scenes into their surfaces (outgoing continues rendering, §7.3).
            try compileScene(transition.outgoing, role: .outgoing, target: outgoingSurface, into: &ctx)
            try compileScene(transition.incoming, role: .incoming, target: incomingSurface, into: &ctx)
            // The transition composites those populated surfaces into the linear canvas.
            try TransitionGraphBuilder.emitTransition(
                transition: transition, outgoingSurface: outgoingSurface, incomingSurface: incomingSurface,
                targetSurface: RenderSurface.linearCanvas, canvasWidth: canvasW, canvasHeight: canvasH, into: &ctx)
        }

        // 5) Overlays above the body, into the linear canvas.
        try OverlayGraphBuilder.build(overlays: plan.overlays, input: input, into: &ctx)

        // 6) Final conversion + output (explicit source/target chain, corrective #2).
        ctx.emit(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        ctx.emit(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))

        let graph = try RenderGraph(configuration: configuration, commands: try ctx.commands())
        // Compiler validates the completed graph before returning (corrective #10).
        try RenderGraphValidator.validate(graph, configuration: configuration)
        return graph
    }

    /// Canvas extent in points → `CanvasScalar` raw units.
    static func canvasRaw(_ points: Int64) throws -> Int64 {
        try CheckedInt64.multiply(points, CanvasScalar.unitsPerPoint, "canvas.raw")
    }

    // MARK: - Scene subgraph

    static func compileScene(
        _ subplan: SceneSubplan, role: ResolvedSceneRole, target: String, into ctx: inout CompileContext
    ) throws {
        // Validate the role matches the requested body position (corrective #9).
        let expectedRole: ResolvedSceneRole
        switch subplan.role {
        case .sole: expectedRole = .sole
        case .outgoing: expectedRole = .outgoing
        case .incoming: expectedRole = .incoming
        }
        guard expectedRole == role else {
            throw RenderGraphError.inconsistentAnimationRequest(
                sceneID: subplan.sceneID.raw, layerID: "", detail: "scene role \(subplan.role) != body position \(role)")
        }

        // Dense unique localCompositionOrder (corrective #9): reject duplicates and gaps.
        try requireDenseUniqueOrders(subplan.layers.map { $0.localCompositionOrder },
                                     field: "scene[\(subplan.sceneID.raw)].localCompositionOrder")

        // Clear the scene surface before drawing (corrective #5). The linear canvas is already cleared
        // by the top-level clearBackground; a transition scene surface needs its own clear here.
        if target != RenderSurface.linearCanvas {
            ctx.emit(.clearBackground(color: .transparentBlack, targetSurfaceID: target))
        }
        ctx.emit(.beginScene(sceneID: subplan.sceneID.raw, role: role, targetSurfaceID: target))
        let ordered = subplan.layers.sorted { $0.localCompositionOrder < $1.localCompositionOrder }
        for layer in ordered {
            try compileSceneLayer(layer, sceneID: subplan.sceneID, role: role, target: target, into: &ctx)
        }
        ctx.emit(.endScene(sceneID: subplan.sceneID.raw, role: role, targetSurfaceID: target))
    }

    /// Compiles one scene media layer: resolves its program, computes the block→canvas transform, and
    /// expands the **complete** program composition tree from `rootCompID` (corrective #3).
    static func compileSceneLayer(
        _ layer: ActiveLayer, sceneID: SceneInstanceID, role: ResolvedSceneRole, target: String, into ctx: inout CompileContext
    ) throws {
        let key = ResolvedLayerKey.sceneLayer(sceneID: sceneID, role: role, layerID: layer.layerID)
        guard let program = ctx.input.program(for: key),
              let placement = ctx.input.mediaPlacement(for: key),
              let userPixelID = ctx.input.pixelInputID(for: key) else {
            throw RenderGraphError.missingMaterialBinding(sceneID: sceneID.raw, layerID: layer.layerID.raw)
        }

        // Animation request → scene frame time (request modes, §7.2; corrective #8 reference/request).
        guard let request = layer.animationRequest else {
            throw RenderGraphError.inconsistentAnimationRequest(
                sceneID: sceneID.raw, layerID: layer.layerID.raw, detail: "media layer without animationRequest")
        }
        // Reject a reference/request mismatch (corrective #8): a non-trivial request needs a reference.
        switch request {
        case .sample, .looped:
            guard layer.animationReference != nil else {
                throw RenderGraphError.inconsistentAnimationRequest(
                    sceneID: sceneID.raw, layerID: layer.layerID.raw, detail: "sample/looped request without AnimationReference")
            }
        case .holdLast, .inactive:
            break
        }
        let authoredTicks = layer.animationReference?.authoredDuration.ticks ?? 0
        guard let sceneFrame = try AnimationSampler.frameTime(for: request, meta: program.meta, authoredDurationTicks: authoredTicks) else {
            return   // .inactive: nothing rendered.
        }

        // blockToCanvas: maps the block's ANIMATION coordinate space (where authored layer positions
        // live) into the canvas, mirroring the TVECore oracle (SceneTransforms.blockTransform):
        //   if animSize == canvasSize → IDENTITY (authored positions are canvas-absolute);
        //   else → animToInputContain(animSize, blockRectCanvas) (uniform contain-scale + centre).
        // animSize is the WHOLE animation coordinate space = AnimIR meta.size, carried canonically by
        // `program.meta.width/height` (NOT duplicated in mediaGeometry — CP4 Rev-4 cleanup). It is
        // DISTINCT from `mediaGeometry.contentSize` (the binding fit baseline). The previous model used
        // `placementMatrix(Placement(frame: block.rect))`, which re-applied the block origin on top of
        // already-canvas-absolute authored positions (the double-origin bug). MediaFitResolver still
        // uses contentRect/contentSize as the fit baseline.
        let canvasWRaw = try canvasRaw(ctx.configuration.output.canvas.width)
        let canvasHRaw = try canvasRaw(ctx.configuration.output.canvas.height)
        let animWidthRaw = program.meta.width.rawValue
        let animHeightRaw = program.meta.height.rawValue
        let blockToCanvas: FixedAffineTransform2D
        if animWidthRaw == canvasWRaw && animHeightRaw == canvasHRaw {
            blockToCanvas = .identity
        } else {
            blockToCanvas = try animToInputContain(
                animWidth: animWidthRaw, animHeight: animHeightRaw,
                blockRect: program.mediaGeometry.blockRectCanvas)
        }

        // Expand the complete program tree from the root composition.
        guard let root = program.compositions.first(where: { $0.id == program.rootCompID }) else {
            throw RenderGraphError.missingComposition(compID: program.rootCompID)
        }
        // Rev-4 §3.1 — retain the actual path resources by id, rejecting duplicate ids (no trap path).
        var pathResourcesByID: [Int: RenderPathResource] = [:]
        for resource in program.pathResources {
            guard pathResourcesByID[resource.pathID] == nil else {
                throw RenderGraphError.pathResourceMismatch(
                    pathID: resource.pathID, field: "program[\(program.id.rawValue)].pathResources",
                    detail: "duplicate pathID")
            }
            pathResourcesByID[resource.pathID] = resource
        }
        let isVideo: Bool = { if case .video = layer.content { return true }; return false }()
        let frame = LayerFrame(
            program: program, input: ctx.input, key: key, sceneID: sceneID, layerID: layer.layerID,
            roleRaw: role.rawValue, target: target, blockToCanvas: blockToCanvas, mediaPlacement: placement,
            userPixelID: userPixelID, userContentIsVideo: isVideo, pathResourcesByID: pathResourcesByID)
        try expandComposition(root, parentWorld: blockToCanvas, parentOpacity: .opaque, compFrame: sceneFrame, frame: frame, target: target, depth: 0, into: &ctx, visiting: [])
    }

    /// Recursively expands a composition's layers in authored order, emitting draw/mask/matte commands.
    /// `parentOpacity` is the accumulated opacity of the enclosing precomp-layer chain (symmetric to
    /// `parentWorld` for transforms): a precomp layer's own opacity scales its whole subtree (bugfix —
    /// previously dropped at the precomp boundary, so an opacity keyframe on a precomp/root layer had no
    /// effect on the rendered subtree).
    static func expandComposition(
        _ comp: RenderComposition, parentWorld: FixedAffineTransform2D, parentOpacity: OpacityScalar,
        compFrame: RationalSourceTime, frame: LayerFrame, target: String, depth: Int,
        into ctx: inout CompileContext, visiting: Set<String>
    ) throws {
        guard depth < 64, !visiting.contains(comp.id) else {
            throw RenderGraphError.parentCycle(compID: comp.id, layerID: -1)
        }
        let nextVisiting = visiting.union([comp.id])
        let layersByID = try indexLayers(comp)
        // Draw bottom-to-top: AE/Lottie `comp.layers` is ordered top-to-bottom (index 0 is the
        // top-most/front layer), so the renderer must emit the LAST array element first and the
        // first element last. (Matches TVECore `AnimIR.swift:257` `composition.layers.reversed()`;
        // forward iteration here drew authored decor UNDER the binding media — CP2 blocker.)
        // Matte sources/parents are resolved by explicit id (layersByID / matte.sourceLayerID), so
        // reversing the visible-draw order does not affect matte/parent resolution.
        for layer in comp.layers.reversed() {
            // A matte SOURCE layer must not also render as an ordinary visible layer (corrective #3); it
            // is rendered (into its matte surface) only as part of its consumer's matte pass.
            if layer.isMatteSource { continue }
            try compileAnimLayer(layer, in: comp, layersByID: layersByID, parentWorld: parentWorld,
                                 parentOpacity: parentOpacity, compFrame: compFrame, frame: frame,
                                 target: target, depth: depth, into: &ctx, visiting: nextVisiting)
        }
    }

    /// The world transform of `layer` within `comp` at `compFrame`, applying the **parent chain** with
    /// **each parent sampled at its own layer timing/startTime** (corrective #2). `parentWorld` is the
    /// transform of the enclosing composition. A missing parent or a cycle is a typed error raised on the
    /// compiler path.
    static func worldWithinComp(
        _ layer: RenderLayer, layersByID: [Int: RenderLayer], comp: RenderComposition,
        compFrame: RationalSourceTime, parentWorld: FixedAffineTransform2D
    ) throws -> FixedAffineTransform2D {
        // Build the chain layer→…→root, detecting cycles and missing parents on the compiler path.
        var chain: [RenderLayer] = []
        var seen = Set<Int>()
        var currentID: Int? = layer.id
        while let id = currentID {
            guard let l = layersByID[id] else {
                throw RenderGraphError.missingParentLayer(compID: comp.id, layerID: layer.id, parentLayerID: id)
            }
            guard seen.insert(id).inserted else {
                throw RenderGraphError.parentCycle(compID: comp.id, layerID: id)
            }
            chain.append(l)
            currentID = l.parentLayerID
        }
        // Compose root→child: world = parentWorld · local(root) · … · local(child). Each parent uses its
        // OWN startTime, ALWAYS at `compFrame − startTime` regardless of the parent's visible interval
        // (corrective #3): parent visibility and parent transform time are separate concerns. A parent
        // outside its visible range still positions its children.
        var world = parentWorld
        for l in chain.reversed() {
            let lf = try AnimationSampler.layerTransformFrame(l.timing, compFrame: compFrame)
            let local = try AnimationSampler.localTransform(l.transform, at: lf, field: "comp[\(comp.id)].layer[\(l.id)].transform")
            world = try world.concatenating(local)
        }
        return world
    }

    /// The accumulated opacity of `layer` within `comp` at `compFrame`: the inherited **precomp-container**
    /// opacity (`parentOpacity`) × this layer's OWN sampled opacity. Per After Effects / Lottie semantics
    /// (and the TVECore oracle, `AnimIR.computeWorldTransform`: `worldOpacity = baseWorldOpacity * localOpacity`),
    /// **layer parenting affects ONLY transform, never opacity** — the parent chain is honoured for the world
    /// matrix (``worldWithinComp``) but must NOT scale opacity. Only the enclosing precomp container's opacity
    /// (carried in `parentOpacity` across the recursion) propagates to children. (Corrective: a prior change
    /// wrongly walked the parenting chain for opacity too, so a 0%-opacity parent/null layer zeroed its
    /// children — e.g. example_4blocks block_02's `img_1.2_parent` blanked the alpha-matte source+consumer.)
    /// The product is checked fixed-point and clamped to `[0, 1]`.
    static func opacityWithinComp(
        _ layer: RenderLayer, layersByID: [Int: RenderLayer], comp: RenderComposition,
        compFrame: RationalSourceTime, parentOpacity: OpacityScalar
    ) throws -> OpacityScalar {
        // This layer's OWN opacity, sampled at its OWN transform frame (same timing rule as the transform).
        let lf = try AnimationSampler.layerTransformFrame(layer.timing, compFrame: compFrame)
        let own = try AnimationSampler.sampleOpacity(
            layer.transform.opacity, at: lf, field: "comp[\(comp.id)].layer[\(layer.id)].opacity")
        // precompContainer × own — the parenting chain contributes transform only (AE/Lottie/TVECore).
        let raw = try FixedPointMath.multiplyDivideRounding(
            parentOpacity.rawValue, own.rawValue, OpacityScalar.unitsPerUnit,
            "comp[\(comp.id)].layer[\(layer.id)].opacityChain")
        return try OpacityScalar(rawValue: min(max(raw, 0), OpacityScalar.unitsPerUnit))
    }

    /// Compiles a single AnimIR layer honouring timing, hidden/toggle state, type↔content alignment,
    /// parent chain, masks (sampled), mattes (rendered source surface + link), shapes, and asset sizing.
    static func compileAnimLayer(
        _ layer: RenderLayer, in comp: RenderComposition, layersByID: [Int: RenderLayer],
        parentWorld: FixedAffineTransform2D, parentOpacity: OpacityScalar, compFrame: RationalSourceTime,
        frame: LayerFrame, target: String, depth: Int, into ctx: inout CompileContext, visiting: Set<String>,
        asMatteSource: Bool = false, matteChain: Set<Int> = []
    ) throws {
        let field = "scene[\(frame.sceneID.raw)].layer[\(frame.layerID.raw)].comp[\(comp.id)].animLayer[\(layer.id)]"
        try requireTypeContentAlignment(layer, field: field)
        guard depth < 64 else { throw RenderGraphError.parentCycle(compID: comp.id, layerID: layer.id) }

        // CP7.5 (oracle parity): a MATTE SOURCE bypasses BOTH the hidden flag AND the timing-active
        // [inPoint,outPoint) gate. TVECore renders a matte source via `emitLayerForMatteSource`, which
        // calls `computeLayerWorld` WITHOUT any `isVisible`/`isHidden` check — so a source authored to
        // a shorter range than its consumer still renders (its tracks clamp to the last keyframe =
        // hold-last), keeping the consumer matted/visible. An ORDINARY layer keeps both gates: hidden
        // or out-of-timing → it simply does not draw. The matte source samples at the non-gated
        // transform frame (still the VISUAL clock), never a special per-source clamp.
        let localFrame: RationalSourceTime
        if asMatteSource {
            localFrame = try AnimationSampler.layerTransformFrame(layer.timing, compFrame: compFrame)
        } else {
            if layer.isHidden { return }
            guard let active = try AnimationSampler.layerLocalFrame(layer.timing, compFrame: compFrame) else {
                return   // ordinary layer, out of its [inPoint,outPoint) range → no draw
            }
            localFrame = active
        }
        // world including the parent chain (corrective #2).
        let world = try worldWithinComp(layer, layersByID: layersByID, comp: comp, compFrame: compFrame, parentWorld: parentWorld)
        // opacity including the parent chain AND the enclosing precomp-layer opacity (bugfix): a precomp/
        // parent layer's opacity scales this layer's draw, symmetric to the transform chain. (Was: only the
        // layer's own opacity, dropping precomp/parent opacity entirely.)
        let opacity = try opacityWithinComp(layer, layersByID: layersByID, comp: comp, compFrame: compFrame, parentOpacity: parentOpacity)

        // Matte (Rev-4 §5.4): isolate BOTH the source and the consumer into target-cloned surfaces, then
        // link them into `target`. The consumer's whole masked contribution renders into a consumer
        // surface (never directly into target); the link composites the matted result into target.
        var matteResolution: (mode: RenderMatteMode, source: RenderLayer, sourceSurfaceID: String, consumerSurfaceID: String)?
        if let (mode, source) = try MaskMatteGraphBuilder.resolveMatte(for: layer, layersByID: layersByID, field: field) {
            // Explicit matte-chain cycle detection (final micro-correction #3 / §2.9).
            let chainWithSelf = matteChain.union([layer.id])
            guard !chainWithSelf.contains(source.id) else {
                throw RenderGraphError.matteCycle(compID: comp.id, layerID: source.id)
            }
            let sourceSurfaceID = ctx.matteSurfaceID(
                scene: frame.sceneID.raw, role: frame.roleRaw, layerID: frame.layerID.raw, comp: comp.id, sourceLayerID: source.id)
            let consumerSurfaceID = ctx.matteConsumerSurfaceID(
                scene: frame.sceneID.raw, role: frame.roleRaw, layerID: frame.layerID.raw, comp: comp.id, consumerLayerID: layer.id)
            // §5.1 — both isolation surfaces clone the actual target descriptor.
            try ctx.declareIntermediateSurfaceLike(newID: sourceSurfaceID, targetSurfaceID: target)
            try ctx.declareIntermediateSurfaceLike(newID: consumerSurfaceID, targetSurfaceID: target)
            ctx.emit(.clearBackground(color: .transparentBlack, targetSurfaceID: sourceSurfaceID))
            ctx.emit(.clearBackground(color: .transparentBlack, targetSurfaceID: consumerSurfaceID))
            // Render the complete source subtree into the source surface (own masks/nested matte/precomp).
            // The source carries the SAME inherited precomp opacity as the consumer (its own chain opacity is
            // accumulated inside its compileAnimLayer call).
            try compileAnimLayer(source, in: comp, layersByID: layersByID, parentWorld: parentWorld,
                                 parentOpacity: parentOpacity, compFrame: compFrame, frame: frame,
                                 target: sourceSurfaceID, depth: depth + 1,
                                 into: &ctx, visiting: visiting, asMatteSource: true, matteChain: chainWithSelf)
            matteResolution = (mode, source, sourceSurfaceID, consumerSurfaceID)
        }

        // The surface the layer's own masked contribution writes to: the consumer surface when this layer
        // is a matte consumer, otherwise the passed-in `target`.
        let contributionTarget = matteResolution?.consumerSurfaceID ?? target

        // Clip scope (only the bound media layer carries the container clip).
        let isBindingLayer = (comp.id == frame.program.binding.boundCompID && layer.id == frame.program.binding.boundLayerID)
        var clipRect: FixedRect?
        if isBindingLayer {
            if case .rect(let r) = frame.mediaPlacement.clip { clipRect = r }
        }
        if let clipRect { ctx.emit(.beginClip(rect: clipRect)) }

        // Mask group (Rev-4 §5.2): if the layer has masks, isolate its content into a target-cloned
        // mask-content surface, then `endMask` applies the aggregate mask once into `contributionTarget`.
        let maskOperations = try MaskMatteGraphBuilder.maskOperations(
            for: layer, at: localFrame, world: world, pathResourcesByID: frame.pathResourcesByID, field: field)
        if maskOperations.isEmpty {
            try emitContent(layer, in: comp, world: world, opacity: opacity, localFrame: localFrame,
                            frame: frame, depth: depth, target: contributionTarget, into: &ctx, visiting: visiting, layersByID: layersByID)
        } else {
            let scopeOrdinal = ctx.allocateScopeOrdinal()
            let contentSurfaceID = ctx.maskContentSurfaceID(
                scene: frame.sceneID.raw, role: frame.roleRaw, layerID: frame.layerID.raw,
                comp: comp.id, maskLayerID: layer.id, scopeOrdinal: scopeOrdinal)
            try ctx.declareIntermediateSurfaceLike(newID: contentSurfaceID, targetSurfaceID: contributionTarget)
            ctx.emit(.clearBackground(color: .transparentBlack, targetSurfaceID: contentSurfaceID))
            ctx.emit(.beginMask(operations: maskOperations, contentSurfaceID: contentSurfaceID, targetSurfaceID: contributionTarget))
            try emitContent(layer, in: comp, world: world, opacity: opacity, localFrame: localFrame,
                            frame: frame, depth: depth, target: contentSurfaceID, into: &ctx, visiting: visiting, layersByID: layersByID)
            ctx.emit(.endMask(contentSurfaceID: contentSurfaceID, targetSurfaceID: contributionTarget))
        }

        if clipRect != nil { ctx.emit(.endClip) }

        // Emit the matte link AFTER both source and consumer subtrees are complete (§5.4).
        if let m = matteResolution {
            ctx.emit(.matteLink(mode: m.mode, sourceLayerID: m.source.id, consumerLayerID: layer.id,
                                sourceSurfaceID: m.sourceSurfaceID, consumerSurfaceID: m.consumerSurfaceID,
                                targetSurfaceID: target))
        }
    }

    /// Emits the draw/expansion for a layer's content onto `target` (threaded explicitly).
    static func emitContent(
        _ layer: RenderLayer, in comp: RenderComposition, world: FixedAffineTransform2D, opacity: OpacityScalar,
        localFrame: RationalSourceTime, frame: LayerFrame, depth: Int,
        target: String, into ctx: inout CompileContext, visiting: Set<String>, layersByID: [Int: RenderLayer]
    ) throws {
        let field = "scene[\(frame.sceneID.raw)].comp[\(comp.id)].layer[\(layer.id)]"
        switch layer.content {
        case .none:
            return
        case .precomp(let compID):
            guard let sub = frame.program.compositions.first(where: { $0.id == compID }) else {
                throw RenderGraphError.missingComposition(compID: compID)
            }
            // Precomp content renders into the SAME `target` it was asked for (corrective #3: a matte
            // precomp renders into the matte surface, never frame.target). The precomp LAYER's accumulated
            // opacity (`opacity`, which already includes this layer's parent chain) becomes the subtree's
            // parentOpacity, so a precomp/root layer's opacity scales its whole subtree (bugfix).
            try expandComposition(sub, parentWorld: world, parentOpacity: opacity, compFrame: localFrame, frame: frame, target: target, depth: depth + 1, into: &ctx, visiting: visiting)
        case .image(let assetID):
            let isBindingLayer = (comp.id == frame.program.binding.boundCompID && layer.id == frame.program.binding.boundLayerID)
            if isBindingLayer {
                let finalTransform = try world.concatenating(frame.mediaPlacement.transform)
                let payload: RenderCommandPayload = frame.userContentIsVideo
                    ? .drawVideoFrame(resourceID: frame.userPixelID.rawValue, transform: finalTransform, opacity: opacity, targetSurfaceID: target)
                    : .drawImage(resourceID: frame.userPixelID.rawValue, transform: finalTransform, opacity: opacity, targetSurfaceID: target)
                ctx.emit(payload)
            } else {
                guard let pixels = frame.input.assetPixels(materialID: frame.program.id, assetID: assetID) else {
                    throw RenderGraphError.missingAssetPixels(materialID: frame.program.id.rawValue, assetID: assetID)
                }
                ctx.declarePixelResource(pixels)
                // Compose pixel-space → authored asset dimensions → world (corrective #7): scale the
                // fixture pixels onto the authored `RenderAsset` extent (do not assume they are equal).
                // A missing or invalid authored asset is a typed error (final corrective #6).
                guard let asset = frame.program.assets.first(where: { $0.id == assetID }) else {
                    throw RenderGraphError.missingAuthoredAsset(materialID: frame.program.id.rawValue, assetID: assetID, detail: "no RenderAsset")
                }
                let sizing = try assetSizing(pixels: pixels, asset: asset, materialID: frame.program.id.rawValue, assetID: assetID, field: field)
                let finalTransform = try world.concatenating(sizing)
                ctx.emit(.drawImage(resourceID: pixels.id.rawValue, transform: finalTransform, opacity: opacity, targetSurfaceID: target))
            }
        case .shapes(let group):
            // Rev-4 §5.5 — sample the producer mesh + stroke mesh, compose world·group into a single
            // path-local→target matrix, and emit one execution-ready drawShape.
            let (shape, groupTransform) = try sampledShape(
                group, at: localFrame, pathResourcesByID: frame.pathResourcesByID, field: "\(field).shape")
            let composed = try world.concatenating(groupTransform)
            ctx.emit(.drawShape(shape: shape, transform: composed, opacity: opacity, targetSurfaceID: target))
        }
    }

    /// Scales a fixture pixel buffer onto the authored asset's dimensions (corrective #7). An invalid
    /// (non-positive) authored asset extent is a typed error — there is **no identity fallback**
    /// (final corrective #6).
    static func assetSizing(pixels: ResolvedPixelInput, asset: RenderAsset, materialID: String, assetID: String, field: String) throws -> FixedAffineTransform2D {
        guard asset.width.rawValue > 0, asset.height.rawValue > 0 else {
            throw RenderGraphError.missingAuthoredAsset(materialID: materialID, assetID: assetID,
                detail: "non-positive authored asset dimensions \(asset.width.rawValue)x\(asset.height.rawValue)")
        }
        let one = FixedAffineTransform2D.linearUnitsPerOne
        let pxWRaw = try CheckedInt64.multiply(Int64(pixels.dimensions.width), CanvasScalar.unitsPerPoint, "\(field).pxW")
        let pxHRaw = try CheckedInt64.multiply(Int64(pixels.dimensions.height), CanvasScalar.unitsPerPoint, "\(field).pxH")
        guard pxWRaw > 0, pxHRaw > 0 else {
            throw RenderGraphError.invalidSourceDimensions(width: pixels.dimensions.width, height: pixels.dimensions.height)
        }
        let sx = try FixedPointMath.multiplyDivideRounding(asset.width.rawValue, one, pxWRaw, "\(field).sx")
        let sy = try FixedPointMath.multiplyDivideRounding(asset.height.rawValue, one, pxHRaw, "\(field).sy")
        return FixedAffineTransform2D.scale(scaleX: sx, scaleY: sy)
    }

    /// Samples a shape group's geometry/fill/stroke and its **composed group transform/opacity** at
    /// `frame` into a `SampledShape` (corrective #1). Every `groupTransform` is sampled and composed in
    /// authored order as `T(position)·R·S·T(-anchor)`; the group opacity is the checked fixed-point
    /// product of every group transform's sampled opacity.
    static func sampledShape(
        _ group: RenderShapeGroup, at frame: RationalSourceTime,
        pathResourcesByID: [Int: RenderPathResource], field: String
    ) throws -> (shape: SampledShape, groupTransform: FixedAffineTransform2D) {
        // The fill mesh + colour are present together (a fill needs both a path resource and a colour).
        // The fill rule is already baked into the producer triangulation — Metal never recomputes it.
        var fillMesh: SampledPathMesh?
        var fillColor: SampledSRGBAColor?
        if let fc = group.fillColor {
            guard let animPath = group.animPath, let pid = group.pathID else {
                throw RenderGraphError.missingPathResource(pathID: group.pathID ?? -1, field: "\(field).fill.pathID")
            }
            guard let resource = pathResourcesByID[pid] else {
                throw RenderGraphError.missingPathResource(pathID: pid, field: "\(field).fill.pathID")
            }
            let closed = try PathClosedResolver.invariantClosed(animPath, pathID: pid, field: "\(field).fill.path")
            guard closed else {
                throw RenderGraphError.pathResourceMismatch(pathID: pid, field: "\(field).fill.path", detail: "fill path must be closed")
            }
            fillMesh = try PathResourceSampler.sample(resource: resource, closed: closed, at: frame, field: "\(field).fill.mesh")
            fillColor = try fillSRGBA(fc, field: "\(field).fill.color")
        }

        // Stroke: build an execution-ready triangle mesh from the producer-flattened polyline.
        var stroke: SampledStroke?
        if let s = group.stroke {
            guard let pid = group.pathID, let animPath = group.animPath else {
                throw RenderGraphError.missingPathResource(pathID: group.pathID ?? -1, field: "\(field).stroke.pathID")
            }
            guard let resource = pathResourcesByID[pid] else {
                throw RenderGraphError.missingPathResource(pathID: pid, field: "\(field).stroke.pathID")
            }
            let closed = try PathClosedResolver.invariantClosed(animPath, pathID: pid, field: "\(field).stroke.path")
            let polyline = try PathResourceSampler.sample(resource: resource, closed: closed, at: frame, field: "\(field).stroke.polyline")
            guard let lineCap = RenderStrokeLineCap(rawValue: s.lineCap) else {
                throw RenderGraphError.unsupportedStrokeGeometry(field: "\(field).stroke.lineCap", detail: "unknown lineCap \(s.lineCap)")
            }
            guard let lineJoin = RenderStrokeLineJoin(rawValue: s.lineJoin) else {
                throw RenderGraphError.unsupportedStrokeGeometry(field: "\(field).stroke.lineJoin", detail: "unknown lineJoin \(s.lineJoin)")
            }
            let widthRaw = try AnimationSampler.sampleScalar(s.width, at: frame, field: "\(field).stroke.width")
            let width = CanvasScalar(rawValue: widthRaw)
            let mesh = try StrokeMeshBuilder.build(
                path: polyline, width: width, lineCap: lineCap, lineJoin: lineJoin, miterLimit: s.miterLimit)
            stroke = SampledStroke(
                sourcePathID: pid, mesh: mesh, color: try strokeSRGBA(s.color, field: "\(field).stroke.color"),
                opacity: s.opacity, width: width, lineCap: lineCap, lineJoin: lineJoin, miterLimit: s.miterLimit)
        }

        // Compose group transforms in authored order and multiply group opacities (checked fixed point).
        var composed = FixedAffineTransform2D.identity
        var opacityRaw = OpacityScalar.opaque.rawValue
        for (i, gt) in group.groupTransforms.enumerated() {
            let gf = "\(field).groupTransforms[\(i)]"
            let pos = try AnimationSampler.sampleVector(gt.position, at: frame, field: "\(gf).position")
            let anchor = try AnimationSampler.sampleVector(gt.anchor, at: frame, field: "\(gf).anchor")
            let scale = try AnimationSampler.sampleScale(gt.scale, at: frame, field: "\(gf).scale")
            let rotationRaw = try AnimationSampler.sampleRotation(gt.rotation, at: frame, field: "\(gf).rotation")
            let opacity = try AnimationSampler.sampleOpacity(gt.opacity, at: frame, field: "\(gf).opacity")
            let local = try FixedAffineTransform2D
                .translation(tx: pos.x, ty: pos.y)
                .concatenating(FixedAffineTransform2D.rotation(degreesTimesUnitsPerDegree: rotationRaw))
                .concatenating(FixedAffineTransform2D.scale(scaleX: scale.x, scaleY: scale.y))
                .concatenating(FixedAffineTransform2D.translation(
                    tx: try CheckedInt64.subtract(0, anchor.x, "\(gf).negAnchorX"),
                    ty: try CheckedInt64.subtract(0, anchor.y, "\(gf).negAnchorY")))
            composed = try composed.concatenating(local)
            opacityRaw = try FixedPointMath.multiplyDivideRounding(opacityRaw, opacity.rawValue, OpacityScalar.unitsPerUnit, "\(gf).opacityProduct")
        }
        let groupOpacity = try OpacityScalar(rawValue: min(max(opacityRaw, 0), OpacityScalar.unitsPerUnit))
        let shape = try SampledShape(
            fillMesh: fillMesh, fillColor: fillColor, fillOpacity: group.fillOpacity,
            stroke: stroke, groupOpacity: groupOpacity)
        return (shape, composed)
    }

    /// Fill-colour converter (FCP §1): the producer fill colour is **RGBA** — exactly 4 components. Any
    /// other count is a typed error; no coercion, no implicit alpha.
    static func fillSRGBA(_ color: RenderColor, field: String) throws -> SampledSRGBAColor {
        guard color.components.count == 4 else {
            throw RenderGraphError.unsupportedLayerMode(
                field: field, value: "fill colour must have 4 components (RGBA), got \(color.components.count)")
        }
        return try SampledSRGBAColor(components: color.components)
    }

    /// Stroke-colour converter (FCP §1): the producer stroke colour is **RGB** — exactly 3 components.
    /// The converter sets alpha = `.one` explicitly (the authored stroke alpha flows through the stroke
    /// opacity per the effective-style-alpha contract). Any other count is a typed error.
    static func strokeSRGBA(_ color: RenderColor, field: String) throws -> SampledSRGBAColor {
        guard color.components.count == 3 else {
            throw RenderGraphError.unsupportedLayerMode(
                field: field, value: "stroke colour must have 3 components (RGB), got \(color.components.count)")
        }
        return try SampledSRGBAColor(components: color.components + [.one])
    }

    // MARK: - Transforms

    /// TVECore oracle `GeometryMapping.animToInputContain`: uniformly scale the block's animation
    /// (`animWidth`×`animHeight`, CanvasScalar raw) to CONTAIN it within `blockRect` (canvas,
    /// CanvasScalar raw), centred, then translate to the block origin. Returns the anim→canvas affine.
    /// Degenerate sizes fall back to a translate to the block origin (matching the oracle's guards).
    static func animToInputContain(animWidth: Int64, animHeight: Int64, blockRect: FixedRect) throws -> FixedAffineTransform2D {
        let bx = blockRect.x.rawValue, by = blockRect.y.rawValue
        let bw = blockRect.width.rawValue, bh = blockRect.height.rawValue
        guard animWidth > 0, animHeight > 0, bw > 0, bh > 0 else {
            return FixedAffineTransform2D.translation(tx: bx, ty: by)
        }
        let unit = FixedAffineTransform2D.linearUnitsPerOne   // 1e6 raw per 1.0
        let sX = try FixedPointMath.multiplyDivideRounding(bw, unit, animWidth, "contain.scaleX")
        let sY = try FixedPointMath.multiplyDivideRounding(bh, unit, animHeight, "contain.scaleY")
        let scaleRaw = min(sX, sY)
        let scaledW = try FixedPointMath.multiplyDivideRounding(animWidth, scaleRaw, unit, "contain.scaledW")
        let scaledH = try FixedPointMath.multiplyDivideRounding(animHeight, scaleRaw, unit, "contain.scaledH")
        let tx = try CheckedInt64.add(bx, try FixedAffineTransform2D.divideRoundHalfAway(
            try CheckedInt64.subtract(bw, scaledW, "contain.dw"), 2, "contain.cx"), "contain.tx")
        let ty = try CheckedInt64.add(by, try FixedAffineTransform2D.divideRoundHalfAway(
            try CheckedInt64.subtract(bh, scaledH, "contain.dh"), 2, "contain.cy"), "contain.ty")
        return FixedAffineTransform2D(a: scaleRaw, b: 0, c: 0, d: scaleRaw, tx: tx, ty: ty)
    }

    /// Legacy `Placement` affine helper retained for focused geometry tests and non-scene placement math:
    /// translate to the frame **origin**, then apply isotropic scale + rotation about the frame **local**
    /// centre. Scene-layer `blockToCanvas` no longer calls this directly; it is derived from
    /// `program.meta.width/height` (the AnimIR anim size) + `mediaGeometry.blockRectCanvas` to match the
    /// TVECore block transform.
    static func placementMatrix(_ placement: Placement) throws -> FixedAffineTransform2D {
        let frame = placement.frame
        let localCentreX = try FixedAffineTransform2D.divideRoundHalfAway(frame.width.rawValue, 2, "place.lcx")
        let localCentreY = try FixedAffineTransform2D.divideRoundHalfAway(frame.height.rawValue, 2, "place.lcy")
        let rotate = try FixedAffineTransform2D.rotation(degreesTimesUnitsPerDegree: placement.rotation.rawValue)
        let scale = FixedAffineTransform2D.scale(scaleX: placement.scale.rawValue, scaleY: placement.scale.rawValue)
        let aboutLocalCentre = try FixedAffineTransform2D
            .translation(tx: localCentreX, ty: localCentreY)
            .concatenating(scale)
            .concatenating(rotate)
            .concatenating(FixedAffineTransform2D.translation(
                tx: try CheckedInt64.subtract(0, localCentreX, "place.negLcx"),
                ty: try CheckedInt64.subtract(0, localCentreY, "place.negLcy")))
        // Translate to the frame origin LAST (outermost), so a non-zero origin is always applied.
        return try FixedAffineTransform2D
            .translation(tx: frame.x.rawValue, ty: frame.y.rawValue)
            .concatenating(aboutLocalCentre)
    }

    // MARK: - Helpers

    static func requireDenseUniqueOrders(_ orders: [Int], field: String) throws {
        let sorted = orders.sorted()
        for (i, v) in sorted.enumerated() {
            guard v == i else {
                throw RenderGraphError.nonDenseOrder(field: field, detail: "orders not dense/unique 0..<n: \(orders)")
            }
        }
    }

    static func indexLayers(_ comp: RenderComposition) throws -> [Int: RenderLayer] {
        var byID: [Int: RenderLayer] = [:]
        for layer in comp.layers {
            guard byID[layer.id] == nil else {
                throw RenderGraphError.malformedTrack(field: "comp[\(comp.id)].layers", detail: "duplicate layer id \(layer.id)")
            }
            byID[layer.id] = layer
        }
        return byID
    }

    static func requireTypeContentAlignment(_ layer: RenderLayer, field: String) throws {
        let ok: Bool
        switch (layer.type, layer.content) {
        case (0, .precomp), (2, .image), (3, .none), (4, .shapes):
            ok = true
        default:
            ok = false
        }
        guard ok else {
            throw RenderGraphError.unsupportedLayerMode(
                field: "\(field).type", value: "type \(layer.type) does not match content \(layer.content)")
        }
    }
}
