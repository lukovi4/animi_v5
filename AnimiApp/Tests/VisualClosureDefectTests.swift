import XCTest
import Metal
import TVECore
@testable import AnimiApp

// MARK: - Shared Stubs

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

// MARK: - Test Constants

/// Real block ID present in the scene definition and used by all mutation tests.
private let testBlockId = "block_photo_1"

// MARK: - Shared Helpers

@MainActor
private func makeMinimalResources(durationFrames: Int, fps: Int = 30, sceneTypeId: String = "test-scene-type") -> SceneTypeResourcesCache.Resources {
    let canvas = Canvas(width: 1080, height: 1920, fps: fps, durationFrames: durationFrames)
    let scene = Scene(
        schemaVersion: "1.0",
        sceneId: "test-scene",
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

private func framesToUs(_ frames: Int, fps: Int = 30) -> TimeUs {
    Int64(frames) * 1_000_000 / Int64(fps)
}

@MainActor
private func makeMinimalTimeline(sceneCount: Int, framesPerScene: Int = 100) -> (CanonicalTimeline, [SceneTypeResourcesCache.Resources]) {
    var items: [TimelineItem] = []
    var payloads: [UUID: TimelinePayload] = [:]
    var resources: [SceneTypeResourcesCache.Resources] = []

    for i in 0..<sceneCount {
        let instanceId = UUID()
        let payloadId = UUID()
        let sceneTypeId = "scene-type-\(i)"
        let durationUs = framesToUs(framesPerScene)
        let item = TimelineItem(
            id: instanceId,
            payloadId: payloadId,
            kind: .scene,
            startUs: nil,
            durationUs: durationUs
        )
        items.append(item)
        payloads[payloadId] = .scene(ScenePayload(sceneTypeId: sceneTypeId))
        resources.append(makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeId))
    }

    let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: items)
    let timeline = CanonicalTimeline(
        tracks: [sceneTrack],
        payloads: payloads,
        boundaryTransitions: [:]
    )
    return (timeline, resources)
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

/// Creates an InitialSceneLoadResult with a **real media block** (`testBlockId`).
@MainActor
private func makeInitialLoadResult(device: MTLDevice) -> EditorRuntime.InitialSceneLoadResult {
    let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 90)

    let mediaBlock = MediaBlock(
        id: testBlockId,
        zIndex: 0,
        rect: Rect(x: 0, y: 0, width: 1080, height: 1920),
        containerClip: .slotRect,
        input: MediaInput(
            bindingKey: "user_photo_1",
            allowedMedia: ["photo", "video"]
        ),
        variants: [
            Variant(id: "default", animRef: "anim-default.json")
        ]
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

/// Boots an EditorRuntime with real Metal context and engine cache pre-populated.
/// The cache is populated AFTER `configureAndBoot` returns but BEFORE the async
/// resolve Task runs (all on @MainActor), so the engine can successfully resolve frames.
@MainActor
private func makeFullyBootedRuntime(device: MTLDevice, commandQueue: MTLCommandQueue) async -> (EditorSession, EditorRuntime)? {
    let session = await makeBootstrappedSession()
    guard let editorState = session.state else { return nil }

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

    runtime.configureAndBoot(
        metalContext: metalContext,
        library: library,
        loadResult: makeInitialLoadResult(device: device),
        editorState: editorState
    )

    // Pre-populate engine cache BEFORE the async resolve Task body runs.
    // This works because the Task created by handlePlayheadChanged is on @MainActor
    // and hasn't yielded yet (cooperative scheduling).
    if let engine = runtime.testTimelineCompositionEngine {
        let resources = makeMinimalResources(durationFrames: 90, sceneTypeId: "scene_1")
        engine.resourcesCache.addToCache(resources)
    }

    return (session, runtime)
}

/// Boots a runtime WITHOUT pre-populating the engine resources cache, so the timeline
/// engine cannot create the scene runtime and frame resolution fails
/// (`.failed(.missingDependency)`). Used to exercise the render-payload HARD GATE: a
/// non-resolving start must keep the boundary closed.
@MainActor
private func makeBootedRuntimeWithoutResources(device: MTLDevice, commandQueue: MTLCommandQueue) async -> (EditorSession, EditorRuntime)? {
    let session = await makeBootstrappedSession()
    guard let editorState = session.state else { return nil }

    let runtime = EditorRuntime(session: session)
    let metalContext = EditorRuntimeMetalContext(
        device: device, commandQueue: commandQueue, colorPixelFormat: .bgra8Unorm
    )
    let library = SceneLibrarySnapshot(
        fps: 30,
        canvas: CanvasConfig(width: 1080, height: 1920),
        scenes: [SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)]
    )
    runtime.configureAndBoot(
        metalContext: metalContext,
        library: library,
        loadResult: makeInitialLoadResult(device: device),
        editorState: editorState
    )
    // Intentionally NO resourcesCache population → frame resolution fails.
    return (session, runtime)
}

/// Creates a real SceneMediaSlot for injection into session state.
private func makeTestSlot() -> SceneMediaSlot {
    let assetId = ProjectAssetID()
    let mediaRef = MediaRef(storagePath: "Media/UserMedia/test.jpg", mediaKind: .photo, assetId: assetId)
    let asset = SceneMediaAsset(mediaRef: mediaRef, placement: .defaultCover)
    return SceneMediaSlot(visibility: true, asset: asset)
}


// MARK: - A. First-Frame Boot Contract (Defect 1)

/// Proves the automatic first-frame chain without manual refresh:
/// boot → engine.onNeedsRedraw → refreshCurrentTimelineFrame → currentRenderSource
final class FirstFrameReadinessTests: XCTestCase {

    /// Unit: `.ready` transition fires `onNeedsRedraw` exactly once.
    @MainActor
    func testReadyTransition_firesOnNeedsRedraw_exactlyOnce() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        var redrawCount = 0
        runtime.onNeedsRedraw = { redrawCount += 1 }

        let state = await runtime.waitUntilReadyForPresentation(at: 0)

        XCTAssertEqual(state, .ready(targetLocalFrame: 0))
        XCTAssertEqual(redrawCount, 1, "onNeedsRedraw must fire exactly once on .ready")
    }

    /// Unit: failed preparation must NOT fire onNeedsRedraw.
    @MainActor
    func testFailedTransition_doesNotFireOnNeedsRedraw() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false
        spy.hasFailedMedia = true

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        var redrawFired = false
        runtime.onNeedsRedraw = { redrawFired = true }
        let _ = await runtime.waitUntilReadyForPresentation(at: 0)

        XCTAssertFalse(redrawFired, "onNeedsRedraw must NOT fire on failure")
    }

    /// Engine integration: onNeedsRedraw propagates through engine to its callback.
    @MainActor
    func testEngine_propagatesOnNeedsRedraw() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources { cache.addToCache(res) }

        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )

        let redrawExpectation = XCTestExpectation(description: "Engine onNeedsRedraw fires")
        engine.onNeedsRedraw = { redrawExpectation.fulfill() }
        engine.setTimeline(timeline, sceneStates: [:])

        let _ = await engine.resolveFrame(50, policy: .presentation)

        await fulfillment(of: [redrawExpectation], timeout: 2.0)
    }

    /// End-to-end: configureAndBoot → automatic engine.onNeedsRedraw →
    /// refreshCurrentTimelineFrame → currentRenderSource resolved.
    /// Does NOT manually call refreshCurrentTimelineFrame or move the playhead.
    @MainActor
    func testFullBoot_automaticRedrawChain_producesRenderSource() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        guard let (_, runtime) = await makeFullyBootedRuntime(device: device, commandQueue: commandQueue) else {
            XCTFail("Failed to boot runtime")
            return
        }

        XCTAssertEqual(runtime.state, .timelinePreview)

        // Wait for the automatic resolve chain: boot → handlePlayheadChanged → resolveFrame Task →
        // runtime reaches .ready → onNeedsRedraw → engine callback → refreshCurrentTimelineFrame →
        // renderSource assigned. No manual refresh, no playhead move.
        let resolved = XCTestExpectation(description: "automatic renderSourceUpdated after boot")
        runtime.onOutput = { (output: EditorRuntimeOutput) in
            if case .renderSourceUpdated = output { resolved.fulfill() }
        }

        await fulfillment(of: [resolved], timeout: 3.0)

        if case .none = runtime.currentRenderSource {
            XCTFail("After automatic boot chain, currentRenderSource must not be .none")
        }
        XCTAssertGreaterThan(runtime.renderSourceRevision, 0,
            "renderSourceRevision must advance from automatic resolve chain")
    }
}


