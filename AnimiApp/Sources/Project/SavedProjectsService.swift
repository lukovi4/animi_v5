import Foundation

/// Service layer for My Projects listing, deletion, and duplication.
/// Takes protocol dependencies — testable without concrete actor.
@MainActor
final class SavedProjectsService {
    private let persistence: any ProjectPersistenceGateway
    private let duplication: ProjectDuplicationUseCase?

    init(
        persistence: any ProjectPersistenceGateway,
        duplication: ProjectDuplicationUseCase? = nil
    ) {
        self.persistence = persistence
        self.duplication = duplication
    }

    func allSummaries() async -> [SavedProjectSummary] {
        await persistence.allSavedProjectSummaries()
    }

    func deleteProject(projectId: UUID) async throws {
        try await persistence.deleteSavedProject(projectId: projectId)
    }

    /// Duplicates a saved project and returns the new project's id.
    func duplicateProject(projectId: UUID) async throws -> UUID {
        guard let duplication else {
            throw SavedProjectsServiceError.duplicationNotConfigured
        }
        return try await duplication.execute(sourceProjectId: projectId)
    }
}

enum SavedProjectsServiceError: Error, LocalizedError, Equatable {
    case duplicationNotConfigured

    var errorDescription: String? {
        switch self {
        case .duplicationNotConfigured:
            return "Project duplication is not available"
        }
    }
}
