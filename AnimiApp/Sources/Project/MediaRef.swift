import Foundation

/// Whether the referenced media is a still image or a video.
public enum MediaKind: String, Codable, Hashable, Sendable {
    case photo
    case video
}

/// Persistent reference to user media file.
/// Identity is by `assetId` (logical UUID), not by storage path.
public struct MediaRef: Codable, Sendable {
    /// Logical asset identity — decoupled from file path.
    public var assetId: ProjectAssetID

    /// Whether this is a photo or video.
    public var mediaKind: MediaKind

    /// Relative path within Application Support (e.g., "Media/Background/<uuid>.jpg").
    /// Internal storage detail — not used for identity.
    public var storagePath: String

    public init(storagePath: String, mediaKind: MediaKind = .photo, assetId: ProjectAssetID = .init()) {
        self.assetId = assetId
        self.mediaKind = mediaKind
        self.storagePath = storagePath
    }

    /// Creates a file-based media reference.
    public static func file(
        _ storagePath: String,
        assetId: ProjectAssetID = .init(),
        mediaKind: MediaKind = .photo
    ) -> MediaRef {
        MediaRef(storagePath: storagePath, mediaKind: mediaKind, assetId: assetId)
    }

    // MARK: - Hashable / Equatable by assetId only

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.assetId == rhs.assetId }
    public func hash(into hasher: inout Hasher) { hasher.combine(assetId) }
}

// MARK: - Hashable conformance

extension MediaRef: Hashable {}
