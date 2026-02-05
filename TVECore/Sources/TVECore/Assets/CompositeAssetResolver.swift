import Foundation

// MARK: - Composite Asset Resolver

/// Resolves image asset URLs using a two-stage pipeline: Local → Shared.
///
/// Resolution order:
/// 1. **Local** — ScenePackage `images/` directory (per-template assets)
/// 2. **Shared** — App Bundle `SharedAssets/` directory (cross-template assets)
/// 3. If neither found — throws `AssetResolutionError.assetNotFound`
///
/// This is the canonical resolver for all non-binding image assets.
/// Binding layer assets are excluded from resolution (handled separately via user media injection).
public struct CompositeAssetResolver: Sendable {

    /// Local assets index (per scene package)
    private let localIndex: LocalAssetsIndex

    /// Shared assets index (per app, long-lived)
    private let sharedIndex: SharedAssetsIndex

    // MARK: - Init

    /// Creates a composite resolver with local and shared indices.
    ///
    /// - Parameters:
    ///   - localIndex: Index of local assets from the scene package `images/` folder.
    ///   - sharedIndex: Index of shared assets from the App Bundle.
    public init(localIndex: LocalAssetsIndex, sharedIndex: SharedAssetsIndex) {
        self.localIndex = localIndex
        self.sharedIndex = sharedIndex
    }

    // MARK: - Resolution

    /// Resolves a file URL for an asset by its basename key.
    ///
    /// Resolution order: local → shared → throw.
    ///
    /// - Parameter key: Basename without extension, case-sensitive.
    /// - Returns: Resolved file URL.
    /// - Throws: `AssetResolutionError.assetNotFound` if not found in either index.
    public func resolveURL(forKey key: String) throws -> URL {
        if let url = localIndex.url(forKey: key) {
            return url
        }
        if let url = sharedIndex.url(forKey: key) {
            return url
        }
        throw AssetResolutionError.assetNotFound(key: key, stage: .shared)
    }

    /// Checks if an asset key can be resolved (without throwing).
    ///
    /// - Parameter key: Basename without extension, case-sensitive.
    /// - Returns: `true` if the key resolves to a URL in local or shared index.
    public func canResolve(key: String) -> Bool {
        localIndex.url(forKey: key) != nil || sharedIndex.url(forKey: key) != nil
    }

    /// Returns the resolution stage where the key was found.
    ///
    /// - Parameter key: Basename without extension, case-sensitive.
    /// - Returns: `.local` or `.shared`, or `nil` if not found.
    public func resolvedStage(forKey key: String) -> AssetResolutionStage? {
        if localIndex.url(forKey: key) != nil { return .local }
        if sharedIndex.url(forKey: key) != nil { return .shared }
        return nil
    }
}
