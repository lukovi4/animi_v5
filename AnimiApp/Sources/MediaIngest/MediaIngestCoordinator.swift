import Foundation
import PhotosUI

// MARK: - Ingest Slot Key

/// Canonical identity for an ingest operation.
/// Two ingests with the same key are the same logical slot; new one cancels the old.
/// Different scenes with the same blockId are independent slots.
public struct IngestSlotKey: Hashable, Sendable {
    public let sceneInstanceId: UUID
    public let blockId: String

    public init(sceneInstanceId: UUID, blockId: String) {
        self.sceneInstanceId = sceneInstanceId
        self.blockId = blockId
    }
}

// MARK: - Ingest Slot Status

/// UI-facing status of a single ingest slot.
/// Owned by MediaIngestCoordinator. UI subscribes for progress/error indicators.
public enum IngestSlotStatus: Equatable, Sendable {
    case idle
    case processing
    case ready
    case failed(reason: String)
}

// MARK: - Ingest Result

/// Result of a completed ingest operation.
///
/// Contains only persisted media payload — no placement policy.
/// The caller (EditorViewController) is responsible for resolving `defaultFit`
/// from template metadata and assembling the final `SceneMediaSlot`.
public struct IngestResult: Sendable {
    public let key: IngestSlotKey
    /// Reference to the persisted media file.
    public let mediaRef: MediaRef
    /// Media kind detected from picker result.
    public let mediaKind: IngestMediaKind
    /// Video trim/audio parameters. Nil for photos.
    public let videoWindow: PersistedVideoSelection?
    /// URL of the persisted file on disk.
    public let persistedURL: URL

    public var sceneInstanceId: UUID { key.sceneInstanceId }
    public var blockId: String { key.blockId }
}

/// Media kind determined during ingest.
public enum IngestMediaKind: Sendable {
    case photo
    case video
}

// MARK: - Media Ingest Coordinator

/// Orchestrates the full ingest pipeline: PHPicker → prepare → persist → bind.
///
/// Identity contract:
/// - Each ingest operation is keyed by `IngestSlotKey(sceneInstanceId, blockId)`.
/// - Same key = same logical slot. New ingest for the same key cancels the previous one.
/// - Different scenes with the same blockId are independent and do not interfere.
///
/// Orphan cleanup contract:
/// - If a task is cancelled or invalidated AFTER persisting a file, the file is deleted immediately.
/// - GC is not relied upon for ingest-abort cleanup.
///
/// Does NOT own runtime state (textures, decoders). That's UserMediaService.
@MainActor
public final class MediaIngestCoordinator {

    // MARK: - Dependencies

    private let assetStore: MediaAssetStore

    // MARK: - State (keyed by IngestSlotKey)

    /// Per-slot ingest status.
    public private(set) var slotStatus: [IngestSlotKey: IngestSlotStatus] = [:]

    /// In-flight ingest tasks.
    private var ingestTasks: [IngestSlotKey: Task<Void, Never>] = [:]

    /// Generation tokens for race protection.
    private var generationByKey: [IngestSlotKey: UInt64] = [:]

    // MARK: - Callbacks

    /// Called when ingest completes successfully. Wire to EditorStore dispatch + runtime bind.
    public var onIngestComplete: ((IngestResult) -> Void)?

    /// PR5 Phase E: Called on success **before** `onIngestComplete`, with the
    /// fresh asset descriptor. The session wires this to
    /// `registerAssetBookkeeping(_:)` so the project asset registry is
    /// populated before any downstream apply path reads it.
    ///
    /// Contract: bookkeeping is non-dirtying and runs strictly ahead of
    /// `onIngestComplete`, so when the reducer sees the ingest result and
    /// dispatches `.setMediaSlot(...)`, the `session.state.draft.assetRegistry`
    /// already contains the new descriptor.
    public var onAssetPersisted: ((ProjectAssetDescriptor) -> Void)?

