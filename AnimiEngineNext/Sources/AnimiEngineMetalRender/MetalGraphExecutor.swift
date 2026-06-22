import Foundation
import Metal
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineRenderGraph

/// Task-003 plan §4, §8 + corrective §1/§4/§7b — the per-execution graph executor.
///
/// Whole-graph preflight (plan §4.1 + corrective Issue-4 surface geometry) then the exact command-buffer
/// sequence (plan §8.6 + corrective §10): upload blits first, **normalization passes**, scenes, final
/// conversion, the readback blit last — one command buffer, one wait. Scene draws sample the **normalized**
/// linear-premultiplied texture (corrective §1). No fallback, placeholder, ignored command, force-unwrap,
/// trap, or silent substitution.
struct MetalGraphExecutor {
    let device: MTLDevice
    let pipelines: MetalPipelineLibrary
    let submitter: CommandSubmitter
    /// Corrective §7b — package-internal execution-event observer; inert when nil.
    let onExecutionEvent: ((ExecutionEvent) -> Void)?
    /// Corrective §7 — package-internal hook to surface the per-execution owner to a lifecycle test.
    let onOwnerCreated: ((MetalResourceOwner) -> Void)?
    /// Diagnostic seam (package-internal, inert when nil) — fires after each render command is encoded into
    /// the single command buffer, so a test can blit-read a surface's *intermediate* state at that exact
    /// point in the GPU program. Production sets nothing, so this is a no-op and behaviour is unchanged.
    var onCommandEncoded: ((Int, RenderCommandPayload, MetalResourceOwner, MTLCommandBuffer) -> Void)? = nil

    func execute(_ graph: RenderGraph) throws -> RenderedFrame {
        // CP7.6a: the readback path is the shared encode + a final readback blit (the ReferenceData
        // oracle). Byte-identical to the pre-CP7.6a behaviour. NEVER receives texture bindings (CP7.8):
        // the oracle path declares only bytes pixel inputs — a dynamic-texture resource here would fail
        // the binding lookup, which is correct (the oracle never renders user video).
        guard let frame = try runShared(graph, finish: .readback, textureBindings: .none) else {
            throw MetalRenderError.incompleteFrame(detail: "readback path produced no frame")
        }
        return frame
    }

    /// CP7.6a — GPU-direct: run the shared encode and copy the final sRGB pixels straight into the
    /// caller's external `target`, with NO CPU readback and NO `RenderedFrame`. Synchronous (commit+wait):
    /// the GPU write to `target` is complete on return.
    func render(_ graph: RenderGraph, into target: GPURenderTarget) throws {
        try render(graph, into: target, textureBindings: .none)
    }

    /// CP7.8 — GPU-direct with dynamic texture bindings (user video). Same external-target validation as
    /// the no-binding path; the bindings are consumed in `runShared`'s declareResource step.
    func render(_ graph: RenderGraph, into target: GPURenderTarget, textureBindings: RenderRuntimeTextureBindings) throws {
        // External-target validation (fail closed, no silent resize/reinterpret).
        let canvasW = graph.configuration.output.canvas.width
        let canvasH = graph.configuration.output.canvas.height
        if target.texture.device !== device {
            throw MetalRenderError.invalidRenderTarget(detail: "target texture device != session device")
        }
        guard target.texture.pixelFormat == .bgra8Unorm else {
            throw MetalRenderError.invalidRenderTarget(
                detail: "target pixelFormat \(target.texture.pixelFormat.rawValue) != bgra8Unorm")
        }
        guard target.texture.usage.contains(.renderTarget) else {
            throw MetalRenderError.invalidRenderTarget(detail: "target texture usage lacks .renderTarget")
        }
        guard Int64(target.texture.width) == canvasW, Int64(target.texture.height) == canvasH else {
            throw MetalRenderError.surfaceDimensionMismatch(
                resourceID: "externalTarget",
                expectedWidth: canvasW, expectedHeight: canvasH,
                actualWidth: Int64(target.texture.width), actualHeight: Int64(target.texture.height))
        }
        _ = try runShared(graph, finish: .target(target), textureBindings: textureBindings)
    }

