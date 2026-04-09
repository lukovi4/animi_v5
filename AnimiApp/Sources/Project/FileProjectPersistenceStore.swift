import Foundation

/// Thin file-backed persistence implementation.
/// Extracted from `ProjectStore` — owns all file I/O for drafts, records, and index.
/// No GC, no migration, no purge.
final class FileProjectPersistenceStore: @unchecked Sendable {

    // MARK: - Constants

    static let projectsDirectoryName = "AnimiProjects"
    static let indexFileName = "index.json"
    static let activeDraftFileName = "active_draft.json"
    static let mediaDirectoryName = "Media"
    static let backgroundMediaDirectoryName = "Background"
    static let userMediaDirectoryName = "UserMedia"

    // MARK: - Properties

    let fileManager: FileManager
    private let rootDirectoryOverride: URL?
    private var cachedIndex: SavedProjectsIndex?

    /// Set to true after an incompatible index wipe. Actor reads and clears this to schedule GC.
    var didWipeIncompatibleData = false

    // MARK: - Initialization

    init(fileManager: FileManager = .default, rootDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootDirectoryOverride = rootDirectoryURL
    }

    // MARK: - Directory Helpers

    func projectsDirectoryURL() throws -> URL {
        if let override = rootDirectoryOverride {
            return override
        }
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent(Self.projectsDirectoryName)
    }

    func backgroundMediaDirectoryURL() throws -> URL {
        let projectsDir = try projectsDirectoryURL()
        return projectsDir
            .appendingPathComponent(Self.mediaDirectoryName)
            .appendingPathComponent(Self.backgroundMediaDirectoryName)
    }

    func userMediaDirectoryURL() throws -> URL {
        let projectsDir = try projectsDirectoryURL()
        return projectsDir
            .appendingPathComponent(Self.mediaDirectoryName)
            .appendingPathComponent(Self.userMediaDirectoryName)
    }

    func ensureDirectoriesExist() throws {
        let projectsDir = try projectsDirectoryURL()
        let backgroundDir = try backgroundMediaDirectoryURL()
        let userMediaDir = try userMediaDirectoryURL()

        do {
            try fileManager.createDirectory(at: projectsDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: backgroundDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: userMediaDir, withIntermediateDirectories: true)
        } catch {
            throw ProjectStoreError.directoryCreationFailed(error)
        }
    }

    // MARK: - Index Management

    private func indexURL() throws -> URL {
        try projectsDirectoryURL().appendingPathComponent(Self.indexFileName)
    }

    func loadSavedIndex() throws -> SavedProjectsIndex {
        if let cached = cachedIndex {
            return cached
        }

        let url = try indexURL()

        guard fileManager.fileExists(atPath: url.path) else {
            let empty = SavedProjectsIndex()
            cachedIndex = empty
            return empty
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(SavedProjectsIndex.self, from: data)
            cachedIndex = index
            return index
        } catch {
            #if DEBUG
            print("[FileProjectPersistenceStore] Incompatible index format, wiping: \(error.localizedDescription)")
            #endif
            try? fileManager.removeItem(at: url)
            wipeOrphanProjectFiles()
            didWipeIncompatibleData = true
            let empty = SavedProjectsIndex()
            cachedIndex = empty
            return empty
        }
    }

