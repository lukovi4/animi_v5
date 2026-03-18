import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// Tests for Hold Last Frame fix in SceneInstanceRuntime.
/// Verifies that localFrame is clamped to [0, durationFrames-1] via production API behavior.
final class SceneInstanceRuntimeHoldFrameTests: XCTestCase {

    // MARK: - Test Infrastructure

    /// Creates minimal in-memory resources for testing SceneInstanceRuntime.
    /// - Parameter durationFrames: Native animation duration in frames.
    /// - Returns: Resources configured with empty scene and specified duration.
    @MainActor
    private func makeMinimalResources(durationFrames: Int, fps: Int = 30) -> SceneTypeResourcesCache.Resources {
        // Create minimal canvas
        let canvas = Canvas(width: 1080, height: 1920, fps: fps, durationFrames: durationFrames)

        // Create minimal scene with no blocks
        let scene = Scene(
            schemaVersion: "1.0",
            sceneId: "test-scene",
            canvas: canvas,
            background: nil,
            mediaBlocks: []
        )

        // Create minimal SceneRuntime
        let runtime = SceneRuntime(
            scene: scene,
            canvas: canvas,
            blocks: [],
            durationFrames: durationFrames,
            fps: fps
        )

        // Create minimal CompiledScene
        let compiled = CompiledScene(
            runtime: runtime,
            mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry(),
            bindingAssetIds: []
        )

        // Create empty resolver
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)

        // Create empty base texture provider
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

    // MARK: - Media Syncing Spy

    /// Spy to capture sceneFrameIndex values passed to media syncing methods.
    /// TT-02: Added frozenFrames, isSceneMediaReady, hasFailedMedia for readiness testing.
    @MainActor
    final class MediaSyncingSpy: SceneMediaSyncing {
        var scrubFrames: [Int] = []
        var playbackFrames: [Int] = []
        var frozenFrames: [Int] = []
        var startPlaybackFrames: [Int] = []

        // TT-02: Controllable readiness flags for tests
        var isSceneMediaReady: Bool = false
        var hasFailedMedia: Bool = false

        func updateVideoFramesForScrub(sceneFrameIndex: Int) {
            scrubFrames.append(sceneFrameIndex)
        }

        func updateVideoFramesForPlayback(sceneFrameIndex: Int) {
            playbackFrames.append(sceneFrameIndex)
        }

        func updateVideoFramesForFrozen(sceneFrameIndex: Int) {
            frozenFrames.append(sceneFrameIndex)
        }

        func startVideoPlayback(sceneFrameIndex: Int) {
            startPlaybackFrames.append(sceneFrameIndex)
        }
    }

    // MARK: - Behavior Tests: makeRenderContext

    /// Behavior: makeRenderContext(localFrame: 350) returns context.localFrame == 299 when durationFrames=300.
    @MainActor
    func testMakeRenderContext_beyondDuration_returnsClamped() throws {
        // Skip if no Metal device available (CI environment)
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // Given: Scene with 300 native frames
        let durationFrames = 300
        let resources = makeMinimalResources(durationFrames: durationFrames)

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        // When: Request render context for frame 350 (beyond duration)
        let context = runtime.makeRenderContext(localFrame: 350)

        // Then: localFrame should be clamped to 299 (last valid frame)
        XCTAssertEqual(context.localFrame, 299, "localFrame should be clamped to durationFrames-1")
    }

    /// Behavior: makeRenderContext(localFrame: 299) returns context.localFrame == 299 (no clamp needed).
    @MainActor
    func testMakeRenderContext_atLastValidFrame_returnsUnchanged() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let durationFrames = 300
        let resources = makeMinimalResources(durationFrames: durationFrames)

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        // When: Request render context for frame 299 (last valid frame)
        let context = runtime.makeRenderContext(localFrame: 299)

