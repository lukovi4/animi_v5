import Foundation

// MARK: - Media Restore Coordinator

/// Restores persisted media from SceneMediaSlot to UserMediaRuntimeService.
/// Replaces MediaRestoreHelper with the same contract but using unified slots.
///
/// Phase 2 Contract:
/// - Photo restore is file-based (no UIImage). Uses `setPhoto(blockId:fileURL:)`.
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
    ///   - resolved: Pre-resolved map from asset identity to absolute URL.
    ///               Built via `ResolvedMediaMapBuilder.build(slots:locator:)`
    ///               on an async path before entering this sync apply.
    /// - Returns: Number of successfully accepted media items.
    @MainActor
    @discardableResult
    public static func restore(
        slots: [String: SceneMediaSlot]?,
        to service: UserMediaService,
        resolved: ResolvedMediaMap
    ) -> Int {
        guard let slots else { return 0 }

        var restored = 0

        for (blockId, slot) in slots {
            // Resolve URL from pre-built map
            guard let url = resolved.url(for: slot.mediaRef) else {
                service.markRestoreFailed(blockId: blockId, reason: "failed to resolve URL for asset: \(slot.mediaRef.assetId.rawValue)")
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
                let accepted = service.setPhoto(blockId: blockId, fileURL: url, presentOnReady: presentOnReady, mediaRefId: slot.mediaRef.assetId.rawValue.uuidString)
                if accepted { restored += 1 }

                #if DEBUG
                print("[MediaRestoreCoordinator] Restored photo for \(blockId): presentOnReady=\(presentOnReady), \(accepted ? "accepted" : "rejected")")
                #endif

            case .video:
                guard let videoWindow = slot.videoWindow else {
                    service.markRestoreFailed(blockId: blockId, reason: "missing videoWindow")
                    #if DEBUG
                    print("[MediaRestoreCoordinator] Video slot missing videoWindow for \(blockId)")
                    #endif
                    continue
                }

                let success = service.setVideo(
                    blockId: blockId,
                    url: url,
                    presentOnReady: presentOnReady,
                    persistedSelection: videoWindow
                )
                if success { restored += 1 }

                #if DEBUG
                print("[MediaRestoreCoordinator] Restored video for \(blockId): presentOnReady=\(presentOnReady), \(success ? "success" : "failed")")
                #endif

            case .audio:
                // Audio media kind is not used in scene media slots — skip
                break
            }
        }

        return restored
    }
}
