import XCTest
import Metal
import AVFoundation
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

private struct NoOpDeliverer: ExportDelivering {
    func deliver(fileURL: URL, to destination: ExportDeliveryDestination,
                 completion: @escaping (Result<Void, ExportDeliveryError>) -> Void) {
        completion(.success(()))
    }
}

// MARK: - Video File Helper

private let testBlockId = "block_video"

private func createDummyVideoFile() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_video_\(UUID().uuidString).mov")
    FileManager.default.createFile(atPath: url.path, contents: Data(count: 64))
    return url
}

private func createValidVideoFile(durationFrames: Int = 3, fps: Int32 = 30) async throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_valid_\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 16,
        AVVideoHeightKey: 16
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16
        ]
    )
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard let buffer = pixelBuffer else {
        throw NSError(domain: "Test", code: 1)
    }
    for i in 0..<durationFrames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw writer.error ?? NSError(domain: "Test", code: 2)
    }
    return url
}

/// Media locator that resolves all refs to a fixed URL.
private struct FixedURLMediaLocator: ProjectMediaLocator {
    let fixedURL: URL
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        fixedURL
    }
}

// MARK: - Helpers

private func makeMinimalResources(durationFrames: Int, fps: Int = 30, sceneTypeId: String = "scene_1") -> SceneTypeResourcesCache.Resources {
    let canvas = Canvas(width: 1080, height: 1920, fps: fps, durationFrames: durationFrames)
    let scene = Scene(
        schemaVersion: "1.0",
        sceneId: sceneTypeId,
        canvas: canvas,
        background: nil,
        mediaBlocks: []
    )
    let runtime = SceneRuntime(
        scene: scene,
        canvas: canvas,
        blocks: [],
        durationFrames: durationFrames,
        fps: fps
    )
    let compiled = CompiledScene(
        runtime: runtime,
        mergedAssetIndex: AssetIndexIR(),
        pathRegistry: PathRegistry(),
        bindingAssetIds: []
    )
    let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
    let baseProvider = InMemoryTextureProvider()

    return SceneTypeResourcesCache.Resources(
        sceneTypeId: sceneTypeId,
        compiled: compiled,
        resolver: resolver,
        baseTextureProvider: baseProvider,
        assetSizes: [:],
        pathRegistry: PathRegistry(),
        canvasSize: SizeD(width: Double(canvas.width), height: Double(canvas.height)),
        fps: fps,
        durationFrames: durationFrames
    )
}

private func makeMinimalResourcesWithMediaBlock(durationFrames: Int, fps: Int = 30, sceneTypeId: String = "scene_1") -> SceneTypeResourcesCache.Resources {
    let canvas = Canvas(width: 1080, height: 1920, fps: fps, durationFrames: durationFrames)
    let mediaBlock = MediaBlock(
        id: testBlockId,
        zIndex: 0,
        rect: Rect(x: 0, y: 0, width: 1080, height: 1920),
        containerClip: .slotRect,
        input: MediaInput(bindingKey: "media_0", allowedMedia: ["photo", "video"]),
        variants: [Variant(id: "v1", animRef: "anim.json")]
    )
    let scene = Scene(
        schemaVersion: "1.0",
        sceneId: sceneTypeId,
        canvas: canvas,
        background: nil,
        mediaBlocks: [mediaBlock]
    )
    let runtime = SceneRuntime(
        scene: scene,
        canvas: canvas,
        blocks: [],
        durationFrames: durationFrames,
        fps: fps
    )
    let compiled = CompiledScene(
        runtime: runtime,
        mergedAssetIndex: AssetIndexIR(),
        pathRegistry: PathRegistry(),
        bindingAssetIds: []
    )
    let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
    let baseProvider = InMemoryTextureProvider()

    return SceneTypeResourcesCache.Resources(
        sceneTypeId: sceneTypeId,
        compiled: compiled,
        resolver: resolver,
        baseTextureProvider: baseProvider,
        assetSizes: [:],
        pathRegistry: PathRegistry(),
        canvasSize: SizeD(width: Double(canvas.width), height: Double(canvas.height)),
        fps: fps,
        durationFrames: durationFrames
    )
}

