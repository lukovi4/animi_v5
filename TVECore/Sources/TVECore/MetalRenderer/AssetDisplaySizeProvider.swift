import Foundation

// MARK: - Asset Display Size Provider Protocols

/// Read-only access to per-asset display size metadata.
///
/// Used by the renderer to determine the correct quad geometry for user media.
/// This decouples the renderer from `UserMediaService` and allows texture providers
/// to carry display-size metadata alongside injected textures.
public protocol AssetDisplaySizeProvider {
    /// Returns the display size for the given asset, if set.
    func displaySize(for assetId: String) -> CGSize?
}

/// Mutable access to per-asset display size metadata.
///
/// Implementations should clear display size metadata alongside texture removal
/// to prevent stale geometry after media replace/remove.
public protocol MutableAssetDisplaySizeProvider: AssetDisplaySizeProvider {
    /// Sets the display size for a given asset.
    func setDisplaySize(_ size: CGSize, for assetId: String)
    /// Removes the display size for a given asset.
    func removeDisplaySize(for assetId: String)
}
