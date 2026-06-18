/// Task-003 / Step-11 (Rev-4 §4.1) — deterministic checked fixed-point 2D vector helpers for the
/// stroke-mesh builder.
///
/// All coordinates are `CanvasScalar` raw units (65,536 per canvas point). Every operation is exact
/// integer arithmetic: full-width 128-bit intermediates where a product can exceed `Int64`, a
/// deterministic integer square root (no `Float`/`Double`, no platform `sqrt`), and checked narrowing.
/// There is no `precondition`/`fatalError`/trap reachable from public input — a genuine overflow throws
/// a typed ``TimeError``. The result is bit-identical on every platform.
public enum FixedVectorMath {

    /// A 2D vector in `CanvasScalar` raw units.
    public struct Vec2: Hashable, Sendable {
        public let x: Int64
        public let y: Int64
        public init(x: Int64, y: Int64) { self.x = x; self.y = y }
    }

    // MARK: - Basic checked operations

    public static func subtract(_ a: Vec2, _ b: Vec2, _ op: String) throws -> Vec2 {
        Vec2(x: try CheckedInt64.subtract(a.x, b.x, "\(op).x"),
             y: try CheckedInt64.subtract(a.y, b.y, "\(op).y"))
    }

    public static func add(_ a: Vec2, _ b: Vec2, _ op: String) throws -> Vec2 {
        Vec2(x: try CheckedInt64.add(a.x, b.x, "\(op).x"),
             y: try CheckedInt64.add(a.y, b.y, "\(op).y"))
    }

    /// Checked squared magnitude `x² + y²` as an exact unsigned 128-bit value (never overflows for any
    /// `Int64` components).
    static func squaredMagnitude128(_ v: Vec2) -> UInt128 {
        UInt128.multiplyU64(v.x.magnitude, v.x.magnitude) + UInt128.multiplyU64(v.y.magnitude, v.y.magnitude)
    }

    /// Exact dot product `a·b` as `Int64`, full-width then checked-narrow.
    public static func dot(_ a: Vec2, _ b: Vec2, _ op: String) throws -> Int64 {
        let p = FixedPointMath.signedProduct(a.x, b.x) + FixedPointMath.signedProduct(a.y, b.y)
        return try FixedPointMath.narrow(magnitude: p.magnitude, negative: p.negative, operation: "\(op).dot")
    }

    /// Exact 2D cross product `a×b = a.x·b.y − a.y·b.x` as `Int64`, full-width then checked-narrow.
    public static func cross(_ a: Vec2, _ b: Vec2, _ op: String) throws -> Int64 {
        let p = FixedPointMath.signedProduct(a.x, b.y) + negate(FixedPointMath.signedProduct(a.y, b.x))
        return try FixedPointMath.narrow(magnitude: p.magnitude, negative: p.negative, operation: "\(op).cross")
    }

    private static func negate(_ s: SInt128) -> SInt128 {
        SInt128(negative: !s.negative, magnitude: s.magnitude)
    }

    // MARK: - Deterministic integer square root

    /// Floor of the square root of a 128-bit value, exact integer (binary digit-by-digit / Newton-free
    /// bit method). Deterministic and trap-free.
    static func isqrt128(_ n: UInt128) -> UInt128 {
        if n.isZero { return .zero }
        // Bit-by-bit integer sqrt. `bit` starts at the highest power of four <= n.
        var rem = n
        var root = UInt128.zero
        // Highest even bit position <= 127.
        var bit = oneShiftedLeft(126)
        // Lower `bit` until it does not exceed `rem`.
        while bit > rem { bit = shiftRight2(bit) }
        while !bit.isZero {
            let rootPlusBit = root + bit
            if !(rem < rootPlusBit) {            // rem >= root + bit
                rem = rem - rootPlusBit
                root = shiftRight1(root) + bit
            } else {
                root = shiftRight1(root)
            }
            bit = shiftRight2(bit)
        }
        return root
    }

    /// Rounded (nearest, ties up) integer length `round(sqrt(dx² + dy²))` in `CanvasScalar` raw units.
    /// Throws if the result does not fit `Int64` (a length that large is itself rejected upstream).
    public static func length(_ v: Vec2, _ op: String) throws -> Int64 {
        let sq = squaredMagnitude128(v)
        let floorRoot = isqrt128(sq)
        // Round to nearest integer root, ties away from zero. The midpoint between r and r+1 in the
        // squared domain is (r+0.5)^2 = r^2 + r + 0.25, so round up exactly when
        //   sq - r^2 >= r + 0.25  ⇔  2*(sq - r^2) >= 2r + 1  (integers; ties at frac = r round up).
        let rootSquared = UInt128.multiplyU64(floorRoot.low, floorRoot.low) // floorRoot fits 64 bits for any realistic length
        let frac = sq - rootSquared
        let twiceFrac = frac + frac
        let twoRootPlusOne = floorRoot + floorRoot + UInt128(1)
        var rounded = floorRoot
        if floorRoot.high == 0, !(twiceFrac < twoRootPlusOne) {  // 2*frac >= 2r+1  → round up
            rounded = floorRoot + UInt128(1)
        }
        guard rounded.fitsInt64Magnitude else {
            throw TimeError.integerOverflow(operation: "\(op).length")
        }
        return Int64(rounded.low)
    }