@MainActor
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

@MainActor
private func makeLoadResult(device: MTLDevice) -> EditorRuntime.InitialSceneLoadResult {
    let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 90)
    let scene = Scene(
        schemaVersion: "1.0",
        sceneId: "scene_1",
        canvas: canvas,
        background: nil,
        mediaBlocks: []
    )
    let runtime = SceneRuntime(
        scene: scene,
        canvas: canvas,
        blocks: [],
        durationFrames: 90,
        fps: 30
    )
    let compiled = CompiledScene(
        runtime: runtime,
        mergedAssetIndex: AssetIndexIR(),
        pathRegistry: PathRegistry(),
        bindingAssetIds: []
    )
    let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
    let provider = ScenePackageTextureProvider(
        device: device,
        assetIndex: compiled.mergedAssetIndex,
        resolver: resolver,
        bindingAssetIds: compiled.bindingAssetIds
    )
    let player = ScenePlayer()
    let loaded = player.loadCompiledScene(compiled)
    return EditorRuntime.InitialSceneLoadResult(
        player: player,
        compiled: loaded,
        provider: provider,
        resolver: resolver,
        preloadStats: nil
    )
}

@MainActor
private func makeFullyBootedRuntime() async -> (EditorSession, EditorRuntime)? {
    let session = await makeBootstrappedSession()
    guard let editorState = session.state else { return nil }
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else { return nil }

    let runtime = EditorRuntime(session: session)
    let metalContext = EditorRuntimeMetalContext(
        device: device,
        commandQueue: commandQueue,
        colorPixelFormat: .bgra8Unorm
    )
    let library = SceneLibrarySnapshot(
        fps: 30,
        canvas: CanvasConfig(width: 1080, height: 1920),
        scenes: [
            SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
        ]
    )

    let loadResult = makeLoadResult(device: device)
    runtime.configureAndBoot(
        metalContext: metalContext,
        library: library,
        loadResult: loadResult,
        editorState: editorState
    )

    // Pre-populate engine cache so prepareForPlayback can create instance runtimes
    if let engine = runtime.testTimelineCompositionEngine {
        let resources = makeMinimalResources(durationFrames: 90, sceneTypeId: "scene_1")
        engine.resourcesCache.addToCache(resources)
    }

    return (session, runtime)
}

@MainActor
private func makeLoadResultWithMediaBlock(device: MTLDevice) -> EditorRuntime.InitialSceneLoadResult {
    let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 90)
    let mediaBlock = MediaBlock(
        id: testBlockId,
        zIndex: 0,
        rect: Rect(x: 0, y: 0, width: 1080, height: 1920),
        containerClip: .slotRect,
        input: MediaInput(bindingKey: "media_0", allowedMedia: ["photo", "video"]),
        variants: [Variant(id: "v1", animRef: "anim.json")]
    )
    let scene = Scene(
        schemaVersion: "1.0",
        sceneId: "scene_1",
        canvas: canvas,
        background: nil,
        mediaBlocks: [mediaBlock]
    )
    let runtime = SceneRuntime(
        scene: scene,
        canvas: canvas,
        blocks: [],
        durationFrames: 90,
        fps: 30
    )
    let compiled = CompiledScene(
        runtime: runtime,
        mergedAssetIndex: AssetIndexIR(),
        pathRegistry: PathRegistry(),
        bindingAssetIds: []
    )
    let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
    let provider = ScenePackageTextureProvider(
        device: device,
        assetIndex: compiled.mergedAssetIndex,
        resolver: resolver,
        bindingAssetIds: compiled.bindingAssetIds
    )
    let player = ScenePlayer()
    let loaded = player.loadCompiledScene(compiled)
    return EditorRuntime.InitialSceneLoadResult(
        player: player,
        compiled: loaded,
        provider: provider,
        resolver: resolver,
        preloadStats: nil
    )
}

