// swiftlint:disable file_length
import Metal
import simd

// MARK: - Quad Vertex

/// Vertex structure for textured quad rendering.
struct QuadVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

// MARK: - Quad Uniforms

/// Uniform buffer structure for quad rendering.
/// Layout must match Metal: float4x4 (64) + float (4) + float3 (12) = 80 bytes
struct QuadUniforms {
    var mvp: simd_float4x4
    var opacity: Float
    // Use tuple instead of SIMD3 to match Metal float3 alignment (4, not 16)
    var padding: (Float, Float, Float) = (0, 0, 0)

    init(mvp: simd_float4x4, opacity: Float) {
        self.mvp = mvp
        self.opacity = opacity
    }
}

// MARK: - Coverage Uniforms (GPU Mask)

/// Uniform buffer structure for coverage rendering (path triangles → R8).
/// Note: inverted and opacity are applied in the combine kernel, not here.
/// The coverage shader just renders raw triangle coverage (1.0 inside path).
struct CoverageUniforms {
    var mvp: simd_float4x4

    init(mvp: simd_float4x4) {
        self.mvp = mvp
    }
}

// MARK: - Masked Composite Uniforms (GPU Mask)

/// Uniform buffer structure for masked composite (content × mask).
/// Layout must match Metal: float4x4 (64) + float (4) + float3 (12) = 80 bytes
struct MaskedCompositeUniforms {
    var mvp: simd_float4x4
    var opacity: Float
    // Use tuple instead of SIMD3 to match Metal float3 alignment (4, not 16)
    var padding: (Float, Float, Float) = (0, 0, 0)

    init(mvp: simd_float4x4, opacity: Float) {
        self.mvp = mvp
        self.opacity = opacity
    }
}

// MARK: - Mask Combine Parameters (GPU Mask)

/// Parameters for mask boolean combination compute kernel.
struct MaskCombineParams {
    /// Boolean operation mode: 0=add, 1=subtract, 2=intersect
    var mode: Int32
    /// Whether coverage should be inverted before operation
    var inverted: Int32
    /// Coverage opacity multiplier (0-1)
    var opacity: Float
    var padding: Float = 0

    /// Mode constants matching shader
    static let modeAdd: Int32 = 0
    static let modeSubtract: Int32 = 1
    static let modeIntersect: Int32 = 2

    init(mode: Int32, inverted: Bool, opacity: Float) {
        self.mode = mode
        self.inverted = inverted ? 1 : 0
        self.opacity = opacity
    }
}

// MARK: - Metal Renderer Resources

/// Manages Metal resources for quad rendering.
final class MetalRendererResources {
    // MARK: - Base Pipeline

    let pipelineState: MTLRenderPipelineState
    let samplerState: MTLSamplerState
    let quadIndexBuffer: MTLBuffer
    let quadIndexCount: Int = 6

    // MARK: - Stencil Mask Resources

    /// Pipeline for rendering with stencil test (composite masked content)
    let stencilCompositePipelineState: MTLRenderPipelineState

    /// Pipeline for writing mask alpha to stencil buffer
    let maskWritePipelineState: MTLRenderPipelineState

    /// Depth stencil state for writing 0xFF to stencil where mask > 0
    let stencilWriteDepthStencilState: MTLDepthStencilState

    /// Depth stencil state for testing stencil == 0xFF
    let stencilTestDepthStencilState: MTLDepthStencilState

    // MARK: - Matte Composite Resources

    /// Pipeline for compositing consumer with matte (alpha/luma modes)
    let matteCompositePipelineState: MTLRenderPipelineState

    // MARK: - GPU Mask Resources (for boolean mask ops)

    /// Pipeline for rendering path triangles to R8 coverage texture
    let coveragePipelineState: MTLRenderPipelineState

    /// Pipeline for compositing content with R8 mask texture (content × mask)
    let maskedCompositePipelineState: MTLRenderPipelineState

