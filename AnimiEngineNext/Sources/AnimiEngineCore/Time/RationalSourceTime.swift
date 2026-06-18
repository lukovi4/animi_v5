/// An exact rational source presentation time, in seconds (Task-002 plan, §4.2; corrective plan C-3).
///
/// Source targets are **not** forced onto the asset's native integer tick grid. A
/// `RationalSourceTime` is always reduced by GCD and has a strictly positive denominator, so
/// equivalent fractions (`15000/30000`, `300/600`, `1/2`) are equal. The numerator is signed —
/// negative source PTS values are allowed.
///
/// Arithmetic uses the **proven reduced-rational algorithm** (corrective plan C-3): denominators are
/// reduced first and kept in 64-bit; the numerator is formed in signed 128-bit width; reduction uses
/// `gcd` against a 64-bit value (`UInt128 % UInt64`). The `Int64` fit is checked **only on the final
/// reduced result**. There is no `Decimal`/`Float`/`Double`, no "widen on overflow", and no general
/// `UInt128 ÷ UInt128` or `UInt128` GCD.
///
/// Signed-narrowing rules (enforced wherever a rational is constructed):
/// - positive numerator magnitude must be `<= Int64.max`;
/// - negative numerator magnitude may equal `2^63` and becomes exactly `Int64.min`;
/// - denominator must be `1...Int64.max`.
public struct RationalSourceTime: Hashable, Comparable, Sendable {
    public let numerator: Int64              // signed
    public let denominator: Int64            // > 0, always reduced

    /// Reduces `numerator/denominator` to lowest terms with a positive denominator.
    public init(numerator: Int64, denominator: Int64) throws {
        guard denominator != 0 else {
            throw TimeError.nonPositiveDenominator(field: "RationalSourceTime.denominator", value: 0)
        }
        // Work in unsigned magnitudes (correct for Int64.min, whose magnitude is exactly 2^63).
        let negative = (numerator < 0) != (denominator < 0)
        let nMag = numerator.magnitude          // UInt64; 2^63 for Int64.min
        let dMag = denominator.magnitude
        let g = RationalSupport.gcd64(nMag, dMag) // g > 0 because dMag > 0
        let reducedN = nMag / g
        let reducedD = dMag / g
        let (n, d) = try RationalSourceTime.narrow(negative: negative, numeratorMagnitude: reducedN, denominatorMagnitude: reducedD)
        self.numerator = n
        self.denominator = d
    }

    init(reducedNumerator numerator: Int64, positiveDenominator denominator: Int64) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public static let zero = RationalSourceTime(reducedNumerator: 0, positiveDenominator: 1)

    /// Narrows a reduced unsigned magnitude pair to a signed numerator / positive denominator,
    /// applying the signed-narrowing rules. Throws ``TimeError/rationalDoesNotFit`` otherwise.
    static func narrow(negative: Bool, numeratorMagnitude nMag: UInt64, denominatorMagnitude dMag: UInt64) throws -> (Int64, Int64) {
        // Denominator must be 1...Int64.max (magnitude 2^63 is rejected).
        guard dMag >= 1, dMag <= UInt64(Int64.max) else { throw TimeError.rationalDoesNotFit }
        let denominator = Int64(dMag)
        // Numerator sign narrowing.
        if nMag == 0 {
            return (0, denominator)
        }
        if negative {
            // Negative magnitude may be 2^63 (→ Int64.min); otherwise must be <= Int64.max.
            if nMag == UInt64(Int64.max) + 1 {
                return (Int64.min, denominator)
            }
            guard nMag <= UInt64(Int64.max) else { throw TimeError.rationalDoesNotFit }
            return (-Int64(nMag), denominator)
        } else {
            guard nMag <= UInt64(Int64.max) else { throw TimeError.rationalDoesNotFit }
            return (Int64(nMag), denominator)
        }
    }

    /// Exact comparison via full-width signed cross multiplication; never throws (Task-002 plan, §4.2).
    public static func < (lhs: RationalSourceTime, rhs: RationalSourceTime) -> Bool {
        // Compare lhs.n/lhs.d vs rhs.n/rhs.d ⇔ lhs.n·rhs.d vs rhs.n·lhs.d (denominators > 0).
        let left = SInt128.product(lhs.numerator, UInt64(rhs.denominator))
        let right = SInt128.product(rhs.numerator, UInt64(lhs.denominator))
        return RationalSourceTime.signedLess(left, right)
    }

    /// Signed 128-bit `<` (zero is non-negative).
    static func signedLess(_ a: SInt128, _ b: SInt128) -> Bool {
        if a.negative != b.negative {
            // a negative & b non-negative ⇒ a < b.
            return a.negative
        }
        // Same sign.
        if a.negative {
            // Both negative: larger magnitude is the smaller value.
            return b.magnitude < a.magnitude
        } else {
            return a.magnitude < b.magnitude
        }
    }

    public static func == (lhs: RationalSourceTime, rhs: RationalSourceTime) -> Bool {
        // Both reduced with positive denominator, so structural equality is exact equality.
        lhs.numerator == rhs.numerator && lhs.denominator == rhs.denominator
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(numerator)
        hasher.combine(denominator)
    }

