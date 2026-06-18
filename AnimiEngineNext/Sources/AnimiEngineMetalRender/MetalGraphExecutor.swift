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

    func execute(_ graph: RenderGraph) throws -> RenderedFrame {
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

        // ---- Step 3: allocate raw+normalized pixel textures; prepare host data / staging buffers. ----
        var stagedUploads: [MetalResourceUploader.StagedUpload] = []
        // The pixel resources in declaration order, for the normalization passes (step 7b).
        var pixelResourceOrder: [String] = []
        // ---- Step 4: allocate offscreen + final textures. ----
        for command in graph.commands {
            switch command.payload {
            case .declareResource(let descriptor):
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

        // ---- Step 5: derive output dims from the final surface; allocate the readback buffer. ----
        let finalSurface = try owner.surface(for: RenderSurface.sRGBSurface)
        let readbackPlan = try readback.makePlan(finalSurface: finalSurface)
        owner.retain(stagingBuffer: readbackPlan.stagingBuffer)

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
            try normalizer.encodeNormalization(
                into: commandBuffer, raw: entry.raw, normalized: entry.normalized, resourceID: resourceID)
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

        // ---- Step 7d: readback blit LAST. ----
        try readback.encodeBlit(into: commandBuffer, plan: readbackPlan)
        onExecutionEvent?(.readbackBlit)

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

        // ---- Step 10: read staging memory, repack tight, build the frame. ----
        return try readback.makeFrame(from: readbackPlan, colorContract: configuration.colorContract)
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
                guard d.pixels != nil else {
                    throw MetalRenderError.missingResource(resourceID: d.resourceID)
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
                guard declared[resourceID]?.kind == .pixelInput else {
                    throw MetalRenderError.missingResource(resourceID: resourceID)
                }
            case .endScene, .beginClip, .endClip, .finalLinearToSRGB, .finalOutput,
                 .drawShape, .beginMask, .endMask, .matteLink:
                break
            case let .fadeTransition(_, outgoing, incoming, target),
                 let .slideTransition(_, _, _, _, outgoing, incoming, target):
                // Step-12: the two scene surfaces and the target must be declared offscreens.
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

        for command in graph.commands {
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

            case let .overlay(resourceID, transform, opacity, _, target):
                // Step-12 overlay: composite the pre-resolved (normalized) overlay pixels above the body
                // via the existing image-draw path, in graph (composition) order, into the target.
                try ensureEncoder(target: target)
                try encodeImageDraw(
                    resourceID: resourceID, transform: transform, opacity: opacity, target: target,
                    state: state, owner: owner, applyScissor: applyScissor)
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
    case commit
    case completion
}
