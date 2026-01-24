import Metal

// MARK: - Texture Pool Key

/// Key for texture pool lookup based on dimensions and format.
struct TexturePoolKey: Hashable {
    let width: Int
    let height: Int
    let pixelFormat: MTLPixelFormat

    init(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    init(size: (width: Int, height: Int), pixelFormat: MTLPixelFormat) {
        self.width = size.width
        self.height = size.height
        self.pixelFormat = pixelFormat
    }
}

// MARK: - Texture Pool

/// Manages reusable Metal textures to avoid per-frame allocations.
/// Textures are pooled by (width, height, pixelFormat) key.
final class TexturePool {
    private let device: MTLDevice
    private var available: [TexturePoolKey: [MTLTexture]] = [:]
    private var inUse: Set<ObjectIdentifier> = []

    init(device: MTLDevice) {
        self.device = device
    }

    /// Acquires a color texture (BGRA8Unorm) for offscreen rendering.
    /// - Parameter size: Texture dimensions in pixels
    /// - Returns: A texture configured for render target and shader read
    func acquireColorTexture(size: (width: Int, height: Int)) -> MTLTexture? {
        acquire(
            size: size,
            pixelFormat: .bgra8Unorm,
            usage: [.renderTarget, .shaderRead],
            storageMode: .shared
        )
    }

    /// Acquires a stencil texture (depth32Float_stencil8) for mask rendering.
    /// - Parameter size: Texture dimensions in pixels
    /// - Returns: A texture configured for render target
    func acquireStencilTexture(size: (width: Int, height: Int)) -> MTLTexture? {
        acquire(
            size: size,
            pixelFormat: .depth32Float_stencil8,
            usage: [.renderTarget],
            storageMode: .private
        )
    }

    /// Acquires a mask texture (r8Unorm) for alpha mask storage.
    /// - Parameter size: Texture dimensions in pixels
    /// - Returns: A texture configured for shader read
    func acquireMaskTexture(size: (width: Int, height: Int)) -> MTLTexture? {
        acquire(
            size: size,
            pixelFormat: .r8Unorm,
            usage: [.shaderRead],
            storageMode: .shared
        )
    }

    /// Releases a texture back to the pool for reuse.
    /// - Parameter texture: The texture to release
    func release(_ texture: MTLTexture) {
        let identifier = ObjectIdentifier(texture)
        guard inUse.contains(identifier) else { return }

        inUse.remove(identifier)
        let key = TexturePoolKey(
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )
        available[key, default: []].append(texture)
    }

    /// Clears all pooled textures to free memory.
    func clear() {
        available.removeAll()
        inUse.removeAll()
    }

    // MARK: - Private

    private func acquire(
        size: (width: Int, height: Int),
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage,
        storageMode: MTLStorageMode
    ) -> MTLTexture? {
        let key = TexturePoolKey(size: size, pixelFormat: pixelFormat)

        // Try to reuse existing texture
        if var textures = available[key], !textures.isEmpty {
            let texture = textures.removeLast()
            available[key] = textures
            inUse.insert(ObjectIdentifier(texture))
            return texture
        }

        // Create new texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = storageMode

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        inUse.insert(ObjectIdentifier(texture))
        return texture
    }
}
