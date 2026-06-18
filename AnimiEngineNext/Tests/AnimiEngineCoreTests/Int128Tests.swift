import XCTest
@testable import AnimiEngineCore

/// Primitive 128-bit arithmetic tests with independent oracles (corrective pass, issues #2 and #5).
///
/// The division oracle does **not** reuse the production division algorithm: it reconstructs
/// `quotient · d + remainder` via `multipliedFullWidth` + 128-bit addition (a code path independent of
/// `divMod(byU64:)`) and checks it equals the original value, plus `remainder < d`.
final class Int128Tests: XCTestCase {

    // MARK: - Independent oracle helper

    /// Exact `(high, low)` 128-bit add with explicit carry; returns `nil` if it overflows 128 bits.
    /// Independent of production `UInt128 +` (corrective pass: no unchecked `+`).
    private func checkedAdd(_ a: (high: UInt64, low: UInt64), _ b: (high: UInt64, low: UInt64))
        -> (high: UInt64, low: UInt64)? {
        let (low, carry1) = a.low.addingReportingOverflow(b.low)
        let (h1, o1) = a.high.addingReportingOverflow(b.high)
        if o1 { return nil }
        let (high, o2) = h1.addingReportingOverflow(carry1 ? 1 : 0)
        if o2 { return nil }
        return (high, low)
    }

    /// Exact `value · d` reconstructed as a 128-bit `(high, low)` using `multipliedFullWidth` and
    /// explicit overflow checks. Returns `nil` if the true product exceeds 128 bits. No wrapping `&*`,
    /// no unchecked `UInt128 +`. Independent of `divMod`.
    private func multiply(_ value: UInt128, by d: UInt64) -> (high: UInt64, low: UInt64)? {
        // value·d = value.high·d·2^64 + value.low·d.
        let (lowHi, lowLo) = value.low.multipliedFullWidth(by: d)          // value.low·d  → bits [0,128)
        let (hiHi, hiLo) = value.high.multipliedFullWidth(by: d)           // value.high·d → bits [64,192)
        // value.high·d shifted by 2^64 occupies bits [64,192); its top 64 bits (hiHi) must be zero,
        // otherwise the product exceeds 128 bits.
        if hiHi != 0 { return nil }
        // Now combine: low part = lowLo; high part = lowHi + hiLo (with carry → overflow check).
        return checkedAdd((high: 0, low: lowHi), (high: 0, low: hiLo)).flatMap { mid -> (UInt64, UInt64)? in
            // `mid.high` is the carry out of the high-limb sum; if non-zero the product exceeds 128 bits.
            if mid.high != 0 { return nil }
            return (mid.low, lowLo)
        }
    }

    /// Asserts `value.divMod(byU64: d)` is exact: `q·d + r == value` (reconstructed with overflow
    /// checks, failing if `q·d` or `q·d + r` exceeds 128 bits) and `r < d`.
    private func assertExactDivision(_ value: UInt128, _ d: UInt64,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let (q, r) = value.divMod(byU64: d)
        XCTAssertLessThan(r, d, "remainder must be < divisor", file: file, line: line)
        guard let product = multiply(q, by: d) else {
            return XCTFail("q·d exceeded 128 bits — reconstruction overflow", file: file, line: line)
        }
        guard let reconstructed = checkedAdd(product, (high: 0, low: r)) else {
            return XCTFail("q·d + r exceeded 128 bits — reconstruction overflow", file: file, line: line)
        }
        XCTAssertEqual(reconstructed.high, value.high, "q·d + r high limb must equal the dividend", file: file, line: line)
        XCTAssertEqual(reconstructed.low, value.low, "q·d + r low limb must equal the dividend", file: file, line: line)
    }

    // MARK: - #2: direct primitive division vectors

    func testRequiredVector_2Pow64_DividedByIntMax() {
        // UInt128(high: 1, low: 0) == 2^64. 2^64 / Int64.max:
        //   Int64.max = 2^63 - 1, 2·(2^63 - 1) = 2^64 - 2, so quotient = 2, remainder = 2^64 - (2^64-2) = 2.
        let value = UInt128(high: 1, low: 0)
        let (q, r) = value.divMod(byU64: UInt64(Int64.max))
        XCTAssertEqual(q, UInt128(2))
        XCTAssertEqual(r, 2)
        XCTAssertEqual(value.dividedByU64(UInt64(Int64.max)), UInt128(2))
        XCTAssertEqual(value.remainderU64(UInt64(Int64.max)), 2)
    }