// MARK: - B. Scene-Edit Render Source Rebuild Contract (Defect 2)

/// Proves scene-edit mutations regenerate `currentRenderSource` on real block IDs.
@MainActor
final class SceneEditRenderSourceRebuildTests: XCTestCase {

    /// Boots runtime into scene-edit, injects a real media slot for `testBlockId`.
    private func bootIntoSceneEditWithSlot(
        device: MTLDevice, commandQueue: MTLCommandQueue
    ) async throws -> (EditorSession, EditorRuntime, UUID) {
        guard let (session, runtime) = await makeFullyBootedRuntime(device: device, commandQueue: commandQueue) else {
            throw XCTSkip("Failed to boot runtime")
        }
        guard let instanceId = runtime.currentActiveSceneInstanceId else {
            throw XCTSkip("No active scene instance after boot")
        }

        // Inject a real media slot for testBlockId into session state
        session.dispatch(.setMediaSlot(
            sceneInstanceId: instanceId,
            blockId: testBlockId,
            slot: makeTestSlot()
        ))

        runtime.activateSceneEditTarget(instanceId: instanceId)
        try await Task.sleep(nanoseconds: 400_000_000)

        guard case .sceneEdit = runtime.state else {
            throw XCTSkip("Failed to enter scene-edit state")
        }

        return (session, runtime, instanceId)
    }

    /// Placement mutation on real block rebuilds currentRenderSource.
    func test_placement_rebuildsRenderSource() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (_, runtime, instanceId) = try await bootIntoSceneEditWithSlot(device: device, commandQueue: commandQueue)
        let revisionBefore = runtime.renderSourceRevision

