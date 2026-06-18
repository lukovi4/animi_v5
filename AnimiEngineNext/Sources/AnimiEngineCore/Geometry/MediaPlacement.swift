/// Task-003 step-8 corrective (issue #1) — the canonical **authored** media placement of a scene
/// layer, distinct from the outer layer ``Placement``.
///
/// `Placement` positions a layer's rectangle on the canvas. `MediaPlacement` describes how the **user
/// media** sits inside that layer's binding baseline: the chosen fit mode plus the user's own
/// transform (offset, scale, rotation) applied on top of the fit. Keeping them separate is the model
/// correction the render-side fit resolver depends on — the fit baseline (`bindingBaseline.contentRect`)
/// and the user delta live here, not conflated into `Placement`.
///
/// This is an **input** value carried by `SceneLayer`/`ActiveLayer` through the strict codec, canonical
/// hash and evaluator. The render layer's `ResolvedMediaPlacement` (the computed affine + clip) is a
/// separate, derived result and is **not** this type.

/// The media fit mode (the producer's `FitMode`). There is no default — a scene layer must carry an
/// explicit choice, validated by the adapter against the template's `fitModesAllowed`.
public enum MediaFitMode: String, Hashable, Sendable, CaseIterable {
    case cover
    case contain
    case fill
}

/// The authored media placement: fit mode + the user's transform inside the binding baseline.
///
/// `userOffset` is a **binding-baseline-local** translation delta expressed in `CanvasScalar`
/// fixed-point units, `userScale` is the isotropic user scale (`ScaleScalar`, > 0), and `userRotation`
/// is an **arbitrary** rotation (`RotationScalar`, 1,000 raw units per degree) — there is no 90°-only
/// restriction; the render layer realises it with deterministic fixed-point CORDIC.
public struct MediaPlacement: Hashable, Sendable {
    public let fitMode: MediaFitMode
    public let userOffsetX: CanvasScalar
    public let userOffsetY: CanvasScalar
    public let userScale: ScaleScalar
    public let userRotation: RotationScalar

    /// Private unchecked storage init. Used only by paths that supply statically-valid values (the
    /// `identity` factory), so there is no `try!`/force anywhere in this type.
    private init(
        uncheckedFitMode fitMode: MediaFitMode,
        userOffsetX: CanvasScalar, userOffsetY: CanvasScalar,
        userScale: ScaleScalar, userRotation: RotationScalar
    ) {
        self.fitMode = fitMode
        self.userOffsetX = userOffsetX
        self.userOffsetY = userOffsetY
        self.userScale = userScale
        self.userRotation = userRotation
    }

    public init(
        fitMode: MediaFitMode,
        userOffsetX: CanvasScalar,
        userOffsetY: CanvasScalar,
        userScale: ScaleScalar,
        userRotation: RotationScalar
    ) throws {
        guard userScale.rawValue > 0 else {
            throw TimeError.negativeValue(domain: "MediaPlacement.userScale", value: userScale.rawValue)
        }
        self.init(
            uncheckedFitMode: fitMode, userOffsetX: userOffsetX, userOffsetY: userOffsetY,
            userScale: userScale, userRotation: userRotation)
    }

    /// The identity user transform with an explicit fit mode (no user offset/scale/rotation). Used by
    /// the adapter when the compiled template carries a fit selection but no authored user transform.
    /// Built through the private unchecked path with the statically-valid `.one` scale — no `try!`.
    public static func identity(fitMode: MediaFitMode) -> MediaPlacement {
        MediaPlacement(
            uncheckedFitMode: fitMode,
            userOffsetX: CanvasScalar(rawValue: 0), userOffsetY: CanvasScalar(rawValue: 0),
            userScale: .one, userRotation: .zero)
    }
}
