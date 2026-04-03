import Foundation

// MARK: - Scene Media Slot

/// Unified persisted contract for a single media block in a scene instance.
///
/// Format: `{ visibility, asset: { mediaRef, placement, videoWindow? } }`
///
/// `placement` is always present — initialized to default fit mode on ingest.
public struct SceneMediaSlot: Equatable, Sendable {

    /// Whether the binding layer should be rendered.
    /// `true` = render binding layer, `false` = hide (media still assigned).
    public var visibility: Bool

    /// The media asset (file reference, placement, video params).
    public var asset: SceneMediaAsset

    // MARK: - Initialization

    public init(visibility: Bool = true, asset: SceneMediaAsset) {
        self.visibility = visibility
        self.asset = asset
    }

    // MARK: - Convenience Accessors (bridge)

    /// Shortcut to the media file reference.
    public var mediaRef: MediaRef {
        get { asset.mediaRef }
        set { asset.mediaRef = newValue }
    }

    /// Shortcut to video trim/audio params.
    public var videoWindow: PersistedVideoSelection? {
        get { asset.videoWindow }
        set { asset.videoWindow = newValue }
    }

    /// Shortcut to placement state.
    public var placement: MediaPlacementState {
        get { asset.placement }
        set { asset.placement = newValue }
    }

    // MARK: - Convenience Factories

    /// Creates a photo slot.
    public static func photo(
        mediaRef: MediaRef,
        visibility: Bool = true,
        placement: MediaPlacementState
    ) -> SceneMediaSlot {
        SceneMediaSlot(
            visibility: visibility,
            asset: .photo(mediaRef: mediaRef, placement: placement)
        )
    }

    /// Creates a video slot.
    /// `videoWindow` is required — a persisted video slot without a valid window is not allowed.
    public static func video(
        mediaRef: MediaRef,
        visibility: Bool = true,
        placement: MediaPlacementState,
        videoWindow: PersistedVideoSelection
    ) -> SceneMediaSlot {
        SceneMediaSlot(
            visibility: visibility,
            asset: .video(mediaRef: mediaRef, placement: placement, videoWindow: videoWindow)
        )
    }
}

// MARK: - Codable

extension SceneMediaSlot: Codable {

    private enum CodingKeys: String, CodingKey {
        case visibility, asset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.visibility = try container.decode(Bool.self, forKey: .visibility)
        self.asset = try container.decode(SceneMediaAsset.self, forKey: .asset)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(visibility, forKey: .visibility)
        try container.encode(asset, forKey: .asset)
    }
}
