import Metal
import Foundation

// MARK: - Scene Texture Provider Factory

/// Factory for creating a texture provider for an entire scene.
/// Uses the merged asset index from ScenePlayer which contains namespaced asset IDs
/// from all animations in the scene.
public enum SceneTextureProviderFactory {

    /// Creates a texture provider for the entire scene
    ///
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - package: Scene package containing images root URL
    ///   - mergedAssetIndex: Merged asset index from ScenePlayer (with namespaced IDs)
    ///   - logger: Optional logger for diagnostic messages
    /// - Returns: Texture provider that can serve textures for all animations in the scene
    public static func create(
        device: MTLDevice,
        package: ScenePackage,
        mergedAssetIndex: AssetIndexIR,
        logger: TVELogger? = nil
    ) -> ScenePackageTextureProvider {
        // Use package.rootURL because asset paths include "images/" prefix
        return ScenePackageTextureProvider(
            device: device,
            imagesRootURL: package.rootURL,
            assetIndex: mergedAssetIndex,
            logger: logger
        )
    }
}
