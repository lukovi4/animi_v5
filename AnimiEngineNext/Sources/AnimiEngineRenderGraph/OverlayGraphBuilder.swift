import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §7 (overlays above the body), §7.1 (compositionOrder), D3-09 / §3.1 (pre-resolved
/// pixels) — overlay compilation (§17 step 9 corrective #2/#7/#9).
///
/// Overlays are compiled after the body, in dense unique `compositionOrder` (corrective #9), into the
/// explicit linear-canvas surface (corrective #2). Each overlay's transform includes the frame origin
/// **and** a deterministic source-pixel→frame sizing (corrective #7): the pixel buffer is scaled so its
/// pixel extent maps onto the overlay frame, then placed at the frame, with the user scale/rotation
/// about the frame centre. A missing pixel or an active animation request is a typed failure.
public enum OverlayGraphBuilder {

    static func build(overlays: [ActiveOverlay], input: ResolvedFrameInput, into ctx: inout CompileContext) throws {
        // Dense unique compositionOrder (corrective #9).
        try RenderGraphCompiler.requireDenseUniqueOrders(
            overlays.map { $0.compositionOrder }, field: "overlays.compositionOrder")

        let ordered = overlays.sorted { $0.compositionOrder < $1.compositionOrder }
        for overlay in ordered {
            let key = ResolvedLayerKey.overlay(overlayID: overlay.overlayID)
            guard let pixels = input.pixelInput(for: key), let pixelID = input.pixelInputID(for: key) else {
                throw RenderGraphError.missingFixturePixels(reference: "overlay\u{1F}\(overlay.overlayID.raw)")
            }
            switch overlay.animationRequest {
            case nil, .some(.inactive):
                break
            default:
                throw RenderGraphError.unsupportedOverlayAnimation(
                    overlayID: overlay.overlayID.raw, detail: "active overlay animation is not supported in static composition")
            }
            let transform = try placementTransform(overlay.placement, pixels: pixels)
            ctx.emit(.overlay(resourceID: pixelID.rawValue, transform: transform, opacity: .opaque,
                              compositionOrder: overlay.compositionOrder, targetSurfaceID: RenderSurface.linearCanvas))
        }
    }

    /// Composes the overlay transform: source-pixel space → frame (deterministic sizing) → placed at the
    /// frame origin with the user scale/rotation about the frame centre.
    ///
    /// Source-pixel→frame sizing (corrective #7): a `w×h`-pixel buffer is scaled by `frame.width / w`
    /// (x) and `frame.height / h` (y) so the pixels exactly fill the overlay frame, then translated to
    /// the frame origin. The placement scale/rotation are then applied about the frame centre.
    static func placementTransform(_ placement: Placement, pixels: ResolvedPixelInput) throws -> FixedAffineTransform2D {
        let frame = placement.frame
        let pxW = Int64(pixels.dimensions.width)
        let pxH = Int64(pixels.dimensions.height)
        guard pxW > 0, pxH > 0 else {
            throw RenderGraphError.invalidSourceDimensions(width: pixels.dimensions.width, height: pixels.dimensions.height)
        }
        // Pixel extent in canvas raw units (1 pixel → 1 point), then scale to the frame size.
        let one = FixedAffineTransform2D.linearUnitsPerOne
        let srcWRaw = try CheckedInt64.multiply(pxW, CanvasScalar.unitsPerPoint, "overlay.srcW")
        let srcHRaw = try CheckedInt64.multiply(pxH, CanvasScalar.unitsPerPoint, "overlay.srcH")
        let scaleX = try FixedPointMath.multiplyDivideRounding(frame.width.rawValue, one, srcWRaw, "overlay.scaleX")
        let scaleY = try FixedPointMath.multiplyDivideRounding(frame.height.rawValue, one, srcHRaw, "overlay.scaleY")
        let sizing = FixedAffineTransform2D.scale(scaleX: scaleX, scaleY: scaleY)

        // Place at the frame origin, then apply the user scale/rotation about the frame centre.
        let centreX = try CheckedInt64.add(frame.x.rawValue,
            try FixedAffineTransform2D.divideRoundHalfAway(frame.width.rawValue, 2, "overlay.centreX"), "overlay.cx")
        let centreY = try CheckedInt64.add(frame.y.rawValue,
            try FixedAffineTransform2D.divideRoundHalfAway(frame.height.rawValue, 2, "overlay.centreY"), "overlay.cy")
        let rotate = try FixedAffineTransform2D.rotation(degreesTimesUnitsPerDegree: placement.rotation.rawValue)
        let userScale = FixedAffineTransform2D.scale(scaleX: placement.scale.rawValue, scaleY: placement.scale.rawValue)

        // userTransform = T(centre)·userScale·rotate·T(-centre) · T(frameOrigin) · sizing
        let aboutCentre = try FixedAffineTransform2D
            .translation(tx: centreX, ty: centreY)
            .concatenating(userScale)
            .concatenating(rotate)
            .concatenating(FixedAffineTransform2D.translation(
                tx: try CheckedInt64.subtract(0, centreX, "overlay.negCx"),
                ty: try CheckedInt64.subtract(0, centreY, "overlay.negCy")))
        return try aboutCentre
            .concatenating(FixedAffineTransform2D.translation(tx: frame.x.rawValue, ty: frame.y.rawValue))
            .concatenating(sizing)
    }
}
