import Foundation
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorSession")

/// Session boundary that owns EditorStore, dirty state, checkpoint, export-commit, and close decisions.
/// The view controller dispatches actions and wires callbacks, but does not own the store.
@MainActor
final class EditorSession {

    let intent: EditorLaunchIntent
    let deps: EditorSessionDependencies

    private(set) var phase: EditorSessionPhase = .idle
    /// Set during bootstrap, updated by checkpoint/export-commit. Writable from tests via @testable.
    var activeDraftSlot: ActiveDraftSlot?

    /// EditorStore — created during bootstrap, owned by session.
    private var store: EditorStore?
    /// Dual-baseline dirty tracking.
    private var dirtyState: EditorSessionDirtyState?
    /// Missing media summary — populated via `updateMissingMedia(for:failures:)`.
    private(set) var missingMediaSummary: MissingMediaSummary?
    /// Whether a missing-media notice is pending presentation to the user.
    /// Set to true when first missing media is detected; cleared by controller ack.
    private(set) var hasPendingMissingMediaNotice = false
    /// Whether the missing-media notice has been presented and acknowledged by the controller.
    private var missingMediaNoticeDelivered = false

    // MARK: - Store Proxy API

    /// Dispatches an action to the internal EditorStore.
    func dispatch(_ action: EditorAction) { store?.dispatch(action) }

    /// Read-only access to the current editor state.
    var state: EditorState? { store?.state }

    /// Wires all store callbacks through the session boundary.
    func setStoreCallbacks(_ callbacks: EditorStoreCallbacks) {
        guard let store else { return }
        store.onPlayheadChanged = callbacks.onPlayheadChanged
        store.onSelectionChanged = callbacks.onSelectionChanged
        store.onTimelineChanged = callbacks.onTimelineChanged
        store.onTimelinePreviewChanged = callbacks.onTimelinePreviewChanged
        store.onUndoRedoChanged = callbacks.onUndoRedoChanged
        store.onUIModeChanged = callbacks.onUIModeChanged
        store.onSelectedBlockChanged = callbacks.onSelectedBlockChanged
        store.onStateRestoredFromUndoRedo = callbacks.onStateRestoredFromUndoRedo
        store.onSceneStateChanged = callbacks.onSceneStateChanged
        store.onVideoSelectionChanged = callbacks.onVideoSelectionChanged
        store.onMediaSlotChanged = callbacks.onMediaSlotChanged
        store.onMediaPlacementChanged = callbacks.onMediaPlacementChanged
        store.onMediaVisibilityChanged = callbacks.onMediaVisibilityChanged
        store.onNotice = callbacks.onNotice
    }

    // MARK: - Missing Media

    /// Replaces the set of failed slots for a specific scene instance.
    /// Called after each applySceneInstanceState and after slot changes (rebind/clear).
    /// Accumulates across scenes: only the reported instance's entries are replaced,
    /// other instances' failures are preserved. Clears resolved slots automatically.
    func updateMissingMedia(for sceneInstanceId: UUID, failures: Set<String>) {
        var current = missingMediaSummary?.failedSlots ?? []
        // Remove all entries for this scene instance (replace, not merge)
        current = current.filter { $0.sceneInstanceId != sceneInstanceId }
        // Add new failures for this instance
        for blockId in failures {
            current.insert(MissingMediaSlotKey(sceneInstanceId: sceneInstanceId, blockId: blockId))
        }
        if current.isEmpty {
            missingMediaSummary = nil
            hasPendingMissingMediaNotice = false
        } else {
            let summary = MissingMediaSummary(failedSlots: current)
            missingMediaSummary = summary
            if !missingMediaNoticeDelivered && !hasPendingMissingMediaNotice {
                hasPendingMissingMediaNotice = true
                onOutput?(.missingMediaDetected(summary))
            }
        }
    }

    /// Called by the controller after the missing-media notice has been shown to the user.
    func markMissingMediaNoticePresented() {
        hasPendingMissingMediaNotice = false
        missingMediaNoticeDelivered = true
    }

    /// Background preset provider — exposed for controller use.
    var backgroundPresetProvider: BackgroundPresetProviding { deps.backgroundPresetProvider }

    var onOutput: ((EditorSessionOutput) -> Void)?

    init(intent: EditorLaunchIntent, dependencies: EditorSessionDependencies) {
        self.intent = intent
        self.deps = dependencies
    }

    // MARK: - Bootstrap

