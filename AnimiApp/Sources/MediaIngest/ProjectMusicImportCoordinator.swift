import Foundation
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "MusicImport")

/// Owns the async music import pipeline: temp copy → persist → register → read duration → dispatch.
@MainActor
final class ProjectMusicImportCoordinator {

    private let session: EditorSession

    init(session: EditorSession) {
        self.session = session
    }

    /// Imports audio from a temp file: persist with collision-proof name, register, read duration, dispatch.
    /// Cleans up temp file and reverts on failure.
    func importProjectMusic(tempURL: URL, originalExtension: String) {
        Task { @MainActor [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            var persistedMediaRef: MediaRef?
            do {
                // Collision-proof storage filename: UUID + original extension
                let storageFilename = originalExtension.isEmpty
                    ? UUID().uuidString
                    : "\(UUID().uuidString).\(originalExtension)"

                let (mediaRef, savedURL) = try await self.session.mediaWriter.saveUserMedia(
                    from: tempURL,
                    mediaKind: .audio,
                    filename: storageFilename
                )
                persistedMediaRef = mediaRef

                // Remove temp file now that persist succeeded
                try? FileManager.default.removeItem(at: tempURL)

                // Register in asset registry
                let descriptor = ProjectAssetDescriptor(
                    assetId: mediaRef.assetId,
                    mediaKind: .audio,
                    storagePath: mediaRef.storagePath
                )
                self.session.registerAssetBookkeeping(descriptor)

                // Read duration
                let asset = AVURLAsset(url: savedURL)
                let duration = try await asset.load(.duration)
                let durationUs = TimeUs(duration.seconds * 1_000_000)

                // Dispatch to store
                self.session.dispatch(.setProjectMusic(
                    assetRef: .imported(assetId: mediaRef.assetId),
                    sourceDurationUs: durationUs
                ))

                logger.info("[Music] Imported: \(storageFilename), duration=\(durationUs)us")
            } catch {
                // Cleanup: remove temp file
                try? FileManager.default.removeItem(at: tempURL)
                // Cleanup: remove persisted file + unregister if persist succeeded but later step failed
                if let ref = persistedMediaRef {
                    try? await self.session.mediaWriter.deleteMediaFile(ref)
                    self.session.unregisterAssetBookkeeping(ref.assetId)
                }
                logger.error("[Music] Import failed: \(error)")
            }
        }
    }
}
