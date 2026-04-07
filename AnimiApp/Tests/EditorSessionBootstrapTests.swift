import XCTest
import TVECore
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
            .success(TemplateCatalogSnapshot(categories: [], templates: []))
        },
        backgroundPresetProvider: BackgroundPresetProviding = StubBackgroundPresetProvider()
    ) -> EditorSessionDependencies {
        EditorSessionDependencies(
            saveActiveDraft: saveActiveDraft,
            loadActiveDraft: loadActiveDraft,
            deleteActiveDraft: deleteActiveDraft,
            loadSavedProject: loadSavedProject,
            materializeSavedProject: materializeSavedProject,
            loadSceneLibrary: loadSceneLibrary,
            sceneTypeDefaults: sceneTypeDefaults,
            loadTemplateCatalog: loadTemplateCatalog,
            backgroundPresetProvider: backgroundPresetProvider
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

    /// Bootstraps a session and returns it ready for lifecycle tests.
    private func makeBootstrappedSession(
        saveActiveDraft: @escaping (ActiveDraftSlot) throws -> Void = { _ in },
        deleteActiveDraft: @escaping () throws -> Void = {},
        materializeSavedProject: @escaping (inout ActiveDraftSlot) throws -> Void = { _ in }
    ) async -> EditorSession {
        let deps = makeDeps(
            saveActiveDraft: saveActiveDraft,
            deleteActiveDraft: deleteActiveDraft,
            materializeSavedProject: materializeSavedProject
        )
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        await session.bootstrap()
        return session
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

    func testBootstrapTemplate_createsEditorStore() async {
        let session = await makeBootstrappedSession()
        XCTAssertNotNil(session.state, "Store should be created during bootstrap (state accessible via proxy)")
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

    // MARK: - Checkpoint Tests (PR3: self-contained, no params)

    func testPersistCheckpoint_savesWhenDirty() async {
        var savedSlot: ActiveDraftSlot?
        let session = await makeBootstrappedSession(saveActiveDraft: { savedSlot = $0 })

        // Mutate the store to make it differ from baseline
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))

        let saved = session.persistCheckpointIfNeeded()
        XCTAssertTrue(saved)
        XCTAssertNotNil(savedSlot)
    }

    func testPersistCheckpoint_skipsWhenClean() async {
        var saveCount = 0
        let session = await makeBootstrappedSession(saveActiveDraft: { _ in saveCount += 1 })

        // Don't mutate — should be clean
        let initialSaveCount = saveCount // bootstrap may have saved
        let saved = session.persistCheckpointIfNeeded()
        XCTAssertFalse(saved)
        XCTAssertEqual(saveCount, initialSaveCount)
    }

    // MARK: - Export Commit Tests

    func testCommitAfterExport_materializesAndDeletesDraft() async {
        var materializeCalled = false
        var deleteCalled = false
        let session = await makeBootstrappedSession(
            deleteActiveDraft: { deleteCalled = true },
            materializeSavedProject: { _ in materializeCalled = true }
        )

        session.commitAfterExportSuccess()

        XCTAssertTrue(materializeCalled)
        XCTAssertTrue(deleteCalled)
    }

    // MARK: - Close Tests (PR3: dual-baseline dirty model)

    func testRequestClose_cleanSession_safeToClose() async {
        let session = await makeBootstrappedSession()
        // No mutations — should be clean
        let action = session.requestClose()
        XCTAssertEqual(action, .safeToClose)
    }

    func testRequestClose_dirtySession_needsUserDecision() async {
        let session = await makeBootstrappedSession()
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        let action = session.requestClose()
        XCTAssertEqual(action, .needsUserDecision)
    }

    func testCheckpointThenClose_stillNeedsUserDecision() async {
        let session = await makeBootstrappedSession()

        // Mutate and checkpoint
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        let saved = session.persistCheckpointIfNeeded()
        XCTAssertTrue(saved, "Checkpoint should succeed")

        // After checkpoint, session is still dirty for user (autosave != explicit save)
        let action = session.requestClose()
        XCTAssertEqual(action, .needsUserDecision,
            "Autosave checkpoint must not suppress close prompt")
    }

    func testExecuteSaveAndClose_materializesAndDeletesDraft() async {
        var materializeCalled = false
        var deleteCalled = false
        let session = await makeBootstrappedSession(
            deleteActiveDraft: { deleteCalled = true },
            materializeSavedProject: { _ in materializeCalled = true }
        )

        XCTAssertNoThrow(try session.executeSaveAndClose())
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

// MARK: - Stub Background Preset Provider

private struct StubBackgroundPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