    /// CP7.8 — resolve + validate the runtime texture binding for a dynamic-texture descriptor. Fail
    /// closed with a typed error on a missing binding or any device/format/usage mismatch. The dimension
    /// check (display vs descriptor) is done by the caller, which knows the quarter-turn. Returns the
    /// handle (texture + retained CV objects).
    private func resolveDynamicBinding(
        _ descriptor: RenderResourceDescriptor, bindings: RenderRuntimeTextureBindings
    ) throws -> RuntimeTextureHandle {
        guard let handle = bindings.handle(for: descriptor.resourceID) else {
            throw MetalRenderError.missingTextureBinding(resourceID: descriptor.resourceID)
        }
        let tex = handle.texture
        if tex.device !== device {
            throw MetalRenderError.invalidTextureBinding(
                resourceID: descriptor.resourceID, detail: "bound texture device != session device")
        }
        guard tex.pixelFormat == MetalTextureAllocator.pixelInputFormat else {
            throw MetalRenderError.invalidTextureBinding(
                resourceID: descriptor.resourceID,
                detail: "bound pixelFormat \(tex.pixelFormat.rawValue) != bgra8Unorm")
        }
        guard tex.usage.contains(.shaderRead) else {
            throw MetalRenderError.invalidTextureBinding(
                resourceID: descriptor.resourceID, detail: "bound texture usage lacks .shaderRead")
        }
        guard tex.width > 0, tex.height > 0 else {
            throw MetalRenderError.invalidTextureBinding(
                resourceID: descriptor.resourceID, detail: "bound texture has non-positive dimensions")
        }
        return handle
    }

    /// How the shared encode terminates after the final sRGB conversion.
    private enum Finish {
        case readback                 // blit sRGBSurface → staging → RenderedFrame (the oracle path)
        case target(GPURenderTarget)  // GPU copy sRGBSurface → external texture (CP7.6a)
    }

