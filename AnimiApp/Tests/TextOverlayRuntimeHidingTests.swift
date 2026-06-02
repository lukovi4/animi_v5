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

/// Verifies the scoped overlay-hiding set that lets the live Core Animation layer
/// replace the committed Metal copy of a text overlay during a transform. The set
/// is mutated by begin/end and is empty otherwise — there is no per-`.changed`
/// render loop here, only set state and (in production) one scoped refresh.
@MainActor
final class TextOverlayRuntimeHidingTests: XCTestCase {

    private func makeBootedRuntime(state: EditorRuntimeState = .timelinePreview) async -> EditorRuntime {
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
                    scenes: [SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)]
                )
            },
            sceneTypeDefaults: { _, _ in [SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: 3_000_000)] },
            loadTemplateCatalog: { .success(TemplateCatalogSnapshot(categories: [], templates: [])) },
            backgroundPresetProvider: StubPresetProvider()
        )
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        await session.bootstrap()
        let runtime = EditorRuntime(session: session)
        runtime.bootForTesting(state: state)
        return runtime
    }

    func testBeginThenEnd_addsThenRemovesId() async {
        let runtime = await makeBootedRuntime()
        let id = UUID()
        XCTAssertTrue(runtime.liveHiddenOverlayIds.isEmpty)

        runtime.beginHidingOverlay(id)
        XCTAssertEqual(runtime.liveHiddenOverlayIds, [id], "begin hides exactly the requested id")

        runtime.endHidingOverlay(id)
        XCTAssertTrue(runtime.liveHiddenOverlayIds.isEmpty, "end restores the committed copy")
    }

    func testBegin_isIdempotent() async {
        let runtime = await makeBootedRuntime()
        let id = UUID()
        runtime.beginHidingOverlay(id)
        runtime.beginHidingOverlay(id)
        XCTAssertEqual(runtime.liveHiddenOverlayIds, [id])
    }

    func testEnd_unknownId_isNoOp() async {
        let runtime = await makeBootedRuntime()
        runtime.endHidingOverlay(UUID())
        XCTAssertTrue(runtime.liveHiddenOverlayIds.isEmpty)
    }

    /// Hiding is scoped to the live preview: outside timeline preview, begin does
    /// nothing (playback/scrub/export render every overlay normally).
    func testBegin_outsideTimelinePreview_isNoOp() async {
        let runtime = await makeBootedRuntime(state: .idle)
        runtime.beginHidingOverlay(UUID())
        XCTAssertTrue(runtime.liveHiddenOverlayIds.isEmpty)
    }
}
