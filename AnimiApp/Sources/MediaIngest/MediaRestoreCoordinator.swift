import Foundation
import UIKit

// MARK: - Media Restore Coordinator

/// Restores persisted media from SceneMediaSlot to UserMediaRuntimeService.
/// Replaces MediaRestoreHelper with the same contract but using unified slots.
///
/// Phase 1 Contract:
/// - Any persisted media that cannot be restored MUST mark the block as failed.
/// - No silent `continue` on restore failure.
/// - Every slot must either succeed or fail explicitly.
public enum MediaRestoreCoordinator {

    // MARK: - Restore

    /// Restores media slots to the runtime service.
    ///
    /// - Parameters:
    ///   - slots: Media slots from SceneState (blockId -> SceneMediaSlot).
    ///   - service: UserMediaService to apply media to.
    ///   - projectStore: Project store for URL resolution.
    /// - Returns: Number of successfully restored media items.
    @MainActor
    @discardableResult
    public static func restore(
        slots: [String: SceneMediaSlot]?,
        to service: UserMediaService,
        projectStore: ProjectStore = .shared
    ) -> Int {
        guard let slots else { return 0 }

        var restored = 0

        for (blockId, slot) in slots {
            // Validate media ref kind
            guard slot.mediaRef.kind == .file else {
                service.markRestoreFailed(blockId: blockId, reason: "unsupported media kind: \(slot.mediaRef.kind)")
                continue
            }

            // Resolve URL
            guard let url = try? projectStore.absoluteURL(for: slot.mediaRef) else {
                service.markRestoreFailed(blockId: blockId, reason: "failed to resolve URL for: \(slot.mediaRef.id)")
                continue
            }

            // Verify file exists
            guard FileManager.default.fileExists(atPath: url.path) else {
                service.markRestoreFailed(blockId: blockId, reason: "file not found: \(url.lastPathComponent)")
                continue
            }

            let presentOnReady = slot.visibility

            switch slot.mediaRef.mediaKind {
            case .photo:
                guard let image = UIImage(contentsOfFile: url.path) else {
                    service.markRestoreFailed(blockId: blockId, reason: "unreadable photo: \(url.lastPathComponent)")
                    continue
                }

                let success = service.setPhoto(blockId: blockId, image: image, presentOnReady: presentOnReady)
                if success { restored += 1 }

                #if DEBUG
                print("[MediaRestoreCoordinator] Restored photo for \(blockId): presentOnReady=\(presentOnReady), \(success ? "success" : "failed")")
                #endif

            case .video:
                let success = service.setVideo(
                    blockId: blockId,
                    url: url,
                    ownership: .persistent,
                    presentOnReady: presentOnReady,
                    emitSelectionPersistence: false,
                    pendingPersistedSelection: slot.videoWindow
                )
                if success { restored += 1 }

                #if DEBUG
                print("[MediaRestoreCoordinator] Restored video for \(blockId): presentOnReady=\(presentOnReady), \(success ? "success" : "failed")")
                #endif
            }
        }

        return restored
    }
}
