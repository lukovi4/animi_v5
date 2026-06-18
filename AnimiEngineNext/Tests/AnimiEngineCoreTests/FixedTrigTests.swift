import XCTest
@testable import AnimiEngineCore

/// Task-003 step-8 corrective (issue #6) — deterministic fixed-point CORDIC sine/cosine, plus the
/// full-width fixed-point multiply/divide it stands on. No `Float`/`Double` in the implementation; the
/// tests use `Double` only to compute the reference and assert a tight integer tolerance.
final class FixedTrigTests: XCTestCase {

    private let scale: Int64 = 1_000_000

    /// CORDIC accuracy: ≤ a few hundred ULP at the 1e6 scale (the table self-checks to ≤7 ULP at 2^32,
    /// which is ~0 at 1e6; allow a small slack for the final scale rounding).
    private func assertCosSin(degrees: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let raw = Int64((degrees * 1000).rounded())
        let (cos, sin) = try FixedTrig.cosSin(rotationRaw: raw, linearUnitsPerOne: scale)
        let radians = degrees * Double.pi / 180
        let expectedCos = Int64((Foundation.cos(radians) * Double(scale)).rounded())
        let expectedSin = Int64((Foundation.sin(radians) * Double(scale)).rounded())
        XCTAssertEqual(cos, expectedCos, accuracy: 4, "cos(\(degrees)°)", file: file, line: line)
        XCTAssertEqual(sin, expectedSin, accuracy: 4, "sin(\(degrees)°)", file: file, line: line)
    }

    func testCardinalAnglesExact() throws {
        // 0°, 90°, 180°, 270°, 360° land on exact integers.
        let (c0, s0) = try FixedTrig.cosSin(rotationRaw: 0, linearUnitsPerOne: scale)
        XCTAssertEqual(c0, 1_000_000); XCTAssertEqual(s0, 0)
        let (c90, s90) = try FixedTrig.cosSin(rotationRaw: 90_000, linearUnitsPerOne: scale)
        XCTAssertEqual(c90, 0, accuracy: 2); XCTAssertEqual(s90, 1_000_000, accuracy: 2)
        let (c180, s180) = try FixedTrig.cosSin(rotationRaw: 180_000, linearUnitsPerOne: scale)
        XCTAssertEqual(c180, -1_000_000, accuracy: 2); XCTAssertEqual(s180, 0, accuracy: 2)
        let (c270, s270) = try FixedTrig.cosSin(rotationRaw: 270_000, linearUnitsPerOne: scale)
        XCTAssertEqual(c270, 0, accuracy: 2); XCTAssertEqual(s270, -1_000_000, accuracy: 2)
        let (c360, s360) = try FixedTrig.cosSin(rotationRaw: 360_000, linearUnitsPerOne: scale)
        XCTAssertEqual(c360, 1_000_000, accuracy: 2); XCTAssertEqual(s360, 0, accuracy: 2)
    }

    func testArbitraryAngles() throws {
        for d in [30.0, 45.0, 60.0, 12.34, 123.456, 200.0, 359.9, 17.0, 88.5] {
            try assertCosSin(degrees: d)
        }
    }

    func testNegativeAndLargeAnglesReduce() throws {
        for d in [-45.0, -90.0, -200.0, 720.0 + 30.0, -720.0 - 60.0, 1234.5] {
            try assertCosSin(degrees: d)
        }
    }

    func testDeterministicRepeatability() throws {
        let a = try FixedTrig.cosSin(rotationRaw: 47_123, linearUnitsPerOne: scale)
        let b = try FixedTrig.cosSin(rotationRaw: 47_123, linearUnitsPerOne: scale)
        XCTAssertEqual(a.cos, b.cos); XCTAssertEqual(a.sin, b.sin)
    }

    // MARK: - FixedPointMath full-width multiply/divide

