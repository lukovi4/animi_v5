import Foundation
import CryptoKit

// MARK: - Project Store Errors

/// Errors that can occur during project store operations.
public enum ProjectStoreError: Error, LocalizedError {
    case directoryCreationFailed(Error)
    case indexReadFailed(Error)
    case indexWriteFailed(Error)
    case projectReadFailed(UUID, Error)
    case projectWriteFailed(UUID, Error)
    case projectNotFound(UUID)
    case activeDraftWriteFailed(Error)
    case activeDraftReadFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let error):
            return "Failed to create projects directory: \(error.localizedDescription)"
        case .indexReadFailed(let error):
            return "Failed to read projects index: \(error.localizedDescription)"
        case .indexWriteFailed(let error):
            return "Failed to write projects index: \(error.localizedDescription)"
        case .projectReadFailed(let id, let error):
            return "Failed to read project \(id): \(error.localizedDescription)"
        case .projectWriteFailed(let id, let error):
            return "Failed to write project \(id): \(error.localizedDescription)"
        case .projectNotFound(let id):
            return "Project not found: \(id)"
        case .activeDraftWriteFailed(let error):
            return "Failed to write active draft: \(error.localizedDescription)"
        case .activeDraftReadFailed(let error):
            return "Failed to read active draft: \(error.localizedDescription)"
        }
    }
}

// MARK: - Saved Projects Index

/// Index file mapping projectId → entry metadata.
struct SavedProjectsIndex: Codable {
    var projects: [UUID: SavedProjectIndexEntry]
    init(projects: [UUID: SavedProjectIndexEntry] = [:]) {
        self.projects = projects
    }
}

/// Metadata entry in the saved projects index.
struct SavedProjectIndexEntry: Codable {
    var projectId: UUID
    var origin: ProjectOrigin
    var title: String?
    var savedAt: Date
}

// MARK: - Project Store

/// Thin shim over `FileProjectPersistenceStore` + `FileProjectMediaStore`.
///
/// `.shared` remains only for export/player/media composition-engine-level code
/// that is explicitly deferred to PR 5 (`TimelineCompositionEngine`, `VideoExporter`,
/// `ExportMediaSnapshot`). All feature/session/routing code goes through `ProjectStorageActor`.
///
/// File structure:
/// ```
/// Application Support/AnimiProjects/
/// ├── index.json                    # SavedProjectsIndex (projectId → entry)
/// ├── active_draft.json             # ActiveDraftSlot (current editor session)
/// ├── <projectId>.json              # SavedProjectRecord
/// └── Media/
///     ├── Background/
///     │   └── <uuid>.jpg
///     └── UserMedia/
///         └── <uuid>.jpg
/// ```
public final class ProjectStore: @unchecked Sendable, ProjectMediaLocator {

    // MARK: - Singleton (PR 5 will remove — only for export/player/media code)

    public static let shared = ProjectStore()

    // MARK: - Backing Stores

    let persistence: FileProjectPersistenceStore
    let media: FileProjectMediaStore

    // MARK: - Initialization

    public init(fileManager: FileManager = .default, rootDirectoryURL: URL? = nil) {
        self.persistence = FileProjectPersistenceStore(fileManager: fileManager, rootDirectoryURL: rootDirectoryURL)
        self.media = FileProjectMediaStore(fileManager: fileManager, rootDirectoryURL: rootDirectoryURL)
    }

    // MARK: - Directory Helpers (delegated)

    public func projectsDirectoryURL() throws -> URL {
        try persistence.projectsDirectoryURL()
    }

    public func backgroundMediaDirectoryURL() throws -> URL {
        try media.backgroundMediaDirectoryURL()
    }

    public func userMediaDirectoryURL() throws -> URL {
        try media.userMediaDirectoryURL()
    }

    public func ensureDirectoriesExist() throws {
        try persistence.ensureDirectoriesExist()
    }

    // MARK: - Active Draft Slot API (delegated)

    func saveActiveDraft(_ slot: ActiveDraftSlot) throws {
        try persistence.saveActiveDraft(slot)
    }

    func loadActiveDraft() -> ActiveDraftSlot? {
        persistence.loadActiveDraft()
    }

    public func deleteActiveDraft() throws {
        try persistence.deleteActiveDraft()
    }

    public func hasActiveDraft() -> Bool {
        persistence.hasActiveDraft()
    }

    // MARK: - Saved Projects API (delegated)

    func materializeSavedProject(_ slot: ActiveDraftSlot) throws -> ActiveDraftSlot {
        try persistence.materializeSavedProject(slot)
    }

    func loadSavedProject(projectId: UUID) -> SavedProjectRecord? {
        persistence.loadSavedProject(projectId: projectId)
    }

    public func deleteSavedProject(projectId: UUID) throws {
        try persistence.deleteSavedProject(projectId: projectId)
    }

    func allSavedProjectEntries() -> [SavedProjectIndexEntry] {
        persistence.allSavedProjectEntries()
    }

    // MARK: - Media File API (delegated)

    public func saveBackgroundImage(from preparedFileURL: URL) throws -> (MediaRef, URL) {
        try media.saveBackgroundImage(from: preparedFileURL)
    }

    public func absoluteURL(for mediaRef: MediaRef) throws -> URL {
        try media.absoluteURL(for: mediaRef)
    }

    public func deleteMediaFile(_ mediaRef: MediaRef) throws {
        try media.deleteMediaFile(mediaRef)
    }

    // MARK: - Garbage Collection (delegated)

    public func collectOrphanMediaFiles() async {
        await media.collectOrphanMediaFiles(persistence: persistence)
    }

    // MARK: - Cache Management

    public func clearCache() {
        persistence.clearCache()
    }
}
