import Metal
import simd

// MARK: - GPU Mask Helper Functions

extension MetalRenderer {

    // MARK: - Texture Clearing

    /// Clears an R8Unorm texture to a uniform value using render pass clear.
    ///
    /// Per task.md: R8 clear via render pass (loadAction = .clear, clearColor = (v,v,v,v))
    ///
    /// - Parameters:
    ///   - texture: R8Unorm texture to clear
    ///   - value: Clear value (0.0 or 1.0 typically)
    ///   - commandBuffer: Command buffer for encoding
    func clearR8Texture(_ texture: MTLTexture, value: Float, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(value),
            green: Double(value),
            blue: Double(value),
            alpha: Double(value)
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.endEncoding()
    }

    /// Clears a color texture to transparent black using render pass clear.
    ///
    /// - Parameters:
    ///   - texture: BGRA8Unorm texture to clear
    ///   - commandBuffer: Command buffer for encoding
    func clearColorTexture(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.endEncoding()
    }

    // MARK: - Coverage Rendering

    /// Renders path triangles to R8 coverage texture.
    ///
    /// Uses coveragePipelineState to draw triangulated path geometry.
    /// Output is raw coverage (1.0 inside triangles).
    ///
    /// - Parameters:
    ///   - pathId: Path ID to render
    ///   - frame: Animation frame for sampling
    ///   - into: R8Unorm coverage texture (already cleared to 0)
    ///   - mvp: Model-view-projection matrix (path space → NDC)
    ///   - scissor: Scissor rect (bbox-local)
    ///   - pathRegistry: Registry containing path data
    ///   - commandBuffer: Command buffer for encoding
    ///   - scratch: Reusable scratch buffer for position sampling
    func renderCoverage(
        pathId: PathID,
        frame: Double,
        into texture: MTLTexture,
        mvp: simd_float4x4,
        scissor: MTLScissorRect,
        pathRegistry: PathRegistry,
        commandBuffer: MTLCommandBuffer,
        scratch: inout [Float]
    ) throws {
        guard let resource = pathRegistry.path(for: pathId) else {
            return // No path resource - skip
        }
        guard resource.vertexCount > 0, !resource.indices.isEmpty else {
            return // Empty path - skip
        }

        // Sample positions at frame
        resource.sampleTriangulatedPositions(at: frame, into: &scratch)

        guard scratch.count >= resource.vertexCount * 2 else {
            return // Invalid data - skip
        }

        // TODO: [I4-perf] Cache vertex/index buffers to avoid per-frame allocations.
        // - indexBuffer is stable per PathResource, can be cached in PathResource or a pool
        // - vertexBuffer changes per frame for animated paths, consider ring buffer or pool

        // Create vertex buffer from positions
        let vertexByteCount = scratch.count * MemoryLayout<Float>.stride
        guard let vertexBuffer = device.makeBuffer(
            bytes: scratch,
            length: vertexByteCount,
            options: .storageModeShared
        ) else {
            return
        }

        // Create index buffer (stable per path, candidate for caching)
        let indexByteCount = resource.indices.count * MemoryLayout<UInt16>.stride
        guard let indexBuffer = device.makeBuffer(
            bytes: resource.indices,
            length: indexByteCount,
            options: .storageModeShared
        ) else {
            return
        }

        // Create render pass (load existing content - already cleared)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        defer { encoder.endEncoding() }

        // Setup pipeline
        encoder.setRenderPipelineState(resources.coveragePipelineState)
        encoder.setScissorRect(scissor)

        // Bind vertex buffer (positions as float2)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        // Bind uniforms
        var uniforms = CoverageUniforms(mvp: mvp)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CoverageUniforms>.stride, index: 1)

        // Draw triangles
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resource.indices.count,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    // MARK: - Mask Combine (Compute)