    /// Called when ingest status changes. Wire to UI for progress indicators.
    public var onStatusChanged: ((IngestSlotKey, IngestSlotStatus) -> Void)?

    // MARK: - Init

    public init(assetStore: MediaAssetStore) {
        self.assetStore = assetStore
    }

    // MARK: - Ingest from PHPicker

    /// Starts ingest for a PHPicker result.
    /// Cancels any in-flight ingest for the same (sceneInstanceId, blockId).
    ///
    /// - Parameters:
    ///   - result: PHPicker result
    ///   - key: Identity of the target slot
    public func ingest(pickerResult result: PHPickerResult, key: IngestSlotKey) {
        // Cancel previous ingest for this exact slot
        cancelIngest(for: key)

        // Increment generation token
        let newGen = (generationByKey[key] ?? 0) + 1
        generationByKey[key] = newGen

        updateStatus(key: key, status: .processing)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            // Track persisted file for orphan cleanup on abort
            var ownedPersistedURL: URL?

            do {
                // Determine media kind before extraction
                let mediaKind = PickerAssetAdapter.mediaKind(of: result)

                let ingestedMediaRef: MediaRef
                let ingestedMediaKind: IngestMediaKind
                var ingestedVideoWindow: PersistedVideoSelection?
                let persistedURL: URL

                switch mediaKind {
                case .photo:
                    // Step 1: Extract photo from picker (temp copy)
                    let pickedAsset = try await PickerAssetAdapter.extractPhoto(from: result)
                    let tempPickerURL: URL
                    switch pickedAsset {
                    case .photo(let url): tempPickerURL = url
                    }

                    guard self.isCurrentGeneration(key: key, gen: newGen) else {
                        try? FileManager.default.removeItem(at: tempPickerURL)
                        self.cleanupOrphan(ownedPersistedURL)
                        return
                    }

                    defer { try? FileManager.default.removeItem(at: tempPickerURL) }

                    // Prepare + persist off MainActor
                    let (mediaRef, resolved) = try await Self.prepareAndPersistPhoto(
                        tempPickerURL: tempPickerURL,
                        assetStore: self.assetStore,
                        sceneInstanceId: key.sceneInstanceId,
                        blockId: key.blockId
                    )
                    persistedURL = resolved
                    ownedPersistedURL = persistedURL

                    guard self.isCurrentGeneration(key: key, gen: newGen) else {
                        self.cleanupOrphan(ownedPersistedURL)
                        return
                    }

                    ingestedMediaRef = mediaRef
                    ingestedMediaKind = .photo

                case .video:
                    // Step 1: Persist video directly from PHPicker callback (single copy, no temp)
                    // saveMedia returns (MediaRef, URL) atomically — no separate resolve step.
                    let (mediaRef, resolved) = try await Self.persistVideoFromPicker(
                        result: result,
                        assetStore: self.assetStore,
                        sceneInstanceId: key.sceneInstanceId,
                        blockId: key.blockId
                    )
                    persistedURL = resolved
                    ownedPersistedURL = persistedURL

                    guard self.isCurrentGeneration(key: key, gen: newGen) else {
                        self.cleanupOrphan(ownedPersistedURL)
                        return
                    }

                    // Step 2: Validate persisted video off MainActor
                    let validatedSelection = try await Self.validatePersistedVideo(at: persistedURL)

                    guard self.isCurrentGeneration(key: key, gen: newGen) else {
                        self.cleanupOrphan(ownedPersistedURL)
                        return
                    }

                    ingestedMediaRef = mediaRef
                    ingestedMediaKind = .video
                    ingestedVideoWindow = validatedSelection

                case .audio, nil:
                    throw PickerAssetError.unsupportedMediaType
                }

                guard self.isCurrentGeneration(key: key, gen: newGen) else {
                    self.cleanupOrphan(ownedPersistedURL)
                    return
                }

                // Step 3: Complete — file is now owned by the store, not us
                ownedPersistedURL = nil
                self.finalizeSuccess(
                    key: key,
                    mediaRef: ingestedMediaRef,
                    mediaKind: ingestedMediaKind,
                    videoWindow: ingestedVideoWindow,
                    persistedURL: persistedURL
                )

            } catch is CancellationError {
                self.cleanupOrphan(ownedPersistedURL)
                #if DEBUG
                print("[MediaIngestCoordinator] Cancelled: \(key.blockId)@\(key.sceneInstanceId)")
                #endif
            } catch {
                self.cleanupOrphan(ownedPersistedURL)
                guard self.isCurrentGeneration(key: key, gen: newGen) else { return }
                self.updateStatus(key: key, status: .failed(reason: error.localizedDescription))
                self.ingestTasks.removeValue(forKey: key)
                #if DEBUG
                print("[MediaIngestCoordinator] Failed: \(key.blockId)@\(key.sceneInstanceId): \(error)")
                #endif
            }
        }

