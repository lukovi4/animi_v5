import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineTemplateAdapter

/// Task-003 plan §5.4, §13 row "Numeric conversion" — render-only checked fixed-point value types,
/// plus the §17 step-7 adapter-boundary `Double` → fixed-point conversion (round-to-nearest,
/// ties-away-from-zero; NaN/inf/overflow rejected).
final class RenderNumericConversionTests: XCTestCase {

    func testUnitIntervalAcceptsClosedRangeAndRejectsOutside() throws {
        XCTAssertEqual(try UnitInterval(rawValue: 0).rawValue, 0)
        XCTAssertEqual(try UnitInterval(rawValue: 1_000_000).rawValue, 1_000_000)
        XCTAssertEqual(UnitInterval.zero.rawValue, 0)
        XCTAssertEqual(UnitInterval.one.rawValue, 1_000_000)
        XCTAssertThrowsError(try UnitInterval(rawValue: -1)) { assertOutOfRange($0, "UnitInterval") }
        XCTAssertThrowsError(try UnitInterval(rawValue: 1_000_001)) { assertOutOfRange($0, "UnitInterval") }
    }

    func testOpacityScalarRangeAndConstants() throws {
        XCTAssertEqual(OpacityScalar.opaque.rawValue, 1_000_000)
        XCTAssertEqual(OpacityScalar.transparent.rawValue, 0)
        XCTAssertEqual(try OpacityScalar(rawValue: 500_000).rawValue, 500_000)
        XCTAssertThrowsError(try OpacityScalar(rawValue: -1)) { assertOutOfRange($0, "OpacityScalar") }
        XCTAssertThrowsError(try OpacityScalar(rawValue: 2_000_000)) { assertOutOfRange($0, "OpacityScalar") }
    }

    func testNormalizedColorComponentRange() throws {
        XCTAssertEqual(NormalizedColorComponent.one.rawValue, 1_000_000)
        XCTAssertThrowsError(try NormalizedColorComponent(rawValue: -5)) {
            assertOutOfRange($0, "NormalizedColorComponent")
        }
        XCTAssertThrowsError(try NormalizedColorComponent(rawValue: 1_000_001)) {
            assertOutOfRange($0, "NormalizedColorComponent")
        }
    }

    func testOrderingIsByRawValue() throws {
        XCTAssertLessThan(try UnitInterval(rawValue: 1), try UnitInterval(rawValue: 2))
        XCTAssertLessThan(OpacityScalar.transparent, OpacityScalar.opaque)
        XCTAssertLessThan(NormalizedColorComponent.zero, NormalizedColorComponent.one)
    }

    func testAuthoredRationalTimeIsExactRationalReuse() throws {
        // §5.4: authored frame/time mapping is exact rational; the alias reuses the Task-002 engine.
        let t: AuthoredRationalTime = try RationalSourceTime(numerator: 15_000, denominator: 30_000)
        XCTAssertEqual(t.numerator, 1)
        XCTAssertEqual(t.denominator, 2)
    }

    private func assertOutOfRange(_ error: Error, _ field: String) {
        guard case let RenderModelError.valueOutOfRange(f, _, _, _)? = error as? RenderModelError else {
            return XCTFail("expected valueOutOfRange for \(field), got \(error)")
        }
        XCTAssertEqual(f, field)
    }

    // MARK: - §17 step 7: Double → fixed-point conversion boundary

    func testCanvasScalarRoundsToNearest() throws {
        // 65,536 units per point. Whole points are exact.
        XCTAssertEqual(try FixedPointConversion.canvasScalar(points: 0, field: "x").rawValue, 0)
        XCTAssertEqual(try FixedPointConversion.canvasScalar(points: 1, field: "x").rawValue, 65_536)
        XCTAssertEqual(try FixedPointConversion.canvasScalar(points: 540, field: "x").rawValue, 540 * 65_536)
        // 0.5 / 65536 point lands exactly on a tie at the raw grid → ties away from zero.
        // 1.5 raw units rounds to 2 (away from zero); -1.5 rounds to -2.
        let half = 1.5 / Double(CanvasScalar.unitsPerPoint)
        XCTAssertEqual(try FixedPointConversion.canvasScalar(points: half, field: "x").rawValue, 2)
        XCTAssertEqual(try FixedPointConversion.canvasScalar(points: -half, field: "x").rawValue, -2)
    }

