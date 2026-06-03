import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// TT-02: Tests for TimelineCompositionEngine readiness handling.
final class TimelineCompositionEngineReadinessTests: XCTestCase {

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
    private func makeMinimalTimeline(sceneCount: Int, framesPerScene: Int = 100) -> (CanonicalTimeline, [SceneTypeResourcesCache.Resources]) {
        var items: [TimelineItem] = []
        var payloads: [UUID: TimelinePayload] = [:]
        var resources: [SceneTypeResourcesCache.Resources] = []

        for i in 0..<sceneCount {
            let instanceId = UUID()
            let payloadId = UUID()
            let sceneTypeId = "scene-type-\(i)"

            // TimelineItem uses microseconds, not frames
            let durationUs = framesToUs(framesPerScene)
            let item = TimelineItem(
                id: instanceId,
                payloadId: payloadId,
                kind: .scene,
                startUs: nil,  // Derived from cumulative sum for sceneSequence
                durationUs: durationUs
            )
            items.append(item)

            let scenePayload = ScenePayload(sceneTypeId: sceneTypeId)
            payloads[payloadId] = .scene(scenePayload)

            let res = makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeId)
            resources.append(res)
        }

        // Create sceneSequence track with items
        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: items)
        let timeline = CanonicalTimeline(
            tracks: [sceneTrack],
            payloads: payloads,
            boundaryTransitions: [:]
        )

        return (timeline, resources)
    }

    // MARK: - Single Scene Presentation Tests

    /// TT-02: Single scene, policy .presentation: returns .hold when runtime is .created/.preparing
    @MainActor
    func testSingleScenePresentationHoldWhenNotReady() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)

        // Create cache and add resources
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        // Create spy that will be used by runtime factory
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false  // Not ready

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

        engine.setTimeline(timeline, sceneStates: [:])

        // First call should return .hold because runtime starts in .created
        let result = await engine.resolveFrame(50, policy: .presentation)
        guard case .hold = result else {
            XCTFail("Expected .hold, got \(result)")
            return
        }
    }

    /// TT-02: Single scene, policy .presentation: returns .resolved when runtime is .ready
    @MainActor
    func testSingleScenePresentationResolvedWhenReady() async throws {
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
        spy.isSceneMediaReady = true  // Ready immediately

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

        engine.setTimeline(timeline, sceneStates: [:])

        // First call triggers preparation, but since spy.isSceneMediaReady = true,
        // the loop should complete quickly and return .resolved
        // Note: This test may be flaky due to async timing - we use prepareForPlayback first
        await engine.prepareForPlayback(startingAt: 50)

        let result = await engine.resolveFrame(50, policy: .presentation)

        if case .resolved = result {
            // Success
        } else {
            XCTFail("Expected .resolved, got \(result)")
        }
    }

    // MARK: - Stretched-Scene Scrub Media Frame (Repair)

    /// Full presentation path: a scene stretched past its native animation
    /// duration must resolve a `SceneRenderContext` whose render `localFrame` is
    /// CLAMPED to the last native frame (hold-last visuals) while `mediaLocalFrame`
    /// stays UNCLAMPED so video still sampling keeps tracking the playhead across
    /// the full stretched block. Exercises `setTimeline -> prepareForPlayback ->
    /// resolveFrame -> makeRenderContext`, the real scrub path.
    @MainActor
    func testStretchedScene_resolveBeyondNativeDuration_keepsUnclampedMediaFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let nativeFrames = 100
        let stretchedFrames = 200   // timeline holds the scene for 200 frames
        let beyondNativeFrame = 150 // scrub past native duration, inside stretched span

        // Single scene whose timeline duration (200f) exceeds native duration (100f).
        let instanceId = UUID()
        let payloadId = UUID()
        let sceneTypeId = "scene-type-stretched"
        let item = TimelineItem(
            id: instanceId,
            payloadId: payloadId,
            kind: .scene,
            startUs: nil,
            durationUs: framesToUs(stretchedFrames)
        )
        let timeline = CanonicalTimeline(
            tracks: [Track(id: UUID(), kind: .sceneSequence, items: [item])],
            payloads: [payloadId: .scene(ScenePayload(sceneTypeId: sceneTypeId))],
            boundaryTransitions: [:]
        )
        let res = makeMinimalResources(durationFrames: nativeFrames, sceneTypeId: sceneTypeId)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        cache.addToCache(res)

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

        engine.setTimeline(timeline, sceneStates: [:])
        await engine.prepareForPlayback(startingAt: beyondNativeFrame)

        let result = await engine.resolveFrame(beyondNativeFrame, policy: .presentation)
        guard case .resolved(.single(let ctx)) = result else {
            XCTFail("Expected .resolved(.single) for stretched scene, got \(result)")
            return
        }

        XCTAssertEqual(ctx.localFrame, nativeFrames - 1,
            "Render/visibility frame must be clamped to the last native frame (hold-last)")
        XCTAssertEqual(ctx.mediaLocalFrame, beyondNativeFrame,
            "Media frame must stay UNCLAMPED so stretched-scene scrub video tracks the playhead")
    }

    /// Warm interactive stop: `stopPlaybackPreservingTextures()` must route to each
    /// runtime's preserving deactivation (hold-last, `flush: false`) rather than the
    /// flushing `pause()`. This keeps video textures/providers warm for the first
    /// scrub frame after Pause.
    @MainActor
    func testStopPlaybackPreservingTextures_routesToPreservingPath() async throws {
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
        engine.setTimeline(timeline, sceneStates: [:])
        await engine.prepareForPlayback(startingAt: 0)

        engine.stopPlaybackPreservingTextures()

        XCTAssertGreaterThanOrEqual(spy.softStopPreservingTexturesCalls, 1,
            "Warm stop must use the texture-preserving deactivation (flush: false), not the flushing pause")
    }

    /// TT-02: Terminal failure returns .failed, not .hold
    @MainActor
    func testTerminalFailureReturnsFailedNotHold() async throws {
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
        spy.isSceneMediaReady = false
        spy.hasFailedMedia = true  // Will cause failure

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

        engine.setTimeline(timeline, sceneStates: [:])

        // Prepare to trigger failure
        await engine.prepareForPlayback(startingAt: 50)

        let result = await engine.resolveFrame(50, policy: .presentation)

        if case .failed(let failure) = result {
            if case .dependencyFailed(_, let reason) = failure {
                XCTAssertEqual(reason, "Media restore failed")
            } else {
                XCTFail("Expected dependencyFailed, got \(failure)")
            }
        } else {
            XCTFail("Expected .failed, got \(result)")
        }
    }

    /// TT-02: Generation mismatch returns .staleGeneration
    @MainActor
    func testGenerationMismatchReturnsStaleGeneration() async throws {
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

        engine.setTimeline(timeline, sceneStates: [:])

        // Get current generation
        let gen = engine.currentScrubGeneration

        // Invalidate scrub (increment generation)
        engine.invalidateScrub()

        // Resolve with old generation
        let result = await engine.resolveFrame(50, generation: gen, policy: .presentation)

        guard case .staleGeneration = result else {
            XCTFail("Expected .staleGeneration, got \(result)")
            return
        }
    }

    /// TT-02: Already ready runtime returns .resolved without downgrading to .preparing
    @MainActor
    func testAlreadyReadyDoesNotDowngrade() async throws {
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

        engine.setTimeline(timeline, sceneStates: [:])

        // Prepare first
        await engine.prepareForPlayback(startingAt: 50)

        // First resolve should be .resolved
        let result1 = await engine.resolveFrame(50, policy: .presentation)
        guard case .resolved = result1 else {
            XCTFail("First resolve should be .resolved")
            return
        }

        // Get runtime and verify it's ready
        let instanceId = timeline.sceneItems[0].id
        guard let runtime = engine.runtime(for: instanceId) else {
            XCTFail("Runtime should exist")
            return
        }
        XCTAssertTrue(runtime.isReady)

        // Second resolve for different frame should also be .resolved (not .hold)
        let result2 = await engine.resolveFrame(75, policy: .presentation)
        guard case .resolved = result2 else {
            XCTFail("Second resolve should be .resolved, got \(result2)")
            return
        }

        // Runtime should still be ready
        XCTAssertTrue(runtime.isReady)
    }

    // MARK: - Export Policy Tests

    /// TT-02: Export policy blocks until ready, never returns .hold
    @MainActor
    func testExportPolicyBlocksUntilReady() async throws {
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
        spy.isSceneMediaReady = true  // Will become ready during wait

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

        engine.setTimeline(timeline, sceneStates: [:])

        // Export policy should block until ready
        let result = await engine.resolveFrame(50, policy: .export)

        // Should be .resolved (export waits), not .hold
        if case .resolved = result {
            // Success
        } else {
            XCTFail("Expected .resolved for export policy, got \(result)")
        }
    }

    // MARK: - Invalid Timeline Tests

    /// TT-02: Missing timeline returns .failed(.invalidTimeline)
    @MainActor
    func testMissingTimelineReturnsFailed() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)

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
                    mediaLocator: StubProjectMediaLocator()
                )
            }
        )

        // Don't set timeline

        let result = await engine.resolveFrame(50, policy: .presentation)

        if case .failed(.invalidTimeline) = result {
            // Success
        } else {
            XCTFail("Expected .failed(.invalidTimeline), got \(result)")
        }
    }

    // MARK: - Transition Readiness Tests (P1)

    /// TT-02: Transition returns .hold until both scenes are ready
    @MainActor
    func testTransitionPresentationHoldUntilBothReady() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // Create timeline with 2 scenes and a transition between them
        let result = makeTimelineWithTransition()

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in result.resources {
            cache.addToCache(res)
        }

        // Create separate spies for each scene - deterministic mapping by instanceId
        let spyA = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        let spyB = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spyA.isSceneMediaReady = false  // Scene A not ready
        spyB.isSceneMediaReady = true   // Scene B ready

        // Map spies by instanceId, not by creation order
        let spyMap: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [
            result.instanceIdA: spyA,
            result.instanceIdB: spyB
        ]

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                // Deterministic spy assignment by instanceId
                let spy = spyMap[instanceId] ?? SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )

        engine.setTimeline(result.timeline, sceneStates: [:])

        // Resolve frame in transition zone (frame 95 is in transition)
        let resolveResult = await engine.resolveFrame(95, policy: .presentation)

        // Should return .hold because scene A is not ready
        guard case .hold = resolveResult else {
            XCTFail("Expected .hold when one scene is not ready, got \(resolveResult)")
            return
        }
    }

    /// TT-02: Transition returns .resolved when both scenes are ready
    @MainActor
    func testTransitionPresentationResolvedWhenBothReady() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let transitionResult = makeTimelineWithTransition()

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in transitionResult.resources {
            cache.addToCache(res)
        }

        // Both scenes will be ready - use shared spy
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

        engine.setTimeline(transitionResult.timeline, sceneStates: [:])

        // Prepare first
        await engine.prepareForPlayback(startingAt: 95)

        // Resolve frame in transition zone
        let resolveResult = await engine.resolveFrame(95, policy: .presentation)

        // Should return .resolved with transition context
        guard case .resolved(let frame) = resolveResult else {
            XCTFail("Expected .resolved, got \(resolveResult)")
            return
        }

        // Verify it's a transition frame
        guard case .transition = frame else {
            XCTFail("Expected transition frame, got single")
            return
        }
    }

    /// TT-02: No partial transition - both scenes must be ready
    @MainActor
    func testNoPartialTransition() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let transitionResult = makeTimelineWithTransition()

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in transitionResult.resources {
            cache.addToCache(res)
        }

        // Scene A ready, scene B not ready - deterministic mapping by instanceId
        let spyA = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        let spyB = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spyA.isSceneMediaReady = true
        spyB.isSceneMediaReady = false

        // Map spies by instanceId, not by creation order
        let spyMap: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [
            transitionResult.instanceIdA: spyA,
            transitionResult.instanceIdB: spyB
        ]

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                // Deterministic spy assignment by instanceId
                let spy = spyMap[instanceId] ?? SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )

        engine.setTimeline(transitionResult.timeline, sceneStates: [:])

        // Resolve in transition zone
        let resolveResult = await engine.resolveFrame(95, policy: .presentation)

        // Should be .hold (no partial transition allowed)
        guard case .hold = resolveResult else {
            XCTFail("Expected .hold for partial transition, got \(resolveResult)")
            return
        }
    }

    /// TT-02: prepareForPlayback in transition waits for exact frameA/frameB
    @MainActor
    func testPrepareForPlaybackTransitionWaitsExactFrames() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let transitionResult = makeTimelineWithTransition()

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in transitionResult.resources {
            cache.addToCache(res)
        }

        // Create separate spies for each scene to verify exact frames
        let spyA = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        let spyB = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spyA.isSceneMediaReady = true
        spyB.isSceneMediaReady = true

        // Map spies by instanceId for deterministic assignment
        let spyMap: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [
            transitionResult.instanceIdA: spyA,
            transitionResult.instanceIdB: spyB
        ]

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                let spy = spyMap[instanceId] ?? SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )

        engine.setTimeline(transitionResult.timeline, sceneStates: [:])

        // Choose a compressed frame in the transition zone
        let compressedFrame = 95

        // Calculate expected local frames using TimelineTransitionMath
        // sceneItems are already TimelineItem - use directly
        let math = TimelineTransitionMath(
            sceneItems: transitionResult.timeline.sceneItems,
            boundaryTransitions: transitionResult.timeline.boundaryTransitions,
            fps: 30
        )

        guard let renderMode = math.renderMode(for: compressedFrame) else {
            XCTFail("renderMode should return valid mode for frame \(compressedFrame)")
            return
        }

        // Verify we're in a transition
        guard case .transition(_, let expectedFrameA, _, let expectedFrameB, _, _) = renderMode else {
            XCTFail("Expected transition renderMode, got \(renderMode)")
            return
        }

        // Prepare at transition frame
        await engine.prepareForPlayback(startingAt: compressedFrame)

        // Both runtimes should be ready after prepare
        guard let runtimeA = engine.runtime(for: transitionResult.instanceIdA),
              let runtimeB = engine.runtime(for: transitionResult.instanceIdB) else {
            XCTFail("Runtimes should exist after prepareForPlayback")
            return
        }
        XCTAssertTrue(runtimeA.isReady, "Runtime A should be ready after prepareForPlayback in transition")
        XCTAssertTrue(runtimeB.isReady, "Runtime B should be ready after prepareForPlayback in transition")

        // Verify exact frames were requested via still API
        XCTAssertTrue(
            spyA.stillFrames.contains(expectedFrameA),
            "SpyA should have still exact frame \(expectedFrameA), got \(spyA.stillFrames)"
        )
        XCTAssertTrue(
            spyB.stillFrames.contains(expectedFrameB),
            "SpyB should have still exact frame \(expectedFrameB), got \(spyB.stillFrames)"
        )
    }

    // MARK: - Transition Terminal Branch Tests (TT-02 Acceptance)

    /// TT-02: Transition returns .failed(.dependencyFailed) when one dependency fails
    @MainActor
    func testTransitionPresentationFailedWhenDependencyFailed() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let transitionResult = makeTimelineWithTransition()

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in transitionResult.resources {
            cache.addToCache(res)
        }

        // Scene A will fail, scene B ready
        let spyA = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        let spyB = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spyA.isSceneMediaReady = false
        spyA.hasFailedMedia = true  // Failure condition
        spyB.isSceneMediaReady = true

        let spyMap: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [
            transitionResult.instanceIdA: spyA,
            transitionResult.instanceIdB: spyB
        ]

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                let spy = spyMap[instanceId] ?? SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )

        engine.setTimeline(transitionResult.timeline, sceneStates: [:])

        // First, drive dependency A to terminal .failed state via prepareForPlayback
        await engine.prepareForPlayback(startingAt: 95)

        // Verify runtime A reached .failed
        guard let runtimeA = engine.runtime(for: transitionResult.instanceIdA) else {
            XCTFail("Runtime A should exist")
            return
        }
        guard case .failed = runtimeA.readinessState else {
            XCTFail("Runtime A should be in .failed state, got \(runtimeA.readinessState)")
            return
        }

        // Now resolve should return .failed, not .hold
        let resolveResult = await engine.resolveFrame(95, policy: .presentation)

        guard case .failed(let failure) = resolveResult else {
            XCTFail("Expected .failed, got \(resolveResult)")
            return
        }
        guard case .dependencyFailed(let failedId, let reason) = failure else {
            XCTFail("Expected .dependencyFailed, got \(failure)")
            return
        }
        XCTAssertEqual(failedId, transitionResult.instanceIdA, "Failed instance ID should match scene A")
        XCTAssertEqual(reason, "Media restore failed")
    }

    /// TT-02: Transition returns .failed(.dependencyTimedOut) when one dependency times out
    @MainActor
    func testTransitionPresentationFailedWhenDependencyTimedOut() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let transitionResult = makeTimelineWithTransition()

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in transitionResult.resources {
            cache.addToCache(res)
        }

        // Scene A will timeout (never ready, no failure), scene B ready
        let spyA = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        let spyB = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spyA.isSceneMediaReady = false
        spyA.hasFailedMedia = false  // Not failed, just slow/hanging
        spyB.isSceneMediaReady = true

        let spyMap: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [
            transitionResult.instanceIdA: spyA,
            transitionResult.instanceIdB: spyB
        ]

        // Need to pass timingConfig for fast timeout - use closure capture
        let timingConfigMap: [UUID: PreparationTimingConfig] = [
            transitionResult.instanceIdA: .fastForTesting,  // 100ms timeout
            transitionResult.instanceIdB: .production
        ]

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                let spy = spyMap[instanceId] ?? SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                let timing = timingConfigMap[instanceId] ?? .production
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy,
                    timingConfig: timing
                )
            }
        )

        engine.setTimeline(transitionResult.timeline, sceneStates: [:])

        // Drive dependency A to terminal .timedOut state via prepareForPlayback
        await engine.prepareForPlayback(startingAt: 95)

        // Verify runtime A reached .timedOut
        guard let runtimeA = engine.runtime(for: transitionResult.instanceIdA) else {
            XCTFail("Runtime A should exist")
            return
        }
        guard case .timedOut = runtimeA.readinessState else {
            XCTFail("Runtime A should be in .timedOut state, got \(runtimeA.readinessState)")
            return
        }

        // Now resolve should return .failed(.dependencyTimedOut), not .hold
        let resolveResult = await engine.resolveFrame(95, policy: .presentation)

        guard case .failed(let failure) = resolveResult else {
            XCTFail("Expected .failed, got \(resolveResult)")
            return
        }
        guard case .dependencyTimedOut(let timedOutId) = failure else {
            XCTFail("Expected .dependencyTimedOut, got \(failure)")
            return
        }
        XCTAssertEqual(timedOutId, transitionResult.instanceIdA, "Timed out instance ID should match scene A")
    }

    /// TT-02: Transition export returns .resolved(.transition) when both ready
    @MainActor
    func testTransitionExportResolvedWhenBothReady() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let transitionResult = makeTimelineWithTransition()

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in transitionResult.resources {
            cache.addToCache(res)
        }

        // Both scenes ready
        let spyA = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        let spyB = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spyA.isSceneMediaReady = true
        spyB.isSceneMediaReady = true

        let spyMap: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [
            transitionResult.instanceIdA: spyA,
            transitionResult.instanceIdB: spyB
        ]

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                let spy = spyMap[instanceId] ?? SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )

        engine.setTimeline(transitionResult.timeline, sceneStates: [:])

        // Export policy should block and return .resolved for transition
        let resolveResult = await engine.resolveFrame(95, policy: .export)

        guard case .resolved(let frame) = resolveResult else {
            XCTFail("Expected .resolved, got \(resolveResult)")
            return
        }

        // Verify it's a transition frame, not single
        guard case .transition = frame else {
            XCTFail("Expected .transition frame, got \(frame)")
            return
        }
    }

    /// TT-02: Transition export returns .failed(.dependencyTimedOut) when one dependency times out
    @MainActor
    func testTransitionExportFailedWhenDependencyTimedOut() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let transitionResult = makeTimelineWithTransition()

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in transitionResult.resources {
            cache.addToCache(res)
        }

        // Scene A will timeout, scene B ready
        let spyA = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        let spyB = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spyA.isSceneMediaReady = false
        spyA.hasFailedMedia = false  // Not failed, just slow
        spyB.isSceneMediaReady = true

        let spyMap: [UUID: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy] = [
            transitionResult.instanceIdA: spyA,
            transitionResult.instanceIdB: spyB
        ]

        let timingConfigMap: [UUID: PreparationTimingConfig] = [
            transitionResult.instanceIdA: .fastForTesting,  // 100ms timeout
            transitionResult.instanceIdB: .production
        ]

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: StubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                let spy = spyMap[instanceId] ?? SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
                let timing = timingConfigMap[instanceId] ?? .production
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy,
                    timingConfig: timing
                )
            }
        )

        engine.setTimeline(transitionResult.timeline, sceneStates: [:])

        // Export policy will wait and should return .failed (not .hold)
        let resolveResult = await engine.resolveFrame(95, policy: .export)

        guard case .failed(let failure) = resolveResult else {
            XCTFail("Expected .failed, got \(resolveResult)")
            return
        }
        guard case .dependencyTimedOut(let timedOutId) = failure else {
            XCTFail("Expected .dependencyTimedOut, got \(failure)")
            return
        }
        XCTAssertEqual(timedOutId, transitionResult.instanceIdA, "Timed out instance ID should match scene A")
    }

    // MARK: - DEFECT-01 Proof Tests

    /// DEFECT-01 proof: warm prewarm does not await readiness —
    /// prewarmed warm scene should resolve via resolveFrame after prepareForPlayback.
    /// Primary oracle: black-box resolveFrame call (not internal readinessState).
    @MainActor
    func testPrewarmedWarmScene_resolvesReady_afterPrepareForPlayback() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // 3 scenes, no transitions
        let (timeline, resources) = makeMinimalTimeline(sceneCount: 3, framesPerScene: 100)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        // All spies report media ready immediately
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

        engine.setTimeline(timeline, sceneStates: [:])

        // Playhead at frame 150 = middle of scene 1 (index 1)
        // Budget coordinator will mark scene 0 and scene 2 as warm
        await engine.prepareForPlayback(startingAt: 150)

        let warmSceneId = timeline.sceneItems[0].id

        // Primary oracle: black-box resolveFrame for warm scene (frame 0 = scene 0)
        let result = await engine.resolveFrame(0, policy: .presentation)
        guard case .resolved(.single) = result else {
            XCTFail("Expected .resolved(.single(...)) for warm scene 0, got \(result)")
            return
        }

        // Secondary explanatory probe (not asserted)
        if let warmRuntime = engine.runtime(for: warmSceneId) {
            print("[DEFECT-01 probe] warmRuntime.readinessState = \(warmRuntime.readinessState)")
        }
    }

    /// DEFECT-01 proof: prewarmed transition partner is not ready —
    /// first transition frame returns .hold instead of .resolved(.transition(...)).
    @MainActor
    func testTransitionWithPrewarmedPartner_resolvesReady_afterPrepareForPlayback() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // 3 scenes with a 10-frame fade transition between scene 0 and scene 1
        let transitionResult = makeTimelineWithTransition3Scenes()

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in transitionResult.resources {
            cache.addToCache(res)
        }

        // All spies report media ready immediately
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

        engine.setTimeline(transitionResult.timeline, sceneStates: [:])

        // prepareForPlayback at frame 50 = single mode in scene 0
        // Scene 1 is warm (next scene)
        await engine.prepareForPlayback(startingAt: 50)

        // Scene 1 should be ready if partner prewarm works
        let warmSceneId = transitionResult.instanceIdB
        guard let warmRuntime = engine.runtime(for: warmSceneId) else {
            XCTFail("Warm scene 1 runtime should exist after prepareForPlayback")
            return
        }

        // Now resolve at transition frame (frame 95, in the transition zone)
        // If scene 1 were properly prewarmed, this would return .resolved(.transition(...))
        let resolveResult = await engine.resolveFrame(95, policy: .presentation)

        guard case .resolved(let frame) = resolveResult else {
            XCTFail("Expected .resolved at transition frame, got \(resolveResult)")
            return
        }
        guard case .transition = frame else {
            XCTFail("Expected .transition frame, got \(frame)")
            return
        }
    }

    // MARK: - Transition Test Helpers

    /// Result of makeTimelineWithTransition for deterministic spy mapping
    struct TransitionTimelineResult {
        let timeline: CanonicalTimeline
        let resources: [SceneTypeResourcesCache.Resources]
        let instanceIdA: UUID
        let instanceIdB: UUID
        let framesPerScene: Int
        let transitionDuration: Int
    }

    /// Creates a timeline with 2 scenes and a fade transition between them
    @MainActor
    private func makeTimelineWithTransition() -> TransitionTimelineResult {
        let framesPerScene = 100
        let transitionDuration = 10

        var items: [TimelineItem] = []
        var payloads: [UUID: TimelinePayload] = [:]
        var resources: [SceneTypeResourcesCache.Resources] = []

        // Scene A
        let instanceIdA = UUID()
        let payloadIdA = UUID()
        let sceneTypeIdA = "scene-type-A"

        let durationUsA = framesToUs(framesPerScene)
        let itemA = TimelineItem(
            id: instanceIdA,
            payloadId: payloadIdA,
            kind: .scene,
            startUs: nil,  // Derived from cumulative sum
            durationUs: durationUsA
        )
        items.append(itemA)
        payloads[payloadIdA] = .scene(ScenePayload(sceneTypeId: sceneTypeIdA))
        resources.append(makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeIdA))

        // Scene B
        let instanceIdB = UUID()
        let payloadIdB = UUID()
        let sceneTypeIdB = "scene-type-B"

        let durationUsB = framesToUs(framesPerScene)
        let itemB = TimelineItem(
            id: instanceIdB,
            payloadId: payloadIdB,
            kind: .scene,
            startUs: nil,  // Derived from cumulative sum
            durationUs: durationUsB
        )
        items.append(itemB)
        payloads[payloadIdB] = .scene(ScenePayload(sceneTypeId: sceneTypeIdB))
        resources.append(makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeIdB))

        // Transition between A and B
        let boundaryKey = SceneBoundaryKey(instanceIdA, instanceIdB)
        let transition = SceneTransition(type: .fade, durationFrames: transitionDuration)

        // Create sceneSequence track with items
        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: items)
        let timeline = CanonicalTimeline(
            tracks: [sceneTrack],
            payloads: payloads,
            boundaryTransitions: [boundaryKey: transition]
        )

        return TransitionTimelineResult(
            timeline: timeline,
            resources: resources,
            instanceIdA: instanceIdA,
            instanceIdB: instanceIdB,
            framesPerScene: framesPerScene,
            transitionDuration: transitionDuration
        )
    }

    /// Creates a timeline with 3 scenes and a fade transition between scene 0 and scene 1.
    /// Scene 2 has no transition — used for DEFECT-01 tests where scene 1 is a warm partner.
    @MainActor
    private func makeTimelineWithTransition3Scenes() -> TransitionTimelineResult {
        let framesPerScene = 100
        let transitionDuration = 10

        var items: [TimelineItem] = []
        var payloads: [UUID: TimelinePayload] = [:]
        var resources: [SceneTypeResourcesCache.Resources] = []

        // Scene A
        let instanceIdA = UUID()
        let payloadIdA = UUID()
        let sceneTypeIdA = "scene-type-A"

        let durationUsA = framesToUs(framesPerScene)
        let itemA = TimelineItem(
            id: instanceIdA,
            payloadId: payloadIdA,
            kind: .scene,
            startUs: nil,
            durationUs: durationUsA
        )
        items.append(itemA)
        payloads[payloadIdA] = .scene(ScenePayload(sceneTypeId: sceneTypeIdA))
        resources.append(makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeIdA))

        // Scene B
        let instanceIdB = UUID()
        let payloadIdB = UUID()
        let sceneTypeIdB = "scene-type-B"

        let durationUsB = framesToUs(framesPerScene)
        let itemB = TimelineItem(
            id: instanceIdB,
            payloadId: payloadIdB,
            kind: .scene,
            startUs: nil,
            durationUs: durationUsB
        )
        items.append(itemB)
        payloads[payloadIdB] = .scene(ScenePayload(sceneTypeId: sceneTypeIdB))
        resources.append(makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeIdB))

        // Scene C
        let instanceIdC = UUID()
        let payloadIdC = UUID()
        let sceneTypeIdC = "scene-type-C"

        let durationUsC = framesToUs(framesPerScene)
        let itemC = TimelineItem(
            id: instanceIdC,
            payloadId: payloadIdC,
            kind: .scene,
            startUs: nil,
            durationUs: durationUsC
        )
        items.append(itemC)
        payloads[payloadIdC] = .scene(ScenePayload(sceneTypeId: sceneTypeIdC))
        resources.append(makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeIdC))

        // Transition between A and B (10-frame fade)
        let boundaryKey = SceneBoundaryKey(instanceIdA, instanceIdB)
        let transition = SceneTransition(type: .fade, durationFrames: transitionDuration)

        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: items)
        let timeline = CanonicalTimeline(
            tracks: [sceneTrack],
            payloads: payloads,
            boundaryTransitions: [boundaryKey: transition]
        )

        return TransitionTimelineResult(
            timeline: timeline,
            resources: resources,
            instanceIdA: instanceIdA,
            instanceIdB: instanceIdB,
            framesPerScene: framesPerScene,
            transitionDuration: transitionDuration
        )
    }
}

// MARK: - Test Stubs

private struct StubMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/\(mediaRef.storagePath)")
    }
}
