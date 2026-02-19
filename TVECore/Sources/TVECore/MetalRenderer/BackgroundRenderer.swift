import Metal
import simd

// MARK: - Background Uniforms

/// Vertex uniforms for background shaders (shared by all, for vertex shader)
struct BgVertexUniforms {
    var mvp: simd_float4x4
    var animToViewport: simd_float4x4  // Transform from canvas to viewport coordinates
    var targetSize: simd_float2         // Target/viewport size in pixels for mask UV
    var _padding: simd_float2 = .zero

    init(mvp: simd_float4x4, animToViewport: simd_float4x4, targetSize: simd_float2) {
        self.mvp = mvp
        self.animToViewport = animToViewport
        self.targetSize = targetSize
    }
}

/// Uniforms for background solid color shader
struct BgSolidUniforms {
    var mvp: simd_float4x4
    var animToViewport: simd_float4x4
    var targetSize: simd_float2
    var _padding: simd_float2 = .zero
    var color: simd_float4

    init(mvp: simd_float4x4, animToViewport: simd_float4x4, targetSize: simd_float2, color: simd_float4) {
        self.mvp = mvp
        self.animToViewport = animToViewport
        self.targetSize = targetSize
        self.color = color
    }
}

/// Uniforms for background gradient shader
struct BgGradientUniforms {
    var mvp: simd_float4x4
    var animToViewport: simd_float4x4
    var targetSize: simd_float2
    var _padding: simd_float2 = .zero
    var color0: simd_float4
    var color1: simd_float4
    var p0: simd_float2
    var p1: simd_float2

    init(mvp: simd_float4x4, animToViewport: simd_float4x4, targetSize: simd_float2, color0: simd_float4, color1: simd_float4, p0: simd_float2, p1: simd_float2) {
        self.mvp = mvp
        self.animToViewport = animToViewport
        self.targetSize = targetSize
        self.color0 = color0
        self.color1 = color1
        self.p0 = p0
        self.p1 = p1
    }
}

/// Uniforms for background image shader
struct BgImageUniforms {
    var mvp: simd_float4x4
    var animToViewport: simd_float4x4
    var targetSize: simd_float2
    var _padding: simd_float2 = .zero
    var uvTransform: simd_float4x4

    init(mvp: simd_float4x4, animToViewport: simd_float4x4, targetSize: simd_float2, uvTransform: simd_float4x4) {
        self.mvp = mvp
        self.animToViewport = animToViewport
        self.targetSize = targetSize
        self.uvTransform = uvTransform
    }
}

// MARK: - Background Renderer

/// Renders background presets with multiple regions.
/// Supports solid color, linear gradient (2 stops), and image fills.
/// Each region is masked by its shape path.
final class BackgroundRenderer {

    // MARK: - Properties

    private let device: MTLDevice
    private let shapeCache: ShapeCache
    private let colorPixelFormat: MTLPixelFormat

    // Pipeline states
    private let solidPipeline: MTLRenderPipelineState
    private let gradientPipeline: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let samplerState: MTLSamplerState

    // Shared resources
    private let quadIndexBuffer: MTLBuffer
    private let quadIndexCount: Int = 6

    // MARK: - Initialization

    init(device: MTLDevice, shapeCache: ShapeCache, colorPixelFormat: MTLPixelFormat) throws {
        self.device = device
        self.shapeCache = shapeCache
        self.colorPixelFormat = colorPixelFormat

        // Load shader library
        let library = try Self.loadShaderLibrary(device: device)

        // Create pipeline states
        solidPipeline = try Self.makeSolidPipeline(device: device, library: library, colorPixelFormat: colorPixelFormat)
        gradientPipeline = try Self.makeGradientPipeline(device: device, library: library, colorPixelFormat: colorPixelFormat)
        imagePipeline = try Self.makeImagePipeline(device: device, library: library, colorPixelFormat: colorPixelFormat)
        samplerState = try Self.makeSamplerState(device: device)
        quadIndexBuffer = try Self.makeIndexBuffer(device: device)
    }

    // MARK: - Rendering

