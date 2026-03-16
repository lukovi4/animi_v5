import Metal
import simd

// MARK: - Transition Compositor

/// Composites two scene textures with a transition effect.
/// Used for multi-scene timeline rendering during transition windows.
///
/// Supports all v1 transition types:
/// - none: instant cut (B only)
/// - fade: fade-over (A unchanged, B fades in 0→100%)
/// - slide: B slides in over A
/// - push: B pushes A out
/// - dipToBlack/dipToWhite: dip through solid color
///
/// Usage:
/// ```swift
/// // During transition window
/// let textureA = renderer.drawOffscreen(sceneA)
/// let textureB = renderer.drawOffscreen(sceneB)
///
/// try compositor.composite(
///     sceneA: textureA,
///     sceneB: textureB,
///     transition: transition,
///     progress: 0.5,
///     target: finalTarget,
///     commandBuffer: cmdBuf
/// )
/// ```
public final class TransitionCompositor {

    // MARK: - Properties

    private let device: MTLDevice
    private let resources: TransitionCompositorResources

    // MARK: - Init

    /// Creates a transition compositor.
    /// - Parameters:
    ///   - device: Metal device.
    ///   - colorPixelFormat: Pixel format for render targets.
    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws {
        self.device = device
        self.resources = try TransitionCompositorResources(
            device: device,
            colorPixelFormat: colorPixelFormat
        )
    }

    // MARK: - Composite API

    /// Composites two scene textures with a transition effect.
    /// - Parameters:
    ///   - sceneA: Outgoing scene texture (premultiplied alpha).
    ///   - sceneB: Incoming scene texture (premultiplied alpha).
    ///   - transition: Transition parameters.
    ///   - progress: Progress through transition (0.0 to 1.0).
    ///   - canvasSize: Canvas size in points.
    ///   - target: Render target texture.
    ///   - commandBuffer: Metal command buffer.
    public func composite(
        sceneA: MTLTexture,
        sceneB: MTLTexture,
        transition: TransitionParams,
        progress: Double,
        canvasSize: SizeD,
        target: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        // Contract: target is already prepared by caller (cleared + background rendered).
        // Compositor must use loadAction = .load for first pass to preserve target contents.
        switch transition.type {
        case .none:
            // Instant cut - just draw B over existing background
            try drawTexturedQuad(
                texture: sceneB,
                opacity: 1.0,
                transform: matrix_identity_float4x4,
                target: target,
                commandBuffer: commandBuffer,
                canvasSize: canvasSize,
                loadAction: .load  // Preserve background
            )

        case .fade:
            // Fade-over: A unchanged (100%), B fades in (0% → 100%)
            let easedProgress = applyEasing(progress, preset: transition.easing)

            // Draw A at full opacity (preserve background)
            try drawTexturedQuad(
                texture: sceneA,
                opacity: 1.0,
                transform: matrix_identity_float4x4,
                target: target,
                commandBuffer: commandBuffer,
                canvasSize: canvasSize,
                loadAction: .load  // Preserve background
            )

            // Draw B fading in over A
            try drawTexturedQuad(
                texture: sceneB,
                opacity: easedProgress,
                transform: matrix_identity_float4x4,
                target: target,
                commandBuffer: commandBuffer,
                canvasSize: canvasSize,
                loadAction: .load  // Preserve A underneath
            )

        case .slide(let direction):
            // B slides in over A (A stays in place)
            let easedProgress = applyEasing(progress, preset: transition.easing)

            // Draw A (stationary, preserve background)
            try drawTexturedQuad(
                texture: sceneA,
                opacity: 1.0,
                transform: matrix_identity_float4x4,
                target: target,
                commandBuffer: commandBuffer,
                canvasSize: canvasSize,
                loadAction: .load  // Preserve background
            )

            // Draw B sliding in
            let slideOffset = slideTransform(
                direction: direction,
                progress: Double(easedProgress),
                canvasSize: canvasSize
            )
            try drawTexturedQuad(
                texture: sceneB,
                opacity: 1.0,
                transform: slideOffset,
                target: target,
                commandBuffer: commandBuffer,
                canvasSize: canvasSize,
                loadAction: .load  // Preserve A underneath
            )

        case .push(let direction):
            // B pushes A out (both move)
            let easedProgress = applyEasing(progress, preset: transition.easing)

            // Calculate offsets for push effect
            let (offsetA, offsetB) = pushTransforms(
                direction: direction,
                progress: Double(easedProgress),
                canvasSize: canvasSize
            )

            // Draw A sliding out (preserve background)
            try drawTexturedQuad(
                texture: sceneA,
                opacity: 1.0,
                transform: offsetA,
                target: target,
                commandBuffer: commandBuffer,
                canvasSize: canvasSize,
                loadAction: .load  // Preserve background
            )

            // Draw B sliding in
            try drawTexturedQuad(
                texture: sceneB,
                opacity: 1.0,
                transform: offsetB,
                target: target,
                commandBuffer: commandBuffer,
                canvasSize: canvasSize,
                loadAction: .load  // Preserve A
            )

        case .dipToBlack:
            try drawDipTransition(
                sceneA: sceneA,
                sceneB: sceneB,
                progress: Double(applyEasing(progress, preset: transition.easing)),
                dipColor: SIMD4<Float>(0, 0, 0, 1),
                target: target,
                commandBuffer: commandBuffer,
                canvasSize: canvasSize
            )

        case .dipToWhite:
            try drawDipTransition(
                sceneA: sceneA,
                sceneB: sceneB,
                progress: Double(applyEasing(progress, preset: transition.easing)),
                dipColor: SIMD4<Float>(1, 1, 1, 1),
                target: target,
                commandBuffer: commandBuffer,
                canvasSize: canvasSize
            )
        }
    }

