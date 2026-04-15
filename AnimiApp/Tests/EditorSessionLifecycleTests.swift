import XCTest
import TVECore
@testable import AnimiApp

@MainActor
final class EditorSessionLifecycleTests: XCTestCase {

    // MARK: - Helpers

    private func makeDeps(
        saveActiveDraft: @escaping (ActiveDraftSlot) async throws -> Void = { _ in },
        deleteActiveDraft: @escaping () async throws -> Void = {},
        materializeSavedProject: @escaping (ActiveDraftSlot) async throws -> ActiveDraftSlot = { $0 }
    ) -> EditorSessionDependencies {
        EditorSessionDependencies(
            saveActiveDraft: saveActiveDraft,
            loadActiveDraft: { nil },
            deleteActiveDraft: deleteActiveDraft,
            loadSavedProject: { _ in nil },
            materializeSavedProject: materializeSavedProject,
            mediaLocator: StubMediaLocator(),
            mediaWriter: StubMediaWriter(),
            loadSceneLibrary: { Self.stubSceneLibrary() },
            sceneTypeDefaults: { _, _ in
                [SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: 3_000_000)]
            },
            loadTemplateCatalog: {
                .success(TemplateCatalogSnapshot(categories: [], templates: []))
            },
            backgroundPresetProvider: StubPresetProvider()
        )
    }

    private static func stubSceneLibrary() -> SceneLibrarySnapshot {
        SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: [
                SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
            ]
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

    // MARK: - Store Ownership

    func testBootstrap_createsStoreAndDirtyState() async {
        let session = await makeBootstrappedSession()
        XCTAssertNotNil(session.state, "Store state should be accessible after bootstrap")
    }

    func testState_reflectsChanges() async {
        let session = await makeBootstrappedSession()
        let sceneCountBefore = session.state?.sceneItems.count ?? 0

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        let sceneCountAfter = session.state?.sceneItems.count ?? 0
        XCTAssertEqual(sceneCountAfter, sceneCountBefore + 1, "State should reflect dispatched changes")
    }

    // MARK: - Full Lifecycle

    func testFullLifecycle_bootstrap_mutate_checkpoint_close() async {
        var saveCalls = 0
        let session = await makeBootstrappedSession(saveActiveDraft: { _ in saveCalls += 1 })

        // 1. Initially clean
        XCTAssertEqual(session.requestClose(), .safeToClose)

        // 2. Mutate
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        // 3. Checkpoint (autosave)
        let initialSaves = saveCalls
        let saved = await session.persistCheckpointIfNeeded()
        XCTAssertTrue(saved)
        XCTAssertEqual(saveCalls, initialSaves + 1)

        // 4. Still dirty for user after autosave
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        // 5. Save and close
        try! await session.executeSaveAndClose()
    }

    func testBackgroundPresetProvider_exposedFromDeps() async {
        let session = await makeBootstrappedSession()
        XCTAssertEqual(session.backgroundPresetProvider.count, 0)
    }

    // MARK: - Behavioral Contract Tests

    func testMultipleCheckpoints_withoutMutation_secondIsNoOp() async {
        var saveCount = 0
        let session = await makeBootstrappedSession(saveActiveDraft: { _ in saveCount += 1 })

        // Mutate to make dirty
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))

        // First checkpoint should save
        let saved1 = await session.persistCheckpointIfNeeded()
        XCTAssertTrue(saved1)
        let countAfterFirst = saveCount

        // Second checkpoint without further mutation — should be a no-op
        let saved2 = await session.persistCheckpointIfNeeded()
        XCTAssertFalse(saved2)
        XCTAssertEqual(saveCount, countAfterFirst, "Save count should not increase on redundant checkpoint")
    }

    func testUndoAfterCheckpoint_dirtyRelativeToMaterializedBaseline() async {
        let session = await makeBootstrappedSession()

        // Mutate
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        // Checkpoint (recovery write)
        await session.persistCheckpointIfNeeded()

        // Undo reverts to the bootstrapped state — which is the materialized baseline
        session.dispatch(.undo)
        XCTAssertEqual(session.requestClose(), .safeToClose, "After undoing back to baseline, session should be safe to close")
    }

    func testSaveAndClose_verifiesMaterializeDeleteAndSavedContent() async {
        var materializeCalled = false
        var deleteCalled = false
        var materializedDraft: ProjectDraft?

        let session = await makeBootstrappedSession(
            deleteActiveDraft: { deleteCalled = true },
            materializeSavedProject: { slot in
                materializeCalled = true
                materializedDraft = slot.draft
                return slot
            }
        )

        // Mutate — add a scene
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        let sceneCountAfterAdd = session.state?.sceneItems.count ?? 0

        // Save and close
        try! await session.executeSaveAndClose()

        XCTAssertTrue(materializeCalled, "executeSaveAndClose must call materializeSavedProject")
        XCTAssertTrue(deleteCalled, "executeSaveAndClose must call deleteActiveDraft")
        XCTAssertEqual(
            materializedDraft?.canonicalTimeline.sceneItems.count,
            sceneCountAfterAdd,
            "Materialized draft should contain the added scene"
        )
    }

    func testExportCommit_clearsUserDirty() async {
        let session = await makeBootstrappedSession(
            materializeSavedProject: { $0 }
        )

        // Mutate — dirty
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        // Export commit — materializes and resets baseline
        await session.commitAfterExportSuccess()
        XCTAssertEqual(session.requestClose(), .safeToClose, "After export commit, user-dirty should be cleared")
    }

    func testBootstrapFailure_emitsBootstrapFailedAndNoState() async {
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { $0 },
            mediaLocator: StubMediaLocator(),
            mediaWriter: StubMediaWriter(),
            loadSceneLibrary: { throw NSError(domain: "test", code: 1) },
            sceneTypeDefaults: { _, _ in [] },
            loadTemplateCatalog: { .success(TemplateCatalogSnapshot(categories: [], templates: [])) },
            backgroundPresetProvider: StubPresetProvider()
        )

        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        var emittedOutput: EditorSessionOutput?
        session.onOutput = { output in emittedOutput = output }

        await session.bootstrap()

        // Verify bootstrap failed
        if case .bootstrapFailed = emittedOutput {
            // expected
        } else {
            XCTFail("Expected .bootstrapFailed output, got \(String(describing: emittedOutput))")
        }

        XCTAssertNil(session.state, "State must be nil after bootstrap failure")
    }
}

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

private struct StubPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