    /// Renders all background regions to the given encoder.
    /// Call this immediately after clear, before scene commands.
    ///
    /// - Parameters:
    ///   - state: The effective background state to render
    ///   - encoder: The render command encoder (already begun)
    ///   - target: The render target
    ///   - textureProvider: Provider for image textures
    ///   - animToViewport: Transform from animation/canvas coordinates to viewport coordinates
    ///   - viewportToNDC: Transform from viewport to NDC
    func render(
        state: EffectiveBackgroundState,
        encoder: MTLRenderCommandEncoder,
        target: RenderTarget,
        textureProvider: TextureProvider,
        animToViewport: Matrix2D,
        viewportToNDC: Matrix2D
    ) {
        let targetSize = target.sizePx
        let canvasSize = (width: state.preset.canvasSize[0], height: state.preset.canvasSize[1])

        // Render regions in order (bottom to top)
        for regionPreset in state.preset.regions {
            guard let regionState = state.regionStates[regionPreset.regionId] else {
                // No state for this region - skip
                continue
            }

            do {
                try renderRegion(
                    preset: regionPreset,
                    state: regionState,
                    encoder: encoder,
                    targetSize: targetSize,
                    canvasSize: canvasSize,
                    textureProvider: textureProvider,
                    animToViewport: animToViewport,
                    viewportToNDC: viewportToNDC
                )
            } catch {
                #if DEBUG
                print("[BackgroundRenderer] Error rendering region '\(regionPreset.regionId)': \(error)")
                #endif
                // Continue with other regions
            }
        }
    }

    // MARK: - Region Rendering

    private func renderRegion(
        preset: BackgroundRegionPreset,
        state: BackgroundRegionState,
        encoder: MTLRenderCommandEncoder,
        targetSize: (width: Int, height: Int),
        canvasSize: (width: Int, height: Int),
        textureProvider: TextureProvider,
        animToViewport: Matrix2D,
        viewportToNDC: Matrix2D
    ) throws {
        // Get mask texture from shape cache
        // Use animToViewport transform to rasterize path in viewport coordinates
        let path = try preset.mask.toBezierPath()
        let maskResult = shapeCache.texture(
            for: path,
            transform: animToViewport,  // Transform path from canvas to viewport space
            size: targetSize,
            fillColor: [1.0, 1.0, 1.0],
            opacity: 1.0
        )

        guard let maskTexture = maskResult.texture else {
            throw BackgroundRendererError.maskCreationFailed(regionId: preset.regionId)
        }

        // Calculate bbox for quad rendering (in canvas coordinates)
        let bbox = path.aabb
        let quadWidth = Float(bbox.maxX - bbox.minX)
        let quadHeight = Float(bbox.maxY - bbox.minY)

        guard quadWidth > 0, quadHeight > 0 else { return }

        // Create vertex buffer for region bbox (canvas coordinates)
        guard let vertexBuffer = makeQuadVertexBuffer(
            x: Float(bbox.minX),
            y: Float(bbox.minY),
            width: quadWidth,
            height: quadHeight
        ) else { return }

        // Calculate MVP: viewportToNDC * animToViewport
        // This transforms canvas coordinates → viewport → NDC
        let combinedTransform = viewportToNDC.concatenating(animToViewport)
        let mvp = combinedTransform.toFloat4x4()

        // Target size for mask UV calculation (mask is in viewport space)
        let targetSizeF = simd_float2(Float(targetSize.width), Float(targetSize.height))

        // animToViewport matrix for shader (to transform canvasPos to viewport for maskUV)
        let animToViewportF = animToViewport.toFloat4x4()

        // Render based on source type
        switch state.source {
        case .solid(let config):
            renderSolid(
                config: config,
                encoder: encoder,
                vertexBuffer: vertexBuffer,
                maskTexture: maskTexture,
                mvp: mvp,
                targetSize: targetSizeF,
                animToViewport: animToViewportF
            )

        case .gradient(let config):
            try renderGradient(
                config: config,
                encoder: encoder,
                vertexBuffer: vertexBuffer,
                maskTexture: maskTexture,
                mvp: mvp,
                targetSize: targetSizeF,
                animToViewport: animToViewportF
            )

        case .image(let config):
            renderImage(
                config: config,
                preset: preset,
                encoder: encoder,
                vertexBuffer: vertexBuffer,
                maskTexture: maskTexture,
                mvp: mvp,
                targetSize: targetSizeF,
                animToViewport: animToViewportF,
                textureProvider: textureProvider,
                bbox: bbox
            )
        }
    }

    // MARK: - Solid Rendering

    private func renderSolid(
        config: SolidConfig,
        encoder: MTLRenderCommandEncoder,
        vertexBuffer: MTLBuffer,
        maskTexture: MTLTexture,
        mvp: simd_float4x4,
        targetSize: simd_float2,
        animToViewport: simd_float4x4
    ) {
        encoder.setRenderPipelineState(solidPipeline)

        var uniforms = BgSolidUniforms(
            mvp: mvp,
            animToViewport: animToViewport,
            targetSize: targetSize,
            color: simd_float4(
                Float(config.color.red),
                Float(config.color.green),
                Float(config.color.blue),
                Float(config.color.alpha)
            )
        )

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        // Pass full uniforms to vertex shader (includes mvp + animToViewport + targetSize)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<BgSolidUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BgSolidUniforms>.stride, index: 1)
        encoder.setFragmentTexture(maskTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: quadIndexCount,
            indexType: .uint16,
            indexBuffer: quadIndexBuffer,
            indexBufferOffset: 0
        )
    }

