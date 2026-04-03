import XCTest
@testable import AnimiApp
import TVECore

/// Tests for MediaPlacementResolver: pure placement → Matrix2D conversion.
final class MediaPlacementResolverTests: XCTestCase {

    // MARK: - Helpers

    /// Landscape slot: 540×960 at origin
    private let landscapeSlot = RectD(x: 0, y: 0, width: 540, height: 960)
    /// Portrait slot: 960×540 at origin
    private let portraitSlot = RectD(x: 0, y: 0, width: 960, height: 540)
    /// Offset slot (non-zero origin)
    private let offsetSlot = RectD(x: 100, y: 50, width: 400, height: 300)

    private func geom(slot: RectD, mediaW: Double, mediaH: Double) -> MediaPlacementResolver.SlotGeometry {
        MediaPlacementResolver.SlotGeometry(baselineRectLocal: slot, mediaWidth: mediaW, mediaHeight: mediaH)
    }

    // MARK: - Cover Fit Mode

    func test_cover_landscapeMediaInLandscapeSlot() {
        // 1920×1080 media in 540×960 slot
        // cover: max(540/1920, 960/1080) = max(0.28125, 0.8889) = 0.8889
        let g = geom(slot: landscapeSlot, mediaW: 1920, mediaH: 1080)
        let m = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)

