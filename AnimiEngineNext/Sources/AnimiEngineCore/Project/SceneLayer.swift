/// A video media binding for a scene layer (Task-002 plan, §6.2).
///
/// There is no `.video` with optional media — every active video layer can produce a complete
/// ``SourceRequest`` because the binding always carries both the media reference and the exact
/// source-time mapping.
public struct VideoBinding: Equatable, Sendable {
    public let media: MediaReference
    public let sourceMapping: SourceTimeMapping

    public init(media: MediaReference, sourceMapping: SourceTimeMapping) {
        self.media = media
        self.sourceMapping = sourceMapping
    }
}

/// The content of a scene-owned layer: video or image (Task-002 plan, §1.3, §6.2).
///
/// Text, stickers, and graphics are global timeline overlays, never scene layers.
public enum SceneLayerContent: Equatable, Sendable {
    case video(VideoBinding)
    case image(ImageReference)
}

/// A scene-owned layer (Task-002 plan, §6.2).
public struct SceneLayer: Equatable, Sendable {
    public let id: LayerID
    public let zIndex: Int
    public let stableOrdinal: Int
    public let activeRange: ScenePlaybackRange
    public let placement: Placement
    /// The authored media placement (fit mode + user transform inside the binding baseline), distinct
    /// from the outer `placement` (step-8 corrective, issue #1).
    public let mediaPlacement: MediaPlacement
    public let content: SceneLayerContent
    public let animation: AnimationReference?

    public init(
        id: LayerID,
        zIndex: Int,
        stableOrdinal: Int,
        activeRange: ScenePlaybackRange,
        placement: Placement,
        mediaPlacement: MediaPlacement,
        content: SceneLayerContent,
        animation: AnimationReference?
    ) {
        self.id = id
        self.zIndex = zIndex
        self.stableOrdinal = stableOrdinal
        self.activeRange = activeRange
        self.placement = placement
        self.mediaPlacement = mediaPlacement
        self.content = content
        self.animation = animation
    }
}
