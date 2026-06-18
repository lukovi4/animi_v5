/// Minimal 128-bit integer support for exact rational arithmetic (Task-002 corrective plan, C-3).
///
/// This file intentionally provides **only** the operations the reduced-rational algorithm needs:
/// `UInt64 × UInt64 → UInt128`, `UInt128 ± UInt128`, and division/remainder by a **64-bit** divisor.
/// There is deliberately **no** general `UInt128 ÷ UInt128` and **no** `UInt128`-vs-`UInt128` GCD —
/// the algorithm keeps every denominator factor in 64-bit and only ever reduces a 128-bit numerator
/// against a 64-bit value (`UInt128 % UInt64`).

/// An unsigned 128-bit magnitude as a (high, low) pair of 64-bit limbs.
struct UInt128: Equatable, Comparable {
    let high: UInt64
    let low: UInt64

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    init(_ value: UInt64) {
        self.high = 0
        self.low = value
    }

    static let zero = UInt128(high: 0, low: 0)

    var isZero: Bool { high == 0 && low == 0 }

    /// Exact `UInt64 × UInt64 → UInt128` via `multipliedFullWidth`.
    static func multiplyU64(_ a: UInt64, _ b: UInt64) -> UInt128 {
        let (high, low) = a.multipliedFullWidth(by: b)
        return UInt128(high: high, low: low)
    }

    /// Exact addition. The callers only ever add two products each `< 2^126`, so the sum fits 127
    /// bits and never overflows the 128-bit representation.
    static func + (lhs: UInt128, rhs: UInt128) -> UInt128 {
        let (low, carry) = lhs.low.addingReportingOverflow(rhs.low)
        let high = lhs.high &+ rhs.high &+ (carry ? 1 : 0)
        return UInt128(high: high, low: low)
    }

    /// Exact subtraction; the caller guarantees `lhs >= rhs`.
    static func - (lhs: UInt128, rhs: UInt128) -> UInt128 {
        let (low, borrow) = lhs.low.subtractingReportingOverflow(rhs.low)
        let high = lhs.high &- rhs.high &- (borrow ? 1 : 0)
        return UInt128(high: high, low: low)
    }

    static func < (lhs: UInt128, rhs: UInt128) -> Bool {
        (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }

    /// The single exact division-by-64-bit-divisor implementation (corrective pass, issue #1).
    ///
    /// Uses `UInt64.dividingFullWidth` so the partial dividend `(high: rHigh, low: low)` is divided
    /// without ever forming `rHigh << 32`, which could lose high bits. This is the **only** division a
    /// 128-bit value participates in, and the divisor is always 64-bit; no `UInt128 ÷ UInt128`.
    ///
    /// Algorithm (for divisor `d > 0`):
    ///   qHigh = high / d ; rHigh = high % d
    ///   (qLow, r) = d.dividingFullWidth((high: rHigh, low: low))
    ///   quotient  = UInt128(high: qHigh, low: qLow)
    ///   remainder = r
    ///
    /// `rHigh < d`, so the full-width dividend `rHigh·2^64 + low` is `< d·2^64`, guaranteeing the
    /// quotient `qLow` fits 64 bits — `dividingFullWidth`'s precondition is met and it cannot trap.
    func divMod(byU64 d: UInt64) -> (quotient: UInt128, remainder: UInt64) {
        precondition(d > 0, "divisor must be positive")
        let qHigh = high / d
        let rHigh = high % d
        let (qLow, r) = d.dividingFullWidth((high: rHigh, low: low))
        return (UInt128(high: qHigh, low: qLow), r)
    }

    /// `self % d` for a 64-bit divisor `d > 0`. Delegates to ``divMod(byU64:)``.
    func remainderU64(_ d: UInt64) -> UInt64 {
        divMod(byU64: d).remainder
    }

    /// `self / d` for a 64-bit divisor `d > 0`. Delegates to ``divMod(byU64:)``.
    func dividedByU64(_ d: UInt64) -> UInt128 {
        divMod(byU64: d).quotient
    }

    /// Whether the magnitude fits a non-negative `Int64` (`<= Int64.max`).
    var fitsInt64Magnitude: Bool {
        high == 0 && low <= UInt64(Int64.max)
    }

    /// Whether the magnitude equals exactly `2^63` (the magnitude of `Int64.min`).
    var isTwoToThe63: Bool {
        high == 0 && low == UInt64(Int64.max) + 1
    }
}

/// A signed 128-bit integer as an explicit sign plus an unsigned magnitude. Used for the rational
/// numerator, which is a sum/difference of two `< 2^126` products and therefore fits 127 bits.
struct SInt128: Equatable {
    /// `negative == true` means a value `< 0`. Zero is canonically non-negative.
    let negative: Bool
    let magnitude: UInt128

    init(negative: Bool, magnitude: UInt128) {
        // Normalize the sign of zero.
        self.negative = magnitude.isZero ? false : negative
        self.magnitude = magnitude
    }

    /// Builds a signed 128-bit value from a 64-bit signed integer (correct for `Int64.min`).
    init(_ value: Int64) {
        self.init(negative: value < 0, magnitude: UInt128(value.magnitude))
    }

    static let zero = SInt128(negative: false, magnitude: .zero)

    var isZero: Bool { magnitude.isZero }

    /// The exact product `signed × factor` where `signed` is a 64-bit signed integer and `factor`
    /// is a 64-bit unsigned integer — an exact `UInt64 × UInt64 → UInt128` magnitude with the sign
    /// of `signed`. This is how each numerator term `a·d'` is formed (both 64-bit operands).
    static func product(_ signed: Int64, _ factor: UInt64) -> SInt128 {
        SInt128(negative: signed < 0, magnitude: UInt128.multiplyU64(signed.magnitude, factor))
    }

    /// Exact signed addition.
    static func + (lhs: SInt128, rhs: SInt128) -> SInt128 {
        if lhs.negative == rhs.negative {
            return SInt128(negative: lhs.negative, magnitude: lhs.magnitude + rhs.magnitude)
        }
        // Opposite signs: subtract the smaller magnitude from the larger; sign follows the larger.
        if lhs.magnitude < rhs.magnitude {
            return SInt128(negative: rhs.negative, magnitude: rhs.magnitude - lhs.magnitude)
        } else if rhs.magnitude < lhs.magnitude {
            return SInt128(negative: lhs.negative, magnitude: lhs.magnitude - rhs.magnitude)
        } else {
            return .zero
        }
    }

    /// `self / d` (sign preserved) for a 64-bit divisor `d > 0` that divides the magnitude exactly.
    func dividedByU64(_ d: UInt64) -> SInt128 {
        SInt128(negative: negative, magnitude: magnitude.dividedByU64(d))
    }
}

/// Shared exact-integer helpers for the rational layer.
enum RationalSupport {
    /// True unsigned `UInt64` GCD (Euclid). No clamp. `gcd(0, x) == x`, `gcd(0, 0) == 0`.
    static func gcd64(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var x = a
        var y = b
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x
    }

    /// `gcd(|N|, x)` where `N` is a 128-bit magnitude and `x` is 64-bit, computed as
    /// `gcd64(|N| % x, x)` — the only place a 128-bit value meets division, against a 64-bit divisor.
    static func gcd128by64(_ n: UInt128, _ x: UInt64) -> UInt64 {
        if x == 0 { return 0 }
        let r = n.remainderU64(x)
        return gcd64(r, x)
    }
}