    /// The shared per-execution body (plan §8.6) up to and including the single commit+wait. Both the
    /// readback path (`execute`) and the GPU-target path (`render(into:)`) run the IDENTICAL preflight,
    /// allocation, upload, normalization, scene/transition encode, and final sRGB conversion; they
    /// diverge ONLY in the trailing step (readback blit vs external-target copy). Returns a
    /// `RenderedFrame` for `.readback` and nil for `.target`.
    @discardableResult
    private func runShared(
        _ graph: RenderGraph, finish: Finish, textureBindings: RenderRuntimeTextureBindings
    ) throws -> RenderedFrame? {
        let configuration = graph.configuration

        // ---- Step 1: whole-graph preflight (plan §4.1 + Issue-4) — no per-execution GPU objects yet. ----
        try preflight(graph, configuration: configuration)

        let allocator = MetalTextureAllocator(device: device)
        let uploader = MetalResourceUploader(device: device)
        let readback = MetalFrameReadback(device: device)
        let compositor = MetalColorConverter(pipelines: pipelines)
        let normalizer = MetalSourceNormalizer(pipelines: pipelines)
        let owner = MetalResourceOwner()
        onOwnerCreated?(owner)

        // CP7.8: per-resource quarter-turn for the normalization pass (0 for bytes inputs; the
        // descriptor's value for a dynamic texture input). Keyed by resourceID.
        var normalizeQuarterTurns: [String: Int] = [:]

        // ---- Step 3: allocate raw+normalized pixel textures; prepare host data / staging buffers. ----
        var stagedUploads: [MetalResourceUploader.StagedUpload] = []
        // The pixel resources in declaration order, for the normalization passes (step 7b).
        var pixelResourceOrder: [String] = []
        // ---- Step 4: allocate offscreen + final textures. ----
        for command in graph.commands {
            switch command.payload {
            case .declareResource(let descriptor):
                if descriptor.kind == .dynamicTexturePixelInput {
                    // CP7.8: bind the externally supplied RAW texture (track-native orientation). NO CPU
                    // upload. The normalized texture is allocated at the descriptor's DISPLAY (oriented)
                    // dims; the normalization pass applies the quarter-turn (raw → display). Fail closed
                    // on a missing/invalid binding — never a silent fallback.
                    let raw = try resolveDynamicBinding(descriptor, bindings: textureBindings)
                    owner.retainRuntimeBinding(raw.retain)   // hold CVPixelBuffer/CVMetalTexture to completion
                    let turns = descriptor.dynamicOrientationQuarterTurns ?? 0
                    // Display (oriented) dims: odd turns swap the raw texture's W/H. The descriptor's
                    // declared dims MUST equal these (fail closed on any mismatch).
                    let rawW = raw.texture.width, rawH = raw.texture.height
                    let displayW = (turns % 2 == 0) ? rawW : rawH
                    let displayH = (turns % 2 == 0) ? rawH : rawW
                    guard Int64(displayW) == descriptor.width, Int64(displayH) == descriptor.height else {
                        throw MetalRenderError.invalidTextureBinding(
                            resourceID: descriptor.resourceID,
                            detail: "bound texture \(rawW)x\(rawH) (turns \(turns) → display \(displayW)x\(displayH)) != descriptor \(descriptor.width)x\(descriptor.height)")
                    }
                    let normalizedTexture = try allocator.makeNormalizedTexture(
                        width: displayW, height: displayH, resourceID: descriptor.resourceID)
                    owner.registerPixelResource(
                        MetalResourceOwner.PixelResourceTextures(raw: raw.texture, normalized: normalizedTexture),
                        for: descriptor.resourceID)
                    pixelResourceOrder.append(descriptor.resourceID)
                    normalizeQuarterTurns[descriptor.resourceID] = turns
                    break   // dynamic input fully set up; no staged/shared upload.
                }
                guard let pixels = descriptor.pixels else {
                    throw MetalRenderError.missingResource(resourceID: descriptor.resourceID)
                }
                let rawTexture = try allocator.makePixelInputTexture(descriptor)
                let normalizedTexture = try allocator.makeNormalizedTexture(
                    width: rawTexture.width, height: rawTexture.height, resourceID: descriptor.resourceID)
                // §1.2a inv. 1: equal dims — fail closed on any mismatch (never a silent resample).
                guard normalizedTexture.width == rawTexture.width,
                      normalizedTexture.height == rawTexture.height else {
                    throw MetalRenderError.surfaceDimensionMismatch(
                        resourceID: descriptor.resourceID,
                        expectedWidth: Int64(rawTexture.width), expectedHeight: Int64(rawTexture.height),
                        actualWidth: Int64(normalizedTexture.width), actualHeight: Int64(normalizedTexture.height))
                }
                owner.registerPixelResource(
                    MetalResourceOwner.PixelResourceTextures(raw: rawTexture, normalized: normalizedTexture),
                    for: descriptor.resourceID)
                pixelResourceOrder.append(descriptor.resourceID)
                normalizeQuarterTurns[descriptor.resourceID] = 0
                if allocator.pixelInputNeedsStagedUpload {
                    let staged = try uploader.prepareStagedUpload(
                        pixels, into: rawTexture, resourceID: descriptor.resourceID)
                    owner.retain(stagingBuffer: staged.stagingBuffer)
                    stagedUploads.append(staged)
                } else {
                    try uploader.uploadShared(pixels, into: rawTexture, resourceID: descriptor.resourceID)
                }
            case .offscreenSurface(let descriptor):
                let texture = try allocator.makeOffscreenTexture(descriptor)
                owner.registerSurface(texture, for: descriptor.resourceID)
            default:
                break
            }
        }

        // ---- Step 5: derive output dims from the final surface; allocate the readback buffer
        // (readback path only — the GPU-target path needs no staging buffer). ----
        let finalSurface = try owner.surface(for: RenderSurface.sRGBSurface)
        let readbackPlan: MetalFrameReadback.Plan?
        switch finish {
        case .readback:
            let plan = try readback.makePlan(finalSurface: finalSurface)
            owner.retain(stagingBuffer: plan.stagingBuffer)
            readbackPlan = plan
        case .target:
            readbackPlan = nil
        }

        // ---- Step 6: one command buffer. ----
        let commandBuffer = try submitter.makeCommandBuffer()

        // ---- Step 7a: upload blits FIRST (private textures). ----
        if !stagedUploads.isEmpty {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw MetalRenderError.encodingFailed(detail: "upload blit encoder")
            }
            for staged in stagedUploads {
                blit.copy(
                    from: staged.stagingBuffer, sourceOffset: 0,
                    sourceBytesPerRow: staged.sourceBytesPerRow,
                    sourceBytesPerImage: staged.sourceBytesPerImage,
                    sourceSize: staged.size,
                    to: staged.destination, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            blit.endEncoding()
            onExecutionEvent?(.uploadBlit)
        }

        // ---- Step 7b: NORMALIZATION passes — after upload, before scenes (corrective §1/§10). ----
        for resourceID in pixelResourceOrder {
            guard let entry = owner.pixelResources[resourceID] else {
                throw MetalRenderError.missingResource(resourceID: resourceID)
            }
            // CP7.8: a dynamic texture input carries a non-zero quarter-turn the pass applies (raw →
            // display). Bytes inputs are quarter-turn 0 (byte-identical to the pre-CP7.8 pass).
            try normalizer.encodeNormalization(
                into: commandBuffer, raw: entry.raw, normalized: entry.normalized,
                quarterTurns: normalizeQuarterTurns[resourceID] ?? 0, resourceID: resourceID)
            onExecutionEvent?(.normalize(resourceID: resourceID))
        }

        // ---- Step 7c: render passes (clears, scenes, image draws, clip scissor, final conversion). ----
        let shapeCompositor = MetalShapeCompositor(device: device, pipelines: pipelines, allocator: allocator)
        let maskMatteCompositor = MetalMaskMatteCompositor(
            device: device, pipelines: pipelines, allocator: allocator, shapeCompositor: shapeCompositor)
        let transitionCompositor = MetalTransitionCompositor(device: device, pipelines: pipelines)
        try encodeRenderWork(graph, owner: owner, compositor: compositor,
                             shapeCompositor: shapeCompositor, maskMatteCompositor: maskMatteCompositor,
                             transitionCompositor: transitionCompositor,
                             into: commandBuffer)

        // ---- Step 7d: finalize — readback blit LAST (oracle path) OR GPU copy into the external target. ----
        switch finish {
        case .readback:
            guard let plan = readbackPlan else {
                throw MetalRenderError.readbackFailed(detail: "missing readback plan")
            }
            try readback.encodeBlit(into: commandBuffer, plan: plan)
            onExecutionEvent?(.readbackBlit)
        case let .target(target):
            // CP7.6a: GPU-only copy of the final sRGB surface into the caller's external texture.
            let copier = MetalExternalTargetCopy(pipelines: pipelines)
            try copier.encode(
                into: commandBuffer, source: finalSurface, target: target.texture,
                alphaMode: target.alphaMode)
            onExecutionEvent?(.externalCopy)
        }

        // ---- Step 8: commit + wait once. ----
        onExecutionEvent?(.commit)
        let completion = submitter.commitAndWait(commandBuffer)

        // ---- Step 9: map status; fail with no frame. ----
        switch completion {
        case .completed:
            onExecutionEvent?(.completion)
        case let .failed(status, detail):
            throw MetalRenderError.commandBufferFailed(status: status, detail: detail)
        }

        // ---- Step 10: read staging memory, repack tight, build the frame (readback path only). ----
        switch finish {
        case .readback:
            guard let plan = readbackPlan else {
                throw MetalRenderError.readbackFailed(detail: "missing readback plan")
            }
            return try readback.makeFrame(from: plan, colorContract: configuration.colorContract)
        case .target:
            // CP7.6a: the GPU write to the external target completed above; no RenderedFrame.
            return nil
        }
        // owner drops here (step 11): raw+normalized textures + staging buffers released after completion.
    }

    // MARK: - Preflight (plan §4.1 + corrective Issue 4)

    private func preflight(_ graph: RenderGraph, configuration: RenderConfiguration) throws {
        // 1. Independent graph validation (plan §1.3/§4.1).
        try RenderGraphValidator.validate(graph, configuration: configuration)
        // 2. framesInFlight == 1 (plan §8/§4.1).
        guard configuration.framesInFlight == 1 else {
            throw MetalRenderError.unsupportedFramesInFlight(value: configuration.framesInFlight)
        }
        // 3 + 4: reject Step-11/12 commands; verify resources/profiles/clear domain + surface geometry.
        // The geometry/command/resource checks are a pure package-internal function (`metalPreflight`) so a
        // test can drive the executor's own surface-dimension check directly and assert the exact typed
        // `surfaceDimensionMismatch`, independent of the structural validator (corrective Rev-4 pt.3 seam).
        try Self.metalPreflight(graph, configuration: configuration)
    }

    /// Package-internal Metal preflight seam (corrective Rev-4 pt.3): the executor's own resource/clear/
    /// deferred-command/surface-geometry checks, **without** the structural `RenderGraphValidator`. Pure
    /// (no device, no GPU object). Lets a test prove the exact `MetalRenderError.surfaceDimensionMismatch`
    /// (and the other executor-side typed errors) directly. NOT public API.
    static func metalPreflight(_ graph: RenderGraph, configuration: RenderConfiguration) throws {
        let canvasW = configuration.output.canvas.width
        let canvasH = configuration.output.canvas.height

        var declared: [String: RenderResourceDescriptor] = [:]
        for command in graph.commands {
            // Deferred-command rejection via the pure classifier (corrective §5a) — before any GPU work.
            if let (category, step) = MetalSceneCompositor.unsupportedCommand(for: command.payload) {
                throw MetalRenderError.unsupportedCommand(
                    category: category, step: step, reason: "category is Step \(step)")
            }
            switch command.payload {
            case .declareResource(let d):
                // CP7.8: a dynamic texture input carries NO bytes (the raw texture is bound at execution);
                // a bytes pixel input MUST carry its owned pixels. Either is a valid declared pixel resource.
                if d.kind == .dynamicTexturePixelInput {
                    guard d.pixels == nil, d.dynamicTextureSourceID == d.resourceID,
                          let q = d.dynamicOrientationQuarterTurns, (0...3).contains(q) else {
                        throw MetalRenderError.missingResource(resourceID: d.resourceID)
                    }
                } else {
                    guard d.pixels != nil else {
                        throw MetalRenderError.missingResource(resourceID: d.resourceID)
                    }
                }
                guard d.width > 0, d.height > 0 else {
                    throw MetalRenderError.invalidSurfaceDimensions(
                        resourceID: d.resourceID, width: d.width, height: d.height)
                }
                declared[d.resourceID] = d
            case .offscreenSurface(let d):
                // Positivity + exact integer conversion (throws on bad dims); format mapping validates
                // role↔storage (throws on mismatch). No GPU object created.
                let (pxW, pxH) = try MetalTextureAllocator.surfacePixelSize(d)
                _ = try MetalTextureAllocator.surfaceFormat(for: d)
                // Issue 4: linearCanvas and sRGBSurface must equal the configuration canvas (no resample).
                if d.resourceID == RenderSurface.linearCanvas || d.resourceID == RenderSurface.sRGBSurface {
                    guard Int64(pxW) == canvasW, Int64(pxH) == canvasH else {
                        throw MetalRenderError.surfaceDimensionMismatch(
                            resourceID: d.resourceID,
                            expectedWidth: canvasW, expectedHeight: canvasH,
                            actualWidth: Int64(pxW), actualHeight: Int64(pxH))
                    }
                }
                declared[d.resourceID] = d
            case let .clearBackground(color, _):
                guard color == PremultipliedColor.transparentBlack else {
                    throw MetalRenderError.unsupportedClearColor(
                        detail: "non-transparent-black clear is unsupported in Step 10")
                }
            case let .beginScene(_, _, target):
                // Issue 4: every Step-10 scene target must equal the canvas (fail closed otherwise).
                guard let d = declared[target], d.kind == .offscreen else {
                    throw MetalRenderError.missingResource(resourceID: target)
                }
                let (pxW, pxH) = try MetalTextureAllocator.surfacePixelSize(d)
                guard Int64(pxW) == canvasW, Int64(pxH) == canvasH else {
                    throw MetalRenderError.surfaceDimensionMismatch(
                        resourceID: target,
                        expectedWidth: canvasW, expectedHeight: canvasH,
                        actualWidth: Int64(pxW), actualHeight: Int64(pxH))
                }
            case let .drawImage(resourceID, _, _, _), let .drawVideoFrame(resourceID, _, _, _):
                // CP7.8: a draw may reference a bytes pixel input OR a dynamic texture-backed input.
                let k = declared[resourceID]?.kind
                guard k == .pixelInput || k == .dynamicTexturePixelInput else {
                    throw MetalRenderError.missingResource(resourceID: resourceID)
                }
            case .endScene, .beginClip, .endClip, .finalLinearToSRGB, .finalOutput,
                 .drawShape, .beginMask, .endMask, .matteLink:
                break
            case let .fadeTransition(_, outgoing, incoming, target),
                 let .slideTransition(_, _, _, _, outgoing, incoming, target),
                 let .pushTransition(_, _, _, _, _, _, outgoing, incoming, target),
                 let .dipTransition(_, _, outgoing, incoming, target):
                // Step-12 / CP5.5: the two scene surfaces and the target must be declared offscreens.
                guard declared[outgoing]?.kind == .offscreen else { throw MetalRenderError.missingResource(resourceID: outgoing) }
                guard declared[incoming]?.kind == .offscreen else { throw MetalRenderError.missingResource(resourceID: incoming) }
                guard declared[target]?.kind == .offscreen else { throw MetalRenderError.missingResource(resourceID: target) }
            case let .overlay(resourceID, _, _, _, target):
                guard declared[resourceID]?.kind == .pixelInput else { throw MetalRenderError.missingResource(resourceID: resourceID) }
                guard declared[target]?.kind == .offscreen else { throw MetalRenderError.missingResource(resourceID: target) }
            }
        }
    }

    // MARK: - Render-work encoding (plan §7, §8.6 step 7c)

    private final class RenderState {
        var encoder: MTLRenderCommandEncoder?
        var targetSurfaceID: String?
        var targetTexture: MTLTexture?
        var targetWidth: Int = 0
        var targetHeight: Int = 0
        var clipStack: [MetalSceneCompositor.ScissorBounds] = []
        /// Whether at least one draw was encoded into a scene (for the sceneRender event, emitted once).
        var sceneRenderEmitted = false
        /// Open mask groups (Rev-4 §2.8): resolved inner-first at the matching endMask.
        struct MaskGroup { let operations: [SampledMaskOperation]; let content: String; let target: String }
        var maskGroups: [MaskGroup] = []
    }

    private func encodeRenderWork(
        _ graph: RenderGraph,
        owner: MetalResourceOwner,
        compositor: MetalColorConverter,
        shapeCompositor: MetalShapeCompositor,
        maskMatteCompositor: MetalMaskMatteCompositor,
        transitionCompositor: MetalTransitionCompositor,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        let state = RenderState()

        func applyScissor(_ encoder: MTLRenderCommandEncoder) {
            guard let top = state.clipStack.last else {
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: state.targetWidth, height: state.targetHeight))
                return
            }
            encoder.setScissorRect(MTLScissorRect(x: top.x, y: top.y, width: top.width, height: top.height))
        }

