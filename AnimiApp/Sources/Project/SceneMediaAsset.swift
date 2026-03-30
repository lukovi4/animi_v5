import Foundation

/// Persisted asset within a media slot: file reference + placement + video params.
/// Wraps `MediaRef`, optional `MediaPlacementState`, and optional `PersistedVideoSelection`.
public struct SceneMediaAsset: Codable, Equatable, Sendable {

    /// Reference to the persisted media file.
    public var mediaRef: MediaRef

    /// User placement state. `nil` means not yet hydrated (legacy data).
    /// Hydration happens at runtime via `SceneStateMigrationHelper`.
    public var placement: MediaPlacementState?

    /// Video trim/audio parameters. Nil for photos.
    public var videoWindow: PersistedVideoSelection?

    // MARK: - Initialization

    public init(
        mediaRef: MediaRef,
        placement: MediaPlacementState? = nil,
        videoWindow: PersistedVideoSelection? = nil
    ) {
        self.mediaRef = mediaRef
        self.placement = placement
        self.videoWindow = videoWindow
    }

    // MARK: - Convenience Factories

    /// Creates a photo asset.
    public static func photo(
        mediaRef: MediaRef,
        placement: MediaPlacementState? = nil
    ) -> SceneMediaAsset {
        SceneMediaAsset(mediaRef: mediaRef, placement: placement)
    }

    /// Creates a video asset.
    public static func video(
        mediaRef: MediaRef,
        placement: MediaPlacementState? = nil,
        videoWindow: PersistedVideoSelection
    ) -> SceneMediaAsset {
        SceneMediaAsset(mediaRef: mediaRef, placement: placement, videoWindow: videoWindow)
    }
}
