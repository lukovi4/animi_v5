import Foundation
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "ProjectStorageActor")

/// Actor = serialization/isolation boundary only.
/// Coordinates access to persistence and media stores, owns GC scheduling.
/// All feature/session/routing code accesses storage through this actor.
actor ProjectStorageActor: ProjectPersistenceGateway, ProjectMediaLocator, ProjectMediaWriteGateway {

    private let persistence: FileProjectPersistenceStore
    private let media: FileProjectMediaStore
    private var gcTask: Task<Void, Never>?

    init(
        persistence: FileProjectPersistenceStore = FileProjectPersistenceStore(),
        media: FileProjectMediaStore = FileProjectMediaStore()
    ) {
        self.persistence = persistence
        self.media = media
    }

    // MARK: - ProjectPersistenceGateway

    func saveActiveDraft(_ slot: ActiveDraftSlot) throws {
        try persistence.saveActiveDraft(slot)
    }

    func loadActiveDraft() -> ActiveDraftSlot? {
        persistence.loadActiveDraft()
    }

    func deleteActiveDraft() throws {
        try persistence.deleteActiveDraft()
        scheduleGC()
    }

    func hasActiveDraft() -> Bool {
        persistence.hasActiveDraft()
    }

    func materializeSavedProject(_ slot: ActiveDraftSlot) throws -> ActiveDraftSlot {
        let result = try persistence.materializeSavedProject(slot)
        scheduleGC()
        return result
    }

    func loadSavedProject(projectId: UUID) -> SavedProjectRecord? {
        persistence.loadSavedProject(projectId: projectId)
    }

    func deleteSavedProject(projectId: UUID) throws {
        try persistence.deleteSavedProject(projectId: projectId)
        scheduleGC()
    }

    func allSavedProjectSummaries() -> [SavedProjectSummary] {
        let result = persistence.allSavedProjectSummaries()
        if persistence.didWipeIncompatibleData {
            persistence.didWipeIncompatibleData = false
            scheduleGC()
        }
        return result
    }

    // MARK: - ProjectMediaLocator

    /// Canonical registry-backed resolver. Instance-scoped — the actor holds
    /// NO current-project state; the caller passes the registry snapshot.
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) throws -> URL {
        try media.absoluteURL(for: mediaRef, registry: registry)
    }

    /// Observable fallback counter (forwards the inner store's counter).
    /// Tests assert this stays zero on happy-path production flows.
    var legacyFallbackHits: Int {
        media.legacyFallbackHits
    }

    // MARK: - ProjectMediaWriteGateway

    func saveBackgroundImage(from preparedFileURL: URL) throws -> (MediaRef, URL) {
        try media.saveBackgroundImage(from: preparedFileURL)
    }

    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) throws -> (MediaRef, URL) {
        try media.saveUserMedia(from: fileURL, mediaKind: mediaKind, filename: filename)
    }

    func deleteMediaFile(_ mediaRef: MediaRef) throws {
        try media.deleteMediaFile(mediaRef)
    }

    // MARK: - Duplicate Assets (PR5 storage-level foundation)

    /// Copies every asset referenced by `sourceDraft` to new files with fresh
    /// `ProjectAssetID`s, rebinds every `MediaRef` in the returned draft, and
    /// rebuilds the draft's `assetRegistry` to contain only the new descriptors.
    ///
    /// - The returned draft has a new `id` (UUID) distinct from the source.
    /// - The returned draft shares zero asset IDs and zero storage paths with
    ///   the source draft.
    /// - Source files remain on disk untouched.
    ///
    /// No UI is wired in PR5; this is the storage-level foundation for the
    /// PR7 "Duplicate project" action.
    func duplicateAssets(inDraft sourceDraft: ProjectDraft) throws -> ProjectDraft {
        let (newRegistry, idRewrite, pathRewrite) = try media.duplicateAssets(inDraft: sourceDraft)

        // Rebind a local mutable copy of the source draft.
        var newDraft = sourceDraft
        newDraft.id = UUID()
        newDraft.assetRegistry = newRegistry
        newDraft.createdAt = Date()
        newDraft.updatedAt = Date()

        // Rewrite background regions.
        var newRegions = newDraft.background.regions
        for (regionId, region) in newDraft.background.regions {
            guard case .image(var imageOverride) = region.source else { continue }
            let oldRef = imageOverride.mediaRef
            let newAssetId = idRewrite[oldRef.assetId] ?? oldRef.assetId
            let newStoragePath = pathRewrite[oldRef.storagePath]
                ?? newRegistry.storagePath(for: newAssetId)
                ?? oldRef.storagePath
            imageOverride.mediaRef = MediaRef(
                storagePath: newStoragePath,
                mediaKind: oldRef.mediaKind,
                assetId: newAssetId
            )
            var newRegion = region
            newRegion.source = .image(imageOverride)
            newRegions[regionId] = newRegion
        }
        newDraft.background.regions = newRegions

        // Rewrite scene instance slot media refs.
        var newSceneStates = newDraft.sceneInstanceStates
        for (instanceId, sceneState) in newDraft.sceneInstanceStates {
            guard let slots = sceneState.mediaSlotsByBlockId else { continue }
            var newSlots = slots
            for (blockId, slot) in slots {
                let oldRef = slot.mediaRef
                let newAssetId = idRewrite[oldRef.assetId] ?? oldRef.assetId
                let newStoragePath = pathRewrite[oldRef.storagePath]
                    ?? newRegistry.storagePath(for: newAssetId)
                    ?? oldRef.storagePath
                var newSlot = slot
                newSlot.mediaRef = MediaRef(
                    storagePath: newStoragePath,
                    mediaKind: oldRef.mediaKind,
                    assetId: newAssetId
                )
                newSlots[blockId] = newSlot
            }
            var newState = sceneState
            newState.mediaSlotsByBlockId = newSlots
            newSceneStates[instanceId] = newState
        }
        newDraft.sceneInstanceStates = newSceneStates

        return newDraft
    }

    // MARK: - GC Scheduling (actor-bound, replaces Task.detached)

    private var isGCInProgress = false
    private var gcPending = false

    private func scheduleGC() {
        if isGCInProgress {
            gcPending = true
            return
        }
        startGC()
    }

    private func startGC() {
        isGCInProgress = true
        gcPending = false
        gcTask = Task { [weak self] in
            guard let self else { return }
            await self.media.collectOrphanMediaFiles(persistence: self.persistence)
            await self.gcDidComplete()
        }
    }

    private func gcDidComplete() {
        isGCInProgress = false
        if gcPending {
            startGC()
        }
    }
}