    /// Resolves intent → templateId + draft + ActiveDraftSlot, loads content, emits result.
    /// Extracted from PlayerViewController.loadEditorContent() lines 391–529.
    func bootstrap() async {
        phase = .bootstrapping

        // Step 1: Resolve templateId and draft from intent
        let templateId: String
        let draft: ProjectDraft
        let slot: ActiveDraftSlot

        switch intent {
        case .template(let tplId):
            templateId = tplId
            let newDraft = ProjectDraft.create(for: tplId)
            slot = ActiveDraftSlot(
                entryContext: .newFromTemplate(templateId: tplId),
                sourceTemplateId: tplId,
                linkedSavedProjectId: nil,
                draft: newDraft
            )
            do {
                try deps.saveActiveDraft(slot)
            } catch {
                logger.error("[EditorSession] Failed to save active draft: \(error)")
            }
            draft = newDraft
            logger.info("[EditorSession] New from template: \(tplId), draft: \(newDraft.id)")

        case .savedProject(let projectId):
            guard let record = deps.loadSavedProject(projectId) else {
                let msg = "Project load failed"
                logger.error("[EditorSession] Cannot load saved project \(projectId)")
                phase = .failed(msg)
                onOutput?(.bootstrapFailed(msg))
                return
            }
            templateId = record.sourceTemplateId
            slot = ActiveDraftSlot(
                entryContext: .openSavedProject(projectId: projectId),
                sourceTemplateId: record.sourceTemplateId,
                linkedSavedProjectId: projectId,
                draft: record.draft
            )
            do {
                try deps.saveActiveDraft(slot)
            } catch {
                logger.error("[EditorSession] Failed to save active draft: \(error)")
            }
            draft = record.draft
            logger.info("[EditorSession] Opened saved project: \(projectId)")

        case .resumeDraft:
            guard let existingSlot = deps.loadActiveDraft() else {
                let msg = "No draft to resume"
                logger.error("[EditorSession] No active draft to resume")
                phase = .failed(msg)
                onOutput?(.bootstrapFailed(msg))
                return
            }
            slot = existingSlot
            templateId = existingSlot.sourceTemplateId
            draft = existingSlot.draft
            logger.info("[EditorSession] Resumed active draft: \(draft.id), template: \(templateId)")

        case .blankProject:
            let msg = "Blank project not yet supported"
            phase = .failed(msg)
            onOutput?(.bootstrapFailed(msg))
            return
        }

        activeDraftSlot = slot

        // Step 2: Load SceneLibrary
        let library: SceneLibrarySnapshot
        do {
            library = try await deps.loadSceneLibrary()
            logger.info("[EditorSession] SceneLibrary loaded: \(library.scenesById.count) scenes")
        } catch {
            let msg = "Scene library load failed"
            logger.error("[EditorSession] Failed to load SceneLibrary: \(error)")
            phase = .failed(msg)
            onOutput?(.bootstrapFailed(msg))
            return
        }

        // Step 3: Load template catalog + resolve defaults
        var defaultSceneSequence: [SceneTypeDefault]

        let catalogResult = await deps.loadTemplateCatalog()
        switch catalogResult {
        case .failure(let catalogError):
            if draft.canonicalTimeline.sceneItems.isEmpty {
                let msg = "Catalog load failed"
                logger.error("[EditorSession] Catalog load failed and draft has no timeline: \(catalogError)")
                phase = .failed(msg)
                onOutput?(.bootstrapFailed(msg))
                return
            }
            logger.warning("[EditorSession] Catalog load failed, using draft timeline: \(catalogError)")
            defaultSceneSequence = []

        case .success:
            do {
                defaultSceneSequence = try deps.sceneTypeDefaults(templateId, library)
                logger.info("[EditorSession] Template loaded: \(defaultSceneSequence.count) scenes")
            } catch {
                if draft.canonicalTimeline.sceneItems.isEmpty {
                    let msg: String
                    if let catalogError = error as? TemplateCatalogError {
                        switch catalogError {
                        case .templateNotFound: msg = "Template not found"
                        case .emptySceneList: msg = "Template has no scenes"
                        case .sceneNotInLibrary: msg = "Template is unavailable"
                        }
                    } else {
                        msg = "Template not found"
                    }
                    logger.error("[EditorSession] Template not in catalog and draft has no timeline: \(error)")
                    phase = .failed(msg)
                    onOutput?(.bootstrapFailed(msg))
                    return
                }
                logger.warning("[EditorSession] Template '\(templateId)' not in catalog, using draft timeline")
                defaultSceneSequence = []
            }
        }

        // Step 4: Determine first scene
        let firstSceneTypeId: String
        if let draftFirst = draft.canonicalTimeline.firstSceneTypeId {
            firstSceneTypeId = draftFirst
            logger.info("[EditorSession] Using first scene from draft: \(firstSceneTypeId)")
        } else if let defaultFirst = defaultSceneSequence.first?.sceneTypeId {
            firstSceneTypeId = defaultFirst
            logger.info("[EditorSession] Using first scene from template defaults: \(firstSceneTypeId)")
        } else {
            let msg = "Empty project"
            logger.error("[EditorSession] No scenes in draft or template defaults")
            phase = .failed(msg)
            onOutput?(.bootstrapFailed(msg))
            return
        }

        // Step 5: Create EditorStore
        let fps = library.fps
        let editorStore = EditorStore.create(
            draft: draft,
            templateFPS: fps,
            defaultSceneSequence: defaultSceneSequence
        )
        self.store = editorStore
        self.dirtyState = EditorSessionDirtyState(
            baseline: EditorSessionSnapshot(from: editorStore.state)
        )

        let editor = BootstrappedEditor(
            activeDraftSlot: slot,
            templateId: templateId,
            draft: draft,
            sceneLibrary: library,
            defaultSceneSequence: defaultSceneSequence,
            firstSceneTypeId: firstSceneTypeId
        )
        phase = .ready(editor)
        onOutput?(.bootstrapSucceeded(editor))
    }

