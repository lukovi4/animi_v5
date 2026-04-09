import Foundation

/// Thin file-backed media implementation.
/// Extracted from `ProjectStore` — owns media file I/O and GC logic.
final class FileProjectMediaStore: @unchecked Sendable {

    // MARK: - Properties

    let fileManager: FileManager
    private let rootDirectoryOverride: URL?

    // MARK: - Initialization

    init(fileManager: FileManager = .default, rootDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootDirectoryOverride = rootDirectoryURL
    }

    // MARK: - Directory Helpers

    private func projectsDirectoryURL() throws -> URL {
        if let override = rootDirectoryOverride {
            return override
        }
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent(FileProjectPersistenceStore.projectsDirectoryName)
    }

    func backgroundMediaDirectoryURL() throws -> URL {
        let projectsDir = try projectsDirectoryURL()
        return projectsDir
            .appendingPathComponent(FileProjectPersistenceStore.mediaDirectoryName)
            .appendingPathComponent(FileProjectPersistenceStore.backgroundMediaDirectoryName)
    }

    func userMediaDirectoryURL() throws -> URL {
        let projectsDir = try projectsDirectoryURL()
        return projectsDir
            .appendingPathComponent(FileProjectPersistenceStore.mediaDirectoryName)
            .appendingPathComponent(FileProjectPersistenceStore.userMediaDirectoryName)
    }

    // MARK: - Media File API

    func saveBackgroundImage(from preparedFileURL: URL) throws -> (MediaRef, URL) {
        let backgroundDir = try backgroundMediaDirectoryURL()
        try fileManager.createDirectory(at: backgroundDir, withIntermediateDirectories: true)

        let uuid = UUID().uuidString
        let filename = "\(uuid).jpg"
        let relativePath = "\(FileProjectPersistenceStore.mediaDirectoryName)/\(FileProjectPersistenceStore.backgroundMediaDirectoryName)/\(filename)"

        let destURL = backgroundDir.appendingPathComponent(filename)
        try fileManager.copyItem(at: preparedFileURL, to: destURL)

        return (MediaRef.file(relativePath, mediaKind: .photo), destURL)
    }

    func absoluteURL(for mediaRef: MediaRef) throws -> URL {
        let projectsDir = try projectsDirectoryURL()
        return projectsDir.appendingPathComponent(mediaRef.id)
    }

    func deleteMediaFile(_ mediaRef: MediaRef) throws {
        let url = try absoluteURL(for: mediaRef)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Garbage Collection

    /// Collects and deletes orphan media files not referenced by any saved project or active draft.
    func collectOrphanMediaFiles(persistence: FileProjectPersistenceStore) async {
        do {
            let referencedPaths = try collectAllReferencedMediaPaths(persistence: persistence)

            try gcDirectory(
                try backgroundMediaDirectoryURL(),
                subdirectory: "\(FileProjectPersistenceStore.mediaDirectoryName)/\(FileProjectPersistenceStore.backgroundMediaDirectoryName)",
                referencedPaths: referencedPaths
            )

            try gcDirectory(
                try userMediaDirectoryURL(),
                subdirectory: "\(FileProjectPersistenceStore.mediaDirectoryName)/\(FileProjectPersistenceStore.userMediaDirectoryName)",
                referencedPaths: referencedPaths
            )
        } catch {
            #if DEBUG
            print("[FileProjectMediaStore] GC error: \(error.localizedDescription)")
            #endif
        }
    }

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
            print("[FileProjectMediaStore] GC deleted \(deletedCount) orphan file(s) from \(subdirectory)")
        }
        #endif
    }

    private func collectAllReferencedMediaPaths(persistence: FileProjectPersistenceStore) throws -> Set<String> {
        var paths: Set<String> = []

        let index = try persistence.loadSavedIndex()
        for (projectId, _) in index.projects {
            if let record = persistence.loadSavedProject(projectId: projectId) {
                collectMediaPaths(from: record.draft, into: &paths)
            }
        }

        if let slot = persistence.loadActiveDraft() {
            collectMediaPaths(from: slot.draft, into: &paths)
        }

        return paths
    }

    private func collectMediaPaths(from draft: ProjectDraft, into paths: inout Set<String>) {
        for (_, regionOverride) in draft.background.regions {
            if let mediaRef = regionOverride.imageMediaRef {
                paths.insert(mediaRef.id)
            }
        }

        for (_, sceneState) in draft.sceneInstanceStates {
            if let slots = sceneState.mediaSlotsByBlockId {
                for (_, slot) in slots {
                    paths.insert(slot.mediaRef.id)
                }
            }
        }
    }
}
