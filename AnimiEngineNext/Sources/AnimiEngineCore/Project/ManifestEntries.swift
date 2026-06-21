/// A lightweight scene entry in the project manifest (Task-002 plan, §6.1).
///
/// The runtime can evaluate one frame from the manifest plus only the selected payloads; it never
/// needs every scene payload loaded.
public struct SceneManifestEntry: Equatable, Sendable {
    public let id: SceneInstanceID
    public let payloadID: ScenePayloadID
    /// The scene's NATIVE/template duration. Template animation + layer activeRange + animation
    /// sampling are authored against this. Past it the VISUAL clock holds the last native frame.
    public let nominalDuration: TickDuration
    /// How far the scene can continue playing past its nominal end (post-roll capability), used to
    /// satisfy the outgoing side of an animated transition.
    public let postRollCapability: TickDuration
    /// CP7.5 (schema v2): the scene's TIMELINE span on the project — `>= nominalDuration`. When the
    /// scene is "stretched" (`timelineSpan > nominalDuration`) the MEDIA/video clock continues across
    /// the full span while the VISUAL clock holds at `nominalDuration`. Project duration, scene
    /// layout, and transition boundaries are computed from this span. Defaults to `nominalDuration`
    /// (no stretch) so every existing non-stretched call site is unchanged. v1 documents decode with
    /// `timelineSpan == nominalDuration`.
    public let timelineSpan: TickDuration

    public init(
        id: SceneInstanceID,
        payloadID: ScenePayloadID,
        nominalDuration: TickDuration,
        postRollCapability: TickDuration,
        timelineSpan: TickDuration? = nil
    ) {
        self.id = id
        self.payloadID = payloadID
        self.nominalDuration = nominalDuration
        self.postRollCapability = postRollCapability
        self.timelineSpan = timelineSpan ?? nominalDuration
    }
}

/// A lightweight overlay entry in the project manifest (Task-002 plan, §6.1).
public struct OverlayManifestEntry: Equatable, Sendable {
    public let id: OverlayID
    public let payloadID: OverlayPayloadID
    public let timeRange: ProjectTimeRange
    public let zIndex: Int
    public let stableOrdinal: Int

    public init(
        id: OverlayID,
        payloadID: OverlayPayloadID,
        timeRange: ProjectTimeRange,
        zIndex: Int,
        stableOrdinal: Int
    ) {
        self.id = id
        self.payloadID = payloadID
        self.timeRange = timeRange
        self.zIndex = zIndex
        self.stableOrdinal = stableOrdinal
    }
}
