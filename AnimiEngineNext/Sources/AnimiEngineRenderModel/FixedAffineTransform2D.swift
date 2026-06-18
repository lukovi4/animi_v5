import AnimiEngineCore

/// Task-003 plan D3-05, §6 — a checked fixed-point 2×3 affine transform value (§17 step 8).
///
/// This type is **coordinate-space-neutral**: it is pure fixed-point affine arithmetic and carries no
/// inherent input or output space. Its **input space and output space are defined independently by the
/// containing contract** and are not necessarily the same coordinate space — for example,
/// ``ResolvedMediaPlacement/transform`` defines it as *source-pixel space → binding-baseline local
/// space* (distinct input and output spaces), and step 9 composes it further. Nothing here maps to
/// canvas space by itself.
///
/// It exists because the Task-002 `Placement` (a single isotropic `ScaleScalar` + a frame rect + a
/// rotation) cannot represent the composition the media-fit resolver must produce: `fill` yields an
/// **anisotropic** X/Y scale, and "scaled media is centered in the binding baseline **before** user
/// transform" (D3-05) is a genuine matrix composition (fit-scale → center → user transform). A
/// six-coefficient affine matrix is the smallest representation that holds all of these exactly.
///
/// ## Coordinate convention
///
/// The matrix maps an input point `(x, y)` (in the input space the containing contract assigns) to an
/// output point `(x', y')` (in the contract's output space) — the two spaces are defined independently
/// and need not be the same, and neither is canvas space by default:
/// ```
/// x' = (a · x + c · y) / linearUnitsPerOne + tx
/// y' = (b · x + d · y) / linearUnitsPerOne + ty
/// ```
/// ## Units (deliberately two scales, item: no silent unit mixing)
///
///   * `a, b, c, d` — the linear part — are **dimensionless scale factors** in fixed point with
///     `linearUnitsPerOne` (= 1,000,000) raw units per `1.0`, matching `ScaleScalar`.
///   * `tx, ty` — the translation — use `CanvasScalar` fixed-point units (65,536 per point); their
///     **coordinate space is whatever the containing contract defines**, not canvas space by default.
///
/// ## Exactness (step-8 corrective, issue #7)
///
/// Every multiply that scales a coordinate uses a **full-width** `Int64 × Int64 / divisor` via
/// ``FixedPointMath`` (`AnimiEngineCore`), so the intermediate product never overflows a 64-bit window;
/// only the final narrowed result can overflow, and that is a typed failure, never a trap. There is no
/// `precondition`/`fatalError` on any public path and no `Float`/`Double`. Arbitrary rotation is exact
/// fixed-point CORDIC (``FixedTrig``), not a 90°-only special case.
public struct FixedAffineTransform2D: Hashable, Sendable {
    /// Raw units per `1.0` for the dimensionless linear coefficients (`a, b, c, d`).
    public static let linearUnitsPerOne: Int64 = 1_000_000

    /// Linear coefficient (column-major affine `[a c tx; b d ty]`), `linearUnitsPerOne` units per 1.0.
    public let a: Int64
    public let b: Int64
    public let c: Int64
    public let d: Int64
    /// Translation in `CanvasScalar` raw units.
    public let tx: Int64
    public let ty: Int64

    /// The identity transform: linear part is `1`, translation is `0`.
    public static let identity = FixedAffineTransform2D(
        a: linearUnitsPerOne, b: 0, c: 0, d: linearUnitsPerOne, tx: 0, ty: 0)

    public init(a: Int64, b: Int64, c: Int64, d: Int64, tx: Int64, ty: Int64) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    // MARK: - Deterministic exact fixed-point primitive (issue #7)

    /// `(value · factor) / linearUnitsPerOne`, rounded to nearest with ties away from zero, computed
    /// with a full-width 128-bit intermediate so `value · factor` never overflows. Used wherever a
    /// `linearUnitsPerOne`-scaled factor is applied to a `CanvasScalar`-scaled (or linear) quantity.
    public static func applyLinear(_ value: Int64, _ factor: Int64, _ operation: String) throws -> Int64 {
        try FixedPointMath.multiplyDivideRounding(value, factor, linearUnitsPerOne, operation)
    }

    /// Checked integer division rounded to nearest, ties away from zero, with the half-bias formed in
    /// full width so it cannot overflow. A non-positive divisor is a **typed failure** (issue #7: no
    /// `precondition`/trap on any public path).
    public static func divideRoundHalfAway(_ numerator: Int64, _ divisor: Int64, _ operation: String) throws -> Int64 {
        // round(numerator / divisor) == round(numerator · 1 / divisor); reuse the full-width primitive.
        try FixedPointMath.multiplyDivideRounding(numerator, 1, divisor, operation)
    }

    // MARK: - Constructors

    /// A pure translation by `(tx, ty)` in `CanvasScalar` fixed-point units (output-space defined by the
    /// containing contract).
    public static func translation(tx: Int64, ty: Int64) -> FixedAffineTransform2D {
        FixedAffineTransform2D(a: linearUnitsPerOne, b: 0, c: 0, d: linearUnitsPerOne, tx: tx, ty: ty)
    }