    // MARK: - Gradient Rendering

    private func renderGradient(
        config: GradientConfig,
        encoder: MTLRenderCommandEncoder,
        vertexBuffer: MTLBuffer,
        maskTexture: MTLTexture,
        mvp: simd_float4x4,
        targetSize: simd_float2,
        animToViewport: simd_float4x4
    ) throws {
        // Validate gradient stops
        try config.validate()

        encoder.setRenderPipelineState(gradientPipeline)

        let color0 = config.stops[0].color
        let color1 = config.stops[1].color

        var uniforms = BgGradientUniforms(
            mvp: mvp,
            animToViewport: animToViewport,
            targetSize: targetSize,
            color0: simd_float4(Float(color0.red), Float(color0.green), Float(color0.blue), Float(color0.alpha)),
            color1: simd_float4(Float(color1.red), Float(color1.green), Float(color1.blue), Float(color1.alpha)),
            p0: simd_float2(Float(config.p0.x), Float(config.p0.y)),
            p1: simd_float2(Float(config.p1.x), Float(config.p1.y))
        )

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        // Pass full uniforms to vertex shader (includes mvp + animToViewport + targetSize)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<BgGradientUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BgGradientUniforms>.stride, index: 1)
        encoder.setFragmentTexture(maskTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: quadIndexCount,
            indexType: .uint16,
            indexBuffer: quadIndexBuffer,
            indexBufferOffset: 0
        )
    }

    // MARK: - Image Rendering

    private func renderImage(
        config: ImageConfig,
        preset: BackgroundRegionPreset,
        encoder: MTLRenderCommandEncoder,
        vertexBuffer: MTLBuffer,
        maskTexture: MTLTexture,
        mvp: simd_float4x4,
        targetSize: simd_float2,
        animToViewport: simd_float4x4,
        textureProvider: TextureProvider,
        bbox: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    ) {
        // Get image texture - skip if not available
        guard let imageTexture = textureProvider.texture(for: config.slotKey) else {
            // No texture - skip this region (as per spec)
            return
        }

        encoder.setRenderPipelineState(imagePipeline)

        // Calculate UV transform
        let uvTransform = calculateUVTransform(
            transform: config.transform,
            bbox: bbox,
            textureWidth: imageTexture.width,
            textureHeight: imageTexture.height
        )

        var uniforms = BgImageUniforms(mvp: mvp, animToViewport: animToViewport, targetSize: targetSize, uvTransform: uvTransform)

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        // Pass full uniforms to vertex shader (includes mvp + animToViewport + targetSize)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<BgImageUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BgImageUniforms>.stride, index: 1)
        encoder.setFragmentTexture(maskTexture, index: 0)
        encoder.setFragmentTexture(imageTexture, index: 1)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: quadIndexCount,
            indexType: .uint16,
            indexBuffer: quadIndexBuffer,
            indexBufferOffset: 0
        )
    }

    // MARK: - UV Transform Calculation

    private func calculateUVTransform(
        transform: ImageTransform,
        bbox: (minX: Double, minY: Double, maxX: Double, maxY: Double),
        textureWidth: Int,
        textureHeight: Int
    ) -> simd_float4x4 {
        let bboxW = bbox.maxX - bbox.minX
        let bboxH = bbox.maxY - bbox.minY
        let texW = Double(textureWidth)
        let texH = Double(textureHeight)

        // 1. Calculate base scale from fitMode
        let baseScale: Double
        switch transform.fitMode {
        case .fill:
            // Cover: use max scale to cover entire bbox
            baseScale = max(bboxW / texW, bboxH / texH)
        case .fit:
            // Contain: use min scale to fit within bbox
            baseScale = min(bboxW / texW, bboxH / texH)
        }

        // Scaled texture dimensions
        let scaledTexW = texW * baseScale
        let scaledTexH = texH * baseScale

        // Center offset (to center the image in bbox)
        let centerOffsetX = Float((bboxW - scaledTexW) / 2.0 / bboxW)
        let centerOffsetY = Float((bboxH - scaledTexH) / 2.0 / bboxH)

        // 2. Build transform matrix using proper matrix composition
        // Order per spec: fitMode → flip → zoom → rotate → pan

        // Base scale: bbox to texture
        let scaleX = Float(bboxW / scaledTexW)
        let scaleY = Float(bboxH / scaledTexH)

        // Apply flip
        let flipX: Float = transform.flipX ? -1.0 : 1.0
        let flipY: Float = transform.flipY ? -1.0 : 1.0

        // Apply user zoom (zoom > 1 means zoom in, so divide scale)
        let userZoom = Float(max(transform.zoom, 0.001)) // Prevent division by zero

        // Combined scale with flip and zoom
        let finalScaleX = scaleX * flipX / userZoom
        let finalScaleY = scaleY * flipY / userZoom

        // Rotation angle
        let rotAngle = Float(transform.rotationRadians)
        let cosR = cos(rotAngle)
        let sinR = sin(rotAngle)

        // User pan (in normalized bbox space)
        let panX = Float(transform.pan.x)
        let panY = Float(transform.pan.y)

        // Build the UV transform as composition of matrices
        // We want to: center → rotate → scale → flip adjustment → offset → pan

        // The transform applied to UV = (u, v):
        //   1. Translate by (-0.5, -0.5) to center at origin
        //   2. Scale by (finalScaleX, finalScaleY) including flip and zoom
        //   3. Rotate by rotAngle
        //   4. Translate back by (0.5, 0.5)
        //   5. Add center offset and flip adjustments
        //   6. Subtract pan

        // Composed matrix: T(offset) * R(θ) * S(scale) * T(-0.5, -0.5) + pan adjustments
        // This centers rotation around (0.5, 0.5) in UV space

        // For a 2D affine transform:
        // | a  b  tx |   | cosR*sx  -sinR*sy  tx |
        // | c  d  ty | = | sinR*sx   cosR*sy  ty |
        // | 0  0  1  |   | 0         0        1  |

        let a = cosR * finalScaleX
        let b = -sinR * finalScaleY
        let c = sinR * finalScaleX
        let d = cosR * finalScaleY

        // Translation: T(0.5, 0.5) * R * S * T(-0.5, -0.5) gives us:
        // tx = 0.5 - 0.5 * (a + b) + extraOffset
        // ty = 0.5 - 0.5 * (c + d) + extraOffset
        var tx = 0.5 - 0.5 * (a + b) + centerOffsetX - panX
        var ty = 0.5 - 0.5 * (c + d) + centerOffsetY - panY

        // Flip adjustments: when flipped, shift by 1.0 in that axis
        if transform.flipX {
            tx += 1.0
        }
        if transform.flipY {
            ty += 1.0
        }

        // Build the result matrix (column-major)
        var result = matrix_identity_float4x4
        result.columns.0 = simd_float4(a, c, 0, 0)
        result.columns.1 = simd_float4(b, d, 0, 0)
        result.columns.2 = simd_float4(0, 0, 1, 0)
        result.columns.3 = simd_float4(tx, ty, 0, 1)

        return result
    }

    // MARK: - Resource Helpers

    private func makeQuadVertexBuffer(x: Float, y: Float, width: Float, height: Float) -> MTLBuffer? {
        let vertices: [QuadVertex] = [
            QuadVertex(position: SIMD2<Float>(x, y), texCoord: SIMD2<Float>(0, 0)),
            QuadVertex(position: SIMD2<Float>(x + width, y), texCoord: SIMD2<Float>(1, 0)),
            QuadVertex(position: SIMD2<Float>(x, y + height), texCoord: SIMD2<Float>(0, 1)),
            QuadVertex(position: SIMD2<Float>(x + width, y + height), texCoord: SIMD2<Float>(1, 1))
        ]
        let size = vertices.count * MemoryLayout<QuadVertex>.stride
        return device.makeBuffer(bytes: vertices, length: size, options: .storageModeShared)
    }
}

