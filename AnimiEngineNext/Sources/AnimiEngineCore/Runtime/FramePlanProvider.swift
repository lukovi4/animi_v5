/// Slice-003 Stage D — the evaluation seam (ADR-006 §6).
///
/// The scheduler obtains a complete `FramePlan` for one exact project time through this protocol rather
/// than calling the evaluator directly, so tests can inject late/failed/garbage providers. The default
/// adapter wraps the existing pure `TimelineEvaluator` WITHOUT modifying it.
public protocol FramePlanProvider: Sendable {
    func plan(window: EvaluationWindow, at time: ProjectTime) throws -> FramePlan
}

/// The default adapter: delegates to the unmodified `TimelineEvaluator`. Pure; no I/O, no rendering.
public struct TimelineEvaluatorFramePlanProvider: FramePlanProvider {
    public init() {}

    public func plan(window: EvaluationWindow, at time: ProjectTime) throws -> FramePlan {
        try TimelineEvaluator.evaluate(window, at: time)
    }
}
