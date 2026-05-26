import XCTest
import Metal
import AVFoundation
import TVECore
@testable import AnimiApp

/// PR2: Tests for UserMediaService still frame pipeline.
/// Verifies: callback separation, latest-wins, cleanup cancellation, awaitPendingStillFrames.
@MainActor
final class UserMediaServiceStillFrameTests: XCTestCase {

    // MARK: - Test Doubles

    final class FakeScenePlayer: ScenePlayerForMedia {
        private(set) var assetIdsByBlock: [String: [String: String]] = [:]
        private(set) var userMediaPresentByBlock: [String: Bool] = [:]

        func addBlock(blockId: String, assetId: String) {
            assetIdsByBlock[blockId] = ["default": assetId]
        }

        func bindingAssetIdsByVariant(blockId: String) -> [String: String] {
            assetIdsByBlock[blockId] ?? [:]
        }

        func setUserMediaPresent(blockId: String, present: Bool) {
            userMediaPresentByBlock[blockId] = present
        }

        func blockTiming(for blockId: String) -> BlockTiming? {
            nil
        }

        func blockPriorityInfo(blockId: String, at sceneFrameIndex: Int) -> BlockPriorityInfo? {
            nil
        }
    }

    final class FakeTextureProvider: MutableTextureProvider, MutableAssetPresentationInfoProvider {
        private(set) var textures: [String: MTLTexture] = [:]
        private(set) var presentationInfos: [String: VideoPresentationInfo] = [:]

        func texture(for assetId: String) -> MTLTexture? { textures[assetId] }
        func setTexture(_ texture: MTLTexture, for assetId: String) { textures[assetId] = texture }
        func removeTexture(for assetId: String) { textures.removeValue(forKey: assetId) }
        func presentationInfo(for assetId: String) -> VideoPresentationInfo? { presentationInfos[assetId] }
        func setPresentationInfo(_ info: VideoPresentationInfo, for assetId: String) { presentationInfos[assetId] = info }
        func removePresentationInfo(for assetId: String) { presentationInfos.removeValue(forKey: assetId) }
    }

    /// Controllable fake video provider with async still texture support.
    final class StillTrackingProvider: VideoSetupProviding {
        var isReady: Bool = true
        var state: VideoProviderState { .ready }
        private(set) var isPlaybackActive: Bool = false
        var duration: CMTime = CMTime(seconds: 5.0, preferredTimescale: 600)

