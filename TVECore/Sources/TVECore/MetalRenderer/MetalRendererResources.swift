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
/// Layout must match Metal shader struct exactly.
///
/// Metal layout (with float3 alignment = 16):
///   float4x4 mvp:    64 bytes (offset 0)
///   float opacity:    4 bytes (offset 64)
///   padding:         12 bytes (offset 68, for float3 alignment)
///   float3 _padding: 12 bytes (offset 80) + 4 bytes struct padding = 16 bytes
///   Total: 96 bytes
struct QuadUniforms {
    var mvp: simd_float4x4          // 64 bytes
    var opacity: Float              // 4 bytes
    var _pad0: Float = 0            // 4 bytes (padding before SIMD3)
    var _pad1: Float = 0            // 4 bytes
    var _pad2: Float = 0            // 4 bytes
    var _padding: SIMD3<Float> = .zero  // 16 bytes (SIMD3 has alignment 16 in Swift too)

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
/// Layout must match Metal shader struct exactly.
///
/// Metal layout (with float3 alignment = 16):
///   float4x4 mvp:    64 bytes (offset 0)
///   float opacity:    4 bytes (offset 64)
///   padding:         12 bytes (offset 68, for float3 alignment)
///   float3 _padding: 12 bytes (offset 80) + 4 bytes struct padding = 16 bytes
///   Total: 96 bytes
struct MaskedCompositeUniforms {
    var mvp: simd_float4x4          // 64 bytes
    var opacity: Float              // 4 bytes
    var _pad0: Float = 0            // 4 bytes (padding before SIMD3)
    var _pad1: Float = 0            // 4 bytes
    var _pad2: Float = 0            // 4 bytes
    var _padding: SIMD3<Float> = .zero  // 16 bytes (SIMD3 has alignment 16 in Swift too)

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
        // Try SPM Bundle.module first (for TVECore as Swift Package)
        if let url = Bundle.module.url(forResource: "default", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: url) {
            return lib
        }
        // Fallback: main bundle (for embedded frameworks or direct integration)
        if let lib = device.makeDefaultLibrary() {
            return lib
        }
        throw MetalRendererError.failedToCreatePipeline(reason: "Failed to load Metal library from Bundle.module or main bundle")
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

