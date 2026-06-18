import XCTest
@testable import AnimiEngineCore

/// Frame-to-time sampling tests: exact, no implicit rounding (Task-002 plan, §18 "Time").
final class FrameSamplingTests: XCTestCase {

    func testFrameToTimeIsExactForAllRates() throws {
        let cases: [(FrameRate, Int64, Int64)] = [
            (.fps24, 48, 480_000),
            (.fps25, 50, 480_000),
            (.fps30, 30, 240_000),
            (.fps29_97, 90, 720_720),
            (.fps59_94, 90, 360_360),
            (.fps60, 120, 480_000)
        ]
        for (rate, frame, expected) in cases {
            let time = try FrameIndex(value: frame).projectTime(at: rate)
            XCTAssertEqual(time.ticks, expected, "rate \(rate.numerator)/\(rate.denominator) frame \(frame)")
        }
    }

    func testNoImplicitRoundingForDropFrameRates() throws {
        // 29.97 frame 1 must be 8008, never rounded down to a "nice" 8000.
        XCTAssertEqual(try FrameIndex(value: 1).projectTime(at: .fps29_97).ticks, 8_008)
        // 59.94 frame 1 = 4004.
        XCTAssertEqual(try FrameIndex(value: 1).projectTime(at: .fps59_94).ticks, 4_004)
    }

    func testFrameZeroIsTimeZero() throws {
        XCTAssertEqual(try FrameIndex(value: 0).projectTime(at: .fps30).ticks, 0)
    }
}
