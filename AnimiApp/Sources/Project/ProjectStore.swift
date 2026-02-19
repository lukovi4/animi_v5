import Foundation

// MARK: - Project Store Errors

/// Errors that can occur during project store operations.
public enum ProjectStoreError: Error, LocalizedError {
    case directoryCreationFailed(Error)
    case indexReadFailed(Error)
    case indexWriteFailed(Error)
    case projectReadFailed(UUID, Error)
    case projectWriteFailed(UUID, Error)
    case projectNotFound(UUID)

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
/// ├── <projectId>.json              # ProjectBackgroundOverride
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

    // MARK: - Background Override API

    /// Returns the URL for a project's background override file.
    private func projectURL(for projectId: UUID) throws -> URL {
        try projectsDirectoryURL().appendingPathComponent("\(projectId.uuidString).json")
    }

    /// Loads the background override for a project.
    /// - Parameter projectId: Project UUID
    /// - Returns: Background override or nil if not found
    public func loadBackgroundOverride(projectId: UUID) throws -> ProjectBackgroundOverride? {
        let url = try projectURL(for: projectId)

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ProjectBackgroundOverride.self, from: data)
        } catch {
            throw ProjectStoreError.projectReadFailed(projectId, error)
        }
    }

    /// Saves the background override for a project.
    /// - Parameters:
    ///   - projectId: Project UUID
    ///   - override: Background override to save
    public func saveBackgroundOverride(projectId: UUID, override: ProjectBackgroundOverride) throws {
        try ensureDirectoriesExist()

        let url = try projectURL(for: projectId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(override)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProjectStoreError.projectWriteFailed(projectId, error)
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

    // MARK: - Cache Management

    /// Clears the cached index (for testing or refresh).
    public func clearCache() {
        cachedIndex = nil
    }
}
