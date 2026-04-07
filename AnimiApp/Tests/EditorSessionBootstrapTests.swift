import XCTest
@testable import AnimiApp

@MainActor
final class EditorSessionBootstrapTests: XCTestCase {

    // MARK: - Stub Helpers

    /// Creates a minimal stub dependencies struct with all closures defaulting to no-ops or empty returns.
    /// Override individual closures per test.
    private func makeDeps(
        saveActiveDraft: @escaping (ActiveDraftSlot) throws -> Void = { _ in },
        loadActiveDraft: @escaping () -> ActiveDraftSlot? = { nil },
        deleteActiveDraft: @escaping () throws -> Void = {},
        loadSavedProject: @escaping (UUID) -> SavedProjectRecord? = { _ in nil },
        materializeSavedProject: @escaping (inout ActiveDraftSlot) throws -> Void = { _ in },
        loadSceneLibrary: @escaping () async throws -> SceneLibrarySnapshot = { stubSceneLibrary() },
        sceneTypeDefaults: @escaping (String, SceneLibrarySnapshot) throws -> [SceneTypeDefault] = { _, _ in
            [SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: 3_000_000)]
        },
        loadTemplateCatalog: @escaping () async -> Result<TemplateCatalogSnapshot, Error> = {
            // Return a minimal success — the session only checks success/failure, not snapshot contents.
            .success(TemplateCatalogSnapshot(categories: [], templates: []))
        }
    ) -> EditorSessionDependencies {
        EditorSessionDependencies(
            saveActiveDraft: saveActiveDraft,
            loadActiveDraft: loadActiveDraft,
            deleteActiveDraft: deleteActiveDraft,
            loadSavedProject: loadSavedProject,
            materializeSavedProject: materializeSavedProject,
            loadSceneLibrary: loadSceneLibrary,
            sceneTypeDefaults: sceneTypeDefaults,
            loadTemplateCatalog: loadTemplateCatalog
        )
    }

    private static func stubSceneLibrary() -> SceneLibrarySnapshot {
        SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: [
                SceneTypeDescriptor(
                    id: "scene_1",
                    order: 0,
                    title: "Test Scene",
                    baseDurationUs: 3_000_000
                )
            ]
        )
    }

    private static func stubDraft(templateId: String = "tpl_1") -> ProjectDraft {
        ProjectDraft.create(for: templateId)
    }

    private static func stubSlot(templateId: String = "tpl_1") -> ActiveDraftSlot {
        ActiveDraftSlot(
            entryContext: .newFromTemplate(templateId: templateId),
            sourceTemplateId: templateId,
            linkedSavedProjectId: nil,
            draft: stubDraft(templateId: templateId)
        )
    }

    // MARK: - Bootstrap Tests

    func testBootstrapTemplate_createsSlotAndSucceeds() async {
        var savedSlot: ActiveDraftSlot?
        let deps = makeDeps(saveActiveDraft: { savedSlot = $0 })
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)

        var receivedOutput: EditorSessionOutput?
        session.onOutput = { receivedOutput = $0 }

        await session.bootstrap()

        XCTAssertNotNil(savedSlot)
        XCTAssertEqual(savedSlot?.sourceTemplateId, "tpl_1")
        if case .ready(let editor) = session.phase {
            XCTAssertEqual(editor.templateId, "tpl_1")
            XCTAssertEqual(editor.firstSceneTypeId, "scene_1")
        } else {
            XCTFail("Expected .ready phase, got \(session.phase)")
        }
        if case .bootstrapSucceeded(let editor) = receivedOutput {
            XCTAssertEqual(editor.templateId, "tpl_1")
        } else {
            XCTFail("Expected .bootstrapSucceeded output")
        }
    }

    func testBootstrapSavedProject_loadsRecordAndSucceeds() async {
        let projectId = UUID()
        let draft = Self.stubDraft(templateId: "tpl_saved")
        let record = SavedProjectRecord(
            sourceTemplateId: "tpl_saved",
            savedAt: Date(),
            draft: draft
        )
        let deps = makeDeps(loadSavedProject: { id in
            id == projectId ? record : nil
        })
        let session = EditorSession(intent: .savedProject(projectId: projectId), dependencies: deps)

        await session.bootstrap()

        if case .ready(let editor) = session.phase {
            XCTAssertEqual(editor.templateId, "tpl_saved")
            XCTAssertEqual(editor.activeDraftSlot.linkedSavedProjectId, projectId)
        } else {
            XCTFail("Expected .ready phase, got \(session.phase)")
        }
    }

    func testBootstrapResumeDraft_loadsActiveDraftAndSucceeds() async {
        let slot = Self.stubSlot(templateId: "tpl_resume")
        let deps = makeDeps(loadActiveDraft: { slot })
        let session = EditorSession(intent: .resumeDraft, dependencies: deps)

        await session.bootstrap()

        if case .ready(let editor) = session.phase {
            XCTAssertEqual(editor.templateId, "tpl_resume")
        } else {
            XCTFail("Expected .ready phase, got \(session.phase)")
        }
    }

    func testBootstrapResumeDraft_noDraftOnDisk_fails() async {
        let deps = makeDeps(loadActiveDraft: { nil })
        let session = EditorSession(intent: .resumeDraft, dependencies: deps)

        var failMessage: String?
        session.onOutput = { output in
            if case .bootstrapFailed(let msg) = output { failMessage = msg }
        }

        await session.bootstrap()

        XCTAssertEqual(failMessage, "No draft to resume")
        if case .failed(let msg) = session.phase {
            XCTAssertEqual(msg, "No draft to resume")
        } else {
            XCTFail("Expected .failed phase")
        }
    }

    func testBootstrapTemplate_sceneLibraryFailure_fails() async {
        let deps = makeDeps(loadSceneLibrary: { throw NSError(domain: "test", code: 1) })
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)

        var failMessage: String?
        session.onOutput = { output in
            if case .bootstrapFailed(let msg) = output { failMessage = msg }
        }

        await session.bootstrap()

        XCTAssertEqual(failMessage, "Scene library load failed")
        if case .failed = session.phase { /* OK */ }
        else { XCTFail("Expected .failed phase") }
    }

    // MARK: - Checkpoint Tests

    func testPersistCheckpoint_savesWhenDirty() {
        var savedSlot: ActiveDraftSlot?
        let deps = makeDeps(saveActiveDraft: { savedSlot = $0 })
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        // Manually set activeDraftSlot via bootstrap side-channel
        let slot = Self.stubSlot()
        session.activeDraftSlot = slot

        let draft = Self.stubDraft()
        let saved = session.persistCheckpointIfNeeded(
            currentDraft: { draft },
            isDirty: true
        )

        XCTAssertTrue(saved)
        XCTAssertNotNil(savedSlot)
    }

    func testPersistCheckpoint_skipsWhenClean() {
        var saveCount = 0
        let deps = makeDeps(saveActiveDraft: { _ in saveCount += 1 })
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        session.activeDraftSlot = Self.stubSlot()

        let draft = Self.stubDraft()
        let saved = session.persistCheckpointIfNeeded(
            currentDraft: { draft },
            isDirty: false
        )

        XCTAssertFalse(saved)
        XCTAssertEqual(saveCount, 0)
    }

    // MARK: - Export Commit Tests

    func testCommitAfterExport_materializesAndSaves() {
        var materializeCalled = false
        var saveCalled = false
        let deps = makeDeps(
            saveActiveDraft: { _ in saveCalled = true },
            materializeSavedProject: { _ in materializeCalled = true }
        )
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        session.activeDraftSlot = Self.stubSlot()

        let draft = Self.stubDraft()
        session.commitAfterExportSuccess(currentDraft: { draft })

        XCTAssertTrue(materializeCalled)
        XCTAssertTrue(saveCalled)
    }

    // MARK: - Close Tests

    /// PR 2 conservative contract: requestClose always returns .needsUserDecision,
    /// regardless of isDirty. This ensures the VC always shows the save/discard prompt
    /// until PR 3 introduces the dual-baseline dirty model.
    func testRequestClose_dirtyReturnsNeedsDecision() {
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: makeDeps())
        let action = session.requestClose(isDirty: true)
        XCTAssertEqual(action, .needsUserDecision)
    }

    func testRequestClose_cleanStillReturnsNeedsDecision() {
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: makeDeps())
        let action = session.requestClose(isDirty: false)
        XCTAssertEqual(action, .needsUserDecision,
            "PR 2 conservative: always prompt, even when isDirty is false")
    }

    /// After autosave checkpoint clears isDirty, requestClose must still return
    /// .needsUserDecision — the session owns this decision, not the VC.
    func testCheckpointThenClose_stillReturnsNeedsDecision() {
        let deps = makeDeps()
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        session.activeDraftSlot = Self.stubSlot()

        let draft = Self.stubDraft()
        let saved = session.persistCheckpointIfNeeded(currentDraft: { draft }, isDirty: true)
        XCTAssertTrue(saved, "Checkpoint should succeed")

        // After checkpoint, VC sets draftIsDirty = false, then user closes.
        // Session must still prompt — autosave != explicit save.
        let action = session.requestClose(isDirty: false)
        XCTAssertEqual(action, .needsUserDecision,
            "Conservative close: autosave checkpoint must not suppress prompt")
    }

    func testExecuteSaveAndClose_materializesAndDeletesDraft() {
        var materializeCalled = false
        var deleteCalled = false
        let deps = makeDeps(
            deleteActiveDraft: { deleteCalled = true },
            materializeSavedProject: { _ in materializeCalled = true }
        )
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        session.activeDraftSlot = Self.stubSlot()

        let draft = Self.stubDraft()
        XCTAssertNoThrow(try session.executeSaveAndClose(currentDraft: { draft }))
        XCTAssertTrue(materializeCalled)
        XCTAssertTrue(deleteCalled)
    }

    func testExecuteDiscardAndClose_deletesDraft() {
        var deleteCalled = false
        let deps = makeDeps(deleteActiveDraft: { deleteCalled = true })
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)

        XCTAssertNoThrow(try session.executeDiscardAndClose())
        XCTAssertTrue(deleteCalled)
    }

}