        let _ = runtime.applyMediaPlacementChange(
            instanceId: instanceId,
            blockId: testBlockId,
            placement: .defaultCover
        )

        XCTAssertGreaterThan(runtime.renderSourceRevision, revisionBefore,
            "Placement on real block must regenerate currentRenderSource")
        XCTAssertEqual(runtime.lastRefreshTrigger, .sceneEditMutation,
            "Trigger must be sceneEditMutation, not playheadChanged")
        if case .sceneEdit = runtime.currentRenderSource { /* expected */ } else {
            XCTFail("currentRenderSource must be .sceneEdit after mutation")
        }
    }

    /// Visibility mutation on real block rebuilds currentRenderSource.
    func test_visibility_rebuildsRenderSource() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (_, runtime, instanceId) = try await bootIntoSceneEditWithSlot(device: device, commandQueue: commandQueue)
        let revisionBefore = runtime.renderSourceRevision

        let _ = runtime.applyMediaVisibilityChange(
            instanceId: instanceId,
            blockId: testBlockId,
            visible: false
        )

        XCTAssertGreaterThan(runtime.renderSourceRevision, revisionBefore,
            "Visibility on real block must regenerate currentRenderSource")
        XCTAssertEqual(runtime.lastRefreshTrigger, .sceneEditMutation)
    }

    /// Slot remove on real block rebuilds currentRenderSource.
    func test_slotRemove_rebuildsRenderSource() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (_, runtime, instanceId) = try await bootIntoSceneEditWithSlot(device: device, commandQueue: commandQueue)
        let revisionBefore = runtime.renderSourceRevision

        runtime.applyMediaSlotChange(instanceId: instanceId, blockId: testBlockId, slot: nil)

        XCTAssertGreaterThan(runtime.renderSourceRevision, revisionBefore,
            "Slot remove on real block must regenerate currentRenderSource")
        XCTAssertEqual(runtime.lastRefreshTrigger, .sceneEditMutation)
    }

    /// Runtime-owned media-ready callback with real slot: slot-found branch rebuilds render source.
    /// Exercises `simulateMediaReadyCallback` — the exact production handler path.
    func test_mediaReadyCallback_slotFound_rebuildsRenderSource() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (_, runtime, _) = try await bootIntoSceneEditWithSlot(device: device, commandQueue: commandQueue)
        let revisionBefore = runtime.renderSourceRevision

        // Invoke the runtime-owned handler with the real blockId that has a slot in session state.
        // Production path: UserMediaService.onMediaReady → handleMediaReadyForPlacement →
        // slot found → reapplyPlacementAfterMediaReady → refreshSceneEditIfActive → rebuild.
        runtime.simulateMediaReadyCallback(blockId: testBlockId)

        XCTAssertGreaterThan(runtime.renderSourceRevision, revisionBefore,
            "Media-ready callback on slot-found path must regenerate currentRenderSource")
        XCTAssertEqual(runtime.lastRefreshTrigger, .sceneEditMutation,
            "Trigger must be sceneEditMutation (via refreshSceneEditIfActive)")
    }

    /// Runtime-owned media-ready callback with no matching slot: fallback emits event.
    func test_mediaReadyCallback_noSlot_emitsFallbackEvent() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (_, runtime, _) = try await bootIntoSceneEditWithSlot(device: device, commandQueue: commandQueue)

        var receivedRenderUpdate = false
        runtime.onOutput = { (output: EditorRuntimeOutput) in
            if case .renderSourceUpdated = output { receivedRenderUpdate = true }
        }

        runtime.simulateMediaReadyCallback(blockId: "nonexistent_block_xyz")

        XCTAssertTrue(receivedRenderUpdate,
            "No-slot fallback path must still emit .renderSourceUpdated")
    }
}


// MARK: - C. Incremental Registry Freshness Contract (Defect 3)

/// Proves `updateSceneState(..., assetRegistry:)` threads fresh registry into the loaded-runtime
/// path and resolving assets through that path yields `legacyFallbackHits == 0`.
final class RegistryFreshnessTests: XCTestCase {

