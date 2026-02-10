@preconcurrency import Metal
import simd

// MARK: - Render Target

/// Target for Metal rendering operations.
/// Unifies on-screen (MTKView drawable) and offscreen rendering.
public struct RenderTarget: Sendable {
    /// Target texture to render into
    public let texture: MTLTexture

    /// Target size in pixels
    public var sizePx: (width: Int, height: Int) {
        (texture.width, texture.height)
    }

    /// Drawable scale factor (UIScreen.main.scale for MTKView, 1.0 for tests)
    public let drawableScale: Double

    /// Animation size for contain mapping
    public let animSize: SizeD

    /// Creates a render target.
    /// - Parameters:
    ///   - texture: Target texture to render into
    ///   - drawableScale: Scale factor (typically UIScreen.main.scale)
    ///   - animSize: Animation size for contain mapping
    public init(texture: MTLTexture, drawableScale: Double, animSize: SizeD) {
        self.texture = texture
        self.drawableScale = drawableScale
        self.animSize = animSize
    }
}

// MARK: - Metal Renderer Error

/// Errors that can occur during Metal rendering.
public enum MetalRendererError: Error, Sendable, Equatable {
    /// Texture for the given asset ID was not found
    case noTextureForAsset(assetId: String)

    /// Failed to create Metal command buffer
    case failedToCreateCommandBuffer

    /// Failed to create render pipeline
    case failedToCreatePipeline(reason: String)

    /// Command stack is invalid (unbalanced push/pop)
    case invalidCommandStack(reason: String)

    /// Path resource for the given PathID was not found in registry
    case missingPathResource(pathId: PathID)
}

extension MetalRendererError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noTextureForAsset(let assetId):
            return "No texture found for asset: \(assetId)"
        case .failedToCreateCommandBuffer:
            return "Failed to create Metal command buffer"
        case .failedToCreatePipeline(let reason):
            return "Failed to create render pipeline: \(reason)"
        case .invalidCommandStack(let reason):
            return "Invalid command stack: \(reason)"
        case .missingPathResource(let pathId):
            return "No path resource found for pathId: \(pathId)"
        }
    }
}

// MARK: - Clear Color

/// RGBA color for clearing render targets (values 0-1).
public struct ClearColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Transparent black (0, 0, 0, 0)
    public static let transparentBlack = Self(red: 0, green: 0, blue: 0, alpha: 0)

    /// Opaque black (0, 0, 0, 1)
    public static let opaqueBlack = Self(red: 0, green: 0, blue: 0, alpha: 1)
}

// MARK: - Metal Renderer Options

/// Configuration options for MetalRenderer.
public struct MetalRendererOptions: Sendable {
    /// Clear color for render target (RGBA, 0-1)
    public var clearColor: ClearColor

    /// Whether to log warnings for unsupported commands (masks/mattes)
    public var enableWarningsForUnsupportedCommands: Bool

    /// Enable diagnostic logging for scissor/transform debugging
    public var enableDiagnostics: Bool

    /// Enable performance metrics collection (PR-14C).
    /// Only effective in DEBUG builds. When true, `PerfMetrics` is created
    /// and collects per-frame counters + timings.
    /// Default: false (zero overhead even in DEBUG).
    public var enablePerfMetrics: Bool

    /// Maximum number of frames that can be in-flight simultaneously.
    /// This controls the size of the vertex upload ring buffer.
    /// Must match the semaphore count in your render loop for correctness.
    /// Default is 3 (triple buffering).
    public var maxFramesInFlight: Int

    /// Creates renderer options with defaults.
    /// - Parameters:
    ///   - clearColor: Clear color (default: transparent black)
    ///   - enableWarningsForUnsupportedCommands: Enable warnings (default: true)
    ///   - enableDiagnostics: Enable diagnostic logging (default: false)
    ///   - enablePerfMetrics: Enable perf metrics collection in DEBUG (default: false)
    ///   - maxFramesInFlight: Max in-flight frames for ring buffer (default: 3)
    public init(
        clearColor: ClearColor = .transparentBlack,
        enableWarningsForUnsupportedCommands: Bool = true,
        enableDiagnostics: Bool = false,
        enablePerfMetrics: Bool = false,
        maxFramesInFlight: Int = 3
    ) {
        self.clearColor = clearColor
        self.enableWarningsForUnsupportedCommands = enableWarningsForUnsupportedCommands
        self.enableDiagnostics = enableDiagnostics
        self.enablePerfMetrics = enablePerfMetrics
        self.maxFramesInFlight = max(1, maxFramesInFlight)
    }
}

