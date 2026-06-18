import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Scene boundary / window-formula tests (Task-002 plan, §7.2, §14, §18).
final class SceneBoundaryTests: XCTestCase {

    func testCenteredWindowEvenDuration() throws {
        // §14: boundary 720000, D 240000 → window [600000, 840000).
        let window = try TransitionMath.window(
            boundary: try ProjectTime(ticks: 720_000), duration: try TickDuration(ticks: 240_000)
        )
        XCTAssertEqual(window.start.ticks, 600_000)
        XCTAssertEqual(window.end.ticks, 840_000)
    }

    func testOddDurationExtraTickAfterBoundary() throws {
        // D = 5 → preHalf 2, postHalf 3.
        let halves = TransitionHalves(duration: try TickDuration(ticks: 5))
        XCTAssertEqual(halves.preHalf, 2)
        XCTAssertEqual(halves.postHalf, 3)
        let window = try TransitionMath.window(boundary: try ProjectTime(ticks: 100), duration: try TickDuration(ticks: 5))
        XCTAssertEqual(window.start.ticks, 98)   // 100 - 2
        XCTAssertEqual(window.end.ticks, 103)    // 100 + 3
    }

    func testProgressIsHalfOpenNeverOne() throws {
        let boundary = try ProjectTime(ticks: 720_000)
        let duration = try TickDuration(ticks: 240_000)
        let window = try TransitionMath.window(boundary: boundary, duration: duration)
        // At window start, progress 0/240000.
        let (n0, d0) = try TransitionMath.progress(at: window.start, window: window, duration: duration)
        XCTAssertEqual(n0, 0); XCTAssertEqual(d0, 240_000)
        // At boundary, progress 120000/240000.
        let (nB, _) = try TransitionMath.progress(at: boundary, window: window, duration: duration)
        XCTAssertEqual(nB, 120_000)
        // At the last in-window tick (839999), progress < duration (never == 1).
        let last = try ProjectTime(ticks: 839_999)
        let (nL, dL) = try TransitionMath.progress(at: last, window: window, duration: duration)
        XCTAssertLessThan(nL, dL)
    }
}
