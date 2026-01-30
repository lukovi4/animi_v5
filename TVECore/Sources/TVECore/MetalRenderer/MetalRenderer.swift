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
    ///   - maxFramesInFlight: Max in-flight frames for ring buffer (default: 3)
    public init(
        clearColor: ClearColor = .transparentBlack,
        enableWarningsForUnsupportedCommands: Bool = true,
        enableDiagnostics: Bool = false,
        maxFramesInFlight: Int = 3
    ) {
        self.clearColor = clearColor
        self.enableWarningsForUnsupportedCommands = enableWarningsForUnsupportedCommands
        self.enableDiagnostics = enableDiagnostics
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

        // Create offscreen texture
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: sizePx.width,
            height: sizePx.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared

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

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return texture
    }
}
