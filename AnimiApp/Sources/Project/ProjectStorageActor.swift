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

    func absoluteURL(for mediaRef: MediaRef) throws -> URL {
        try media.absoluteURL(for: mediaRef)
    }

    // MARK: - ProjectMediaWriteGateway

    func saveBackgroundImage(from preparedFileURL: URL) throws -> (MediaRef, URL) {
        try media.saveBackgroundImage(from: preparedFileURL)
    }

    func deleteMediaFile(_ mediaRef: MediaRef) throws {
        try media.deleteMediaFile(mediaRef)
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
