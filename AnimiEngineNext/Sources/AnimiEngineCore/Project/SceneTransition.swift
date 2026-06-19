/// A serialized transition effect: an effect id plus its canonical parameter set
/// (Task-002 plan, §7.1).
public struct TransitionEffect: Equatable, Sendable {
    public let effectID: TransitionEffectID
    public let parameters: TransitionParameterSet

    public init(effectID: TransitionEffectID, parameters: TransitionParameterSet) {
        self.effectID = effectID
        self.parameters = parameters
    }
}

/// The kind of a scene-boundary transition (Task-002 plan, §7.1).
public enum TransitionKind: Equatable, Sendable {
    case cut
    case animated(TransitionEffect)
}

/// A scene-boundary transition: its kind, duration, and easing (Task-002 plan, §7.1).
///
/// `.cut` has duration zero; an animated effect has a strictly positive duration. These invariants
/// are enforced by ``validated()`` during project validation.
public struct SceneTransition: Equatable, Sendable {
    public let kind: TransitionKind
    public let duration: TickDuration
    public let easing: EasingReference

    public init(kind: TransitionKind, duration: TickDuration, easing: EasingReference) {
        self.kind = kind
        self.duration = duration
        self.easing = easing
    }
}

/// The animated effects supported by the canonical engine (Task-002 plan §7.1; CP5.5 extension).
///
/// Task 002 shipped `fade`/`slide`. CP5.5 adds `push` (directional, both scenes move) and
/// `dipToBlack`/`dipToWhite` (dip through a solid colour), reaching parity with the legacy product
/// model. The dip colour and push offsets are expressed canonically (no engine reads mutable state).
public enum SupportedTransitionEffect {
    public static let fade = "fade"
    public static let slide = "slide"
    public static let push = "push"
    public static let dipToBlack = "dipToBlack"
    public static let dipToWhite = "dipToWhite"

    /// Validates a `SceneTransition`'s kind/duration/parameters (Task-002 plan §7.1; CP5.5).
    ///
    /// - `.cut` accepts duration zero only.
    /// - Animated effects require duration > 0.
    /// - `fade`, `dipToBlack`, `dipToWhite` accept exactly the empty parameter set.
    /// - `slide` and `push` require exactly one `direction` identifier in `left/right/up/down`.
    /// - Missing, extra, duplicate, or wrong-type parameters are typed errors.
    /// - Unknown effect ids are typed unsupported-effect errors.
    public static func validate(_ transition: SceneTransition) throws {
        switch transition.kind {
        case .cut:
            guard transition.duration.ticks == 0 else {
                throw ProjectValidationError.cutWithNonZeroDuration
            }
        case .animated(let effect):
            guard transition.duration.ticks > 0 else {
                throw ProjectValidationError.animatedEffectWithZeroDuration
            }
            try validateEffectParameters(effect)
        }
    }

    private static func validateEffectParameters(_ effect: TransitionEffect) throws {
        let id = effect.effectID.raw
        switch id {
        case fade, dipToBlack, dipToWhite:
            try requireEmptyParameters(effect)
        case slide, push:
            try requireDirectionOnly(effect)
        default:
            throw ProjectValidationError.unsupportedEffect(effectID: id)
        }
    }

    /// An effect that takes no parameters; any supplied parameter is a typed error.
    private static func requireEmptyParameters(_ effect: TransitionEffect) throws {
        if let extra = effect.parameters.sortedUniqueParameters.first {
            throw ProjectValidationError.extraTransitionParameter(effectID: effect.effectID.raw, key: extra.key)
        }
    }

    /// An effect that requires exactly one `direction` identifier in `left/right/up/down`.
    private static func requireDirectionOnly(_ effect: TransitionEffect) throws {
        let id = effect.effectID.raw
        guard let direction = effect.parameters.value(for: "direction") else {
            throw ProjectValidationError.missingTransitionParameter(effectID: id, key: "direction")
        }
        guard case .identifier(let value) = direction else {
            throw ProjectValidationError.wrongTypeTransitionParameter(effectID: id, key: "direction")
        }
        let allowed: Set<String> = ["left", "right", "up", "down"]
        guard allowed.contains(value) else {
            throw ProjectValidationError.wrongTypeTransitionParameter(effectID: id, key: "direction")
        }
        for parameter in effect.parameters.sortedUniqueParameters where parameter.key != "direction" {
            throw ProjectValidationError.extraTransitionParameter(effectID: id, key: parameter.key)
        }
    }
}