    /// Direct engine test: incremental updateSceneState stores fresh registry.
    @MainActor
    func test_updateSceneState_storesFreshRegistry() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator()
        )
        engine.setTimeline(CanonicalTimeline.empty(), sceneStates: [:], assetRegistry: ProjectAssetRegistry())
        XCTAssertTrue(engine.currentAssetRegistry.descriptors.isEmpty)

        var freshRegistry = ProjectAssetRegistry()
        let assetId = ProjectAssetID()
        freshRegistry.register(ProjectAssetDescriptor(assetId: assetId, mediaKind: .photo, storagePath: "Media/UserMedia/photo.jpg"))

        await engine.updateSceneState(SceneState(), for: UUID(), assetRegistry: freshRegistry)

        XCTAssertNotNil(engine.currentAssetRegistry.descriptors[assetId],
            "Fresh registry entry must be present after incremental updateSceneState")
    }

    /// Loaded-runtime incremental path: the already-loaded runtime receives fresh registry
    /// via `reloadState(_, assetRegistry:)`, and resolving through the store yields
    /// `legacyFallbackHits == 0`. This is the exact path that regressed: stale registry
    /// from `setTimeline(...)` was used for `runtime.reloadState` until the fix.
    @MainActor
    func test_loadedRuntime_incrementalUpdate_resolvesWithoutFallback() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // Set up a real project directory with a media file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry_freshness_\(UUID().uuidString)")
        let mediaDir = tempDir.appendingPathComponent("Media/UserMedia")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mediaPath = "Media/UserMedia/test_photo.jpg"
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent(mediaPath).path,
            contents: Data([0xFF, 0xD8])
        )

        let store = FileProjectMediaStore(rootDirectoryURL: tempDir)
        XCTAssertEqual(store.legacyFallbackHits, 0)

        let assetId = ProjectAssetID()
        let mediaRef = MediaRef(storagePath: mediaPath, mediaKind: .photo, assetId: assetId)
        var freshRegistry = ProjectAssetRegistry()
        freshRegistry.register(ProjectAssetDescriptor(assetId: assetId, mediaKind: .photo, storagePath: mediaPath))

        // Boot engine with empty registry (simulates stale setTimeline at boot)
        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources { cache.addToCache(res) }

        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )

        engine.setTimeline(timeline, sceneStates: [:], assetRegistry: ProjectAssetRegistry())

        // Create and load the runtime
        let _ = await engine.resolveFrame(50, policy: .presentation)

        // Incremental update on already-loaded runtime with fresh registry.
        // This is the exact path that regressed: updateSceneState now passes assetRegistry
        // into both engine.currentAssetRegistry AND runtime.reloadState(_, assetRegistry:).
        let instanceId = timeline.sceneItems[0].id
        await engine.updateSceneState(SceneState(), for: instanceId, assetRegistry: freshRegistry)

        // Verify the engine consumed the fresh registry
        XCTAssertNotNil(engine.currentAssetRegistry.descriptors[assetId],
            "Fresh registry must be stored after incremental update on loaded runtime")

        // Resolve through the real store path
        let url = try store.absoluteURL(for: mediaRef, registry: engine.currentAssetRegistry)

        XCTAssertEqual(store.legacyFallbackHits, 0,
            "Incremental update on loaded runtime must resolve without legacy fallback")
        XCTAssertTrue(url.path.contains(mediaPath))
    }

    /// Second incremental update overwrites registry.
    @MainActor
    func test_secondUpdate_overwritesRegistry() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator()
        )
        engine.setTimeline(CanonicalTimeline.empty(), sceneStates: [:])

        var r1 = ProjectAssetRegistry()
        let id1 = ProjectAssetID()
        r1.register(ProjectAssetDescriptor(assetId: id1, mediaKind: .photo, storagePath: "a.jpg"))
        await engine.updateSceneState(SceneState(), for: UUID(), assetRegistry: r1)
        XCTAssertNotNil(engine.currentAssetRegistry.descriptors[id1])

        var r2 = ProjectAssetRegistry()
        let id2 = ProjectAssetID()
        r2.register(ProjectAssetDescriptor(assetId: id2, mediaKind: .photo, storagePath: "b.jpg"))
        await engine.updateSceneState(SceneState(), for: UUID(), assetRegistry: r2)
        XCTAssertNotNil(engine.currentAssetRegistry.descriptors[id2])
    }
}


// MARK: - D. Music Lane Geometry (Defect 4)

final class MusicLaneGeometryTests: XCTestCase {

    @MainActor
    private func leadingConstraintConstant(_ track: AudioTrackView) -> CGFloat? {
        for constraint in track.constraints {
            if constraint.firstAttribute == .leading,
               let first = constraint.firstItem as? UIView,
               first !== track,
               (constraint.secondItem as? UIView) === track {
                return constraint.constant
            }
        }
        return nil
    }

