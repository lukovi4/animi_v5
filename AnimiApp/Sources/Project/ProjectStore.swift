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
    case crashFileReadFailed(String, Error)
    case crashFileWriteFailed(String, Error)

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
        case .crashFileReadFailed(let templateId, let error):
            return "Failed to read crash file for template \(templateId): \(error.localizedDescription)"
        case .crashFileWriteFailed(let templateId, let error):
            return "Failed to write crash file for template \(templateId): \(error.localizedDescription)"
        }
    }
}

// MARK: - Projects Index

/// Index file structure for templateId → projectId mapping.
struct ProjectsIndex: Codable {
    var byTemplateId: [String: String]  // templateId → projectId (UUID string)

    init(byTemplateId: [String: String] = [:]) {
        self.byTemplateId = byTemplateId
    }
}

// MARK: - Project Store

/// Manages project persistence in Application Support.
///
/// File structure:
/// ```
/// Application Support/AnimiProjects/
/// ├── index.json                    # templateId → projectId mapping
/// ├── <projectId>.json              # ProjectDraft (with schemaVersion)
/// ├── crash_<hash>.json             # Crash recovery draft (SHA256 prefix of templateId)
/// └── Media/
///     └── Background/
///         └── <uuid>.jpg            # copied images
/// ```
public final class ProjectStore {

    // MARK: - Singleton

    public static let shared = ProjectStore()

    // MARK: - Constants

    private static let projectsDirectoryName = "AnimiProjects"
    private static let indexFileName = "index.json"
    private static let mediaDirectoryName = "Media"
    private static let backgroundMediaDirectoryName = "Background"

    // MARK: - Properties

    private let fileManager: FileManager
    private var cachedIndex: ProjectsIndex?

    /// PR4: Flag to prevent concurrent GC runs
    private var isGCInProgress = false

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

    /// Ensures all required directories exist.
    public func ensureDirectoriesExist() throws {
        let projectsDir = try projectsDirectoryURL()
        let mediaDir = try backgroundMediaDirectoryURL()

        do {
            try fileManager.createDirectory(at: projectsDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        } catch {
            throw ProjectStoreError.directoryCreationFailed(error)
        }
    }

    // MARK: - Index Management

    /// Returns the URL for the index file.
    private func indexURL() throws -> URL {
        try projectsDirectoryURL().appendingPathComponent(Self.indexFileName)
    }

    /// Loads the projects index from disk.
    private func loadIndex() throws -> ProjectsIndex {
        if let cached = cachedIndex {
            return cached
        }

        let url = try indexURL()

        guard fileManager.fileExists(atPath: url.path) else {
            let empty = ProjectsIndex()
            cachedIndex = empty
            return empty
        }

        do {
            let data = try Data(contentsOf: url)
            let index = try JSONDecoder().decode(ProjectsIndex.self, from: data)
            cachedIndex = index
            return index
        } catch {
            throw ProjectStoreError.indexReadFailed(error)
        }
    }

    /// Saves the projects index to disk.
    private func saveIndex(_ index: ProjectsIndex) throws {
        try ensureDirectoriesExist()

        let url = try indexURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(index)
            try data.write(to: url, options: .atomic)
            cachedIndex = index
        } catch {
            throw ProjectStoreError.indexWriteFailed(error)
        }
    }

    // MARK: - Project ID API

    /// Returns the project ID for a template, if one exists.
    /// - Parameter templateId: Template identifier
    /// - Returns: Project UUID or nil if no project exists
    public func projectId(for templateId: String) throws -> UUID? {
        let index = try loadIndex()
        guard let idString = index.byTemplateId[templateId] else {
            return nil
        }
        return UUID(uuidString: idString)
    }

    /// Creates or loads the project ID for a template.
    /// - Parameter templateId: Template identifier
    /// - Returns: Project UUID (existing or newly created)
    public func createOrLoadProjectId(for templateId: String) throws -> UUID {
        var index = try loadIndex()

        if let existingIdString = index.byTemplateId[templateId],
           let existingId = UUID(uuidString: existingIdString) {
            return existingId
        }

        let newId = UUID()
        index.byTemplateId[templateId] = newId.uuidString
        try saveIndex(index)

        return newId
    }

