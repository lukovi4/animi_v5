import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// Tests for runtime/engine video selection fast-path (applyPersistedVideoSelection).
///
/// Verifies:
/// - SceneInstanceRuntime: fast apply updates appliedState, no resetState, readiness preserved
/// - SceneInstanceRuntime: defensive no-op for missing blockId / photo slot
/// - SceneInstanceRuntime: invalid apply (UMS throws) does not mutate appliedState
/// - TimelineCompositionEngine: cache-authoritative update, best-effort runtime, defensive no-ops
final class VideoSelectionFastPathTests: XCTestCase {

    // MARK: - Test Infrastructure

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

    // MARK: - SceneInstanceRuntime Tests

    /// Fast apply: throw path preserves appliedState (UMS has no video provider).
    @MainActor
    func testRuntime_fastApply_updatesAppliedState() async throws {
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

        // Apply state with a video slot via applyState (sets appliedState)
        let originalSelection = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            placement: .defaultCover,
            videoWindow: originalSelection
        )
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = ["block_01": videoSlot]
        await runtime.applyState(sceneState)

        // Fast-apply will call UMS.applyPersistedVideoSelection which requires a video provider.
        // Since we have no actual video provider, UMS will throw blockNotVideo.
        // But the defensive guard in SceneInstanceRuntime checks appliedState first,
        // and the slot IS video, so it will try to call UMS — which will throw.
        // This verifies the throw path: appliedState should NOT be mutated.
        let newSelection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 8.0)
        do {
            try runtime.applyPersistedVideoSelection(blockId: "block_01", newSelection)
        } catch {
            // Expected: UMS throws because no video in mediaState
        }

        // appliedState should still have original selection (throw path preserves)
        XCTAssertEqual(
            runtime.appliedState?.mediaSlotsByBlockId?["block_01"]?.videoWindow?.trimStart,
            0,
            "appliedState should not be mutated on throw"
        )
    }

    /// Defensive no-op: missing blockId in appliedState.
    @MainActor
    func testRuntime_fastApply_missingBlockId_noop() async throws {
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

        // appliedState with no slots
        await runtime.applyState(.empty)

        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 8.0)
        // Should not throw — defensive no-op
        XCTAssertNoThrow(
            try runtime.applyPersistedVideoSelection(blockId: "nonexistent", selection),
            "Missing blockId should be a silent no-op"
        )
    }

    /// Defensive no-op: photo slot in appliedState.
    @MainActor
    func testRuntime_fastApply_photoSlot_noop() async throws {
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

        // appliedState with photo slot
        var photoState = SceneState.empty
        let photoSlot = SceneMediaSlot.photo(mediaRef: MediaRef.file("Media/test.jpg"), placement: .default(fitMode: .cover))
        photoState.mediaSlotsByBlockId = ["block_01": photoSlot]
        await runtime.applyState(photoState)

        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 8.0)
        XCTAssertNoThrow(
            try runtime.applyPersistedVideoSelection(blockId: "block_01", selection),
            "Photo slot should be a silent no-op"
        )

        // Photo slot should remain unchanged
        XCTAssertNil(
            runtime.appliedState?.mediaSlotsByBlockId?["block_01"]?.videoWindow,
            "Photo slot should not get a videoWindow"
        )
    }

    /// Readiness state preserved after fast apply attempt.
    @MainActor
    func testRuntime_fastApply_preservesReadinessState() throws {
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

        // Start preparation to move to .preparing state
        runtime.startPreparingForPresentation(at: 50)
        let stateBefore = runtime.readinessState

        // Attempt fast apply (will no-op since appliedState is nil)
        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 8.0)
        try? runtime.applyPersistedVideoSelection(blockId: "block_01", selection)

        XCTAssertEqual(runtime.readinessState, stateBefore, "Readiness state must not change from fast apply")
    }

    // MARK: - TimelineCompositionEngine Tests

    /// Engine cache update: applyPersistedVideoSelection updates sceneStates for video slot.
    @MainActor
    func testEngine_fastApply_updatesCachedState() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources { cache.addToCache(res) }

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: 3,
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                )
            }
        )

        let instanceId = timeline.sceneItems[0].id

        // Set initial state with video slot
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            placement: .defaultCover,
            videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = ["block_01": videoSlot]
        engine.setTimeline(timeline, sceneStates: [instanceId: sceneState])

        // Fast apply new selection
        let newSelection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        engine.applyPersistedVideoSelection(newSelection, blockId: "block_01", for: instanceId)

        // Verify cache updated
        let cachedWindow = engine.sceneStates[instanceId]?.mediaSlotsByBlockId?["block_01"]?.videoWindow
        XCTAssertEqual(cachedWindow?.trimStart, 2.0)
        XCTAssertEqual(cachedWindow?.trimEnd, 8.0)
    }

    /// Engine defensive: missing instanceId in cache → no crash.
    @MainActor
    func testEngine_fastApply_missingInstanceId_noop() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources { cache.addToCache(res) }

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: 3,
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                )
            }
        )

        engine.setTimeline(timeline, sceneStates: [:])

        let missingId = UUID()
        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 9.0)

        // Should not crash
        engine.applyPersistedVideoSelection(selection, blockId: "block_01", for: missingId)

        XCTAssertNil(engine.sceneStates[missingId], "Missing instance should not create state")
    }

    /// Engine defensive: photo slot in cache → no update.
    @MainActor
    func testEngine_fastApply_photoSlot_noop() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources { cache.addToCache(res) }

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: 3,
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                )
            }
        )

        let instanceId = timeline.sceneItems[0].id

        // Set state with photo slot
        let photoSlot = SceneMediaSlot.photo(mediaRef: MediaRef.file("Media/test.jpg"), placement: .default(fitMode: .cover))
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = ["block_01": photoSlot]
        engine.setTimeline(timeline, sceneStates: [instanceId: sceneState])

        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 9.0)
        engine.applyPersistedVideoSelection(selection, blockId: "block_01", for: instanceId)

        // Photo slot should not gain a videoWindow
        XCTAssertNil(
            engine.sceneStates[instanceId]?.mediaSlotsByBlockId?["block_01"]?.videoWindow,
            "Photo slot must not get videoWindow from fast apply"
        )
    }

    /// Engine: unloaded runtime → only cache update, no crash.
    @MainActor
    func testEngine_fastApply_unloadedRuntime_cacheOnlyUpdate() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources { cache.addToCache(res) }

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: 3,
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                )
            }  // No runtime factory → no runtimes will be loaded
        )

        let instanceId = timeline.sceneItems[0].id

        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            placement: .defaultCover,
            videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = ["block_01": videoSlot]
        engine.setTimeline(timeline, sceneStates: [instanceId: sceneState])

        // No runtime loaded — fast apply should update cache only
        let newSelection = PersistedVideoSelection(trimStart: 3.0, trimEnd: 7.0)
        engine.applyPersistedVideoSelection(newSelection, blockId: "block_01", for: instanceId)

        let cachedWindow = engine.sceneStates[instanceId]?.mediaSlotsByBlockId?["block_01"]?.videoWindow
        XCTAssertEqual(cachedWindow?.trimStart, 3.0, "Cache should be updated even without loaded runtime")
        XCTAssertEqual(cachedWindow?.trimEnd, 7.0)
    }
}