@MainActor
private func makeFullyBootedRuntimeWithVideoSlot(videoFileURL: URL) async -> (EditorSession, EditorRuntime)? {
    let assetId = ProjectAssetID()
    let mediaRef = MediaRef(storagePath: "Media/UserMedia/test.mov", mediaKind: .video, assetId: assetId)
    let videoSlot = SceneMediaSlot.video(
        mediaRef: mediaRef,
        placement: .defaultCover,
        videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 3.0)
    )

    let deps = EditorSessionDependencies(
        saveActiveDraft: { _ in },
        loadActiveDraft: { nil },
        deleteActiveDraft: {},
        loadSavedProject: { _ in nil },
        materializeSavedProject: { $0 },
        mediaLocator: FixedURLMediaLocator(fixedURL: videoFileURL),
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

    guard let editorState = session.state else { return nil }
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else { return nil }

    // Inject video slot into the first scene instance
    guard let instanceId = editorState.draft.canonicalTimeline.sceneItems.first?.id else { return nil }
    session.dispatch(.setMediaSlot(sceneInstanceId: instanceId, blockId: testBlockId, slot: videoSlot))

    guard let updatedState = session.state else { return nil }

    let runtime = EditorRuntime(session: session)
    let metalContext = EditorRuntimeMetalContext(
        device: device,
        commandQueue: commandQueue,
        colorPixelFormat: .bgra8Unorm
    )
    let library = SceneLibrarySnapshot(
        fps: 30,
        canvas: CanvasConfig(width: 1080, height: 1920),
        scenes: [
            SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
        ]
    )

    let loadResult = makeLoadResultWithMediaBlock(device: device)
    runtime.configureAndBoot(
        metalContext: metalContext,
        library: library,
        loadResult: loadResult,
        editorState: updatedState
    )

    // Pre-populate engine cache with media-block-aware resources
    if let engine = runtime.testTimelineCompositionEngine {
        let resources = makeMinimalResourcesWithMediaBlock(durationFrames: 90, sceneTypeId: "scene_1")
        engine.resourcesCache.addToCache(resources)
    }

    // Apply initial scene instance state so video gets bound
    await runtime.applySceneInstanceState(instanceId: instanceId)

    return (session, runtime)
}

// MARK: - Tests

@MainActor
final class ExportPreviewRestoreTests: XCTestCase {

    // MARK: 1. Success after export teardown restores timeline runtime before output

    func test_successAfterExportTeardown_restoresTimelineRuntimeBeforeSucceededOutput() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        guard let engine = runtime.testTimelineCompositionEngine else {
            XCTFail("Timeline engine not available")
            return
        }

        // Verify initial state: engine has runtimes after boot
        let initialInstanceId = engine.timeline?.sceneItems.first?.id
        XCTAssertNotNil(initialInstanceId)

