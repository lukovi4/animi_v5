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
        guard effect == "fade" || effect == "slide" else {
            throw RenderGraphError.unsupportedTransitionEffect(effectID: effect)
        }
        let kind = try TransitionEasing.kind(from: transition.easing.raw)
        let rawProgress = try TransitionEasing.progress(
            numerator: transition.progressNumerator, denominator: transition.progressDenominator)
        let eased = try TransitionEasing.eased(kind, progress: rawProgress)

        switch effect {
        case "fade":
            ctx.emit(.fadeTransition(easedProgress: eased, outgoingSurfaceID: outgoingSurface,
                                     incomingSurfaceID: incomingSurface, targetSurfaceID: targetSurface))
        case "slide":
            let direction = try slideDirection(from: transition.parameters)
            let (offsetX, offsetY) = try slideOffset(direction: direction, eased: eased, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            ctx.emit(.slideTransition(direction: direction, easedProgress: eased, offsetX: offsetX, offsetY: offsetY,
                                      outgoingSurfaceID: outgoingSurface, incomingSurfaceID: incomingSurface, targetSurfaceID: targetSurface))
        default:
            throw RenderGraphError.unsupportedTransitionEffect(effectID: effect)
        }
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
