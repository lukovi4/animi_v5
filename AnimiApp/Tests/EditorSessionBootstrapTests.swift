import XCTest
import TVECore
@testable import AnimiApp

@MainActor
final class EditorSessionBootstrapTests: XCTestCase {

    // MARK: - Stub Helpers

    private func makeDeps(
        saveActiveDraft: @escaping (ActiveDraftSlot) async throws -> Void = { _ in },
        loadActiveDraft: @escaping () async -> ActiveDraftSlot? = { nil },
        deleteActiveDraft: @escaping () async throws -> Void = {},
        loadSavedProject: @escaping (UUID) async -> SavedProjectRecord? = { _ in nil },
        materializeSavedProject: @escaping (ActiveDraftSlot) async throws -> ActiveDraftSlot = { $0 },
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
            mediaLocator: StubMediaLocator(),
            mediaWriter: StubMediaWriter(),
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
        ProjectDraft.create(origin: .template(templateId: templateId))
    }

    private static func stubSlot(templateId: String = "tpl_1") -> ActiveDraftSlot {
        ActiveDraftSlot(
            entryContext: .newProject(origin: .template(templateId: templateId)),
            linkedSavedProjectId: nil,
            draft: stubDraft(templateId: templateId)
        )
    }

    private func makeBootstrappedSession(
        saveActiveDraft: @escaping (ActiveDraftSlot) async throws -> Void = { _ in },
        deleteActiveDraft: @escaping () async throws -> Void = {},
        materializeSavedProject: @escaping (ActiveDraftSlot) async throws -> ActiveDraftSlot = { $0 }
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
        XCTAssertEqual(savedSlot?.draft.origin, .template(templateId: "tpl_1"))
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

    // MARK: - Non-Template Origin Tests

    func testBootstrapSavedProject_blankOrigin_nonEmptyTimeline_succeeds() async {
        let projectId = UUID()
        var timeline = CanonicalTimeline.empty()
        let pid = UUID()
        timeline.payloads[pid] = .scene(ScenePayload(sceneTypeId: "scene_1"))
        timeline.tracks[0].items.append(TimelineItem(payloadId: pid, kind: .scene, startUs: nil, durationUs: 2_000_000))

        let draft = ProjectDraft(
            id: projectId,
            origin: .blank(starterSceneTypeId: "scene_1"),
            canonicalTimeline: timeline
        )
        let record = SavedProjectRecord(savedAt: Date(), draft: draft)
        var sceneTypeDefaultsCalled = false
        let deps = makeDeps(
            loadSavedProject: { id in id == projectId ? record : nil },
            sceneTypeDefaults: { _, _ in
                sceneTypeDefaultsCalled = true
                return []
            }
        )
        let session = EditorSession(intent: .savedProject(projectId: projectId), dependencies: deps)
        await session.bootstrap()

        if case .ready(let editor) = session.phase {
            XCTAssertNil(editor.templateId, "Blank origin should have nil templateId")
        } else {
            XCTFail("Expected .ready phase, got \(session.phase)")
        }
        XCTAssertFalse(sceneTypeDefaultsCalled, "sceneTypeDefaults should not be called for non-template origin")
    }

    func testBootstrapResumeDraft_duplicateOrigin_succeeds() async {
        let sourceId = UUID()
        var timeline = CanonicalTimeline.empty()
        let pid = UUID()
        timeline.payloads[pid] = .scene(ScenePayload(sceneTypeId: "scene_1"))
        timeline.tracks[0].items.append(TimelineItem(payloadId: pid, kind: .scene, startUs: nil, durationUs: 2_000_000))

        let draft = ProjectDraft(
            origin: .duplicate(sourceProjectId: sourceId),
            canonicalTimeline: timeline
        )
        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: .duplicate(sourceProjectId: sourceId)),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let deps = makeDeps(loadActiveDraft: { slot })
        let session = EditorSession(intent: .resumeDraft, dependencies: deps)
        await session.bootstrap()

        if case .ready(let editor) = session.phase {
            XCTAssertNil(editor.templateId, "Duplicate origin should have nil templateId")
        } else {
            XCTFail("Expected .ready phase, got \(session.phase)")
        }
    }

    // MARK: - Checkpoint Tests (async)

    func testPersistCheckpoint_savesWhenDirty() async {
        var savedSlot: ActiveDraftSlot?
        let session = await makeBootstrappedSession(saveActiveDraft: { savedSlot = $0 })

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))

        let saved = await session.persistCheckpointIfNeeded()
        XCTAssertTrue(saved)
        XCTAssertNotNil(savedSlot)
    }

    func testPersistCheckpoint_skipsWhenClean() async {
        var saveCount = 0
        let session = await makeBootstrappedSession(saveActiveDraft: { _ in saveCount += 1 })

        let initialSaveCount = saveCount
        let saved = await session.persistCheckpointIfNeeded()
        XCTAssertFalse(saved)
        XCTAssertEqual(saveCount, initialSaveCount)
    }

    // MARK: - Export Commit Tests (async)

    func testCommitAfterExport_materializesAndDeletesDraft() async {
        var materializeCalled = false
        var deleteCalled = false
        let session = await makeBootstrappedSession(
            deleteActiveDraft: { deleteCalled = true },
            materializeSavedProject: { slot in materializeCalled = true; return slot }
        )

        await session.commitAfterExportSuccess()

        XCTAssertTrue(materializeCalled)
        XCTAssertTrue(deleteCalled)
    }

    // MARK: - Close Tests (async)

    func testRequestClose_cleanSession_safeToClose() async {
        let session = await makeBootstrappedSession()
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

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        let saved = await session.persistCheckpointIfNeeded()
        XCTAssertTrue(saved, "Checkpoint should succeed")

        let action = session.requestClose()
        XCTAssertEqual(action, .needsUserDecision,
            "Autosave checkpoint must not suppress close prompt")
    }

    func testExecuteSaveAndClose_materializesAndDeletesDraft() async throws {
        var materializeCalled = false
        var deleteCalled = false
        let session = await makeBootstrappedSession(
            deleteActiveDraft: { deleteCalled = true },
            materializeSavedProject: { slot in materializeCalled = true; return slot }
        )

        try await session.executeSaveAndClose()
        XCTAssertTrue(materializeCalled)
        XCTAssertTrue(deleteCalled)
    }

    func testExecuteDiscardAndClose_deletesDraft() async throws {
        var deleteCalled = false
        let deps = makeDeps(deleteActiveDraft: { deleteCalled = true })
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)

        try await session.executeDiscardAndClose()
        XCTAssertTrue(deleteCalled)
    }
}

// MARK: - Stub Media Helpers

private struct StubMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/stub")
    }
}

private struct StubMediaWriter: ProjectMediaWriteGateway {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func deleteMediaFile(_ mediaRef: MediaRef) async throws {}
    func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft { sourceDraft }
}

// MARK: - Stub Background Preset Provider

private struct StubBackgroundPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
