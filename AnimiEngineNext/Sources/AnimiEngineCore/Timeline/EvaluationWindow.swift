/// A resolved scene inside a built evaluation window: its span metadata plus its payload
/// (Task-002 plan, §10.3).
public struct WindowScene: Equatable, Sendable {
    public let span: RequiredSceneSpan
    public let payload: ResolvedScenePayload

    /// Package-internal: minted only by ``EvaluationWindowBuilder`` (corrective plan C-4).
    init(span: RequiredSceneSpan, payload: ResolvedScenePayload) {
        self.span = span
        self.payload = payload
    }
}

/// A resolved transition inside a built evaluation window (Task-002 plan, §10.3).
public struct WindowTransition: Equatable, Sendable {
    public let boundary: RequiredBoundary

    /// Package-internal: minted only by ``EvaluationWindowBuilder`` (corrective plan C-4).
    init(boundary: RequiredBoundary) {
        self.boundary = boundary
    }
}

/// A resolved overlay inside a built evaluation window: its entry metadata plus its payload
/// (Task-002 plan, §10.3).
public struct WindowOverlay: Equatable, Sendable {
    public let entry: RequiredOverlayEntry
    public let payload: ResolvedOverlayPayload

    /// Package-internal: minted only by ``EvaluationWindowBuilder`` (corrective plan C-4).
    init(entry: RequiredOverlayEntry, payload: ResolvedOverlayPayload) {
        self.entry = entry
        self.payload = payload
    }
}

/// An immutable, self-contained evaluation window (Task-002 plan, §10.3).
///
/// The evaluator operates only on this window: no full `CanonicalProject` or payload table is
/// required, and any requested time outside `coverage` is rejected.
public struct EvaluationWindow: Equatable, Sendable {
    public let coverage: ProjectTimeRange
    public let output: OutputContext
    public let projectDuration: TickDuration
    public let scenes: [WindowScene]
    public let transitions: [WindowTransition]
    public let overlays: [WindowOverlay]

    /// Package-internal: minted only by ``EvaluationWindowBuilder`` (corrective plan C-4).
    init(
        coverage: ProjectTimeRange,
        output: OutputContext,
        projectDuration: TickDuration,
        scenes: [WindowScene],
        transitions: [WindowTransition],
        overlays: [WindowOverlay]
    ) {
        self.coverage = coverage
        self.output = output
        self.projectDuration = projectDuration
        self.scenes = scenes
        self.transitions = transitions
        self.overlays = overlays
    }
}
