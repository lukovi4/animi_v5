import XCTest
@testable import TVECore

/// Regression tests for matte bbox geometry resolution.
///
/// Verifies that `computeMatteBBox` uses the shared geometry resolver (4-tier priority)
/// instead of raw `assetSizes` alone, ensuring consistency with `drawImage` quad sizing.
final class MatteBboxGeometryTests: XCTestCase {

    // MARK: - Photo: displaySize beats assetSize

    /// When a user photo has `displaySize` larger than template `assetSize`,
    /// the matte bbox must use `displaySize` — not the smaller `assetSize`.
    func testBboxUsesDisplaySizeOverAssetSize() {
        // Template assetSize is 500×500 but user photo displaySize is 3024×4032
        let assetSizes: [String: AssetSize] = ["photo1": AssetSize(width: 500, height: 500)]

        // Matte source: full-frame shape covering the viewport
        // Consumer: drawImage of the user photo
        let commands: [RenderCommand] = [
            .beginMatte(mode: .alpha),
            .beginGroup(name: "matteSource"),
            .drawImage(assetId: "matteMask", opacity: 1.0),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "photo1", opacity: 1.0),
            .endGroup,
            .endMatte,
        ]

        let sourceRange = 1..<4   // beginGroup..endGroup (matteSource)
        let consumerRange = 4..<7  // beginGroup..endGroup (matteConsumer)

        // Resolver that returns displaySize (3024×4032) for photo1,
        // and assetSize for the mask asset
        let resolveGeometry: (String) -> AssetRenderGeometryResolver.Result? = { assetId in
            if assetId == "photo1" {
                return AssetRenderGeometryResolver.Result(
                    width: 3024, height: 4032, source: .displaySize
                )
            }
            if assetId == "matteMask" {
                return AssetRenderGeometryResolver.Result(
                    width: 1080, height: 1920, source: .assetSize
                )
            }
            return nil
        }

        let animToViewport = Matrix2D.identity
        let bbox = computeMatteBBox(
            commands: commands,
            sourceRange: sourceRange,
            consumerRange: consumerRange,
            inheritedTransform: .identity,
            animToViewport: animToViewport,
            assetSizes: assetSizes,
            pathRegistry: PathRegistry(),
            resolveImageGeometry: resolveGeometry
        )