// MARK: - Metal Renderer

/// Metal renderer for executing RenderCommand lists.
/// Supports DrawImage with transforms, scissor clipping, and mask rendering.
/// Mattes are ignored (no-op) in the current implementation.
public final class MetalRenderer {
    // MARK: - Properties

    let device: MTLDevice
    let resources: MetalRendererResources
    let options: MetalRendererOptions
    let texturePool: TexturePool
    let maskCache: MaskCache
    let shapeCache: ShapeCache
    private let logger: TVELogger?

    // PR-C3: GPU buffer caching for mask rendering
    let vertexUploadPool: VertexUploadPool
    let pathIndexBufferCache: PathIndexBufferCache

    // PR-14B: Two-level path sampling cache (frame memo + LRU)
    let pathSamplingCache: PathSamplingCache

    // PR-14C: Performance metrics (DEBUG-only, opt-in via options.enablePerfMetrics)
    #if DEBUG
    private(set) var perf: PerfMetrics?
    private var perfFrameIndex: Int = 0
    #endif

    // MARK: - Initialization

    /// Creates a Metal renderer.
    /// - Parameters:
    ///   - device: Metal device to use
    ///   - colorPixelFormat: Pixel format for color attachments
    ///   - options: Renderer configuration options
    ///   - logger: Optional logger for diagnostic messages
    /// - Throws: MetalRendererError if initialization fails
    public init(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        options: MetalRendererOptions = MetalRendererOptions(),
        logger: TVELogger? = nil
    ) throws {
        self.device = device
        self.options = options
        self.logger = logger
        self.resources = try MetalRendererResources(device: device, colorPixelFormat: colorPixelFormat)
        self.texturePool = TexturePool(device: device)
        self.maskCache = MaskCache(device: device)
        self.shapeCache = ShapeCache(device: device)
        self.vertexUploadPool = VertexUploadPool(device: device, buffersInFlight: options.maxFramesInFlight)
        self.pathIndexBufferCache = PathIndexBufferCache(device: device)
        self.pathSamplingCache = PathSamplingCache()

        #if DEBUG
        self.perf = options.enablePerfMetrics ? PerfMetrics() : nil
        #endif
    }

    /// Diagnostic logging (only when enabled via options)
    func diagLog(_ message: String) {
        guard options.enableDiagnostics else { return }
        if let logger = logger {
            logger("[RENDERER] \(message)")
        } else {
            #if DEBUG
            print("[RENDERER] \(message)")
            #endif
        }
    }

    /// Clears pooled textures to free memory.
    /// Call this when the renderer won't be used for a while.
    public func clearCaches() {
        texturePool.clear()
        maskCache.clear()
        shapeCache.clear()
        pathIndexBufferCache.clear()
        pathSamplingCache.clear()
    }

    /// PR1.5: Warms up the renderer by forcing GPU shader compilation.
    /// Call this after scene compile but before first visible frame to avoid
    /// 200-400ms stalls from GPU driver JIT compilation.
    /// - Parameter commandQueue: Metal command queue for issuing warm-up commands
    /// - Note: Deprecated in favor of `warmRender(...)` which uses real scene commands.
    @available(*, deprecated, message: "Use warmRender(...) for production warm-up with real scene commands")
    public func warmUp(commandQueue: MTLCommandQueue) {
        // Create a small offscreen texture for warm-up rendering
        // PR1: Use .private storage for GPU-only access
        let warmUpSize = 16
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: warmUpSize,
            height: warmUpSize,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private

        guard let warmUpTexture = device.makeTexture(descriptor: textureDescriptor),
              let cmdBuf = commandQueue.makeCommandBuffer() else {
            return
        }

        // Create R8 texture for mask warm-up
        // PR1: Use .private storage for GPU-only access
        let r8Descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: warmUpSize,
            height: warmUpSize,
            mipmapped: false
        )
        r8Descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        r8Descriptor.storageMode = .private

