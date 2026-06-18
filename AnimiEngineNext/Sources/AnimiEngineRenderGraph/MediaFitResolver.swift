import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan D3-05, §6, §13 row "Fit and crop" — the pure fixed-point media fit/placement
/// resolver (§17 step 8, step-8 corrective issue #2). It turns a media layer's **binding-baseline
/// content rect**, source presentation dimensions, the authored ``MediaPlacement`` (fit mode + user
/// transform) and the container-clip policy into the final immutable affine transform + clip the Metal
/// executor consumes — with **no** `Float`/`Double`, no IO, and deterministic full-width rounding.
///
/// ## Coordinate ownership (issue #2, TVECore oracle)
///
///   * **fit baseline** = `bindingBaseline.contentRect` — the local placeholder rect (always
///     `(0,0,w,h)`); cover/contain/fill scale the source against *this*, not the aperture.
///   * **slotRect clip** = the block's canvas rect (`blockRectCanvas`); the oracle clips to
///     `block.rectCanvas`, never to the aperture.
///   * **aperture** = `placementRect` is a separate entity (input geometry / hit-test / mask); it is
///     **not** the fit baseline and **not** the clip, and is intentionally not consumed by fit here.
///
/// All geometry handled here is **local/baseline** space (not canvas space) except `blockRectCanvas`,
/// which is explicitly the canvas-space clip target — the two are not conflated.
///
/// ## Fit oracle (D3-05)
///
///   * `cover`   — uniform **maximum** scale (overflow bounded by the clip, never a baked source crop);
///   * `contain` — uniform **minimum** scale;
///   * `fill`    — **independent** X/Y scale.
///
/// Scaled media is centered in the fit baseline **before** the user transform (D3-05): the user
/// transform (scale about the baseline centre → arbitrary rotation → translation) is composed on top as
/// a genuine matrix composition. Rotation is exact fixed-point CORDIC — any angle, no `Float`.
///
/// ## Transform contract (issue #7)
///
/// The returned `transform` maps **source-pixel space → binding-baseline local space** only. It does
/// **not** include the block→canvas placement or the sampled binding-world transform; §17 step 9
/// composes those downstream. The `clip` is already a destination (canvas) space rect.
public enum MediaFitResolver {

