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

        return (MediaRef.file(relativePath, assetId: ProjectAssetID(), mediaKind: .photo), destURL)
    }

    /// Low-level path-based resolver used by registry-backed lookups.
    func absoluteURL(forRelativePath relativePath: String) throws -> URL {
        let projectsDir = try projectsDirectoryURL()
        return projectsDir.appendingPathComponent(relativePath)
    }

    /// Registry-backed resolution. If the registry has a descriptor for the
    /// `mediaRef.assetId`, uses its `storagePath`. Otherwise falls back to
    /// `mediaRef.storagePath` (legacy path) and bumps `legacyFallbackHits` so
    /// tests can observe whether any production call hit the fallback.
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) throws -> URL {
        if let descriptor = registry.descriptor(for: mediaRef.assetId) {
            return try absoluteURL(forRelativePath: descriptor.storagePath)
        }
        legacyFallbackHits += 1
        #if DEBUG
        print("[FileProjectMediaStore] Registry miss for asset \(mediaRef.assetId.rawValue); falling back to mediaRef.storagePath=\(mediaRef.storagePath)")
        #endif
        return try absoluteURL(forRelativePath: mediaRef.storagePath)
    }

    /// Observable counter of legacy-path fallbacks. Tests assert this stays
    /// zero on happy-path production flows. Non-atomic — single-thread actor use.
    private(set) var legacyFallbackHits: Int = 0

    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) throws -> (MediaRef, URL) {
        let userDir = try userMediaDirectoryURL()
        try fileManager.createDirectory(at: userDir, withIntermediateDirectories: true)

        let relativePath = "\(FileProjectPersistenceStore.mediaDirectoryName)/\(FileProjectPersistenceStore.userMediaDirectoryName)/\(filename)"
        let destURL = userDir.appendingPathComponent(filename)

        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.copyItem(at: fileURL, to: destURL)

        return (MediaRef.file(relativePath, assetId: ProjectAssetID(), mediaKind: mediaKind), destURL)
    }

    // MARK: - Duplicate-Assets Foundation (PR5 storage-level)

    /// Low-level duplicator. For every asset ID referenced by `sourceDraft`
    /// (via `assetRegistry.assetIds(referencedBy:)`), copies the underlying
    /// file to a new destination with a freshly minted UUID filename in the
    /// same directory class (background vs user media, inferred from the
    /// source storage path). Returns:
    /// - `newRegistry`: a fresh registry containing only the copied descriptors.
    /// - `idRewrite`: mapping from old `ProjectAssetID` to new `ProjectAssetID`.
    /// - `pathRewrite`: mapping from old storage path to new storage path
    ///   (used by the caller to rebind `MediaRef`s whose registry descriptor
    ///   was missing — defense-in-depth).
    ///
    /// Does not touch `sourceDraft`; the caller rebinds the draft's slots and
    /// background region overrides.
    func duplicateAssets(
        inDraft sourceDraft: ProjectDraft
    ) throws -> (registry: ProjectAssetRegistry, idRewrite: [ProjectAssetID: ProjectAssetID], pathRewrite: [String: String]) {
        var newRegistry = ProjectAssetRegistry()
        var idRewrite: [ProjectAssetID: ProjectAssetID] = [:]
        var pathRewrite: [String: String] = [:]

        let referenced = sourceDraft.assetRegistry.assetIds(referencedBy: sourceDraft)

        // Build a draft-scan fallback so we can duplicate assets whose
        // descriptors are missing from the source registry (pre-registry drafts).
        var fallbackRefs: [ProjectAssetID: MediaRef] = [:]
        for (_, region) in sourceDraft.background.regions {
            if let ref = region.mediaRef { fallbackRefs[ref.assetId] = ref }
        }
        for (_, sceneState) in sourceDraft.sceneInstanceStates {
            if let slots = sceneState.mediaSlotsByBlockId {
                for (_, slot) in slots { fallbackRefs[slot.mediaRef.assetId] = slot.mediaRef }
            }
        }
        // PR2: Walk scene-level background overrides for fallback refs
        for (_, sceneState) in sourceDraft.sceneInstanceStates {
            if let bgOverride = sceneState.backgroundOverride {
                for (_, region) in bgOverride.regions {
                    if let ref = region.mediaRef { fallbackRefs[ref.assetId] = ref }
                }
            }
        }
        // PR8: Walk audio payloads for imported asset fallback refs
        for (_, payload) in sourceDraft.canonicalTimeline.payloads {
            if case .audio(let audioPayload) = payload,
               case .imported(let assetId, let storagePath) = audioPayload.assetRef {
                let resolvedStoragePath = sourceDraft.assetRegistry.storagePath(for: assetId) ?? storagePath
                guard !resolvedStoragePath.isEmpty else { continue }
                fallbackRefs[assetId] = MediaRef(storagePath: resolvedStoragePath, mediaKind: .audio, assetId: assetId)
            }
        }

        for oldAssetId in referenced {
            // Resolve the source file and infer its destination class.
            let (sourceURL, sourceRelativePath, mediaKind) = try resolveSourceForDuplicate(
                oldAssetId: oldAssetId,
                registry: sourceDraft.assetRegistry,
                fallbackRefs: fallbackRefs
            )

            let destDirURL: URL
            let destSubdir: String
            if sourceRelativePath.contains("/\(FileProjectPersistenceStore.backgroundMediaDirectoryName)/") {
                destDirURL = try backgroundMediaDirectoryURL()
                destSubdir = "\(FileProjectPersistenceStore.mediaDirectoryName)/\(FileProjectPersistenceStore.backgroundMediaDirectoryName)"
            } else {
                destDirURL = try userMediaDirectoryURL()
                destSubdir = "\(FileProjectPersistenceStore.mediaDirectoryName)/\(FileProjectPersistenceStore.userMediaDirectoryName)"
            }

            let ext = (sourceRelativePath as NSString).pathExtension
            let newFilename = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
            let newRelativePath = "\(destSubdir)/\(newFilename)"

            // Variant B: mint independent descriptor even if source file is missing.
            // Missing files are not copied; the new draft gets a fresh broken ref
            // that the existing missing-media notice path detects at bootstrap.
            if fileManager.fileExists(atPath: sourceURL.path) {
                try fileManager.createDirectory(at: destDirURL, withIntermediateDirectories: true)
                let newDestURL = destDirURL.appendingPathComponent(newFilename)
                try fileManager.copyItem(at: sourceURL, to: newDestURL)
            } else {
                #if DEBUG
                print("[FileProjectMediaStore] duplicateAssets: source missing for asset \(oldAssetId.rawValue) at \(sourceRelativePath), minting broken duplicate descriptor")
                #endif
            }

            let newAssetId = ProjectAssetID()
            let newDescriptor = ProjectAssetDescriptor(
                assetId: newAssetId,
                mediaKind: mediaKind,
                storagePath: newRelativePath
            )
            newRegistry.register(newDescriptor)
            idRewrite[oldAssetId] = newAssetId
            pathRewrite[sourceRelativePath] = newRelativePath
        }

        return (newRegistry, idRewrite, pathRewrite)
    }

    private func resolveSourceForDuplicate(
        oldAssetId: ProjectAssetID,
        registry: ProjectAssetRegistry,
        fallbackRefs: [ProjectAssetID: MediaRef]
    ) throws -> (sourceURL: URL, relativePath: String, mediaKind: MediaKind) {
        if let descriptor = registry.descriptor(for: oldAssetId) {
            let url = try absoluteURL(forRelativePath: descriptor.storagePath)
            return (url, descriptor.storagePath, descriptor.mediaKind)
        }
        if let ref = fallbackRefs[oldAssetId] {
            let url = try absoluteURL(forRelativePath: ref.storagePath)
            return (url, ref.storagePath, ref.mediaKind)
        }
        throw NSError(
            domain: "FileProjectMediaStore.duplicateAssets",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unknown asset id \(oldAssetId.rawValue)"]
        )
    }

    func deleteMediaFile(_ mediaRef: MediaRef) throws {
        // Delete is a path-level operation — GC/unbind have already decided the
        // file should go. Use the low-level path resolver directly, no registry.
        let url = try absoluteURL(forRelativePath: mediaRef.storagePath)
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

    /// GC pin policy (Phase B):
    /// 1. **Primary**: `assetRegistry.storagePaths(referencedBy: draft)` — the
    ///    draft's currently-referenced asset IDs resolved via the registry
    ///    (with `mediaRef.storagePath` fallback when an entry is missing).
    /// 2. **Defense-in-depth**: raw scan of slot/background `mediaRef.storagePath`.
    ///    Catches drafts whose registry is empty or stale.
    ///
    /// Descriptors registered but not referenced by content are **not** pinned.
    /// They are GC-eligible by design.
    private func collectMediaPaths(from draft: ProjectDraft, into paths: inout Set<String>) {
        // Primary: registry-resolved, referenced-only.
        paths.formUnion(draft.assetRegistry.storagePaths(referencedBy: draft))

        // Defense-in-depth: raw-path scan (keeps pre-registry / stale-registry drafts safe).
        for (_, regionOverride) in draft.background.regions {
            if let mediaRef = regionOverride.mediaRef {
                paths.insert(mediaRef.storagePath)
            }
        }
        for (_, sceneState) in draft.sceneInstanceStates {
            if let slots = sceneState.mediaSlotsByBlockId {
                for (_, slot) in slots {
                    paths.insert(slot.mediaRef.storagePath)
                }
            }
            // PR2: Walk scene-level background overrides
            if let bgOverride = sceneState.backgroundOverride {
                for (_, region) in bgOverride.regions {
                    if let mediaRef = region.mediaRef {
                        paths.insert(mediaRef.storagePath)
                    }
                }
            }
        }
        for (_, payload) in draft.canonicalTimeline.payloads {
            if case .audio(let audioPayload) = payload,
               case .imported(_, let storagePath) = audioPayload.assetRef,
               !storagePath.isEmpty {
                paths.insert(storagePath)
            }
        }
    }
}