    @MainActor
    func test_clipOffset_setsLeadingConstraint() {
        let track = AudioTrackView(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        track.setHasClip(true)
        track.configure(durationUs: 5_000_000, pxPerSecond: 100, leftPadding: 100, clipOffsetPx: 50)

        let constant = leadingConstraintConstant(track)
        XCTAssertNotNil(constant)
        XCTAssertEqual(constant!, 150, accuracy: 0.01,
            "Leading = leftPadding(100) + clipOffset(50) = 150")
    }

    @MainActor
    func test_setPxPerSecond_preservesClipOffset() {
        let track = AudioTrackView(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        track.setHasClip(true)
        track.configure(durationUs: 5_000_000, pxPerSecond: 100, leftPadding: 100, clipOffsetPx: 50)

        track.setPxPerSecond(200, leftPadding: 120)

        let constant = leadingConstraintConstant(track)
        XCTAssertNotNil(constant)
        XCTAssertEqual(constant!, 170, accuracy: 0.01,
            "After zoom: Leading = newPadding(120) + preservedClipOffset(50) = 170")
    }

    @MainActor
    func test_defaultClipOffset_isZero() {
        let track = AudioTrackView(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        track.setHasClip(true)
        track.configure(durationUs: 5_000_000, pxPerSecond: 100, leftPadding: 100)

        let constant = leadingConstraintConstant(track)
        XCTAssertNotNil(constant)
        XCTAssertEqual(constant!, 100, accuracy: 0.01,
            "Default clipOffset=0 → leading = leftPadding only")
    }

    @MainActor
    func test_configureBeforeSetHasClip_appliesGeometryWhenClipBecomesVisible() {
        let track = AudioTrackView(frame: CGRect(x: 0, y: 0, width: 600, height: 40))

        // Configure while hasClip is still false (production order: configure first, then setHasClip)
        track.configure(durationUs: 5_000_000, pxPerSecond: 100, leftPadding: 100, clipOffsetPx: 50)

        // Now make clip visible — this must trigger layout update
        track.setHasClip(true)

        let constant = leadingConstraintConstant(track)
        XCTAssertNotNil(constant, "Leading constraint must exist")
        XCTAssertEqual(constant!, 150, accuracy: 0.01,
            "Leading = leftPadding(100) + clipOffset(50) = 150 after setHasClip(true)")

        // Verify track width: 5s * 100px/s = 500px
        var trackWidth: CGFloat?
        for constraint in track.constraints {
            if constraint.firstAttribute == .width,
               let first = constraint.firstItem as? UIView,
               first !== track {
                trackWidth = constraint.constant
                break
            }
        }
        // Also check subview constraints
        if trackWidth == nil {
            for sub in track.subviews {
                for constraint in sub.constraints {
                    if constraint.firstAttribute == .width {
                        trackWidth = constraint.constant
                        break
                    }
                }
                if trackWidth != nil { break }
            }
        }
        XCTAssertNotNil(trackWidth, "Width constraint must exist")
        XCTAssertEqual(trackWidth!, 500, accuracy: 0.01,
            "Width = 5s * 100px/s = 500")

        // Verify visibility
        let trackBg = track.subviews.first(where: { !($0 is UILabel) })
        XCTAssertEqual(trackBg?.isHidden, false, "Track background must be visible")
    }
}


// MARK: - E. Debug Cleanup (Defect 5)

final class DebugCleanupTests: XCTestCase {

    @MainActor
    func test_timelineView_hasExactlyOneAudioTrack() {
        let timeline = TimelineView(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        timeline.layoutIfNeeded()

        var audioTrackCount = 0
        func countAudioTracks(in view: UIView) {
            if view is AudioTrackView { audioTrackCount += 1 }
            for sub in view.subviews { countAudioTracks(in: sub) }
        }
        countAudioTracks(in: timeline)

        XCTAssertEqual(audioTrackCount, 1,
            "TimelineView must have exactly 1 AudioTrackView — no synthetic debug tracks")
    }
}

// MARK: - Playback-Start Render Payload Ownership (render-freeze)

/// Proves the playback-start epoch OWNS the first rendered timeline payload for the
/// requested start frame `N`, and that pre-boundary/first-sub-frame display ticks
/// preserve it instead of re-deriving it through the async resolve path.
///
/// Uses the resolvable `makeFullyBootedRuntime` harness (scene_1 cached) so the start
/// frame actually resolves to a render payload — the seam this contract is about.
final class PlaybackStartRenderFreezeTests: XCTestCase {

    /// Drives the async playback-start task to the running phase, polling cooperatively.
    @MainActor
    private func waitForPlaybackStart(_ runtime: EditorRuntime) async {
        for _ in 0..<40 {
            await Task.yield()
            if runtime.isPlaying { break }
        }
    }

    /// Render-freeze: pressing Play from a nonzero frame `N` installs the epoch-owned
    /// frozen render payload for `N` as `currentRenderSource`. A deliberately stale
    /// pre-Play render source (wrong frame tag) must NOT survive into running playback.
    ///
    /// Fails on pre-fix code: `currentRenderSource` was only written by the async
    /// `applyResolvedTimelineFrame` path, so at the instant playback became running the
    /// render source was still the stale pre-Play value.
    @MainActor
    func test_startPlayback_installsFrozenRenderSourceForN() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }
        guard let (session, runtime) = await makeFullyBootedRuntime(device: device, commandQueue: commandQueue) else {
            throw XCTSkip("Could not boot runtime")
        }
        runtime.audioSessionManager = MockPreviewAudioSessionManager()
        runtime.setPreviewAudioController(MockPreviewAudioController())

        // Let the boot-time frame-0 resolve settle, then overwrite with a STALE payload
        // for a different frame so a missing freeze step is observable.
        for _ in 0..<10 { await Task.yield() }
        let staleFrame = 999
        let staleResolved = try await unwrapResolved(runtime, frame: 0)
        runtime.currentRenderSource = .timeline(TimelineRenderSourcePayload(
            resolvedFrame: staleResolved,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            diagnosticFrameTag: staleFrame,
            overlayItems: []
        ))

        let startFrame = 30
        session.dispatch(.setPlayhead(compressedFrame: startFrame))

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)

        XCTAssertTrue(runtime.isPlaying, "Play must reach the running phase")

        guard case .timeline(let payload) = runtime.currentRenderSource else {
            return XCTFail("Render source must be .timeline after Play, owned by the epoch")
        }
        XCTAssertEqual(payload.diagnosticFrameTag, startFrame,
            "The frozen render payload must be the requested start frame N")
        XCTAssertNotEqual(payload.diagnosticFrameTag, staleFrame,
            "The stale pre-Play render source must not survive into running playback")
        XCTAssertEqual(runtime.activePlaybackStartEpoch?.boundary.requestedCompressedFrame, startFrame,
            "The active epoch must own the start frame")

        runtime.stopPlayback()
        XCTAssertNil(runtime.activePlaybackStartEpoch,
            "Stop must clear the active epoch")
    }

    /// Render-freeze: while transport is holding the start frame (pre-boundary / first
    /// sub-frame tick), a display tick must NOT launch a new async render resolve, and
    /// the frozen `N` payload is preserved.
    ///
    /// Fails on pre-fix code: every timeline tick called
    /// `handleTimelineModePlayheadChanged`, scheduling a new
    /// `resolveAndPresentTimelineFrame` (observable via `timelinePresentResolveCount`),
    /// so the held start frame was re-resolved and could be overwritten.
    @MainActor
    func test_displayTick_whileHoldingStartFrame_doesNotReResolve() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }
        guard let (session, runtime) = await makeFullyBootedRuntime(device: device, commandQueue: commandQueue) else {
            throw XCTSkip("Could not boot runtime")
        }
        runtime.audioSessionManager = MockPreviewAudioSessionManager()
        runtime.setPreviewAudioController(MockPreviewAudioController())