    // MARK: - Project File URL

    /// Returns the URL for a project file.
    private func projectURL(for projectId: UUID) throws -> URL {
        try projectsDirectoryURL().appendingPathComponent("\(projectId.uuidString).json")
    }

    // MARK: - Background Override API (Compatibility Layer)
    //
    // These methods provide backwards compatibility with existing code.
    // They now read/write through ProjectDraft to ensure data consistency.
    // New code should use ProjectDraft API directly.

    /// Loads the background override for a project.
    /// Reads from ProjectDraft.background (with legacy migration support).
    /// - Parameters:
    ///   - projectId: Project UUID
    ///   - templateId: Template identifier (required for migration)
    /// - Returns: Background override or nil if not found
    public func loadBackgroundOverride(projectId: UUID, templateId: String) throws -> ProjectBackgroundOverride? {
        guard let draft = try loadProjectDraft(projectId: projectId, templateId: templateId) else {
            return nil
        }
        return draft.background
    }

    /// Loads the background override for a project (legacy signature).
    /// - Note: Deprecated. Use `loadBackgroundOverride(projectId:templateId:)` instead.
    /// - Parameter projectId: Project UUID
    /// - Returns: Background override or nil if not found
    @available(*, deprecated, message: "Use loadBackgroundOverride(projectId:templateId:) instead")
    public func loadBackgroundOverride(projectId: UUID) throws -> ProjectBackgroundOverride? {
        let url = try projectURL(for: projectId)

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Try to decode as ProjectDraft first
        if let draft = try? decoder.decode(ProjectDraft.self, from: data) {
            return draft.background
        }

        // Fallback to legacy format
        do {
            return try JSONDecoder().decode(ProjectBackgroundOverride.self, from: data)
        } catch {
            throw ProjectStoreError.projectReadFailed(projectId, error)
        }
    }

    /// Saves the background override for a project.
    /// Updates ProjectDraft.background and saves the full draft.
    /// - Parameters:
    ///   - projectId: Project UUID
    ///   - templateId: Template identifier
    ///   - override: Background override to save
    public func saveBackgroundOverride(projectId: UUID, templateId: String, override: ProjectBackgroundOverride) throws {
        // Load or create draft
        var draft = try loadProjectDraft(projectId: projectId, templateId: templateId)
            ?? ProjectDraft.create(for: templateId, projectId: projectId)

        // Update background
        draft.background = override
        draft.updatedAt = Date()

        // Save full draft
        try saveProjectDraft(draft)
    }

    /// Saves the background override for a project (legacy signature).
    /// - Warning: This method cannot update ProjectDraft correctly without templateId.
    ///            Use `saveBackgroundOverride(projectId:templateId:override:)` instead.
    /// - Warning: When no ProjectDraft exists, this creates a legacy background-only file.
    ///            It will be migrated to ProjectDraft only when `loadProjectDraft(projectId:templateId:)` is called.
    ///            Until then, other ProjectDraft fields (name, sceneState, timeline) will not exist.
    @available(*, deprecated, message: "Use saveBackgroundOverride(projectId:templateId:override:) instead")
    public func saveBackgroundOverride(projectId: UUID, override: ProjectBackgroundOverride) throws {
        let url = try projectURL(for: projectId)

        // Try to load existing draft to preserve other data
        let data = try? Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if var draft = data.flatMap({ try? decoder.decode(ProjectDraft.self, from: $0) }) {
            // Update background in existing draft
            draft.background = override
            draft.updatedAt = Date()
            try saveProjectDraft(draft)
        } else {
            // No existing draft - this is a legacy call, write legacy format
            // This maintains backwards compatibility but is not recommended
            try ensureDirectoriesExist()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encodedData = try encoder.encode(override)
            try encodedData.write(to: url, options: .atomic)

            // Run GC async after save
            Task.detached { [weak self] in
                await self?.collectOrphanBackgroundMediaFiles()
            }
        }
    }

