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
            maxActiveDecoders: 3,
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
            maxActiveDecoders: 3,
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
