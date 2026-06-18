import XCTest
@testable import AnimiEngineCore

/// Exact rational source-time tests (Task-002 plan, §18 "Rational source time").
final class RationalSourceTimeTests: XCTestCase {

    func testEquivalentFractionsNormalizeAndCompareEqual() throws {
        let a = try RationalSourceTime(numerator: 1000, denominator: 30_000)
        XCTAssertEqual(a.numerator, 1)
        XCTAssertEqual(a.denominator, 30)

        let b = try RationalSourceTime(numerator: 15_000, denominator: 30_000)
        let c = try RationalSourceTime(numerator: 300, denominator: 600)
        let half = try RationalSourceTime(numerator: 1, denominator: 2)
        XCTAssertEqual(b, c)
        XCTAssertEqual(b, half)
    }

    func testNegativePTSValuesCompareCorrectly() throws {
        let neg = try RationalSourceTime(numerator: -1, denominator: 2)
        let zero = RationalSourceTime.zero
        let pos = try RationalSourceTime(numerator: 1, denominator: 2)
        XCTAssertTrue(neg < zero)
        XCTAssertTrue(zero < pos)
        XCTAssertTrue(neg < pos)
        // sign normalization: -1/2 vs 1/-2 are equal
        let alt = try RationalSourceTime(numerator: 1, denominator: -2)
        XCTAssertEqual(neg, alt)
    }

    func testOneProjectTickMapsToExactly1Over240000() throws {
        // One project tick at rate 1/1 is exactly 1/240000 second.
        let mapping = SourceTimeMapping(
            trimRange: try RationalSourceRange(
                start: .zero, end: try RationalSourceTime(numerator: 10, denominator: 1)
            ),
            nativeTimescale: try SourceTimescale(unitsPerSecond: 30_000),
            rate: .oneToOne
        )
        let target = try mapping.target(for: try ScenePlaybackTime(ticks: 1))
        XCTAssertEqual(target, try RationalSourceTime(numerator: 1, denominator: 240_000))
    }

    func testOriginalTimescaleUnchangedAndDifferentTimescalesProduceSameTarget() throws {
        let trim = try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 10, denominator: 1))
        let m1 = SourceTimeMapping(trimRange: trim, nativeTimescale: try SourceTimescale(unitsPerSecond: 30_000), rate: .oneToOne)
        let m2 = SourceTimeMapping(trimRange: trim, nativeTimescale: try SourceTimescale(unitsPerSecond: 48_000), rate: .oneToOne)
        XCTAssertEqual(m1.nativeTimescale.unitsPerSecond, 30_000)
        XCTAssertEqual(m2.nativeTimescale.unitsPerSecond, 48_000)
        let t1 = try m1.target(for: try ScenePlaybackTime(ticks: 8_000))
        let t2 = try m2.target(for: try ScenePlaybackTime(ticks: 8_000))
        XCTAssertEqual(t1, t2)
        XCTAssertEqual(t1, try RationalSourceTime(numerator: 1, denominator: 30))
    }

    func testFullWidthComparisonAtBoundaryValues() throws {
        // Cross products would overflow Int64 but comparison is exact via full width.
        let a = try RationalSourceTime(numerator: 1, denominator: Int64.max)
        let b = try RationalSourceTime(numerator: 2, denominator: Int64.max)
        XCTAssertTrue(a < b)
        let big1 = try RationalSourceTime(numerator: Int64.max - 1, denominator: Int64.max)
        let big2 = try RationalSourceTime(numerator: Int64.max, denominator: Int64.max)
        XCTAssertTrue(big1 < big2)
    }

    func testGCDCrossCancellationPreventsAvoidableOverflow() throws {
        // a/b + c/d where naive common denominator b*d would overflow, but gcd reduction avoids it.
        let a = try RationalSourceTime(numerator: 1, denominator: 6_000_000_000)
        let b = try RationalSourceTime(numerator: 1, denominator: 4_000_000_000)
        // lcm(6e9,4e9)=12e9 fits Int64; naive 24e18 also fits but reduction keeps it minimal.
        let sum = try a.adding(b)
        // 1/6e9 + 1/4e9 = (2+3)/12e9 = 5/12e9
        XCTAssertEqual(sum, try RationalSourceTime(numerator: 5, denominator: 12_000_000_000))
    }

    func testIrreducibleFinalOverflowProducesTypedError() throws {
        let a = try RationalSourceTime(numerator: Int64.max, denominator: 1)
        let b = try RationalSourceTime(numerator: Int64.max, denominator: 1)
        // (max/1)*(max/1) cannot fit Int64 numerator → typed overflow.
        XCTAssertThrowsError(try a.multiplied(by: b)) { error in
            XCTAssertTrue(error is TimeError)
        }
    }

    func testNoSourceTargetIsRoundedOrClamped() throws {
        // A target between two native sample units stays an exact rational, not rounded.
        let mapping = SourceTimeMapping(
            trimRange: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 10, denominator: 1)),
            nativeTimescale: try SourceTimescale(unitsPerSecond: 30_000),
            rate: .oneToOne
        )
        // scene tick 8000 → 8000/240000 = 1/30, which is exactly one 30000-unit sample boundary,
        // but tick 4000 → 1/60 is NOT on the 30000-grid and must remain 1/60, not rounded.
        let offGrid = try mapping.target(for: try ScenePlaybackTime(ticks: 4_000))
        XCTAssertEqual(offGrid, try RationalSourceTime(numerator: 1, denominator: 60))
    }

    func testZeroDenominatorRejected() {
        XCTAssertThrowsError(try RationalSourceTime(numerator: 1, denominator: 0))
    }
}
