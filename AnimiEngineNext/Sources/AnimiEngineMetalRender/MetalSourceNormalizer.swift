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

    /// CP7.8 — the per-pass orientation parameters the normalize fragment uses to map a DISPLAY
    /// (normalized) texel back to the RAW source texel. Layout MUST match `NormalizeParams` in the shader.
    /// For `quarterTurns == 0` (every bytes input, and an identity-orientation video) the mapping is the
    /// identity `src == dst`, byte-identical to the pre-CP7.8 pass.
    struct NormalizeParams {
        var quarterTurns: UInt32   // 0/1/2/3 clockwise (raw → display)
        var rawWidth: UInt32
        var rawHeight: UInt32
        var pad: UInt32 = 0
    }

    /// Encode one normalization pass: `raw` (read by integer coord) → `normalized` (rgba16Float).
    /// `quarterTurns` rotates the raw source by N clockwise quarter-turns into the display-oriented
    /// `normalized` texture (CP7.8); 0 means a direct 1:1 texel copy (the existing bytes behaviour).
    func encodeNormalization(
        into commandBuffer: MTLCommandBuffer,
        raw: MTLTexture,
        normalized: MTLTexture,
        quarterTurns: Int = 0,
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
        var params = NormalizeParams(
            quarterTurns: UInt32(((quarterTurns % 4) + 4) % 4),
            rawWidth: UInt32(raw.width), rawHeight: UInt32(raw.height))
        encoder.setFragmentBytes(&params, length: MemoryLayout<NormalizeParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
