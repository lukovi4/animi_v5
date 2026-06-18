import XCTest
@testable import AnimiEngineCore

/// Exact tick-time tests (Task-002 plan, §18 "Time").
final class TickTimeTests: XCTestCase {

    func testExactTicksPerFrameForAllSupportedRates() throws {
        XCTAssertEqual(try FrameRate.fps23_976.exactTicksPerFrame, 10_010)
        XCTAssertEqual(try FrameRate.fps24.exactTicksPerFrame, 10_000)
        XCTAssertEqual(try FrameRate.fps25.exactTicksPerFrame, 9_600)
        XCTAssertEqual(try FrameRate.fps29_97.exactTicksPerFrame, 8_008)
        XCTAssertEqual(try FrameRate.fps30.exactTicksPerFrame, 8_000)
        XCTAssertEqual(try FrameRate.fps50.exactTicksPerFrame, 4_800)
        XCTAssertEqual(try FrameRate.fps59_94.exactTicksPerFrame, 4_004)
        XCTAssertEqual(try FrameRate.fps60.exactTicksPerFrame, 4_000)
    }

    func testHalfSecondIs120000Ticks() throws {
        // 0.5s at 240,000 ticks/s.
        XCTAssertEqual(TickClock.ticksPerSecond / 2, 120_000)
    }

    func test29_97Frame90Is720720Ticks() throws {
        let frame = try FrameIndex(value: 90)
        let time = try frame.projectTime(at: .fps29_97)
        XCTAssertEqual(time.ticks, 720_720)
    }

    func test59_94Frame90Is360360Ticks() throws {
        let frame = try FrameIndex(value: 90)
        let time = try frame.projectTime(at: .fps59_94)
        XCTAssertEqual(time.ticks, 360_360)
    }

    func testNonNegativeDomainsRejectNegatives() {
        XCTAssertThrowsError(try ProjectTime(ticks: -1)) { error in
            XCTAssertEqual(error as? TimeError, .negativeValue(domain: "ProjectTime", value: -1))
        }
        XCTAssertThrowsError(try TickDuration(ticks: -5))
        XCTAssertThrowsError(try ScenePlaybackTime(ticks: -1))
        XCTAssertThrowsError(try AnimationPlaybackTime(ticks: -1))
        XCTAssertThrowsError(try OverlayPlaybackTime(ticks: -1))
        XCTAssertThrowsError(try FrameIndex(value: -1))
    }

    func testTransitionRelativeTimeAllowsNegative() {
        let t = TransitionRelativeTime(ticks: -8_000)
        XCTAssertEqual(t.ticks, -8_000)
        XCTAssertTrue(t < TransitionRelativeTime(ticks: 0))
    }

    func testCheckedArithmeticRejectsOverflow() {
        XCTAssertThrowsError(try CheckedInt64.add(Int64.max, 1))
        XCTAssertThrowsError(try CheckedInt64.multiply(Int64.max, 2))
        XCTAssertThrowsError(try (try! TickDuration(ticks: Int64.max)).adding(try! TickDuration(ticks: 1)))
    }

    func testProjectTimeArithmetic() throws {
        let t = try ProjectTime(ticks: 1_000)
        let d = try TickDuration(ticks: 240)
        XCTAssertEqual(try t.adding(d).ticks, 1_240)
        XCTAssertEqual(try t.distance(to: try ProjectTime(ticks: 1_240)).ticks, 240)
        XCTAssertThrowsError(try (try ProjectTime(ticks: 5)).distance(to: try ProjectTime(ticks: 1)))
    }

    func testFrameToTimeSamplingPerformsNoImplicitRounding() throws {
        // 29.97 frame 1 = 8008 ticks exactly; there is no rounding path that would yield 8000.
        let time = try FrameIndex(value: 1).projectTime(at: .fps29_97)
        XCTAssertEqual(time.ticks, 8_008)
    }

    func testInvalidFrameRateRejected() {
        XCTAssertThrowsError(try FrameRate(numerator: 0, denominator: 1))
        XCTAssertThrowsError(try FrameRate(numerator: 24, denominator: 0))
        // An unsupported rate whose ticks-per-frame is not integral (e.g. 7 fps → 240000/7).
        XCTAssertThrowsError(try FrameRate(numerator: 7, denominator: 1).exactTicksPerFrame)
    }
}
