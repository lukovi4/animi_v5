import XCTest
import TVECore
@testable import AnimiApp

@MainActor
final class SaveExportCleanSessionTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrappedSession(
        saveActiveDraft: @escaping (ActiveDraftSlot) async throws -> Void = { _ in },
        deleteActiveDraft: @escaping () async throws -> Void = {},
        materializeSavedProject: @escaping (ActiveDraftSlot) async throws -> ActiveDraftSlot = { $0 }
    ) async -> EditorSession {
        let deps = EditorSessionDependencies(
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

    // MARK: - Export Commit Clears Dirty State

    func testExportCommit_clearsDirtyState() async {
        let session = await makeBootstrappedSession()

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        await session.commitAfterExportSuccess()

        XCTAssertEqual(session.requestClose(), .safeToClose,
            "Export commit should clear dirty state")
    }

    func testExportCommit_deletesRecoverySlot() async {
        var deleteCalled = false
        let session = await makeBootstrappedSession(
            deleteActiveDraft: { deleteCalled = true }
        )

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        await session.commitAfterExportSuccess()

        XCTAssertTrue(deleteCalled, "Export commit should delete recovery slot")
    }

    func testExportCommit_thenMutate_dirtyAgain() async {
        let session = await makeBootstrappedSession()

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        await session.commitAfterExportSuccess()
        XCTAssertEqual(session.requestClose(), .safeToClose)

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision,
            "New mutation after export should be dirty")
    }

    // MARK: - Save And Close

    func testSaveAndClose_materializesAndDeletesDraft() async throws {
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
