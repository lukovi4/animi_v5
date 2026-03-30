import Foundation

// MARK: - Scene Media Slot

/// Unified persisted contract for a single media block in a scene instance.
///
/// New format (nested): `{ visibility, asset: { mediaRef, placement?, videoWindow? } }`
/// Old v8 format (flat): `{ mediaRef, visibility, videoWindow? }` — decoded with `placement = nil`.
///
/// Encoding always writes the new nested format.
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

    /// Backward-compatible init matching the old flat API.
    /// Creates a slot wrapping the fields into a `SceneMediaAsset` with `placement = nil`.
    public init(
        mediaRef: MediaRef,
        visibility: Bool = true,
        videoWindow: PersistedVideoSelection? = nil
    ) {
        self.visibility = visibility
        self.asset = SceneMediaAsset(mediaRef: mediaRef, placement: nil, videoWindow: videoWindow)
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
    public var placement: MediaPlacementState? {
        get { asset.placement }
        set { asset.placement = newValue }
    }

    // MARK: - Convenience Factories

    /// Creates a photo slot.
    public static func photo(
        mediaRef: MediaRef,
        visibility: Bool = true,
        placement: MediaPlacementState? = nil
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
        placement: MediaPlacementState? = nil,
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

    private enum NewCodingKeys: String, CodingKey {
        case visibility, asset
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case mediaRef, visibility, videoWindow
    }

    public init(from decoder: Decoder) throws {
        // Try new nested format first: { visibility, asset }
        let newContainer = try? decoder.container(keyedBy: NewCodingKeys.self)
        if let newContainer, newContainer.contains(.asset) {
            self.visibility = try newContainer.decode(Bool.self, forKey: .visibility)
            self.asset = try newContainer.decode(SceneMediaAsset.self, forKey: .asset)
            return
        }

        // Fall back to legacy v8 flat format: { mediaRef, visibility, videoWindow }
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let mediaRef = try legacy.decode(MediaRef.self, forKey: .mediaRef)
        self.visibility = try legacy.decode(Bool.self, forKey: .visibility)
        let videoWindow = try legacy.decodeIfPresent(PersistedVideoSelection.self, forKey: .videoWindow)
        self.asset = SceneMediaAsset(mediaRef: mediaRef, placement: nil, videoWindow: videoWindow)
    }

    public func encode(to encoder: Encoder) throws {
        // Always encode new nested format
        var container = encoder.container(keyedBy: NewCodingKeys.self)
        try container.encode(visibility, forKey: .visibility)
        try container.encode(asset, forKey: .asset)
    }
}