        // Then: localFrame should remain 299
        XCTAssertEqual(context.localFrame, 299)
    }

    /// Behavior: makeRenderContext(localFrame: 50) returns context.localFrame == 50 (within bounds).
    @MainActor
    func testMakeRenderContext_withinBounds_returnsUnchanged() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let durationFrames = 300
        let resources = makeMinimalResources(durationFrames: durationFrames)

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        // When: Request render context for frame 50 (within bounds)
        let context = runtime.makeRenderContext(localFrame: 50)

        // Then: localFrame should remain 50
        XCTAssertEqual(context.localFrame, 50)
    }

    // MARK: - Behavior Tests: renderCommands

    /// Behavior: renderCommands(localFrame: 350) returns same commands as renderCommands(localFrame: 299).
    @MainActor
    func testRenderCommands_beyondDuration_sameAsLastFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let durationFrames = 300
        let resources = makeMinimalResources(durationFrames: durationFrames)

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        // When: Get render commands for frame 299 and frame 350
        let commandsAt299 = runtime.renderCommands(localFrame: 299, mode: .preview)
        let commandsAt350 = runtime.renderCommands(localFrame: 350, mode: .preview)

        // Then: Commands should be identical (both resolve to frame 299)
        XCTAssertEqual(commandsAt299.count, commandsAt350.count, "Command count should match")

        // Note: For empty scene, both return empty arrays, which verifies no crash/error
        // For scenes with content, this would verify idempotency of render at clamped frame
    }

    // MARK: - Behavior Tests: Media Syncing (Spy Injection)

    /// Behavior: syncVideoFrame(350) passes clamped frame 299 to media service.
    @MainActor
    func testSyncVideoFrame_beyondDuration_passesClampedFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let durationFrames = 300
        let resources = makeMinimalResources(durationFrames: durationFrames)
        let spy = MediaSyncingSpy()

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        // When: Sync video frame for 350 (beyond duration)
        runtime.syncVideoFrame(350)

        // Then: Spy should receive clamped frame 299
        XCTAssertEqual(spy.scrubFrames, [299], "syncVideoFrame should pass clamped frame to media service")
    }

    /// Behavior: syncPlaybackTick(350) passes clamped frame 299 to media service.
    @MainActor
    func testSyncPlaybackTick_beyondDuration_passesClampedFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let durationFrames = 300
        let resources = makeMinimalResources(durationFrames: durationFrames)
        let spy = MediaSyncingSpy()

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        // When: Sync playback tick for 350
        runtime.syncPlaybackTick(350)

        // Then: Spy should receive clamped frame 299
        XCTAssertEqual(spy.playbackFrames, [299], "syncPlaybackTick should pass clamped frame to media service")
    }

    /// Behavior: startPlayback(at: 350) passes clamped frame 299 to media service.
    @MainActor
    func testStartPlayback_beyondDuration_passesClampedFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let durationFrames = 300
        let resources = makeMinimalResources(durationFrames: durationFrames)
        let spy = MediaSyncingSpy()

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        // When: Start playback at frame 350
        runtime.startPlayback(at: 350)

        // Then: Spy should receive clamped frame 299
        XCTAssertEqual(spy.startPlaybackFrames, [299], "startPlayback should pass clamped frame to media service")
    }

    /// Behavior: Multiple sync calls all pass clamped frames.
    @MainActor
    func testMultipleSyncCalls_allPassClampedFrames() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let durationFrames = 300
        let resources = makeMinimalResources(durationFrames: durationFrames)
        let spy = MediaSyncingSpy()

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue,
            mediaSyncing: spy
        )

        // When: Call various sync methods with frames beyond duration
        runtime.syncVideoFrame(300)  // Should clamp to 299
        runtime.syncVideoFrame(350)  // Should clamp to 299
        runtime.syncVideoFrame(450)  // Should clamp to 299
        runtime.syncPlaybackTick(1000)  // Should clamp to 299
        runtime.startPlayback(at: 500)  // Should clamp to 299

        // Then: All should be clamped to 299
        XCTAssertEqual(spy.scrubFrames, [299, 299, 299])
        XCTAssertEqual(spy.playbackFrames, [299])
        XCTAssertEqual(spy.startPlaybackFrames, [299])
    }

    // MARK: - Edge Case Tests

    /// Edge case: Negative frame clamps to 0.
    @MainActor
    func testMakeRenderContext_negativeFrame_clampsToZero() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 300)

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        // When: Request render context for negative frame
        let context = runtime.makeRenderContext(localFrame: -10)

        // Then: localFrame should be clamped to 0
        XCTAssertEqual(context.localFrame, 0)
    }

    /// Edge case: Single frame duration clamps any input to 0.
    @MainActor
    func testMakeRenderContext_singleFrameDuration_clampsToZero() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let resources = makeMinimalResources(durationFrames: 1)

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        // When: Request render context for any frame
        let context0 = runtime.makeRenderContext(localFrame: 0)
        let context1 = runtime.makeRenderContext(localFrame: 1)
        let context100 = runtime.makeRenderContext(localFrame: 100)

        // Then: All should clamp to 0
        XCTAssertEqual(context0.localFrame, 0)
        XCTAssertEqual(context1.localFrame, 0)
        XCTAssertEqual(context100.localFrame, 0)
    }

    /// Edge case: Frame at exact duration boundary (300 with duration 300) clamps to 299.
    @MainActor
    func testMakeRenderContext_exactDurationBoundary_clampsToLastValid() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let durationFrames = 300
        let resources = makeMinimalResources(durationFrames: durationFrames)

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        // When: Request render context for frame 300 (exactly at duration, which is exclusive)
        let context = runtime.makeRenderContext(localFrame: 300)

        // Then: localFrame should be clamped to 299
        XCTAssertEqual(context.localFrame, 299, "Frame at duration should clamp to durationFrames-1")
    }

    // MARK: - Contract Test: Extended Scene Holds Last Frame

    /// Contract: Extended scene (timeline duration > native duration) should render last frame content.
    /// This is the core regression fix - verifies blocks don't disappear after animation ends.
    @MainActor
    func testContract_extendedScene_renderContextHoldsLastFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // Given: Scene with 300 native frames, extended to 450 in timeline
        let nativeDuration = 300
        let timelineLocalFrame = 350  // Beyond native duration

        let resources = makeMinimalResources(durationFrames: nativeDuration)

        let runtime = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        // When: Get render context for timeline frame 350
        let context = runtime.makeRenderContext(localFrame: timelineLocalFrame)

        // Then: localFrame should be clamped to 299 (hold last frame)
        XCTAssertEqual(context.localFrame, 299, "Extended scene should hold last frame")
        XCTAssertLessThan(context.localFrame, nativeDuration, "localFrame must be < nativeDuration")
    }
}
