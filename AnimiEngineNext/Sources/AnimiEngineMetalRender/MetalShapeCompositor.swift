import Metal
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 / Step-11 (Rev-4 §3.1/§7.3/§7.4) — Metal fill + stroke execution.
///
/// A fill or stroke is rasterized from its execution-ready triangle mesh into a 4x-MSAA `r16Float`
/// coverage target (constant 1.0, blending disabled), resolved to a single-sample `r16Float` texture
/// (exact resolve fractions 0/0.25/0.5/0.75/1.0), then a full-surface apply pass converts the authored
/// straight-sRGB colour to linear, premultiplies by `effectiveAlpha × coverage`, and source-over
/// composites once into the open target. Metal constructs **no** geometry — the mesh comes from the graph.
struct MetalShapeCompositor {
    let device: MTLDevice
    let pipelines: MetalPipelineLibrary
    let allocator: MetalTextureAllocator

    /// Parameters matching the shader `ShapeApplyParams` (4 floats).
    private struct ShapeApplyParams {
        var r: Float; var g: Float; var b: Float; var alpha: Float
    }

    /// Encode a fill OR stroke: rasterize `mesh` (positions+indices) transformed by `transform` into
    /// coverage, resolve, and apply `color` at `effectiveAlpha` into `target`. The transient coverage
    /// textures are retained by `owner` until completion.
    func encode(
        positions: [Int64], indices: [Int],
        transform: FixedAffineTransform2D,
        color: SampledSRGBAColor, effectiveAlpha: OpacityScalar,
        target: MTLTexture, label: String,
        owner: MetalResourceOwner,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        let w = target.width, h = target.height
        let ndc = try MetalSceneCompositor.coverageNDC(
            positions: positions, indices: indices, transform: transform,
            surfaceWidthPx: w, surfaceHeightPx: h)
        guard !ndc.isEmpty else { return }   // nothing to rasterize

        let resolved = try rasterizeCoverage(ndc: ndc, width: w, height: h, label: label, owner: owner, into: commandBuffer)

        // Apply pass: full-surface, source-over into the open target.
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
            throw MetalRenderError.encodingFailed(detail: "shape apply encoder for \(label)")
        }
        encoder.setRenderPipelineState(try pipelines.shapeApplyPipeline(for: target.pixelFormat))
        var params = ShapeApplyParams(
            r: Float(color.red.rawValue) / Float(NormalizedColorComponent.unitsPerUnit),
            g: Float(color.green.rawValue) / Float(NormalizedColorComponent.unitsPerUnit),
            b: Float(color.blue.rawValue) / Float(NormalizedColorComponent.unitsPerUnit),
            alpha: effectiveAlphaFloat(color: color, effectiveAlpha: effectiveAlpha))
        encoder.setFragmentTexture(resolved, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<ShapeApplyParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)   // full-surface triangle
        encoder.endEncoding()
    }

    /// The effective style alpha (Rev-4 §2.6): `color.alpha × effectiveAlpha` (the caller has already
    /// folded fillOpacity/styleOpacity/groupOpacity/drawShape.opacity into `effectiveAlpha`).
    private func effectiveAlphaFloat(color: SampledSRGBAColor, effectiveAlpha: OpacityScalar) -> Float {
        let ca = Float(color.alpha.rawValue) / Float(NormalizedColorComponent.unitsPerUnit)
        let ea = Float(effectiveAlpha.rawValue) / Float(OpacityScalar.unitsPerUnit)
        return ca * ea
    }

    /// Rasterize a flat NDC triangle list into a 4x-MSAA coverage target and resolve to a single-sample
    /// `r16Float` texture. Returns the resolved texture (retained by `owner`).
    func rasterizeCoverage(
        ndc: [Float], width: Int, height: Int, label: String,
        owner: MetalResourceOwner, into commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let msaa = try allocator.makeMSAACoverageTexture(width: width, height: height, resourceID: "\(label).msaa")
        let resolved = try allocator.makeCoverageResolveTexture(width: width, height: height, resourceID: "\(label).resolved")
        owner.retainTransient(msaa)
        owner.retainTransient(resolved)

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = msaa
        rp.colorAttachments[0].resolveTexture = resolved
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .multisampleResolve
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else {
            throw MetalRenderError.encodingFailed(detail: "coverage encoder for \(label)")
        }
        encoder.setRenderPipelineState(try pipelines.coveragePipeline())
        try ndc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw MetalRenderError.encodingFailed(detail: "empty coverage vertices for \(label)")
            }
            encoder.setVertexBytes(base, length: raw.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: ndc.count / 2)
        encoder.endEncoding()
        return resolved
    }
}
