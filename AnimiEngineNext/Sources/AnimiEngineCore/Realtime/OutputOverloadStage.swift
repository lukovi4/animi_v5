/// Slice-004 Stage D — the canonical output-overload stage (D-213, ADR-012 §4).
///
/// D-213 is **ACCEPTED OFFLINE-PROVEN**: the selected canonical stage is **Candidate A — explicit
/// deterministic hard saturation** `clamp(x, -1, +1)` (see
/// `Docs/AnimiEngineNext/d-213-audio-output-stage-benchmark.md` and the committed evidence
/// `Docs/AnimiEngineNext/evidence/d-213/output-stage-evidence.json`). Candidate B (the stateless safety
/// limiter) is a documented fallback only and is **not** implemented in production here.
///
/// This is the **first allowed DSP/output boundary** in `Realtime/`, so 32-bit single-precision floats
/// (`Float32`) are permitted in *this file only* (the Realtime no-float sweep allows that one type
/// solely here; wider/decimal floating-point types and any audio-framework import remain forbidden
/// everywhere). The stage is pure, **stateless**, and
/// memoryless: no attack/release/lookahead, no carried state, no tuning knobs, no allocation. It is
/// therefore trivially identical in preview and export (ADR-012 §4 "identical in preview and export").

/// Typed failure for the output stage (Slice-004 Stage D). The internal mix bus may legitimately carry
/// peaks outside `[-1, +1]` (ADR-012 §4), but a **non-finite** sample (`NaN`/`+Inf`/`-Inf`) is never a
/// valid mix value — it signals upstream corruption. No documented policy maps it to a finite value, so
/// the stage fails **closed** rather than silently substituting (e.g. mapping `NaN → 0`).
public enum OutputOverloadStageError: Error, Equatable, Sendable {
    /// A sample handed to the output stage was `NaN`, `+Inf`, or `-Inf`.
    case nonFiniteSample
}

/// The canonical output-overload stage: Candidate A explicit deterministic hard saturation.
///
/// Pure, stateless, `Sendable`. The whole type is a namespace of static functions plus a stable
/// algorithm identity — there is no instance state to construct.
public enum OutputOverloadStage: Sendable {

    /// Stable algorithm identity/version. Any change to the curve or its semantics bumps this string;
    /// it is recorded in diagnostics/evidence so preview and export can prove they ran the same stage.
    public static let algorithmIdentity: String = "d213.hardSaturation.v1"

    /// Apply Candidate A hard saturation to one sample, fail-closed on non-finite input.
    ///
    /// - `NaN`/`±Inf` → throws `OutputOverloadStageError.nonFiniteSample` (never silently passed or
    ///   mapped to a finite value).
    /// - `x > 1` → `+1`; `x < -1` → `-1`.
    /// - otherwise → `x` returned **exactly** (bit-transparent for every finite sample in `[-1, +1]`,
    ///   including `+0.0`, `-0.0`, and `±1`: those fall through both branches and are returned verbatim,
    ///   so even the `-0.0` bit pattern is preserved).
    public static func process(_ x: Float32) throws -> Float32 {
        guard x.isFinite else { throw OutputOverloadStageError.nonFiniteSample }
        if x > 1 { return 1 }
        if x < -1 { return -1 }
        return x
    }
}