        func clearSurface(_ id: String) throws {
            try endEncoderIfOpen(state)
            let texture = try owner.surface(for: id)
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = texture
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rp.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
                throw MetalRenderError.encodingFailed(detail: "clear render encoder for \(id)")
            }
            encoder.endEncoding()
        }

        func openSceneEncoder(target id: String) throws {
            try endEncoderIfOpen(state)
            let texture = try owner.surface(for: id)
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = texture
            rp.colorAttachments[0].loadAction = .load
            rp.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
                throw MetalRenderError.encodingFailed(detail: "scene render encoder for \(id)")
            }
            state.encoder = encoder
            state.targetSurfaceID = id
            state.targetTexture = texture
            state.targetWidth = texture.width
            state.targetHeight = texture.height
        }

        // Ensure an open load/store render encoder targets `id` (re-targeting if a different surface — e.g.
        // an isolation surface — is the destination of an image/shape draw inside a scene scope).
        func ensureEncoder(target id: String) throws {
            if state.targetSurfaceID == id, state.encoder != nil { return }
            try openSceneEncoder(target: id)
        }

        for (commandIndex, command) in graph.commands.enumerated() {
            switch command.payload {
            case .declareResource, .offscreenSurface:
                break

            case let .clearBackground(_, target):
                try clearSurface(target)

            case let .beginScene(_, _, target):
                try openSceneEncoder(target: target)

            case .endScene:
                try endEncoderIfOpen(state)

            case let .drawImage(resourceID, transform, opacity, target),
                 let .drawVideoFrame(resourceID, transform, opacity, target):
                try ensureEncoder(target: target)
                try encodeImageDraw(
                    resourceID: resourceID, transform: transform, opacity: opacity, target: target,
                    state: state, owner: owner, applyScissor: applyScissor)

            case let .drawShape(shape, transform, opacity, target):
                // Coverage/apply passes manage their own encoders; end the open one first.
                try endEncoderIfOpen(state)
                try encodeShapeDraw(shape: shape, transform: transform, opacity: opacity, target: target,
                                    owner: owner, shapeCompositor: shapeCompositor, into: commandBuffer)
                if !state.sceneRenderEmitted { state.sceneRenderEmitted = true; onExecutionEvent?(.sceneRender) }

            case let .beginMask(operations, contentSurfaceID, targetSurfaceID):
                try endEncoderIfOpen(state)
                // The inner content draws into the content surface; defer the apply until endMask. Push the
                // group onto a stack so nested groups resolve inner-first.
                state.maskGroups.append(RenderState.MaskGroup(operations: operations, content: contentSurfaceID, target: targetSurfaceID))

            case let .endMask(contentSurfaceID, targetSurfaceID):
                try endEncoderIfOpen(state)
                guard let group = state.maskGroups.last,
                      group.content == contentSurfaceID, group.target == targetSurfaceID else {
                    throw MetalRenderError.encodingFailed(detail: "endMask mismatch \(contentSurfaceID)→\(targetSurfaceID)")
                }
                state.maskGroups.removeLast()
                let content = try owner.surface(for: contentSurfaceID)
                let target = try owner.surface(for: targetSurfaceID)
                try maskMatteCompositor.encodeMask(
                    operations: group.operations, contentSurface: content, target: target,
                    label: "mask\u{1F}\(contentSurfaceID)", owner: owner, into: commandBuffer)

            case let .matteLink(mode, _, _, sourceSurfaceID, consumerSurfaceID, targetSurfaceID):
                try endEncoderIfOpen(state)
                let source = try owner.surface(for: sourceSurfaceID)
                let consumer = try owner.surface(for: consumerSurfaceID)
                let target = try owner.surface(for: targetSurfaceID)
                try maskMatteCompositor.encodeMatte(
                    mode: mode, source: source, consumer: consumer, target: target, into: commandBuffer)

            case let .beginClip(rect):
                try pushClip(rect, state: state)

            case .endClip:
                if !state.clipStack.isEmpty { state.clipStack.removeLast() }

            case let .finalLinearToSRGB(source, target):
                try endEncoderIfOpen(state)
                let src = try owner.surface(for: source)
                let dst = try owner.surface(for: target)
                try compositor.encode(into: commandBuffer, source: src, target: dst)
                onExecutionEvent?(.finalConversion)

            case .finalOutput:
                try endEncoderIfOpen(state)

            case let .fadeTransition(easedProgress, outgoing, incoming, target):
                // Step-12 fade: self-contained `.replace` full-surface pass; end the open encoder first.
                try endEncoderIfOpen(state)
                try transitionCompositor.encodeFade(
                    outgoing: try owner.surface(for: outgoing), incoming: try owner.surface(for: incoming),
                    target: try owner.surface(for: target), easedProgress: easedProgress, into: commandBuffer)
                if !state.sceneRenderEmitted { state.sceneRenderEmitted = true; onExecutionEvent?(.sceneRender) }

            case let .slideTransition(_, _, offsetX, offsetY, outgoing, incoming, target):
                try endEncoderIfOpen(state)
                try transitionCompositor.encodeSlide(
                    outgoing: try owner.surface(for: outgoing), incoming: try owner.surface(for: incoming),
                    target: try owner.surface(for: target), offsetX: offsetX, offsetY: offsetY, into: commandBuffer)
                if !state.sceneRenderEmitted { state.sceneRenderEmitted = true; onExecutionEvent?(.sceneRender) }

            case let .pushTransition(_, _, outX, outY, inX, inY, outgoing, incoming, target):
                // CP5.5 push: self-contained `.replace` full-surface pass; both scenes shifted.
                try endEncoderIfOpen(state)
                try transitionCompositor.encodePush(
                    outgoing: try owner.surface(for: outgoing), incoming: try owner.surface(for: incoming),
                    target: try owner.surface(for: target),
                    outgoingOffsetX: outX, outgoingOffsetY: outY, incomingOffsetX: inX, incomingOffsetY: inY,
                    into: commandBuffer)
                if !state.sceneRenderEmitted { state.sceneRenderEmitted = true; onExecutionEvent?(.sceneRender) }

            case let .dipTransition(dipColor, easedProgress, outgoing, incoming, target):
                // CP5.5 dip: self-contained `.replace` full-surface pass through the solid dip colour.
                try endEncoderIfOpen(state)
                try transitionCompositor.encodeDip(
                    outgoing: try owner.surface(for: outgoing), incoming: try owner.surface(for: incoming),
                    target: try owner.surface(for: target), dipColor: dipColor, easedProgress: easedProgress,
                    into: commandBuffer)
                if !state.sceneRenderEmitted { state.sceneRenderEmitted = true; onExecutionEvent?(.sceneRender) }

            case let .overlay(resourceID, transform, opacity, _, target):
                // Step-12 overlay: composite the pre-resolved (normalized) overlay pixels above the body
                // via the existing image-draw path, in graph (composition) order, into the target.
                try ensureEncoder(target: target)
                try encodeImageDraw(
                    resourceID: resourceID, transform: transform, opacity: opacity, target: target,
                    state: state, owner: owner, applyScissor: applyScissor)
            }

            // Diagnostic seam (inert in production): flush any open scene encoder so the captured surface
            // reflects all draws encoded so far, then hand the test this command + owner + buffer to blit.
            if let capture = onCommandEncoded {
                try endEncoderIfOpen(state)
                capture(commandIndex, command.payload, owner, commandBuffer)
            }
        }
        try endEncoderIfOpen(state)
    }

    private func encodeShapeDraw(
        shape: SampledShape, transform: FixedAffineTransform2D, opacity: OpacityScalar, target: String,
        owner: MetalResourceOwner, shapeCompositor: MetalShapeCompositor, into commandBuffer: MTLCommandBuffer
    ) throws {
        let targetTexture = try owner.surface(for: target)
        // Effective alpha folds fillOpacity/groupOpacity/drawShape.opacity (color.alpha is applied in-shader).
        let fillAlpha = try foldOpacities([shape.fillOpacity, shape.groupOpacity, opacity], field: "shape.fillAlpha")
        // Fill first, then stroke (authored order).
        if let mesh = shape.fillMesh, let color = shape.fillColor {
            try shapeCompositor.encode(
                positions: mesh.positions.map { $0.rawValue }, indices: mesh.indices, transform: transform,
                color: color, effectiveAlpha: fillAlpha, target: targetTexture, label: "fill\u{1F}\(target)",
                owner: owner, into: commandBuffer)
        }
        if let stroke = shape.stroke {
            let strokeAlpha = try foldOpacities([stroke.opacity, shape.groupOpacity, opacity], field: "shape.strokeAlpha")
            try shapeCompositor.encode(
                positions: stroke.mesh.positions.map { $0.rawValue }, indices: stroke.mesh.indices, transform: transform,
                color: stroke.color, effectiveAlpha: strokeAlpha, target: targetTexture, label: "stroke\u{1F}\(target)",
                owner: owner, into: commandBuffer)
        }
    }

    /// Product of opacities in the checked fixed-point opacity contract (1_000_000 == 1.0).
    private func foldOpacities(_ values: [OpacityScalar], field: String) throws -> OpacityScalar {
        var raw = OpacityScalar.opaque.rawValue
        for v in values {
            raw = try FixedPointMath.multiplyDivideRounding(raw, v.rawValue, OpacityScalar.unitsPerUnit, field)
        }
        return try OpacityScalar(rawValue: min(max(raw, 0), OpacityScalar.unitsPerUnit))
    }

    private func encodeImageDraw(
        resourceID: String,
        transform: FixedAffineTransform2D,
        opacity: OpacityScalar,
        target: String,
        state: RenderState,
        owner: MetalResourceOwner,
        applyScissor: (MTLRenderCommandEncoder) -> Void
    ) throws {
        guard let encoder = state.encoder, state.targetSurfaceID == target,
              let targetTexture = state.targetTexture else {
            throw MetalRenderError.missingResource(resourceID: "open scene target \(target)")
        }
        // Empty clip ⇒ skip the enclosed draw entirely (plan §7.5, Rev-4 #5) — no zero-sized scissor.
        if let top = state.clipStack.last, top.isEmpty {
            return
        }
        // Corrective §1.4: scene draws sample the NORMALIZED texture only (never the raw upload texture).
        let normalizedTexture = try owner.normalizedTexture(for: resourceID)
        let quad = try MetalSceneCompositor.imageQuad(
            sourceWidthPx: normalizedTexture.width, sourceHeightPx: normalizedTexture.height,
            transform: transform,
            surfaceWidthPx: state.targetWidth, surfaceHeightPx: state.targetHeight)

        var vertexData: [Float] = []
        vertexData.reserveCapacity(quad.count * 4)
        for v in quad { vertexData.append(contentsOf: [v.ndcX, v.ndcY, v.u, v.v]) }
        var opacityF = Float(opacity.rawValue) / Float(OpacityScalar.unitsPerUnit)

        // Corrective Issue 2g: resolve the render-target format EXPLICITLY from the open target texture —
        // no `try?`, no default. (The target is the open scene texture, already resolved above.)
        let format = targetTexture.pixelFormat

        applyScissor(encoder)
        encoder.setRenderPipelineState(try pipelines.imagePipeline(for: format))
        try vertexData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw MetalRenderError.encodingFailed(detail: "empty vertex data for \(resourceID)")
            }
            encoder.setVertexBytes(base, length: raw.count, index: 0)
        }
        encoder.setFragmentTexture(normalizedTexture, index: 0)
        encoder.setFragmentSamplerState(pipelines.sampler(), index: 0)
        encoder.setFragmentBytes(&opacityF, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad.count)
        if !state.sceneRenderEmitted {
            state.sceneRenderEmitted = true
            onExecutionEvent?(.sceneRender)
        }
    }

    private func pushClip(_ rect: FixedRect, state: RenderState) throws {
        let single = try MetalSceneCompositor.scissor(
            for: rect, surfaceWidth: state.targetWidth, surfaceHeight: state.targetHeight)
        let combined: MetalSceneCompositor.ScissorBounds
        if let top = state.clipStack.last {
            combined = try MetalSceneCompositor.intersect(top, single)
        } else {
            combined = single
        }
        state.clipStack.append(combined)
    }

    private func endEncoderIfOpen(_ state: RenderState) throws {
        if let encoder = state.encoder {
            encoder.endEncoding()
            state.encoder = nil
            state.targetSurfaceID = nil
            state.targetTexture = nil
        }
    }
}

/// Corrective §7b — package-internal execution-event observer. The executor calls `onExecutionEvent?(…)` at
/// each milestone; inert (no-op) when the closure is nil, so production behaviour is unchanged.
enum ExecutionEvent: Equatable {
    case uploadBlit
    case normalize(resourceID: String)
    case sceneRender
    case finalConversion
    case readbackBlit
    /// CP7.6a — the GPU-only copy of the final sRGB surface into an external target (render(into:) path).
    case externalCopy
    case commit
    case completion
}
