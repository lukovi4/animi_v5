import Metal
import simd

// MARK: - Quad Vertex

/// Vertex structure for textured quad rendering.
/// Must match QuadVertexIn in QuadShaders.metal.
struct QuadVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

// MARK: - Quad Uniforms

/// Uniform buffer structure for quad rendering.
/// Must match QuadUniforms in QuadShaders.metal.
struct QuadUniforms {
    var mvp: simd_float4x4
    var opacity: Float
    var padding: SIMD3<Float> = .zero // Alignment to 16 bytes

    init(mvp: simd_float4x4, opacity: Float) {
        self.mvp = mvp
        self.opacity = opacity
    }
}

// MARK: - Metal Renderer Resources

/// Manages Metal resources for quad rendering: pipeline state, samplers, and buffers.
final class MetalRendererResources {
    let pipelineState: MTLRenderPipelineState
    let samplerState: MTLSamplerState
    let quadIndexBuffer: MTLBuffer

    /// Index count for quad (2 triangles = 6 indices)
    let quadIndexCount: Int = 6

    /// Creates Metal resources for quad rendering.
    /// - Parameters:
    ///   - device: Metal device
    ///   - colorPixelFormat: Target color pixel format
    /// - Throws: MetalRendererError if resource creation fails
    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws {
        // Create shader library from source code
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalRendererError.failedToCreatePipeline(
                reason: "Failed to compile Metal shaders: \(error.localizedDescription)"
            )
        }

        // Load shader functions
        guard let vertexFunction = library.makeFunction(name: "quad_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(
                reason: "Vertex function 'quad_vertex' not found"
            )
        }

        guard let fragmentFunction = library.makeFunction(name: "quad_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(
                reason: "Fragment function 'quad_fragment' not found"
            )
        }

        // Create vertex descriptor
        let vertexDescriptor = MTLVertexDescriptor()

        // Position attribute
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0

        // TexCoord attribute
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0

        // Vertex buffer layout
        vertexDescriptor.layouts[0].stride = MemoryLayout<QuadVertex>.stride
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        // Create pipeline descriptor
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor

        // Configure color attachment with premultiplied alpha blending
        // swiftlint:disable:next force_unwrapping
        let colorAttachment = pipelineDescriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = colorPixelFormat
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        colorAttachment.sourceRGBBlendFactor = .one
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.sourceAlphaBlendFactor = .one
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Create pipeline state
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw MetalRendererError.failedToCreatePipeline(
                reason: "Failed to create pipeline state: \(error.localizedDescription)"
            )
        }

        // Create sampler state (linear filtering, clamp to edge)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge

        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MetalRendererError.failedToCreatePipeline(
                reason: "Failed to create sampler state"
            )
        }
        samplerState = sampler

        // Create index buffer for quad (2 triangles)
        // Triangle 1: 0, 1, 2
        // Triangle 2: 2, 1, 3
        let indices: [UInt16] = [0, 1, 2, 2, 1, 3]
        let indexBufferSize = indices.count * MemoryLayout<UInt16>.stride

        guard let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indexBufferSize,
            options: .storageModeShared
        ) else {
            throw MetalRendererError.failedToCreatePipeline(
                reason: "Failed to create index buffer"
            )
        }
        quadIndexBuffer = indexBuffer
    }

    // MARK: - Shader Source

    /// Metal shader source code for quad rendering.
    /// Embedded as string to support Swift Package Manager (no pre-compiled metallib).
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

    /// Creates a vertex buffer for a quad with the given size in pixels.
    /// Vertices are in local pixel coordinates: (0,0) to (width, height).
    /// UV coordinates map to full texture: (0,0) to (1,1).
    ///
    /// - Parameters:
    ///   - device: Metal device
    ///   - width: Quad width in pixels
    ///   - height: Quad height in pixels
    /// - Returns: Vertex buffer or nil if creation fails
    func makeQuadVertexBuffer(
        device: MTLDevice,
        width: Float,
        height: Float
    ) -> MTLBuffer? {
        // Vertices in pixel coordinates (top-left origin)
        // UV origin at top-left (0,0), bottom-right (1,1)
        let vertices: [QuadVertex] = [
            QuadVertex(position: SIMD2<Float>(0, 0), texCoord: SIMD2<Float>(0, 0)),         // Top-left
            QuadVertex(position: SIMD2<Float>(width, 0), texCoord: SIMD2<Float>(1, 0)),     // Top-right
            QuadVertex(position: SIMD2<Float>(0, height), texCoord: SIMD2<Float>(0, 1)),    // Bottom-left
            QuadVertex(position: SIMD2<Float>(width, height), texCoord: SIMD2<Float>(1, 1)) // Bottom-right
        ]

        let bufferSize = vertices.count * MemoryLayout<QuadVertex>.stride
        return device.makeBuffer(bytes: vertices, length: bufferSize, options: .storageModeShared)
    }
}
