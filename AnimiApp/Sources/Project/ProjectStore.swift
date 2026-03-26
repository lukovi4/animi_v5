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
    var sourceTemplateId: String
    var savedAt: Date
}

// MARK: - Legacy Index (for migration)

/// Old index format: templateId → projectId string.
private struct LegacyProjectsIndex: Codable {
    var byTemplateId: [String: String]
}

// MARK: - Project Store

/// Manages project persistence in Application Support.
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
public final class ProjectStore {

    // MARK: - Singleton

    public static let shared = ProjectStore()

    // MARK: - Constants

    private static let projectsDirectoryName = "AnimiProjects"
    private static let indexFileName = "index.json"
    private static let activeDraftFileName = "active_draft.json"
    private static let mediaDirectoryName = "Media"
    private static let backgroundMediaDirectoryName = "Background"
    private static let userMediaDirectoryName = "UserMedia"

    // MARK: - Properties

    private let fileManager: FileManager
    private var cachedIndex: SavedProjectsIndex?

    /// Flag to prevent concurrent GC runs
    private var isGCInProgress = false

    /// Tracks whether one-time migration has been attempted this session
    private var migrationAttempted = false

    /// Tracks whether one-time schema purge has been performed this session
    private var purgeAttempted = false

    // MARK: - Initialization

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Directory Helpers

