import XCTest
import Metal
import TVECore
@testable import AnimiApp

// MARK: - Stubs

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

// MARK: - Helpers

@MainActor
private func makeSession() async -> EditorSession {
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

// MARK: - Tests

@MainActor
final class EditorExportFlowControllerTests: XCTestCase {

    // MARK: 1. restorePreviewRenderSurface sets paused=true and requests one render

    func test_restorePreviewRenderSurface_setsPausedAndRequestsRender() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal not available")
        }

        let session = await makeSession()
        let vc = EditorViewController(session: session)
        vc.loadViewIfNeeded()

        let controller = vc.exportFlowController

        // Simulate export started: continuous draw mode
        vc.setMetalViewPaused(false)
        XCTAssertFalse(vc.isMetalViewPausedForTesting, "Pre-condition: MTKView should be unpaused")

        let renderCountBefore = vc.requestRenderCallCountForTesting

        // Act
        controller.restorePreviewRenderSurfaceAfterExport()

        // Assert
        XCTAssertTrue(vc.isMetalViewPausedForTesting,
                       "MTKView must be paused (on-demand mode) after export restore")
        XCTAssertEqual(vc.requestRenderCallCountForTesting, renderCountBefore + 1,
                       "Exactly one render must be requested for the still frame")
    }

    // MARK: 2. handleExportRenderSucceeded restores on-demand rendering

    func test_exportSucceeded_restoresOnDemandRendering() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal not available")
        }

        let session = await makeSession()
        let vc = EditorViewController(session: session)
        vc.loadViewIfNeeded()

        vc.setMetalViewPaused(false)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).mp4")
        vc.exportFlowController.handleExportRenderSucceeded(tempURL)

        XCTAssertTrue(vc.isMetalViewPausedForTesting,
                       "MTKView must be paused after export succeeded")
    }

    // MARK: 3. handleExportRenderFailed restores on-demand rendering

    func test_exportFailed_restoresOnDemandRendering() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal not available")
        }

        let session = await makeSession()
        let vc = EditorViewController(session: session)
        vc.loadViewIfNeeded()

        vc.setMetalViewPaused(false)

        let error = NSError(domain: "test", code: 1)
        vc.exportFlowController.handleExportRenderFailed(error)

        XCTAssertTrue(vc.isMetalViewPausedForTesting,
                       "MTKView must be paused after export failed")
    }

    // MARK: 4. handleExportCancelled restores on-demand rendering

    func test_exportCancelled_restoresOnDemandRendering() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal not available")
        }

        let session = await makeSession()
        let vc = EditorViewController(session: session)
        vc.loadViewIfNeeded()

        vc.setMetalViewPaused(false)

        vc.exportFlowController.handleExportCancelled()

        XCTAssertTrue(vc.isMetalViewPausedForTesting,
                       "MTKView must be paused after export cancelled")
    }
}
