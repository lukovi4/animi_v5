import Metal

/// CP7.6a — encodes the GPU-only copy of the final sRGB surface into an external caller-supplied
/// `.bgra8Unorm` texture (the `GPURenderTarget`), replacing the CPU readback path for export.
///
/// A full-surface `.replace` render pass samples the already-final sRGB output surface and writes it
/// into the external target. `preserveAlpha` is a straight passthrough (byte-identical to the source
/// surface, hence to what the readback would produce). `opaqueBlack` forces alpha = 1.0 in-shader while
/// keeping the premultiplied B/G/R — the GPU equivalent of the export CPU `compositeOpaque`.
///
/// This never reads the texture it writes, and the source surface is a distinct private texture.
struct MetalExternalTargetCopy {
    let pipelines: MetalPipelineLibrary

    /// Encode the copy into `commandBuffer`: source = final sRGB surface, target = external texture.
    func encode(
        into commandBuffer: MTLCommandBuffer,
        source sRGBSurface: MTLTexture,
        target: MTLTexture,
        alphaMode: AlphaMode
    ) throws {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
            throw MetalRenderError.encodingFailed(detail: "external-target copy render encoder")
        }
        encoder.setRenderPipelineState(try pipelines.externalCopyPipeline())
        encoder.setFragmentTexture(sRGBSurface, index: 0)
        encoder.setFragmentSamplerState(pipelines.sampler(), index: 0)
        var forceOpaque: UInt32 = (alphaMode == .opaqueBlack) ? 1 : 0
        encoder.setFragmentBytes(&forceOpaque, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
