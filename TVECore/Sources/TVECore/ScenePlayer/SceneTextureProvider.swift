import Metal
import Foundation

// MARK: - Scene Texture Provider Factory

/// Factory for creating a texture provider for an entire scene.
/// Uses the merged asset index from ScenePlayer which contains namespaced asset IDs
/// from all animations in the scene, and resolves assets via CompositeAssetResolver (PR-28).
public enum SceneTextureProviderFactory {

    /// Creates a mutable texture provider for scene-edit / legacy single-scene path.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - mergedAssetIndex: Merged asset index from ScenePlayer (with namespaced IDs and basenames)
    ///   - resolver: Composite resolver for Local → Shared asset resolution
    ///   - bindingAssetIds: Namespaced IDs of binding layer assets (no file on disk).
    ///     Only these may be skipped during preload. All other missing assets are errors.
    ///   - logger: Optional logger for diagnostic messages
    /// - Returns: Mutable texture provider for scene-edit path
    public static func create(
        device: MTLDevice,
        mergedAssetIndex: AssetIndexIR,
        resolver: CompositeAssetResolver,
        bindingAssetIds: Set<String> = [],
        logger: TVELogger? = nil
    ) -> ScenePackageTextureProvider {
        return ScenePackageTextureProvider(
            device: device,
            assetIndex: mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: bindingAssetIds,
            logger: logger
        )
    }

    /// Creates an immutable base texture provider for timeline shared cache.
    ///
    /// TT-07: The returned provider does NOT conform to `MutableTextureProvider`.
    /// Used by `SceneTypeResourcesCache` for shared base layer per `sceneTypeId`.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - mergedAssetIndex: Merged asset index from ScenePlayer (with namespaced IDs and basenames)
    ///   - resolver: Composite resolver for Local → Shared asset resolution
    ///   - bindingAssetIds: Namespaced IDs of binding layer assets (no file on disk).
    ///   - logger: Optional logger for diagnostic messages
    /// - Returns: Immutable base texture provider for timeline shared cache
    public static func createBaseProvider(
        device: MTLDevice,
        mergedAssetIndex: AssetIndexIR,
        resolver: CompositeAssetResolver,
        bindingAssetIds: Set<String> = [],
        logger: TVELogger? = nil
    ) -> ScenePackageBaseTextureProvider {
        return ScenePackageBaseTextureProvider(
            device: device,
            assetIndex: mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: bindingAssetIds,
            logger: logger
        )
    }
}
