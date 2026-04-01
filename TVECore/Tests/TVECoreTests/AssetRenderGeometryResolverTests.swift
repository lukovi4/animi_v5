import XCTest
import Foundation
@testable import TVECore

/// PR-F §6.1: Unit tests for the renderer's quad size priority logic.
///
/// Verifies the 4-tier priority: orientedSize → displaySize → assetSizes → texture.size
final class AssetRenderGeometryResolverTests: XCTestCase {

    // MARK: - Test: video orientedSize beats everything

    func testVideoOrientedSizeBeatsDisplaySizeAndAssetSizes() {
        let result = AssetRenderGeometryResolver.resolve(
            videoOrientedSize: CGSize(width: 1920, height: 1080),
            displaySize: CGSize(width: 800, height: 600),
            assetSize: AssetSize(width: 500, height: 500),
            textureWidth: 256,
            textureHeight: 256
        )

        XCTAssertEqual(result.width, 1920, accuracy: 0.01)
        XCTAssertEqual(result.height, 1080, accuracy: 0.01)
        XCTAssertEqual(result.source, .videoOrientedSize)
    }

    // MARK: - Test: display size beats assetSizes for user photo

    func testDisplaySizeBeatsAssetSizes() {
        let result = AssetRenderGeometryResolver.resolve(
            videoOrientedSize: nil,
            displaySize: CGSize(width: 3024, height: 4032),
            assetSize: AssetSize(width: 500, height: 500),
            textureWidth: 256,
            textureHeight: 256
        )

        XCTAssertEqual(result.width, 3024, accuracy: 0.01)
        XCTAssertEqual(result.height, 4032, accuracy: 0.01)
        XCTAssertEqual(result.source, .displaySize)
    }

    // MARK: - Test: template asset without display size still uses assetSizes

    func testTemplateAssetUsesAssetSizesWhenNoDisplaySize() {
        let result = AssetRenderGeometryResolver.resolve(
            videoOrientedSize: nil,
            displaySize: nil,
            assetSize: AssetSize(width: 500, height: 700),
            textureWidth: 256,
            textureHeight: 256
        )

        XCTAssertEqual(result.width, 500, accuracy: 0.01)
        XCTAssertEqual(result.height, 700, accuracy: 0.01)
        XCTAssertEqual(result.source, .assetSize)
    }

    // MARK: - Test: fallback to texture size

    func testFallbackToTextureSizeWhenNothingElse() {
        let result = AssetRenderGeometryResolver.resolve(
            videoOrientedSize: nil,
            displaySize: nil,
            assetSize: nil,
            textureWidth: 1024,
            textureHeight: 768
        )

        XCTAssertEqual(result.width, 1024, accuracy: 0.01)
        XCTAssertEqual(result.height, 768, accuracy: 0.01)
        XCTAssertEqual(result.source, .textureSize)
    }

    // MARK: - Test: video orientedSize beats display size even when both present

    func testVideoOrientedSizeHasHighestPriority() {
        let result = AssetRenderGeometryResolver.resolve(
            videoOrientedSize: CGSize(width: 1080, height: 1920),
            displaySize: CGSize(width: 500, height: 500),
            assetSize: nil,
            textureWidth: 64,
            textureHeight: 64
        )

        XCTAssertEqual(result.width, 1080, accuracy: 0.01)
        XCTAssertEqual(result.height, 1920, accuracy: 0.01)
        XCTAssertEqual(result.source, .videoOrientedSize)
    }

    // MARK: - Test: display size with no assetSize and no video

    func testDisplaySizeAloneWorks() {
        let result = AssetRenderGeometryResolver.resolve(
            videoOrientedSize: nil,
            displaySize: CGSize(width: 640, height: 480),
            assetSize: nil,
            textureWidth: 64,
            textureHeight: 64
        )

        XCTAssertEqual(result.width, 640, accuracy: 0.01)
        XCTAssertEqual(result.height, 480, accuracy: 0.01)
        XCTAssertEqual(result.source, .displaySize)
    }
}
