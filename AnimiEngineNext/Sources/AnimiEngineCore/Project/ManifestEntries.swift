/// A lightweight scene entry in the project manifest (Task-002 plan, §6.1).
///
/// The runtime can evaluate one frame from the manifest plus only the selected payloads; it never
/// needs every scene payload loaded.
public struct SceneManifestEntry: Equatable, Sendable {
    public let id: SceneInstanceID
    public let payloadID: ScenePayloadID
    public let nominalDuration: TickDuration
    /// How far the scene can continue playing past its nominal end (post-roll capability), used to
    /// satisfy the outgoing side of an animated transition.
    public let postRollCapability: TickDuration

    public init(
        id: SceneInstanceID,
        payloadID: ScenePayloadID,
        nominalDuration: TickDuration,
        postRollCapability: TickDuration
    ) {
        self.id = id
        self.payloadID = payloadID
        self.nominalDuration = nominalDuration
        self.postRollCapability = postRollCapability
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
