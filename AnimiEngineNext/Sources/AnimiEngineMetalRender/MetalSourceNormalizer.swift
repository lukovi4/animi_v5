import Metal

/// Corrective §1.2/§1.2a/§1.6 — encodes the one-time per-resource source normalization render pass.
///
/// Reads the raw `.bgra8Unorm` premultiplied-sRGB texture by **exact integer coordinate** (no sampler/UV)
/// and writes the `rgba16Float` **linear-premultiplied** normalized texture. Sets the viewport to the full
/// `normalized` size (§1.2a inv. 2) so the full-surface triangle runs the fragment once per destination
/// texel, with `in.position.xy == (x+0.5, y+0.5)` → exact `uint2(x, y)`. The executor pins the equal-dims
/// invariant (§1.2a inv. 1) before calling this.
struct MetalSourceNormalizer {
    let pipelines: MetalPipelineLibrary

    /// Encode one normalization pass: `raw` (read by integer coord) → `normalized` (rgba16Float).
    func encodeNormalization(
        into commandBuffer: MTLCommandBuffer,
        raw: MTLTexture,
        normalized: MTLTexture,
        resourceID: String
    ) throws {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = normalized
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
            throw MetalRenderError.encodingFailed(detail: "normalization render encoder for \(resourceID)")
        }
        // §1.2a inv. 2: viewport = full normalized size, so pixel-centers truncate to exact texel indices.
        encoder.setViewport(MTLViewport(
            originX: 0, originY: 0,
            width: Double(normalized.width), height: Double(normalized.height),
            znear: 0, zfar: 1))
        encoder.setRenderPipelineState(try pipelines.normalizePipeline())
        encoder.setFragmentTexture(raw, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
