import Foundation

// MARK: - Media Asset Store

/// Unified file-based persistence for user media assets.
/// Single entry point for saving both photos and videos to the project media directory.
/// For video: this is the single durable copy from the PHPicker file representation (no temp copy).
public final class MediaAssetStore {

    private let projectStore: ProjectStore

    public init(projectStore: ProjectStore = .shared) {
        self.projectStore = projectStore
    }

    // MARK: - Save API

    /// Saves a media file (photo or video) to the user media directory.
    /// Single-copy operation: copies/writes the file to its canonical location.
    ///
    /// - Parameters:
    ///   - fileURL: Source file URL (temp photo JPEG or video file)
    ///   - mediaKind: Whether this is a photo or video
    ///   - sceneInstanceId: Scene instance owning this media
    ///   - blockId: Block ID this media is assigned to
    /// - Returns: Tuple of (MediaRef, absolute destination URL). Both are available atomically
    ///   after the copy succeeds — no separate resolve step needed.
    public func saveMedia(
        from fileURL: URL,
        mediaKind: MediaKind,
        sceneInstanceId: UUID,
        blockId: String
    ) throws -> (MediaRef, URL) {
        try projectStore.ensureDirectoriesExist()

        let uuid = UUID().uuidString
        let ext: String
        switch mediaKind {
        case .photo:
            ext = "jpg"
        case .video:
            ext = fileURL.pathExtension.lowercased()
        }

        let filename = "\(sceneInstanceId.uuidString)_\(blockId)_\(uuid).\(ext)"
        let relativePath = "Media/UserMedia/\(filename)"

        let mediaDir = try projectStore.userMediaDirectoryURL()
        let destURL = mediaDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }

        try FileManager.default.copyItem(at: fileURL, to: destURL)

        return (MediaRef.file(relativePath, mediaKind: mediaKind), destURL)
    }

    /// Returns the absolute URL for a media reference.
    public func absoluteURL(for mediaRef: MediaRef) throws -> URL {
        try projectStore.absoluteURL(for: mediaRef)
    }
}
