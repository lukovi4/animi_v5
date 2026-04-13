import Foundation

/// Duplicates an existing saved project by loading it, duplicating all assets,
/// and materializing a new independent saved project.
///
/// Works on top of the existing storage foundation (PR5 `duplicateAssets`).
struct ProjectDuplicationUseCase {

    private let persistence: any ProjectPersistenceGateway
    private let mediaWriter: any ProjectMediaWriteGateway

    init(persistence: any ProjectPersistenceGateway, mediaWriter: any ProjectMediaWriteGateway) {
        self.persistence = persistence
        self.mediaWriter = mediaWriter
    }

    /// Duplicates a saved project and returns the new project's id.
    ///
    /// - Parameter sourceProjectId: The project to duplicate.
    /// - Returns: The UUID of the newly created duplicate project.
    /// - Throws: If the source project cannot be loaded or duplication fails.
    func execute(sourceProjectId: UUID) async throws -> UUID {
        // 1. Load source project
        guard let record = await persistence.loadSavedProject(projectId: sourceProjectId) else {
            throw ProjectDuplicationError.sourceNotFound(sourceProjectId)
        }

        // 2. Duplicate assets — returns a new draft with fresh id and independent media
        var duplicatedDraft = try await mediaWriter.duplicateAssets(inDraft: record.draft)

        // 3. Rewrite origin to .duplicate
        duplicatedDraft.origin = .duplicate(sourceProjectId: sourceProjectId)

        // 4. Preserve the source project's name if present
        duplicatedDraft.name = record.draft.name

        // 5. Materialize as a new saved project via the existing persistence path
        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: duplicatedDraft.origin),
            linkedSavedProjectId: nil,
            draft: duplicatedDraft
        )
        let materializedSlot = try await persistence.materializeSavedProject(slot)

        return materializedSlot.draft.id
    }
}

// MARK: - Errors

enum ProjectDuplicationError: Error, LocalizedError {
    case sourceNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let id):
            return "Source project \(id) not found"
        }
    }
}
