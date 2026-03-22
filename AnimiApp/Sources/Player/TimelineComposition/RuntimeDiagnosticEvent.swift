import Foundation

// MARK: - Runtime Diagnostic Events

/// Typed diagnostic events for timeline composition runtime observability.
/// Internal/test-only — does not affect production semantics.
public enum RuntimeDiagnosticEvent: Sendable, Equatable {
    /// Scene type preload started for a scene type ID.
    case sceneTypePreloadStarted(sceneTypeId: String)

    /// Scene type preload completed successfully.
    case sceneTypePreloadCompleted(sceneTypeId: String)

    /// Scene type preload failed with error description.
    case sceneTypePreloadFailed(sceneTypeId: String, error: String)

    /// Instance preparation started at target frame.
    case instancePrepareStarted(instanceId: UUID, targetFrame: Int)

    /// Instance preparation completed (reached .ready).
    case instancePrepareCompleted(instanceId: UUID, targetFrame: Int)

    /// Instance preparation failed with reason.
    case instancePrepareFailed(instanceId: UUID, reason: String)

    /// Media restore applied to instance.
    case mediaRestore(instanceId: UUID, restoredCount: Int)

    /// Transition partner became ready during transition resolution.
    case transitionPartnerReady(instanceIdA: UUID, instanceIdB: UUID)

    /// Eviction decision made for instance.
    case evictionDecision(instanceId: UUID, tier: String)
}