    // MARK: - Private Rendering

    private func drawTexturedQuad(
        texture: MTLTexture,
        opacity: Float,
        transform: simd_float4x4,
        target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        canvasSize: SizeD,
        loadAction: MTLLoadAction = .clear
    ) throws {
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = target
        passDescriptor.colorAttachments[0].loadAction = loadAction
        passDescriptor.colorAttachments[0].storeAction = .store
        if loadAction == .clear {
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            throw TransitionCompositorError.failedToCreateEncoder
        }

        encoder.setRenderPipelineState(resources.quadPipelineState)

        // Create full-screen quad vertices
        let width = Float(target.width)
        let height = Float(target.height)
        let vertices: [QuadVertex] = [
            QuadVertex(position: SIMD2<Float>(0, 0), texCoord: SIMD2<Float>(0, 0)),
            QuadVertex(position: SIMD2<Float>(width, 0), texCoord: SIMD2<Float>(1, 0)),
            QuadVertex(position: SIMD2<Float>(0, height), texCoord: SIMD2<Float>(0, 1)),
            QuadVertex(position: SIMD2<Float>(width, height), texCoord: SIMD2<Float>(1, 1))
        ]

        let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<QuadVertex>.stride,
            options: .storageModeShared
        )

        // Create projection matrix
        let projection = orthographicProjection(width: width, height: height)
        let mvp = projection * transform