        let scale = 960.0 / 1080.0  // ~0.8889
        XCTAssertEqual(m.a, scale, accuracy: 1e-6, "scaleX")
        XCTAssertEqual(m.d, scale, accuracy: 1e-6, "scaleY")
        // Centered: tx = (540 - 1920*scale)/2
        let expectedTx = (540.0 - 1920.0 * scale) / 2.0
        XCTAssertEqual(m.tx, expectedTx, accuracy: 1e-4)
    }

    func test_cover_portraitMediaInLandscapeSlot() {
        // 1080×1920 media in 540×960 slot
        // cover: max(540/1080, 960/1920) = max(0.5, 0.5) = 0.5
        let g = geom(slot: landscapeSlot, mediaW: 1080, mediaH: 1920)
        let m = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)

        XCTAssertEqual(m.a, 0.5, accuracy: 1e-6)
        XCTAssertEqual(m.d, 0.5, accuracy: 1e-6)
        // Perfectly centered: media scaled = 540×960
        XCTAssertEqual(m.tx, 0, accuracy: 1e-6)
        XCTAssertEqual(m.ty, 0, accuracy: 1e-6)
    }

    func test_cover_landscapeMediaInPortraitSlot() {
        // 1920×1080 media in 960×540 slot
        // cover: max(960/1920, 540/1080) = max(0.5, 0.5) = 0.5
        let g = geom(slot: portraitSlot, mediaW: 1920, mediaH: 1080)
        let m = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)

        XCTAssertEqual(m.a, 0.5, accuracy: 1e-6)
        XCTAssertEqual(m.d, 0.5, accuracy: 1e-6)
    }

    // MARK: - Contain Fit Mode

    func test_contain_landscapeMediaInLandscapeSlot() {
        // 1920×1080 media in 540×960 slot
        // contain: min(540/1920, 960/1080) = min(0.28125, 0.8889) = 0.28125
        let g = geom(slot: landscapeSlot, mediaW: 1920, mediaH: 1080)
        let m = MediaPlacementResolver.baseFitTransform(fitMode: .contain, geometry: g)

        let scale = 540.0 / 1920.0  // 0.28125
        XCTAssertEqual(m.a, scale, accuracy: 1e-6)
        XCTAssertEqual(m.d, scale, accuracy: 1e-6)
        // Centered vertically: ty = (960 - 1080*scale)/2
        let expectedTy = (960.0 - 1080.0 * scale) / 2.0
        XCTAssertEqual(m.ty, expectedTy, accuracy: 1e-4)
        XCTAssertEqual(m.tx, 0, accuracy: 1e-4, "Horizontally exact fit")
    }

    func test_contain_portraitMediaInPortraitSlot() {
        // 1080×1920 media in 960×540 slot
        // contain: min(960/1080, 540/1920) = min(0.8889, 0.28125) = 0.28125
        let g = geom(slot: portraitSlot, mediaW: 1080, mediaH: 1920)
        let m = MediaPlacementResolver.baseFitTransform(fitMode: .contain, geometry: g)

        let scale = 540.0 / 1920.0
        XCTAssertEqual(m.a, scale, accuracy: 1e-6)
        XCTAssertEqual(m.d, scale, accuracy: 1e-6)
    }

    // MARK: - Fill Fit Mode

    func test_fill_stretchesToFill() {
        // 1920×1080 media in 540×960 slot → different x/y scales
        let g = geom(slot: landscapeSlot, mediaW: 1920, mediaH: 1080)
        let m = MediaPlacementResolver.baseFitTransform(fitMode: .fill, geometry: g)

        XCTAssertEqual(m.a, 540.0 / 1920.0, accuracy: 1e-6, "scaleX for fill")
        XCTAssertEqual(m.d, 960.0 / 1080.0, accuracy: 1e-6, "scaleY for fill")
        XCTAssertEqual(m.tx, 0, accuracy: 1e-6, "No centering offset for fill")
        XCTAssertEqual(m.ty, 0, accuracy: 1e-6, "No centering offset for fill")
    }

    // MARK: - Identity Placement → baseFit

    func test_identityPlacement_producesBaseFit() {
        let g = geom(slot: landscapeSlot, mediaW: 1920, mediaH: 1080)
        let baseFit = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)
        let resolved = MediaPlacementResolver.resolve(
            placement: .default(fitMode: .cover),
            geometry: g
        )

        XCTAssertTrue(
            resolved.isApproximatelyEqual(to: baseFit, epsilon: 1e-6),
            "Default placement must produce pure baseFit. Got \(resolved) vs \(baseFit)"
        )
    }

    func test_resolveDefault_matchesResolveWithDefaultPlacement() {
        let g = geom(slot: landscapeSlot, mediaW: 1920, mediaH: 1080)
        let a = MediaPlacementResolver.resolveDefault(fitMode: .contain, geometry: g)
        let b = MediaPlacementResolver.resolve(placement: .default(fitMode: .contain), geometry: g)

        XCTAssertTrue(a.isApproximatelyEqual(to: b, epsilon: 1e-10))
    }

    // MARK: - Offset Application

    func test_offset_translatesResult() {
        let g = geom(slot: landscapeSlot, mediaW: 1920, mediaH: 1080)
        let baseFit = MediaPlacementResolver.resolve(placement: .default(fitMode: .cover), geometry: g)
        let offsetPlacement = MediaPlacementState(fitMode: .cover, offsetX: 20, offsetY: -10)
        let resolved = MediaPlacementResolver.resolve(placement: offsetPlacement, geometry: g)

        // Offset should shift the result
        XCTAssertEqual(resolved.tx - baseFit.tx, 20, accuracy: 1e-6)
        XCTAssertEqual(resolved.ty - baseFit.ty, -10, accuracy: 1e-6)
        // Scale shouldn't change
        XCTAssertEqual(resolved.a, baseFit.a, accuracy: 1e-6)
        XCTAssertEqual(resolved.d, baseFit.d, accuracy: 1e-6)
    }

    // MARK: - Scale Application

    func test_scale_multipliesBaseFit() {
        let g = geom(slot: landscapeSlot, mediaW: 1920, mediaH: 1080)
        let placement = MediaPlacementState(fitMode: .cover, userScale: 2.0)
        let resolved = MediaPlacementResolver.resolve(placement: placement, geometry: g)
        let baseFit = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)

        // At the center, scale 2x around center should double the effective scale
        // The a/d components should be baseFit.a * 2.0 (since rotation = 0)
        XCTAssertEqual(resolved.a, baseFit.a * 2.0, accuracy: 1e-6)
        XCTAssertEqual(resolved.d, baseFit.d * 2.0, accuracy: 1e-6)
    }

    // MARK: - Rotation Application

    func test_rotation90_appliedCorrectly() {
        let g = geom(slot: landscapeSlot, mediaW: 1920, mediaH: 1080)
        let placement = MediaPlacementState(fitMode: .cover, rotationDegrees: 90)
        let resolved = MediaPlacementResolver.resolve(placement: placement, geometry: g)

        // After 90° rotation around center, a≈0, b≈scale, c≈-scale, d≈0
        let baseFit = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)
        let scale = baseFit.a  // uniform scale from cover
        XCTAssertEqual(resolved.a, 0, accuracy: 1e-6, "cos(90°)*scale ≈ 0")
        XCTAssertEqual(resolved.b, scale, accuracy: 1e-6, "sin(90°)*scale")
        XCTAssertEqual(resolved.c, -scale, accuracy: 1e-6, "-sin(90°)*scale")
        XCTAssertEqual(resolved.d, 0, accuracy: 1e-6, "cos(90°)*scale ≈ 0")
    }

    // MARK: - Rotation Snap

    func test_snapRotation_withinThreshold_snaps() {
        XCTAssertEqual(MediaPlacementResolver.snapRotation(2), 0, "2° snaps to 0°")
        XCTAssertEqual(MediaPlacementResolver.snapRotation(-2), 0, "-2° snaps to 0°")
        XCTAssertEqual(MediaPlacementResolver.snapRotation(4), 0, "4° snaps to 0°")
        XCTAssertEqual(MediaPlacementResolver.snapRotation(89), 90, "89° snaps to 90°")
        XCTAssertEqual(MediaPlacementResolver.snapRotation(91), 90, "91° snaps to 90°")
        XCTAssertEqual(MediaPlacementResolver.snapRotation(-89), -90, "-89° snaps to -90°")
        XCTAssertEqual(MediaPlacementResolver.snapRotation(178), 180, "178° snaps to 180°")
        XCTAssertEqual(MediaPlacementResolver.snapRotation(-178), -180, "-178° snaps to -180°")
    }

    func test_snapRotation_outsideThreshold_noSnap() {
        XCTAssertEqual(MediaPlacementResolver.snapRotation(4.1), 4.1, "4.1° must NOT snap")
        XCTAssertEqual(MediaPlacementResolver.snapRotation(45), 45, "45° must NOT snap")
        XCTAssertEqual(MediaPlacementResolver.snapRotation(85), 85, "85° must NOT snap (outside 4° of 90°)")
        XCTAssertEqual(MediaPlacementResolver.snapRotation(-5), -5, "-5° must NOT snap")
    }

    // MARK: - Non-Zero Origin Slot

    func test_offsetSlot_baseFitCentersCorrectly() {
        // Slot at (100, 50) with 400×300
        let g = geom(slot: offsetSlot, mediaW: 800, mediaH: 600)
        let m = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)

        // cover: max(400/800, 300/600) = max(0.5, 0.5) = 0.5
        XCTAssertEqual(m.a, 0.5, accuracy: 1e-6)
        // Centered: tx = 100 + (400 - 800*0.5)/2 = 100 + 0 = 100
        XCTAssertEqual(m.tx, 100, accuracy: 1e-6)
        XCTAssertEqual(m.ty, 50, accuracy: 1e-6)
    }

    func test_offsetSlot_identityPlacementResolves() {
        let g = geom(slot: offsetSlot, mediaW: 800, mediaH: 600)
        let resolved = MediaPlacementResolver.resolve(
            placement: .default(fitMode: .cover),
            geometry: g
        )
        let baseFit = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)

        XCTAssertTrue(resolved.isApproximatelyEqual(to: baseFit, epsilon: 1e-6))
    }

    // MARK: - Edge Cases

    func test_zeroMediaSize_returnsIdentity() {
        let g = geom(slot: landscapeSlot, mediaW: 0, mediaH: 0)
        let m = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)
        XCTAssertTrue(m.isApproximatelyEqual(to: .identity, epsilon: 1e-10))
    }

    func test_zeroSlotSize_returnsIdentity() {
        let g = geom(slot: RectD(x: 0, y: 0, width: 0, height: 0), mediaW: 100, mediaH: 100)
        let m = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)
        XCTAssertTrue(m.isApproximatelyEqual(to: .identity, epsilon: 1e-10))
    }

    // MARK: - Combined Transform

    func test_combinedOffsetScaleRotation() {
        let g = geom(slot: landscapeSlot, mediaW: 1080, mediaH: 1920)
        let placement = MediaPlacementState(
            fitMode: .cover, offsetX: 15, offsetY: -8, userScale: 1.3, rotationDegrees: 30
        )
        let resolved = MediaPlacementResolver.resolve(placement: placement, geometry: g)

        // Verify it's not identity and not just baseFit
        let baseFit = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: g)
        XCTAssertFalse(resolved.isApproximatelyEqual(to: baseFit, epsilon: 1e-3),
                       "Combined transform must differ from pure baseFit")
        XCTAssertFalse(resolved.isApproximatelyEqual(to: .identity, epsilon: 1e-3),
                       "Combined transform must not be identity")

        // Verify the matrix is invertible (valid transform)
        XCTAssertNotNil(resolved.inverse, "Resolved matrix must be invertible")
    }
}
