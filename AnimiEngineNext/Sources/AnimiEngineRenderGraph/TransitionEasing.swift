import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §3.7 D3-07, §7.3 — the transition easing functions, in pure fixed point (§17 step 9).
///
/// The supported easings are exactly (D3-07):
///   * `linear`    — `eased(t) = t`;
///   * `easeInOut` — `eased(t) = 3t² − 2t³` (the smoothstep curve);
///   * `none`      — valid **only** for a cut and never evaluated as an animated transition.
///
/// Unknown easing is a typed error (D3-07: "unknown easing is a typed error"). All arithmetic is
/// checked fixed point (`UnitInterval`, 1,000,000 units per 1.0) with a full-width 128-bit
/// intermediate; there is no `Float`/`Double`.
public enum TransitionEasing {

    /// The pinned easing identifiers (the producer/evaluator strings — D3-07).
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case linear
        case easeInOut
        case none
    }

    /// Parses an `EasingReference` raw string into a supported ``Kind``; an unknown string is a typed
    /// failure (no default).
    public static func kind(from raw: String) throws -> Kind {
        guard let kind = Kind(rawValue: raw) else {
            throw RenderGraphError.unsupportedEasing(raw: raw)
        }
        return kind
    }

    /// Exact transition progress `t = numerator / denominator` as a `UnitInterval` (0 ≤ t ≤ 1). The
    /// The evaluator emits a **half-open** `[0, 1)` progress, so an animated transition must satisfy
    /// `0 <= numerator < denominator` (corrective #8: `numerator == denominator`, i.e. progress 1, is
    /// the cut boundary and is never an animated transition). A non-positive denominator or an
    /// out-of-range ratio is a typed failure.
    public static func progress(numerator: Int64, denominator: Int64) throws -> UnitInterval {
        guard denominator > 0 else {
            throw RenderGraphError.invalidTransitionProgress(numerator: numerator, denominator: denominator)
        }
        guard numerator >= 0, numerator < denominator else {
            throw RenderGraphError.invalidTransitionProgress(numerator: numerator, denominator: denominator)
        }
        let raw = try FixedPointMath.multiplyDivideRounding(
            numerator, UnitInterval.unitsPerUnit, denominator, "transition.progress")
        return try UnitInterval(rawValue: raw)
    }

    /// Applies the easing curve to a progress value, returning the eased `UnitInterval`.
    ///
    /// `none` must never reach here as an animated transition (it is cut-only, D3-07); doing so is a
    /// typed failure rather than a silent passthrough.
    public static func eased(_ kind: Kind, progress t: UnitInterval) throws -> UnitInterval {
        switch kind {
        case .linear:
            return t
        case .easeInOut:
            return try smoothstep(t)
        case .none:
            throw RenderGraphError.unsupportedEasing(raw: "none (cut-only easing evaluated as animated)")
        }
    }

    /// `3t² − 2t³` in fixed point, exact and clamped to `[0, 1]`. With `u = unitsPerUnit`:
    ///   t² scaled = round(t·t / u); t³ scaled = round(t²·t / u); result = 3·t² − 2·t³.
    /// For `t ∈ [0, 1]` the result lies in `[0, 1]`, so `UnitInterval` construction never rejects.
    private static func smoothstep(_ t: UnitInterval) throws -> UnitInterval {
        let u = UnitInterval.unitsPerUnit
        let t1 = t.rawValue
        let t2 = try FixedPointMath.multiplyDivideRounding(t1, t1, u, "easeInOut.t2")
        let t3 = try FixedPointMath.multiplyDivideRounding(t2, t1, u, "easeInOut.t3")
        // result = 3·t2 − 2·t3 (both already in unit scale).
        let threeT2 = try CheckedInt64.multiply(3, t2, "easeInOut.3t2")
        let twoT3 = try CheckedInt64.multiply(2, t3, "easeInOut.2t3")
        let result = try CheckedInt64.subtract(threeT2, twoT3, "easeInOut.result")
        // Clamp defensively against a 1-ULP rounding excursion past the bound.
        let clamped = min(max(result, 0), u)
        return try UnitInterval(rawValue: clamped)
    }
}