    /// Combines coverage with accumulator using boolean operation (ping-pong).
    ///
    /// INVARIANT: accumIn !== accumOut (no in-place read/write)
    ///
    /// - Parameters:
    ///   - coverage: R8 coverage texture (input)
    ///   - accumIn: R8 accumulator input texture
    ///   - accumOut: R8 accumulator output texture
    ///   - mode: Boolean operation mode (add/subtract/intersect)
    ///   - inverted: Whether to invert coverage before operation
    ///   - opacity: Coverage opacity multiplier
    ///   - commandBuffer: Command buffer for encoding
    func combineMask(
        coverage: MTLTexture,
        accumIn: MTLTexture,
        accumOut: MTLTexture,
        mode: MaskMode,
        inverted: Bool,
        opacity: Float,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        defer { encoder.endEncoding() }

        encoder.setComputePipelineState(resources.maskCombineComputePipeline)

        // Bind textures
        encoder.setTexture(coverage, index: 0)
        encoder.setTexture(accumIn, index: 1)
        encoder.setTexture(accumOut, index: 2)

        // Bind parameters
        var params = MaskCombineParams(
            mode: mode.shaderModeValue,
            inverted: inverted,
            opacity: opacity
        )
        encoder.setBytes(&params, length: MemoryLayout<MaskCombineParams>.stride, index: 0)

        // Dispatch threads
        let width = accumOut.width
        let height = accumOut.height
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
    }

    // MARK: - Masked Composite

    /// Composites content texture with mask to main target.
    ///
    /// Draws a quad at bbox position, multiplying content by mask value.
    /// Uses maskedCompositePipelineState.
    ///
    /// - Parameters:
    ///   - content: BGRA content texture (bbox-sized)
    ///   - mask: R8 final mask texture (bbox-sized)
    ///   - bbox: Bounding box position in viewport pixels
    ///   - target: Main render target
    ///   - viewportToNDC: Transform from viewport to NDC
    ///   - commandBuffer: Command buffer for encoding
    ///   - scissor: Parent scissor rect (optional)
    func compositeMaskedQuad(
        content: MTLTexture,
        mask: MTLTexture,
        bbox: PixelBBox,
        target: RenderTarget,
        viewportToNDC: Matrix2D,
        commandBuffer: MTLCommandBuffer,
        scissor: MTLScissorRect?
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target.texture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        defer { encoder.endEncoding() }

        // Set parent scissor (not bbox-local!)
        if let scissor = scissor {
            encoder.setScissorRect(scissor)
        }

        encoder.setRenderPipelineState(resources.maskedCompositePipelineState)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)

        // Create quad vertices at bbox position
        let x = Float(bbox.x)
        let y = Float(bbox.y)
        let w = Float(bbox.width)
        let h = Float(bbox.height)

        let vertices: [QuadVertex] = [
            QuadVertex(position: SIMD2<Float>(x, y), texCoord: SIMD2<Float>(0, 0)),
            QuadVertex(position: SIMD2<Float>(x + w, y), texCoord: SIMD2<Float>(1, 0)),
            QuadVertex(position: SIMD2<Float>(x, y + h), texCoord: SIMD2<Float>(0, 1)),
            QuadVertex(position: SIMD2<Float>(x + w, y + h), texCoord: SIMD2<Float>(1, 1))
        ]

        let vertexSize = vertices.count * MemoryLayout<QuadVertex>.stride
        guard let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertexSize, options: .storageModeShared) else {
            return
        }

        // MVP transforms viewport coords to NDC
        let mvp = viewportToNDC.toFloat4x4()
        var uniforms = MaskedCompositeUniforms(mvp: mvp, opacity: 1.0)

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MaskedCompositeUniforms>.stride, index: 1)
        encoder.setFragmentTexture(content, index: 0)
        encoder.setFragmentTexture(mask, index: 1)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.quadIndexCount,
            indexType: .uint16,
            indexBuffer: resources.quadIndexBuffer,
            indexBufferOffset: 0
        )
    }
}

// MARK: - MaskMode Shader Value

extension MaskMode {
    /// Returns shader mode value for mask boolean operations.
    /// 0 = add, 1 = subtract, 2 = intersect
    var shaderModeValue: Int32 {
        switch self {
        case .add: return MaskCombineParams.modeAdd
        case .subtract: return MaskCombineParams.modeSubtract
        case .intersect: return MaskCombineParams.modeIntersect
        }
    }
}