    /// Deletes a project and its associated data.
    /// - Parameter templateId: Template identifier
    public func deleteProject(templateId: String) throws {
        var index = try loadIndex()

        guard let idString = index.byTemplateId[templateId],
              let projectId = UUID(uuidString: idString) else {
            return  // No project to delete
        }

        // Remove project file
        let projectURL = try projectURL(for: projectId)
        if fileManager.fileExists(atPath: projectURL.path) {
            try fileManager.removeItem(at: projectURL)
        }

        // Update index
        index.byTemplateId.removeValue(forKey: templateId)
        try saveIndex(index)
    }

    // MARK: - Project Draft API (PR1)

    /// Loads the project draft for a project, with automatic migration from legacy format.
    /// - Parameters:
    ///   - projectId: Project UUID
    ///   - templateId: Template identifier (needed for migration)
    /// - Returns: ProjectDraft or nil if not found
    public func loadProjectDraft(projectId: UUID, templateId: String) throws -> ProjectDraft? {
        let url = try projectURL(for: projectId)

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)

        // Try to decode as ProjectDraft first (with ISO8601 dates)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let draft = try? decoder.decode(ProjectDraft.self, from: data) {
            return draft
        }

        // Fallback: try to decode as legacy ProjectBackgroundOverride and migrate
        do {
            let legacy = try JSONDecoder().decode(ProjectBackgroundOverride.self, from: data)
            let migrated = ProjectDraft.migrate(from: legacy, templateId: templateId, projectId: projectId)

            // Rewrite file in new format (atomic)
            try saveProjectDraft(migrated)

            #if DEBUG
            print("[ProjectStore] Migrated legacy project \(projectId) to ProjectDraft format")
            #endif

            return migrated
        } catch {
            throw ProjectStoreError.projectReadFailed(projectId, error)
        }
    }

    /// Saves the project draft.
    /// - Parameter draft: ProjectDraft to save
    public func saveProjectDraft(_ draft: ProjectDraft) throws {
        try ensureDirectoriesExist()

        let url = try projectURL(for: draft.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(draft)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProjectStoreError.projectWriteFailed(draft.id, error)
        }

        // Run GC async after save (non-blocking)
        Task.detached { [weak self] in
            await self?.collectOrphanBackgroundMediaFiles()
        }
    }

    /// Creates or loads a ProjectDraft for a template.
    /// - Parameter templateId: Template identifier
    /// - Returns: Existing or new ProjectDraft
    public func createOrLoadProjectDraft(for templateId: String) throws -> ProjectDraft {
        let projectId = try createOrLoadProjectId(for: templateId)

        // Try to load existing draft
        if let existingDraft = try loadProjectDraft(projectId: projectId, templateId: templateId) {
            return existingDraft
        }

        // Create new draft
        let newDraft = ProjectDraft.create(for: templateId, projectId: projectId)
        try saveProjectDraft(newDraft)

        return newDraft
    }

    // MARK: - Crash Recovery API (PR1)

    /// Returns the crash file URL for a template.
    /// Uses first 16 bytes (32 hex chars) of SHA256 hash of templateId for filesystem-safe filename.
    /// Full templateId is stored inside the file for validation.
    private func crashFileURL(for templateId: String) throws -> URL {
        let hash = SHA256.hash(data: Data(templateId.utf8))
        let hashString = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        let filename = "crash_\(hashString).json"
        return try projectsDirectoryURL().appendingPathComponent(filename)
    }

    /// Checks if a crash recovery file exists for a template.
    /// - Parameter templateId: Template identifier
    /// - Returns: true if crash file exists
    public func hasCrashFile(for templateId: String) -> Bool {
        guard let url = try? crashFileURL(for: templateId) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    /// Loads the crash recovery draft for a template.
    /// - Parameter templateId: Template identifier
    /// - Returns: ProjectDraft from crash file, or nil if not found/invalid
    public func loadCrashDraft(for templateId: String) throws -> ProjectDraft? {
        let url = try crashFileURL(for: templateId)

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let draft = try decoder.decode(ProjectDraft.self, from: data)

            // Validate templateId matches
            guard draft.templateId == templateId else {
                #if DEBUG
                print("[ProjectStore] Crash file templateId mismatch, ignoring")
                #endif
                try? deleteCrashFile(for: templateId)
                return nil
            }

            return draft
        } catch {
            throw ProjectStoreError.crashFileReadFailed(templateId, error)
        }
    }

    /// Saves a crash recovery draft for a template.
    /// Called on every user edit onEnd to enable crash recovery.
    /// - Parameters:
    ///   - draft: Current ProjectDraft state
    ///   - templateId: Template identifier
    public func saveCrashDraft(_ draft: ProjectDraft, for templateId: String) throws {
        try ensureDirectoriesExist()

        let url = try crashFileURL(for: templateId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(draft)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProjectStoreError.crashFileWriteFailed(templateId, error)
        }
    }

    /// Deletes the crash recovery file for a template.
    /// Called after successful Save/Export or on Discard.
    /// - Parameter templateId: Template identifier
    public func deleteCrashFile(for templateId: String) throws {
        let url = try crashFileURL(for: templateId)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
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

        return MediaRef.file(relativePath)
    }

    /// Returns the absolute URL for a media reference.
    /// - Parameter mediaRef: Media reference
    /// - Returns: Absolute file URL
    public func absoluteURL(for mediaRef: MediaRef) throws -> URL {
        let projectsDir = try projectsDirectoryURL()
        return projectsDir.appendingPathComponent(mediaRef.id)
    }

    /// Deletes a media file.
    /// - Parameter mediaRef: Media reference to delete
    public func deleteMediaFile(_ mediaRef: MediaRef) throws {
        let url = try absoluteURL(for: mediaRef)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Garbage Collection (PR4)

    /// Collects and deletes orphan background media files not referenced by any project.
    /// Runs async, with throttle to prevent concurrent executions.
    public func collectOrphanBackgroundMediaFiles() async {
        // Throttle: skip if GC already in progress
        guard !isGCInProgress else {
            #if DEBUG
            print("[ProjectStore] GC skipped - already in progress")
            #endif
            return
        }

        isGCInProgress = true
        defer { isGCInProgress = false }

        do {
            // 1. Collect all referenced media paths from all projects
            let referencedPaths = try collectAllReferencedMediaPaths()

            // 2. Get all files in Media/Background/
            let mediaDir = try backgroundMediaDirectoryURL()
            guard fileManager.fileExists(atPath: mediaDir.path) else { return }

            let contents = try fileManager.contentsOfDirectory(
                at: mediaDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            // 3. Delete orphan files
            var deletedCount = 0
            for fileURL in contents {
                let relativePath = "\(Self.mediaDirectoryName)/\(Self.backgroundMediaDirectoryName)/\(fileURL.lastPathComponent)"

                if !referencedPaths.contains(relativePath) {
                    try fileManager.removeItem(at: fileURL)
                    deletedCount += 1
                }
            }

            #if DEBUG
            if deletedCount > 0 {
                print("[ProjectStore] GC deleted \(deletedCount) orphan file(s)")
            }
            #endif
        } catch {
            #if DEBUG
            print("[ProjectStore] GC error: \(error.localizedDescription)")
            #endif
        }
    }

    /// Collects all MediaRef paths referenced by all projects.
    private func collectAllReferencedMediaPaths() throws -> Set<String> {
        var paths: Set<String> = []

        let index = try loadIndex()

        for (templateId, projectIdString) in index.byTemplateId {
            guard let projectId = UUID(uuidString: projectIdString) else { continue }

            // Try to load as ProjectDraft first, fallback to legacy
            if let draft = try? loadProjectDraft(projectId: projectId, templateId: templateId) {
                // Collect MediaRefs from background regions
                for (_, regionOverride) in draft.background.regions {
                    if let mediaRef = regionOverride.imageMediaRef {
                        paths.insert(mediaRef.id)
                    }
                }
                // Future: collect from sceneState.mediaAssignments when implemented
            } else if let override = try? loadBackgroundOverride(projectId: projectId) {
                // Legacy fallback
                for (_, regionOverride) in override.regions {
                    if let mediaRef = regionOverride.imageMediaRef {
                        paths.insert(mediaRef.id)
                    }
                }
            }
        }

        return paths
    }

    // MARK: - Cache Management

    /// Clears the cached index (for testing or refresh).
    public func clearCache() {
        cachedIndex = nil
    }
}
