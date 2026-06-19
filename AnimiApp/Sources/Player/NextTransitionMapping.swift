#if DEBUG
import Foundation

import AnimiEngineCore

// MARK: - CP5 / CP5.5: app SceneTransition -> canonical Next SceneTransition (DEBUG only)
//
// CP5 added cut/fade/slide(direction). CP5.5 extends the canonical Next model to cover the remaining
// app v1 boundary transitions: push(direction), dipToBlack, and dipToWhite. Unknown transition types
// still fail closed; there is never a silent map to another effect.
//
// Timing is canonical: the app boundary duration is `durationFrames` at the timeline fps. We convert
// it to canonical ticks (exact integer ticks-per-frame at 240,000 ticks/second) and hand it to Next;
// the canonical evaluator owns the centered transition window and the exact rational progress. We do
// NOT compute progress app-side (no Double guessing).

/// The pure, app-supplied description of one scene-boundary transition the bridge must map. Carries
/// only primitives so the type stays free of any TVECore dependency.
struct NextBridgeTransition {
    /// App transition type raw discriminator. One of:
    /// `none | fade | slide | push | dipToBlack | dipToWhite`. For `slide`/`push`, `direction` is required.
    let typeRaw: String
    /// Slide/push direction (`left|right|up|down`) when required; ignored otherwise.
    let direction: String?
    /// App boundary duration in frames at the timeline fps.
    let durationFrames: Int
    /// App easing preset raw: `linear` or `easeInOut` (canonical accepts both; `none` for cut).
    let easingRaw: String
}

/// Typed, visible failure for CP5 transition mapping. No silent substitution.
enum NextTransitionMappingError: Error, CustomStringConvertible {
    case unsupportedTransitionType(typeRaw: String)
    case missingDirection(effect: String)
    case invalidDirection(effect: String, direction: String)
    case unsupportedEasing(easingRaw: String)
    case nonPositiveAnimatedDuration(durationFrames: Int)
    case engine(String)

    var description: String {
        switch self {
        case .unsupportedTransitionType(let t):
            return "Next bridge: transition type '\(t)' is not supported by AnimiEngineNext."
        case .missingDirection(let effect):
            return "Next bridge: \(effect) transition requires a direction (left/right/up/down)."
        case .invalidDirection(let effect, let d):
            return "Next bridge: \(effect) direction '\(d)' invalid. Use left/right/up/down."
        case .unsupportedEasing(let e):
            return "Next bridge: easing '\(e)' not supported. CP5 maps only linear/easeInOut."
        case .nonPositiveAnimatedDuration(let n):
            return "Next bridge: animated transition requires duration > 0 frames (got \(n))."
        case .engine(let m):
            return "Next bridge transition mapping engine error: \(m)."
        }
    }
}

enum NextTransitionMapping {

    /// Exact integer ticks-per-frame at the timeline fps, matching `AnimiEngineCore.FrameRate`
    /// (240,000 ticks/second). CP5 timeline fps is 30 (the v1 product constant) → 8,000 ticks/frame.
    /// Any unsupported fps fails closed rather than guessing.
    static func ticksPerFrame(fps: Int) throws -> Int64 {
        // TickClock.ticksPerSecond is 240,000; require an exact division so timing is integer-exact.
        let ticksPerSecond = TickClock.ticksPerSecond
        guard fps > 0, ticksPerSecond % Int64(fps) == 0 else {
            throw NextTransitionMappingError.engine("unsupported timeline fps \(fps) (no exact ticks-per-frame)")
        }
        return ticksPerSecond / Int64(fps)
    }

    /// Map app easing preset raw → canonical easing identifier. Canonical `TransitionEasing.Kind`
    /// accepts exactly `linear`/`easeInOut`/`none`. `none` is the cut-only easing.
    static func easingReference(easingRaw: String, isCut: Bool) throws -> EasingReference {
        let canonical: String
        if isCut {
            // A cut is not animated; canonical uses the `none` easing for it.
            canonical = "none"
        } else {
            switch easingRaw {
            case "linear": canonical = "linear"
            case "easeInOut": canonical = "easeInOut"
            default: throw NextTransitionMappingError.unsupportedEasing(easingRaw: easingRaw)
            }
        }
        do { return try EasingReference(canonical) }
        catch { throw NextTransitionMappingError.engine("easing reference '\(canonical)': \(error)") }
    }