// MARK: - Pipeline Creation

extension BackgroundRenderer {
    private static func loadShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let url = Bundle.module.url(forResource: "default", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: url) {
            return lib
        }
        if let lib = device.makeDefaultLibrary() {
            return lib
        }
        throw MetalRendererError.failedToCreatePipeline(reason: "Failed to load Metal library")
    }

    private static func makeSolidPipeline(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "bg_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "bg_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "bg_solid_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "bg_solid_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.vertexDescriptor = makeVertexDescriptor()
        configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeGradientPipeline(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "bg_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "bg_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "bg_gradient_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "bg_gradient_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.vertexDescriptor = makeVertexDescriptor()
        configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeImagePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "bg_vertex") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "bg_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "bg_image_fragment") else {
            throw MetalRendererError.failedToCreatePipeline(reason: "bg_image_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.vertexDescriptor = makeVertexDescriptor()
        configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)

        return try device.makeRenderPipelineState(descriptor: descriptor)
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
        // Premultiplied alpha blending
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
            throw MetalRendererError.failedToCreatePipeline(reason: "Background sampler creation failed")
        }
        return sampler
    }

    private static func makeIndexBuffer(device: MTLDevice) throws -> MTLBuffer {
        let indices: [UInt16] = [0, 1, 2, 2, 1, 3]
        let size = indices.count * MemoryLayout<UInt16>.stride
        guard let buffer = device.makeBuffer(bytes: indices, length: size, options: .storageModeShared) else {
            throw MetalRendererError.failedToCreatePipeline(reason: "Background index buffer creation failed")
        }
        return buffer
    }
}
