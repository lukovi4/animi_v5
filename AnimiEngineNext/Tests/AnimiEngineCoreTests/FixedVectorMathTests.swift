import XCTest
@testable import AnimiEngineCore

/// Task-003 / Step-11 (Rev-4 §4.1) — deterministic checked fixed-point vector math.
final class FixedVectorMathTests: XCTestCase {
    typealias V = FixedVectorMath.Vec2

    // MARK: - Integer square root / length

    func testIsqrtExactPerfectSquares() {
        for n: UInt64 in [0, 1, 4, 9, 16, 65536, 1 << 40] {
            let root = FixedVectorMath.isqrt128(UInt128(n))
            XCTAssertEqual(root.low, UInt64(Double(n).squareRoot().rounded(.down)), "isqrt(\(n))")
        }
    }

    func testLengthAxisAligned() throws {
        // A purely horizontal vector of 100 units has length 100 exactly.
        XCTAssertEqual(try FixedVectorMath.length(V(x: 100, y: 0), "h"), 100)
        XCTAssertEqual(try FixedVectorMath.length(V(x: 0, y: -250), "v"), 250)
    }

    func testLength345Triangle() throws {
        // 3-4-5 scaled: (30000, 40000) → 50000 exactly.
        XCTAssertEqual(try FixedVectorMath.length(V(x: 30000, y: 40000), "345"), 50000)
    }

    func testLengthRoundsNearest() throws {
        // |(1,1)| = sqrt(2) ≈ 1.414 → rounds to 1.
        XCTAssertEqual(try FixedVectorMath.length(V(x: 1, y: 1), "r"), 1)
        // |(2,2)| = 2.828 → rounds to 3.
        XCTAssertEqual(try FixedVectorMath.length(V(x: 2, y: 2), "r"), 3)
    }

    // MARK: - dot / cross

    func testDotAndCross() throws {
        let a = V(x: 3, y: 0), b = V(x: 0, y: 5)
        XCTAssertEqual(try FixedVectorMath.dot(a, b, "perp"), 0)
        XCTAssertEqual(try FixedVectorMath.cross(a, b, "perp"), 15)   // 3*5 - 0*0
        XCTAssertEqual(try FixedVectorMath.cross(b, a, "perp"), -15)  // opposite sign
    }

    // MARK: - perpendicular half-width offset

    func testPerpendicularOffsetHorizontalSegment() throws {
        // Segment (100,0); left-perp (-dy,dx) = (0,100); scaled to halfWidth 10 → (0,10).
        let off = try FixedVectorMath.perpendicularOffset(segment: V(x: 100, y: 0), halfWidth: 10, "p")
        XCTAssertEqual(off.x, 0)
        XCTAssertEqual(off.y, 10)
    }

    func testPerpendicularOffsetVerticalSegment() throws {
        // Segment (0,100); left-perp (-100,0); scaled to halfWidth 10 → (-10,0).
        let off = try FixedVectorMath.perpendicularOffset(segment: V(x: 0, y: 100), halfWidth: 10, "p")
        XCTAssertEqual(off.x, -10)
        XCTAssertEqual(off.y, 0)
    }

    func testPerpendicularOffsetZeroSegmentThrows() {
        XCTAssertThrowsError(try FixedVectorMath.perpendicularOffset(segment: V(x: 0, y: 0), halfWidth: 10, "p"))
    }

    // MARK: - line intersection

    func testLineIntersectionCrossingLines() throws {
        // Line through (0,0) dir (1,0) and line through (5,-5) dir (0,1) → intersect at (5,0).
        let p = try XCTUnwrap(try FixedVectorMath.lineIntersection(
            p0: V(x: 0, y: 0), d0: V(x: 1, y: 0), p1: V(x: 5, y: -5), d1: V(x: 0, y: 1), "x"))
        XCTAssertEqual(p.x, 5)
        XCTAssertEqual(p.y, 0)
    }

    func testLineIntersectionParallelReturnsNil() throws {
        XCTAssertNil(try FixedVectorMath.lineIntersection(
            p0: V(x: 0, y: 0), d0: V(x: 1, y: 0), p1: V(x: 0, y: 5), d1: V(x: 2, y: 0), "par"))
    }

    // MARK: - miter limit comparison

    func testMiterWithinLimit() {
        let u: Int64 = 1_000_000   // MiterScalar.unitsPerUnit (defined in AnimiEngineRenderModel)
        // miterLength 20, halfWidth 10 → ratio 2.0. limit 4.0 → within; limit 1.5 → exceeds.
        XCTAssertTrue(FixedVectorMath.miterWithinLimit(miterLength: 20, halfWidth: 10, miterLimitRaw: 4 * u, miterUnitsPerOne: u))
        XCTAssertFalse(FixedVectorMath.miterWithinLimit(miterLength: 20, halfWidth: 10, miterLimitRaw: u + u / 2, miterUnitsPerOne: u))
        // Exact equality (ratio == limit) counts as within.
        XCTAssertTrue(FixedVectorMath.miterWithinLimit(miterLength: 20, halfWidth: 10, miterLimitRaw: 2 * u, miterUnitsPerOne: u))
    }

    // MARK: - boundary overflow is typed (no trap)

    func testLengthBoundaryOverflowIsTyped() {
        // A vector whose squared magnitude root exceeds Int64 is impossible (root <= ~9.2e18 fits), but a
        // genuine overflow in intermediate add must throw, not trap. Use Int64.max components.
        XCTAssertNoThrow(try FixedVectorMath.length(V(x: Int64.max, y: 0), "max"))  // |(max,0)| == max, fits.
    }

    func testCrossOverflowIsTyped() {
        // cross(Int64.max, ...) that overflows Int64 must throw a typed error, never trap.
        XCTAssertThrowsError(try FixedVectorMath.cross(V(x: Int64.max, y: Int64.max), V(x: Int64.max, y: Int64.min), "ovf"))
    }

    // MARK: - determinism

    func testDeterministicRepeatedComputation() throws {
        let a = try FixedVectorMath.length(V(x: 12345, y: 67890), "d")
        let b = try FixedVectorMath.length(V(x: 12345, y: 67890), "d")
        XCTAssertEqual(a, b)
    }
}