    /// Compute pipeline for boolean mask combination (add/subtract/intersect)
    let maskCombineComputePipeline: MTLComputePipelineState

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws {
        let library = try Self.makeShaderLibrary(device: device)
        pipelineState = try Self.makePipelineState(device: device, library: library, colorPixelFormat: colorPixelFormat)
        samplerState = try Self.makeSamplerState(device: device)
        quadIndexBuffer = try Self.makeIndexBuffer(device: device)

        // Stencil mask resources
        stencilCompositePipelineState = try Self.makeStencilCompositePipeline(
            device: device,
            library: library,
            colorPixelFormat: colorPixelFormat
        )
        maskWritePipelineState = try Self.makeMaskWritePipeline(
            device: device,
            library: library
        )
        stencilWriteDepthStencilState = try Self.makeStencilWriteDepthStencilState(device: device)
        stencilTestDepthStencilState = try Self.makeStencilTestDepthStencilState(device: device)

        // Matte composite resources
        matteCompositePipelineState = try Self.makeMatteCompositePipeline(
            device: device,
            library: library,
            colorPixelFormat: colorPixelFormat
        )

        // GPU mask resources
        coveragePipelineState = try Self.makeCoveragePipeline(
            device: device,
            library: library
        )
        maskedCompositePipelineState = try Self.makeMaskedCompositePipeline(
            device: device,
            library: library,
            colorPixelFormat: colorPixelFormat
        )
        maskCombineComputePipeline = try Self.makeMaskCombineComputePipeline(
            device: device,
            library: library
        )
    }

    func makeQuadVertexBuffer(device: MTLDevice, width: Float, height: Float) -> MTLBuffer? {
        let vertices: [QuadVertex] = [
            QuadVertex(position: SIMD2<Float>(0, 0), texCoord: SIMD2<Float>(0, 0)),
            QuadVertex(position: SIMD2<Float>(width, 0), texCoord: SIMD2<Float>(1, 0)),
            QuadVertex(position: SIMD2<Float>(0, height), texCoord: SIMD2<Float>(0, 1)),
            QuadVertex(position: SIMD2<Float>(width, height), texCoord: SIMD2<Float>(1, 1))
        ]
        let size = vertices.count * MemoryLayout<QuadVertex>.stride
        return device.makeBuffer(bytes: vertices, length: size, options: .storageModeShared)
    }
}

// MARK: - Resource Creation

extension MetalRendererResources {
    private static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        do {
            return try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            let msg = "Shader compile failed: \(error.localizedDescription)"
            throw MetalRendererError.failedToCreatePipeline(reason: msg)
        }
    }

    private static func makePipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "quad_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "quad_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "quad_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "quad_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.vertexDescriptor = makeVertexDescriptor()
        configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            let msg = "Pipeline creation failed: \(error.localizedDescription)"
            throw MetalRendererError.failedToCreatePipeline(reason: msg)
        }
    }

    private static func makeVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float2
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float2
        descriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        descriptor.attributes[1].bufferIndex = 0
        descriptor.layouts[0].stride = MemoryLayout<QuadVertex>.stride
        descriptor.layouts[0].stepRate = 1
        descriptor.layouts[0].stepFunction = .perVertex
        return descriptor
    }

    private static func configureBlending(
        _ attachment: MTLRenderPipelineColorAttachmentDescriptor?,
        pixelFormat: MTLPixelFormat
    ) {
        guard let attachment = attachment else { return }
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    private static func makeSamplerState(device: MTLDevice) throws -> MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw MetalRendererError.failedToCreatePipeline(reason: "Sampler creation failed")
        }
        return sampler
    }

    private static func makeIndexBuffer(device: MTLDevice) throws -> MTLBuffer {
        let indices: [UInt16] = [0, 1, 2, 2, 1, 3]
        let size = indices.count * MemoryLayout<UInt16>.stride
        guard let buffer = device.makeBuffer(bytes: indices, length: size, options: .storageModeShared) else {
            throw MetalRendererError.failedToCreatePipeline(reason: "Index buffer creation failed")
        }
        return buffer
    }
}

// MARK: - Stencil Pipeline Creation

