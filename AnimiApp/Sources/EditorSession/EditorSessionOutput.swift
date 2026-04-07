import Foundation

/// Events emitted from session to UI layer.
enum EditorSessionOutput {
    case bootstrapSucceeded(BootstrappedEditor)
    case bootstrapFailed(String)
    case missingMediaDetected(MissingMediaSummary)
}

/// Result of requesting close — tells the UI whether to prompt or just pop.
enum EditorCloseAction {
    /// Dirty — show Save/Don't Save/Cancel alert.
    case needsUserDecision
    /// Clean — just pop the view controller.
    case safeToClose
}

/// Composite key for identifying a specific media slot that failed to restore.
struct MissingMediaSlotKey: Hashable, Sendable {
    let sceneInstanceId: UUID
    let blockId: String
}

/// Summary of media that failed to restore, keyed by (sceneInstanceId, blockId).
struct MissingMediaSummary: Equatable, Sendable {
    let failedSlots: Set<MissingMediaSlotKey>
    var hasFailedMedia: Bool { !failedSlots.isEmpty }

    func isBlockFailed(sceneInstanceId: UUID, blockId: String) -> Bool {
        failedSlots.contains(MissingMediaSlotKey(sceneInstanceId: sceneInstanceId, blockId: blockId))
    }
}