        guard let r8Texture = device.makeTexture(descriptor: r8Descriptor) else {
            return
        }

        // 1. Warm up basic quad pipeline
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = warmUpTexture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) {
            encoder.setRenderPipelineState(resources.pipelineState)
            encoder.endEncoding()
        }

        // 2. Warm up matte composite pipeline
        if let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) {
            encoder.setRenderPipelineState(resources.matteCompositePipelineState)
            encoder.endEncoding()
        }

        // 3. Warm up masked composite pipeline
        if let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) {
            encoder.setRenderPipelineState(resources.maskedCompositePipelineState)
            encoder.endEncoding()
        }

        // 4. Warm up coverage pipeline (renders to R8)
        let coveragePass = MTLRenderPassDescriptor()
        coveragePass.colorAttachments[0].texture = r8Texture
        coveragePass.colorAttachments[0].loadAction = .clear
        coveragePass.colorAttachments[0].storeAction = .store
        coveragePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: coveragePass) {
            encoder.setRenderPipelineState(resources.coveragePipelineState)
            encoder.endEncoding()
        }

        // 5. Warm up mask combine compute pipeline
        if let encoder = cmdBuf.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(resources.maskCombineComputePipeline)
            encoder.endEncoding()
        }

        // 6. Warm up stencil pipelines
        let stencilDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float_stencil8,
            width: warmUpSize,
            height: warmUpSize,
            mipmapped: false
        )
        stencilDescriptor.usage = [.renderTarget]
        stencilDescriptor.storageMode = .private

        if let stencilTex = device.makeTexture(descriptor: stencilDescriptor) {
            // 6a. maskWritePipelineState: NO color attachment, stencil only
            let maskWritePass = MTLRenderPassDescriptor()
            maskWritePass.depthAttachment.texture = stencilTex
            maskWritePass.depthAttachment.loadAction = .clear
            maskWritePass.depthAttachment.storeAction = .dontCare
            maskWritePass.stencilAttachment.texture = stencilTex
            maskWritePass.stencilAttachment.loadAction = .clear
            maskWritePass.stencilAttachment.storeAction = .dontCare
            maskWritePass.stencilAttachment.clearStencil = 0

            if let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: maskWritePass) {
                encoder.setRenderPipelineState(resources.maskWritePipelineState)
                encoder.setDepthStencilState(resources.stencilWriteDepthStencilState)
                encoder.endEncoding()
            }

            // 6b. stencilCompositePipelineState: HAS color attachment + stencil
            let stencilCompositePass = MTLRenderPassDescriptor()
            stencilCompositePass.colorAttachments[0].texture = warmUpTexture
            stencilCompositePass.colorAttachments[0].loadAction = .load
            stencilCompositePass.colorAttachments[0].storeAction = .store
            stencilCompositePass.depthAttachment.texture = stencilTex
            stencilCompositePass.depthAttachment.loadAction = .load
            stencilCompositePass.depthAttachment.storeAction = .dontCare
            stencilCompositePass.stencilAttachment.texture = stencilTex
            stencilCompositePass.stencilAttachment.loadAction = .load
            stencilCompositePass.stencilAttachment.storeAction = .dontCare

            if let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: stencilCompositePass) {
                encoder.setRenderPipelineState(resources.stencilCompositePipelineState)
                encoder.setDepthStencilState(resources.stencilTestDepthStencilState)
                encoder.endEncoding()
            }
        }

        // Commit and wait for GPU to finish (ensures all shaders are compiled)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        diagLog("warmUp() completed - all shaders compiled")
    }

    // MARK: - Public API

    /// Renders commands to an on-screen drawable.
    /// - Parameters:
    ///   - commands: Render commands from AnimIR
    ///   - target: Render target (drawable texture)
    ///   - textureProvider: Provider for asset textures
    ///   - commandBuffer: Metal command buffer to use
    ///   - assetSizes: Asset sizes from AnimIR for correct quad geometry
    ///   - pathRegistry: Registry of path resources for GPU rendering
    /// - Throws: MetalRendererError if rendering fails
    public func draw(
        commands: [RenderCommand],
        target: RenderTarget,
        textureProvider: TextureProvider,
        commandBuffer: MTLCommandBuffer,
        assetSizes: [String: AssetSize] = [:],
        pathRegistry: PathRegistry
    ) throws {
        // PR-C3: Rotate to next buffer in ring for in-flight frame safety
        vertexUploadPool.beginFrame()
        // PR-14B: Clear per-frame path sampling memo (LRU preserved across frames)
        pathSamplingCache.beginFrame()

        #if DEBUG
        perf?.beginFrame(index: perfFrameIndex)
        perf?.beginPhase(.frameTotal)
        perfFrameIndex += 1
        #endif

        // PR-22: Validate command structure in DEBUG before execution.
        // Catches cross-boundary transform/clip issues at the source.
        #if DEBUG
        let validationErrors = RenderCommandValidator.validateScopeBalance(commands)
        if !validationErrors.isEmpty {
            for err in validationErrors {
                print("[TVECore] \u{274c} RenderCommandValidator: \(err)")
            }
            if RenderCommandValidator.assertOnFailure {
                assertionFailure("[TVECore] RenderCommand structural validation failed (\(validationErrors.count) error(s))")
            }
        }
        #endif

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = target.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: options.clearColor.red,
            green: options.clearColor.green,
            blue: options.clearColor.blue,
            alpha: options.clearColor.alpha
        )

        try drawInternal(
            commands: commands,
            renderPassDescriptor: renderPassDescriptor,
            target: target,
            textureProvider: textureProvider,
            commandBuffer: commandBuffer,
            assetSizes: assetSizes,
            pathRegistry: pathRegistry
        )

        #if DEBUG
        perf?.endPhase(.frameTotal)
        perf?.endFrame()
        #endif
    }

    /// Renders commands to an offscreen texture.
    /// - Parameters:
    ///   - commands: Render commands from AnimIR
    ///   - device: Metal device to use
    ///   - sizePx: Target size in pixels
    ///   - animSize: Animation size for contain mapping
    ///   - textureProvider: Provider for asset textures
    ///   - assetSizes: Asset sizes from AnimIR for correct quad geometry
    ///   - pathRegistry: Registry of path resources for GPU rendering
    /// - Returns: Rendered texture
    /// - Throws: MetalRendererError if rendering fails
    public func drawOffscreen(
        commands: [RenderCommand],
        device: MTLDevice,
        sizePx: (width: Int, height: Int),
        animSize: SizeD,
        textureProvider: TextureProvider,
        assetSizes: [String: AssetSize] = [:],
        pathRegistry: PathRegistry
    ) throws -> MTLTexture {
        // PR-C3: Rotate to next buffer in ring for in-flight frame safety
        vertexUploadPool.beginFrame()
        // PR-14B: Clear per-frame path sampling memo
        pathSamplingCache.beginFrame()

        #if DEBUG
        perf?.beginFrame(index: perfFrameIndex)
        perf?.beginPhase(.frameTotal)
        perfFrameIndex += 1
        #endif

        // Create offscreen texture
        // PR1: Use .private storage — GPU-only render target, no CPU access needed
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: sizePx.width,
            height: sizePx.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw MetalRendererError.failedToCreatePipeline(
                reason: "Failed to create offscreen texture"
            )
        }

        // Create command queue and buffer
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.failedToCreateCommandBuffer
        }

        let target = RenderTarget(
            texture: texture,
            drawableScale: 1.0,
            animSize: animSize
        )

        // PR-22: Validate command structure in DEBUG before execution.
        #if DEBUG
        let offscreenValidationErrors = RenderCommandValidator.validateScopeBalance(commands)
        if !offscreenValidationErrors.isEmpty {
            for err in offscreenValidationErrors {
                print("[TVECore] \u{274c} RenderCommandValidator: \(err)")
            }
            if RenderCommandValidator.assertOnFailure {
                assertionFailure("[TVECore] RenderCommand structural validation failed (\(offscreenValidationErrors.count) error(s))")
            }
        }
        #endif

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: options.clearColor.red,
            green: options.clearColor.green,
            blue: options.clearColor.blue,
            alpha: options.clearColor.alpha
        )

        try drawInternal(
            commands: commands,
            renderPassDescriptor: renderPassDescriptor,
            target: target,
            textureProvider: textureProvider,
            commandBuffer: commandBuffer,
            assetSizes: assetSizes,
            pathRegistry: pathRegistry
        )

        #if DEBUG
        perf?.endPhase(.frameTotal)
        perf?.endFrame()
        #endif

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return texture
    }

    // MARK: - Warm Render API (PR1)

    /// PR1: Production-grade GPU warm-up using real scene render commands.
    ///
    /// Renders specified frames offscreen to force GPU shader compilation and texture cache warm-up.
    /// Uses a single command buffer with multiple encode passes for efficiency.
    /// Does NOT block UI — completion is called asynchronously when GPU finishes.
    ///
    /// - Parameters:
    ///   - commandQueue: Metal command queue for issuing render commands
    ///   - targetSizePx: Target texture size in pixels (typically canvas size)
    ///   - animSize: Animation size for contain mapping
    ///   - frames: Frame indices to render (e.g., [0, totalFrames/2])
    ///   - commandsProvider: Closure that returns render commands for a given frame index
    ///   - textureProvider: Provider for asset textures
    ///   - assetSizes: Asset sizes from AnimIR for correct quad geometry
    ///   - pathRegistry: Registry of path resources for GPU rendering
    ///   - renderLockQueue: Serial queue for synchronizing renderer access (prevents races with draw)
    ///   - completion: Called on GPU completion (not on main thread)
    public func warmRender(
        commandQueue: MTLCommandQueue,
        targetSizePx: (width: Int, height: Int),
        animSize: SizeD,
        frames: [Int],
        commandsProvider: (Int) -> [RenderCommand],
        textureProvider: TextureProvider,
        assetSizes: [String: AssetSize],
        pathRegistry: PathRegistry,
        renderLockQueue: DispatchQueue,
        completion: @escaping @Sendable () -> Void
    ) {
        guard !frames.isEmpty else {
            completion()
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion()
            return
        }

        // Safe in-flight texture storage — released in completion handler
        var inFlightTextures: [MTLTexture] = []

        // Encode all frames in sequence within single command buffer
        for frameIndex in frames {
            // PR1-fix: Synchronize renderer access via renderLockQueue
            // This prevents races with draw(in:) which uses the same queue
            renderLockQueue.sync { [self] in
                // PR1-fix: Call beginFrame() before each frame (contract requirement)
                vertexUploadPool.beginFrame()
                pathSamplingCache.beginFrame()

                // Acquire offscreen target from pool (now .private per PR1)
                guard let targetTexture = texturePool.acquireColorTexture(size: targetSizePx) else {
                    return
                }
                inFlightTextures.append(targetTexture)

                let target = RenderTarget(
                    texture: targetTexture,
                    drawableScale: 1.0,
                    animSize: animSize
                )

                let renderPassDescriptor = MTLRenderPassDescriptor()
                renderPassDescriptor.colorAttachments[0].texture = targetTexture
                renderPassDescriptor.colorAttachments[0].loadAction = .clear
                renderPassDescriptor.colorAttachments[0].storeAction = .store
                renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                    red: options.clearColor.red,
                    green: options.clearColor.green,
                    blue: options.clearColor.blue,
                    alpha: options.clearColor.alpha
                )

                let commands = commandsProvider(frameIndex)

                do {
                    try drawInternal(
                        commands: commands,
                        renderPassDescriptor: renderPassDescriptor,
                        target: target,
                        textureProvider: textureProvider,
                        commandBuffer: commandBuffer,
                        assetSizes: assetSizes,
                        pathRegistry: pathRegistry
                    )
                } catch {
                    // Log error but continue with other frames
                    diagLog("warmRender frame \(frameIndex) failed: \(error)")
                }
            }
        }

        // Release textures and call completion when GPU finishes
        // PR1-fix: Use renderLockQueue.async to prevent data race with draw(in:)
        // (completion handler runs on arbitrary Metal queue)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else {
                completion()
                return
            }
            renderLockQueue.async {
                // Release all in-flight textures back to pool (now synchronized)
                for texture in inFlightTextures {
                    self.texturePool.release(texture)
                }
            }
            completion()
        }

        // Commit without waiting — async completion
        commandBuffer.commit()
    }
}