    func testScaleAndRotationConversion() throws {
        // Authored scale is a percent: 100% → 1.0 → 1_000_000 raw; 50% → 500_000.
        XCTAssertEqual(try FixedPointConversion.scaleScalar(percent: 100, field: "s").rawValue, 1_000_000)
        XCTAssertEqual(try FixedPointConversion.scaleScalar(percent: 50, field: "s").rawValue, 500_000)
        XCTAssertEqual(try FixedPointConversion.rotationScalar(degrees: 90, field: "r").rawValue, 90_000)
        XCTAssertEqual(try FixedPointConversion.rotationScalar(degrees: -45.5, field: "r").rawValue, -45_500)
    }

    func testOpacityConversionPercentAndUnit() throws {
        // Percent opacity: 100 → 1.0; 50 → 0.5.
        XCTAssertEqual(try FixedPointConversion.opacity(percent: 100, field: "o").rawValue, 1_000_000)
        XCTAssertEqual(try FixedPointConversion.opacity(percent: 50, field: "o").rawValue, 500_000)
        // Unit opacity (stroke): 1.0 → 1.0; 0.25 → 0.25.
        XCTAssertEqual(try FixedPointConversion.opacity(unit: 1.0, field: "o").rawValue, 1_000_000)
        XCTAssertEqual(try FixedPointConversion.opacity(unit: 0.25, field: "o").rawValue, 250_000)
    }

    func testExactRationalSpecificValues() throws {
        // 0.1 is exactly 3602879701896397 / 2^55 in IEEE-754 double.
        let tenth = try FixedPointConversion.exactRational(0.1, field: "t")
        XCTAssertEqual(tenth, try RationalSourceTime(numerator: 3_602_879_701_896_397, denominator: 36_028_797_018_963_968))
        // 29.97 round-trips back to the same double.
        let r2997 = try FixedPointConversion.exactRational(29.97, field: "t")
        XCTAssertEqual(Double(r2997.numerator) / Double(r2997.denominator), 29.97, accuracy: 0)
        // +0 and -0 both map to zero.
        XCTAssertEqual(try FixedPointConversion.exactRational(0.0, field: "t"), .zero)
        XCTAssertEqual(try FixedPointConversion.exactRational(-0.0, field: "t"), .zero)
        // 2^-30 is exactly 1 / 2^30.
        let eps = Double(sign: .plus, exponent: -30, significand: 1)
        XCTAssertEqual(try FixedPointConversion.exactRational(eps, field: "t"),
                       try RationalSourceTime(numerator: 1, denominator: 1_073_741_824))
        // Int64.min is exactly representable as a Double (-2^63) and converts to numerator Int64.min.
        let int64MinDouble = Double(sign: .minus, exponent: 63, significand: 1)   // -2^63
        let rmin = try FixedPointConversion.exactRational(int64MinDouble, field: "t")
        XCTAssertEqual(rmin.numerator, Int64.min)
        XCTAssertEqual(rmin.denominator, 1)
        // An unrepresentable denominator: a tiny value needing 2^-60 > Int64 denominator → typed overflow.
        let tiny = Double(sign: .plus, exponent: -62, significand: 1)   // 2^-62, denominator 2^62 fits;
        XCTAssertNoThrow(try FixedPointConversion.exactRational(tiny, field: "t"))
        let tooTiny = Double(sign: .plus, exponent: -64, significand: 1) // 2^-64 → denominator 2^64 overflow
        XCTAssertThrowsError(try FixedPointConversion.exactRational(tooTiny, field: "t")) {
            guard case TemplateNumericConversionError.rationalOverflow? = $0 as? TemplateNumericConversionError else {
                return XCTFail("expected rationalOverflow, got \($0)")
            }
        }
    }