extension MetalRendererResources {
    private static func makeStencilCompositePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "quad_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "quad_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "quad_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "quad_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.vertexDescriptor = makeVertexDescriptor()
        configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            let msg = "Stencil composite pipeline failed: \(error.localizedDescription)"
            throw MetalRendererError.failedToCreatePipeline(reason: msg)
        }
    }

    private static func makeMaskWritePipeline(
        device: MTLDevice,
        library: MTLLibrary
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "mask_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "mask_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "mask_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "mask_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.vertexDescriptor = makeVertexDescriptor()
        // No color attachment - stencil only
        descriptor.colorAttachments[0].pixelFormat = .invalid
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            let msg = "Mask write pipeline failed: \(error.localizedDescription)"
            throw MetalRendererError.failedToCreatePipeline(reason: msg)
        }
    }

    private static func makeStencilWriteDepthStencilState(device: MTLDevice) throws -> MTLDepthStencilState {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.isDepthWriteEnabled = false
        descriptor.depthCompareFunction = .always

        // Front face stencil: write 0xFF where fragment passes (mask alpha > 0)
        let stencilDescriptor = MTLStencilDescriptor()
        stencilDescriptor.stencilCompareFunction = .always
        stencilDescriptor.stencilFailureOperation = .keep
        stencilDescriptor.depthFailureOperation = .keep
        stencilDescriptor.depthStencilPassOperation = .replace
        stencilDescriptor.readMask = 0xFF
        stencilDescriptor.writeMask = 0xFF

        descriptor.frontFaceStencil = stencilDescriptor
        descriptor.backFaceStencil = stencilDescriptor

        guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
            throw MetalRendererError.failedToCreatePipeline(reason: "Stencil write state failed")
        }
        return state
    }

    private static func makeStencilTestDepthStencilState(device: MTLDevice) throws -> MTLDepthStencilState {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.isDepthWriteEnabled = false
        descriptor.depthCompareFunction = .always

        // Front face stencil: pass only where stencil == 0xFF
        let stencilDescriptor = MTLStencilDescriptor()
        stencilDescriptor.stencilCompareFunction = .equal
        stencilDescriptor.stencilFailureOperation = .keep
        stencilDescriptor.depthFailureOperation = .keep
        stencilDescriptor.depthStencilPassOperation = .keep
        stencilDescriptor.readMask = 0xFF
        stencilDescriptor.writeMask = 0x00

        descriptor.frontFaceStencil = stencilDescriptor
        descriptor.backFaceStencil = stencilDescriptor

        guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
            throw MetalRendererError.failedToCreatePipeline(reason: "Stencil test state failed")
        }
        return state
    }

    private static func makeMatteCompositePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "matte_composite_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "matte_composite_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "matte_composite_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "matte_composite_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.vertexDescriptor = makeVertexDescriptor()
        configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            let msg = "Matte composite pipeline failed: \(error.localizedDescription)"
            throw MetalRendererError.failedToCreatePipeline(reason: msg)
        }
    }
}

// MARK: - GPU Mask Pipeline Creation

extension MetalRendererResources {
    /// Creates pipeline for rendering path triangles to R8 coverage texture.
    /// Uses additive blending for overlapping triangles.
    private static func makeCoveragePipeline(
        device: MTLDevice,
        library: MTLLibrary
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "coverage_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "coverage_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "coverage_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "coverage_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc

        // R8Unorm output for coverage
        let colorAttachment = descriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = .r8Unorm
        // No blending - triangulation should not produce overlapping triangles
        // If overlap occurs, it's a bug in triangulation data
        // saturate() in compute kernel handles any edge cases
        colorAttachment.isBlendingEnabled = false

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            let msg = "Coverage pipeline failed: \(error.localizedDescription)"
            throw MetalRendererError.failedToCreatePipeline(reason: msg)
        }
    }

    /// Creates pipeline for compositing content with R8 mask (content × mask.r).
    private static func makeMaskedCompositePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "masked_composite_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "masked_composite_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "masked_composite_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "masked_composite_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.vertexDescriptor = makeVertexDescriptor()
        configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            let msg = "Masked composite pipeline failed: \(error.localizedDescription)"
            throw MetalRendererError.failedToCreatePipeline(reason: msg)
        }
    }

    /// Creates compute pipeline for mask boolean operations.
    private static func makeMaskCombineComputePipeline(
        device: MTLDevice,
        library: MTLLibrary
    ) throws -> MTLComputePipelineState {
        guard let kernelFunc = library.makeFunction(name: "mask_combine_kernel") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "mask_combine_kernel not found")
        }

        do {
            return try device.makeComputePipelineState(function: kernelFunc)
        } catch {
            let msg = "Mask combine compute pipeline failed: \(error.localizedDescription)"
            throw MetalRendererError.failedToCreatePipeline(reason: msg)
        }
    }
}

