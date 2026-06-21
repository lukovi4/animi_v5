/// A required scene span within an evaluation-window requirement (Task-002 plan, §10.2).
public struct RequiredSceneSpan: Equatable, Sendable {
    public let sceneID: SceneInstanceID
    public let payloadID: ScenePayloadID
    /// The scene's start instant on the project timeline.
    public let sceneStart: ProjectTime
    /// NATIVE/template duration — the VISUAL clock holds here; layer activeRange/animation are
    /// authored against this.
    public let nominalDuration: TickDuration
    public let postRollCapability: TickDuration
    /// CP7.5: the scene's TIMELINE span on the project (`>= nominalDuration`). The scene occupies
    /// `[sceneStart, sceneStart + timelineSpan)`; the MEDIA clock continues across it.
    public let timelineSpan: TickDuration

    /// Package-internal: minted only by ``TimelineIndex`` (corrective plan C-4). External, non-`@testable`
    /// consumers can read these values but cannot construct them.
    init(
        sceneID: SceneInstanceID,
        payloadID: ScenePayloadID,
        sceneStart: ProjectTime,
        nominalDuration: TickDuration,
        postRollCapability: TickDuration,
        timelineSpan: TickDuration? = nil
    ) {
        self.sceneID = sceneID
        self.payloadID = payloadID
        self.sceneStart = sceneStart
        self.nominalDuration = nominalDuration
        self.postRollCapability = postRollCapability
        self.timelineSpan = timelineSpan ?? nominalDuration
    }
}

/// A required transition boundary within an evaluation-window requirement (Task-002 plan, §10.2).
public struct RequiredBoundary: Equatable, Sendable {
    public let boundaryIndex: Int
    public let boundary: ProjectTime
    public let transition: SceneTransition
    public let window: ProjectTimeRange
    public let outgoingSceneID: SceneInstanceID
    public let incomingSceneID: SceneInstanceID

    /// Package-internal: minted only by ``TimelineIndex`` (corrective plan C-4).
    init(
        boundaryIndex: Int,
        boundary: ProjectTime,
        transition: SceneTransition,
        window: ProjectTimeRange,
        outgoingSceneID: SceneInstanceID,
        incomingSceneID: SceneInstanceID
    ) {
        self.boundaryIndex = boundaryIndex
        self.boundary = boundary
        self.transition = transition
        self.window = window
        self.outgoingSceneID = outgoingSceneID
        self.incomingSceneID = incomingSceneID
    }
}

/// A required overlay entry within an evaluation-window requirement (Task-002 plan, §10.2).
public struct RequiredOverlayEntry: Equatable, Sendable {
    public let overlayID: OverlayID
    public let payloadID: OverlayPayloadID
    public let timeRange: ProjectTimeRange
    public let zIndex: Int
    public let stableOrdinal: Int

    /// Package-internal: minted only by ``TimelineIndex`` (corrective plan C-4).
    init(
        overlayID: OverlayID,
        payloadID: OverlayPayloadID,
        timeRange: ProjectTimeRange,
        zIndex: Int,
        stableOrdinal: Int
    ) {
        self.overlayID = overlayID
        self.payloadID = payloadID
        self.timeRange = timeRange
        self.zIndex = zIndex
        self.stableOrdinal = stableOrdinal
    }
}

/// The authoritative contract between timeline lookup, later payload loading, and the pure window
/// builder (Task-002 plan, §10.2).
public struct EvaluationWindowRequirement: Equatable, Sendable {
    public let coverage: ProjectTimeRange
    /// The authoritative output context, derived from the minting ``TimelineIndex`` (corrective plan C-4).
    public let output: OutputContext
    /// The authoritative project duration, derived from the minting ``TimelineIndex``.
    public let projectDuration: TickDuration
    public let sceneSpans: [RequiredSceneSpan]
    public let transitions: [RequiredBoundary]
    public let overlayEntries: [RequiredOverlayEntry]

    /// Package-internal: minted only by ``TimelineIndex/requirements(for:)`` (corrective plan C-4).
    init(
        coverage: ProjectTimeRange,
        output: OutputContext,
        projectDuration: TickDuration,
        sceneSpans: [RequiredSceneSpan],
        transitions: [RequiredBoundary],
        overlayEntries: [RequiredOverlayEntry]
    ) {
        self.coverage = coverage
        self.output = output
        self.projectDuration = projectDuration
        self.sceneSpans = sceneSpans
        self.transitions = transitions
        self.overlayEntries = overlayEntries
    }
}
