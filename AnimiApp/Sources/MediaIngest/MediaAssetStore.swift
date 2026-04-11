import Foundation

// MARK: - Media Asset Store

/// Unified file-based persistence for user media assets.
/// Single entry point for saving both photos and videos to the project media directory.
/// For video: this is the single durable copy from the PHPicker file representation (no temp copy).
public final class MediaAssetStore {

    private let mediaWriter: any ProjectMediaWriteGateway

    public init(mediaWriter: any ProjectMediaWriteGateway) {
        self.mediaWriter = mediaWriter
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
    ) async throws -> (MediaRef, URL) {
        let uuid = UUID().uuidString
        let ext = fileURL.pathExtension.lowercased()
        let filename = "\(sceneInstanceId.uuidString)_\(blockId)_\(uuid).\(ext)"

        return try await mediaWriter.saveUserMedia(from: fileURL, mediaKind: mediaKind, filename: filename)
    }
}