        for _ in 0..<10 { await Task.yield() }
        let startFrame = 30
        session.dispatch(.setPlayhead(compressedFrame: startFrame))

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        XCTAssertTrue(runtime.isPlaying)

        XCTAssertTrue(runtime.testTransportIsHoldingStartFrame,
            "Transport must be holding the start frame immediately after epoch start")

        let resolveCountBefore = runtime.timelinePresentResolveCount
        let revisionBefore = runtime.renderSourceRevision

        // Pre-boundary display tick (defaults to the epoch boundary host time).
        runtime.simulateDisplayTickForTesting()

        XCTAssertTrue(runtime.testTransportIsHoldingStartFrame,
            "Pre-boundary tick must keep the transport holding the start frame")
        XCTAssertEqual(runtime.timelinePresentResolveCount, resolveCountBefore,
            "While holding the start frame, the tick must NOT launch a new async render resolve")

        guard case .timeline(let payload) = runtime.currentRenderSource else {
            return XCTFail("Render source must remain .timeline")
        }
        XCTAssertEqual(payload.diagnosticFrameTag, startFrame,
            "The frozen N payload must be preserved across a hold tick")
        XCTAssertEqual(runtime.renderSourceRevision, revisionBefore,
            "No re-resolve means no new render-source emission while holding N")

