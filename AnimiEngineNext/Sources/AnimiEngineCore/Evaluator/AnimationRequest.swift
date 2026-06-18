/// The explicit animation request emitted by the evaluator (Task-002 plan, §6.3).
///
/// The half-open animation endpoint is never represented as a fabricated "last time". Instead the
/// evaluator emits one of these explicit cases, derived from the layer's authored
/// ``AnimationShorterPolicy``.
public enum AnimationRequest: Equatable, Sendable {
    /// Sample the authored animation at the given animation-local time (before the authored end).
    case sample(AnimationPlaybackTime)
    /// `.loop` policy past the authored end: sample at the wrapped time within the authored range.
    case looped(AnimationPlaybackTime)
    /// `.holdLast` policy past the authored end: hold the last authored frame.
    case holdLast
    /// `.becomeInactive` policy past the authored end: the animation produces nothing.
    case inactive
}

/// Pure resolution of an authored animation reference at an animation-local time (Task-002 plan,
/// §6.3, §8.5).
public enum AnimationRequestResolver {
    /// Resolves the request for `reference` at `time`.
    ///
    /// - before `authoredDuration`: `.sample(time)`;
    /// - at/after the authored end: `.holdLast` / `.looped(wrapped)` / `.inactive` per policy.
    public static func resolve(
        reference: AnimationReference,
        at time: AnimationPlaybackTime
    ) -> AnimationRequest {
        let authored = reference.authoredDuration.ticks      // > 0 by AnimationReference invariant
        if time.ticks < authored {
            return .sample(time)
        }
        switch reference.ifShorter {
        case .holdLast:
            return .holdLast
        case .becomeInactive:
            return .inactive
        case .loop:
            // Wrap into [0, authored). authored > 0, so the modulo is well-defined.
            let wrapped = time.ticks % authored
            return .looped(AnimationPlaybackTime(uncheckedTicks: wrapped))
        }
    }
}