    func testBoundaryVectorsWithHighLimbAndLargeDivisors() {
        let vectors: [(UInt128, UInt64)] = [
            (UInt128(high: 1, low: 0), UInt64(Int64.max)),
            (UInt128(high: 1, low: 0), UInt64.max),                       // 2^64 / (2^64-1) = 1 r 1
            (UInt128(high: UInt64.max, low: UInt64.max), UInt64.max),     // max128 / max64
            (UInt128(high: UInt64.max, low: UInt64.max), UInt64(Int64.max)),
            (UInt128(high: 12345, low: 67890), 9_223_372_036_854_775_783), // large prime-ish divisor
            (UInt128(high: 1, low: 1), 2),
            (UInt128(high: 0, low: UInt64.max), UInt64(Int64.max)),
            (UInt128(high: 7, low: 0), 3),
            (UInt128(high: UInt64.max, low: 0), 2)
        ]
        for (value, d) in vectors {
            assertExactDivision(value, d)
        }
    }

    func testDivisionMatchesPlainModuloWhenHighIsZero() {
        for (low, d): (UInt64, UInt64) in [(100, 7), (UInt64.max, 3), (0, 5), (999_999, 1_000)] {
            let value = UInt128(low)
            let (q, r) = value.divMod(byU64: d)
            XCTAssertEqual(q, UInt128(low / d))
            XCTAssertEqual(r, low % d)
        }
    }

    func test_2Pow64_DividedBy2() {
        // 2^64 / 2 = 2^63, remainder 0.
        let (q, r) = UInt128(high: 1, low: 0).divMod(byU64: 2)
        XCTAssertEqual(q, UInt128(high: 0, low: UInt64(1) << 63))
        XCTAssertEqual(r, 0)
    }

    // MARK: - #5: deterministic arithmetic oracles (high-limb add, reduction, division)

    func testHighLimbAdditionOracle() {
        // Addition oracle: compare (a + b) against the value reconstructed from independent limb math
        // with explicit carry (not the production `+`).
        let cases: [(UInt128, UInt128)] = [
            (UInt128(high: 0, low: UInt64.max), UInt128(1)),                       // carry into high
            (UInt128(high: 1, low: 5), UInt128(high: 2, low: 7)),
            (UInt128(high: 0, low: UInt64.max), UInt128(high: 0, low: UInt64.max)),
            (UInt128(high: 5, low: 0), UInt128(high: 0, low: 0))
        ]
        for (a, b) in cases {
            let sum = a + b
            // Independent limb addition with manual carry detection.
            let expectedLow = a.low &+ b.low
            let carry: UInt64 = (expectedLow < a.low) ? 1 : 0
            let expectedHigh = a.high &+ b.high &+ carry
            XCTAssertEqual(sum, UInt128(high: expectedHigh, low: expectedLow))
        }
    }

    func testReductionOracle() throws {
        // GCD reduction oracle: for known reducible fractions, the reduced result matches hand values.
        XCTAssertEqual(RationalSupport.gcd64(48, 18), 6)
        XCTAssertEqual(RationalSupport.gcd64(UInt64(Int64.max), 6), 1)   // Int64.max coprime to 6
        XCTAssertEqual(RationalSupport.gcd64(0, 9), 9)
        XCTAssertEqual(RationalSupport.gcd64(1_000_000, 240_000), 40_000)
        // gcd128by64 against a 128-bit magnitude (2^64) and a 64-bit divisor.
        // 2^64 mod 6 = 4 (since 2^64 = 18446744073709551616, /6 r 4); gcd(4,6) = 2.
        XCTAssertEqual(RationalSupport.gcd128by64(UInt128(high: 1, low: 0), 6), 2)
        // 2^64 mod 8 = 0 ⇒ gcd(0,8) = 8.
        XCTAssertEqual(RationalSupport.gcd128by64(UInt128(high: 1, low: 0), 8), 8)
    }

    func testDivisionOracleAcrossDeterministicVectors() {
        // A deterministic spread of high-limb dividends and divisors, each checked by the independent
        // reconstruction oracle (q·d + r == value, r < d).
        var value = UInt128(high: 3, low: 123_456_789)
        for d: UInt64 in [2, 3, 7, 1_000, UInt64(Int64.max), UInt64.max, 9_223_372_036_854_775_783] {
            assertExactDivision(value, d)
            // Evolve the vector deterministically (no randomness): rotate limbs and mix.
            value = UInt128(high: value.low ^ 0xA5A5_A5A5, low: value.high &+ 0x1234_5678_9ABC_DEF0)
        }
    }

    func testSInt128SignedDivisionPreservesSignAndMagnitude() {
        // SInt128 division by a 64-bit factor preserves sign; magnitude checked via the oracle.
        let mag = UInt128(high: 2, low: 4)
        let neg = SInt128(negative: true, magnitude: mag)
        let result = neg.dividedByU64(2)
        XCTAssertTrue(result.negative)
        assertExactDivision(mag, 2)
        XCTAssertEqual(result.magnitude, mag.dividedByU64(2))
    }
}
