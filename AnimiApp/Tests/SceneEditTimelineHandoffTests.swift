import XCTest
import TVECore
@testable import AnimiApp

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

/// Tests scene-edit activation, render source transitions, and rapid switching.
@MainActor
final class SceneEditTimelineHandoffTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrappedSession() async -> EditorSession {
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { $0 },
            mediaLocator: StubMediaLocator(),
            mediaWriter: StubMediaWriter(),
            loadSceneLibrary: {
                SceneLibrarySnapshot(
                    fps: 30,
                    canvas: CanvasConfig(width: 1080, height: 1920),
                    scenes: [
                        SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
                    ]
                )
            },
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

    private func makeBootedRuntime(state: EditorRuntimeState = .timelinePreview) async -> (EditorSession, EditorRuntime) {
        let session = await makeBootstrappedSession()
        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: state)
        return (session, runtime)
    }

    // MARK: - Runtime Integration: State Transitions

    func test_deactivateSceneEdit_transitionsToTimelinePreview() async {
        let instanceId = UUID()
        let (_, runtime) = await makeBootedRuntime(state: .sceneEdit(instanceId: instanceId))

        runtime.deactivateSceneEdit()

        XCTAssertEqual(runtime.state, .timelinePreview)
    }

    func test_startExport_from_sceneEdit_restores_sceneEdit() async {
        let instanceId = UUID()
        let (_, runtime) = await makeBootedRuntime(state: .sceneEdit(instanceId: instanceId))

        runtime.startExport(policy: .photoLibraryOnly)
        XCTAssertEqual(runtime.state, .exporting)

        runtime.cancelExport()
        XCTAssertEqual(runtime.state, .sceneEdit(instanceId: instanceId))
    }

    func test_startExport_from_timelinePreview_restores_timelinePreview() async {
        let (_, runtime) = await makeBootedRuntime(state: .timelinePreview)

        runtime.startExport(policy: .photoLibraryOnly)
        XCTAssertEqual(runtime.state, .exporting)

        runtime.cancelExport()
        XCTAssertEqual(runtime.state, .timelinePreview)
    }

    // MARK: - State Transitions (unit-level, preserved)

    func test_idle_to_booting_to_timelinePreview() {
        var state: EditorRuntimeState = .idle
        XCTAssertEqual(state, .idle)
        state = .booting
        XCTAssertEqual(state, .booting)
        state = .timelinePreview
        XCTAssertEqual(state, .timelinePreview)
    }

    func test_rapid_sceneEdit_switching_replaces_instanceId() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        var state: EditorRuntimeState = .sceneEdit(instanceId: id1)
        state = .sceneEdit(instanceId: id2)
        state = .sceneEdit(instanceId: id3)
        XCTAssertEqual(state, .sceneEdit(instanceId: id3))
        XCTAssertNotEqual(state, .sceneEdit(instanceId: id1))
    }

    // MARK: - Render Source Transitions (preserved)

    func test_renderSource_transitions_timeline_to_sceneEdit() {
        var source: EditorRuntimeRenderSource = .none

        if case .none = source {} else { XCTFail("Expected .none") }

        let context = SceneRenderContext(
            commands: [],
            textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(),
            assetSizes: [:],
            localFrame: 0,
            canvasSize: SizeD(width: 100, height: 100),
            sceneInstanceId: UUID()
        )
        source = .timeline(TimelineRenderSourcePayload(
            resolvedFrame: .single(context),
            backgroundState: nil,
            backgroundTextureProvider: nil,
            diagnosticFrameTag: nil
        ))
        if case .timeline = source {} else { XCTFail("Expected .timeline") }

        source = .sceneEdit(SceneEditRenderSourcePayload(
            commands: [],
            textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(),
            assetSizes: [:],
            canvasSize: SizeD(width: 100, height: 100),
            backgroundState: nil,
            backgroundTextureProvider: nil
        ))
        if case .sceneEdit = source {} else { XCTFail("Expected .sceneEdit") }

        source = .none
        if case .none = source {} else { XCTFail("Expected .none") }
    }
}