        runtime.stopPlayback()
    }

    /// Render-freeze hard gate: when the start frame does NOT resolve a render payload,
    /// `startPlayback()` must keep the boundary closed — it must not set `isPlaying`,
    /// must not leave an `activePlaybackStartEpoch`, and must not emit
    /// `.playbackStateChanged(true)`. A stale pre-Play `currentRenderSource` may remain
    /// while paused, but it is never treated as the first running frame.
    ///
    /// (Repair #2 instruction 4.) Boots WITHOUT pre-populating the engine resources
    /// cache, so the scene type cannot be created and `makePlaybackStartFrameSnapshot`
    /// resolves to `.failed(.missingDependency)` → nil snapshot → aborted start.
    @MainActor
    func test_startPlayback_missingRenderPayload_keepsBoundaryClosed() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }
        // Boot WITHOUT the resources cache so frame resolution fails.
        guard let (session, runtime) = await makeBootedRuntimeWithoutResources(device: device, commandQueue: commandQueue) else {
            throw XCTSkip("Could not boot runtime")
        }
        runtime.audioSessionManager = MockPreviewAudioSessionManager()
        runtime.setPreviewAudioController(MockPreviewAudioController())

        var sawPlayingTrue = false
        runtime.onOutput = { output in
            if case .playbackStateChanged(let isPlaying) = output, isPlaying { sawPlayingTrue = true }
        }

        session.dispatch(.setPlayhead(compressedFrame: 30))

        runtime.startPlayback()
        // Give the start task real time to run its async phases and (correctly) abort.
        for _ in 0..<60 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            if runtime.isPlaying { break }
        }

        XCTAssertFalse(runtime.isPlaying,
            "Start must NOT open the boundary when the start frame has no render payload")
        XCTAssertNil(runtime.activePlaybackStartEpoch,
            "No epoch may be left active when the render payload is missing")
        XCTAssertFalse(sawPlayingTrue,
            "playbackStateChanged(true) must NOT be emitted for a render-gated start")

        runtime.stopPlayback()
    }

    /// Render-freeze scrub-to-play: with a STALE current render source (frame `M`) and a
    /// pending playhead resolve in flight, pressing Play from the scrubbed/committed
    /// playhead frame `N` must install the frozen payload for `N` (not `M`), and a
    /// pre-boundary hold tick must not re-resolve or overwrite it.
    ///
    /// (Repair #2 instruction 5.)
    @MainActor
    func test_scrubToPlay_installsScrubbedFrameNotStale() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }
        guard let (session, runtime) = await makeFullyBootedRuntime(device: device, commandQueue: commandQueue) else {
            throw XCTSkip("Could not boot runtime")
        }
        runtime.audioSessionManager = MockPreviewAudioSessionManager()
        runtime.setPreviewAudioController(MockPreviewAudioController())

        for _ in 0..<10 { await Task.yield() }

        // Simulate a prior scrub that left a STALE render source for frame M and a pending
        // async playhead resolve (scrub-to-play must invalidate both).
        let staleFrameM = 12
        let staleResolved = try await unwrapResolved(runtime, frame: 0)
        runtime.currentRenderSource = .timeline(TimelineRenderSourcePayload(
            resolvedFrame: staleResolved,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            diagnosticFrameTag: staleFrameM,
            overlayItems: []
        ))
        // Kick a pending playhead resolve at M (the stale scrub resolve still in flight).
        runtime.handlePlayheadChanged(staleFrameM)

        // The committed scrub playhead is N (≈3s region). Play from N.
        let scrubbedFrameN = 45
        session.dispatch(.setPlayhead(compressedFrame: scrubbedFrameN))

        runtime.startPlayback()
        await waitForPlaybackStart(runtime)
        XCTAssertTrue(runtime.isPlaying, "Play must reach running for a resolvable scrubbed frame")

        guard case .timeline(let payload) = runtime.currentRenderSource else {
            return XCTFail("Render source must be .timeline after scrub-to-play")
        }
        XCTAssertEqual(payload.diagnosticFrameTag, scrubbedFrameN,
            "Scrub-to-play must install the scrubbed frame N, not the stale frame M")
        XCTAssertNotEqual(payload.diagnosticFrameTag, staleFrameM,
            "The stale scrub render source for M must not survive into running playback")
        XCTAssertEqual(runtime.activePlaybackStartEpoch?.boundary.requestedCompressedFrame, scrubbedFrameN)

        // A pre-boundary hold tick must not re-resolve / overwrite the frozen N payload,
        // even though a stale resolve for M was pending before Play.
        let resolveCountBefore = runtime.timelinePresentResolveCount
        runtime.simulateDisplayTickForTesting()
        XCTAssertEqual(runtime.timelinePresentResolveCount, resolveCountBefore,
            "Hold tick must not launch a stale async resolve after scrub-to-play")
        if case .timeline(let after) = runtime.currentRenderSource {
            XCTAssertEqual(after.diagnosticFrameTag, scrubbedFrameN,
                "Frozen N payload must be preserved across the hold tick")
        } else {
            XCTFail("Render source must remain .timeline")
        }

        runtime.stopPlayback()
    }

    /// Resolves a real `ResolvedTimelineFrame` from the runtime's engine, for seeding a
    /// stale render source.
    @MainActor
    private func unwrapResolved(_ runtime: EditorRuntime, frame: Int) async throws -> ResolvedTimelineFrame {
        let engine = try XCTUnwrap(runtime.testTimelineCompositionEngine)
        await engine.prepareForPlayback(startingAt: frame)
        guard case .resolved(let resolved) = await engine.resolveFrame(frame, policy: .presentation) else {
            throw XCTSkip("Frame \(frame) did not resolve in this environment")
        }
        return resolved
    }

    // MARK: - Texture-binding boundary (hold-phase no media publication)

    /// Boots a runtime, then swaps in a spy-backed `TimelineCompositionEngine` that uses
    /// the SAME `canonicalTimeline` the session already has (so session + engine agree on
    /// frame boundaries / instance ids) and routes per-scene media sync through a
    /// `MediaSyncingSpy`. The spy reports media-ready immediately, so production
    /// `startPlayback()` resolves frame `N` and opens the boundary through the real path,
    /// while every `syncPlaybackTick -> updateVideoFramesForPlayback` call is recorded.
    /// Returns the runtime and the spy. Returns nil if Metal is unavailable.
    @MainActor
    private func makeSpyBackedRuntime(
        device: MTLDevice, commandQueue: MTLCommandQueue
    ) async -> (EditorSession, EditorRuntime, SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy)? {
        guard let (session, runtime) = await makeFullyBootedRuntime(device: device, commandQueue: commandQueue) else {
            return nil
        }
        guard let editorState = session.state else { return nil }

        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true

        // Spy engine cache: the same scene type the session/boot uses (`scene_1`, 90f).
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        cache.addToCache(makeMinimalResources(durationFrames: 90, sceneTypeId: "scene_1"))

        let spyEngine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: session.mediaLocator,
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )
        // Apply the SAME timeline the session has so session/engine agree.
        spyEngine.setTimeline(
            editorState.canonicalTimeline,
            sceneStates: editorState.draft.sceneInstanceStates,
            assetRegistry: editorState.draft.assetRegistry.selfHealed(for: editorState.draft)
        )
        runtime.injectTimelineCompositionEngine(spyEngine)
        runtime.audioSessionManager = MockPreviewAudioSessionManager()
        runtime.setPreviewAudioController(MockPreviewAudioController())
        return (session, runtime, spy)
    }

    /// Real-time deadline wait for the production start task to reach running. The
    /// spy-backed engine's `prepareForPlayback` readiness settles on real time, so a
    /// cooperative yield loop can return before `isPlaying`.
    @MainActor
    private func waitForPlaybackStartRealTime(_ runtime: EditorRuntime, timeout: TimeInterval = 2.0) async {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while !runtime.isPlaying && CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    /// Texture-binding boundary: while transport holds the start frame `N`, a display tick
    /// must NOT invoke timeline media sync (`engine.syncPlaybackTick ->
    /// updateVideoFramesForPlayback`), because that polls video providers and writes
    /// textures into the mutable provider the frozen `ResolvedTimelineFrame` references —
    /// changing a render-visible binding while transport still claims `N` (the start-time
    /// tick/glint). The spy must observe ZERO grant-aware tick calls during the hold.
    ///
    /// Fails on pre-fix code: the hold branch of `processPlaybackTick` called
    /// `syncPlaybackTick(...)`, so the spy recorded a tick during the hold.
    @MainActor
    func test_holdPhaseTick_doesNotPublishMediaBinding() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }
        guard let (session, runtime, spy) = await makeSpyBackedRuntime(device: device, commandQueue: commandQueue) else {
            throw XCTSkip("Could not boot spy-backed runtime")
        }

        let startFrame = 30
        session.dispatch(.setPlayhead(compressedFrame: startFrame))

        runtime.startPlayback()
        await waitForPlaybackStartRealTime(runtime)
        XCTAssertTrue(runtime.isPlaying, "Play must reach running")
        XCTAssertTrue(runtime.testTransportIsHoldingStartFrame,
            "Transport must be holding the start frame immediately after epoch start")

        // The start-frame handoff (engine.startPlayback(epoch:)) legitimately schedules
        // providers once via the grant-aware START call. Snapshot the per-tick publication
        // count and drive a hold-phase display tick.
        let tickCallsBefore = spy.grantTickCalls.count
        runtime.simulateDisplayTickForTesting()  // pre-boundary hold tick

        XCTAssertTrue(runtime.testTransportIsHoldingStartFrame,
            "Pre-boundary tick must keep transport holding the start frame")
        XCTAssertEqual(spy.grantTickCalls.count, tickCallsBefore,
            "During the start-frame hold, a display tick must NOT invoke media sync (no binding publication)")

        runtime.stopPlayback()
    }

    /// Paired contract: once transport advances by an integer frame from `N`
    /// (`isHoldingStartFrame == false`), normal media sync resumes — exactly once per
    /// tick — using the tick's authoritative compressed frame and host time.
    ///
    /// Asserts a SYNCHRONOUS call-count delta around a single
    /// `simulateDisplayTickForTesting(hostTime:)` (not a fragile absolute count after
    /// async waiting), and captures the grant-aware host time the resumed sync used.
    @MainActor
    func test_firstAdvanceTick_resumesMediaSyncWithAuthoritativeFrameAndHostTime() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }
        guard let (session, runtime, spy) = await makeSpyBackedRuntime(device: device, commandQueue: commandQueue) else {
            throw XCTSkip("Could not boot spy-backed runtime")
        }

        let startFrame = 30
        session.dispatch(.setPlayhead(compressedFrame: startFrame))

        runtime.startPlayback()
        await waitForPlaybackStartRealTime(runtime)
        XCTAssertTrue(runtime.isPlaying)

        let boundary = try XCTUnwrap(runtime.activePlaybackStartEpoch?.boundary.hostTime,
            "An active epoch boundary host time must exist after Play")

        // Advance transport well past the boundary so `isHoldingStartFrame` is false and an
        // integer frame has elapsed. Host time = boundary + ~5 frame intervals @30fps.
        let frameInterval = 1.0 / 30.0
        let advancedHostTime = boundary + frameInterval * 5.0

        // Synchronous call-count delta around exactly one advancing tick.
        let tickCallsBefore = spy.grantTickCalls.count
        let hostTimesBefore = spy.grantTickHostTimes.count
        runtime.simulateDisplayTickForTesting(hostTime: advancedHostTime)

        XCTAssertFalse(runtime.testTransportIsHoldingStartFrame,
            "Transport must have advanced past the start frame for this tick")
        XCTAssertEqual(spy.grantTickCalls.count, tickCallsBefore + 1,
            "After advancing past the hold, exactly one media-sync tick must occur")

        // The resumed sync must use the tick's authoritative host time.
        XCTAssertEqual(spy.grantTickHostTimes.count, hostTimesBefore + 1)
        let usedHostTime = try XCTUnwrap(spy.grantTickHostTimes.last ?? nil,
            "Resumed media sync must carry the tick host time")
        XCTAssertEqual(usedHostTime, advancedHostTime, accuracy: 1e-9,
            "Resumed media sync must use the advancing tick's authoritative host time")

        // And the authoritative advanced compressed frame (> N).
        let syncedFrame = try XCTUnwrap(spy.grantTickCalls.last?.frame)
        XCTAssertGreaterThan(syncedFrame, startFrame,
            "Resumed media sync must use the advanced compressed frame, not the held N")

        runtime.stopPlayback()
    }
}