    func testExactRationalKeepsSubMicroDistinctValues() throws {
        // Two authored times differing by 2^-30 (≈ 9.3e-10, far below 1e-6). The old fixed-1e-6
        // quantization (× 1_000_000, round) collapsed both to the same numerator (500000); the exact
        // rational conversion keeps them distinct (item 3).
        let epsilon = Double(sign: .plus, exponent: -30, significand: 1)   // 2^-30
        let v1 = 0.5
        let v2 = 0.5 + epsilon
        // Sanity: the old quantization really collapsed them.
        XCTAssertEqual((v1 * 1_000_000).rounded(.toNearestOrAwayFromZero),
                       (v2 * 1_000_000).rounded(.toNearestOrAwayFromZero))
        // Exact rationals are distinct.
        let a = try FixedPointConversion.exactRational(v1, field: "t")
        let b = try FixedPointConversion.exactRational(v2, field: "t")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, try RationalSourceTime(numerator: 1, denominator: 2))   // 0.5 == 1/2 exactly
        // Exact whole values stay clean.
        XCTAssertEqual(try FixedPointConversion.exactRational(150, field: "t"), try RationalSourceTime(numerator: 150, denominator: 1))
    }

    func testTiesAwayFromZeroExactly() throws {
        // 2.5 raw units (a half-tie) → 3 away from zero; -2.5 → -3.
        let twoPointFive = 2.5 / Double(CanvasScalar.unitsPerPoint)
        XCTAssertEqual(try FixedPointConversion.canvasScalar(points: twoPointFive, field: "x").rawValue, 3)
        XCTAssertEqual(try FixedPointConversion.canvasScalar(points: -twoPointFive, field: "x").rawValue, -3)
    }

    func testNaNRejected() {
        XCTAssertThrowsError(try FixedPointConversion.canvasScalar(points: .nan, field: "x")) {
            XCTAssertEqual($0 as? TemplateNumericConversionError, .notANumber(field: "x"))
        }
    }

    func testInfinityRejected() {
        XCTAssertThrowsError(try FixedPointConversion.scaleScalar(percent: .infinity, field: "s")) {
            XCTAssertEqual($0 as? TemplateNumericConversionError, .notFinite(field: "s"))
        }
        XCTAssertThrowsError(try FixedPointConversion.rotationScalar(degrees: -.infinity, field: "r")) {
            XCTAssertEqual($0 as? TemplateNumericConversionError, .notFinite(field: "r"))
        }
    }

    func testFixedPointOverflowRejected() {
        // A point value so large its raw fixed-point magnitude exceeds Int64.
        let huge = 1.0e30
        XCTAssertThrowsError(try FixedPointConversion.canvasScalar(points: huge, field: "x")) {
            guard case TemplateNumericConversionError.fixedPointOverflow(let f, _)? =
                $0 as? TemplateNumericConversionError else {
                return XCTFail("expected fixedPointOverflow, got \($0)")
            }
            XCTAssertEqual(f, "x")
        }
    }

    func testExactIntegerNarrowing() throws {
        XCTAssertEqual(try FixedPointConversion.exactInteger(1080, field: "w"), 1080)
        XCTAssertThrowsError(try FixedPointConversion.exactInteger(10.5, field: "w")) {
            guard case TemplateNumericConversionError.integerOutOfRange? = $0 as? TemplateNumericConversionError else {
                return XCTFail("expected integerOutOfRange, got \($0)")
            }
        }
        XCTAssertThrowsError(try FixedPointConversion.exactInteger(.nan, field: "w")) {
            XCTAssertEqual($0 as? TemplateNumericConversionError, .notANumber(field: "w"))
        }
        XCTAssertThrowsError(try FixedPointConversion.exactInteger(1.0e30, field: "w")) {
            guard case TemplateNumericConversionError.integerOutOfRange? = $0 as? TemplateNumericConversionError else {
                return XCTFail("expected integerOutOfRange, got \($0)")
            }
        }
    }
}
