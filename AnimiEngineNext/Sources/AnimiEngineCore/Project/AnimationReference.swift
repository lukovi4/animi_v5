/// Policy for what happens when authored animation material is **shorter** than the evaluated
/// interval (Task-002 plan, §6.3).
public enum AnimationShorterPolicy: Equatable, Sendable {
    case holdLast
    case loop
    case becomeInactive
}

/// Policy for what happens when authored animation material is **longer** than the evaluated
/// interval (Task-002 plan, §6.3). v1 always cuts at evaluation end.
public enum AnimationLongerPolicy: Equatable, Sendable {
    case cutAtEvaluationEnd
}

/// An immutable reference to a template animation plus its authored duration and out-of-range
/// policies (Task-002 plan, §6.3).
///
/// Every present `AnimationReference` has `authoredDuration > 0`; the validator rejects zero.
public struct AnimationReference: Equatable, Sendable {
    public let variantID: String
    public let animationRef: String
    public let authoredDuration: TickDuration
    public let ifShorter: AnimationShorterPolicy
    public let ifLonger: AnimationLongerPolicy

    public init(
        variantID: String,
        animationRef: String,
        authoredDuration: TickDuration,
        ifShorter: AnimationShorterPolicy,
        ifLonger: AnimationLongerPolicy
    ) throws {
        guard authoredDuration.ticks > 0 else {
            throw ProjectValidationError.invalidAuthoredAnimationDuration
        }
        self.variantID = variantID
        self.animationRef = animationRef
        self.authoredDuration = authoredDuration
        self.ifShorter = ifShorter
        self.ifLonger = ifLonger
    }
}
