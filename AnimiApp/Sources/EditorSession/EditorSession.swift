import Foundation
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorSession")

/// Thin session boundary that owns bootstrap, checkpoint, export-commit, and close decisions.
/// The view controller becomes a consumer of session decisions rather than their source.
///
/// **PR 2 scope**: `currentDraft` and `isDirty` are passed as parameters, not owned.
/// `EditorStore` ownership moves in PR 3.
@MainActor
final class EditorSession {

    let intent: EditorLaunchIntent
    private let deps: EditorSessionDependencies

    private(set) var phase: EditorSessionPhase = .idle
    /// Set during bootstrap, updated by checkpoint/export-commit. Writable from tests via @testable.
    var activeDraftSlot: ActiveDraftSlot?

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

    /// Saves current draft to the active slot if dirty.
    /// Returns true if checkpoint was actually saved.
    /// Extracted from PlayerViewController.saveDraftToActiveSlot() lines 2536–2549.
    @discardableResult
    func persistCheckpointIfNeeded(currentDraft: () -> ProjectDraft?, isDirty: Bool) -> Bool {
        guard isDirty,
              var slot = activeDraftSlot,
              let draft = currentDraft() else { return false }
        slot.draft = draft
        slot.draft.updatedAt = Date()
        do {
            try deps.saveActiveDraft(slot)
            activeDraftSlot = slot
            return true
        } catch {
            logger.error("[EditorSession] Checkpoint save error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Export Commit

    /// Materializes saved project after successful export.
    /// Extracted from PlayerViewController.handleExportSuccess() lines 1041–1053.
    func commitAfterExportSuccess(currentDraft: () -> ProjectDraft?) {
        guard var slot = activeDraftSlot,
              let draft = currentDraft() else { return }
        slot.draft = draft
        slot.draft.updatedAt = Date()
        do {
            try deps.materializeSavedProject(&slot)
            activeDraftSlot = slot
            try deps.saveActiveDraft(slot)
        } catch {
            logger.error("[EditorSession] Export commit error: \(error.localizedDescription)")
        }
    }

    // MARK: - Close

    /// Returns whether the UI should prompt the user or just pop.
    ///
    /// PR 2: Always returns `.needsUserDecision`. The current `draftIsDirty` flag
    /// cannot distinguish explicit save from autosave checkpoint, so using it here
    /// would let autosave silently suppress the close prompt.
    /// PR 3 introduces the dual-baseline dirty model and enables `.safeToClose`.
    func requestClose(isDirty: Bool) -> EditorCloseAction {
        // Conservative: always prompt until PR 3 dual-baseline dirty model.
        .needsUserDecision
    }

    /// Save + materialize + delete active draft (user chose "Save" in close alert).
    /// Extracted from PlayerViewController.saveAndClose() lines 1001–1021.
    func executeSaveAndClose(currentDraft: () -> ProjectDraft?) throws {
        guard var slot = activeDraftSlot,
              let draft = currentDraft() else { return }
        slot.draft = draft
        slot.draft.updatedAt = Date()
        try deps.materializeSavedProject(&slot)
        try deps.deleteActiveDraft()
    }

    /// Delete active draft without saving (user chose "Don't Save" in close alert).
    /// Extracted from PlayerViewController.discardAndClose() lines 1023–1028.
    func executeDiscardAndClose() throws {
        try deps.deleteActiveDraft()
    }
}