    /// Map one app transition to a canonical `SceneTransition`. Canonical duration is the app frame
    /// count converted to exact ticks. The evaluator computes the window and exact rational progress
    /// from this duration; we never compute progress here.
    ///
    /// NOTE: `SceneTransition`/`TransitionEffect`/… are fully qualified `AnimiEngineCore.*` because the
    /// app declares its OWN `SceneTransition` (the v6 product model) with a different shape.
    static func map(_ t: NextBridgeTransition, fps: Int) throws -> AnimiEngineCore.SceneTransition {
        let tpf = try ticksPerFrame(fps: fps)
        switch t.typeRaw {
        case "none":
            // Instant cut: canonical requires duration zero + `none` easing.
            let easing = try easingReference(easingRaw: t.easingRaw, isCut: true)
            return AnimiEngineCore.SceneTransition(kind: .cut, duration: .zero, easing: easing)
        case "fade":
            try requirePositive(t.durationFrames)
            let ticks = try durationTicks(t.durationFrames, tpf)
            let effect = try makeEffect(id: SupportedTransitionEffect.fade, parameters: .empty)
            let easing = try easingReference(easingRaw: t.easingRaw, isCut: false)
            return AnimiEngineCore.SceneTransition(kind: .animated(effect), duration: ticks, easing: easing)
        case "slide":
            try requirePositive(t.durationFrames)
            let ticks = try durationTicks(t.durationFrames, tpf)
            let params = try directionParams(t.direction, effect: "slide")
            let effect = try makeEffect(id: SupportedTransitionEffect.slide, parameters: params)
            let easing = try easingReference(easingRaw: t.easingRaw, isCut: false)
            return AnimiEngineCore.SceneTransition(kind: .animated(effect), duration: ticks, easing: easing)
        case "push":
            // CP5.5: push is now canonically supported (direction param, both scenes move).
            try requirePositive(t.durationFrames)
            let ticks = try durationTicks(t.durationFrames, tpf)
            let params = try directionParams(t.direction, effect: "push")
            let effect = try makeEffect(id: SupportedTransitionEffect.push, parameters: params)
            let easing = try easingReference(easingRaw: t.easingRaw, isCut: false)
            return AnimiEngineCore.SceneTransition(kind: .animated(effect), duration: ticks, easing: easing)
        case "dipToBlack", "dipToWhite":
            // CP5.5: dip is now canonically supported (empty params; dip colour is canonical per effect id).
            try requirePositive(t.durationFrames)
            let ticks = try durationTicks(t.durationFrames, tpf)
            let id = (t.typeRaw == "dipToWhite") ? SupportedTransitionEffect.dipToWhite : SupportedTransitionEffect.dipToBlack
            let effect = try makeEffect(id: id, parameters: .empty)
            let easing = try easingReference(easingRaw: t.easingRaw, isCut: false)
            return AnimiEngineCore.SceneTransition(kind: .animated(effect), duration: ticks, easing: easing)
        default:
            // Unknown transition types remain fail-closed (no silent mapping).
            throw NextTransitionMappingError.unsupportedTransitionType(typeRaw: t.typeRaw)
        }
    }

    /// Build the `direction` parameter set for slide/push, validating the value is left/right/up/down.
    private static func directionParams(_ direction: String?, effect: String) throws -> TransitionParameterSet {
        guard let dir = direction else { throw NextTransitionMappingError.missingDirection(effect: effect) }
        let allowed: Set<String> = ["left", "right", "up", "down"]
        guard allowed.contains(dir) else { throw NextTransitionMappingError.invalidDirection(effect: effect, direction: dir) }
        do {
            return try TransitionParameterSet([TransitionParameter(key: "direction", value: .identifier(dir))])
        } catch { throw NextTransitionMappingError.engine("\(effect) parameters: \(error)") }
    }

    /// The post-roll capability (ticks) the OUTGOING scene needs for one boundary: it continues
    /// playing past its nominal end for the first half of the transition window. Mirrors the app's
    /// existing `transition.durationFrames / 2` clamp (TimelineTransitionMath), expressed in ticks.
    /// A cut needs zero post-roll.
    static func postRollTicks(_ t: NextBridgeTransition, fps: Int) throws -> TickDuration {
        guard t.typeRaw != "none" else { return .zero }
        let tpf = try ticksPerFrame(fps: fps)
        // Half the transition duration (floor), in frames → ticks. The canonical evaluator centers
        // the window as `[B - floor(D/2), B + ceil(D/2))`; the outgoing side spans up to floor(D/2)
        // frames past the boundary, so floor(D/2) frames of post-roll covers it.
        let halfFrames = Int64(max(0, t.durationFrames / 2))
        do { return try TickDuration(ticks: halfFrames * tpf) }
        catch { throw NextTransitionMappingError.engine("postRoll ticks: \(error)") }
    }

    // MARK: - Private

    private static func requirePositive(_ frames: Int) throws {
        guard frames > 0 else { throw NextTransitionMappingError.nonPositiveAnimatedDuration(durationFrames: frames) }
    }

    private static func durationTicks(_ frames: Int, _ tpf: Int64) throws -> TickDuration {
        do { return try TickDuration(ticks: Int64(frames) * tpf) }
        catch { throw NextTransitionMappingError.engine("duration ticks: \(error)") }
    }

    private static func makeEffect(id: String, parameters: TransitionParameterSet) throws -> TransitionEffect {
        do { return TransitionEffect(effectID: try TransitionEffectID(id), parameters: parameters) }
        catch { throw NextTransitionMappingError.engine("effect id '\(id)': \(error)") }
    }
}
#endif