        var uniforms = QuadUniforms(mvp: mvp, opacity: opacity)

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: 6,
            indexType: .uint16,
            indexBuffer: resources.indexBuffer,
            indexBufferOffset: 0
        )

        encoder.endEncoding()
    }

    private func drawDipTransition(
        sceneA: MTLTexture,
        sceneB: MTLTexture,
        progress: Double,
        dipColor: SIMD4<Float>,
        target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        canvasSize: SizeD
    ) throws {
        // Contract: target already prepared by caller, use .load to preserve background
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = target
        passDescriptor.colorAttachments[0].loadAction = .load
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            throw TransitionCompositorError.failedToCreateEncoder
        }

        encoder.setRenderPipelineState(resources.dipTransitionPipelineState)

        // Create full-screen quad vertices
        let width = Float(target.width)
        let height = Float(target.height)
        let vertices: [QuadVertex] = [
            QuadVertex(position: SIMD2<Float>(0, 0), texCoord: SIMD2<Float>(0, 0)),
            QuadVertex(position: SIMD2<Float>(width, 0), texCoord: SIMD2<Float>(1, 0)),
            QuadVertex(position: SIMD2<Float>(0, height), texCoord: SIMD2<Float>(0, 1)),
            QuadVertex(position: SIMD2<Float>(width, height), texCoord: SIMD2<Float>(1, 1))
        ]

        let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<QuadVertex>.stride,
            options: .storageModeShared
        )

        // Create projection matrix
        let projection = orthographicProjection(width: width, height: height)

        var uniforms = TransitionDipUniforms(
            mvp: projection,
            progress: Float(progress),
            dipColor: dipColor
        )

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TransitionDipUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TransitionDipUniforms>.stride, index: 1)
        encoder.setFragmentTexture(sceneA, index: 0)
        encoder.setFragmentTexture(sceneB, index: 1)
        encoder.setFragmentSamplerState(resources.samplerState, index: 0)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: 6,
            indexType: .uint16,
            indexBuffer: resources.indexBuffer,
            indexBufferOffset: 0
        )

        encoder.endEncoding()
    }

    // MARK: - Transform Helpers

    private func orthographicProjection(width: Float, height: Float) -> simd_float4x4 {
        // Standard orthographic projection for 2D rendering
        // Maps (0,0)-(width,height) to clip space (-1,-1)-(1,1)
        let sx = 2.0 / width
        let sy = -2.0 / height  // Flip Y for Metal coordinates
        let tx = -1.0 as Float
        let ty = 1.0 as Float

        return simd_float4x4(columns: (
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(tx, ty, 0, 1)
        ))
    }

    private func slideTransform(
        direction: TransitionDirection,
        progress: Double,
        canvasSize: SizeD
    ) -> simd_float4x4 {
        // Slide: B enters from direction
        // At progress=0: B is fully off-screen
        // At progress=1: B is fully on-screen
        let remaining = 1.0 - progress

        var tx: Float = 0
        var ty: Float = 0

        switch direction {
        case .left:
            // B enters from left, so starts at -width and moves to 0
            tx = Float(-canvasSize.width * remaining)
        case .right:
            // B enters from right, so starts at +width and moves to 0
            tx = Float(canvasSize.width * remaining)
        case .up:
            // B enters from top (up in screen coords), so starts at -height and moves to 0
            ty = Float(-canvasSize.height * remaining)
        case .down:
            // B enters from bottom, so starts at +height and moves to 0
            ty = Float(canvasSize.height * remaining)
        }

        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(tx, ty, 0, 1)
        ))
    }

    private func pushTransforms(
        direction: TransitionDirection,
        progress: Double,
        canvasSize: SizeD
    ) -> (simd_float4x4, simd_float4x4) {
        // Push: A and B move together
        // A moves out in opposite direction of where B comes from
        // At progress=0: A at 0, B off-screen
        // At progress=1: A off-screen, B at 0

        var txA: Float = 0
        var tyA: Float = 0
        var txB: Float = 0
        var tyB: Float = 0

        switch direction {
        case .left:
            // B enters from left, pushes A to the right
            txA = Float(canvasSize.width * progress)
            txB = Float(-canvasSize.width * (1.0 - progress))
        case .right:
            // B enters from right, pushes A to the left
            txA = Float(-canvasSize.width * progress)
            txB = Float(canvasSize.width * (1.0 - progress))
        case .up:
            // B enters from top, pushes A down
            tyA = Float(canvasSize.height * progress)
            tyB = Float(-canvasSize.height * (1.0 - progress))
        case .down:
            // B enters from bottom, pushes A up
            tyA = Float(-canvasSize.height * progress)
            tyB = Float(canvasSize.height * (1.0 - progress))
        }

        let transformA = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(txA, tyA, 0, 1)
        ))

        let transformB = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(txB, tyB, 0, 1)
        ))

        return (transformA, transformB)
    }

    // MARK: - Easing

    private func applyEasing(_ t: Double, preset: TransitionEasingPreset) -> Float {
        let clamped = max(0, min(1, t))

        switch preset {
        case .linear:
            return Float(clamped)
        case .easeInOut:
            // Smooth step: 3t² - 2t³
            let t2 = clamped * clamped
            let t3 = t2 * clamped
            return Float(3 * t2 - 2 * t3)
        }
    }
}

// MARK: - Transition Parameters

