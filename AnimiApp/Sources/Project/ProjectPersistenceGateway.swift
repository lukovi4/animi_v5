import Foundation

/// Protocol for project persistence operations.
/// Implemented by `FileProjectPersistenceStore`, consumed through `ProjectStorageActor`.
protocol ProjectPersistenceGateway: Sendable {
    func saveActiveDraft(_ slot: ActiveDraftSlot) async throws
    func loadActiveDraft() async -> ActiveDraftSlot?
    func deleteActiveDraft() async throws
    func hasActiveDraft() async -> Bool
    func materializeSavedProject(_ slot: ActiveDraftSlot) async throws -> ActiveDraftSlot
    func loadSavedProject(projectId: UUID) async -> SavedProjectRecord?
    func deleteSavedProject(projectId: UUID) async throws
    func allSavedProjectSummaries() async -> [SavedProjectSummary]
}
