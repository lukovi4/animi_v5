#if DEBUG
import XCTest
@testable import AnimiApp

/// CP2 corrective: focused unit tests for the Next-bridge placement conversion (fix 3).
/// Asserts exact fixed-point rounding with no silent Float coercion, and typed failures.
final class NextSingleSceneBridgePlacementTests: XCTestCase {

    // Unit conventions (from AnimiEngineCore scalar definitions):
    //   CanvasScalar:   65,536 raw / point
    //   ScaleScalar: 1,000,000 raw / 1.0
    //   RotationScalar:    1,000 raw / degree

    func test_identityPlacement_mapsToCanonicalIdentity() throws {
        let raw = try NextSingleSceneBridge.convertPlacementForTesting(
            NextBridgePlacement(fitModeRaw: "contain", offsetX: 0, offsetY: 0,
                                userScale: 1.0, rotationDegrees: 0))
        XCTAssertEqual(raw.fitModeRaw, "contain")
        XCTAssertEqual(raw.offsetXRaw, 0)
        XCTAssertEqual(raw.offsetYRaw, 0)
        XCTAssertEqual(raw.scaleRaw, 1_000_000)   // ScaleScalar.one
        XCTAssertEqual(raw.rotationRaw, 0)
    }

    func test_fitModes_mapOneToOne() throws {
        for mode in ["cover", "contain", "fill"] {
            let raw = try NextSingleSceneBridge.convertPlacementForTesting(
                NextBridgePlacement(fitModeRaw: mode, offsetX: 0, offsetY: 0,
                                    userScale: 1.0, rotationDegrees: 0))
            XCTAssertEqual(raw.fitModeRaw, mode)
        }
    }

    func test_offsetScaleRotation_exactFixedPoint() throws {
        let raw = try NextSingleSceneBridge.convertPlacementForTesting(
            NextBridgePlacement(fitModeRaw: "cover", offsetX: 10.0, offsetY: -2.5,
                                userScale: 1.5, rotationDegrees: 90.0))
        XCTAssertEqual(raw.offsetXRaw, 10 * 65_536)            // 655_360
        XCTAssertEqual(raw.offsetYRaw, Int64((-2.5 * 65_536).rounded()))  // -163_840
        XCTAssertEqual(raw.scaleRaw, Int64((1.5 * 1_000_000).rounded()))  // 1_500_000
        XCTAssertEqual(raw.rotationRaw, 90 * 1_000)           // 90_000
    }

    func test_roundsToNearest_noTruncation() throws {
        // 0.123456 deg * 1000 = 123.456 -> rounds to 123 (nearest), not truncated by cast.
        let raw = try NextSingleSceneBridge.convertPlacementForTesting(
            NextBridgePlacement(fitModeRaw: "contain", offsetX: 0, offsetY: 0,
                                userScale: 1.0, rotationDegrees: 0.123456))
        XCTAssertEqual(raw.rotationRaw, 123)
    }

    func test_unknownFitMode_failsClosed() {
        XCTAssertThrowsError(try NextSingleSceneBridge.convertPlacementForTesting(
            NextBridgePlacement(fitModeRaw: "bogus", offsetX: 0, offsetY: 0,
                                userScale: 1.0, rotationDegrees: 0)))
    }

    func test_nonPositiveScale_failsClosed() {
        XCTAssertThrowsError(try NextSingleSceneBridge.convertPlacementForTesting(
            NextBridgePlacement(fitModeRaw: "contain", offsetX: 0, offsetY: 0,
                                userScale: 0.0, rotationDegrees: 0)))
    }

    func test_nonFiniteOffset_failsClosed() {
        XCTAssertThrowsError(try NextSingleSceneBridge.convertPlacementForTesting(
            NextBridgePlacement(fitModeRaw: "contain", offsetX: .nan, offsetY: 0,
                                userScale: 1.0, rotationDegrees: 0)))
    }
}
#endif
