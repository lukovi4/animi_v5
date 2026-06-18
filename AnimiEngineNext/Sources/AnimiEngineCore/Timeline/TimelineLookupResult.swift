/// A reference to the active transition boundary at a queried time (Task-002 plan, §10.1).
public struct ActiveBoundaryReference: Equatable, Sendable {
    /// Index of the boundary in `manifest.boundaryTransitions`.
    public let boundaryIndex: Int
    public let boundary: ProjectTime
    public let transition: SceneTransition
    public let window: ProjectTimeRange

    public init(boundaryIndex: Int, boundary: ProjectTime, transition: SceneTransition, window: ProjectTimeRange) {
        self.boundaryIndex = boundaryIndex
        self.boundary = boundary
        self.transition = transition
        self.window = window
    }
}

/// The result of looking up a single project time on the timeline (Task-002 plan, §10.1).
///
/// `requiredSceneIDs` is one scene for normal playback / cut, or outgoing+incoming for an active
/// animated transition window.
public struct TimelineLookupResult: Equatable, Sendable {
    public let requiredSceneIDs: [SceneInstanceID]
    public let requiredScenePayloadIDs: [ScenePayloadID]
    public let transition: ActiveBoundaryReference?
    public let activeOverlayIDs: [OverlayID]
    public let activeOverlayPayloadIDs: [OverlayPayloadID]

    public init(
        requiredSceneIDs: [SceneInstanceID],
        requiredScenePayloadIDs: [ScenePayloadID],
        transition: ActiveBoundaryReference?,
        activeOverlayIDs: [OverlayID],
        activeOverlayPayloadIDs: [OverlayPayloadID]
    ) {
        self.requiredSceneIDs = requiredSceneIDs
        self.requiredScenePayloadIDs = requiredScenePayloadIDs
        self.transition = transition
        self.activeOverlayIDs = activeOverlayIDs
        self.activeOverlayPayloadIDs = activeOverlayPayloadIDs
    }
}
