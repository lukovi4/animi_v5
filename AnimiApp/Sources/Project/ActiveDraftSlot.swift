import Foundation

// MARK: - Editor Entry Context

/// Describes how the editor was entered — determines save/discard behavior.
enum EditorEntryContext: Codable, Equatable {
    case newProject(origin: ProjectOrigin)
    case openSavedProject(projectId: UUID)
}

// MARK: - Active Draft Slot

/// Single in-flight editor session persisted to `active_draft.json`.
/// Enables crash recovery and background-save lifecycle.
struct ActiveDraftSlot: Codable {
    var entryContext: EditorEntryContext
    var linkedSavedProjectId: UUID?
    var draft: ProjectDraft
}
