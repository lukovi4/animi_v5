import Foundation

// MARK: - Draft Entry Context

/// Describes how the draft was entered — determines save/discard behavior.
/// Persisted as part of `ActiveDraftSlot` in `active_draft.json`.
enum DraftEntryContext: Codable, Equatable {
    case newProject(origin: ProjectOrigin)
    case openSavedProject(projectId: UUID)

    // Backward compatibility: existing `active_draft.json` files written
    // under the previous type name decode without migration because Swift
    // synthesised Codable encodes enum cases, not the type name.
}

// MARK: - Active Draft Slot

/// Single in-flight editor session persisted to `active_draft.json`.
/// Enables crash recovery and background-save lifecycle.
struct ActiveDraftSlot: Codable {
    var entryContext: DraftEntryContext
    var linkedSavedProjectId: UUID?
    var draft: ProjectDraft
}
