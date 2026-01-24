import Metal

// MARK: - Texture Provider Protocol

/// Protocol for providing Metal textures for asset rendering.
/// Abstracts texture loading to enable testing with in-memory textures.
public protocol TextureProvider {
    /// Returns the texture for the given asset ID.
    /// - Parameter assetId: Asset identifier from RenderCommand.drawImage
    /// - Returns: Metal texture or nil if not found/loadable
    func texture(for assetId: String) -> MTLTexture?
}

// MARK: - In-Memory Texture Provider

/// Simple texture provider for testing.
/// Stores textures in memory keyed by asset ID.
public final class InMemoryTextureProvider: TextureProvider {
    private var textures: [String: MTLTexture] = [:]

    public init() {}

    /// Registers a texture for an asset ID.
    /// - Parameters:
    ///   - texture: Metal texture to register
    ///   - assetId: Asset identifier
    public func register(_ texture: MTLTexture, for assetId: String) {
        textures[assetId] = texture
    }

    /// Returns the registered texture for the given asset ID.
    public func texture(for assetId: String) -> MTLTexture? {
        textures[assetId]
    }
}