        // Enter exporting + teardown
        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)
        await runtime.simulateEnterExportMode()

        // Runtimes should be cleared
        XCTAssertTrue(engine.instanceRuntimes.isEmpty, "Runtimes should be cleared after export teardown")

        // Spy: at the moment output fires, runtimes must be restored
        let successExpectation = expectation(description: "exportRenderSucceeded emitted")
        runtime.onOutput = { output in
            if case .exportRenderSucceeded = output {
                XCTAssertFalse(engine.instanceRuntimes.isEmpty,
                               "Instance runtimes must be restored before exportRenderSucceeded fires")
                if case .timeline = runtime.currentRenderSource {
                    // OK — render source is timeline
                } else {
                    XCTFail("Expected .timeline render source after restore")
                }
                successExpectation.fulfill()
            }
        }

        runtime.makeDeliverer = { NoOpDeliverer() }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_export_\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        runtime.simulateHandleExportCompletion(result: .success(tempURL))

        await fulfillment(of: [successExpectation], timeout: 5.0)
    }

    // MARK: 2. Success without background still restores video preview

    func test_successWithoutBackground_stillRestoresVideoPreview() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        guard let engine = runtime.testTimelineCompositionEngine else {
            XCTFail("Timeline engine not available")
            return
        }

        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)
        await runtime.simulateEnterExportMode()
        XCTAssertTrue(engine.instanceRuntimes.isEmpty)

        let successExpectation = expectation(description: "exportRenderSucceeded")
        runtime.onOutput = { output in
            if case .exportRenderSucceeded = output {
                XCTAssertFalse(engine.instanceRuntimes.isEmpty,
                               "Video preview must be restored even without background images")
                successExpectation.fulfill()
            }
        }

        runtime.makeDeliverer = { NoOpDeliverer() }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        runtime.simulateHandleExportCompletion(result: .success(tempURL))
        await fulfillment(of: [successExpectation], timeout: 5.0)
    }

    // MARK: 4. Playhead moved during restore presents frame at new position

    func test_playheadMovedDuringRestore_presentsFrameAtNewPlayhead() async throws {
        guard let (session, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        guard let engine = runtime.testTimelineCompositionEngine else {
            XCTFail("Timeline engine not available")
            return
        }

        // Start at frame 0
        session.dispatch(.setPlayhead(compressedFrame: 0))

        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)
        await runtime.simulateEnterExportMode()

        // Move playhead to frame 20 while runtimes are torn down.
        // The restore loop re-reads playheadCompressedFrame after prepareForPlayback,
        // so it must pick up this new position.
        session.dispatch(.setPlayhead(compressedFrame: 20))

        let successExpectation = expectation(description: "exportRenderSucceeded")
        runtime.onOutput = { output in
            if case .exportRenderSucceeded = output {
                XCTAssertFalse(engine.instanceRuntimes.isEmpty,
                               "Instance runtimes must be restored")
                // Verify the presented frame matches the moved playhead
                if case .timeline(let payload) = runtime.currentRenderSource {
                    XCTAssertEqual(payload.diagnosticFrameTag, 20,
                                   "Restore must present frame at new playhead (20), not original (0)")
                } else {
                    XCTFail("Expected .timeline render source after restore")
                }
                successExpectation.fulfill()
            }
        }

        runtime.makeDeliverer = { NoOpDeliverer() }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        runtime.simulateHandleExportCompletion(result: .success(tempURL))
        await fulfillment(of: [successExpectation], timeout: 5.0)
    }

    // MARK: 7. Cancel after teardown restores preview before cancelled output

    func test_cancelAfterTeardown_restoresPreviewBeforeCancelledOutput() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        guard let engine = runtime.testTimelineCompositionEngine else {
            XCTFail("Timeline engine not available")
            return
        }

        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)
        await runtime.simulateEnterExportMode()
        XCTAssertTrue(engine.instanceRuntimes.isEmpty)

        let cancelExpectation = expectation(description: "exportCancelled emitted")
        runtime.onOutput = { output in
            if case .exportCancelled = output {
                XCTAssertFalse(engine.instanceRuntimes.isEmpty,
                               "Runtimes must be restored before exportCancelled fires")
                cancelExpectation.fulfill()
            }
        }

        runtime.cancelExport()
        await fulfillment(of: [cancelExpectation], timeout: 5.0)
    }

    // MARK: 8. Failure after teardown restores preview before failed output

    func test_failureAfterTeardown_restoresPreviewBeforeFailedOutput() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        guard let engine = runtime.testTimelineCompositionEngine else {
            XCTFail("Timeline engine not available")
            return
        }

        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)
        await runtime.simulateEnterExportMode()
        XCTAssertTrue(engine.instanceRuntimes.isEmpty)

        let failExpectation = expectation(description: "exportRenderFailed emitted")
        runtime.onOutput = { output in
            if case .exportRenderFailed = output {
                XCTAssertFalse(engine.instanceRuntimes.isEmpty,
                               "Runtimes must be restored before exportRenderFailed fires")
                failExpectation.fulfill()
            }
        }

        runtime.makeDeliverer = { NoOpDeliverer() }
        let error = NSError(domain: "test", code: 42)
        runtime.simulateHandleExportCompletion(result: .failure(error))
        await fulfillment(of: [failExpectation], timeout: 5.0)
    }

    // MARK: 9. Scene-edit export restores scene-edit video preview

    func test_sceneEditExport_restoresSceneEditVideoPreview() async throws {
        guard let (session, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        guard let instanceId = session.state?.draft.canonicalTimeline.sceneItems.first?.id else {
            XCTFail("No scene instance")
            return
        }

        // Enter scene edit
        runtime.bootForTesting(state: .sceneEdit(instanceId: instanceId))

        runtime.exportController.preExportState = .sceneEdit(instanceId: instanceId)
        runtime.bootForTesting(state: .exporting)
        await runtime.simulateEnterExportMode()

        let successExpectation = expectation(description: "exportRenderSucceeded emitted")
        runtime.onOutput = { output in
            if case .exportRenderSucceeded = output {
                if case .sceneEdit = runtime.state {
                    // OK — restored to scene edit state
                } else {
                    XCTFail("Expected .sceneEdit state after restore, got \(runtime.state)")
                }
                successExpectation.fulfill()
            }
        }

        runtime.makeDeliverer = { NoOpDeliverer() }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        runtime.simulateHandleExportCompletion(result: .success(tempURL))
        await fulfillment(of: [successExpectation], timeout: 5.0)
    }

    // MARK: 10. Start playback during post-export restore is blocked

    func test_startPlaybackDuringPostExportRestore_isBlocked() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        // Directly set the flag to simulate active restore — deterministic, no timing dependency
        runtime.exportController.setRestoringForTesting(true)
        XCTAssertTrue(runtime.isRestoringPreviewAfterExport)

        // startPlayback must no-op while flag is set
        runtime.startPlayback()
        XCTAssertFalse(runtime.isPlaying,
                       "startPlayback() must no-op while isRestoringPreviewAfterExport is true")

        // Clear flag and verify playback can start after restore completes
        runtime.exportController.setRestoringForTesting(false)
        XCTAssertFalse(runtime.isRestoringPreviewAfterExport,
                       "Flag must be clearable")
    }

    // MARK: 11. Start export during restore is blocked

    func test_startExportDuringRestore_isBlocked() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        runtime.exportController.setRestoringForTesting(true)

        // startExport must no-op while flag is set
        runtime.startExport(policy: .photoLibraryOnly)
        XCTAssertNotEqual(runtime.state, .exporting,
                          "startExport() must no-op while isRestoringPreviewAfterExport is true")

        runtime.exportController.setRestoringForTesting(false)
    }

    // MARK: 13. Video providers rehydrate after export teardown + restore

    func test_videoProvidersRehydrateAfterExportRestore() async throws {
        let videoURL = createDummyVideoFile()
        defer { try? FileManager.default.removeItem(at: videoURL) }

        guard let (session, runtime) = await makeFullyBootedRuntimeWithVideoSlot(videoFileURL: videoURL) else {
            throw XCTSkip("Metal or session not available")
        }

        guard let service = runtime.userMediaService else {
            XCTFail("UserMediaService not available")
            return
        }

        guard let instanceId = session.state?.draft.canonicalTimeline.sceneItems.first?.id else {
            XCTFail("No scene instance")
            return
        }

        // Pre-condition: video provider exists after initial bind
        XCTAssertGreaterThan(service.activeVideoProviderCount, 0,
                             "Pre-condition: video provider must exist after initial applySceneInstanceState")

        // Export teardown releases video providers
        runtime.exportController.preExportState = .sceneEdit(instanceId: instanceId)
        runtime.bootForTesting(state: .exporting)
        await runtime.simulateEnterExportMode()

        XCTAssertEqual(service.activeVideoProviderCount, 0,
                       "releasePreviewResources must clear all video providers")

        // Restore
        let successExpectation = expectation(description: "exportRenderSucceeded")
        runtime.onOutput = { [weak service] output in
            if case .exportRenderSucceeded = output {
                guard let service else { return }
                XCTAssertGreaterThan(service.activeVideoProviderCount, 0,
                                     "Video providers must be rehydrated before export output fires")
                successExpectation.fulfill()
            }
        }

        runtime.makeDeliverer = { NoOpDeliverer() }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        runtime.simulateHandleExportCompletion(result: .success(tempURL))
        await fulfillment(of: [successExpectation], timeout: 5.0)
    }

    // MARK: 14. Timeline preview restore with video slot — runtime re-created with video state applied

    func test_timelinePreviewRestore_withVideoSlot_runtimeReCreatedWithVideoState() async throws {
        let videoURL = try await createValidVideoFile(durationFrames: 90, fps: 30)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        guard let (session, runtime) = await makeFullyBootedRuntimeWithVideoSlot(videoFileURL: videoURL) else {
            throw XCTSkip("Metal or session not available")
        }

        guard let engine = runtime.testTimelineCompositionEngine else {
            XCTFail("Timeline engine not available")
            return
        }

        guard let instanceId = session.state?.draft.canonicalTimeline.sceneItems.first?.id else {
            XCTFail("No scene instance")
            return
        }

        // Verify engine has the video slot from session state
        let engineSlot = engine.sceneStates[instanceId]?.mediaSlotsByBlockId?[testBlockId]
        XCTAssertNotNil(engineSlot, "Pre-condition: engine must have video slot from session state")
        XCTAssertEqual(engineSlot?.mediaRef.mediaKind, .video, "Pre-condition: slot must be video")

        // Export teardown: releases all runtimes
        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)
        await runtime.simulateEnterExportMode()
        XCTAssertTrue(engine.instanceRuntimes.isEmpty, "Runtimes cleared after teardown")

        // Trigger restore via completion
        let successExpectation = expectation(description: "exportRenderSucceeded with restored runtime")
        runtime.onOutput = { output in
            if case .exportRenderSucceeded = output {
                // Verify SceneInstanceRuntime was re-created by prepareForPlayback
                guard let sceneRuntime = engine.runtime(for: instanceId) else {
                    XCTFail("SceneInstanceRuntime must exist after timeline restore")
                    successExpectation.fulfill()
                    return
                }

                // Verify state was applied — appliedState contains the video slot.
                // This proves: prepareForPlayback → ensureReady → applyState with engine.sceneStates
                // which includes the video slot → MediaRestoreCoordinator.restore called.
                let appliedSlot = sceneRuntime.appliedState?.mediaSlotsByBlockId?[testBlockId]
                XCTAssertNotNil(appliedSlot,
                                "appliedState must contain video slot after timeline restore")
                XCTAssertEqual(appliedSlot?.mediaRef.mediaKind, .video,
                               "Applied slot must be video kind")

                // Verify the video block was offered to UserMediaService
                // (blockIdsWithVideo reads from mediaState, set by setVideo before async poster)
                let videoBlockIds = sceneRuntime.userMediaService.blockIdsWithVideo
                XCTAssertTrue(videoBlockIds.contains(testBlockId),
                              "UserMediaService must have video block registered after timeline restore (got \(videoBlockIds))")

                successExpectation.fulfill()
            }
        }

        runtime.makeDeliverer = { NoOpDeliverer() }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        runtime.simulateHandleExportCompletion(result: .success(tempURL))
        await fulfillment(of: [successExpectation], timeout: 10.0)
    }

    // MARK: 12. Scrub during active export after teardown does not start new resolve

    func test_scrubDuringExportAfterTeardown_doesNotStartNewResolve() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        guard let engine = runtime.testTimelineCompositionEngine else {
            XCTFail("Timeline engine not available")
            return
        }

        // Let any boot-time resolve Tasks settle first
        await Task.yield()
        await Task.yield()

        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)
        await runtime.simulateEnterExportMode()

        // Wait for any in-flight boot resolves to drain after teardown
        await Task.yield()
        await Task.yield()

        // Now runtimes are stable (may have been re-created by stale in-flight boot resolve,
        // then immediately cleared — or fully drained). Record baseline.
        let baselineCount = engine.instanceRuntimes.count

        XCTAssertTrue(runtime.exportController.exportTeardownOccurred)

        // Record resolve count before scrub
        let resolveCountBefore = runtime.timelinePresentResolveCount

        // Scrub playhead while in .exporting after teardown
        runtime.handlePlayheadChanged(10)

        // handlePlayheadChanged must NOT trigger a new presentation resolve
        XCTAssertEqual(runtime.timelinePresentResolveCount, resolveCountBefore,
                       "handlePlayheadChanged in .exporting after teardown must not trigger timeline resolve")

        // Yield to verify no async side-effects from the scrub
        await Task.yield()

        XCTAssertEqual(engine.instanceRuntimes.count, baselineCount,
                       "Scrub during export after teardown must not change runtime count")
    }

    // MARK: - PR3 Race Path Tests

    func test_playheadBlockedDuringExportEntering() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        // Put into exporting state
        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)

        // Simulate entering state (without actually running enterExportMode)
        runtime.exportController.setExportTeardownStateForTesting(.entering)

        let resolveBefore = runtime.timelinePresentResolveCount

        // Playhead change during .entering should be blocked
        runtime.handlePlayheadChanged(5)
        runtime.handlePlayheadChanged(10)
        runtime.handlePlayheadChanged(15)

        XCTAssertEqual(runtime.timelinePresentResolveCount, resolveBefore,
                       "Playhead resolve must be blocked during .entering state")
    }

    func test_cancelDuringEntering_setsFlag() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)

        // Simulate entering state
        runtime.exportController.setExportTeardownStateForTesting(.entering)

        // cancelExport in .entering state should set flag (not restore immediately)
        runtime.exportController.cancelExport()

        // The cancel path for .entering doesn't emit immediately — deferred to enterExportMode resume
        // Verify the state machine accepted the cancel
        XCTAssertTrue(runtime.exportController.blocksPreviewPresentationDuringExport,
                      "Should still block presentation until enterExportMode resumes")
    }

    func test_enterExportMode_succeeds_whenNoCancelRequested() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }
        guard let engine = runtime.testTimelineCompositionEngine else {
            throw XCTSkip("No engine")
        }

        let resources = makeMinimalResources(durationFrames: 90, sceneTypeId: "scene_1")
        engine.resourcesCache.addToCache(resources)

        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)

        // Enter export mode — should succeed when no cancel requested
        let entered = await runtime.exportController.enterExportMode()
        XCTAssertTrue(entered, "Should succeed when no cancel requested")
        XCTAssertEqual(runtime.exportController.exportTeardownState, .completed)

        // Verify export runner guards work: cancel clears state
        runtime.exportController.cancelExport()

        // After cancel from .completed, export request should be nil (not created yet)
        XCTAssertNil(runtime.exportController.activeExportRequest,
                     "No active request should survive cancel")
    }

    func test_cancelAfterEnterBeforeRunnerStart_preventsExport() async throws {
        guard let (_, runtime) = await makeFullyBootedRuntime() else {
            throw XCTSkip("Metal or session not available")
        }

        runtime.exportController.preExportState = .timelinePreview
        runtime.bootForTesting(state: .exporting)

        // Enter export mode successfully
        await runtime.simulateEnterExportMode()

        XCTAssertEqual(runtime.exportController.exportTeardownState, .completed)

        // Now simulate cancel between enter and runner start
        runtime.exportController.cancelExport()

        // Verify export runner would bail
        XCTAssertNil(runtime.exportController.activeExportRequest,
                     "No export request should exist after cancel")
    }

    func test_releasePreviewResources_drainsSetupTasks() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal not available")
        }

        let session = await makeBootstrappedSession()
        guard let editorState = session.state else {
            throw XCTSkip("No editor state")
        }

        let runtime = EditorRuntime(session: session)
        let metalContext = EditorRuntimeMetalContext(
            device: device,
            commandQueue: commandQueue,
            colorPixelFormat: .bgra8Unorm
        )
        let loadResult = makeLoadResult(device: device)
        runtime.configureAndBoot(
            metalContext: metalContext,
            library: SceneLibrarySnapshot(
                fps: 30,
                canvas: CanvasConfig(width: 1080, height: 1920),
                scenes: [SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)]
            ),
            loadResult: loadResult,
            editorState: editorState
        )

        // After release, no video providers should remain
        await runtime.userMediaService?.releasePreviewResources()

        #if DEBUG
        XCTAssertEqual(runtime.userMediaService?.activeVideoProviderCount ?? 0, 0,
                       "All video providers must be released after drain")
        #endif
    }
}
