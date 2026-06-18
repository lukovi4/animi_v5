/// Task-003 step-8 corrective (issue #7) — public exact fixed-point helpers built on the existing
/// 128-bit support, so render-side fixed-point math never overflows a 64-bit intermediate and never
/// traps.
///
/// `AnimiEngineCore` already has `UInt128`/`SInt128` (`Int128.swift`) with `multipliedFullWidth` /
/// `dividingFullWidth` primitives, but they are `internal`. This enum exposes the two operations the
/// render layer needs — a full-width multiply-then-divide with round-to-nearest/ties-away-from-zero,
/// and a checked narrowing back to `Int64` — without leaking the 128-bit representation. Every path is
/// total (throws ``TimeError`` on a true out-of-range result) and contains **no** `Float`/`Double` and
/// **no** `precondition`/`fatalError` reachable from public input.
public enum FixedPointMath {

    /// Computes `round(value * factor / divisor)` exactly, with ties away from zero, using a full-width
    /// 128-bit intermediate so `value * factor` never overflows for any `Int64` operands (including
    /// `Int64.min`/`Int64.max`, whose magnitudes are formed via `UInt64`).
    ///
    /// **Contract (issue #2):** `divisor` must be **strictly positive**. A zero or negative divisor is
    /// a typed failure (`TimeError.nonPositiveDenominator`), never a trap and never a silently
    /// sign-flipped result. The result must fit `Int64` or a typed overflow is thrown.
    ///
    /// The result sign is exactly `sign(value) * sign(factor)` (the divisor is positive), computed on
    /// the magnitudes so `value == Int64.min` works without forming `-value`.
    public static func multiplyDivideRounding(
        _ value: Int64, _ factor: Int64, _ divisor: Int64, _ operation: String
    ) throws -> Int64 {
        guard divisor > 0 else {
            throw TimeError.nonPositiveDenominator(field: operation, value: divisor)
        }
        // Exact signed 128-bit product = (sign(value) ⊕ sign(factor)) · (|value| · |factor|).
        // Both magnitudes are UInt64 (correct for Int64.min), so no intermediate Int64 overflow.
        let resultNegative = (value < 0) != (factor < 0)
        let productMagnitude = UInt128.multiplyU64(value.magnitude, factor.magnitude)

        let d = divisor.magnitude                       // positive divisor as UInt64
        let (quotient, remainder) = productMagnitude.divMod(byU64: d)
        // Round half away from zero: bump the magnitude when 2*remainder >= divisor.
        var resultMagnitude = quotient
        let twiceRemainder = UInt128.multiplyU64(remainder, 2)
        if !(twiceRemainder < UInt128(d)) {            // 2*remainder >= d
            resultMagnitude = resultMagnitude + UInt128(1)
        }
        return try narrow(magnitude: resultMagnitude, negative: resultNegative, operation: operation)
    }

    /// Computes `round((a·b + c·d) / divisor)` exactly, with ties away from zero, entirely in full-width
    /// 128-bit arithmetic (issue #2): there is **no intermediate `Int64` difference or sum** to overflow,
    /// no negation of `Int64.min`, and only the **final** narrowed result is range-checked. `divisor`
    /// must be strictly positive (a zero/negative divisor is a typed failure).
    ///
    /// This is the building block for an overflow-free `lerp`: `lo + (hi − lo)·frac` is computed as
    /// `(lo·(u − frac) + hi·frac) / u`, avoiding the `hi − lo` intermediate.
    public static func weightedSumDivide(
        _ a: Int64, _ b: Int64, _ c: Int64, _ d: Int64, _ divisor: Int64, _ operation: String
    ) throws -> Int64 {
        guard divisor > 0 else {
            throw TimeError.nonPositiveDenominator(field: operation, value: divisor)
        }
        // sum = sign(a·b)·|a·b| + sign(c·d)·|c·d|, formed in exact signed 128-bit (no Int64 hi−lo).
        let ab = signedProduct(a, b)
        let cd = signedProduct(c, d)
        let sum = ab + cd
        let dMag = divisor.magnitude
        let (quotient, remainder) = sum.magnitude.divMod(byU64: dMag)
        var resultMagnitude = quotient
        let twiceRemainder = UInt128.multiplyU64(remainder, 2)
        if !(twiceRemainder < UInt128(dMag)) {
            resultMagnitude = resultMagnitude + UInt128(1)
        }
        return try narrow(magnitude: resultMagnitude, negative: sum.negative, operation: operation)
    }

    /// Exact signed `Int64 × Int64 → SInt128` (correct for `Int64.min`, magnitudes via `UInt64`).
    static func signedProduct(_ x: Int64, _ y: Int64) -> SInt128 {
        SInt128(negative: (x < 0) != (y < 0), magnitude: UInt128.multiplyU64(x.magnitude, y.magnitude))
    }

    /// Narrows a signed 128-bit magnitude back to `Int64`, throwing on overflow (including the
    /// `Int64.min` boundary). No trap on any input. Internal: the 128-bit representation is not public.
    static func narrow(magnitude: UInt128, negative: Bool, operation: String) throws -> Int64 {
        if negative {
            if magnitude.isTwoToThe63 { return Int64.min }        // exact Int64.min
            guard magnitude.fitsInt64Magnitude else {
                throw TimeError.integerOverflow(operation: operation)
            }
            return -Int64(magnitude.low)
        } else {
            guard magnitude.fitsInt64Magnitude else {
                throw TimeError.integerOverflow(operation: operation)
            }
            return Int64(magnitude.low)
        }
    }
}
