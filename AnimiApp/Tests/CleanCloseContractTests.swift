import XCTest
import TVECore
@testable import AnimiApp

@MainActor
final class CleanCloseContractTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrappedSession() async -> EditorSession {
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { _ in },
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

    // MARK: - Clean Close

    func testCleanSession_safeToClose() async {
        let session = await makeBootstrappedSession()
        XCTAssertEqual(session.requestClose(), .safeToClose)
    }

    func testDirtySession_needsUserDecision() async {
        let session = await makeBootstrappedSession()
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision)
    }

    func testPlayheadOnlyChange_staysClean() async {
        let session = await makeBootstrappedSession()
        session.dispatch(.setPlayhead(compressedFrame: 10))
        XCTAssertEqual(session.requestClose(), .safeToClose,
            "Playhead-only changes should not dirty the session")
    }

    func testSelectionOnlyChange_staysClean() async {
        let session = await makeBootstrappedSession()
        session.dispatch(.select(selection: .none))
        XCTAssertEqual(session.requestClose(), .safeToClose,
            "Selection-only changes should not dirty the session")
    }

    func testUndoBackToBaseline_becomesClean() async {
        let session = await makeBootstrappedSession()
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        session.dispatch(.undo)
        XCTAssertEqual(session.requestClose(), .safeToClose,
            "Undoing back to baseline should make session clean")
    }

    func testBackgroundChange_makesDirty() async {
        let session = await makeBootstrappedSession()
        var bg = ProjectBackgroundOverride.empty
        bg.selectedPresetId = "new_preset"
        session.dispatch(.setBackground(bg))
        XCTAssertEqual(session.requestClose(), .needsUserDecision,
            "Background change should dirty the session")
    }

    func testNoStore_safeToClose() {
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { _ in },
            loadSceneLibrary: { Self.stubSceneLibrary() },
            sceneTypeDefaults: { _, _ in [] },
            loadTemplateCatalog: { .success(TemplateCatalogSnapshot(categories: [], templates: [])) },
            backgroundPresetProvider: StubPresetProvider()
        )
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        // No bootstrap — no store
        XCTAssertEqual(session.requestClose(), .safeToClose)
    }
}

private struct StubPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
