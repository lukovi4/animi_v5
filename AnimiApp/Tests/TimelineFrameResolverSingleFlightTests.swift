import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// Tests for the single-flight runtime creation contract in TimelineFrameResolver.
/// Verifies that concurrent callers for the same sceneInstanceId
/// share one creation task and produce exactly one runtime, and that
/// cancellation prevents stale runtimes from being stored.
final class TimelineFrameResolverSingleFlightTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeMinimalResources(durationFrames: Int = 100, fps: Int = 30, sceneTypeId: String = "test-scene-type") -> SceneTypeResourcesCache.Resources {
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
    private func makeSingleSceneTimeline(instanceId: UUID = UUID(), sceneTypeId: String = "test-scene-type") -> CanonicalTimeline {
        let payloadId = UUID()
        let item = TimelineItem(
            id: instanceId,
            payloadId: payloadId,
            kind: .scene,
            startUs: nil,
            durationUs: framesToUs(100)
        )
        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: [item])
        return CanonicalTimeline(
            tracks: [sceneTrack],
            payloads: [payloadId: .scene(ScenePayload(sceneTypeId: sceneTypeId))],
            boundaryTransitions: [:]
        )
    }

    @MainActor
    private func makeEngine(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        resources: SceneTypeResourcesCache.Resources,
        timeline: CanonicalTimeline,
        sceneStates: [UUID: SceneState] = [:],
        factoryCounter: FactoryCounter,
        mediaLocator: (any ProjectMediaLocator)? = nil
    ) -> TimelineCompositionEngine {
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        cache.addToCache(resources)

        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true

        let locator = mediaLocator ?? SFStubMediaLocator()

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: SFStubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                factoryCounter.count += 1
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy,
                    mediaLocator: locator
                )
            }
        )
        engine.setTimeline(timeline, sceneStates: sceneStates)
        return engine
    }

    // MARK: - Single-Flight Tests

    /// Two concurrent callers for the same instanceId join a single in-flight creation.
    /// Proves: one Runtime.create.start, one Runtime.create.join, one factory call.
    @MainActor
    func testConcurrentSameIdCallersJoinInFlightCreation() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let instanceId = UUID()
        let resources = makeMinimalResources()
        let timeline = makeSingleSceneTimeline(instanceId: instanceId)

        // Gate: locator blocks until we release it, keeping creation in-flight
        let gate = AsyncGate()
        let gatingLocator = GatingMediaLocator(gate: gate)

        // Provide a SceneState with a media slot so applyState calls the locator
        let mediaRef = MediaRef(storagePath: "test.jpg", mediaKind: .photo)
        let slot = SceneMediaSlot.photo(mediaRef: mediaRef, placement: .defaultCover)
        let sceneState = SceneState(mediaSlotsByBlockId: ["block0": slot])

        let counter = FactoryCounter()
        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            resources: resources,
            timeline: timeline,
            sceneStates: [instanceId: sceneState],
            factoryCounter: counter,
            mediaLocator: gatingLocator
        )

        // Launch two concurrent resolveFrame calls — first creates, second joins
        async let resultA: TimelineFrameResolution = engine.resolveFrame(0, policy: .presentation)
        async let resultB: TimelineFrameResolution = engine.resolveFrame(0, policy: .presentation)

        // Wait for the gate to be entered (creation is in-flight, blocked at applyState)
        await gate.waitUntilEntered()

        // Verify: only one factory call so far (second caller joined the first)
        XCTAssertEqual(counter.count, 1, "Only one factory call should happen before gate release")

        // Release gate — creation completes
        await gate.release()

        let a = await resultA
        let b = await resultB

        // Both must not be .failed
        if case .failed(let err) = a { XCTFail("Caller A failed: \(err)") }
        if case .failed(let err) = b { XCTFail("Caller B failed: \(err)") }

        // Factory must have been called exactly once
        XCTAssertEqual(counter.count, 1, "Factory should be called exactly once for concurrent same-id callers")

        // Engine should have exactly one runtime cached
        XCTAssertNotNil(engine.runtime(for: instanceId))
    }

    /// After a runtime is cached, subsequent calls don't invoke factory.
    @MainActor
    func testCachedRuntimeSkipsFactory() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let instanceId = UUID()
        let resources = makeMinimalResources()
        let timeline = makeSingleSceneTimeline(instanceId: instanceId)
        let counter = FactoryCounter()
        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            resources: resources,
            timeline: timeline,
            factoryCounter: counter
        )

        _ = await engine.resolveFrame(0, policy: .presentation)
        XCTAssertEqual(counter.count, 1)

        _ = await engine.resolveFrame(0, policy: .presentation)
        XCTAssertEqual(counter.count, 1, "Factory should not be called again for cached runtime")
    }

    // MARK: - Cancellation-Before-Store Tests

    /// releaseForExport cancels in-flight creation, preventing stale runtime storage.
    @MainActor
    func testReleaseForExportCancelsInFlightCreationBeforeStore() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let instanceId = UUID()
        let resources = makeMinimalResources()
        let timeline = makeSingleSceneTimeline(instanceId: instanceId)

        let gate = AsyncGate()
        let gatingLocator = GatingMediaLocator(gate: gate)

        let mediaRef = MediaRef(storagePath: "test.jpg", mediaKind: .photo)
        let slot = SceneMediaSlot.photo(mediaRef: mediaRef, placement: .defaultCover)
        let sceneState = SceneState(mediaSlotsByBlockId: ["block0": slot])

        let counter = FactoryCounter()
        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            resources: resources,
            timeline: timeline,
            sceneStates: [instanceId: sceneState],
            factoryCounter: counter,
            mediaLocator: gatingLocator
        )

        // Start creation — it will block at applyState (gating locator)
        let resolveTask = Task { @MainActor in
            await engine.resolveFrame(0, policy: .presentation)
        }

        // Wait until creation is in-flight
        await gate.waitUntilEntered()
        XCTAssertEqual(counter.count, 1, "Factory should have been called")

        // Cancel via releaseForExport (calls cancelAllRuntimeCreationTasks)
        await engine.releaseForExport()

        // Release gate — cancelled task should NOT store runtime
        await gate.release()

        _ = await resolveTask.value

        // No runtime should be cached
        XCTAssertNil(engine.runtime(for: instanceId),
                     "Cancelled in-flight creation must not store runtime")
    }

    /// setTimeline orphan eviction cancels in-flight creation, preventing stale runtime storage.
    @MainActor
    func testSetTimelineOrphanCancelsInFlightCreationBeforeStore() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let instanceId1 = UUID()
        let resources = makeMinimalResources()
        let timeline1 = makeSingleSceneTimeline(instanceId: instanceId1)

        let gate = AsyncGate()
        let gatingLocator = GatingMediaLocator(gate: gate)

        let mediaRef = MediaRef(storagePath: "test.jpg", mediaKind: .photo)
        let slot = SceneMediaSlot.photo(mediaRef: mediaRef, placement: .defaultCover)
        let sceneState = SceneState(mediaSlotsByBlockId: ["block0": slot])

        let counter = FactoryCounter()
        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            resources: resources,
            timeline: timeline1,
            sceneStates: [instanceId1: sceneState],
            factoryCounter: counter,
            mediaLocator: gatingLocator
        )

        // Start creation for instanceId1 — blocks at applyState
        let resolveTask = Task { @MainActor in
            await engine.resolveFrame(0, policy: .presentation)
        }

        await gate.waitUntilEntered()
        XCTAssertEqual(counter.count, 1, "Factory should have been called for instanceId1")

        // Replace timeline — instanceId1 becomes orphan, its creation task is cancelled
        let instanceId2 = UUID()
        let timeline2 = makeSingleSceneTimeline(instanceId: instanceId2)
        engine.setTimeline(timeline2, sceneStates: [:])

        // Release gate — cancelled task completes but should NOT store runtime
        await gate.release()

        _ = await resolveTask.value

        // instanceId1 must not be cached
        XCTAssertNil(engine.runtime(for: instanceId1),
                     "Orphaned in-flight creation must not store runtime after setTimeline")
    }

    /// setTimeline orphan eviction clears an already-stored runtime.
    @MainActor
    func testSetTimelineOrphanEvictsStoredRuntime() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let instanceId1 = UUID()
        let resources = makeMinimalResources()
        let timeline1 = makeSingleSceneTimeline(instanceId: instanceId1)
        let counter = FactoryCounter()
        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            resources: resources,
            timeline: timeline1,
            factoryCounter: counter
        )

        _ = await engine.resolveFrame(0, policy: .presentation)
        XCTAssertNotNil(engine.runtime(for: instanceId1))

        let instanceId2 = UUID()
        let timeline2 = makeSingleSceneTimeline(instanceId: instanceId2)
        engine.setTimeline(timeline2, sceneStates: [:])

        XCTAssertNil(engine.runtime(for: instanceId1), "Orphaned runtime should be evicted")
    }

    /// setTimeline orphan eviction cancels preparation on a stored .preparing runtime.
    @MainActor
    func testSetTimelineOrphanEvictsStoredPreparingRuntimeCancelsPreparation() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let instanceId1 = UUID()
        let resources = makeMinimalResources()
        let timeline1 = makeSingleSceneTimeline(instanceId: instanceId1)

        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false  // Never becomes ready — stays .preparing

        let counter = FactoryCounter()
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        cache.addToCache(resources)

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            mediaLocator: SFStubMediaLocator(),
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                counter.count += 1
                return SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )
        engine.setTimeline(timeline1, sceneStates: [:])

        // Create and cache the runtime via resolveFrame (won't await readiness)
        _ = await engine.resolveFrame(0, policy: .presentation)
        let runtime = engine.runtime(for: instanceId1)
        XCTAssertNotNil(runtime)

        // Runtime should be in .preparing since isSceneMediaReady = false
        XCTAssertEqual(runtime!.readinessState, .preparing(targetLocalFrame: 0))

        // Replace timeline — instanceId1 becomes orphan
        let instanceId2 = UUID()
        let timeline2 = makeSingleSceneTimeline(instanceId: instanceId2)
        engine.setTimeline(timeline2, sceneStates: [:])

        // Runtime removed from engine
        XCTAssertNil(engine.runtime(for: instanceId1),
                     "Orphaned runtime should be removed from engine")

        // Retained local reference should show preparation was cancelled
        if case .failed(let reason) = runtime!.readinessState {
            XCTAssertEqual(reason, "evicted")
        } else {
            XCTFail("Expected .failed(reason: \"evicted\"), got \(runtime!.readinessState)")
        }
    }

    /// releaseForExport clears stored runtimes.
    @MainActor
    func testReleaseForExportClearsStoredRuntimes() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let instanceId = UUID()
        let resources = makeMinimalResources()
        let timeline = makeSingleSceneTimeline(instanceId: instanceId)
        let counter = FactoryCounter()
        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            resources: resources,
            timeline: timeline,
            factoryCounter: counter
        )

        _ = await engine.resolveFrame(0, policy: .presentation)
        XCTAssertNotNil(engine.runtime(for: instanceId))

        await engine.releaseForExport()
        XCTAssertNil(engine.runtime(for: instanceId))
    }
}

