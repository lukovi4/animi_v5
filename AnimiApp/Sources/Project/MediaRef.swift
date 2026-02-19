import Foundation

/// Persistent reference to user media file.
/// For v1: file copy approach (stored in Application Support).
public struct MediaRef: Codable, Equatable, Sendable {
    /// Type of media reference.
    public enum Kind: String, Codable, Sendable {
        /// File stored in app sandbox (Application Support/AnimiProjects/Media/)
        case file
    }

    /// Reference type
    public var kind: Kind

    /// Relative path within Application Support (e.g., "Media/Background/<uuid>.jpg")
    public var id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// Creates a file-based media reference.
    /// - Parameter relativePath: Path relative to AnimiProjects directory
    public static func file(_ relativePath: String) -> MediaRef {
        MediaRef(kind: .file, id: relativePath)
    }
}
