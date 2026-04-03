import Foundation

/// Persisted asset within a media slot: file reference + placement + video params.
/// Wraps `MediaRef`, `MediaPlacementState`, and optional `PersistedVideoSelection`.
public struct SceneMediaAsset: Codable, Equatable, Sendable {

    /// Reference to the persisted media file.
    public var mediaRef: MediaRef

    /// User placement state. Always present — initialized to default on ingest.
    public var placement: MediaPlacementState

    /// Video trim/audio parameters. Nil for photos.
    public var videoWindow: PersistedVideoSelection?

    // MARK: - Initialization

    public init(
        mediaRef: MediaRef,
        placement: MediaPlacementState,
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
        placement: MediaPlacementState
    ) -> SceneMediaAsset {
        SceneMediaAsset(mediaRef: mediaRef, placement: placement)
    }

    /// Creates a video asset.
    public static func video(
        mediaRef: MediaRef,
        placement: MediaPlacementState,
        videoWindow: PersistedVideoSelection
    ) -> SceneMediaAsset {
        SceneMediaAsset(mediaRef: mediaRef, placement: placement, videoWindow: videoWindow)
    }
}
