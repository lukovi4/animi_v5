import Metal

/// Task-003 plan §5.3 — encodes the final linear→sRGB conversion full-surface `.replace` pass.
///
/// Reads the linear-canvas surface (linear premultiplied) and writes the sRGB output surface
/// (`.bgra8Unorm`); the encode + explicit quantization happen in `final_srgb_fragment` (plan §5.3). This
/// pass writes, never blends, and never reads the surface it writes.
struct MetalColorConverter {
    let pipelines: MetalPipelineLibrary

    /// Encode the conversion into `commandBuffer`: source = linear canvas texture, target = sRGB texture.
    func encode(
        into commandBuffer: MTLCommandBuffer,
        source linearCanvas: MTLTexture,
        target sRGBSurface: MTLTexture
    ) throws {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = sRGBSurface
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
            throw MetalRenderError.pipelineCreationFailed(detail: "final conversion render encoder")
        }
        encoder.setRenderPipelineState(try pipelines.finalPipeline())
        encoder.setFragmentTexture(linearCanvas, index: 0)
        encoder.setFragmentSamplerState(pipelines.sampler(), index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
