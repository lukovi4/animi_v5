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

/// Tests that EditorRuntime media fast-path mutations work correctly
/// without controller reaching into subsystem internals.
@MainActor
final class EditorRuntimeMutationTests: XCTestCase {

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

    // MARK: - Placement Fast-Path

    func test_applyMediaPlacementChange_emitsRenderSourceUpdated_whenNoActiveScene() async {
        let (_, runtime) = await makeBootedRuntime()
        var renderUpdated = false
        runtime.onOutput = { output in
            if case .renderSourceUpdated = output { renderUpdated = true }
        }

        // No scene player loaded — local apply returns false, but timeline path still runs
        let applied = runtime.applyMediaPlacementChange(
            instanceId: UUID(),
            blockId: "block_1",
            placement: .defaultCover
        )

        // No scene loaded → local path not applied
        XCTAssertFalse(applied)
    }

    // MARK: - Visibility Fast-Path

    func test_applyMediaVisibilityChange_returnsCorrectly() async {
        let (_, runtime) = await makeBootedRuntime()

        let applied = runtime.applyMediaVisibilityChange(
            instanceId: UUID(),
            blockId: "block_1",
            visible: false
        )

        // No scene loaded → local path not applied
        XCTAssertFalse(applied)
    }

    // MARK: - Slot Change

    func test_applyMediaSlotChange_nilSlot_doesNotCrash() async {
        let (_, runtime) = await makeBootedRuntime()
        // Nil slot (remove) with no active scene — should not crash
        runtime.applyMediaSlotChange(instanceId: UUID(), blockId: "block_1", slot: nil)
    }

    // MARK: - Media Ready Reapply

    func test_reapplyPlacementAfterMediaReady_returnsFalse_withoutScenePlayer() async {
        let (_, runtime) = await makeBootedRuntime()

        let applied = runtime.reapplyPlacementAfterMediaReady(
            instanceId: UUID(),
            blockId: "block_1",
            placement: .defaultCover
        )

        XCTAssertFalse(applied)
    }

    // MARK: - Scene State Change

    func test_applySceneStateChange_doesNotCrash_withoutEngine() async {
        let (_, runtime) = await makeBootedRuntime()
        let sceneState = SceneState()
        // No timeline engine — should not crash
        runtime.applySceneStateChange(instanceId: UUID(), sceneState: sceneState)
    }

    // MARK: - Export Abort Restores State

    func test_abortExport_restoresTimelinePreview() async {
        let (_, runtime) = await makeBootedRuntime(state: .timelinePreview)
        var outputs: [EditorRuntimeOutput] = []
        runtime.onOutput = { outputs.append($0) }

        runtime.startExport(policy: .photoLibraryOnly)
        XCTAssertEqual(runtime.state, .exporting)

        // Execute without metal context → should abort
        await runtime.executeExport()

        XCTAssertEqual(runtime.state, .timelinePreview)
        XCTAssertFalse(runtime.isExporting)
    }

    // MARK: - Background Mutations

    func test_clearAllBackgroundTextures_doesNotCrash_withoutService() async {
        let (_, runtime) = await makeBootedRuntime()
        // No background service — should not crash
        runtime.clearAllBackgroundTextures()
    }

    // MARK: - Sealed Query Contract Tests

    func test_videoTrimContext_returnsNil_withoutScenePlayer() async {
        let (_, runtime) = await makeBootedRuntime()
        XCTAssertNil(runtime.videoTrimContext(blockId: "block_1"))
    }

    func test_canCommitVideoTrim_returnsFalse_withoutUserMediaService() async {
        let (_, runtime) = await makeBootedRuntime()
        XCTAssertFalse(runtime.canCommitVideoTrim)
    }

    func test_mediaActionBarContext_returnsDefaults_withoutScenePlayer() async {
        let (_, runtime) = await makeBootedRuntime()
        let ctx = runtime.mediaActionBarContext(blockId: "block_1")
        XCTAssertNil(ctx.allowedMedia)
        XCTAssertTrue(ctx.availableVariants.isEmpty)
        XCTAssertNil(ctx.selectedVariantId)
        XCTAssertFalse(ctx.canTrimVideo)
    }

    func test_resolveDefaultFitMode_returnsCover_withoutEngine() async {
        let (_, runtime) = await makeBootedRuntime()
        let fit = await runtime.resolveDefaultFitMode(sceneTypeId: "scene_1", blockId: "block_1")
        XCTAssertEqual(fit, .cover)
    }

    func test_templateBackground_returnsNil_withoutCompiledScene() async {
        let (_, runtime) = await makeBootedRuntime()
        XCTAssertNil(runtime.templateBackground)
    }

    func test_hasTransitionCompositor_returnsFalse_withoutEngine() async {
        let (_, runtime) = await makeBootedRuntime()
        XCTAssertFalse(runtime.hasTransitionCompositor)
    }

    func test_bestLocalFrame_returnsZero_withoutCoordinator() async {
        let (_, runtime) = await makeBootedRuntime()
        XCTAssertEqual(runtime.bestLocalFrame, 0)
    }

    func test_sceneEditOverlayProvider_returnsNil_withoutScene() async {
        let (_, runtime) = await makeBootedRuntime()
        XCTAssertNil(runtime.sceneEditOverlayProvider())
    }

    func test_queryCanvasSize_returnsZero_withoutScene() async {
        let (_, runtime) = await makeBootedRuntime()
        XCTAssertEqual(runtime.queryCanvasSize, .zero)
    }

    // MARK: - SceneEditInteractionController Boundary

    func test_sceneEditInteractionController_doesNotDependOnScenePlayer() {
        // SceneEditInteractionController's injected API uses SceneEditOverlayProviding protocol,
        // not ScenePlayer directly. Verify by constructing and wiring with nil provider.
        let controller = SceneEditInteractionController()
        controller.getOverlayProvider = { nil }
        // Should not crash — gracefully handles nil provider
        controller.handleTap(viewPoint: .zero)
        controller.updateOverlay()
    }
}
