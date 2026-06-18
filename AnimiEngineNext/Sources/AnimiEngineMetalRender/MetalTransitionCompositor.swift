import Metal
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 / Step-12 (Rev-1 §3.2/§3.3, R1/R2/R3) — Metal fade + slide transition execution.
///
/// Both are SINGLE full-surface `.replace` passes (R1): the fragment reads the two already-rendered scene
/// surfaces (linear-premultiplied) and emits the final composited value, so the target is exclusively
/// owned by this pass (no double-counting). Fade is a premultiplied cross-dissolve at the graph's eased
/// progress; slide composites the incoming surface — shifted by the graph's exact canvas-raw offset —
/// source-over a stationary (still-animating) outgoing surface (R2). The slide offset is converted from
/// canvas-raw to normalized UV in exact fixed point, with `Float` only at the shader boundary.
struct MetalTransitionCompositor {
    let device: MTLDevice
    let pipelines: MetalPipelineLibrary

    /// Encode a fade into `target`: `mix(outgoing, incoming, progress)` on premultiplied RGBA.
    func encodeFade(
        outgoing: MTLTexture, incoming: MTLTexture, target: MTLTexture, easedProgress: UnitInterval,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        let encoder = try beginReplacePass(target: target, label: "fade", into: commandBuffer)
        encoder.setRenderPipelineState(try pipelines.fadePipeline(for: target.pixelFormat))
        encoder.setFragmentTexture(outgoing, index: 0)
        encoder.setFragmentSamplerState(pipelines.sampler(), index: 0)
        encoder.setFragmentTexture(incoming, index: 1)
        var progress = Float(easedProgress.rawValue) / Float(UnitInterval.unitsPerUnit)
        encoder.setFragmentBytes(&progress, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Encode a slide into `target`: shifted `incoming` source-over stationary `outgoing`. `offsetX`/
    /// `offsetY` are the graph's canvas-raw offsets (already eased); they are converted to a normalized UV
    /// shift using the target's pixel size, in exact fixed point.
    func encodeSlide(
        outgoing: MTLTexture, incoming: MTLTexture, target: MTLTexture,
        offsetX: Int64, offsetY: Int64, into commandBuffer: MTLCommandBuffer
    ) throws {
        // UV shift = offset(canvas-raw) / (unitsPerPoint · sizePx). The fragment samples
        // `incoming.sample(uv - offsetUV)`, so a positive canvas offset moves the incoming content in the
        // positive direction (its UV is read from a smaller coordinate). `Float` only at this boundary.
        let widthPx = Int64(target.width)
        let heightPx = Int64(target.height)
        guard widthPx > 0, heightPx > 0 else {
            throw MetalRenderError.invalidSurfaceDimensions(resourceID: "slide.target", width: widthPx, height: heightPx)
        }
        let denomX = try CheckedInt64.multiply(CanvasScalar.unitsPerPoint, widthPx, "slide.denomX")
        let denomY = try CheckedInt64.multiply(CanvasScalar.unitsPerPoint, heightPx, "slide.denomY")
        var offsetUV = SIMD2<Float>(Float(offsetX) / Float(denomX), Float(offsetY) / Float(denomY))

        let encoder = try beginReplacePass(target: target, label: "slide", into: commandBuffer)
        encoder.setRenderPipelineState(try pipelines.slidePipeline(for: target.pixelFormat))
        encoder.setFragmentTexture(outgoing, index: 0)
        encoder.setFragmentSamplerState(pipelines.sampler(), index: 0)
        encoder.setFragmentTexture(incoming, index: 1)
        encoder.setFragmentBytes(&offsetUV, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// A full-surface `.clear`/`.store` render pass into `target`; the fragment emits the final value, so
    /// blending stays disabled in the PSO (R1).
    private func beginReplacePass(target: MTLTexture, label: String, into commandBuffer: MTLCommandBuffer) throws -> MTLRenderCommandEncoder {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
            throw MetalRenderError.encodingFailed(detail: "\(label) transition encoder")
        }
        return encoder
    }
}
