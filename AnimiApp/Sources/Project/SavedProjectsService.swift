import Foundation

/// Service layer for My Projects listing and deletion.
/// Takes protocol dependency — testable without concrete actor.
@MainActor
final class SavedProjectsService {
    private let persistence: any ProjectPersistenceGateway

    init(persistence: any ProjectPersistenceGateway) {
        self.persistence = persistence
    }

    func allSummaries() async -> [SavedProjectSummary] {
        await persistence.allSavedProjectSummaries()
    }

    func deleteProject(projectId: UUID) async throws {
        try await persistence.deleteSavedProject(projectId: projectId)
    }
}
