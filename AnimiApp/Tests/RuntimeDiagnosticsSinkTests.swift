import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// Tests for RuntimeDiagnosticsSink and RenderDiagnosticsSink event emission.
/// Verifies that all 9 diagnostic events are emitted at the correct call sites.
final class RuntimeDiagnosticsSinkTests: XCTestCase {

    // MARK: - Test Spy

    /// Thread-safe spy that collects both runtime and render diagnostic events.
    @MainActor
    final class DiagnosticsSpy: RuntimeDiagnosticsSink, RenderDiagnosticsSink, @unchecked Sendable {
        private(set) var runtimeEvents: [RuntimeDiagnosticEvent] = []
        private(set) var renderEvents: [RenderDiagnosticEvent] = []

        nonisolated func receive(_ event: RenderDiagnosticEvent) {
            // Note: render events may arrive from non-main thread in production,
            // but in tests we control the call site.
            // For test purposes, we store directly since tests are @MainActor.
            MainActor.assumeIsolated {
                renderEvents.append(event)
            }
        }

        func receive(_ event: RuntimeDiagnosticEvent) {
            runtimeEvents.append(event)
        }

        func reset() {
            runtimeEvents.removeAll()
            renderEvents.removeAll()
        }
    }

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

    @MainActor
    private func makeEngineWithSpy(
        sceneCount: Int = 1,
        framesPerScene: Int = 100,
        maxActiveDecoders: Int = 3,
        spy: DiagnosticsSpy,
        mediaSpy: SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy
    ) -> (TimelineCompositionEngine, CanonicalTimeline, [SceneTypeResourcesCache.Resources]) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: sceneCount, framesPerScene: framesPerScene)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: maxActiveDecoders,
            mediaLocator: StubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: mediaSpy
                )
            },
            runtimeDiagnosticsSink: spy
        )

        engine.setTimeline(timeline, sceneStates: [:])

        return (engine, timeline, resources)
    }

    // MARK: - Test 1: Preload Events

    /// Verifies sceneTypePreloadStarted/Completed are emitted on cache miss.
    /// Since we pre-fill the cache in tests, preload fallback doesn't trigger.
    /// This test verifies the nil-sink safety path instead (no crash when preload used with cached resources).
    @MainActor
    func testPreloadEvents_cachedResources_noPreloadEmitted() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device not available")
        }

        let spy = DiagnosticsSpy()
        let mediaSpy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        mediaSpy.isSceneMediaReady = true

        let (engine, _, _) = makeEngineWithSpy(spy: spy, mediaSpy: mediaSpy)

        // Resolve frame — resources are cached, so no preload events expected
        await engine.prepareForPlayback(startingAt: 50)

        let preloadStarted = spy.runtimeEvents.filter {
            if case .sceneTypePreloadStarted = $0 { return true }
            return false
        }
        // No preload events when cache hit
        XCTAssertTrue(preloadStarted.isEmpty, "No preload events expected for cached resources")
    }

    // MARK: - Test 1b: Preload Events — Cache Miss

    /// Verifies sceneTypePreloadStarted and sceneTypePreloadFailed are emitted on cache miss.
    /// Engine has a valid timeline but the cache has no resources and no URL provider,
    /// so preload() throws SceneCacheError.noURLProvider.
    @MainActor
    func testPreloadEvents_cacheMiss_emitsStartedAndFailed() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let spy = DiagnosticsSpy()
        let mediaSpy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        mediaSpy.isSceneMediaReady = true

        // Build a timeline with 1 scene but do NOT add resources to cache
        let (timeline, _) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)

        // Empty cache — no resources, no sceneURLProvider
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)

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
                    mediaSyncing: mediaSpy
                )
            },
            runtimeDiagnosticsSink: spy
        )

        engine.setTimeline(timeline, sceneStates: [:])

        // prepareForPlayback → getOrCreateRuntime → cache miss → preload → throw (no URL provider)
        await engine.prepareForPlayback(startingAt: 50)

        let preloadStarted = spy.runtimeEvents.filter {
            if case .sceneTypePreloadStarted = $0 { return true }
            return false
        }
        let preloadFailed = spy.runtimeEvents.filter {
            if case .sceneTypePreloadFailed = $0 { return true }
            return false
        }

        XCTAssertFalse(preloadStarted.isEmpty, "sceneTypePreloadStarted should be emitted on cache miss")
        XCTAssertFalse(preloadFailed.isEmpty, "sceneTypePreloadFailed should be emitted when preload throws")
    }

    // MARK: - Test 2: Prepare Started/Completed

    /// Verifies instancePrepareStarted and instancePrepareCompleted are emitted.
    @MainActor
    func testPrepareStartedAndCompleted() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device not available")
        }

        let spy = DiagnosticsSpy()
        let mediaSpy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        mediaSpy.isSceneMediaReady = true

        let (engine, timeline, _) = makeEngineWithSpy(spy: spy, mediaSpy: mediaSpy)

        await engine.prepareForPlayback(startingAt: 50)

        let instanceId = timeline.sceneItems[0].id

        let prepareStarted = spy.runtimeEvents.contains {
            if case .instancePrepareStarted(let id, _) = $0 { return id == instanceId }
            return false
        }
        let prepareCompleted = spy.runtimeEvents.contains {
            if case .instancePrepareCompleted(let id, _) = $0 { return id == instanceId }
            return false
        }

        XCTAssertTrue(prepareStarted, "instancePrepareStarted should be emitted")
        XCTAssertTrue(prepareCompleted, "instancePrepareCompleted should be emitted")
    }

    // MARK: - Test 3: Prepare Failed

    /// Verifies instancePrepareFailed is emitted when media fails.
    @MainActor
    func testPrepareFailed() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device not available")
        }

        let spy = DiagnosticsSpy()
        let mediaSpy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        mediaSpy.isSceneMediaReady = false
        mediaSpy.hasFailedMedia = true

        let (engine, timeline, _) = makeEngineWithSpy(spy: spy, mediaSpy: mediaSpy)

        await engine.prepareForPlayback(startingAt: 50)

        let instanceId = timeline.sceneItems[0].id

        let prepareFailed = spy.runtimeEvents.contains {
            if case .instancePrepareFailed(let id, _) = $0 { return id == instanceId }
            return false
        }

        XCTAssertTrue(prepareFailed, "instancePrepareFailed should be emitted for failed media")
    }

    // MARK: - Test 4: Media Restore

    /// Verifies mediaRestore event is emitted during applyState.
    @MainActor
    func testMediaRestore() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let spy = DiagnosticsSpy()
        let mediaSpy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        mediaSpy.isSceneMediaReady = true

        let resources = makeMinimalResources(durationFrames: 100, sceneTypeId: "test-type")

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: mediaSpy
        )
        runtime.runtimeDiagnosticsSink = spy

        // Apply empty state — should emit mediaRestore(restoredCount: 0)
        await runtime.applyState(.empty)

        let mediaRestore = spy.runtimeEvents.contains {
            if case .mediaRestore = $0 { return true }
            return false
        }

        XCTAssertTrue(mediaRestore, "mediaRestore event should be emitted during applyState")
    }

    // MARK: - Test 5: Transition Partner Ready

    /// Verifies transitionPartnerReady is emitted when both scenes resolve in transition.
    @MainActor
    func testTransitionPartnerReady() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let spy = DiagnosticsSpy()
        let mediaSpy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        mediaSpy.isSceneMediaReady = true

        // Create 2-scene timeline with transition
        let framesPerScene = 100
        let instanceIdA = UUID()
        let instanceIdB = UUID()
        let payloadIdA = UUID()
        let payloadIdB = UUID()

        let durationUs = framesToUs(framesPerScene)

        let items = [
            TimelineItem(id: instanceIdA, payloadId: payloadIdA, kind: .scene, startUs: nil, durationUs: durationUs),
            TimelineItem(id: instanceIdB, payloadId: payloadIdB, kind: .scene, startUs: nil, durationUs: durationUs)
        ]

        let payloads: [UUID: TimelinePayload] = [
            payloadIdA: .scene(ScenePayload(sceneTypeId: "scene-type-A")),
            payloadIdB: .scene(ScenePayload(sceneTypeId: "scene-type-B"))
        ]

        let boundaryKey = SceneBoundaryKey(instanceIdA, instanceIdB)
        let transition = SceneTransition(type: .fade, durationFrames: 10)

        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: items)
        let timeline = CanonicalTimeline(
            tracks: [sceneTrack],
            payloads: payloads,
            boundaryTransitions: [boundaryKey: transition]
        )

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        let resA = makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: "scene-type-A")
        let resB = makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: "scene-type-B")
        cache.addToCache(resA)
        cache.addToCache(resB)

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
                    mediaSyncing: mediaSpy
                )
            },
            runtimeDiagnosticsSink: spy
        )

        engine.setTimeline(timeline, sceneStates: [:])

        // Prepare at transition frame
        await engine.prepareForPlayback(startingAt: 95)

        // Resolve in transition zone — both must be ready
        let result = await engine.resolveFrame(95, policy: .presentation)

        guard case .resolved(.transition) = result else {
            XCTFail("Expected resolved transition, got \(result)")
            return
        }

        let partnerReady = spy.runtimeEvents.contains {
            if case .transitionPartnerReady = $0 { return true }
            return false
        }

        XCTAssertTrue(partnerReady, "transitionPartnerReady should be emitted when both scenes are ready")
    }

    // MARK: - Test 6: First Composited Frame

    /// Verifies firstCompositedFrame is emitted with the diagnostic frame tag.
    @MainActor
    func testFirstCompositedFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let spy = DiagnosticsSpy()

        // Create a minimal render request with diagnostic tag
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 100, height: 100,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Cannot create texture")
        }

        let renderer: MetalRenderer
        do {
            renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
        } catch {
            throw XCTSkip("Cannot create renderer: \(error)")
        }

        let ctx = SceneRenderContext(
            commands: [],
            textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(),
            assetSizes: [:],
            localFrame: 0,
            canvasSize: SizeD(width: 100, height: 100),
            sceneInstanceId: UUID()
        )

        let request = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: texture,
            drawableScale: 1.0,
            timelineCanvasSize: SizeD(width: 100, height: 100),
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            diagnosticFrameTag: 42
        )

        try TimelineRenderExecutor.render(
            request,
            renderer: renderer,
            commandQueue: commandQueue,
            transitionCompositor: nil,
            completionQueue: nil,
            renderSink: spy
        )

        let firstFrame = spy.renderEvents.contains {
            if case .firstCompositedFrame(let tag) = $0 { return tag == 42 }
            return false
        }

        XCTAssertTrue(firstFrame, "firstCompositedFrame(frameTag: 42) should be emitted")
    }

    // MARK: - Test 7: Compositor Encode Time

    /// Verifies compositorEncodeTime is emitted for transition renders.
    /// Requires actual Metal transition — skipped if no Metal device.
    @MainActor
    func testCompositorEncodeTime() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let spy = DiagnosticsSpy()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 100, height: 100,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Cannot create texture")
        }

        let renderer: MetalRenderer
        let compositor: TransitionCompositor
        do {
            renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
            compositor = try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)
        } catch {
            throw XCTSkip("Cannot create renderer/compositor: \(error)")
        }

        let canvasSize = SizeD(width: 100, height: 100)
        let ctxA = SceneRenderContext(
            commands: [],
            textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(),
            assetSizes: [:],
            localFrame: 0,
            canvasSize: canvasSize,
            sceneInstanceId: UUID()
        )
        let ctxB = SceneRenderContext(
            commands: [],
            textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(),
            assetSizes: [:],
            localFrame: 0,
            canvasSize: canvasSize,
            sceneInstanceId: UUID()
        )
        let transCtx = TransitionRenderContext(
            sceneA: ctxA,
            sceneB: ctxB,
            transition: SceneTransition(type: .fade, durationFrames: 10),
            progress: 0.5
        )

        let request = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: texture,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: true
        )

        try TimelineRenderExecutor.render(
            request,
            renderer: renderer,
            commandQueue: commandQueue,
            transitionCompositor: compositor,
            completionQueue: nil,
            renderSink: spy
        )

        let encodeTime = spy.renderEvents.contains {
            if case .compositorEncodeTime = $0 { return true }
            return false
        }

        XCTAssertTrue(encodeTime, "compositorEncodeTime should be emitted for transition render")
    }

    // MARK: - Test 8: Offscreen Render A

    /// Verifies offscreenRenderA is emitted during transition.
    @MainActor
    func testOffscreenRenderA() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let spy = DiagnosticsSpy()
        let instanceIdA = UUID()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 100, height: 100,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Cannot create texture")
        }

        let renderer: MetalRenderer
        let compositor: TransitionCompositor
        do {
            renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
            compositor = try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)
        } catch {
            throw XCTSkip("Cannot create renderer/compositor: \(error)")
        }

        let canvasSize = SizeD(width: 100, height: 100)
        let ctxA = SceneRenderContext(
            commands: [], textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(), assetSizes: [:],
            localFrame: 0, canvasSize: canvasSize, sceneInstanceId: instanceIdA
        )
        let ctxB = SceneRenderContext(
            commands: [], textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(), assetSizes: [:],
            localFrame: 0, canvasSize: canvasSize, sceneInstanceId: UUID()
        )
        let transCtx = TransitionRenderContext(
            sceneA: ctxA, sceneB: ctxB,
            transition: SceneTransition(type: .fade, durationFrames: 10),
            progress: 0.5
        )

        let request = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: texture, drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil, backgroundTextureProvider: nil,
            clearColorOverride: nil, presentationDrawable: nil,
            waitUntilCompleted: true
        )

        try TimelineRenderExecutor.render(
            request, renderer: renderer,
            commandQueue: commandQueue, transitionCompositor: compositor,
            completionQueue: nil, renderSink: spy
        )

        let offscreenA = spy.renderEvents.contains {
            if case .offscreenRenderA(let id) = $0 { return id == instanceIdA }
            return false
        }

        XCTAssertTrue(offscreenA, "offscreenRenderA should be emitted with scene A's instanceId")
    }

    // MARK: - Test 9: Offscreen Render B

    /// Verifies offscreenRenderB is emitted during transition.
    @MainActor
    func testOffscreenRenderB() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let spy = DiagnosticsSpy()
        let instanceIdB = UUID()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 100, height: 100,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Cannot create texture")
        }

        let renderer: MetalRenderer
        let compositor: TransitionCompositor
        do {
            renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
            compositor = try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)
        } catch {
            throw XCTSkip("Cannot create renderer/compositor: \(error)")
        }

        let canvasSize = SizeD(width: 100, height: 100)
        let ctxA = SceneRenderContext(
            commands: [], textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(), assetSizes: [:],
            localFrame: 0, canvasSize: canvasSize, sceneInstanceId: UUID()
        )
        let ctxB = SceneRenderContext(
            commands: [], textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(), assetSizes: [:],
            localFrame: 0, canvasSize: canvasSize, sceneInstanceId: instanceIdB
        )
        let transCtx = TransitionRenderContext(
            sceneA: ctxA, sceneB: ctxB,
            transition: SceneTransition(type: .fade, durationFrames: 10),
            progress: 0.5
        )

        let request = TimelineRenderRequest(
            resolved: .transition(transCtx),
            targetTexture: texture, drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: nil, backgroundTextureProvider: nil,
            clearColorOverride: nil, presentationDrawable: nil,
            waitUntilCompleted: true
        )

        try TimelineRenderExecutor.render(
            request, renderer: renderer,
            commandQueue: commandQueue, transitionCompositor: compositor,
            completionQueue: nil, renderSink: spy
        )

        let offscreenB = spy.renderEvents.contains {
            if case .offscreenRenderB(let id) = $0 { return id == instanceIdB }
            return false
        }

        XCTAssertTrue(offscreenB, "offscreenRenderB should be emitted with scene B's instanceId")
    }

    // MARK: - Test 10: Nil Sink Safety

    /// Verifies that nil sinks don't crash — all emission sites are guarded by optional chaining.
    @MainActor
    func testNilSinkSafety() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let mediaSpy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        mediaSpy.isSceneMediaReady = true

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 100)

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        // Engine with nil sinks (production mode)
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
                    mediaSyncing: mediaSpy
                )
            }
            // No runtimeDiagnosticsSink — defaults to nil
        )

        engine.setTimeline(timeline, sceneStates: [:])

        // All these should work without crash (nil sink)
        await engine.prepareForPlayback(startingAt: 50)
        _ = await engine.resolveFrame(50, policy: .presentation)
        engine.startPlayback(at: 50)
        engine.syncPlaybackTick(51)
        engine.stopPlayback()

        // If we got here, nil sink safety is confirmed
    }
}

// MARK: - Test Stubs

private struct StubMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/\(mediaRef.storagePath)")
    }
}
