import Metal
import Foundation

/// Internal helper that resolves image quad geometry for an asset using
/// the canonical 4-tier priority chain via `AssetRenderGeometryResolver`.
///
/// This is the **single source of truth** for image geometry in the renderer module.
/// Both `drawImage(...)` in `MetalRenderer+Execute.swift` and matte bbox dry-run
/// in `MatteBboxCompute.swift` must use this helper to ensure consistency.
enum AssetQuadGeometryLookup {

    /// Resolves quad geometry for the given asset ID.
    ///
    /// Gathers inputs from the texture provider (via protocol downcasts) and asset
    /// metadata, then delegates to `AssetRenderGeometryResolver.resolve(...)`.
    ///
    /// - Parameters:
    ///   - assetId: The asset identifier to resolve geometry for.
    ///   - textureProvider: Texture provider (may also conform to
    ///     `AssetPresentationInfoProvider` and/or `AssetDisplaySizeProvider`).
    ///   - assetSizes: Template asset size metadata.
    /// - Returns: Resolved geometry, or `nil` if no geometry source is available
    ///   (no metadata and no texture).
    static func resolve(
        assetId: String,
        textureProvider: TextureProvider,
        assetSizes: [String: AssetSize]
    ) -> AssetRenderGeometryResolver.Result? {
        resolve(
            assetId: assetId,
            textureProvider: textureProvider,
            assetSizes: assetSizes,
            prefetchedTexture: nil
        )
    }

    /// Overload that accepts a pre-fetched texture to avoid a redundant
    /// `textureProvider.texture(for:)` call on the hot draw path.
    static func resolve(
        assetId: String,
        textureProvider: TextureProvider,
        assetSizes: [String: AssetSize],
        prefetchedTexture: MTLTexture?
    ) -> AssetRenderGeometryResolver.Result? {
        let videoOrientedSize = (textureProvider as? AssetPresentationInfoProvider)?
            .presentationInfo(for: assetId)?.orientedSize

        let displaySize = (textureProvider as? AssetDisplaySizeProvider)?
            .displaySize(for: assetId)

        let assetSize = assetSizes[assetId]

        let texture = prefetchedTexture ?? textureProvider.texture(for: assetId)

        // If we have no geometry source at all, return nil.
        guard videoOrientedSize != nil || displaySize != nil || assetSize != nil || texture != nil else {
            return nil
        }

        return AssetRenderGeometryResolver.resolve(
            videoOrientedSize: videoOrientedSize,
            displaySize: displaySize,
            assetSize: assetSize,
            textureWidth: texture?.width ?? 0,
            textureHeight: texture?.height ?? 0
        )
    }
}