        ingestTasks[key] = task
    }

    // MARK: - Off-Main Photo Prepare + Persist

    /// PR5: Saves the original photo file as-is (no downsample/transcode).
    /// The original serves as master for export; runtime uses a proxy via PhotoProxyCache.
    private static nonisolated func prepareAndPersistPhoto(
        tempPickerURL: URL,
        assetStore: MediaAssetStore,
        sceneInstanceId: UUID,
        blockId: String
    ) async throws -> (MediaRef, URL) {
        // Save original file directly — runtime uses PhotoProxyCache for display proxies
        let (mediaRef, absoluteURL) = try await assetStore.saveMedia(
            from: tempPickerURL,
            mediaKind: .photo,
            sceneInstanceId: sceneInstanceId,
            blockId: blockId
        )
        return (mediaRef, absoluteURL)
    }

    // MARK: - Off-Main Video Persist + Resolve

    /// Persists a video from PHPicker via single-copy into MediaAssetStore.
    /// Returns (mediaRef, absoluteURL) atomically from `saveMedia` — no separate resolve step.
    /// The destURL is produced by `saveMedia` itself, so there is no window where the file
    /// exists on disk but the caller doesn't hold its absolute path.
    private static nonisolated func persistVideoFromPicker(
        result: PHPickerResult,
        assetStore: MediaAssetStore,
        sceneInstanceId: UUID,
        blockId: String
    ) async throws -> (MediaRef, URL) {
        // Copy to temp location synchronously inside the file representation callback,
        // then persist asynchronously via the media writer gateway.
        let tempURL: URL = try await PickerAssetAdapter.withVideoFileRepresentation(
            from: result
        ) { sourceURL in
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(sourceURL.pathExtension)
            try FileManager.default.copyItem(at: sourceURL, to: tmp)
            return tmp
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await assetStore.saveMedia(
            from: tempURL,
            mediaKind: .video,
            sceneInstanceId: sceneInstanceId,
            blockId: blockId
        )
    }

    // MARK: - Off-Main Video Validation

    /// Runs VideoPreparePipeline.validatePersistedVideo off the MainActor.
    private static nonisolated func validatePersistedVideo(at url: URL) async throws -> PersistedVideoSelection {
        try await VideoPreparePipeline.validatePersistedVideo(at: url)
    }

    // MARK: - Cancel

    /// Cancels in-flight ingest for a specific slot.
    /// Clears status and emits `.idle` so UI observers stay consistent.
    public func cancelIngest(for key: IngestSlotKey) {
        ingestTasks[key]?.cancel()
        ingestTasks.removeValue(forKey: key)
        if slotStatus.removeValue(forKey: key) != nil {
            onStatusChanged?(key, .idle)
        }
    }

    /// Cancels all in-flight ingests for a specific scene instance.
    /// Clears status for all slots of that scene.
    public func cancelAll(for sceneInstanceId: UUID) {
        for (key, task) in ingestTasks where key.sceneInstanceId == sceneInstanceId {
            task.cancel()
            ingestTasks.removeValue(forKey: key)
        }
        for key in slotStatus.keys where key.sceneInstanceId == sceneInstanceId {
            slotStatus.removeValue(forKey: key)
            onStatusChanged?(key, .idle)
        }
    }

    /// Cancels all in-flight ingests.
    public func cancelAll() {
        let keys = Array(slotStatus.keys)
        for (_, task) in ingestTasks {
            task.cancel()
        }
        ingestTasks.removeAll()
        slotStatus.removeAll()
        for key in keys {
            onStatusChanged?(key, .idle)
        }
    }

    /// Nonisolated cancel for use in VC `deinit` (where @MainActor methods cannot be called directly).
    /// Only cancels Swift Tasks (Task.cancel() is thread-safe per Swift concurrency spec).
    /// Does not touch status dicts — not needed at dealloc, no observers remain.
    nonisolated func cancelAllFromDeinit() {
        // Access ingestTasks via assumeIsolated — safe because:
        // 1. EditorViewController is @MainActor, so its deinit runs on main thread
        // 2. At deinit, no other references exist, so no concurrent access
        MainActor.assumeIsolated {
            for (_, task) in self.ingestTasks {
                task.cancel()
            }
        }
    }

    // MARK: - Status Query

    /// Returns ingest status for a slot.
    public func status(for key: IngestSlotKey) -> IngestSlotStatus {
        slotStatus[key] ?? .idle
    }

    // MARK: - Success Finalization

    /// Shared success finalization: .ready → onIngestComplete → .idle
    private func finalizeSuccess(
        key: IngestSlotKey,
        mediaRef: MediaRef,
        mediaKind: IngestMediaKind,
        videoWindow: PersistedVideoSelection?,
        persistedURL: URL
    ) {
        updateStatus(key: key, status: .ready)
        ingestTasks.removeValue(forKey: key)

        // PR5 Phase E: Register the freshly persisted asset BEFORE emitting
        // the ingest result. This guarantees that any downstream code (the
        // reducer, the apply path, etc.) sees the descriptor in the draft's
        // registry by the time it touches `mediaRef.assetId`.
        let descriptor = ProjectAssetDescriptor(
            assetId: mediaRef.assetId,
            mediaKind: mediaRef.mediaKind,
            storagePath: mediaRef.storagePath
        )
        onAssetPersisted?(descriptor)

        let result = IngestResult(
            key: key,
            mediaRef: mediaRef,
            mediaKind: mediaKind,
            videoWindow: videoWindow,
            persistedURL: persistedURL
        )
        onIngestComplete?(result)
        // Transient ready: immediately transition to idle
        slotStatus.removeValue(forKey: key)
        onStatusChanged?(key, .idle)
    }

    /// Test-only: simulates a complete ingest success for lifecycle testing.
    /// Calls the same finalizeSuccess path as production code.
    internal func simulateIngestCompletion(
        key: IngestSlotKey,
        mediaRef: MediaRef,
        mediaKind: IngestMediaKind,
        videoWindow: PersistedVideoSelection? = nil,
        persistedURL: URL
    ) {
        updateStatus(key: key, status: .processing)
        finalizeSuccess(
            key: key,
            mediaRef: mediaRef,
            mediaKind: mediaKind,
            videoWindow: videoWindow,
            persistedURL: persistedURL
        )
    }

    // MARK: - Private

    private func isCurrentGeneration(key: IngestSlotKey, gen: UInt64) -> Bool {
        guard generationByKey[key] == gen, !Task.isCancelled else { return false }
        return true
    }

    private func updateStatus(key: IngestSlotKey, status: IngestSlotStatus) {
        slotStatus[key] = status
        onStatusChanged?(key, status)
    }

    /// Deletes an orphan persisted file from an aborted ingest.
    private func cleanupOrphan(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        #if DEBUG
        print("[MediaIngestCoordinator] Cleaned up orphan: \(url.lastPathComponent)")
        #endif
    }

}