        var playbackWindowStart: Double?
        var playbackWindowEnd: Double?
        func setPlaybackWindow(start: Double, end: Double) {
            playbackWindowStart = start
            playbackWindowEnd = end
        }
        var presentationInfo: VideoPresentationInfo? = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 64, height: 64),
            preferredTransform: .identity
        )

        private let device: MTLDevice
        var stillRequestCount: Int = 0
        var stillRequestTimes: [Double] = []

        /// If set, requestStillTexture blocks until this continuation is resumed.
        var stillContinuation: CheckedContinuation<MTLTexture, Error>?
        var shouldBlockStill: Bool = false

        init(device: MTLDevice) {
            self.device = device
        }

        func requestPoster(at time: Double) async throws -> MTLTexture {
            return createFakeTexture()
        }

        func requestStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
            stillRequestCount += 1
            stillRequestTimes.append(videoTimeSeconds)

            if shouldBlockStill {
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.stillContinuation = continuation
                    }
                } onCancel: {
                    self.stillContinuation?.resume(throwing: CancellationError())
                    self.stillContinuation = nil
                }
            }

            return createFakeTexture()
        }

        /// Resume a blocked still request with a texture.
        func releaseStill() {
            stillContinuation?.resume(returning: createFakeTexture())
            stillContinuation = nil
        }

        func requestInteractiveStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
            return createFakeTexture()
        }
        func releaseInteractiveStillResources() {}

        func release() {}
        func startPlayback(atVideoTime videoTimeSeconds: Double, hostTime: CFTimeInterval? = nil) {}
        func stopPlayback(flush: Bool) {}
        func frameTextureForPlayback(expectedVideoTime videoTimeSeconds: Double, hostTime: CFTimeInterval? = nil) -> MTLTexture? { nil }

        func createFakeTexture() -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false
            )
            return device.makeTexture(descriptor: desc)!
        }
    }

    // MARK: - Properties

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var fakePlayer: FakeScenePlayer!
    private var fakeTextureProvider: FakeTextureProvider!
    private var sut: UserMediaService!
    private var provider: StillTrackingProvider!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = metalDevice
        commandQueue = device.makeCommandQueue()!

        fakePlayer = FakeScenePlayer()
        fakePlayer.addBlock(blockId: "block_01", assetId: "binding_asset_01")

        fakeTextureProvider = FakeTextureProvider()

        sut = UserMediaService(
            device: device,
            commandQueue: commandQueue,
            scenePlayerForTest: fakePlayer,
            textureProvider: fakeTextureProvider
        )

        provider = StillTrackingProvider(device: device)
        sut.makeVideoProvider = { [weak self] _, _, _, _ in
            self?.provider ?? StillTrackingProvider(device: metalDevice)
        }
    }

    override func tearDown() async throws {
        sut = nil
        fakePlayer = nil
        fakeTextureProvider = nil
        provider = nil
        device = nil
        commandQueue = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Sets up a video block so it transitions to ready (poster delivered).
    private func setupVideoBlock(blockId: String = "block_01") async {
        let url = URL(fileURLWithPath: "/dev/null") // Fake, provider is injected
        _ = sut.setVideo(
            blockId: blockId,
            url: url,
            presentOnReady: true,
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
        )
        // Wait for poster delivery
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    }

    // MARK: - Test: onStillFrameDelivered fires, not onNeedsDisplay

    /// PR2: Still frame delivery uses onStillFrameDelivered callback, not onNeedsDisplay.
    /// This proves the infinite loop is impossible.
    func testStillFrameDelivery_usesStillCallback_notNeedsDisplay() async throws {
        var needsDisplayCount = 0
        var stillDeliveredCount = 0

        sut.onNeedsDisplay = {
            needsDisplayCount += 1
        }
        sut.onStillFrameDelivered = {
            stillDeliveredCount += 1
        }

        await setupVideoBlock()

        // Reset counters after setup (poster triggers onNeedsDisplay)
        let needsDisplayAfterSetup = needsDisplayCount
        stillDeliveredCount = 0

        // Trigger still frame update
        sut.updateVideoStillFrames(sceneFrameIndex: 0, mediaFrameIndex: 0)

        // Wait for async still task to complete
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // onStillFrameDelivered should have fired
        XCTAssertGreaterThan(stillDeliveredCount, 0,
                             "onStillFrameDelivered should fire after still frame delivery")

        // onNeedsDisplay should NOT have fired again (only from poster setup)
        XCTAssertEqual(needsDisplayCount, needsDisplayAfterSetup,
                       "onNeedsDisplay must not fire from still frame delivery (prevents infinite loop)")
    }

    // MARK: - Test: awaitPendingStillFrames blocks until delivery

    /// PR2: awaitPendingStillFrames blocks until all in-flight still tasks complete.
    func testAwaitPendingStillFrames_blocksUntilDelivery() async throws {
        provider.shouldBlockStill = true

        await setupVideoBlock()

        // Trigger still frame update (will block in provider)
        sut.updateVideoStillFrames(sceneFrameIndex: 0, mediaFrameIndex: 0)

        // Start awaiting in background
        var awaitCompleted = false
        let awaitTask = Task { @MainActor in
            await self.sut.awaitPendingStillFrames()
            awaitCompleted = true
        }

        // Give it time — should NOT complete yet
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertFalse(awaitCompleted, "awaitPendingStillFrames should block while still task is pending")

        // Release the blocked still request
        provider.releaseStill()

        // Now it should complete
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertTrue(awaitCompleted, "awaitPendingStillFrames should complete after still task finishes")

        awaitTask.cancel()
    }

    // MARK: - Test: Cleanup cancels pending still tasks

    /// PR2: clearMedia cancels pending still tasks.
    func testCleanup_cancelsPendingStillTasks() async throws {
        provider.shouldBlockStill = true

        await setupVideoBlock()

        // Trigger still frame update (will block in provider)
        sut.updateVideoStillFrames(sceneFrameIndex: 0, mediaFrameIndex: 0)

        // Give the task time to start
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Clear media — should cancel the still task
        sut.clear(blockId: "block_01")

        // awaitPendingStillFrames should complete immediately (task was cancelled)
        await sut.awaitPendingStillFrames()

        // If we get here without hanging, cleanup works correctly
    }

    // MARK: - Test: cancelPendingStillFrames cancels blocked tasks

    /// PR5: cancelPendingStillFrames cancels in-flight still tasks without full cleanup.
    func testCancelPendingStillFrames_cancelsBlockedStillTasks() async throws {
        provider.shouldBlockStill = true

        await setupVideoBlock()

        // Trigger still frame update (will block in provider)
        sut.updateVideoStillFrames(sceneFrameIndex: 0, mediaFrameIndex: 0)

        // Give the task time to start
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Cancel pending still frames
        sut.cancelPendingStillFrames()

        // awaitPendingStillFrames should complete immediately (task was cancelled)
        await sut.awaitPendingStillFrames()

        // If we get here without hanging, cancellation works correctly
    }

    // MARK: - Playback Window

    func testSetVideo_setsPlaybackWindowOnProvider() async throws {
        await setupVideoBlock()
        XCTAssertEqual(provider.playbackWindowStart, 0.0,
            "setVideo must set playback window start to trimStart")
        XCTAssertEqual(provider.playbackWindowEnd, 5.0,
            "setVideo must set playback window end to trimEnd")
    }
}