/// Parameters for transition compositing.
/// Decoupled from SceneTransition for TVECore independence.
public struct TransitionParams: Sendable {
    public let type: TransitionType
    public let easing: TransitionEasingPreset

    public init(type: TransitionType, easing: TransitionEasingPreset) {
        self.type = type
        self.easing = easing
    }

    /// No transition (instant cut).
    public static let none = TransitionParams(type: .none, easing: .linear)
}

// MARK: - Transition Type (TVECore)

/// Type of visual transition effect.
/// Mirrors AnimiApp's TransitionType but lives in TVECore for independence.
public enum TransitionType: Sendable, Equatable {
    case none
    case fade
    case slide(direction: TransitionDirection)
    case push(direction: TransitionDirection)
    case dipToBlack
    case dipToWhite
}

// MARK: - Transition Direction (TVECore)

/// Direction for slide/push transitions.
public enum TransitionDirection: Sendable, Equatable {
    case left
    case right
    case up
    case down
}

// MARK: - Transition Easing Preset (TVECore)

/// Easing preset for transitions.
public enum TransitionEasingPreset: Sendable, Equatable {
    case linear
    case easeInOut
}

// MARK: - Errors

public enum TransitionCompositorError: Error, LocalizedError {
    case failedToCreateEncoder
    case failedToCreatePipeline(reason: String)

    public var errorDescription: String? {
        switch self {
        case .failedToCreateEncoder:
            return "Failed to create render command encoder"
        case .failedToCreatePipeline(let reason):
            return "Failed to create pipeline: \(reason)"
        }
    }
}

// MARK: - Resources

/// Metal resources for TransitionCompositor.
final class TransitionCompositorResources {

    let quadPipelineState: MTLRenderPipelineState
    let dipTransitionPipelineState: MTLRenderPipelineState
    let samplerState: MTLSamplerState
    let indexBuffer: MTLBuffer

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws {
        let library = try Self.makeShaderLibrary(device: device)

        // Quad pipeline (for fade/slide/push)
        self.quadPipelineState = try Self.makeQuadPipeline(
            device: device,
            library: library,
            colorPixelFormat: colorPixelFormat
        )

        // Dip transition pipeline
        self.dipTransitionPipelineState = try Self.makeDipTransitionPipeline(
            device: device,
            library: library,
            colorPixelFormat: colorPixelFormat
        )

        // Sampler
        self.samplerState = try Self.makeSamplerState(device: device)

        // Index buffer for quad rendering
        self.indexBuffer = try Self.makeIndexBuffer(device: device)
    }

    private static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let url = Bundle.module.url(forResource: "default", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: url) {
            return lib
        }
        if let lib = device.makeDefaultLibrary() {
            return lib
        }
        throw TransitionCompositorError.failedToCreatePipeline(
            reason: "Failed to load Metal library"
        )
    }

    private static func makeQuadPipeline(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "quad_vertex") else {
            throw TransitionCompositorError.failedToCreatePipeline(reason: "quad_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "quad_fragment") else {
            throw TransitionCompositorError.failedToCreatePipeline(reason: "quad_fragment not found")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.vertexDescriptor = makeVertexDescriptor()
        configureBlending(descriptor.colorAttachments[0], pixelFormat: colorPixelFormat)

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeDipTransitionPipeline(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: "dip_transition_vertex") else {
            throw TransitionCompositorError.failedToCreatePipeline(reason: "dip_transition_vertex not found")
        }
        guard let fragmentFunc = library.makeFunction(name: "dip_transition_fragment") else {
            throw TransitionCompositorError.failedToCreatePipeline(reason: "dip_transition_fragment not found")
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
            throw TransitionCompositorError.failedToCreatePipeline(reason: "Sampler creation failed")
        }
        return sampler
    }

    private static func makeIndexBuffer(device: MTLDevice) throws -> MTLBuffer {
        let indices: [UInt16] = [0, 1, 2, 2, 1, 3]
        let size = indices.count * MemoryLayout<UInt16>.stride
        guard let buffer = device.makeBuffer(bytes: indices, length: size, options: .storageModeShared) else {
            throw TransitionCompositorError.failedToCreatePipeline(reason: "Index buffer creation failed")
        }
        return buffer
    }
}
