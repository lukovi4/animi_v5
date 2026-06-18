import XCTest
@testable import AnimiEngineCore

/// `SourceTimeMapping.target(for:)` formula tests (Task-002 plan, §4.2, §14).
final class SourceTimeMappingTests: XCTestCase {

    private func mapping(trimStart: RationalSourceTime, trimEnd: RationalSourceTime) throws -> SourceTimeMapping {
        SourceTimeMapping(
            trimRange: try RationalSourceRange(start: trimStart, end: trimEnd),
            nativeTimescale: try SourceTimescale(unitsPerSecond: 30_000),
            rate: .oneToOne
        )
    }

    func testWorkedExampleTargets() throws {
        // §14: with trim start 0, frame 91 = scene tick 8000, frame 104 = 112000, frame 105 = 120000.
        let m = try mapping(trimStart: .zero, trimEnd: try RationalSourceTime(numerator: 10, denominator: 1))
        XCTAssertEqual(try m.target(for: try ScenePlaybackTime(ticks: 8_000)),
                       try RationalSourceTime(numerator: 1, denominator: 30))
        XCTAssertEqual(try m.target(for: try ScenePlaybackTime(ticks: 112_000)),
                       try RationalSourceTime(numerator: 7, denominator: 15))
        XCTAssertEqual(try m.target(for: try ScenePlaybackTime(ticks: 120_000)),
                       try RationalSourceTime(numerator: 1, denominator: 2))
    }

    func testTrimStartOffsetIsAdded() throws {
        let m = try mapping(
            trimStart: try RationalSourceTime(numerator: 1, denominator: 4),
            trimEnd: try RationalSourceTime(numerator: 10, denominator: 1)
        )
        // tick 0 → trim start exactly.
        XCTAssertEqual(try m.target(for: .zero), try RationalSourceTime(numerator: 1, denominator: 4))
        // tick 120000 → 1/4 + 1/2 = 3/4.
        XCTAssertEqual(try m.target(for: try ScenePlaybackTime(ticks: 120_000)),
                       try RationalSourceTime(numerator: 3, denominator: 4))
    }

    func testResultIsNotRoundedToNativeTimescale() throws {
        let m = try mapping(trimStart: .zero, trimEnd: try RationalSourceTime(numerator: 10, denominator: 1))
        // tick 1 → 1/240000 — far finer than the 30000 native grid, never rounded.
        XCTAssertEqual(try m.target(for: try ScenePlaybackTime(ticks: 1)),
                       try RationalSourceTime(numerator: 1, denominator: 240_000))
        XCTAssertEqual(m.nativeTimescale.unitsPerSecond, 30_000)
    }
}
