import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// TT-02: Tests for SceneInstanceRuntime readiness state machine.
final class SceneInstanceRuntimeReadinessTests: XCTestCase {

    // MARK: - Test Infrastructure

    @MainActor
    private func makeMinimalResources(durationFrames: Int, fps: Int = 30) -> SceneTypeResourcesCache.Resources {
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
            sceneTypeId: "test-scene-type",
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

    // MARK: - State Machine Tests

    /// TT-02: Initial state is .created
    @MainActor
    func testInitialStateIsCreated() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true  // Ready immediately

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        XCTAssertEqual(runtime.readinessState, .created)
    }

    /// TT-02: startPreparingForPresentation transitions from .created to .preparing
    @MainActor
    func testStartPreparingFromCreatedTransitionsToPreparing() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false  // Not ready yet

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        runtime.startPreparingForPresentation(at: 50)

        XCTAssertEqual(runtime.readinessState, .preparing(targetLocalFrame: 50))
    }

    /// TT-02: startPreparingForPresentation uses exact frozen frame, not scrub frame 0
    @MainActor
    func testStartPreparingUsesExactFrozenFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        runtime.startPreparingForPresentation(at: 75)

        // Should call frozen with exact frame 75, not 0
        XCTAssertTrue(spy.stillFrames.contains(75), "Should use still API with exact frame")
        XCTAssertFalse(spy.stillFrames.contains(0), "Should not use still frame 0")
    }

    /// TT-02: Target frame is clamped to valid range
    @MainActor
    func testTargetFrameClamp() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 100)  // Max frame = 99
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        runtime.startPreparingForPresentation(at: 500)  // Beyond duration

        // State should show clamped frame
        XCTAssertEqual(runtime.readinessState, .preparing(targetLocalFrame: 99))
        // Frozen frame should be clamped
        XCTAssertTrue(spy.stillFrames.contains(99))
    }

    /// TT-02: When isSceneMediaReady becomes true, state transitions to .ready
    @MainActor
    func testReadyTransitionOnMediaReady() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true  // Ready immediately

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        let state = await runtime.waitUntilReadyForPresentation(at: 50)

        XCTAssertEqual(state, .ready(targetLocalFrame: 50))
        XCTAssertEqual(runtime.readinessState, .ready(targetLocalFrame: 50))
    }

    /// TT-02: When hasFailedMedia is true, state transitions to .failed
    @MainActor
    func testFailedTransitionOnMediaFailure() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false
        spy.hasFailedMedia = true  // Failure

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        let state = await runtime.waitUntilReadyForPresentation(at: 50)

        if case .failed(let reason) = state {
            XCTAssertEqual(reason, "Media restore failed")
        } else {
            XCTFail("Expected .failed state, got \(state)")
        }
    }

    /// TT-02: reloadState no longer calls auto-prepare
    @MainActor
    func testReloadStateDoesNotAutoPrepare() async throws {
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

        // Create a minimal state
        let state = SceneState()
        await runtime.reloadState(state)

        // After reloadState, should be in .created, not .ready or .preparing
        XCTAssertEqual(runtime.readinessState, .created)
    }

    /// TT-02: startPreparingForPresentation from .ready is no-op (does not downgrade)
    @MainActor
    func testStartPreparingFromReadyIsNoOp() async throws {
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

        // Get to ready state
        _ = await runtime.waitUntilReadyForPresentation(at: 50)
        XCTAssertEqual(runtime.readinessState, .ready(targetLocalFrame: 50))

        let frozenCountBefore = spy.stillFrames.count

        // Try to start preparing again
        runtime.startPreparingForPresentation(at: 100)

        // Should still be ready with original target, not downgraded to preparing
        XCTAssertEqual(runtime.readinessState, .ready(targetLocalFrame: 50))
        // Should not have called frozen again
        XCTAssertEqual(spy.stillFrames.count, frozenCountBefore)
    }

    /// TT-02: startPreparingForPresentation from .failed is no-op
    @MainActor
    func testStartPreparingFromFailedIsNoOp() async throws {
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

        // Get to failed state
        _ = await runtime.waitUntilReadyForPresentation(at: 50)

        guard case .failed = runtime.readinessState else {
            XCTFail("Expected failed state")
            return
        }

        let frozenCountBefore = spy.stillFrames.count

        // Try to start preparing again
        runtime.startPreparingForPresentation(at: 100)

        // Should still be failed, not preparing
        if case .failed = runtime.readinessState {
            // Good
        } else {
            XCTFail("Expected to remain in failed state")
        }

        // Should not have called frozen again
        XCTAssertEqual(spy.stillFrames.count, frozenCountBefore)
    }

    /// TT-02: startPreparingForPresentation from .preparing is no-op
    @MainActor
    func testStartPreparingFromPreparingIsNoOp() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        runtime.startPreparingForPresentation(at: 50)
        XCTAssertEqual(runtime.readinessState, .preparing(targetLocalFrame: 50))

        let frozenCountBefore = spy.stillFrames.count

        // Try to start preparing for different frame
        runtime.startPreparingForPresentation(at: 100)

        // Should still be preparing with original target
        XCTAssertEqual(runtime.readinessState, .preparing(targetLocalFrame: 50))
        // Should not have called frozen again for initial sync
        XCTAssertEqual(spy.stillFrames.count, frozenCountBefore)
    }

    /// TT-02: isReady returns true only for .ready state
    @MainActor
    func testIsReadyComputedProperty() async throws {
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

        // Initially .created
        XCTAssertFalse(runtime.isReady)

        // After waiting, should be .ready
        _ = await runtime.waitUntilReadyForPresentation(at: 50)
        XCTAssertTrue(runtime.isReady)
    }

    /// TT-02: resetState resets to .created and cancels preparation
    @MainActor
    func testResetStateCancelsPreparation() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        runtime.startPreparingForPresentation(at: 50)
        XCTAssertEqual(runtime.readinessState, .preparing(targetLocalFrame: 50))

        runtime.resetState()

        XCTAssertEqual(runtime.readinessState, .created)
    }

    // MARK: - Timeout Tests (TT-02 Task 4)

    /// TT-02: When media never becomes ready, state transitions to .timedOut
    @MainActor
    func testTimeoutTransitionWhenMediaNeverReady() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false  // Never becomes ready
        spy.hasFailedMedia = false     // Not a failure, just slow

        // Use fast timing config for deterministic quick test
        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy,
            timingConfig: .fastForTesting  // 100ms max wait
        )

        let targetFrame = 75
        let state = await runtime.waitUntilReadyForPresentation(at: targetFrame)

        // Should transition to .timedOut with exact target frame
        guard case .timedOut(let timedOutFrame) = state else {
            XCTFail("Expected .timedOut, got \(state)")
            return
        }
        XCTAssertEqual(timedOutFrame, targetFrame, "timedOut should contain exact target frame")
        XCTAssertEqual(runtime.readinessState, .timedOut(targetLocalFrame: targetFrame))
    }

    /// TT-02: Timeout uses clamped frame for out-of-bounds target
    @MainActor
    func testTimeoutUsesClampedFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 100)  // Max frame = 99
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false
        spy.hasFailedMedia = false

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy,
            timingConfig: .fastForTesting
        )

        // Request frame beyond duration
        let state = await runtime.waitUntilReadyForPresentation(at: 500)

        // Should clamp to 99 (max valid frame)
        guard case .timedOut(let timedOutFrame) = state else {
            XCTFail("Expected .timedOut, got \(state)")
            return
        }
        XCTAssertEqual(timedOutFrame, 99, "timedOut frame should be clamped to valid range")
    }

    /// TT-02: startPreparingForPresentation from .timedOut is no-op
    @MainActor
    func testStartPreparingFromTimedOutIsNoOp() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false
        spy.hasFailedMedia = false

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy,
            timingConfig: .fastForTesting
        )

        // Get to timedOut state
        _ = await runtime.waitUntilReadyForPresentation(at: 50)

        guard case .timedOut = runtime.readinessState else {
            XCTFail("Expected timedOut state")
            return
        }

        let frozenCountBefore = spy.stillFrames.count

        // Try to start preparing again
        runtime.startPreparingForPresentation(at: 100)

        // Should still be timedOut, not preparing
        guard case .timedOut = runtime.readinessState else {
            XCTFail("Expected to remain in timedOut state")
            return
        }

        // Should not have called frozen again
        XCTAssertEqual(spy.stillFrames.count, frozenCountBefore)
    }

    // MARK: - PR5: Eviction Cancels Preparation

    /// PR5: evictFromTimeline cancels in-flight preparation and transitions to .failed
    @MainActor
    func test_evictFromTimeline_cancelsPreparing() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = false

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        runtime.startPreparingForPresentation(at: 50)
        XCTAssertEqual(runtime.readinessState, .preparing(targetLocalFrame: 50))

        runtime.evictFromTimeline()

        if case .failed(let reason) = runtime.readinessState {
            XCTAssertEqual(reason, "evicted")
        } else {
            XCTFail("Expected .failed(reason: \"evicted\"), got \(runtime.readinessState)")
        }

        // Let cancelled task settle
        await Task.yield()

        // State must NOT have become .ready
        if case .ready = runtime.readinessState {
            XCTFail("Evicted runtime must not transition to .ready")
        }
    }

    /// PR5: evictFromTimeline from .created is a no-op (only .preparing transitions to .failed)
    @MainActor
    func test_evictFromTimeline_fromCreated_isNoOp() throws {
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

        XCTAssertEqual(runtime.readinessState, .created)

        runtime.evictFromTimeline()

        XCTAssertEqual(runtime.readinessState, .created)
    }

    /// PR5: evictFromTimeline from .ready does not downgrade state
    @MainActor
    func test_evictFromTimeline_fromReady_doesNotDowngrade() async throws {
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

        _ = await runtime.waitUntilReadyForPresentation(at: 0)
        XCTAssertEqual(runtime.readinessState, .ready(targetLocalFrame: 0))

        runtime.evictFromTimeline()

        XCTAssertEqual(runtime.readinessState, .ready(targetLocalFrame: 0),
                       "Eviction should not downgrade .ready state")
    }

    // MARK: - PR2: Readiness Holds Until Still Frames Delivered

    /// PR2: Runtime stays in .preparing until awaitPendingStillFrames completes.
    /// Proves that fire-and-forget still tasks block readiness transition.
    @MainActor
    func testReadyTransitionAwaitsStillFrameDelivery() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)
        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true
        spy.shouldBlockStillAwait = true  // Block until we release

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        // Start preparation (non-blocking)
        runtime.startPreparingForPresentation(at: 50)

        // Give the prep loop a chance to reach the await point
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Runtime should still be preparing (blocked on still await)
        XCTAssertEqual(runtime.readinessState, .preparing(targetLocalFrame: 50),
                       "Runtime must stay .preparing while still frames are pending")
        XCTAssertEqual(spy.awaitPendingStillFramesCalls, 1,
                       "Should have called awaitPendingStillFrames exactly once")

        // Release the still await
        spy.releaseStillAwait()

        // Give the prep loop a chance to complete
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Now runtime should be ready
        XCTAssertEqual(runtime.readinessState, .ready(targetLocalFrame: 50),
                       "Runtime should transition to .ready after still frames delivered")
    }
}
