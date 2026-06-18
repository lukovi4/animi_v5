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

/// The two animated effects supported in Task 002 (Task-002 plan, §7.1).
public enum SupportedTransitionEffect {
    public static let fade = "fade"
    public static let slide = "slide"

    /// Validates a `SceneTransition`'s kind/duration/parameters (Task-002 plan, §7.1).
    ///
    /// - `.cut` accepts duration zero only.
    /// - Animated effects require duration > 0.
    /// - `fade` accepts exactly its documented parameter set — empty in Task 002.
    /// - `slide` requires exactly one `direction` identifier in `left/right/up/down`.
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
        let params = effect.parameters.sortedUniqueParameters
        switch id {
        case fade:
            // Fade accepts exactly the empty parameter set in Task 002.
            if let extra = params.first {
                throw ProjectValidationError.extraTransitionParameter(effectID: id, key: extra.key)
            }
        case slide:
            // Slide requires exactly one `direction` identifier with a valid value.
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
            // Reject any parameter other than `direction`.
            for parameter in params where parameter.key != "direction" {
                throw ProjectValidationError.extraTransitionParameter(effectID: id, key: parameter.key)
            }
        default:
            throw ProjectValidationError.unsupportedEffect(effectID: id)
        }
    }
}
