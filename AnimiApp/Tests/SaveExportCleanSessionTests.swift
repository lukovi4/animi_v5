import XCTest
import TVECore
@testable import AnimiApp

@MainActor
final class SaveExportCleanSessionTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrappedSession(
        saveActiveDraft: @escaping (ActiveDraftSlot) throws -> Void = { _ in },
        deleteActiveDraft: @escaping () throws -> Void = {},
        materializeSavedProject: @escaping (inout ActiveDraftSlot) throws -> Void = { _ in }
    ) async -> EditorSession {
        let deps = EditorSessionDependencies(
            saveActiveDraft: saveActiveDraft,
            loadActiveDraft: { nil },
            deleteActiveDraft: deleteActiveDraft,
            loadSavedProject: { _ in nil },
            materializeSavedProject: materializeSavedProject,
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

        // Mutate
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        // Export commit
        session.commitAfterExportSuccess()

        // Now clean
        XCTAssertEqual(session.requestClose(), .safeToClose,
            "Export commit should clear dirty state")
    }

    func testExportCommit_deletesRecoverySlot() async {
        var deleteCalled = false
        let session = await makeBootstrappedSession(
            deleteActiveDraft: { deleteCalled = true }
        )

        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        session.commitAfterExportSuccess()

        XCTAssertTrue(deleteCalled, "Export commit should delete recovery slot")
    }

    func testExportCommit_thenMutate_dirtyAgain() async {
        let session = await makeBootstrappedSession()

        // Mutate, export
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        session.commitAfterExportSuccess()
        XCTAssertEqual(session.requestClose(), .safeToClose)

        // Mutate again
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision,
            "New mutation after export should be dirty")
    }

    // MARK: - Save And Close

    func testSaveAndClose_materializesAndDeletesDraft() async {
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
}

private struct StubPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