    /// Returns the base projects directory (Application Support/AnimiProjects/).
    public func projectsDirectoryURL() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent(Self.projectsDirectoryName)
    }

    /// Returns the media directory for background images.
    public func backgroundMediaDirectoryURL() throws -> URL {
        let projectsDir = try projectsDirectoryURL()
        return projectsDir
            .appendingPathComponent(Self.mediaDirectoryName)
            .appendingPathComponent(Self.backgroundMediaDirectoryName)
    }

    /// Returns the media directory for user media (scene instance photos/videos).
    public func userMediaDirectoryURL() throws -> URL {
        let projectsDir = try projectsDirectoryURL()
        return projectsDir
            .appendingPathComponent(Self.mediaDirectoryName)
            .appendingPathComponent(Self.userMediaDirectoryName)
    }

    /// Ensures all required directories exist.
    public func ensureDirectoriesExist() throws {
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

    /// Returns the URL for the index file.
    private func indexURL() throws -> URL {
        try projectsDirectoryURL().appendingPathComponent(Self.indexFileName)
    }

    /// Loads the saved projects index, migrating from legacy format if needed.
    private func loadSavedIndex() throws -> SavedProjectsIndex {
        if let cached = cachedIndex {
            return cached
        }

        // Run one-time migration if needed
        if !migrationAttempted {
            migrationAttempted = true
            try migrateIfNeeded()
            if let cached = cachedIndex {
                return cached
            }
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
            throw ProjectStoreError.indexReadFailed(error)
        }
    }

    /// Saves the saved projects index to disk.
    private func saveSavedIndex(_ index: SavedProjectsIndex) throws {
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

    /// Returns the URL for a project file.
    private func projectURL(for projectId: UUID) throws -> URL {
        try projectsDirectoryURL().appendingPathComponent("\(projectId.uuidString).json")
    }

    // MARK: - Active Draft Slot API

    /// Returns the URL for the active draft file.
    private func activeDraftURL() throws -> URL {
        try projectsDirectoryURL().appendingPathComponent(Self.activeDraftFileName)
    }

    /// Saves the active draft slot to disk.
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

    /// Loads the active draft slot from disk.
    /// Returns nil if no active draft exists or if it cannot be decoded.
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

            // Validate schema version
            guard slot.draft.isValid else {
                #if DEBUG
                print("[ProjectStore] Active draft has invalid schema, ignoring")
                #endif
                try? deleteActiveDraft()
                return nil
            }

            return slot
        } catch {
            #if DEBUG
            print("[ProjectStore] Failed to load active draft: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    /// Deletes the active draft file.
    public func deleteActiveDraft() throws {
        let url = try activeDraftURL()
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        // Trigger async GC
        triggerAsyncGC()
    }

    /// Checks whether an active draft exists on disk.
    public func hasActiveDraft() -> Bool {
        guard let url = try? activeDraftURL() else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Saved Projects API

    /// Materializes a saved project from the active draft slot.
    /// 1. Determines projectId (linkedSavedProjectId or draft.id)
    /// 2. Creates/overwrites SavedProjectRecord on disk
    /// 3. Updates index
    /// 4. Sets slot.linkedSavedProjectId
    func materializeSavedProject(from slot: inout ActiveDraftSlot) throws {
        let projectId = slot.linkedSavedProjectId ?? slot.draft.id

        let record = SavedProjectRecord(
            sourceTemplateId: slot.sourceTemplateId,
            savedAt: Date(),
            draft: slot.draft
        )

        // Ensure draft.id matches projectId for identity invariant
        if slot.draft.id != projectId {
            // This shouldn't happen, but defensive: use draft.id as canonical
        }

        try saveSavedProjectRecord(record)

        // Update index
        var index = try loadSavedIndex()
        index.projects[record.id] = SavedProjectIndexEntry(
            projectId: record.id,
            sourceTemplateId: slot.sourceTemplateId,
            savedAt: record.savedAt
        )
        try saveSavedIndex(index)

        slot.linkedSavedProjectId = record.id

        // Trigger async GC
        triggerAsyncGC()
    }

    /// Loads a saved project record by projectId.
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
                print("[ProjectStore] Saved project \(projectId) has invalid schema, skipping")
                #endif
                return nil
            }

            return record
        } catch {
            #if DEBUG
            print("[ProjectStore] Failed to load saved project \(projectId): \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    /// Deletes a saved project and removes it from the index.
    public func deleteSavedProject(projectId: UUID) throws {
        // Remove project file
        let url = try projectURL(for: projectId)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        // Update index
        var index = try loadSavedIndex()
        index.projects.removeValue(forKey: projectId)
        try saveSavedIndex(index)

        // Trigger async GC
        triggerAsyncGC()
    }

    /// Returns all saved project index entries, sorted by savedAt descending.
    /// Runs one-time schema purge on first call, then defensively filters out
    /// any entries whose project file cannot be loaded (incompatible schema, missing file, etc.).
    func allSavedProjectEntries() -> [SavedProjectIndexEntry] {
        // One-time purge: physically remove incompatible projects and rewrite index
        if !purgeAttempted {
            purgeAttempted = true
            purgeIncompatibleSavedProjects()
        }

        guard let index = try? loadSavedIndex() else { return [] }

        // Defensive filter: even after purge, only return entries that can actually be loaded
        let validEntries = index.projects.values.filter { entry in
            loadSavedProject(projectId: entry.projectId) != nil
        }

        return validEntries.sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: - Internal IO Helpers

    /// Saves a SavedProjectRecord to disk as `<record.id>.json`.
    private func saveSavedProjectRecord(_ record: SavedProjectRecord) throws {
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

    // MARK: - One-Time Migration (Legacy → SavedProjectsIndex)

    /// Migrates from old `ProjectsIndex { byTemplateId }` format to new `SavedProjectsIndex`.
    /// Also converts raw `ProjectDraft` files to `SavedProjectRecord` wrapper format.
    private func migrateIfNeeded() throws {
        let url = try indexURL()

        guard fileManager.fileExists(atPath: url.path) else {
            // No index at all — clean start
            return
        }

        // Try to decode as new format first
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let _ = try? decoder.decode(SavedProjectsIndex.self, from: data) {
            // Already new format
            return
        }

        // Try to decode as legacy format
        guard let legacyIndex = try? JSONDecoder().decode(LegacyProjectsIndex.self, from: data) else {
            // Cannot decode either format — remove corrupted index, clean start
            #if DEBUG
            print("[ProjectStore] Cannot decode index as old or new format, starting fresh")
            #endif
            try? fileManager.removeItem(at: url)
            return
        }

        #if DEBUG
        print("[ProjectStore] Migrating legacy index with \(legacyIndex.byTemplateId.count) entries")
        #endif

        // Migrate each project
        var newIndex = SavedProjectsIndex()
        for (templateId, projectIdString) in legacyIndex.byTemplateId {
            guard let projectId = UUID(uuidString: projectIdString) else { continue }

            // Load raw ProjectDraft from legacy file
            guard let draft = loadLegacyProjectDraft(projectId: projectId) else {
                #if DEBUG
                print("[ProjectStore] Migration: skipping project \(projectId) (cannot load/invalid schema)")
                #endif
                continue
            }

            // Wrap in SavedProjectRecord
            let record = SavedProjectRecord(
                sourceTemplateId: templateId,
                savedAt: draft.updatedAt,
                draft: draft
            )

            // Overwrite file in new format
            do {
                try saveSavedProjectRecord(record)
            } catch {
                #if DEBUG
                print("[ProjectStore] Migration: failed to save record for \(projectId): \(error)")
                #endif
                continue
            }

            newIndex.projects[projectId] = SavedProjectIndexEntry(
                projectId: projectId,
                sourceTemplateId: templateId,
                savedAt: draft.updatedAt
            )
        }

        // Save new index
        try saveSavedIndex(newIndex)

        // Clean up legacy crash files
        cleanupLegacyCrashFiles()

        #if DEBUG
        print("[ProjectStore] Migration complete: \(newIndex.projects.count) projects migrated")
        #endif
    }

    /// Loads a raw ProjectDraft from legacy file format (pre-SavedProjectRecord).
    private func loadLegacyProjectDraft(projectId: UUID) -> ProjectDraft? {
        guard let url = try? projectURL(for: projectId),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let draft = try decoder.decode(ProjectDraft.self, from: data)

            // Schema fallback: skip invalid drafts
            guard draft.isValid else { return nil }

            return draft
        } catch {
            return nil
        }
    }

    /// Removes legacy crash_*.json files after migration.
    private func cleanupLegacyCrashFiles() {
        guard let projectsDir = try? projectsDirectoryURL() else { return }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: projectsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for fileURL in contents where fileURL.lastPathComponent.hasPrefix("crash_") {
                try? fileManager.removeItem(at: fileURL)
            }
        } catch {
            #if DEBUG
            print("[ProjectStore] Failed to clean up legacy crash files: \(error)")
            #endif
        }
    }

    // MARK: - Media File API

    /// Saves an image to the background media directory.
    /// - Parameter imageData: JPEG image data
    /// - Returns: MediaRef with relative path
    public func saveBackgroundImage(_ imageData: Data) throws -> MediaRef {
        try ensureDirectoriesExist()

        let uuid = UUID().uuidString
        let filename = "\(uuid).jpg"
        let relativePath = "\(Self.mediaDirectoryName)/\(Self.backgroundMediaDirectoryName)/\(filename)"

        let mediaDir = try backgroundMediaDirectoryURL()
        let fileURL = mediaDir.appendingPathComponent(filename)

        try imageData.write(to: fileURL, options: .atomic)

        return MediaRef.file(relativePath, mediaKind: .photo)
    }

    /// Saves user video to the user media directory.
    /// Uses `FileManager.copyItem` instead of loading video into memory.
    public func saveUserVideo(
        from sourceURL: URL,
        sceneInstanceId: UUID,
        blockId: String
    ) throws -> MediaRef {
        try ensureDirectoriesExist()

        let uuid = UUID().uuidString
        let ext = sourceURL.pathExtension.lowercased()
        let filename = "\(sceneInstanceId.uuidString)_\(blockId)_\(uuid).\(ext)"
        let relativePath = "\(Self.mediaDirectoryName)/\(Self.userMediaDirectoryName)/\(filename)"

        let mediaDir = try userMediaDirectoryURL()
        let destURL = mediaDir.appendingPathComponent(filename)

        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destURL)

        return MediaRef.file(relativePath, mediaKind: .video)
    }

    /// Returns the absolute URL for a media reference.
    public func absoluteURL(for mediaRef: MediaRef) throws -> URL {
        let projectsDir = try projectsDirectoryURL()
        return projectsDir.appendingPathComponent(mediaRef.id)
    }

    /// Deletes a media file.
    public func deleteMediaFile(_ mediaRef: MediaRef) throws {
        let url = try absoluteURL(for: mediaRef)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Garbage Collection

    /// Triggers async GC (non-blocking).
    private func triggerAsyncGC() {
        Task.detached { [weak self] in
            await self?.collectOrphanMediaFiles()
        }
    }

    /// Collects and deletes orphan media files not referenced by any saved project or active draft.
    /// Scans both Media/Background/ and Media/UserMedia/.
    public func collectOrphanMediaFiles() async {
        guard !isGCInProgress else {
            #if DEBUG
            print("[ProjectStore] GC skipped - already in progress")
            #endif
            return
        }

        isGCInProgress = true
        defer { isGCInProgress = false }

        do {
            let referencedPaths = try collectAllReferencedMediaPaths()

            // GC Background media
            try gcDirectory(
                try backgroundMediaDirectoryURL(),
                subdirectory: "\(Self.mediaDirectoryName)/\(Self.backgroundMediaDirectoryName)",
                referencedPaths: referencedPaths
            )

            // GC UserMedia
            try gcDirectory(
                try userMediaDirectoryURL(),
                subdirectory: "\(Self.mediaDirectoryName)/\(Self.userMediaDirectoryName)",
                referencedPaths: referencedPaths
            )
        } catch {
            #if DEBUG
            print("[ProjectStore] GC error: \(error.localizedDescription)")
            #endif
        }
    }

    /// Deletes files in a directory that are not in the referenced set.
    private func gcDirectory(_ dirURL: URL, subdirectory: String, referencedPaths: Set<String>) throws {
        guard fileManager.fileExists(atPath: dirURL.path) else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var deletedCount = 0
        for fileURL in contents {
            let relativePath = "\(subdirectory)/\(fileURL.lastPathComponent)"
            if !referencedPaths.contains(relativePath) {
                try fileManager.removeItem(at: fileURL)
                deletedCount += 1
            }
        }

        #if DEBUG
        if deletedCount > 0 {
            print("[ProjectStore] GC deleted \(deletedCount) orphan file(s) from \(subdirectory)")
        }
        #endif
    }

    /// Collects all MediaRef paths referenced by all saved projects + active draft.
    private func collectAllReferencedMediaPaths() throws -> Set<String> {
        var paths: Set<String> = []

        // Collect from all saved projects
        let index = try loadSavedIndex()
        for (projectId, _) in index.projects {
            if let record = loadSavedProject(projectId: projectId) {
                collectMediaPaths(from: record.draft, into: &paths)
            }
        }

        // Collect from active draft
        if let slot = loadActiveDraft() {
            collectMediaPaths(from: slot.draft, into: &paths)
        }

        return paths
    }

    /// Extracts all media paths from a ProjectDraft.
    private func collectMediaPaths(from draft: ProjectDraft, into paths: inout Set<String>) {
        // Background region media
        for (_, regionOverride) in draft.background.regions {
            if let mediaRef = regionOverride.imageMediaRef {
                paths.insert(mediaRef.id)
            }
        }

        // User media from scene instance states (v7: unified media slots)
        for (_, sceneState) in draft.sceneInstanceStates {
            if let slots = sceneState.mediaSlotsByBlockId {
                for (_, slot) in slots {
                    paths.insert(slot.mediaRef.id)
                }
            }
        }
    }

    // MARK: - Schema Purge (v7)

    /// Purges saved projects with incompatible schema from the index.
    /// Called on first launch with v7 schema — no users in prod, so safe to invalidate.
    public func purgeIncompatibleSavedProjects() {
        guard let index = try? loadSavedIndex() else { return }

        var newIndex = index
        var purgedCount = 0

        for (projectId, _) in index.projects {
            // loadSavedProject already returns nil for invalid schema
            if loadSavedProject(projectId: projectId) == nil {
                newIndex.projects.removeValue(forKey: projectId)
                // Remove project file
                if let url = try? projectURL(for: projectId),
                   fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
                purgedCount += 1
            }
        }

        if purgedCount > 0 {
            try? saveSavedIndex(newIndex)
            #if DEBUG
            print("[ProjectStore] Purged \(purgedCount) incompatible saved project(s)")
            #endif

            // Clean up orphan media from purged projects
            triggerAsyncGC()
        }
    }

    // MARK: - Cache Management

    /// Clears the cached index (for testing or refresh).
    public func clearCache() {
        cachedIndex = nil
        migrationAttempted = false
        purgeAttempted = false
    }
}
