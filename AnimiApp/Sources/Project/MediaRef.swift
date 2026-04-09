import Foundation

/// Whether the referenced media is a still image or a video.
public enum MediaKind: String, Codable, Hashable, Sendable {
    case photo
    case video
}

/// Persistent reference to user media file.
/// For v1: file copy approach (stored in Application Support).
public struct MediaRef: Codable, Hashable, Sendable {
    /// Type of media reference.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// File stored in app sandbox (Application Support/AnimiProjects/Media/)
        case file
    }

    /// Reference type
    public var kind: Kind

    /// Relative path within Application Support (e.g., "Media/Background/<uuid>.jpg")
    public var id: String

    /// Whether this is a photo or video. Backward-compatible: inferred from extension if absent.
    public var mediaKind: MediaKind

    public init(kind: Kind, id: String, mediaKind: MediaKind = .photo) {
        self.kind = kind
        self.id = id
        self.mediaKind = mediaKind
    }

    /// Creates a file-based media reference.
    /// - Parameter relativePath: Path relative to AnimiProjects directory
    public static func file(_ relativePath: String, mediaKind: MediaKind = .photo) -> MediaRef {
        MediaRef(kind: .file, id: relativePath, mediaKind: mediaKind)
    }

    // MARK: - Backward-Compatible Codable

    private enum CodingKeys: String, CodingKey {
        case kind, id, mediaKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        mediaKind = try container.decodeIfPresent(MediaKind.self, forKey: .mediaKind)
            ?? Self.inferMediaKind(from: id)
    }

    /// Infers media kind from file extension for backward compatibility.
    private static func inferMediaKind(from id: String) -> MediaKind {
        let ext = (id as NSString).pathExtension.lowercased()
        let videoExts = ["mp4", "mov", "m4v"]
        return videoExts.contains(ext) ? .video : .photo
    }
}
