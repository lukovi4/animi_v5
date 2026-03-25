import Foundation
import UIKit

// MARK: - Media Restore Helper

/// Helper for restoring persisted media assignments to UserMediaService.
/// Consolidates photo+video restore logic used by both PlayerViewController and SceneInstanceRuntime.
///
/// Phase 1 Contract:
/// - Any persisted media assignment that cannot be restored MUST mark the block as failed.
/// - No silent `continue` on restore failure - every assignment must either succeed or fail explicitly.
/// - Failures before entering `setPhoto`/`setVideo` are marked via `markRestoreFailed`.
/// - Failures inside `setPhoto`/`setVideo` are marked by those APIs themselves.
///
/// Usage:
/// ```swift
/// MediaRestoreHelper.restore(
///     assignments: state.mediaAssignments,
///     userMediaPresent: state.userMediaPresent,
///     to: userMediaService
/// )
/// ```
public enum MediaRestoreHelper {

    // MARK: - Restore

    /// Restores media assignments to UserMediaService.
    ///
    /// Phase 1 Contract: Every assignment either succeeds or marks the block as failed.
    /// No silent skips - all failures are recorded in readiness state.
    ///
    /// - Parameters:
    ///   - assignments: Media assignments from SceneState (blockId -> MediaRef).
    ///   - userMediaPresent: Optional overrides for userMediaPresent (for presentOnReady).
    ///   - videoSelections: Optional persisted video selections (trim/offset/audio params).
    ///   - service: UserMediaService to apply media to.
    /// - Returns: Number of successfully restored media items.
    @MainActor
    @discardableResult
    public static func restore(
        assignments: [String: MediaRef]?,
        userMediaPresent: [String: Bool]?,
        videoSelections: [String: PersistedVideoSelection]? = nil,
        to service: UserMediaService
    ) -> Int {
        guard let assignments = assignments else { return 0 }

        var restored = 0

        for (blockId, mediaRef) in assignments {
            // Check media ref kind is supported
            guard mediaRef.kind == .file else {
                service.markRestoreFailed(blockId: blockId, reason: "unsupported media kind: \(mediaRef.kind)")
                continue
            }

            // Resolve URL from relative path via ProjectStore
            guard let url = try? ProjectStore.shared.absoluteURL(for: mediaRef) else {
                service.markRestoreFailed(blockId: blockId, reason: "failed to resolve URL for: \(mediaRef.id)")
                continue
            }

            // Verify file exists
            guard FileManager.default.fileExists(atPath: url.path) else {
                service.markRestoreFailed(blockId: blockId, reason: "file not found: \(url.lastPathComponent)")
                continue
            }

            let presentOnReady = userMediaPresent?[blockId] ?? true

            switch mediaRef.mediaKind {
            case .photo:
                // Photo: load image and apply
                guard let image = UIImage(contentsOfFile: url.path) else {
                    service.markRestoreFailed(blockId: blockId, reason: "unreadable photo: \(url.lastPathComponent)")
                    continue
                }

                // setPhoto marks its own failure if it returns false
                let success = service.setPhoto(blockId: blockId, image: image, presentOnReady: presentOnReady)
                if success { restored += 1 }

                #if DEBUG
                print("[MediaRestoreHelper] Restored photo for \(blockId): presentOnReady=\(presentOnReady), \(success ? "success" : "failed")")
                #endif

            case .video:
                // Video: setVideo marks its own failure if it returns false.
                // pendingPersistedSelection is applied inside the async poster task AFTER mediaState
                // is written — calling applyPersistedVideoSelection synchronously here would be a no-op
                // because mediaState[blockId] is not yet populated.
                let success = service.setVideo(
                    blockId: blockId,
                    url: url,
                    ownership: .persistent,
                    presentOnReady: presentOnReady,
                    emitSelectionPersistence: false,
                    pendingPersistedSelection: videoSelections?[blockId]
                )
                if success {
                    restored += 1
                }

                #if DEBUG
                print("[MediaRestoreHelper] Restored video for \(blockId): presentOnReady=\(presentOnReady), \(success ? "success" : "failed")")
                #endif
            }
        }

        return restored
    }
}
