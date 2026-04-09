import Foundation

// MARK: - Saved Project Record

/// A persisted project on disk. File format: `<draft.id>.json` contains this struct.
/// Identity: `id == draft.id` — no separate id field.
struct SavedProjectRecord: Codable, Identifiable {
    var id: UUID { draft.id }
    var savedAt: Date
    var draft: ProjectDraft
}