    /// Resolves one media layer into its final transform + clip.
    ///
    /// - Parameters:
    ///   - contentRect: the binding-baseline content rect (the fit baseline).
    ///   - blockRectCanvas: the block's canvas rect (the `slotRect` clip target).
    ///   - sourceWidthPixels/sourceHeightPixels: presentation-oriented source dimensions, in pixels.
    ///   - mediaPlacement: the authored fit mode + user transform.
    ///   - containerClip: the producer container-clip tag (`slotRect`, `slotRectAfterSettle`, `none`).
    public static func resolve(
        contentRect: FixedRect,
        blockRectCanvas: FixedRect,
        sourceWidthPixels: Int,
        sourceHeightPixels: Int,
        mediaPlacement: MediaPlacement,
        containerClip: String
    ) throws -> ResolvedMediaPlacement {
        guard sourceWidthPixels > 0, sourceHeightPixels > 0 else {
            throw RenderGraphError.invalidSourceDimensions(
                width: sourceWidthPixels, height: sourceHeightPixels)
        }
        // contentRect is a FixedRect, whose initializer already guarantees positive width/height.

        // Source dimensions in CanvasScalar fixed-point units, in baseline-local space (1 pixel → 1 point).
        let unitsPerPoint = CanvasScalar.unitsPerPoint
        let srcWidthRaw = try CheckedInt64.multiply(Int64(sourceWidthPixels), unitsPerPoint, "fit.srcWidth")
        let srcHeightRaw = try CheckedInt64.multiply(Int64(sourceHeightPixels), unitsPerPoint, "fit.srcHeight")

        // Per-axis baseline/source scale, in linearUnitsPerOne fixed point, full-width round-half-away.
        let linear = FixedAffineTransform2D.linearUnitsPerOne
        let sx = try FixedPointMath.multiplyDivideRounding(contentRect.width.rawValue, linear, srcWidthRaw, "fit.sx")
        let sy = try FixedPointMath.multiplyDivideRounding(contentRect.height.rawValue, linear, srcHeightRaw, "fit.sy")

        let scaleX: Int64
        let scaleY: Int64
        switch mediaPlacement.fitMode {
        case .cover:
            let s = max(sx, sy); scaleX = s; scaleY = s
        case .contain:
            let s = min(sx, sy); scaleX = s; scaleY = s
        case .fill:
            scaleX = sx; scaleY = sy
        }
        guard scaleX > 0, scaleY > 0 else {
            throw RenderGraphError.degenerateFitScale(scaleX: scaleX, scaleY: scaleY)
        }

        // Fitted source size in baseline raw units.
        let fittedWidth = try FixedAffineTransform2D.applyLinear(srcWidthRaw, scaleX, "fit.fittedWidth")
        let fittedHeight = try FixedAffineTransform2D.applyLinear(srcHeightRaw, scaleY, "fit.fittedHeight")

        // Centre the fitted source within the baseline content rect.
        let centerOffsetX = try FixedAffineTransform2D.divideRoundHalfAway(
            try CheckedInt64.subtract(contentRect.width.rawValue, fittedWidth, "fit.centerX.diff"), 2, "fit.centerX")
        let centerOffsetY = try FixedAffineTransform2D.divideRoundHalfAway(
            try CheckedInt64.subtract(contentRect.height.rawValue, fittedHeight, "fit.centerY.diff"), 2, "fit.centerY")
        let originX = try CheckedInt64.add(contentRect.x.rawValue, centerOffsetX, "fit.originX")
        let originY = try CheckedInt64.add(contentRect.y.rawValue, centerOffsetY, "fit.originY")

        // fitTransform = translate(origin) ∘ scale(scaleX, scaleY): source → baseline space.
        let fitTransform = try FixedAffineTransform2D
            .translation(tx: originX, ty: originY)
            .concatenating(FixedAffineTransform2D.scale(scaleX: scaleX, scaleY: scaleY))

        // User transform composed on top, about the baseline content-rect centre (D3-05):
        //   translate(userOffset) ∘ translate(centre) ∘ scale(userScale) ∘ rotate(userRotation) ∘ translate(-centre)
        let centreX = try CheckedInt64.add(
            contentRect.x.rawValue,
            try FixedAffineTransform2D.divideRoundHalfAway(contentRect.width.rawValue, 2, "fit.centreX"),
            "fit.centreX.abs")
        let centreY = try CheckedInt64.add(
            contentRect.y.rawValue,
            try FixedAffineTransform2D.divideRoundHalfAway(contentRect.height.rawValue, 2, "fit.centreY"),
            "fit.centreY.abs")

        let userScaleRaw = mediaPlacement.userScale.rawValue
        let rotate = try FixedAffineTransform2D.rotation(
            degreesTimesUnitsPerDegree: mediaPlacement.userRotation.rawValue)
        let scaleAboutCentre = try FixedAffineTransform2D
            .translation(tx: centreX, ty: centreY)
            .concatenating(FixedAffineTransform2D.scale(scaleX: userScaleRaw, scaleY: userScaleRaw))
            .concatenating(rotate)
            .concatenating(FixedAffineTransform2D.translation(
                tx: try CheckedInt64.subtract(0, centreX, "fit.negCentreX"),
                ty: try CheckedInt64.subtract(0, centreY, "fit.negCentreY")))
        let userTransform = try FixedAffineTransform2D
            .translation(tx: mediaPlacement.userOffsetX.rawValue, ty: mediaPlacement.userOffsetY.rawValue)
            .concatenating(scaleAboutCentre)

        let finalTransform = try userTransform.concatenating(fitTransform)

        let clip = try resolveClip(containerClip: containerClip, blockRectCanvas: blockRectCanvas)
        return ResolvedMediaPlacement(fitMode: mediaPlacement.fitMode, transform: finalTransform, clip: clip)
    }

    /// Resolves the container-clip policy into a ready destination-space clip instruction (issue #2).
    ///
    ///   * `slotRect` → the block's canvas rect (the proven oracle clips to `block.rectCanvas`);
    ///   * `slotRectAfterSettle` → a **typed failure**: a static frame has no represented settled
    ///     state yet, so emitting a clip for it would be a guess (no silent fallback);
    ///   * `none` → no clip.
    /// An unknown tag is a typed failure.
    static func resolveClip(containerClip: String, blockRectCanvas: FixedRect) throws -> ResolvedClip {
        switch containerClip {
        case "none":
            return .none
        case "slotRect":
            return .rect(blockRectCanvas)
        case "slotRectAfterSettle":
            throw RenderGraphError.unsupportedSettledClip
        default:
            throw RenderGraphError.unsupportedContainerClip(tag: containerClip)
        }
    }
}
