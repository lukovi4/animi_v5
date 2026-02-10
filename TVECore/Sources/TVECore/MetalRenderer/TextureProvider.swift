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

// MARK: - Mutable Texture Provider Protocol (PR-32)

/// Extended texture provider that supports runtime texture injection.
///
/// Used for user media (photo/video) injection into binding layers.
/// Implementations should prioritize injected textures over file-loaded ones.
///
/// Typical usage:
/// ```swift
/// // Set user photo texture for a binding layer
/// provider.setTexture(photoTexture, for: "no-anim.json|image_2")
///
/// // Clear user media (binding layer will be hidden)
/// provider.removeTexture(for: "no-anim.json|image_2")
/// ```
public protocol MutableTextureProvider: TextureProvider {
    /// Injects a texture for runtime use (e.g., user-selected photo/video frame).
    ///
    /// Injected textures take precedence over file-loaded textures.
    /// Use this for binding layer user media.
    ///
    /// - Parameters:
    ///   - texture: Metal texture to inject
    ///   - assetId: Namespaced asset identifier (e.g., "animRef|image_x")
    func setTexture(_ texture: MTLTexture, for assetId: String)

    /// Removes an injected texture, reverting to file-based loading (if available).
    ///
    /// For binding assets (no file on disk), this effectively hides the layer
    /// when combined with `setUserMediaPresent(blockId:, present: false)`.
    ///
    /// - Parameter assetId: Namespaced asset identifier to remove
    func removeTexture(for assetId: String)
}

// MARK: - In-Memory Texture Provider

/// Simple texture provider for testing.
/// Stores textures in memory keyed by asset ID.
/// Conforms to MutableTextureProvider for test scenarios requiring texture injection.
public final class InMemoryTextureProvider: MutableTextureProvider {
    private var textures: [String: MTLTexture] = [:]

    public init() {}

    /// Registers a texture for an asset ID (legacy API, prefer setTexture).
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

    // MARK: - MutableTextureProvider

    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        textures[assetId] = texture
    }

    public func removeTexture(for assetId: String) {
        textures.removeValue(forKey: assetId)
    }
}