// MARK: - Shader Source

extension MetalRendererResources {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadVertexIn {
        float2 position [[attribute(0)]];
        float2 texCoord [[attribute(1)]];
    };

    struct QuadUniforms {
        float4x4 mvp;
        float opacity;
        float3 _padding;
    };

    struct QuadVertexOut {
        float4 position [[position]];
        float2 texCoord;
        float opacity;
    };

    vertex QuadVertexOut quad_vertex(
        QuadVertexIn in [[stage_in]],
        constant QuadUniforms& uniforms [[buffer(1)]]
    ) {
        QuadVertexOut out;
        out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        out.opacity = uniforms.opacity;
        return out;
    }

    fragment float4 quad_fragment(
        QuadVertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        float4 color = tex.sample(samp, in.texCoord);
        return color * in.opacity;
    }

    // MARK: - Mask Shaders

    struct MaskVertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex MaskVertexOut mask_vertex(
        QuadVertexIn in [[stage_in]],
        constant QuadUniforms& uniforms [[buffer(1)]]
    ) {
        MaskVertexOut out;
        out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        return out;
    }

    fragment void mask_fragment(
        MaskVertexOut in [[stage_in]],
        texture2d<float> maskTex [[texture(0)]],
        sampler samp [[sampler(0)]]
    ) {
        float alpha = maskTex.sample(samp, in.texCoord).r;
        // Discard fragments where mask alpha is zero
        if (alpha < 0.004) {
            discard_fragment();
        }
        // Fragment passes - stencil will be written via depth stencil state
    }

    // MARK: - Matte Composite Shaders

    struct MatteCompositeUniforms {
        float4x4 mvp;
        int mode;       // 0=alpha, 1=alphaInverted, 2=luma, 3=lumaInverted
        float3 _padding;
    };

    struct MatteCompositeVertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex MatteCompositeVertexOut matte_composite_vertex(
        QuadVertexIn in [[stage_in]],
        constant MatteCompositeUniforms& uniforms [[buffer(1)]]
    ) {
        MatteCompositeVertexOut out;
        out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        return out;
    }

    fragment float4 matte_composite_fragment(
        MatteCompositeVertexOut in [[stage_in]],
        texture2d<float> consumerTex [[texture(0)]],
        texture2d<float> matteTex [[texture(1)]],
        sampler samp [[sampler(0)]],
        constant MatteCompositeUniforms& uniforms [[buffer(1)]]
    ) {
        float4 consumer = consumerTex.sample(samp, in.texCoord);
        float4 matte = matteTex.sample(samp, in.texCoord);

        float factor;
        int mode = uniforms.mode;

        if (mode == 0) {
            // alpha
            factor = matte.a;
        } else if (mode == 1) {
            // alphaInverted
            factor = 1.0 - matte.a;
        } else if (mode == 2) {
            // luma: luminance = 0.2126*r + 0.7152*g + 0.0722*b
            float luma = 0.2126 * matte.r + 0.7152 * matte.g + 0.0722 * matte.b;
            factor = luma;
        } else {
            // lumaInverted
            float luma = 0.2126 * matte.r + 0.7152 * matte.g + 0.0722 * matte.b;
            factor = 1.0 - luma;
        }

        // Apply factor to premultiplied consumer
        return float4(consumer.rgb * factor, consumer.a * factor);
    }

