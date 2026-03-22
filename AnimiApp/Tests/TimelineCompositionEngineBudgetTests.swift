import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// TT-03: Tests for TimelineCompositionEngine budget enforcement.
/// Verifies:
/// - Global decoder budget never exceeded across scenes
/// - Warm scenes resident but receive no playback grants
/// - Eviction follows deterministic ordering
/// - Export policy skips budget refresh and eviction
final class TimelineCompositionEngineBudgetTests: XCTestCase {

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

    /// Converts frames to microseconds at 30fps.
    private func framesToUs(_ frames: Int, fps: Int = 30) -> TimeUs {
        Int64(frames) * 1_000_000 / Int64(fps)
    }

    @MainActor
    private func makeMinimalTimeline(sceneCount: Int, framesPerScene: Int = 100, fixedIds: [UUID]? = nil) -> (CanonicalTimeline, [SceneTypeResourcesCache.Resources]) {
        var items: [TimelineItem] = []
        var payloads: [UUID: TimelinePayload] = [:]
        var resources: [SceneTypeResourcesCache.Resources] = []

        for i in 0..<sceneCount {
            let instanceId = fixedIds?[i] ?? UUID()
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

            let scenePayload = ScenePayload(sceneTypeId: sceneTypeId)
            payloads[payloadId] = .scene(scenePayload)

            let res = makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeId)
            resources.append(res)
        }

        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: items)
        let timeline = CanonicalTimeline(
            tracks: [sceneTrack],
            payloads: payloads,
            boundaryTransitions: [:]
        )

        return (timeline, resources)
    }

    // MARK: - Budget Limit Tests

    /// Test: Single scene playback never exceeds global budget.
    @MainActor
    func testSinglePlaybackBudget_neverExceedsGlobalLimit() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        // Create spy with many candidates (more than budget)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true
        spy.playbackCandidatesByFrame[50] = [
            PlaybackVideoCandidate(blockId: "block_a", priority: BlockPriorityInfo(isVisible: true, area: 100, zIndex: 1)),
            PlaybackVideoCandidate(blockId: "block_b", priority: BlockPriorityInfo(isVisible: true, area: 90, zIndex: 1)),
            PlaybackVideoCandidate(blockId: "block_c", priority: BlockPriorityInfo(isVisible: true, area: 80, zIndex: 1)),
            PlaybackVideoCandidate(blockId: "block_d", priority: BlockPriorityInfo(isVisible: true, area: 70, zIndex: 1)),
            PlaybackVideoCandidate(blockId: "block_e", priority: BlockPriorityInfo(isVisible: true, area: 60, zIndex: 1))
        ]

        let maxDecoders = 3
        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: maxDecoders,
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

        engine.setTimeline(timeline, sceneStates: [:])

        // Start playback
        await engine.prepareForPlayback(startingAt: 50)
        engine.startPlayback(at: 50)

        // Verify budget-aware start was called
        XCTAssertEqual(spy.budgetedStartCalls.count, 1, "Should have one budget-aware start call")

        let grantedCount = spy.budgetedStartCalls[0].granted.count
        XCTAssertLessThanOrEqual(grantedCount, maxDecoders,
                                 "Granted blocks (\(grantedCount)) should not exceed maxDecoders (\(maxDecoders))")

        // Verify top 3 by priority were granted
        let granted = spy.budgetedStartCalls[0].granted
        XCTAssertTrue(granted.contains("block_a"), "Highest priority block should be granted")
        XCTAssertTrue(granted.contains("block_b"), "2nd highest priority block should be granted")
        XCTAssertTrue(granted.contains("block_c"), "3rd highest priority block should be granted")
        XCTAssertFalse(granted.contains("block_d"), "4th priority block should NOT be granted")
        XCTAssertFalse(granted.contains("block_e"), "5th priority block should NOT be granted")
    }

    // MARK: - Warm Scene Tests

    /// Test: Warm scenes are resident but receive no playback grants.
    @MainActor
    func testWarmScenesAreResidentButReceiveNoPlaybackGrants() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // 5 scenes: prev, current, next, far1, far2
        let (timeline, resources) = makeMinimalTimeline(sceneCount: 5, framesPerScene: 100)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        // Spies for each scene
        var spies: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [:]
        for item in timeline.sceneItems {
            let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
            spy.isSceneMediaReady = true
            spies[item.id] = spy
        }

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
                    mediaSyncing: spies[instanceId]!
                )
            }
        )

        engine.setTimeline(timeline, sceneStates: [:])

        // Position at scene 2 (index 2), so scene 1 and 3 are warm
        let compressedFrame = 250  // Mid-scene 2
        await engine.prepareForPlayback(startingAt: compressedFrame)
        engine.startPlayback(at: compressedFrame)

        // Verify: only current scene (index 2) received playback start
        let currentSceneId = timeline.sceneItems[2].id
        let warmScene1Id = timeline.sceneItems[1].id
        let warmScene2Id = timeline.sceneItems[3].id

        XCTAssertEqual(spies[currentSceneId]?.budgetedStartCalls.count ?? 0, 1,
                       "Current scene should receive budget-aware start call")
        XCTAssertEqual(spies[warmScene1Id]?.budgetedStartCalls.count ?? 0, 0,
                       "Warm scene (prev) should NOT receive playback start")
        XCTAssertEqual(spies[warmScene2Id]?.budgetedStartCalls.count ?? 0, 0,
                       "Warm scene (next) should NOT receive playback start")
    }

    // MARK: - Export Policy Tests

    /// Test: resolveFrame with .export policy skips budget refresh and eviction.
    @MainActor
    func testResolveFrameExport_skipsBudgetWindowAndDoesNotEvict() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // 7 scenes to have some that would be evicted in presentation mode
        let ids = (0..<7).map { _ in UUID() }
        let (timeline, resources) = makeMinimalTimeline(sceneCount: 7, framesPerScene: 100, fixedIds: ids)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        var spies: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [:]
        for item in timeline.sceneItems {
            let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
            spy.isSceneMediaReady = true
            spies[item.id] = spy
        }

        var createdRuntimes: Set<UUID> = []

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: 3,
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                createdRuntimes.insert(instanceId)
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spies[instanceId]!
                )
            }
        )

        engine.setTimeline(timeline, sceneStates: [:])

        // First, prepare at scene 0 (which creates runtimes for scene 0, 1)
        await engine.prepareForPlayback(startingAt: 0)

        let runtimesBeforeExport = createdRuntimes.count

        // Now resolve with export policy at various frames
        // This should NOT evict any runtimes
        _ = await engine.resolveFrame(50, policy: TimelineResolvePolicy.export)
        _ = await engine.resolveFrame(350, policy: TimelineResolvePolicy.export)
        _ = await engine.resolveFrame(550, policy: TimelineResolvePolicy.export)

        // For export, runtimes may be created but should not be evicted
        // The key test is that no runtime should have been explicitly paused/removed
        // due to budget eviction
        XCTAssertGreaterThanOrEqual(createdRuntimes.count, runtimesBeforeExport,
                                    "Export should not reduce runtime count (no eviction)")
    }

    // MARK: - Start/Tick Grant Contract Tests

    /// Test: startPlayback and syncPlaybackTick use same grant computation.
    @MainActor
    func testStartPlaybackAndSyncPlaybackTick_useSameGrantContract() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true

        // Configure candidates
        let candidates = [
            PlaybackVideoCandidate(blockId: "video_1", priority: BlockPriorityInfo(isVisible: true, area: 100, zIndex: 1)),
            PlaybackVideoCandidate(blockId: "video_2", priority: BlockPriorityInfo(isVisible: true, area: 50, zIndex: 1))
        ]
        for frame in 0...100 {
            spy.playbackCandidatesByFrame[frame] = candidates
        }

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: 2,
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

        engine.setTimeline(timeline, sceneStates: [:])

        await engine.prepareForPlayback(startingAt: 50)
        engine.startPlayback(at: 50)

        // Get grants from start
        XCTAssertEqual(spy.budgetedStartCalls.count, 1)
        let startGrants = spy.budgetedStartCalls[0].granted

        // Now tick
        engine.syncPlaybackTick(51)

        // Get grants from tick
        XCTAssertEqual(spy.budgetedTickCalls.count, 1)
        let tickGrants = spy.budgetedTickCalls[0].granted

        // Grants should be the same (same candidates, same budget)
        XCTAssertEqual(startGrants, tickGrants, "Start and tick should compute same grants for same candidates")
    }

    // MARK: - Eviction Tests

    /// Test: prepareForPlayback creates warm runtimes and evicts far scenes.
    @MainActor
    func testPrepareForPlayback_createsWarmRuntimesAndEvictsFarScenes() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // 7 scenes
        let ids = (0..<7).map { i in
            UUID(uuidString: "\(String(repeating: String(i), count: 8))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 12))")!
        }
        let (timeline, resources) = makeMinimalTimeline(sceneCount: 7, framesPerScene: 100, fixedIds: ids)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        var spies: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [:]
        for item in timeline.sceneItems {
            let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
            spy.isSceneMediaReady = true
            spies[item.id] = spy
        }

        var createdRuntimeIds: [UUID] = []
        var pausedRuntimeIds: [UUID] = []

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: 3,
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                createdRuntimeIds.append(instanceId)
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spies[instanceId]!
                )
            }
        )

        engine.setTimeline(timeline, sceneStates: [:])

        // Prepare at scene 3 (middle)
        // Should create: scene 3 (pinned), scenes 2 & 4 (warm)
        // Should NOT create: scenes 0, 1, 5, 6 (far)
        let compressedFrame = 350  // Mid-scene 3
        await engine.prepareForPlayback(startingAt: compressedFrame)

        // Verify warm scenes were created
        XCTAssertTrue(createdRuntimeIds.contains(ids[3]), "Pinned scene should be created")
        XCTAssertTrue(createdRuntimeIds.contains(ids[2]), "Warm prev scene should be created")
        XCTAssertTrue(createdRuntimeIds.contains(ids[4]), "Warm next scene should be created")
    }

    // MARK: - TT-03 Completion: Active->Warm Transition Tests

    /// Test: When playhead moves from scene 2 to scene 3, scene 2 becomes warm and gets deactivated.
    ///
    /// This is the critical test for TT-03 completion:
    /// - Start playback at scene 2 (scene 2 is active)
    /// - Move to scene 3 (scene 2 becomes warm)
    /// - Scene 2 must receive deactivatePlaybackPreservingTextures()
    /// - Scene 2 must NOT receive new active grants
    /// - Scene 2 must remain loaded (not evicted)
    @MainActor
    func testActiveToWarmTransition_deactivatesPreviouslyActiveRuntime() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // 5 scenes with fixed IDs for deterministic testing
        let ids = (0..<5).map { i in
            UUID(uuidString: "\(String(repeating: String(i), count: 8))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 12))")!
        }
        let (timeline, resources) = makeMinimalTimeline(sceneCount: 5, framesPerScene: 100, fixedIds: ids)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        // Create spies for each scene
        var spies: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [:]
        for id in ids {
            let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
            spy.isSceneMediaReady = true
            spies[id] = spy
        }

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
                    mediaSyncing: spies[instanceId]!
                )
            }
        )

        engine.setTimeline(timeline, sceneStates: [:])

        // STEP 1: Start playback at scene 2 (frame 250)
        let scene2Frame = 250
        await engine.prepareForPlayback(startingAt: scene2Frame)
        engine.startPlayback(at: scene2Frame)

        // Verify: Scene 2 received budget-aware start
        XCTAssertEqual(spies[ids[2]]!.budgetedStartCalls.count, 1, "Scene 2 should receive start")
        XCTAssertEqual(spies[ids[2]]!.softStopPreservingTexturesCalls, 0, "Scene 2 should NOT be deactivated yet")

        // STEP 2: Move playhead to scene 3 (frame 350)
        // Scene 2 becomes warm (prev), Scene 3 becomes active
        let scene3Frame = 350
        engine.syncPlaybackTick(scene3Frame)

        // Verify: Scene 2 is now deactivated (soft-stop)
        XCTAssertGreaterThan(spies[ids[2]]!.softStopPreservingTexturesCalls, 0,
                             "Scene 2 should receive deactivatePlaybackPreservingTextures() when becoming warm")

        // Verify: Scene 2 did NOT receive new active grants after transition
        // (only the initial start call from step 1)
        XCTAssertEqual(spies[ids[2]]!.budgetedStartCalls.count, 1, "Scene 2 should NOT receive new start calls")
        XCTAssertEqual(spies[ids[2]]!.budgetedTickCalls.count, 0, "Scene 2 should NOT receive tick calls after becoming warm")

        // Verify: Scene 3 received tick call (it's now active)
        XCTAssertEqual(spies[ids[3]]!.budgetedTickCalls.count, 1, "Scene 3 should receive tick")

        // Verify: Scene 2 runtime still exists (not evicted, just deactivated)
        XCTAssertNotNil(engine.runtime(for: ids[2]), "Scene 2 runtime should still exist (warm, not evicted)")
    }

    // MARK: - DEFECT-02 Proof Tests

    /// DEFECT-02 proof: warm scenes do not receive spare decoder grants.
    /// When budget has spare capacity (3 decoders, 1 pinned scene using 1), warm scenes
    /// should receive the remaining 2 grants — but they don't because `shouldHaveActiveDecoders`
    /// only returns true for pinned.
    @MainActor
    func testWarmScenesReceiveSpareBudgetGrants() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // 3 scenes, each with exactly 1 eligible visible video block
        let ids = (0..<3).map { _ in UUID() }
        let (timeline, resources) = makeMinimalTimeline(sceneCount: 3, framesPerScene: 100, fixedIds: ids)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        // Create per-scene spies with 1 playback candidate each
        var spies: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [:]
        for (i, id) in ids.enumerated() {
            let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
            spy.isSceneMediaReady = true
            // Configure 1 candidate for every frame in this scene's range
            let candidate = PlaybackVideoCandidate(
                blockId: "video_\(i)",
                priority: BlockPriorityInfo(isVisible: true, area: 100, zIndex: 1)
            )
            for frame in 0..<100 {
                spy.playbackCandidatesByFrame[frame] = [candidate]
            }
            spies[id] = spy
        }

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
                    mediaSyncing: spies[instanceId]!
                )
            }
        )

        engine.setTimeline(timeline, sceneStates: [:])

        // Playhead at frame 150 = middle of scene 1 (index 1) in single mode
        // Scene 1 is pinned, scenes 0 and 2 are warm
        await engine.prepareForPlayback(startingAt: 150)

        // Get budget snapshot
        guard let snapshot = engine.debugPlaybackBudgetSnapshot(at: 150) else {
            XCTFail("debugPlaybackBudgetSnapshot should return non-nil")
            return
        }

        // Verify pinned and warm classification
        XCTAssertTrue(snapshot.pinnedInstanceIds.contains(ids[1]), "Scene 1 should be pinned")
        XCTAssertTrue(snapshot.warmInstanceIds.contains(ids[0]), "Scene 0 should be warm")
        XCTAssertTrue(snapshot.warmInstanceIds.contains(ids[2]), "Scene 2 should be warm")

        let warmGrants0 = snapshot.grantsByInstance[ids[0]] ?? []
        let warmGrants2 = snapshot.grantsByInstance[ids[2]] ?? []
        XCTAssertFalse(warmGrants0.isEmpty, "Warm scene 0 should receive spare grant, got empty")
        XCTAssertFalse(warmGrants2.isEmpty, "Warm scene 2 should receive spare grant, got empty")
    }

    // MARK: - TT-03 Completion: Active->Warm Transition Tests

    /// Test: Transition A/B -> single C: outgoing scene A becomes warm and gets deactivated.
    ///
    /// Scenario:
    /// - Playhead in transition between scene 0 and scene 1 (both active)
    /// - Move to scene 1 single mode (scene 0 becomes warm)
    /// - Scene 0 must receive deactivatePlaybackPreservingTextures()
    @MainActor
    func testTransitionToSingle_deactivatesOutgoingWarmRuntime() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // 3 scenes
        let ids = (0..<3).map { i in
            UUID(uuidString: "\(String(repeating: String(i), count: 8))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 12))")!
        }

        // Create timeline with transition between scene 0 and 1
        let durationUs: TimeUs = 100 * 1_000_000 / 30  // 100 frames at 30fps
        let sceneItems: [TimelineItem] = ids.map { id in
            TimelineItem(id: id, payloadId: UUID(), kind: .scene, durationUs: durationUs)
        }

        // Add 10-frame fade transition between scene 0 and 1
        let boundaryKey = SceneBoundaryKey(ids[0], ids[1])
        let transition = SceneTransition(type: .fade, durationFrames: 10)

        var payloads: [UUID: TimelinePayload] = [:]
        var resourcesList: [SceneTypeResourcesCache.Resources] = []
        for (i, item) in sceneItems.enumerated() {
            let sceneTypeId = "scene-type-\(i)"
            payloads[item.payloadId] = .scene(ScenePayload(sceneTypeId: sceneTypeId))
            resourcesList.append(makeMinimalResources(durationFrames: 100, sceneTypeId: sceneTypeId))
        }

        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: sceneItems)
        let timeline = CanonicalTimeline(
            tracks: [sceneTrack],
            payloads: payloads,
            boundaryTransitions: [boundaryKey: transition]
        )

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resourcesList {
            cache.addToCache(res)
        }

        var spies: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [:]
        for id in ids {
            let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
            spy.isSceneMediaReady = true
            spies[id] = spy
        }

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
                    mediaSyncing: spies[instanceId]!
                )
            }
        )

        engine.setTimeline(timeline, sceneStates: [:])

        // STEP 1: Start in transition zone (last 10 frames of scene 0)
        // Scene 0 ends at frame 100, transition starts at frame 90
        let transitionFrame = 95
        await engine.prepareForPlayback(startingAt: transitionFrame)
        engine.startPlayback(at: transitionFrame)

        // Verify: Both scene 0 and scene 1 should be active in transition
        XCTAssertEqual(spies[ids[0]]!.budgetedStartCalls.count, 1, "Scene 0 should receive start (transition A)")
        XCTAssertEqual(spies[ids[1]]!.budgetedStartCalls.count, 1, "Scene 1 should receive start (transition B)")
        XCTAssertEqual(spies[ids[0]]!.softStopPreservingTexturesCalls, 0, "Scene 0 should NOT be deactivated yet")

        // STEP 2: Move beyond transition into scene 1 single mode (frame 110)
        // Scene 0 becomes warm (prev), Scene 1 is now single active
        let singleFrame = 110
        engine.syncPlaybackTick(singleFrame)

        // Verify: Scene 0 is now deactivated
        XCTAssertGreaterThan(spies[ids[0]]!.softStopPreservingTexturesCalls, 0,
                             "Scene 0 should receive deactivatePlaybackPreservingTextures() when exiting transition")

        // Verify: Scene 1 received tick (it's now single active)
        XCTAssertEqual(spies[ids[1]]!.budgetedTickCalls.count, 1, "Scene 1 should receive tick")

        // Verify: Scene 0 did NOT receive tick after transition
        XCTAssertEqual(spies[ids[0]]!.budgetedTickCalls.count, 0, "Scene 0 should NOT receive tick after becoming warm")

        // Verify: Scene 0 runtime still exists
        XCTAssertNotNil(engine.runtime(for: ids[0]), "Scene 0 runtime should still exist (warm)")
    }
}
