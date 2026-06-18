/// Task-003 step-8 corrective (issue #6) — deterministic fixed-point sine/cosine for an **arbitrary**
/// `RotationScalar`, with no `Float`/`Double` anywhere (not even when generating the tables).
///
/// The algorithm is integer CORDIC in rotation mode with a **Q32.32** internal format (a real value
/// `v` is the integer `round(v · 2^32)`), a fixed 32 iterations, and explicit quadrant reduction so
/// the residual angle handed to CORDIC always lies in `[-π/2, π/2]` where it converges. The atan table,
/// the CORDIC gain and the π constants are **hardcoded** integer literals (golden-protected by tests);
/// they were produced at 80-digit precision and self-checked to ≤ 7 ULP of `2^32`. The final cosine and
/// sine are rounded into the render linear scale (`1_000_000` units per `1.0`).
///
/// Determinism: every operation is exact `Int64` integer arithmetic (shifts, adds, table lookups) plus
/// the exact full-width multiply/divide in ``FixedPointMath`` — the result is bit-identical on every
/// platform.
public enum FixedTrig {

    /// Q32.32 scale: `1.0` is represented by `2^32`.
    static let q32: Int64 = 4_294_967_296            // 2^32

    /// `round(π/2 · 2^32)`, `round(π · 2^32)`, `round(2π · 2^32)` (hardcoded; golden-protected).
    static let halfPiQ32: Int64 = 6_746_518_852
    static let piQ32: Int64     = 13_493_037_705
    static let twoPiQ32: Int64  = 26_986_075_409

    /// CORDIC gain `K = Π 1/√(1+2^-2i)` as `round(K · 2^32)` (the seed for `x`).
    static let cordicGainQ32: Int64 = 2_608_131_496

    /// `atanTable[i] = round(atan(2^-i) · 2^32)` for `i = 0..31` (hardcoded; golden-protected).
    static let atanTableQ32: [Int64] = [
        3_373_259_426, 1_991_351_318, 1_052_175_346, 534_100_635,
        268_086_748,   134_174_063,   67_103_403,    33_553_749,
        16_777_131,    8_388_597,     4_194_303,     2_097_152,
        1_048_576,     524_288,       262_144,       131_072,
        65_536,        32_768,        16_384,        8_192,
        4_096,         2_048,         1_024,         512,
        256,           128,           64,            32,
        16,            8,             4,             2
    ]

    static let iterations = 32

    /// Cosine and sine of an angle, each in the render linear scale (`1_000_000` units per `1.0`),
    /// rounded to nearest with ties away from zero. Pure integer; total (throws only on a genuine
    /// arithmetic overflow, which the bounded inputs here cannot reach).
    ///
    /// - Parameter rotationRaw: the angle in `RotationScalar` raw units (1,000 per degree).
    /// - Parameter linearUnitsPerOne: the output fixed-point scale (e.g. `1_000_000`).
    /// One full turn in `RotationScalar` raw units: 360° × 1,000 units/degree.
    static let fullTurnRaw: Int64 = 360_000

    public static func cosSin(
        rotationRaw: Int64, linearUnitsPerOne: Int64
    ) throws -> (cos: Int64, sin: Int64) {
        guard linearUnitsPerOne > 0 else {
            throw TimeError.nonPositiveDenominator(field: "FixedTrig.linearUnitsPerOne", value: linearUnitsPerOne)
        }

        // 0) Normalize the angle modulo one full turn **first** (issue #3), in the small integer raw
        //    domain. `Int64.min % fullTurnRaw` is well-defined (no `-Int64.min` is ever formed), so any
        //    `Int64` angle — including `Int64.min`/`Int64.max` — reduces without avoidable overflow, and
        //    the subsequent radian product stays tiny. `%` yields a value in (-fullTurnRaw, fullTurnRaw).
        let normalizedRaw = rotationRaw % fullTurnRaw

        // 1) Angle to Q32.32 radians: radians = degrees · π/180 = (raw/1000) · π/180.
        //    angleQ32 = round(normalizedRaw · piQ32 / (180 · 1000)) via full-width multiply/divide.
        let angleQ32 = try FixedPointMath.multiplyDivideRounding(
            normalizedRaw, piQ32, 180 * 1000, "FixedTrig.angle")

        // 2) Reduce into (-π, π] by taking modulo 2π on the integer Q32 value.
        var z = angleQ32 % twoPiQ32
        if z > piQ32 { z -= twoPiQ32 }
        else if z <= -piQ32 { z += twoPiQ32 }

        // 3) Reduce into [-π/2, π/2]; remember whether we flipped a half-turn (negates cos & sin).
        var negate = false
        if z > halfPiQ32 { z -= piQ32; negate = true }
        else if z < -halfPiQ32 { z += piQ32; negate = true }

        // 4) Integer CORDIC rotation, 32 iterations, in Q32.32.
        var x = cordicGainQ32
        var y: Int64 = 0
        for i in 0..<iterations {
            let dx = x >> Int64(i)            // arithmetic shift (sign-preserving) — x,y are small in Q32
            let dy = y >> Int64(i)
            if z >= 0 {
                x -= dy
                y += dx
                z -= atanTableQ32[i]
            } else {
                x += dy
                y -= dx
                z += atanTableQ32[i]
            }
        }
        if negate { x = -x; y = -y }

        // 5) Convert Q32.32 → linear scale, round-half-away, full-width (cos = x/2^32 · scale).
        let cos = try FixedPointMath.multiplyDivideRounding(x, linearUnitsPerOne, q32, "FixedTrig.cos")
        let sin = try FixedPointMath.multiplyDivideRounding(y, linearUnitsPerOne, q32, "FixedTrig.sin")
        return (cos, sin)
    }
}