    func saveSavedIndex(_ index: SavedProjectsIndex) throws {
        try ensureDirectoriesExist()

        let url = try indexURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(index)
            try data.write(to: url, options: .atomic)
            cachedIndex = index
        } catch {
            throw ProjectStoreError.indexWriteFailed(error)
        }
    }

    // MARK: - Project File URL

    func projectURL(for projectId: UUID) throws -> URL {
        try projectsDirectoryURL().appendingPathComponent("\(projectId.uuidString).json")
    }

    // MARK: - Active Draft Slot API

    private func activeDraftURL() throws -> URL {
        try projectsDirectoryURL().appendingPathComponent(Self.activeDraftFileName)
    }

    func saveActiveDraft(_ slot: ActiveDraftSlot) throws {
        try ensureDirectoriesExist()

        let url = try activeDraftURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(slot)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProjectStoreError.activeDraftWriteFailed(error)
        }
    }

    func loadActiveDraft() -> ActiveDraftSlot? {
        guard let url = try? activeDraftURL(),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let slot = try decoder.decode(ActiveDraftSlot.self, from: data)

            guard slot.draft.isValid else {
                #if DEBUG
                print("[FileProjectPersistenceStore] Active draft has invalid schema, ignoring")
                #endif
                try? deleteActiveDraft()
                return nil
            }

            return slot
        } catch {
            #if DEBUG
            print("[FileProjectPersistenceStore] Failed to load active draft: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    func deleteActiveDraft() throws {
        let url = try activeDraftURL()
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func hasActiveDraft() -> Bool {
        guard let url = try? activeDraftURL() else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Saved Projects API

    /// Materializes a saved project from the active draft slot.
    /// Value-in/value-out (no inout) — safe for async contexts.
    func materializeSavedProject(_ slot: ActiveDraftSlot) throws -> ActiveDraftSlot {
        var mutSlot = slot
        let projectId = mutSlot.linkedSavedProjectId ?? mutSlot.draft.id

        let record = SavedProjectRecord(
            savedAt: Date(),
            draft: mutSlot.draft
        )

        try saveSavedProjectRecord(record)

        var index = try loadSavedIndex()
        index.projects[record.id] = SavedProjectIndexEntry(
            projectId: record.id,
            origin: mutSlot.draft.origin,
            title: mutSlot.draft.name,
            savedAt: record.savedAt
        )
        try saveSavedIndex(index)

        mutSlot.linkedSavedProjectId = record.id
        _ = projectId // suppress unused warning

        return mutSlot
    }

    func loadSavedProject(projectId: UUID) -> SavedProjectRecord? {
        guard let url = try? projectURL(for: projectId),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(SavedProjectRecord.self, from: data)

            guard record.draft.isValid else {
                #if DEBUG
                print("[FileProjectPersistenceStore] Saved project \(projectId) has invalid schema, skipping")
                #endif
                return nil
            }

            return record
        } catch {
            #if DEBUG
            print("[FileProjectPersistenceStore] Failed to load saved project \(projectId): \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    func deleteSavedProject(projectId: UUID) throws {
        let url = try projectURL(for: projectId)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        var index = try loadSavedIndex()
        index.projects.removeValue(forKey: projectId)
        try saveSavedIndex(index)
    }

    /// Returns all saved project index entries, sorted by savedAt descending.
    /// Defensively filters out entries whose project file cannot be loaded.
    func allSavedProjectEntries() -> [SavedProjectIndexEntry] {
        guard let index = try? loadSavedIndex() else { return [] }

        let validEntries = index.projects.values.filter { entry in
            loadSavedProject(projectId: entry.projectId) != nil
        }

        return validEntries.sorted {
            if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
            return $0.projectId.uuidString > $1.projectId.uuidString
        }
    }

    /// Builds `SavedProjectSummary` from index + records.
    func allSavedProjectSummaries() -> [SavedProjectSummary] {
        guard let index = try? loadSavedIndex() else { return [] }

        var summaries: [SavedProjectSummary] = []
        for (_, entry) in index.projects {
            guard let record = loadSavedProject(projectId: entry.projectId) else { continue }
            let title = record.draft.name ?? record.draft.origin.displayTitle
            summaries.append(SavedProjectSummary(
                projectId: entry.projectId,
                savedAt: record.savedAt,
                title: title,
                origin: record.draft.origin,
                previewURL: nil
            ))
        }

        return summaries.sorted {
            if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
            return $0.projectId.uuidString > $1.projectId.uuidString
        }
    }

    // MARK: - Internal IO Helpers

    func saveSavedProjectRecord(_ record: SavedProjectRecord) throws {
        try ensureDirectoriesExist()

        let url = try projectURL(for: record.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProjectStoreError.projectWriteFailed(record.id, error)
        }
    }

    // MARK: - Cache Management

    func clearCache() {
        cachedIndex = nil
    }

    // MARK: - Incompatible Data Cleanup

    private func wipeOrphanProjectFiles() {
        guard let dir = try? projectsDirectoryURL(),
              fileManager.fileExists(atPath: dir.path) else { return }
        let contents = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in contents {
            let name = file.lastPathComponent
            guard name.hasSuffix(".json"),
                  name != Self.indexFileName,
                  name != Self.activeDraftFileName else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}
