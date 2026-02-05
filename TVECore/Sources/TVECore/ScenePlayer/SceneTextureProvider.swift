import Metal
import Foundation

// MARK: - Scene Texture Provider Factory

/// Factory for creating a texture provider for an entire scene.
/// Uses the merged asset index from ScenePlayer which contains namespaced asset IDs
/// from all animations in the scene, and resolves assets via CompositeAssetResolver (PR-28).
public enum SceneTextureProviderFactory {

    /// Creates a texture provider for the entire scene with resolver-based asset resolution.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - mergedAssetIndex: Merged asset index from ScenePlayer (with namespaced IDs and basenames)
    ///   - resolver: Composite resolver for Local → Shared asset resolution
    ///   - bindingAssetIds: Namespaced IDs of binding layer assets (no file on disk).
    ///     Only these may be skipped during preload. All other missing assets are errors.
    ///   - logger: Optional logger for diagnostic messages
    /// - Returns: Texture provider that can serve textures for all animations in the scene
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
}
