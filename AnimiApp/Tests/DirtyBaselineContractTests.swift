import XCTest
import TVECore
@testable import AnimiApp

@MainActor
final class DirtyBaselineContractTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrappedSession(
        saveActiveDraft: @escaping (ActiveDraftSlot) async throws -> Void = { _ in }
    ) async -> EditorSession {
        let deps = EditorSessionDependencies(
            saveActiveDraft: saveActiveDraft,
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { $0 },
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
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        await session.bootstrap()
        return session
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

    // MARK: - Dual Baseline Tests

    func testAutosave_doesNotClearUserDirty() async {
        let session = await makeBootstrappedSession()

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        let saved = await session.persistCheckpointIfNeeded()
        XCTAssertTrue(saved)

        XCTAssertEqual(session.requestClose(), .needsUserDecision,
            "Autosave must not clear user-facing dirty state")
    }

    func testAutosave_preventsRedundantRecoveryWrite() async {
        var saveCount = 0
        let session = await makeBootstrappedSession(saveActiveDraft: { _ in saveCount += 1 })

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))

        let beforeCount = saveCount
        let checkpointResult = await session.persistCheckpointIfNeeded()
        XCTAssertTrue(checkpointResult)
        XCTAssertEqual(saveCount, beforeCount + 1)

        let noWriteResult = await session.persistCheckpointIfNeeded()
        XCTAssertFalse(noWriteResult)
        XCTAssertEqual(saveCount, beforeCount + 1, "No redundant recovery write expected")
    }

    func testAutosave_thenMutate_thenAutosave_writesAgain() async {
        var saveCount = 0
        let session = await makeBootstrappedSession(saveActiveDraft: { _ in saveCount += 1 })

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        let before = saveCount
        let checkpointResult = await session.persistCheckpointIfNeeded()
        XCTAssertTrue(checkpointResult)

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        let checkpointResult2 = await session.persistCheckpointIfNeeded()
        XCTAssertTrue(checkpointResult2)
        XCTAssertEqual(saveCount, before + 2, "Each new mutation should trigger a new recovery write")
    }

    func testExportCommit_resetsBothBaselines() async {
        let session = await makeBootstrappedSession()

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))

        await session.persistCheckpointIfNeeded()
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        await session.commitAfterExportSuccess()
        XCTAssertEqual(session.requestClose(), .safeToClose,
            "Export should reset both baselines")

        let noWrite = await session.persistCheckpointIfNeeded()
        XCTAssertFalse(noWrite,
            "Recovery baseline should match current after export")
    }

    func testDirtyState_structuralEquality() {
        let draft1 = ProjectDraft.create(origin: .template(templateId: "tpl_1"))

        let state1 = EditorState(draft: draft1, templateFPS: 30)
        let state2 = EditorState(draft: draft1, templateFPS: 30)

        let snap1 = EditorSessionSnapshot(from: state1)
        let snap2 = EditorSessionSnapshot(from: state2)

        XCTAssertEqual(snap1, snap2,
            "Snapshots from identical state should be equal")

        var modified = state1
        modified.draft.canonicalTimeline = .empty()
        let snap3 = EditorSessionSnapshot(from: modified)

        if draft1.canonicalTimeline != .empty() {
            XCTAssertNotEqual(snap1, snap3)
        }
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