    /// Exact addition (corrective plan C-3): reduce denominators first, form the signed numerator in
    /// 128-bit width, reduce against the 64-bit denominator factors, then narrow once.
    public func adding(_ other: RationalSourceTime) throws -> RationalSourceTime {
        let b = UInt64(denominator)
        let d = UInt64(other.denominator)
        let g = RationalSupport.gcd64(b, d)         // g > 0
        let bp = b / g                              // b' = b / g
        let dp = d / g                              // d' = d / g
        // N = a·d' + c·b'  (signed 128-bit). a,c are Int64; d',b' are 64-bit.
        let term1 = SInt128.product(numerator, dp)
        let term2 = SInt128.product(other.numerator, bp)
        var n = term1 + term2
        // Denominator factor = b'·d  (64-bit × 64-bit). Reduce N by gcd in two 64-bit-divisor steps.
        // Step 1: cancel gcd(|N|, b').
        let g1 = RationalSupport.gcd128by64(n.magnitude, bp)
        let bpp: UInt64
        if g1 > 1 {
            n = n.dividedByU64(g1)
            bpp = bp / g1
        } else {
            bpp = bp
        }
        // Step 2: cancel gcd(|N|, d).
        let g2 = RationalSupport.gcd128by64(n.magnitude, d)
        let dpp: UInt64
        if g2 > 1 {
            n = n.dividedByU64(g2)
            dpp = d / g2
        } else {
            dpp = d
        }
        // Final denominator magnitude = bpp · dpp (may exceed 64 bits → overflow signal).
        let denMag = UInt128.multiplyU64(bpp, dpp)
        guard denMag.fitsInt64Magnitude else { throw TimeError.rationalDoesNotFit }
        guard n.magnitude.fitsInt64Magnitude || (n.negative && n.magnitude.isTwoToThe63) else {
            throw TimeError.rationalDoesNotFit
        }
        let (rn, rd) = try RationalSourceTime.narrow(
            negative: n.negative, numeratorMagnitude: n.magnitude.low, denominatorMagnitude: denMag.low
        )
        return RationalSourceTime(reducedNumerator: rn, positiveDenominator: rd)
    }

    /// Exact subtraction `self − other`, formed entirely in signed 128-bit with **no negation of any
    /// `Int64`** (step-9 final corrective #2): the second term's sign flag is inverted (a flag flip, not
    /// an `Int64` negation), so `Int64.min` numerators are safe. Mirrors `adding`'s reduction.
    public func subtracting(_ other: RationalSourceTime) throws -> RationalSourceTime {
        let b = UInt64(denominator)
        let d = UInt64(other.denominator)
        let g = RationalSupport.gcd64(b, d)
        let bp = b / g
        let dp = d / g
        // N = a·d' − c·b' : form a·d' and (−c·b') by flipping the sign flag of the second product.
        let term1 = SInt128.product(numerator, dp)
        let term2 = SInt128.product(other.numerator, bp)
        let negTerm2 = SInt128(negative: !term2.negative, magnitude: term2.magnitude)
        var n = term1 + negTerm2
        let g1 = RationalSupport.gcd128by64(n.magnitude, bp)
        let bpp: UInt64
        if g1 > 1 { n = n.dividedByU64(g1); bpp = bp / g1 } else { bpp = bp }
        let g2 = RationalSupport.gcd128by64(n.magnitude, d)
        let dpp: UInt64
        if g2 > 1 { n = n.dividedByU64(g2); dpp = d / g2 } else { dpp = d }
        let denMag = UInt128.multiplyU64(bpp, dpp)
        guard denMag.fitsInt64Magnitude else { throw TimeError.rationalDoesNotFit }
        guard n.magnitude.fitsInt64Magnitude || (n.negative && n.magnitude.isTwoToThe63) else {
            throw TimeError.rationalDoesNotFit
        }
        let (rn, rd) = try RationalSourceTime.narrow(
            negative: n.negative, numeratorMagnitude: n.magnitude.low, denominatorMagnitude: denMag.low)
        return RationalSourceTime(reducedNumerator: rn, positiveDenominator: rd)
    }

    /// Exact multiplication (corrective plan C-3): cross-cancel operands in 64-bit before widening,
    /// then form one `UInt64 × UInt64` product per side — already coprime, so narrow directly.
    public func multiplied(by other: RationalSourceTime) throws -> RationalSourceTime {
        let negative = (numerator < 0) != (other.numerator < 0)
        var aMag = numerator.magnitude
        var bMag = UInt64(denominator)
        var cMag = other.numerator.magnitude
        var dMag = UInt64(other.denominator)
        // Cross-cancel: gcd(|a|, d) and gcd(|c|, b).
        let g1 = RationalSupport.gcd64(aMag, dMag)
        if g1 > 1 { aMag /= g1; dMag /= g1 }
        let g2 = RationalSupport.gcd64(cMag, bMag)
        if g2 > 1 { cMag /= g2; bMag /= g2 }
        // numerator = a·c, denominator = b·d, each UInt64 × UInt64 → UInt128. Now coprime.
        let numMag = UInt128.multiplyU64(aMag, cMag)
        let denMag = UInt128.multiplyU64(bMag, dMag)
        guard denMag.fitsInt64Magnitude else { throw TimeError.rationalDoesNotFit }
        guard numMag.fitsInt64Magnitude || (negative && numMag.isTwoToThe63) else {
            throw TimeError.rationalDoesNotFit
        }
        let (rn, rd) = try RationalSourceTime.narrow(
            negative: negative, numeratorMagnitude: numMag.low, denominatorMagnitude: denMag.low
        )
        return RationalSourceTime(reducedNumerator: rn, positiveDenominator: rd)
    }
}