// MARK: - Test Infrastructure

/// Mutable reference counter for factory invocations.
@MainActor
private final class FactoryCounter {
    var count = 0
}

/// Async gate: allows test to block a coroutine until explicitly released.
/// Used to hold runtime creation at a controlled suspension point.
private actor AsyncGate {
    private var enterContinuation: CheckedContinuation<Void, Never>?
    private var blockContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private var hasEntered = false

    /// Called by the gated code — blocks until `release()` is called.
    func enter() async {
        hasEntered = true
        // Notify waiter that we've entered
        enterContinuation?.resume()
        enterContinuation = nil

        // Block until released
        if !isReleased {
            await withCheckedContinuation { cont in
                blockContinuation = cont
            }
        }
    }

    /// Waits until `enter()` has been called.
    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { cont in
            enterContinuation = cont
        }
    }

    /// Unblocks the gated code.
    func release() {
        isReleased = true
        blockContinuation?.resume()
        blockContinuation = nil
    }
}

/// A ProjectMediaLocator that blocks on an AsyncGate before returning.
/// Used to suspend runtime creation at `applyState` → `ResolvedMediaMapBuilder.build`.
private final class GatingMediaLocator: ProjectMediaLocator, @unchecked Sendable {
    private let gate: AsyncGate

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        await gate.enter()
        return URL(fileURLWithPath: "/tmp/\(mediaRef.storagePath)")
    }
}

private struct SFStubMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/\(mediaRef.storagePath)")
    }
}
