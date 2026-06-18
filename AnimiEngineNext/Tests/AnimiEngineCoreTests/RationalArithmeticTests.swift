import XCTest
@testable import AnimiEngineCore

/// Reduced-rational arithmetic tests (corrective plan C-3).
final class RationalArithmeticTests: XCTestCase {

    func testMaxOverTwoPlusNegMaxOverThree() throws {
        let a = try RationalSourceTime(numerator: Int64.max, denominator: 2)
        let b = try RationalSourceTime(numerator: -Int64.max, denominator: 3)
        let sum = try a.adding(b)
        // Int64.max·(1/2 − 1/3) = Int64.max/6; gcd(Int64.max, 6) == 1, so it stays Int64.max/6.
        XCTAssertEqual(sum.numerator, Int64.max)
        XCTAssertEqual(sum.denominator, 6)
    }

    func testZeroOverIntMin() throws {
        let z = try RationalSourceTime(numerator: 0, denominator: Int64.min)
        XCTAssertEqual(z.numerator, 0)
        XCTAssertEqual(z.denominator, 1)
    }

    func testIntMinOverIntMin() throws {
        let one = try RationalSourceTime(numerator: Int64.min, denominator: Int64.min)
        XCTAssertEqual(one.numerator, 1)
        XCTAssertEqual(one.denominator, 1)
    }

    func testIntMinOverOne() throws {
        // The irreducible Int64.min case: negative magnitude 2^63 narrows to Int64.min, denominator 1.
        let mn = try RationalSourceTime(numerator: Int64.min, denominator: 1)
        XCTAssertEqual(mn.numerator, Int64.min)
        XCTAssertEqual(mn.denominator, 1)
    }

    func testIntMinNumeratorReducesWhenEven() throws {
        let half = try RationalSourceTime(numerator: Int64.min, denominator: 2)
        XCTAssertEqual(half.numerator, -(Int64(1) << 62))
        XCTAssertEqual(half.denominator, 1)
    }

    func testNegativeMagnitude2Pow63Allowed_PositiveRejected() throws {
        // Negative 2^63 magnitude is representable as Int64.min.
        XCTAssertNoThrow(try RationalSourceTime(numerator: Int64.min, denominator: 1))
        // The same magnitude positive cannot fit Int64 → throws. Reach it via 0 − Int64.min/1.
        let neg = try RationalSourceTime(numerator: Int64.min, denominator: 1)        // = -2^63
        // (-2^63)/1 · (-1)/1 would be +2^63/1 which does not fit → throws.
        let minusOne = try RationalSourceTime(numerator: -1, denominator: 1)
        XCTAssertThrowsError(try neg.multiplied(by: minusOne)) {
            XCTAssertEqual($0 as? TimeError, .rationalDoesNotFit)
        }
    }

    func testTrulyIrreducibleOverflowStillThrows() throws {
        let big = try RationalSourceTime(numerator: Int64.max, denominator: 1)
        XCTAssertThrowsError(try big.multiplied(by: big)) {
            XCTAssertEqual($0 as? TimeError, .rationalDoesNotFit)
        }
    }

    func testRationalRegressionTwoOverMaxPlusTwoOverOneThrows() throws {
        // 2/Int64.max + 2/1: common-denominator numerator = 2 + 2·Int64.max = 2^64 which cannot fit
        // Int64; the reduced result (2·Int64.max + 2)/Int64.max also does not fit ⇒ must throw, never
        // silently return zero (corrective pass, issue #3).
        let a = try RationalSourceTime(numerator: 2, denominator: Int64.max)
        let b = try RationalSourceTime(numerator: 2, denominator: 1)
        XCTAssertThrowsError(try a.adding(b)) {
            XCTAssertEqual($0 as? TimeError, .rationalDoesNotFit)
        }
    }

    func testAvoidableOverflowInSourceTimeMappingWithRationalRate() throws {
        // rate = Int64.max/Int64.max (== 1/1 once reduced); scene tick 2. Naive `rn·s` would be
        // 2·Int64.max which overflows Int64 if pre-multiplied as raw integers, but composing rationals
        // reduces the rate to 1/1 first, so target = 0 + (Int64.max/Int64.max)·(2/240000) = 1/120000.
        let mapping = SourceTimeMapping(
            trimRange: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 100, denominator: 1)),
            nativeTimescale: try SourceTimescale(unitsPerSecond: 30_000),
            rate: try PlaybackRate(numerator: Int64.max, denominator: Int64.max)
        )
        let target = try mapping.target(for: try ScenePlaybackTime(ticks: 2))
        XCTAssertEqual(target, try RationalSourceTime(numerator: 1, denominator: 120_000))
    }

    func testComparisonUnchangedAtBoundaryValues() throws {
        XCTAssertTrue(try RationalSourceTime(numerator: 1, denominator: Int64.max)
            < RationalSourceTime(numerator: 2, denominator: Int64.max))
        XCTAssertTrue(try RationalSourceTime(numerator: -1, denominator: 2) < RationalSourceTime.zero)
        XCTAssertTrue(try RationalSourceTime(numerator: Int64.max - 1, denominator: Int64.max)
            < RationalSourceTime(numerator: Int64.max, denominator: Int64.max))
        // Sign normalization equivalence.
        XCTAssertEqual(try RationalSourceTime(numerator: -1, denominator: 2),
                       try RationalSourceTime(numerator: 1, denominator: -2))
    }

    func testCommutativityAndReducedFormInvariants() throws {
        let table: [(Int64, Int64)] = [
            (Int64.min, 1), (Int64.min, Int64.min), (0, Int64.min),
            (5, 10), (-7, 14), (Int64.max, 3), (1, Int64.max)
        ]
        for (n1, d1) in table {
            for (n2, d2) in table {
                let a = try RationalSourceTime(numerator: n1, denominator: d1)
                let b = try RationalSourceTime(numerator: n2, denominator: d2)
                // Reduced-form invariants.
                XCTAssertGreaterThanOrEqual(a.denominator, 1)
                // Commutativity of addition (skip if either overflows).
                if let ab = try? a.adding(b), let ba = try? b.adding(a) {
                    XCTAssertEqual(ab, ba, "add commutativity \(n1)/\(d1) + \(n2)/\(d2)")
                }
                if let ab = try? a.multiplied(by: b), let ba = try? b.multiplied(by: a) {
                    XCTAssertEqual(ab, ba, "mul commutativity")
                }
            }
        }
    }
}
