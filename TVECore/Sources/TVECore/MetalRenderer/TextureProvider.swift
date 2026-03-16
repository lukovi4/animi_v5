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
    ///
    /// Model A contract: texture access happens only on main during playback/render.
    public func texture(for assetId: String) -> MTLTexture? {
        dispatchPrecondition(condition: .onQueue(.main))
        return textures[assetId]
    }

    // MARK: - MutableTextureProvider

    /// Model A contract: texture mutations happen only on main during playback/render.
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        textures[assetId] = texture
    }

    /// Model A contract: texture mutations happen only on main during playback/render.
    public func removeTexture(for assetId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        textures.removeValue(forKey: assetId)
    }
}

// MARK: - Thread-Safe In-Memory Texture Provider (PR-G)

/// Thread-safe texture provider for background queue usage (e.g., export).
///
/// Unlike `InMemoryTextureProvider`, this class:
/// - Has NO `dispatchPrecondition(.main)` assertions
/// - Uses NSLock for thread-safe cache access
/// - Safe for use on export queue or any background thread
///
/// Use this for background texture providers passed to VideoExporter.
/// Preview/playback providers on main thread can use regular `InMemoryTextureProvider`.
public final class ThreadSafeInMemoryTextureProvider: MutableTextureProvider {
    private let lock = NSLock()
    private var textures: [String: MTLTexture] = [:]

    public init() {}

    /// Registers a texture for an asset ID (thread-safe).
    public func register(_ texture: MTLTexture, for assetId: String) {
        lock.lock()
        defer { lock.unlock() }
        textures[assetId] = texture
    }

    /// Returns the registered texture for the given asset ID (thread-safe).
    public func texture(for assetId: String) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return textures[assetId]
    }

    // MARK: - MutableTextureProvider

    /// Injects a texture for runtime use (thread-safe).
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        lock.lock()
        defer { lock.unlock() }
        textures[assetId] = texture
    }

    /// Removes an injected texture (thread-safe).
    public func removeTexture(for assetId: String) {
        lock.lock()
        defer { lock.unlock() }
        textures.removeValue(forKey: assetId)
    }
}