    // MARK: - Checkpoint

    /// Saves current draft to the recovery slot if changed since last recovery write.
    /// Self-contained — reads store state directly, no closure params needed.
    @discardableResult
    func persistCheckpointIfNeeded() -> Bool {
        guard let store = store,
              var slot = activeDraftSlot,
              var dirtyState = dirtyState else { return false }
        let current = EditorSessionSnapshot(from: store.state)
        guard dirtyState.needsRecoveryWrite(current: current) else { return false }
        slot.draft = store.currentDraft
        slot.draft.updatedAt = Date()
        do {
            try deps.saveActiveDraft(slot)
            activeDraftSlot = slot
            dirtyState.didWriteRecovery(current: current)
            self.dirtyState = dirtyState
            return true
        } catch {
            logger.error("[EditorSession] Checkpoint save error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Export Commit

    /// Materializes saved project after successful export and clears recovery slot.
    func commitAfterExportSuccess() {
        guard let store = store, var slot = activeDraftSlot else { return }
        let current = EditorSessionSnapshot(from: store.state)
        slot.draft = store.currentDraft
        slot.draft.updatedAt = Date()
        do {
            try deps.materializeSavedProject(&slot)
            activeDraftSlot = slot
            try deps.deleteActiveDraft()
            dirtyState?.didMaterialize(current: current)
        } catch {
            logger.error("[EditorSession] Export commit error: \(error.localizedDescription)")
        }
    }

    // MARK: - Close

    /// Returns whether the UI should prompt the user or just pop.
    /// Uses dual-baseline dirty model: clean = current matches materialized baseline.
    func requestClose() -> EditorCloseAction {
        guard let store = store, let dirtyState = dirtyState else { return .safeToClose }
        let current = EditorSessionSnapshot(from: store.state)
        return dirtyState.isDirtyForUser(current: current) ? .needsUserDecision : .safeToClose
    }

    /// Save + materialize + delete active draft (user chose "Save" in close alert).
    func executeSaveAndClose() throws {
        guard let store = store, var slot = activeDraftSlot else { return }
        slot.draft = store.currentDraft
        slot.draft.updatedAt = Date()
        try deps.materializeSavedProject(&slot)
        try deps.deleteActiveDraft()
    }

    /// Delete active draft without saving (user chose "Don't Save" in close alert).
    func executeDiscardAndClose() throws {
        try deps.deleteActiveDraft()
    }
}

// MARK: - EditorStoreCallbacks

/// Callback struct that replaces direct store callback wiring.
/// Constructed by the view controller and passed to `EditorSession.setStoreCallbacks(_:)`.
@MainActor
struct EditorStoreCallbacks {
    var onPlayheadChanged: ((Int) -> Void)?
    var onSelectionChanged: ((TimelineSelection?) -> Void)?
    var onTimelineChanged: ((EditorState) -> Void)?
    var onTimelinePreviewChanged: ((EditorState) -> Void)?
    var onUndoRedoChanged: ((_ canUndo: Bool, _ canRedo: Bool) -> Void)?
    var onUIModeChanged: ((EditorUIMode) -> Void)?
    var onSelectedBlockChanged: ((String?) -> Void)?
    var onStateRestoredFromUndoRedo: (() -> Void)?
    var onSceneStateChanged: ((_ instanceId: UUID, _ sceneState: SceneState) -> Void)?
    var onVideoSelectionChanged: ((_ instanceId: UUID, _ blockId: String, _ selection: PersistedVideoSelection) -> Void)?
    var onMediaSlotChanged: ((_ instanceId: UUID, _ blockId: String, _ slot: SceneMediaSlot?) -> Void)?
    var onMediaPlacementChanged: ((_ instanceId: UUID, _ blockId: String, _ placement: MediaPlacementState) -> Void)?
    var onMediaVisibilityChanged: ((_ instanceId: UUID, _ blockId: String, _ visible: Bool) -> Void)?
    var onNotice: ((EditorNotice) -> Void)?
}
