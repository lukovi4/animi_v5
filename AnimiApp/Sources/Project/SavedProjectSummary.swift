import Foundation

/// Listing metadata for saved projects — derived at read time, not persisted.
struct SavedProjectSummary: Identifiable, Sendable {
    let projectId: UUID
    let savedAt: Date
    let title: String
    let origin: ProjectOrigin
    let previewURL: URL?

    var id: UUID { projectId }
}
