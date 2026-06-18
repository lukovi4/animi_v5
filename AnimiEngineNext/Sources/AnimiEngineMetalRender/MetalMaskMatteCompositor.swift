import Metal
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 / Step-11 (Rev-4 §7.5/§7.6) — Metal mask-group and matte execution.
///
/// **Mask group:** the layer content is already isolated in `contentSurface`. Each authored operation's
/// producer mesh is rasterized into 4x-MSAA coverage, resolved, and combined into a running accumulator
/// via two ping-pong `r16Float` textures (exact TVECore oracle: init add→0/sub→1/int→1; add=max,
/// subtract=acc·(1−cov), intersect=min; order clamp→invert→opacity→mode). The aggregate coverage then
/// modulates the content's premultiplied rgb AND alpha, source-over into `target`.
///
/// **Matte:** the fully-rendered `source` and `consumer` surfaces are read; coverage is the source alpha
/// or Rec.709 linear luma (no unpremultiply), modulating the consumer premultiplied rgb+alpha, source-over
/// into `target`.
struct MetalMaskMatteCompositor {
    let device: MTLDevice
    let pipelines: MetalPipelineLibrary
    let allocator: MetalTextureAllocator
    let shapeCompositor: MetalShapeCompositor

    private struct MaskCombineParams {
        var mode: Int32; var inverted: Int32; var opacity: Float; var isFirst: Int32
    }
    private struct MatteParams { var mode: Int32 }

    // MARK: - Mask group

    func encodeMask(
        operations: [SampledMaskOperation],
        contentSurface: MTLTexture, target: MTLTexture, label: String,
        owner: MetalResourceOwner, into commandBuffer: MTLCommandBuffer
    ) throws {
        let w = target.width, h = target.height
        // Two ping-pong accumulators.
        let accumA = try allocator.makeCoverageResolveTexture(width: w, height: h, resourceID: "\(label).accumA")
        let accumB = try allocator.makeCoverageResolveTexture(width: w, height: h, resourceID: "\(label).accumB")
        owner.retainTransient(accumA)
        owner.retainTransient(accumB)

        var readAccum = accumA
        var writeAccum = accumB
        for (i, op) in operations.enumerated() {
            // Rasterize this operation's coverage (its own mesh through pathToTarget).
            let ndc = try MetalSceneCompositor.coverageNDC(
                positions: op.mesh.positions.map { $0.rawValue }, indices: op.mesh.indices,
                transform: op.pathToTarget, surfaceWidthPx: w, surfaceHeightPx: h)
            let coverage = ndc.isEmpty
                ? try emptyCoverage(width: w, height: h, label: "\(label).op\(i).empty", owner: owner, into: commandBuffer)
                : try shapeCompositor.rasterizeCoverage(ndc: ndc, width: w, height: h, label: "\(label).op\(i)", owner: owner, into: commandBuffer)

            // Combine into writeAccum, reading readAccum (ignored for the first op).
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = writeAccum
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
                throw MetalRenderError.encodingFailed(detail: "mask combine encoder \(label).op\(i)")
            }
            encoder.setRenderPipelineState(try pipelines.maskCombinePipeline())
            var params = MaskCombineParams(
                mode: Int32(modeCode(op.mode)),
                inverted: op.inverted ? 1 : 0,
                opacity: Float(op.opacity.rawValue) / Float(OpacityScalar.unitsPerUnit),
                isFirst: i == 0 ? 1 : 0)
            encoder.setFragmentTexture(coverage, index: 0)
            encoder.setFragmentTexture(readAccum, index: 1)
            encoder.setFragmentBytes(&params, length: MemoryLayout<MaskCombineParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            swap(&readAccum, &writeAccum)
        }
        // After the loop, the aggregate coverage is in `readAccum` (last write became read after the swap).
        let aggregate = readAccum

        // Apply: content × aggregate coverage, source-over into target.
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
            throw MetalRenderError.encodingFailed(detail: "mask apply encoder \(label)")
        }
        encoder.setRenderPipelineState(try pipelines.maskApplyPipeline(for: target.pixelFormat))
        encoder.setFragmentTexture(contentSurface, index: 0)
        encoder.setFragmentSamplerState(pipelines.sampler(), index: 0)
        encoder.setFragmentTexture(aggregate, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// A resolved coverage texture cleared to 0 (an empty/degenerate operation mesh contributes nothing).
    private func emptyCoverage(
        width: Int, height: Int, label: String, owner: MetalResourceOwner, into commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let tex = try allocator.makeCoverageResolveTexture(width: width, height: height, resourceID: label)
        owner.retainTransient(tex)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
            throw MetalRenderError.encodingFailed(detail: "empty coverage clear \(label)")
        }
        encoder.endEncoding()
        return tex
    }

    private func modeCode(_ mode: RenderMaskMode) -> Int {
        switch mode {
        case .add: return 0
        case .subtract: return 1
        case .intersect: return 2
        }
    }

    // MARK: - Matte

    func encodeMatte(
        mode: RenderMatteMode, source: MTLTexture, consumer: MTLTexture, target: MTLTexture,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
            throw MetalRenderError.encodingFailed(detail: "matte apply encoder")
        }
        encoder.setRenderPipelineState(try pipelines.matteApplyPipeline(for: target.pixelFormat))
        encoder.setFragmentTexture(consumer, index: 0)
        encoder.setFragmentSamplerState(pipelines.sampler(), index: 0)
        encoder.setFragmentTexture(source, index: 1)
        var params = MatteParams(mode: Int32(mode.rawValue))
        encoder.setFragmentBytes(&params, length: MemoryLayout<MatteParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
