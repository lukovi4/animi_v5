import XCTest
@testable import AnimiApp

final class PlacementGestureSessionTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(
        baseline: MediaPlacementState = .defaultCover
    ) -> PlacementGestureSession {
        PlacementGestureSession(blockId: "block1", baseline: baseline)
    }

    // MARK: - Pan Only

    func test_panOnly_appliesTranslationToBaseline() {
        var session = makeSession()
        session.translationDelta = (x: 50, y: -30)

        let result = session.currentPlacement()
        XCTAssertEqual(result.offsetX, 50, accuracy: 1e-9)
        XCTAssertEqual(result.offsetY, -30, accuracy: 1e-9)
        XCTAssertEqual(result.userScale, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.rotationDegrees, 0, accuracy: 1e-9)
    }

    // MARK: - Pinch Only

    func test_pinchOnly_multipliesBaselineScale() {
        var session = makeSession()
        session.scaleDelta = 2.0

        let result = session.currentPlacement()
        XCTAssertEqual(result.userScale, 2.0, accuracy: 1e-9)
        XCTAssertEqual(result.offsetX, 0, accuracy: 1e-9)
        XCTAssertEqual(result.rotationDegrees, 0, accuracy: 1e-9)
    }

    // MARK: - Rotate Only

    func test_rotateOnly_addsRadiansConvertedToDegrees() {
        var session = makeSession()
        session.rotationDelta = .pi / 4  // 45 degrees

        let result = session.currentPlacement()
        XCTAssertEqual(result.rotationDegrees, 45, accuracy: 1e-6)
        XCTAssertEqual(result.userScale, 1.0, accuracy: 1e-9)
    }

    // MARK: - Simultaneous Gestures

    func test_simultaneous_allDeltasApplied() {
        var session = makeSession()
        session.translationDelta = (x: 10, y: 20)
        session.scaleDelta = 1.5
        session.rotationDelta = .pi / 6  // 30 degrees

        let result = session.currentPlacement()
        XCTAssertEqual(result.offsetX, 10, accuracy: 1e-9)
        XCTAssertEqual(result.offsetY, 20, accuracy: 1e-9)
        XCTAssertEqual(result.userScale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(result.rotationDegrees, 30, accuracy: 1e-6)
    }

    // MARK: - Baseline Unchanged

    func test_baselineUnchangedAfterDeltas() {
        let baseline = MediaPlacementState(fitMode: .cover, offsetX: 5, offsetY: 10, userScale: 2.0, rotationDegrees: 45)
        var session = makeSession(baseline: baseline)
        session.translationDelta = (x: 100, y: 200)
        session.scaleDelta = 3.0
        session.rotationDelta = .pi

        // Baseline must not be mutated
        XCTAssertEqual(session.baseline.offsetX, 5)
        XCTAssertEqual(session.baseline.offsetY, 10)
        XCTAssertEqual(session.baseline.userScale, 2.0)
        XCTAssertEqual(session.baseline.rotationDegrees, 45)
    }

    // MARK: - Scale Clamping

    func test_scaleClamping_hitsLowerBound() {
        // baseline scale 0.5, delta 0.1 → 0.05, clamped to 0.25
        let baseline = MediaPlacementState(fitMode: .cover, userScale: 0.5)
        var session = makeSession(baseline: baseline)
        session.scaleDelta = 0.1

        let result = session.currentPlacement()
        XCTAssertEqual(result.userScale, MediaPlacementState.scaleRange.lowerBound, accuracy: 1e-9)
    }

    func test_scaleClamping_hitsUpperBound() {
        // baseline scale 3.0, delta 3.0 → 9.0, clamped to 6.0
        let baseline = MediaPlacementState(fitMode: .cover, userScale: 3.0)
        var session = makeSession(baseline: baseline)
        session.scaleDelta = 3.0

        let result = session.currentPlacement()
        XCTAssertEqual(result.userScale, MediaPlacementState.scaleRange.upperBound, accuracy: 1e-9)
    }

    // MARK: - Rotation Normalization

    func test_rotationNormalization_wrapsAround() {
        // baseline 170°, delta ~20° (in radians) → 190° → normalized to -170°
        let baseline = MediaPlacementState(fitMode: .cover, rotationDegrees: 170)
        var session = makeSession(baseline: baseline)
        session.rotationDelta = 20.0 * .pi / 180.0  // 20 degrees in radians

        let result = session.currentPlacement()
        XCTAssertEqual(result.rotationDegrees, -170, accuracy: 1e-6)
    }

    // MARK: - Non-Default Baseline

    func test_nonDefaultBaseline_deltasAdditive() {
        let baseline = MediaPlacementState(
            fitMode: .contain,
            offsetX: 100,
            offsetY: -50,
            userScale: 2.0,
            rotationDegrees: -90
        )
        var session = makeSession(baseline: baseline)
        session.translationDelta = (x: -20, y: 10)
        session.scaleDelta = 1.5
        session.rotationDelta = .pi / 2  // +90 degrees

        let result = session.currentPlacement()
        XCTAssertEqual(result.fitMode, .contain)
        XCTAssertEqual(result.offsetX, 80, accuracy: 1e-9)
        XCTAssertEqual(result.offsetY, -40, accuracy: 1e-9)
        XCTAssertEqual(result.userScale, 3.0, accuracy: 1e-9)
        XCTAssertEqual(result.rotationDegrees, 0, accuracy: 1e-6)  // -90 + 90 = 0
    }
}