    func testMultiplyDivideRoundingExactAndRounded() throws {
        // 7 * 1 / 2 = 3.5 → 4 (ties away). -7 * 1 / 2 → -4.
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(7, 1, 2, "t"), 4)
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(-7, 1, 2, "t"), -4)
        // Exact: 6 * 4 / 3 = 8.
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(6, 4, 3, "t"), 8)
    }

    func testMultiplyDivideNoIntermediateOverflow() throws {
        // value*factor overflows Int64 (≈9.2e18) but the full-width path handles it: 3e9 * 3e9 / 1e9 = 9e9.
        let big: Int64 = 3_000_000_000
        XCTAssertEqual(
            try FixedPointMath.multiplyDivideRounding(big, big, 1_000_000_000, "t"), 9_000_000_000)
    }

    func testMultiplyDivideZeroDivisorIsTypedFailure() {
        XCTAssertThrowsError(try FixedPointMath.multiplyDivideRounding(1, 1, 0, "t")) { error in
            guard case TimeError.nonPositiveDenominator? = error as? TimeError else {
                return XCTFail("expected nonPositiveDenominator, got \(error)")
            }
        }
    }

    func testMultiplyDivideTrueOverflowThrows() {
        // Result genuinely exceeds Int64: Int64.max * 2 / 1.
        XCTAssertThrowsError(try FixedPointMath.multiplyDivideRounding(Int64.max, 2, 1, "t")) { error in
            guard case TimeError.integerOverflow? = error as? TimeError else {
                return XCTFail("expected integerOverflow, got \(error)")
            }
        }
    }

    // MARK: - FixedPointMath sign combinations + Int64 boundaries (corrective #2)

    func testMultiplyDivideAllSignCombinations() throws {
        // 7 * 3 / 2 = 10.5 → 11 (ties away). Vary the two operand signs; divisor must stay positive.
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(7, 3, 2, "t"), 11)
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(-7, 3, 2, "t"), -11)
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(7, -3, 2, "t"), -11)
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(-7, -3, 2, "t"), 11)
    }

    func testMultiplyDivideNegativeDivisorIsTypedFailure() {
        XCTAssertThrowsError(try FixedPointMath.multiplyDivideRounding(10, 1, -2, "t")) { error in
            guard case TimeError.nonPositiveDenominator? = error as? TimeError else {
                return XCTFail("expected nonPositiveDenominator for negative divisor, got \(error)")
            }
        }
        XCTAssertThrowsError(try FixedPointMath.multiplyDivideRounding(10, 1, 0, "t")) { error in
            guard case TimeError.nonPositiveDenominator? = error as? TimeError else {
                return XCTFail("expected nonPositiveDenominator for zero divisor, got \(error)")
            }
        }
    }

    func testMultiplyDivideInt64MinMaxOperands() throws {
        // Int64.min as a factor: magnitude formed via UInt64, no `-Int64.min` trap.
        // Int64.min / 1 = Int64.min (exact narrowing boundary).
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(Int64.min, 1, 1, "t"), Int64.min)
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(Int64.max, 1, 1, "t"), Int64.max)
        // Int64.min * 1 / 2 = -2^62 exactly (no overflow, sign correct).
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(Int64.min, 1, 2, "t"), Int64.min / 2)
        // Int64.min as a factor too (the value is small): 4 * Int64.min / Int64.min-magnitude…
        // Use a safe combination: (-2) * Int64.max / Int64.max == -2 (exact).
        XCTAssertEqual(try FixedPointMath.multiplyDivideRounding(-2, Int64.max, Int64.max, "t"), -2)
        // Genuine overflow on the way out is still a typed error: Int64.min * -1 == 2^63 > Int64.max.
        XCTAssertThrowsError(try FixedPointMath.multiplyDivideRounding(Int64.min, -1, 1, "t")) { error in
            guard case TimeError.integerOverflow? = error as? TimeError else {
                return XCTFail("expected integerOverflow, got \(error)")
            }
        }
    }

    // MARK: - FixedTrig periodicity + boundaries (corrective #3)

    func testRotationPeriodicity() throws {
        // cos/sin must be invariant under adding any multiple of a full turn (360_000 raw units).
        for base in [0, 30_000, 123_456, -47_000] as [Int64] {
            let ref = try FixedTrig.cosSin(rotationRaw: base, linearUnitsPerOne: scale)
            for k in [-3, -1, 1, 5, 1000] as [Int64] {
                let shifted = try FixedTrig.cosSin(
                    rotationRaw: base + k * FixedTrig.fullTurnRaw, linearUnitsPerOne: scale)
                XCTAssertEqual(shifted.cos, ref.cos, "cos periodic at base \(base) + \(k) turns")
                XCTAssertEqual(shifted.sin, ref.sin, "sin periodic at base \(base) + \(k) turns")
            }
        }
    }

    func testInt64MinMaxAnglesDoNotOverflow() throws {
        XCTAssertNoThrow(try FixedTrig.cosSin(rotationRaw: Int64.max, linearUnitsPerOne: scale))
        XCTAssertNoThrow(try FixedTrig.cosSin(rotationRaw: Int64.min, linearUnitsPerOne: scale))
    }

    func testNonPositiveLinearUnitsRejected() {
        XCTAssertThrowsError(try FixedTrig.cosSin(rotationRaw: 0, linearUnitsPerOne: 0)) { error in
            guard case TimeError.nonPositiveDenominator? = error as? TimeError else {
                return XCTFail("expected nonPositiveDenominator, got \(error)")
            }
        }
        XCTAssertThrowsError(try FixedTrig.cosSin(rotationRaw: 0, linearUnitsPerOne: -1))
    }

    /// Exhaustive accuracy over **all 360,000 canonical angles** (one full turn at 1,000 units/degree),
    /// against a high-precision reference, asserting a tight integer tolerance at the 1e6 scale.
    func testExhaustiveAllCanonicalAngles() throws {
        var maxErr: Int64 = 0
        for raw in 0..<FixedTrig.fullTurnRaw {
            let (cos, sin) = try FixedTrig.cosSin(rotationRaw: raw, linearUnitsPerOne: scale)
            let radians = Double(raw) / 1000.0 * Double.pi / 180.0
            let expCos = Int64((Foundation.cos(radians) * Double(scale)).rounded())
            let expSin = Int64((Foundation.sin(radians) * Double(scale)).rounded())
            maxErr = max(maxErr, abs(cos - expCos))
            maxErr = max(maxErr, abs(sin - expSin))
        }
        // CORDIC at 32 iterations is accurate to a few ULP at 1e6; allow a small fixed tolerance.
        XCTAssertLessThanOrEqual(maxErr, 8, "max abs error over all 360,000 angles was \(maxErr)")
    }

    // MARK: - Golden protection of the ENTIRE CORDIC table (corrective #3)

    func testCordicTableGoldenFull() {
        let goldenAtan: [Int64] = [
            3_373_259_426, 1_991_351_318, 1_052_175_346, 534_100_635,
            268_086_748,   134_174_063,   67_103_403,    33_553_749,
            16_777_131,    8_388_597,     4_194_303,     2_097_152,
            1_048_576,     524_288,       262_144,       131_072,
            65_536,        32_768,        16_384,        8_192,
            4_096,         2_048,         1_024,         512,
            256,           128,           64,            32,
            16,            8,             4,             2
        ]
        XCTAssertEqual(FixedTrig.atanTableQ32, goldenAtan, "the full CORDIC atan table must not drift")
        XCTAssertEqual(FixedTrig.cordicGainQ32, 2_608_131_496)
        XCTAssertEqual(FixedTrig.halfPiQ32, 6_746_518_852)
        XCTAssertEqual(FixedTrig.piQ32, 13_493_037_705)
        XCTAssertEqual(FixedTrig.twoPiQ32, 26_986_075_409)
        XCTAssertEqual(FixedTrig.fullTurnRaw, 360_000)
        XCTAssertEqual(FixedTrig.iterations, 32)
    }
}
