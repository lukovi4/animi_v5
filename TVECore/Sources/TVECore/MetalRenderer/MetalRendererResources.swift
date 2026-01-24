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
struct QuadUniforms {
    var mvp: simd_float4x4
    var opacity: Float
    var padding: SIMD3<Float> = .zero

    init(mvp: simd_float4x4, opacity: Float) {
        self.mvp = mvp
        self.opacity = opacity
    }
}

// MARK: - Metal Renderer Resources

/// Manages Metal resources for quad rendering.
final class MetalRendererResources {
    let pipelineState: MTLRenderPipelineState
    let samplerState: MTLSamplerState
    let quadIndexBuffer: MTLBuffer
    let quadIndexCount: Int = 6

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws {
        let library = try Self.makeShaderLibrary(device: device)
        pipelineState = try Self.makePipelineState(device: device, library: library, colorPixelFormat: colorPixelFormat)
        samplerState = try Self.makeSamplerState(device: device)
        quadIndexBuffer = try Self.makeIndexBuffer(device: device)
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
    """
}
