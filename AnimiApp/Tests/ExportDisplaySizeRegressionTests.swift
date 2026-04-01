import XCTest
import Metal
import TVECore
@testable import AnimiApp

/// PR-F §6.3: Export-side regression tests for display size metadata injection.
///
/// Verifies that:
/// - User photo export path injects display size metadata into ExportTextureProvider
/// - Export render does not fall back to template assetSizes for bound user photos
final class ExportDisplaySizeRegressionTests: XCTestCase {

    /// Verifies that ExportTextureProvider stores display size after setDisplaySize.
    func testExportTextureProviderStoresDisplaySize() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }

        let provider = ExportTextureProvider(
            device: device,
            assetIndex: AssetIndexIR(),
            resolver: CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty),
            bindingAssetIds: ["binding_01"]
        )

        // Initially no display size
        XCTAssertNil(provider.displaySize(for: "binding_01"))

        // Set display size
        provider.setDisplaySize(CGSize(width: 3024, height: 4032), for: "binding_01")
        XCTAssertEqual(provider.displaySize(for: "binding_01"), CGSize(width: 3024, height: 4032))

        // Remove display size
        provider.removeDisplaySize(for: "binding_01")
        XCTAssertNil(provider.displaySize(for: "binding_01"))
    }

    /// Verifies that clearAll removes display sizes along with textures.
    func testExportTextureProviderClearAllClearsDisplaySizes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }

        let provider = ExportTextureProvider(
            device: device,
            assetIndex: AssetIndexIR(),
            resolver: CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty),
            bindingAssetIds: ["binding_01"]
        )

        provider.setDisplaySize(CGSize(width: 100, height: 200), for: "binding_01")
        XCTAssertNotNil(provider.displaySize(for: "binding_01"))

        provider.clearAll()
        XCTAssertNil(provider.displaySize(for: "binding_01"))
    }

    /// Verifies that selective clear(assetIds:) removes display sizes for specified IDs.
    func testExportTextureProviderSelectiveClearRemovesDisplaySizes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }

        let provider = ExportTextureProvider(
            device: device,
            assetIndex: AssetIndexIR(),
            resolver: CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty),
            bindingAssetIds: ["binding_01", "binding_02"]
        )

        provider.setDisplaySize(CGSize(width: 100, height: 200), for: "binding_01")
        provider.setDisplaySize(CGSize(width: 300, height: 400), for: "binding_02")

        // Clear only binding_01
        provider.clear(assetIds: ["binding_01"])
        XCTAssertNil(provider.displaySize(for: "binding_01"))
        XCTAssertNotNil(provider.displaySize(for: "binding_02"))
    }

    /// Verifies that removeTexture also clears display size for that asset.
    func testExportTextureProviderRemoveTextureClearsDisplaySize() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }

        let provider = ExportTextureProvider(
            device: device,
            assetIndex: AssetIndexIR(),
            resolver: CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty),
            bindingAssetIds: ["binding_01"]
        )

        provider.setDisplaySize(CGSize(width: 100, height: 200), for: "binding_01")
        XCTAssertNotNil(provider.displaySize(for: "binding_01"))

        provider.removeTexture(for: "binding_01")
        XCTAssertNil(provider.displaySize(for: "binding_01"),
            "removeTexture should also clear display size metadata")
    }

    /// Verifies that AssetRenderGeometryResolver correctly prioritizes display size over assetSizes.
    func testGeometryResolverPrioritizesDisplaySizeOverAssetSize() {
        // Simulate: user photo with display size, template has assetSize
        let result = AssetRenderGeometryResolver.resolve(
            videoOrientedSize: nil,
            displaySize: CGSize(width: 3024, height: 4032),
            assetSize: AssetSize(width: 500, height: 500),
            textureWidth: 256,
            textureHeight: 256
        )

        XCTAssertEqual(result.source, .displaySize,
            "Export renderer should use display size, not template assetSizes, for user photos")
        XCTAssertEqual(result.width, 3024, accuracy: 0.01)
        XCTAssertEqual(result.height, 4032, accuracy: 0.01)
    }

    /// Verifies that template assets (no display size) still use assetSizes.
    func testTemplateAssetStillUsesAssetSizesInExport() {
        let result = AssetRenderGeometryResolver.resolve(
            videoOrientedSize: nil,
            displaySize: nil,
            assetSize: AssetSize(width: 500, height: 700),
            textureWidth: 256,
            textureHeight: 256
        )

        XCTAssertEqual(result.source, .assetSize,
            "Template assets without display size should still use assetSizes")
    }

    /// PR-F P1 fix: Verifies that export display size must match file probe dimensions,
    /// not downsampled texture dimensions. When a 3024x4032 photo is downsampled to 1024x1365
    /// for GPU, the renderer quad must still use 3024x4032 to match placement transform.
    func testExportDisplaySizeMustMatchFileProbNotDownsampledTexture() {
        // Placement is resolved with file probe: 3024x4032
        let fileProbedSize = CGSize(width: 3024, height: 4032)
        // Texture is downsampled: 1024x1365
        let downsampledTextureSize = CGSize(width: 1024, height: 1365)

        // If we incorrectly use texture size as displaySize:
        let wrongResult = AssetRenderGeometryResolver.resolve(
            videoOrientedSize: nil,
            displaySize: downsampledTextureSize,
            assetSize: nil,
            textureWidth: 1024,
            textureHeight: 1365
        )

        // If we correctly use file probe size as displaySize:
        let correctResult = AssetRenderGeometryResolver.resolve(
            videoOrientedSize: nil,
            displaySize: fileProbedSize,
            assetSize: nil,
            textureWidth: 1024,
            textureHeight: 1365
        )

        // Aspect ratios should match (both are same photo)
        let wrongAR = wrongResult.width / wrongResult.height
        let correctAR = correctResult.width / correctResult.height
        XCTAssertEqual(wrongAR, correctAR, accuracy: 0.01,
            "Aspect ratios should match regardless of resolution")

        // But absolute dimensions must match placement source
        XCTAssertEqual(correctResult.width, 3024, accuracy: 0.01,
            "Export renderer quad must use file probe dimensions, not downsampled texture")
        XCTAssertEqual(correctResult.height, 4032, accuracy: 0.01,
            "Export renderer quad must use file probe dimensions, not downsampled texture")

        // The wrong approach would give smaller quad, mismatched with placement transform
        XCTAssertNotEqual(wrongResult.width, correctResult.width, accuracy: 1.0,
            "Using downsampled texture size would give wrong absolute quad dimensions")
    }
}