    /// An anisotropic scale about the source origin. `scaleX`/`scaleY` are `linearUnitsPerOne`-scaled
    /// (e.g. `2_000_000` == ×2). This is the only constructor that admits independent X/Y scale and is
    /// what `fill` and the fit baseline use.
    public static func scale(scaleX: Int64, scaleY: Int64) -> FixedAffineTransform2D {
        FixedAffineTransform2D(a: scaleX, b: 0, c: 0, d: scaleY, tx: 0, ty: 0)
    }

    /// A rotation by an **arbitrary** angle, computed with deterministic fixed-point CORDIC
    /// (``FixedTrig``) — no `Float`/`Double`, no 90°-only restriction (issue #6). The linear part is the
    /// rotation matrix `[cos -sin; sin cos]` in `linearUnitsPerOne` units; translation is zero.
    ///
    /// `degreesTimesUnitsPerDegree` is the rotation in `RotationScalar` raw units (1,000 per degree).
    public static func rotation(degreesTimesUnitsPerDegree raw: Int64) throws -> FixedAffineTransform2D {
        let (cos, sin) = try FixedTrig.cosSin(rotationRaw: raw, linearUnitsPerOne: linearUnitsPerOne)
        // Standard rotation: x' = x·cos - y·sin ; y' = x·sin + y·cos  → a=cos, b=sin, c=-sin, d=cos.
        return FixedAffineTransform2D(a: cos, b: sin, c: -sin, d: cos, tx: 0, ty: 0)
    }

    // MARK: - Composition

    /// Returns `self ∘ inner`: the transform that applies `inner` first, then `self`. Concretely, for a
    /// point `p`, `(self.concatenating(inner)).apply(p) == self.apply(inner.apply(p))`.
    ///
    /// Linear part is `Lself · Linner` (a matrix multiply, each product divided back by
    /// `linearUnitsPerOne`). The translation is `Lself · innerTranslation + selfTranslation`, where the
    /// linear part (dimensionless) is applied to the inner translation (`CanvasScalar` fixed-point units)
    /// via `applyLinear`. Every multiply/add is checked and full-width.
    public func concatenating(_ inner: FixedAffineTransform2D) throws -> FixedAffineTransform2D {
        // New linear part = self.linear · inner.linear (dimensionless × dimensionless).
        let na = try Self.applyLinear(a, inner.a, "affine.a") .addingChecked(
                 try Self.applyLinear(c, inner.b, "affine.a2"), "affine.a.sum")
        let nb = try Self.applyLinear(b, inner.a, "affine.b") .addingChecked(
                 try Self.applyLinear(d, inner.b, "affine.b2"), "affine.b.sum")
        let nc = try Self.applyLinear(a, inner.c, "affine.c") .addingChecked(
                 try Self.applyLinear(c, inner.d, "affine.c2"), "affine.c.sum")
        let nd = try Self.applyLinear(b, inner.c, "affine.d") .addingChecked(
                 try Self.applyLinear(d, inner.d, "affine.d2"), "affine.d.sum")
        // New translation = self.linear · inner.translation + self.translation (dimensionless × CanvasScalar units).
        let ntx = try Self.applyLinear(a, inner.tx, "affine.tx") .addingChecked(
                  try Self.applyLinear(c, inner.ty, "affine.tx2"), "affine.tx.sum")
                  .addingChecked(tx, "affine.tx.final")
        let nty = try Self.applyLinear(b, inner.tx, "affine.ty") .addingChecked(
                  try Self.applyLinear(d, inner.ty, "affine.ty2"), "affine.ty.sum")
                  .addingChecked(ty, "affine.ty.final")
        return FixedAffineTransform2D(a: na, b: nb, c: nc, d: nd, tx: ntx, ty: nty)
    }

    /// Applies the transform to an input point in `CanvasScalar` fixed-point units, returning the
    /// **output-space** point `(x', y')` (in the same units) — the output space is whatever the
    /// containing contract defines, not necessarily canvas space.
    public func apply(x: Int64, y: Int64) throws -> (x: Int64, y: Int64) {
        let nx = try Self.applyLinear(a, x, "affine.apply.ax") .addingChecked(
                 try Self.applyLinear(c, y, "affine.apply.cy"), "affine.apply.x.sum")
                 .addingChecked(tx, "affine.apply.x.final")
        let ny = try Self.applyLinear(b, x, "affine.apply.bx") .addingChecked(
                 try Self.applyLinear(d, y, "affine.apply.dy"), "affine.apply.y.sum")
                 .addingChecked(ty, "affine.apply.y.final")
        return (nx, ny)
    }

    // MARK: - Canonical encoding / hashing (D3-11)

    public func canonicalValue() throws -> RenderCanonicalEncoding.Value {
        try RenderCanonicalEncoding.object([
            ("a", .int(a)), ("b", .int(b)), ("c", .int(c)), ("d", .int(d)),
            ("tx", .int(tx)), ("ty", .int(ty))
        ])
    }
}

private extension Int64 {
    /// Small infix helper so the composition reads as a sum of checked terms.
    func addingChecked(_ other: Int64, _ operation: String) throws -> Int64 {
        try CheckedInt64.add(self, other, operation)
    }
}
