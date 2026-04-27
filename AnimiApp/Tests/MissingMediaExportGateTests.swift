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

/// Tests the missing-media hard gate on export and pre/post-export state restore.
@MainActor
final class MissingMediaExportGateTests: XCTestCase {

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

    // MARK: - ActiveExportRequest Unit Tests (preserved)

    func test_isActive_matchingId() {
        let exporter = VideoExporter(mediaLocator: StubMediaLocator())
        let request = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporter, deliveryPolicy: .photoLibraryOnly)
        XCTAssertTrue(request.isActive(for: request.id))
    }

    func test_isActive_nonMatchingId() {
        let exporter = VideoExporter(mediaLocator: StubMediaLocator())
        let request = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: exporter, deliveryPolicy: .photoLibraryOnly)
        XCTAssertFalse(request.isActive(for: UUID()))
    }

    func test_cancelA_startB_staleCompletionIgnored() {
        let requestA = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: VideoExporter(mediaLocator: StubMediaLocator()), deliveryPolicy: .photoLibraryOnly)
        let requestAId = requestA.id
        let requestB = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: VideoExporter(mediaLocator: StubMediaLocator()), deliveryPolicy: .photoLibraryOnly)
        XCTAssertFalse(requestB.isActive(for: requestAId))
        XCTAssertTrue(requestB.isActive(for: requestB.id))
    }

    func test_cancelDuringPreload_nilActiveRequest() {
        let activeRequest: EditorRuntime.ActiveExportRequest? = nil
        let requestId = UUID()
        let shouldProceed = activeRequest?.isActive(for: requestId) ?? false
        XCTAssertFalse(shouldProceed)
    }

    func test_cancelClosure_onlyClears_matchingRequest() {
        let requestA = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: VideoExporter(mediaLocator: StubMediaLocator()), deliveryPolicy: .photoLibraryOnly)
        let requestAId = requestA.id
        let requestB = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: VideoExporter(mediaLocator: StubMediaLocator()), deliveryPolicy: .photoLibraryOnly)
        var activeRequest: EditorRuntime.ActiveExportRequest? = requestB

        if activeRequest?.isActive(for: requestAId) == true {
            activeRequest = nil
        }

        XCTAssertNotNil(activeRequest)
        XCTAssertEqual(activeRequest?.id, requestB.id)
    }

    func test_staleProgress_gatedByRequestId() {
        let requestA = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: VideoExporter(mediaLocator: StubMediaLocator()), deliveryPolicy: .photoLibraryOnly)
        let requestAId = requestA.id
        let requestB = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: VideoExporter(mediaLocator: StubMediaLocator()), deliveryPolicy: .photoLibraryOnly)
        let activeRequest: EditorRuntime.ActiveExportRequest? = requestB

        XCTAssertFalse(activeRequest?.isActive(for: requestAId) ?? false)
        XCTAssertTrue(activeRequest?.isActive(for: requestB.id) ?? false)
    }

    func test_staleFinishing_gatedByRequestId() {
        let requestA = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: VideoExporter(mediaLocator: StubMediaLocator()), deliveryPolicy: .photoLibraryOnly)
        let requestAId = requestA.id
        let requestB = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: VideoExporter(mediaLocator: StubMediaLocator()), deliveryPolicy: .photoLibraryOnly)
        let activeRequest: EditorRuntime.ActiveExportRequest? = requestB

        XCTAssertFalse(activeRequest?.isActive(for: requestAId) ?? false)
        XCTAssertTrue(activeRequest?.isActive(for: requestB.id) ?? false)
    }

    func test_isExporting_computedFromActiveRequest() {
        var activeRequest: EditorRuntime.ActiveExportRequest?
        var isExporting: Bool { activeRequest != nil }

        XCTAssertFalse(isExporting)
        activeRequest = EditorRuntime.ActiveExportRequest(id: UUID(), exporter: VideoExporter(mediaLocator: StubMediaLocator()), deliveryPolicy: .photoLibraryOnly)
        XCTAssertTrue(isExporting)
        activeRequest = nil
        XCTAssertFalse(isExporting)
    }

    // MARK: - Runtime Integration: Missing Media Gate

    func test_startExport_withMissingMedia_emitsError() async {
        let (session, runtime) = await makeBootedRuntime()
        var outputs: [EditorRuntimeOutput] = []
        runtime.onOutput = { outputs.append($0) }

        // Inject missing media
        session.updateMissingMedia(for: UUID(), failures: ["block_1"])

        runtime.startExport(policy: .photoLibraryOnly)

        // State should NOT transition to exporting
        XCTAssertEqual(runtime.state, .timelinePreview)
        XCTAssertTrue(outputs.contains(where: {
            if case .presentError = $0 { return true }
            return false
        }))
    }

    func test_startExport_noMissingMedia_transitionsToExporting() async {
        let (_, runtime) = await makeBootedRuntime()
        var outputs: [EditorRuntimeOutput] = []
        runtime.onOutput = { outputs.append($0) }

        runtime.startExport(policy: .photoLibraryOnly)

        XCTAssertEqual(runtime.state, .exporting)
        XCTAssertTrue(outputs.contains(where: {
            if case .exportStarted = $0 { return true }
            return false
        }))
    }

    // MARK: - Runtime Integration: Cancel Export

    func test_cancelExport_restoresTimelinePreview() async {
        let (_, runtime) = await makeBootedRuntime(state: .timelinePreview)
        var outputs: [EditorRuntimeOutput] = []
        runtime.onOutput = { outputs.append($0) }

        runtime.startExport(policy: .photoLibraryOnly)
        XCTAssertEqual(runtime.state, .exporting)

        runtime.cancelExport()
        XCTAssertEqual(runtime.state, .timelinePreview)
        XCTAssertTrue(outputs.contains(where: {
            if case .exportCancelled = $0 { return true }
            return false
        }))
    }

    func test_cancelExport_restoresSceneEdit() async {
        let instanceId = UUID()
        let (_, runtime) = await makeBootedRuntime(state: .sceneEdit(instanceId: instanceId))
        var outputs: [EditorRuntimeOutput] = []
        runtime.onOutput = { outputs.append($0) }

        runtime.startExport(policy: .photoLibraryOnly)
        XCTAssertEqual(runtime.state, .exporting)

        runtime.cancelExport()
        XCTAssertEqual(runtime.state, .sceneEdit(instanceId: instanceId))
    }

    func test_doubleCancelExport_isNoop() async {
        let (_, runtime) = await makeBootedRuntime(state: .timelinePreview)
        var cancelCount = 0
        runtime.onOutput = { output in
            if case .exportCancelled = output { cancelCount += 1 }
        }

        runtime.startExport(policy: .photoLibraryOnly)
        runtime.cancelExport()
        runtime.cancelExport() // second cancel — should be noop

        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(runtime.state, .timelinePreview)
    }

    // MARK: - Export Terminal Safety

    func test_executeExport_withoutMetalContext_restoresPreExportState_andEmitsTerminalFailure() async {
        let (_, runtime) = await makeBootedRuntime(state: .timelinePreview)
        var outputs: [EditorRuntimeOutput] = []
        runtime.onOutput = { outputs.append($0) }

        // Start export (sets state to .exporting) but no metal context booted
        runtime.startExport(policy: .photoLibraryOnly)
        XCTAssertEqual(runtime.state, .exporting)

        // executeExport should detect missing metal context and abort
        await runtime.executeExport()

        // State must be restored, not stuck in .exporting
        XCTAssertEqual(runtime.state, .timelinePreview)
        // Must emit terminal failure
        XCTAssertTrue(outputs.contains(where: {
            if case .exportRenderFailed(_) = $0 { return true }
            return false
        }))
    }

    func test_executeExport_fromSceneEdit_withoutMetalContext_restoresSceneEdit() async {
        let instanceId = UUID()
        let (_, runtime) = await makeBootedRuntime(state: .sceneEdit(instanceId: instanceId))
        var outputs: [EditorRuntimeOutput] = []
        runtime.onOutput = { outputs.append($0) }

        runtime.startExport(policy: .photoLibraryOnly)
        await runtime.executeExport()

        XCTAssertEqual(runtime.state, .sceneEdit(instanceId: instanceId))
        XCTAssertTrue(outputs.contains(where: {
            if case .exportRenderFailed(_) = $0 { return true }
            return false
        }))
    }

    func test_cancelDuringPreflight_restoresPreExportState() async {
        let (_, runtime) = await makeBootedRuntime(state: .timelinePreview)
        var cancelCount = 0
        runtime.onOutput = { output in
            if case .exportCancelled = output { cancelCount += 1 }
        }

        runtime.startExport(policy: .photoLibraryOnly)
        XCTAssertEqual(runtime.state, .exporting)

        // Cancel (simulating cancel during preflight wait)
        runtime.cancelExport()

        XCTAssertEqual(runtime.state, .timelinePreview)
        XCTAssertEqual(cancelCount, 1)

        // Second cancel is noop
        runtime.cancelExport()
        XCTAssertEqual(cancelCount, 1)
    }

    // MARK: - ExportSession onTerminal (preserved)

    func test_activeSessionClearedOnTerminal() {
        let exp = expectation(description: "completion")
        var sessionCleared = false

        let session = ExportSession { _ in exp.fulfill() }
        session.setOnTerminal { sessionCleared = true }
        session.complete(with: .failure(VideoExportError.cancelled))

        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(sessionCleared)
    }
}
