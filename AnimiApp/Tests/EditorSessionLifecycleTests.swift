import XCTest
import TVECore
@testable import AnimiApp

@MainActor
final class EditorSessionLifecycleTests: XCTestCase {

    // MARK: - Helpers

    private func makeDeps(
        saveActiveDraft: @escaping (ActiveDraftSlot) throws -> Void = { _ in },
        deleteActiveDraft: @escaping () throws -> Void = {},
        materializeSavedProject: @escaping (inout ActiveDraftSlot) throws -> Void = { _ in }
    ) -> EditorSessionDependencies {
        EditorSessionDependencies(
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
        let saved = session.persistCheckpointIfNeeded()
        XCTAssertTrue(saved)
        XCTAssertEqual(saveCalls, initialSaves + 1)

        // 4. Still dirty for user after autosave
        XCTAssertEqual(session.requestClose(), .needsUserDecision)

        // 5. Save and close
        XCTAssertNoThrow(try session.executeSaveAndClose())
    }

    func testBackgroundPresetProvider_exposedFromDeps() async {
        let session = await makeBootstrappedSession()
        // Just verify it doesn't crash — the provider is accessible
        XCTAssertEqual(session.backgroundPresetProvider.count, 0)
    }
}

private struct StubPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