    // MARK: - Perpendicular half-width offset

    /// The left-perpendicular unit-direction offset of `segment` scaled to `halfWidth`, in raw units:
    /// `offset = halfWidth · perp(dir) / |dir|`, rounded, where `perp((dx,dy)) = (-dy, dx)`.
    /// `|dir|` must be positive (a zero-length segment is rejected by the caller).
    public static func perpendicularOffset(segment: Vec2, halfWidth: Int64, _ op: String) throws -> Vec2 {
        let len = try length(segment, "\(op).segLen")
        guard len > 0 else {
            throw TimeError.nonPositiveDenominator(field: "\(op).segLen", value: len)
        }
        // perp = (-dy, dx); scale by halfWidth/len with full-width rounding.
        let negDy = try CheckedInt64.subtract(0, segment.y, "\(op).negDy")
        let ox = try FixedPointMath.multiplyDivideRounding(negDy, halfWidth, len, "\(op).ox")
        let oy = try FixedPointMath.multiplyDivideRounding(segment.x, halfWidth, len, "\(op).oy")
        return Vec2(x: ox, y: oy)
    }

    // MARK: - Line intersection (for miter joins)

    /// Intersection of line through `p0` with direction `d0` and line through `p1` with direction `d1`.
    /// Returns `nil` when the lines are parallel (zero cross product). Coordinates are exact rounded
    /// `CanvasScalar` raw units. Uses the parametric solution `p0 + t·d0`, `t = ((p1−p0)×d1)/(d0×d1)`.
    public static func lineIntersection(
        p0: Vec2, d0: Vec2, p1: Vec2, d1: Vec2, _ op: String
    ) throws -> Vec2? {
        let denom = try cross(d0, d1, "\(op).denom")
        if denom == 0 { return nil }
        let diff = try subtract(p1, p0, "\(op).diff")
        let tNum = try cross(diff, d1, "\(op).tNum")
        // point = p0 + d0 · (tNum / denom), component-wise with full-width rounding (denom may be negative).
        let posDenom = denom < 0 ? try CheckedInt64.subtract(0, denom, "\(op).denomAbs") : denom
        let tNumSigned = denom < 0 ? try CheckedInt64.subtract(0, tNum, "\(op).tNumFlip") : tNum
        let dx = try FixedPointMath.multiplyDivideRounding(d0.x, tNumSigned, posDenom, "\(op).dx")
        let dy = try FixedPointMath.multiplyDivideRounding(d0.y, tNumSigned, posDenom, "\(op).dy")
        return Vec2(x: try CheckedInt64.add(p0.x, dx, "\(op).px"),
                    y: try CheckedInt64.add(p0.y, dy, "\(op).py"))
    }

    // MARK: - Miter-limit comparison

    /// Whether the miter is within the limit: `miterLength / halfWidth <= miterLimit`, compared exactly
    /// without division. `miterLength` and `halfWidth` are raw lengths; `miterLimitRaw` is `MiterScalar`
    /// raw (1,000,000 per 1.0). Tests `miterLength · 1_000_000 <= miterLimitRaw · halfWidth` in
    /// full-width 128-bit (never overflows, no division).
    public static func miterWithinLimit(
        miterLength: Int64, halfWidth: Int64, miterLimitRaw: Int64, miterUnitsPerOne: Int64
    ) -> Bool {
        // Both sides are non-negative (lengths and a positive limit).
        let lhs = UInt128.multiplyU64(miterLength.magnitude, miterUnitsPerOne.magnitude)
        let rhs = UInt128.multiplyU64(miterLimitRaw.magnitude, halfWidth.magnitude)
        return !(rhs < lhs)   // lhs <= rhs
    }

    // MARK: - Internal 128-bit bit helpers (this module owns UInt128)

    private static func oneShiftedLeft(_ bits: Int) -> UInt128 {
        if bits >= 64 {
            return UInt128(high: UInt64(1) << UInt64(bits - 64), low: 0)
        }
        return UInt128(high: 0, low: UInt64(1) << UInt64(bits))
    }

    private static func shiftRight1(_ v: UInt128) -> UInt128 {
        let low = (v.low >> 1) | (v.high << 63)
        let high = v.high >> 1
        return UInt128(high: high, low: low)
    }

    private static func shiftRight2(_ v: UInt128) -> UInt128 {
        shiftRight1(shiftRight1(v))
    }
}
