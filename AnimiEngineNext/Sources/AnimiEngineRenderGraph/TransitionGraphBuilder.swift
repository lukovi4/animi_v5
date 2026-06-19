import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §7.3, §13 — transition compositing (§17 step 9 corrective #2/#6/#11).
///
/// The compiler renders both complete scenes into their own surfaces (`outgoingSurface`,
/// `incomingSurface`) — the outgoing scene continues rendering and animating through the window (§7.3).
/// `emitTransition` then composites those **populated** surfaces into the explicit `targetSurface`:
///   * **fade** — composites the incoming over the outgoing surface at the eased progress;
///   * **slide** — translates the incoming surface from the typed direction by the eased progress.
/// Progress is consumed exactly from the `TransitionPlan`; project time/progress are never modified.
public enum TransitionGraphBuilder {

    static func emitTransition(
        transition: TransitionPlan, outgoingSurface: String, incomingSurface: String,
        targetSurface: String, canvasWidth: Int64, canvasHeight: Int64, into ctx: inout CompileContext
    ) throws {
        let effect = transition.effectID.raw
        guard effect == SupportedTransitionEffect.fade || effect == SupportedTransitionEffect.slide
                || effect == SupportedTransitionEffect.push
                || effect == SupportedTransitionEffect.dipToBlack || effect == SupportedTransitionEffect.dipToWhite else {
            throw RenderGraphError.unsupportedTransitionEffect(effectID: effect)
        }
        let kind = try TransitionEasing.kind(from: transition.easing.raw)
        let rawProgress = try TransitionEasing.progress(
            numerator: transition.progressNumerator, denominator: transition.progressDenominator)
        let eased = try TransitionEasing.eased(kind, progress: rawProgress)

        switch effect {
        case SupportedTransitionEffect.fade:
            ctx.emit(.fadeTransition(easedProgress: eased, outgoingSurfaceID: outgoingSurface,
                                     incomingSurfaceID: incomingSurface, targetSurfaceID: targetSurface))
        case SupportedTransitionEffect.slide:
            let direction = try slideDirection(from: transition.parameters)
            let (offsetX, offsetY) = try slideOffset(direction: direction, eased: eased, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            ctx.emit(.slideTransition(direction: direction, easedProgress: eased, offsetX: offsetX, offsetY: offsetY,
                                      outgoingSurfaceID: outgoingSurface, incomingSurfaceID: incomingSurface, targetSurfaceID: targetSurface))
        case SupportedTransitionEffect.push:
            let direction = try slideDirection(from: transition.parameters)
            let (outOff, inOff) = try pushOffsets(direction: direction, eased: eased, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            ctx.emit(.pushTransition(direction: direction, easedProgress: eased,
                                     outgoingOffsetX: outOff.0, outgoingOffsetY: outOff.1,
                                     incomingOffsetX: inOff.0, incomingOffsetY: inOff.1,
                                     outgoingSurfaceID: outgoingSurface, incomingSurfaceID: incomingSurface, targetSurfaceID: targetSurface))
        case SupportedTransitionEffect.dipToBlack, SupportedTransitionEffect.dipToWhite:
            // Reject any supplied parameter (dip takes none) — keep the graph builder fail-closed too.
            if let extra = transition.parameters.sortedUniqueParameters.first {
                throw RenderGraphError.unsupportedTransitionEffect(effectID: "\(effect)(unexpected-param:\(extra.key))")
            }
            let dipColor = try (effect == SupportedTransitionEffect.dipToWhite) ? opaqueWhite() : opaqueBlack()
            ctx.emit(.dipTransition(dipColor: dipColor, easedProgress: eased,
                                    outgoingSurfaceID: outgoingSurface, incomingSurfaceID: incomingSurface, targetSurfaceID: targetSurface))
        default:
            throw RenderGraphError.unsupportedTransitionEffect(effectID: effect)
        }
    }

    /// Push offsets (CP5.5), mirroring the legacy oracle exactly. At eased progress `p` the OUTGOING
    /// surface moves out by `p·extent` and the INCOMING surface enters from `(1−p)·extent` on the
    /// opposite edge:
    ///   left:  A x=+W·p, B x=−W·(1−p);   right: A x=−W·p, B x=+W·(1−p)
    ///   up:    A y=+H·p, B y=−H·(1−p);   down:  A y=−H·p, B y=+H·(1−p)
    /// All in exact fixed point.
    static func pushOffsets(
        direction: RenderSlideDirection, eased: UnitInterval, canvasWidth: Int64, canvasHeight: Int64
    ) throws -> (out: (Int64, Int64), inc: (Int64, Int64)) {
        let u = UnitInterval.unitsPerUnit
        let p = eased.rawValue
        let remaining = u - p
        func scale(_ extent: Int64, _ factor: Int64) throws -> Int64 {
            try FixedPointMath.multiplyDivideRounding(factor, extent, u, "push.offset")
        }
        func neg(_ v: Int64) throws -> Int64 { try CheckedInt64.subtract(0, v, "push.neg") }
        switch direction {
        case .left:
            let a = try scale(canvasWidth, p), b = try neg(try scale(canvasWidth, remaining))
            return ((a, 0), (b, 0))
        case .right:
            let a = try neg(try scale(canvasWidth, p)), b = try scale(canvasWidth, remaining)
            return ((a, 0), (b, 0))
        case .up:
            let a = try scale(canvasHeight, p), b = try neg(try scale(canvasHeight, remaining))
            return ((0, a), (0, b))
        case .down:
            let a = try neg(try scale(canvasHeight, p)), b = try scale(canvasHeight, remaining)
            return ((0, a), (0, b))
        }
    }

    /// Opaque black / white in premultiplied storage (each colour channel ≤ alpha = 1).
    private static func opaqueBlack() throws -> PremultipliedColor {
        try PremultipliedColor(red: .zero, green: .zero, blue: .zero, alpha: .one)
    }
    private static func opaqueWhite() throws -> PremultipliedColor {
        try PremultipliedColor(red: .one, green: .one, blue: .one, alpha: .one)
    }

    static func slideDirection(from parameters: TransitionParameterSet) throws -> RenderSlideDirection {
        guard let value = parameters.value(for: "direction"), case .identifier(let raw) = value else {
            throw RenderGraphError.unsupportedSlideDirection(raw: "<missing>")
        }
        guard let direction = RenderSlideDirection(rawValue: raw) else {
            throw RenderGraphError.unsupportedSlideDirection(raw: raw)
        }
        return direction
    }

    /// The incoming surface's translation offset: it enters from the declared edge, moving toward
    /// centre as progress goes 0→1. At progress `p` the offset is `(1 − p) · extent` along the axis.
    static func slideOffset(
        direction: RenderSlideDirection, eased: UnitInterval, canvasWidth: Int64, canvasHeight: Int64
    ) throws -> (Int64, Int64) {
        let u = UnitInterval.unitsPerUnit
        let remaining = u - eased.rawValue
        func mag(_ extent: Int64) throws -> Int64 {
            try FixedPointMath.multiplyDivideRounding(remaining, extent, u, "slide.offset")
        }
        switch direction {
        case .left:  return (try CheckedInt64.subtract(0, try mag(canvasWidth), "slide.left"), 0)
        case .right: return (try mag(canvasWidth), 0)
        case .up:    return (0, try CheckedInt64.subtract(0, try mag(canvasHeight), "slide.up"))
        case .down:  return (0, try mag(canvasHeight))
        }
    }
}
