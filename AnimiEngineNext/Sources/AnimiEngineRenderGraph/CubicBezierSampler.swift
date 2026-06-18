import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §7.2, §13 row "Animation" / "fixed-point cubic interpolation and hold keyframes"
/// (§17 step 9) — deterministic fixed-point cubic-bezier easing between two keyframes.
///
/// Authored AnimIR keyframes carry an out-tangent on the earlier keyframe and an in-tangent on the
/// later one (`RenderKeyframe.outTangent` / `.inTangent`, each a `RenderEasingVec2` of `EasingScalar`
/// handles). The eased fraction for a normalized segment position `s ∈ [0, 1]` is the cubic-bezier
/// `y(x = s)` where the control points are `(0,0), (ox, oy), (ix, iy), (1,1)` — the standard Lottie /
/// CSS `cubic-bezier(ox, oy, ix, iy)`.
///
/// Everything is exact fixed point (`UnitInterval`, 1,000,000 units per 1.0) with full-width 128-bit
/// intermediates; there is **no** `Float`/`Double`. The `x(t) = s` root is found by a fixed,
/// deterministic bisection so the result is bit-identical on every platform. A **hold** keyframe is
/// handled by the caller (it takes the earlier value verbatim — there is no interpolation).
public enum CubicBezierSampler {

    /// The number of bisection iterations. 1e6 scale has ~20 bits of fraction, so 40 iterations drive
    /// the `x` residual below 1 ULP deterministically.
    static let iterations = 40

    /// Eases a normalized segment position `s ∈ [0, 1]` through the cubic-bezier defined by the two
    /// tangent handles, returning the eased fraction `y ∈ [0, 1]` (also a `UnitInterval`).
    ///
    /// `outTangent`/`inTangent` are optional; a `nil` tangent defaults to the **linear** handle for
    /// that end (`(0,0)`-relative for out → `(0,0)`; in → `(1,1)`), i.e. a missing tangent means linear
    /// on that side. When both are absent the curve is the identity (`y = s`).
    public static func ease(
        s: UnitInterval,
        outTangent: RenderEasingVec2?,
        inTangent: RenderEasingVec2?
    ) throws -> UnitInterval {
        // Linear fast path: no handles → identity.
        if outTangent == nil, inTangent == nil { return s }

        let u = UnitInterval.unitsPerUnit
        // Control x/y in unit-scale fixed point. Defaults: out handle (0,0); in handle (1,1).
        let ox = outTangent?.x.rawValue ?? 0
        let oy = outTangent?.y.rawValue ?? 0
        let ix = inTangent?.x.rawValue ?? u
        let iy = inTangent?.y.rawValue ?? u

        // Find t such that bezierX(t) ≈ s by deterministic bisection on t ∈ [0, 1].
        let target = s.rawValue
        var lo: Int64 = 0
        var hi: Int64 = u
        for _ in 0..<iterations {
            let mid = lo + (hi - lo) / 2
            let x = try bezierAxis(t: mid, p1: ox, p2: ix, u: u)
            if x < target { lo = mid } else { hi = mid }
        }
        let t = lo + (hi - lo) / 2
        let y = try bezierAxis(t: t, p1: oy, p2: iy, u: u)
        let clamped = min(max(y, 0), u)
        return try UnitInterval(rawValue: clamped)
    }

    /// One axis of a cubic bezier with endpoints `0` and `1` and control values `p1`, `p2`, all in
    /// unit-scale fixed point, evaluated at parameter `t ∈ [0, u]`:
    ///   `B(t) = 3(1−t)²t·p1 + 3(1−t)t²·p2 + t³`   (the `(1−t)³·0` term vanishes; `t³·1` is `t³`).
    /// Every multiply/divide is full-width; `t` is treated as a unit fraction.
    static func bezierAxis(t: Int64, p1: Int64, p2: Int64, u: Int64) throws -> Int64 {
        let oneMinusT = u - t
        // (1−t)² , (1−t)t , t²  — all in unit scale.
        let omt2 = try FixedPointMath.multiplyDivideRounding(oneMinusT, oneMinusT, u, "bezier.omt2")
        let omtT = try FixedPointMath.multiplyDivideRounding(oneMinusT, t, u, "bezier.omtT")
        let t2 = try FixedPointMath.multiplyDivideRounding(t, t, u, "bezier.t2")
        let t3 = try FixedPointMath.multiplyDivideRounding(t2, t, u, "bezier.t3")
        // term1 = 3·omt2·t·p1 ; term2 = 3·omtT·t·p2 — fold the `t` factor in via the unit products.
        // 3(1−t)²t·p1 = 3 · (omt2·t/u) · p1/u   →   compute (omt2·t/u), then ·p1/u, then ·3.
        let omt2T = try FixedPointMath.multiplyDivideRounding(omt2, t, u, "bezier.omt2T")
        let term1Unit = try FixedPointMath.multiplyDivideRounding(omt2T, p1, u, "bezier.term1")
        let term1 = try CheckedInt64.multiply(3, term1Unit, "bezier.3term1")
        // 3(1−t)t²·p2 : (omtT·t/u) == (1−t)t² , then ·p2/u, then ·3.
        let omtT2 = try FixedPointMath.multiplyDivideRounding(omtT, t, u, "bezier.omtT2")
        let term2Unit = try FixedPointMath.multiplyDivideRounding(omtT2, p2, u, "bezier.term2")
        let term2 = try CheckedInt64.multiply(3, term2Unit, "bezier.3term2")
        let sum = try CheckedInt64.add(try CheckedInt64.add(term1, term2, "bezier.s1"), t3, "bezier.s2")
        return sum
    }
}