        // The consumer bbox should be based on displaySize (3024×4032), not assetSize (500×500).
        // Since the intersection clips to the smaller source (1080×1920),
        // the result should be at most 1080×1920.
        XCTAssertNotNil(bbox, "bbox should be computed successfully")
        if let bbox = bbox {
            // Consumer uses displaySize → its bbox covers 3024×4032
            // Source covers 1080×1920
            // Intersection = min of both = 1080×1920
            XCTAssertEqual(bbox.width, 1080, accuracy: 1, "bbox width should match source (intersection)")
            XCTAssertEqual(bbox.height, 1920, accuracy: 1, "bbox height should match source (intersection)")
        }
    }

    /// When displaySize > assetSize, pixels in the displaySize area but outside assetSize area
    /// must be included in the consumer bbox (before intersection with source).
    func testConsumerBboxSpansFullDisplaySize() {
        let assetSizes: [String: AssetSize] = ["photo1": AssetSize(width: 500, height: 500)]

        let commands: [RenderCommand] = [
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "photo1", opacity: 1.0),
            .endGroup,
        ]

        let range = 0..<3

        let resolveGeometry: (String) -> AssetRenderGeometryResolver.Result? = { assetId in
            if assetId == "photo1" {
                return AssetRenderGeometryResolver.Result(
                    width: 3024, height: 4032, source: .displaySize
                )
            }
            return nil
        }

        // Use computeRangeBBox indirectly via computeMatteBBox with only consumer range
        let bbox = computeMatteBBox(
            commands: commands,
            sourceRange: 0..<0, // empty source → falls back to consumer only
            consumerRange: range,
            inheritedTransform: .identity,
            animToViewport: .identity,
            assetSizes: assetSizes,
            pathRegistry: PathRegistry(),
            resolveImageGeometry: resolveGeometry
        )

        XCTAssertNotNil(bbox)
        if let bbox = bbox {
            XCTAssertEqual(bbox.width, 3024, accuracy: 1, "Consumer bbox should use displaySize width")
            XCTAssertEqual(bbox.height, 4032, accuracy: 1, "Consumer bbox should use displaySize height")
        }
    }

    // MARK: - Video: videoOrientedSize beats assetSize

    /// When a video has `videoOrientedSize` different from `assetSize`,
    /// the matte bbox must follow `videoOrientedSize`.
    func testBboxUsesVideoOrientedSizeOverAssetSize() {
        // Template assetSize is 500×500 but video oriented size is 1080×1920
        let assetSizes: [String: AssetSize] = ["video1": AssetSize(width: 500, height: 500)]

        let commands: [RenderCommand] = [
            .beginMatte(mode: .luma),
            .beginGroup(name: "matteSource"),
            .drawImage(assetId: "matteMask", opacity: 1.0),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "video1", opacity: 1.0),
            .endGroup,
            .endMatte,
        ]

        let sourceRange = 1..<4
        let consumerRange = 4..<7

        let resolveGeometry: (String) -> AssetRenderGeometryResolver.Result? = { assetId in
            if assetId == "video1" {
                return AssetRenderGeometryResolver.Result(
                    width: 1080, height: 1920, source: .videoOrientedSize
                )
            }
            if assetId == "matteMask" {
                return AssetRenderGeometryResolver.Result(
                    width: 1080, height: 1920, source: .assetSize
                )
            }
            return nil
        }

        let bbox = computeMatteBBox(
            commands: commands,
            sourceRange: sourceRange,
            consumerRange: consumerRange,
            inheritedTransform: .identity,
            animToViewport: .identity,
            assetSizes: assetSizes,
            pathRegistry: PathRegistry(),
            resolveImageGeometry: resolveGeometry
        )

        XCTAssertNotNil(bbox)
        if let bbox = bbox {
            XCTAssertEqual(bbox.width, 1080, accuracy: 1)
            XCTAssertEqual(bbox.height, 1920, accuracy: 1)
        }
    }

    // MARK: - Nil geometry → full-frame fallback

    /// When the resolver returns nil (no geometry source), `computeMatteBBox`
    /// must return nil so the renderer falls back to full-frame.
    func testBboxReturnsNilWhenResolverReturnsNil() {
        let assetSizes: [String: AssetSize] = [:]

        let commands: [RenderCommand] = [
            .beginMatte(mode: .alpha),
            .beginGroup(name: "matteSource"),
            .drawImage(assetId: "missing", opacity: 1.0),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "alsoMissing", opacity: 1.0),
            .endGroup,
            .endMatte,
        ]

        let bbox = computeMatteBBox(
            commands: commands,
            sourceRange: 1..<4,
            consumerRange: 4..<7,
            inheritedTransform: .identity,
            animToViewport: .identity,
            assetSizes: assetSizes,
            pathRegistry: PathRegistry(),
            resolveImageGeometry: { _ in nil }
        )

        XCTAssertNil(bbox, "bbox should be nil when resolver returns nil → full-frame fallback")
    }

    // MARK: - Template assets use assetSize (no regression)

    /// For template assets without user metadata, the resolver returns assetSize
    /// and behavior is unchanged from before.
    func testBboxUsesAssetSizeForTemplateAssets() {
        let assetSizes: [String: AssetSize] = [
            "mask": AssetSize(width: 1080, height: 1920),
            "templateImg": AssetSize(width: 500, height: 700),
        ]

        let commands: [RenderCommand] = [
            .beginMatte(mode: .alpha),
            .beginGroup(name: "matteSource"),
            .drawImage(assetId: "mask", opacity: 1.0),
            .endGroup,
            .beginGroup(name: "matteConsumer"),
            .drawImage(assetId: "templateImg", opacity: 1.0),
            .endGroup,
            .endMatte,
        ]

        let resolveGeometry: (String) -> AssetRenderGeometryResolver.Result? = { assetId in
            guard let size = assetSizes[assetId] else { return nil }
            return AssetRenderGeometryResolver.Result(
                width: size.width, height: size.height, source: .assetSize
            )
        }

        let bbox = computeMatteBBox(
            commands: commands,
            sourceRange: 1..<4,
            consumerRange: 4..<7,
            inheritedTransform: .identity,
            animToViewport: .identity,
            assetSizes: assetSizes,
            pathRegistry: PathRegistry(),
            resolveImageGeometry: resolveGeometry
        )

        XCTAssertNotNil(bbox)
        if let bbox = bbox {
            // Intersection of 1080×1920 source and 500×700 consumer = 500×700
            XCTAssertEqual(bbox.width, 500, accuracy: 1)
            XCTAssertEqual(bbox.height, 700, accuracy: 1)
        }
    }
}