    // MARK: - GPU Mask Coverage Shaders

    struct CoverageUniforms {
        float4x4 mvp;
    };

    struct CoverageVertexOut {
        float4 position [[position]];
    };

    // Renders path triangles to R8 coverage texture.
    // Output is raw coverage (1.0 inside triangles, 0.0 outside).
    // Inverted and opacity are applied later in mask_combine_kernel.
    vertex CoverageVertexOut coverage_vertex(
        uint vertexID [[vertex_id]],
        const device float2* positions [[buffer(0)]],
        constant CoverageUniforms& uniforms [[buffer(1)]]
    ) {
        CoverageVertexOut out;
        float2 pos = positions[vertexID];
        out.position = uniforms.mvp * float4(pos, 0.0, 1.0);
        return out;
    }

    fragment float coverage_fragment(CoverageVertexOut in [[stage_in]]) {
        // Output raw coverage = 1.0 inside path triangles
        // No blending - triangulation produces non-overlapping triangles
        // saturate() in combine kernel handles any edge cases
        return 1.0;
    }

    // MARK: - Masked Composite Shaders (content × mask)

    struct MaskedCompositeUniforms {
        float4x4 mvp;
        float opacity;
        float3 _padding;
    };

    vertex QuadVertexOut masked_composite_vertex(
        QuadVertexIn in [[stage_in]],
        constant MaskedCompositeUniforms& uniforms [[buffer(1)]]
    ) {
        QuadVertexOut out;
        out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        out.opacity = uniforms.opacity;
        return out;
    }

    fragment float4 masked_composite_fragment(
        QuadVertexOut in [[stage_in]],
        texture2d<float> contentTex [[texture(0)]],
        texture2d<float> maskTex [[texture(1)]],
        sampler samp [[sampler(0)]]
    ) {
        float4 content = contentTex.sample(samp, in.texCoord);
        float maskValue = maskTex.sample(samp, in.texCoord).r;

        // Apply mask to premultiplied content
        float factor = maskValue * in.opacity;
        return float4(content.rgb * factor, content.a * factor);
    }

    // MARK: - Mask Combine Compute Kernel

    // Mode constants for boolean operations
    constant int MASK_MODE_ADD = 0;
    constant int MASK_MODE_SUBTRACT = 1;
    constant int MASK_MODE_INTERSECT = 2;

    struct MaskCombineParams {
        int mode;           // 0=add, 1=subtract, 2=intersect
        int inverted;       // 1 if coverage should be inverted before op
        float opacity;      // coverage opacity multiplier (0-1)
        float _padding;
    };

    kernel void mask_combine_kernel(
        texture2d<float, access::read> coverageTex [[texture(0)]],
        texture2d<float, access::read> accumInTex [[texture(1)]],
        texture2d<float, access::write> accumOutTex [[texture(2)]],
        constant MaskCombineParams& params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        // Bounds check
        if (gid.x >= accumOutTex.get_width() || gid.y >= accumOutTex.get_height()) {
            return;
        }

        // Read current accumulator value
        float acc = accumInTex.read(gid).r;

        // Read and process coverage
        float cov = coverageTex.read(gid).r;

        // Clamp coverage to [0,1] (triangulation may cause slight overdraw)
        cov = saturate(cov);

        // Apply inverted flag
        if (params.inverted != 0) {
            cov = 1.0 - cov;
        }

        // Apply opacity
        cov *= params.opacity;

        // Apply boolean operation
        float result;
        if (params.mode == MASK_MODE_ADD) {
            // ADD: acc = max(acc, cov)
            result = max(acc, cov);
        } else if (params.mode == MASK_MODE_SUBTRACT) {
            // SUBTRACT: acc = acc * (1 - cov)
            result = acc * (1.0 - cov);
        } else {
            // INTERSECT: acc = min(acc, cov)
            result = min(acc, cov);
        }

        accumOutTex.write(float4(result, 0.0, 0.0, 0.0), gid);
    }
    """
}
