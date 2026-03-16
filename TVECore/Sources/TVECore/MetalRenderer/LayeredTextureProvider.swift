import Metal

// MARK: - Layered Texture Provider

/// Composite texture provider that layers overlay textures over base textures.
/// Used for multi-scene timeline where base scene textures are shared,
/// but each scene instance has its own user media overlays.
///
/// Lookup order:
/// 1. First check overlay (per-instance mutable textures)
/// 2. Then fallback to base (shared immutable textures)
///
/// Usage:
/// ```swift
/// let layered = LayeredTextureProvider(
///     base: sharedSceneTextures,    // Immutable, shared per sceneTypeId
///     overlay: instanceOverlay      // Mutable, per sceneInstanceId
/// )
///
/// // User media injection goes to overlay
/// layered.setTexture(photoTexture, for: "binding_asset_id")
///
/// // Base textures remain unchanged
/// let baseTexture = layered.texture(for: "preloaded_asset_id")
/// ```
public final class LayeredTextureProvider: MutableTextureProvider {

    // MARK: - Layers

    /// Base texture provider (immutable, shared per sceneTypeId).
    private let base: TextureProvider

    /// Overlay texture provider (mutable, per sceneInstanceId).
    private let overlay: MutableTextureProvider

    // MARK: - Init

    /// Creates a layered texture provider.
    /// - Parameters:
    ///   - base: Base (immutable) texture provider with preloaded scene textures.
    ///   - overlay: Overlay (mutable) texture provider for user media injection.
    public init(base: TextureProvider, overlay: MutableTextureProvider) {
        self.base = base
        self.overlay = overlay
    }

    // MARK: - TextureProvider

    /// Returns texture from overlay if present, otherwise from base.
    ///
    /// Model A contract: texture access happens only on main during playback/render.
    public func texture(for assetId: String) -> MTLTexture? {
        // 1. Check overlay first (user media takes precedence)
        if let overlayTexture = overlay.texture(for: assetId) {
            return overlayTexture
        }

        // 2. Fallback to base (preloaded scene textures)
        return base.texture(for: assetId)
    }

    // MARK: - MutableTextureProvider

    /// Injects texture into overlay layer.
    /// Base textures are never modified.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    public func setTexture(_ texture: MTLTexture, for assetId: String) {
        overlay.setTexture(texture, for: assetId)
    }

    /// Removes texture from overlay layer.
    /// Base textures are never affected.
    ///
    /// Model A contract: texture mutations happen only on main during playback/render.
    public func removeTexture(for assetId: String) {
        overlay.removeTexture(for: assetId)
    }
}
