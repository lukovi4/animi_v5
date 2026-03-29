import Foundation

// MARK: - Scene Media Slot

/// Unified persisted contract for a single media block in a scene instance.
/// Replaces the old split representation (mediaAssignments + userMediaPresent + videoSelections).
///
/// Each slot fully describes the persisted state of one media block:
/// - What media is assigned (mediaRef)
/// - Whether the binding layer should be rendered (visibility)
/// - Video trim/audio parameters (videoWindow, nil for photos)
public struct SceneMediaSlot: Codable, Equatable, Sendable {

    /// Reference to the persisted media file.
    public var mediaRef: MediaRef

    /// Whether the binding layer should be rendered.
    /// `true` = render binding layer, `false` = hide (media still assigned).
    public var visibility: Bool

    /// Video trim/audio parameters. Nil for photos.
    public var videoWindow: PersistedVideoSelection?

    // MARK: - Initialization

    public init(
        mediaRef: MediaRef,
        visibility: Bool = true,
        videoWindow: PersistedVideoSelection? = nil
    ) {
        self.mediaRef = mediaRef
        self.visibility = visibility
        self.videoWindow = videoWindow
    }

    // MARK: - Convenience Factories

    /// Creates a photo slot.
    public static func photo(mediaRef: MediaRef, visibility: Bool = true) -> SceneMediaSlot {
        SceneMediaSlot(mediaRef: mediaRef, visibility: visibility)
    }

    /// Creates a video slot.
    /// `videoWindow` is required — a persisted video slot without a valid window is not allowed.
    public static func video(
        mediaRef: MediaRef,
        visibility: Bool = true,
        videoWindow: PersistedVideoSelection
    ) -> SceneMediaSlot {
        SceneMediaSlot(mediaRef: mediaRef, visibility: visibility, videoWindow: videoWindow)
    }
}
