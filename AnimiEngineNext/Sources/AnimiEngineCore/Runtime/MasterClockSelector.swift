/// Slice-003 Stage B — pure master-clock selection (ADR-006 §3).
///
/// Decides which ``MasterClockKind`` governs an epoch from the audio present in the remaining playback
/// range. The rule (ADR-006 §3): if the remaining range contains any **unmuted** canonical audio —
/// including audio that begins after an initial silent gap — the audio output render clock is master;
/// otherwise an injected monotonic host clock is master. Silent gaps and the end of the final source do
/// not switch the clock.
///
/// The decision reuses the existing pure ``AudioEvaluator`` over the remaining range and never builds
/// its own audio mapping math: an `AudioPlan` with at least one non-muted segment means audible audio,
/// so the clock is `.audioSample`. No `AVAudioTime`, no device time, no host wall clock, no
/// floating-point. The caller freezes the result per epoch; this slice holds no epoch/scheduler state.
public enum MasterClockSelector {

    public static func select(
        window: AudioEvaluationWindow,
        remaining: ProjectTimeRange
    ) throws -> MasterClockKind {
        // Evaluate only the part of `remaining` that the window actually covers. An empty intersection
        // (the remaining range lies wholly outside coverage, or the coverage-clamped interval collapses)
        // means there is no canonical audio to drive a master clock → host. This also keeps us within
        // `AudioEvaluator`'s coverage contract (it rejects out-of-coverage ranges).
        guard let evaluable = clampedToCoverage(remaining, coverage: window.coverage) else {
            return .monotonicHost
        }

        let plan = try AudioEvaluator.evaluate(window: window, range: evaluable)

        // Any unmuted segment anywhere in the remaining range ⇒ audible canonical audio ⇒ audio master.
        // An empty plan, or a plan whose every segment is muted, ⇒ host master.
        let hasUnmutedAudio = plan.segments.contains { !$0.isMuted }
        return hasUnmutedAudio ? .audioSample : .monotonicHost
    }

    /// The half-open intersection of `range` and `coverage`, or `nil` when they do not overlap in a
    /// non-empty interval. Pure integer-tick clamping; constructs a valid (`end > start`)
    /// `ProjectTimeRange` only when the overlap is non-empty.
    private static func clampedToCoverage(
        _ range: ProjectTimeRange,
        coverage: ProjectTimeRange
    ) -> ProjectTimeRange? {
        let start = max(range.start, coverage.start)
        let end = min(range.end, coverage.end)
        guard start < end else { return nil }
        // start/end are existing valid ProjectTime values and start < end, so this never throws.
        return try? ProjectTimeRange(start: start, end: end)
    }
}
