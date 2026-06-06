import XCTest
import Metal
import AVFoundation
import TVECore
@testable import AnimiApp

/// Regression tests for UserMediaService trim preview and currentVideoTime.
/// Uses FakeScenePlayer + StillTrackingProvider pattern from UserMediaServiceStillFrameTests.
@MainActor
final class UserMediaServiceTrimPreviewTests: XCTestCase {

    // MARK: - Test Doubles

    final class FakeScenePlayer: ScenePlayerForMedia {
        private(set) var assetIdsByBlock: [String: [String: String]] = [:]
        private(set) var userMediaPresentByBlock: [String: Bool] = [:]
        var blockTimingOverrides: [String: BlockTiming] = [:]

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
            blockTimingOverrides[blockId]
        }

        /// Per-block visibility override for grant/playback tests. When set, the block
        /// is reported visible (area/zIndex non-zero) so `startVideoPlayback` /
        /// `updateVideoFramesForPlayback` treat it as a granted active playback source.
        var priorityOverrides: [String: BlockPriorityInfo] = [:]

        func blockPriorityInfo(blockId: String, at sceneFrameIndex: Int) -> BlockPriorityInfo? {
            priorityOverrides[blockId]
        }

        /// Marks a block visible across the whole timeline for playback grant tests.
        func makeVisible(blockId: String) {
            blockTimingOverrides[blockId] = BlockTiming(startFrame: 0, endFrame: 100_000)
            priorityOverrides[blockId] = BlockPriorityInfo(isVisible: true, area: 1000, zIndex: 1)
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

    final class StillTrackingProvider: VideoSetupProviding {
        var isReady: Bool = true
        var state: VideoProviderState { .ready }
        private(set) var isPlaybackActive: Bool = false
        var duration: CMTime = CMTime(seconds: 10.0, preferredTimescale: 600)

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
        var posterRequestTimes: [Double] = []
        var shouldBlockPoster: Bool = false
        private var posterContinuation: CheckedContinuation<MTLTexture, Error>?

        /// When true, requestStillTexture blocks until `releaseStill()` is called.
        var shouldBlockStill: Bool = false
        private var stillContinuation: CheckedContinuation<MTLTexture, Error>?

        /// When set, requestStillTexture throws this non-cancellation error
        /// synchronously. Used to exercise the hard-gated `.failed` start-frame path.
        var stillFailureError: Error?

        /// Textures returned by each still request (indexed by request order).
        var returnedTextures: [MTLTexture] = []

        init(device: MTLDevice) {
            self.device = device
        }

        func requestPoster(at time: Double) async throws -> MTLTexture {
            posterRequestTimes.append(time)
            if shouldBlockPoster {
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.posterContinuation = continuation
                    }
                } onCancel: {
                    self.posterContinuation?.resume(throwing: CancellationError())
                    self.posterContinuation = nil
                }
            }
            return createFakeTexture()
        }

        func releasePoster() {
            posterContinuation?.resume(returning: createFakeTexture())
            posterContinuation = nil
        }

        func requestStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
            stillRequestCount += 1
            stillRequestTimes.append(videoTimeSeconds)

            if let stillFailureError {
                throw stillFailureError
            }

            if shouldBlockStill {
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.stillContinuation = continuation
                    }
                } onCancel: {
                    // Resume the leaked continuation so it doesn't stay suspended forever
                    self.stillContinuation?.resume(throwing: CancellationError())
                    self.stillContinuation = nil
                }
            }

            let texture = createFakeTexture()
            returnedTextures.append(texture)
            return texture
        }

        /// Resume a blocked still request with a fresh texture.
        func releaseStill() {
            let texture = createFakeTexture()
            returnedTextures.append(texture)
            stillContinuation?.resume(returning: texture)
            stillContinuation = nil
        }

        // MARK: - Interactive Still Tracking

        var interactiveStillRequestCount: Int = 0
        var interactiveStillRequestTimes: [Double] = []
        var didReleaseInteractiveResources: Bool = false

        /// When true, requestInteractiveStillTexture blocks until `releaseInteractiveStill()` is called.
        var shouldBlockInteractiveStill: Bool = false
        private var interactiveStillContinuation: CheckedContinuation<MTLTexture, Error>?

        func requestInteractiveStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
            interactiveStillRequestCount += 1
            interactiveStillRequestTimes.append(videoTimeSeconds)

            if shouldBlockInteractiveStill {
                return try await withCheckedThrowingContinuation { continuation in
                    interactiveStillContinuation = continuation
                }
            }

            return createFakeTexture()
        }

        func releaseInteractiveStillResources() {
            didReleaseInteractiveResources = true
        }

        /// Resume a blocked interactive still request with a texture.
        func releaseInteractiveStill() {
            let texture = createFakeTexture()
            interactiveStillContinuation?.resume(returning: texture)
            interactiveStillContinuation = nil
        }

        func release() {}

        // MARK: - Playback Tracking (start-frame handoff regression seam)

        /// Video times passed to `startPlayback`, in call order.
        var startPlaybackTimes: [Double] = []
        /// Host times passed to `startPlayback`, in call order.
        var startPlaybackHostTimes: [CFTimeInterval?] = []

        func startPlayback(atVideoTime videoTimeSeconds: Double, hostTime: CFTimeInterval? = nil) {
            startPlaybackTimes.append(videoTimeSeconds)
            startPlaybackHostTimes.append(hostTime)
            isPlaybackActive = true
        }

        func stopPlayback(flush: Bool) {
            isPlaybackActive = false
        }

        /// Controls the playback-buffer path. By default returns nil (no pixel buffer
        /// available yet — the production stale-window). Tests can queue textures so
        /// the first tick(s) return nil and a later tick returns a distinct playback
        /// texture, mirroring AVPlayerItemVideoOutput warming up.
        var playbackTextureQueue: [MTLTexture?] = []
        var frameTextureForPlaybackCallCount: Int = 0

        func frameTextureForPlayback(expectedVideoTime videoTimeSeconds: Double, hostTime: CFTimeInterval? = nil) -> MTLTexture? {
            frameTextureForPlaybackCallCount += 1
            guard !playbackTextureQueue.isEmpty else { return nil }
            return playbackTextureQueue.removeFirst()
        }

        /// Make a distinct, identifiable texture for assertions.
        func makeDistinctTexture() -> MTLTexture { createFakeTexture() }

        /// Synchronous start-still cache. When set, `currentStartStillTexture` returns
        /// it (simulating a warm cache hit). When nil (default), the production code
        /// falls back to the async `requestStillTexture` path.
        var syncStartStillTexture: MTLTexture?
        var currentStartStillRequestTimes: [Double] = []

        func currentStartStillTexture(atVideoTime videoTimeSeconds: Double) -> MTLTexture? {
            currentStartStillRequestTimes.append(videoTimeSeconds)
            return syncStartStillTexture
        }

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
    private func setupVideoBlock(
        blockId: String = "block_01",
        trimStart: Double = 0,
        trimEnd: Double = 10.0
    ) async {
        let url = URL(fileURLWithPath: "/dev/null")
        _ = sut.setVideo(
            blockId: blockId,
            url: url,
            presentOnReady: true,
            persistedSelection: PersistedVideoSelection(trimStart: trimStart, trimEnd: trimEnd)
        )
        // Wait for poster delivery
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - previewExactVideoTrimFrame

    /// After previewExactVideoTrimFrame, mediaState is unchanged; texture injected into binding asset.
    func test_previewExactVideoTrimFrame_injectsTextureWithoutMutatingMediaState() async {
        await setupVideoBlock(trimStart: 1.0, trimEnd: 9.0)

        // Capture mediaState before preview
        let contextBefore = sut.videoTrimContext(blockId: "block_01")
        XCTAssertNotNil(contextBefore)

        // Record the texture that was set by poster setup, then clear it
        // so we can verify a NEW texture is injected by preview.
        fakeTextureProvider.removeTexture(for: "binding_asset_01")
        XCTAssertNil(fakeTextureProvider.texture(for: "binding_asset_01"), "Precondition: texture cleared")

        provider.stillRequestCount = 0

        let draftSelection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        sut.previewExactVideoTrimFrame(blockId: "block_01", draftSelection: draftSelection, previewTime: 5.0)

        // Wait for async still delivery
        try? await Task.sleep(nanoseconds: 200_000_000)

        // mediaState should still have original selection
        let contextAfter = sut.videoTrimContext(blockId: "block_01")
        XCTAssertEqual(contextAfter?.currentSelection.trimStart, 1.0, "mediaState should not be mutated by preview")
        XCTAssertEqual(contextAfter?.currentSelection.trimEnd, 9.0, "mediaState should not be mutated by preview")

        // Texture should have been actually injected into the binding asset
        XCTAssertNotNil(fakeTextureProvider.texture(for: "binding_asset_01"),
                        "Preview must inject texture into binding asset")
        XCTAssertGreaterThanOrEqual(provider.stillRequestCount, 1, "Should request still for preview")
    }

    /// previewTime outside draft range gets clamped to validated bounds.
    func test_previewExactVideoTrimFrame_clampsPreviewTimeToValidatedRange() async {
        await setupVideoBlock(trimStart: 0, trimEnd: 10.0)

        provider.stillRequestTimes = []

        let draftSelection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        // Preview time 20.0 is far outside [2.0, 8.0]
        sut.previewExactVideoTrimFrame(blockId: "block_01", draftSelection: draftSelection, previewTime: 20.0)

        try? await Task.sleep(nanoseconds: 200_000_000)

        // The requested time should be clamped to near trimEnd
        if let requestedTime = provider.stillRequestTimes.last {
            XCTAssertLessThanOrEqual(requestedTime, 8.0, "Preview time should be clamped to draft range")
            XCTAssertGreaterThanOrEqual(requestedTime, 2.0, "Preview time should be clamped to draft range")
        } else {
            XCTFail("Expected at least one still request")
        }
    }

    /// Rapid-fire calls with overlapping async — only last texture survives in binding asset.
    /// Uses blocking provider to create real overlap, proving the generation-token logic
    /// in requestStillForBlock discards stale completions.
    func test_previewExactVideoTrimFrame_latestWins() async {
        await setupVideoBlock(trimStart: 0, trimEnd: 10.0)

        // Switch to blocking mode so requests pile up
        provider.shouldBlockStill = true
        provider.stillRequestTimes = []
        provider.returnedTextures = []

        let draft = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)

        // Fire first request — it blocks in requestStillTexture
        sut.previewExactVideoTrimFrame(blockId: "block_01", draftSelection: draft, previewTime: 1.0)
        // Yield so the Task enters the await
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Fire second request — cancels first task, also blocks
        sut.previewExactVideoTrimFrame(blockId: "block_01", draftSelection: draft, previewTime: 3.0)
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Fire third (final) request — cancels second task, blocks
        sut.previewExactVideoTrimFrame(blockId: "block_01", draftSelection: draft, previewTime: 5.0)
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Release the blocked still — only the third request's task is alive
        provider.releaseStill()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // The last requested time should be 5.0
        XCTAssertEqual(provider.stillRequestTimes.last, 5.0, "Latest preview call should win")

        // Verify only one texture was actually injected (the last one)
        // The first two were cancelled before they could inject.
        let finalTexture = fakeTextureProvider.texture(for: "binding_asset_01")
        XCTAssertNotNil(finalTexture, "Final texture should be injected")

        // The returned textures list should have exactly 1 entry (only last release succeeded)
        XCTAssertEqual(provider.returnedTextures.count, 1,
                       "Only the last request should complete and produce a texture")
    }

    // MARK: - currentVideoTime

    /// Missing blockId returns nil.
    func test_currentVideoTime_returnsNilForMissingBlock() {
        let result = sut.currentVideoTime(blockId: "nonexistent", sceneFrameIndex: 0)
        XCTAssertNil(result, "Should return nil for missing block")
    }

    /// Block not visible at given frame returns nil.
    func test_currentVideoTime_returnsNilWhenBlockNotVisible() async {
        await setupVideoBlock(trimStart: 0, trimEnd: 10.0)

        // Block is visible only at frames 0..<90 (3 seconds at 30fps)
        fakePlayer.blockTimingOverrides["block_01"] = BlockTiming(startFrame: 0, endFrame: 90)

        // Frame 100 is outside [0, 90)
        let result = sut.currentVideoTime(blockId: "block_01", sceneFrameIndex: 100)
        XCTAssertNil(result, "Should return nil when block not visible at frame")
    }

    /// Visible block returns expected clamped video time.
    func test_currentVideoTime_returnsTimeWhenBlockVisible() async {
        await setupVideoBlock(trimStart: 1.0, trimEnd: 9.0)

        // Block visible at frames 0..<300 (10 seconds at 30fps)
        fakePlayer.blockTimingOverrides["block_01"] = BlockTiming(startFrame: 0, endFrame: 300)
        sut.setSceneFPS(30.0)

        // Frame 30 = 1 second into block → tVideo = trimStart + 1.0 = 2.0
        let result = sut.currentVideoTime(blockId: "block_01", sceneFrameIndex: 30)
        XCTAssertNotNil(result)
        if let t = result {
            XCTAssertEqual(t, 2.0, accuracy: 0.05, "Should return trimStart + blockTime")
        }
    }

    // MARK: - Interactive Trim Preview

    /// updateInteractiveTrimPreview calls interactive still, not exact still.
    func test_updateInteractiveTrimPreview_callsInteractiveStillNotExact() async {
        await setupVideoBlock(trimStart: 0, trimEnd: 10.0)

        provider.stillRequestCount = 0
        provider.interactiveStillRequestCount = 0

        let draft = PersistedVideoSelection(trimStart: 1.0, trimEnd: 9.0)
        sut.updateInteractiveTrimPreview(blockId: "block_01", draftSelection: draft, previewTime: 5.0)

        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertGreaterThanOrEqual(provider.interactiveStillRequestCount, 1,
                                     "Should use interactive still path")
        XCTAssertEqual(provider.stillRequestCount, 0,
                        "Should NOT use exact still path during interactive preview")
    }

    /// Rapid calls while blocked coalesce — only last time is delivered.
    func test_updateInteractiveTrimPreview_coalesces() async {
        await setupVideoBlock(trimStart: 0, trimEnd: 10.0)

        provider.shouldBlockInteractiveStill = true
        provider.interactiveStillRequestTimes = []

        let draft = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)

        // First call starts the loop and blocks
        sut.updateInteractiveTrimPreview(blockId: "block_01", draftSelection: draft, previewTime: 1.0)
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Rapid calls while first is in-flight — these overwrite pending
        sut.updateInteractiveTrimPreview(blockId: "block_01", draftSelection: draft, previewTime: 3.0)
        sut.updateInteractiveTrimPreview(blockId: "block_01", draftSelection: draft, previewTime: 5.0)
        sut.updateInteractiveTrimPreview(blockId: "block_01", draftSelection: draft, previewTime: 7.0)

        // Unblock the first request
        provider.shouldBlockInteractiveStill = false
        provider.releaseInteractiveStill()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // First request was 1.0, then the loop picks up 7.0 (latest pending)
        // So we expect exactly 2 requests: 1.0 and 7.0
        XCTAssertEqual(provider.interactiveStillRequestTimes.count, 2,
                        "Should coalesce to first in-flight + latest pending")
        XCTAssertEqual(provider.interactiveStillRequestTimes.first, 1.0,
                        "First request should be the initial time")
        XCTAssertEqual(provider.interactiveStillRequestTimes.last, 7.0,
                        "Last request should be the most recent pending time")
    }

    /// Interactive preview does not mutate mediaState.
    func test_updateInteractiveTrimPreview_doesNotMutateMediaState() async {
        await setupVideoBlock(trimStart: 1.0, trimEnd: 9.0)

        let contextBefore = sut.videoTrimContext(blockId: "block_01")

        let draft = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        sut.updateInteractiveTrimPreview(blockId: "block_01", draftSelection: draft, previewTime: 5.0)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let contextAfter = sut.videoTrimContext(blockId: "block_01")
        XCTAssertEqual(contextAfter?.currentSelection.trimStart, contextBefore?.currentSelection.trimStart,
                        "mediaState should not be mutated by interactive preview")
        XCTAssertEqual(contextAfter?.currentSelection.trimEnd, contextBefore?.currentSelection.trimEnd,
                        "mediaState should not be mutated by interactive preview")
    }

    /// endInteractiveTrimPreview cleans up task and releases provider resources.
    func test_endInteractiveTrimPreview_cleansUpAndReleasesResources() async {
        await setupVideoBlock(trimStart: 0, trimEnd: 10.0)

        provider.shouldBlockInteractiveStill = true
        provider.didReleaseInteractiveResources = false

        let draft = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        sut.updateInteractiveTrimPreview(blockId: "block_01", draftSelection: draft, previewTime: 5.0)
        try? await Task.sleep(nanoseconds: 50_000_000)

        // End while request is in-flight
        sut.endInteractiveTrimPreview(blockId: "block_01")

        XCTAssertTrue(provider.didReleaseInteractiveResources,
                       "Should release interactive resources on end")
    }

    /// After interactive → end → exact, the exact path is used.
    func test_exactAfterInteractive_usesExactPath() async {
        await setupVideoBlock(trimStart: 0, trimEnd: 10.0)

        provider.stillRequestCount = 0
        provider.interactiveStillRequestCount = 0

        let draft = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)

        // Interactive phase
        sut.updateInteractiveTrimPreview(blockId: "block_01", draftSelection: draft, previewTime: 3.0)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // End interactive
        sut.endInteractiveTrimPreview(blockId: "block_01")

        // Now request exact
        provider.stillRequestCount = 0
        sut.previewExactVideoTrimFrame(blockId: "block_01", draftSelection: draft, previewTime: 5.0)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(provider.stillRequestCount, 1,
                        "Exact path should use requestStillTexture")
    }

    // MARK: - Playback Window

    func testApplyPersistedVideoSelection_updatesPlaybackWindow() async throws {
        await setupVideoBlock()

        // Initial window from setVideo
        XCTAssertEqual(provider.playbackWindowStart, 0.0)
        XCTAssertEqual(provider.playbackWindowEnd, 10.0)

        // Apply new selection
        let newSelection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 3.0)
        try sut.applyPersistedVideoSelection(blockId: "block_01", newSelection)

        XCTAssertEqual(provider.playbackWindowStart, 1.0,
            "applyPersistedVideoSelection must update playback window start")
        XCTAssertEqual(provider.playbackWindowEnd, 3.0,
            "applyPersistedVideoSelection must update playback window end")
    }

    func testSetVideoAsyncCommit_preservesTrimAppliedWhileSetupIsPending() async throws {
        let url = URL(fileURLWithPath: "/tmp/test.mov")

        _ = sut.setVideo(
            blockId: "block_01",
            url: url,
            presentOnReady: true,
            persistedSelection: PersistedVideoSelection(trimStart: 0.0, trimEnd: 10.0)
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sut.videoTrimContext(blockId: "block_01")?.currentSelection.trimEnd, 10.0)

        provider.shouldBlockPoster = true
        _ = sut.setVideo(
            blockId: "block_01",
            url: url,
            presentOnReady: true,
            persistedSelection: PersistedVideoSelection(trimStart: 0.0, trimEnd: 10.0)
        )

        try sut.applyPersistedVideoSelection(
            blockId: "block_01",
            PersistedVideoSelection(trimStart: 0.0, trimEnd: 4.0)
        )
        XCTAssertEqual(provider.playbackWindowEnd, 4.0)

        provider.releasePoster()
        try await Task.sleep(nanoseconds: 200_000_000)

        let context = sut.videoTrimContext(blockId: "block_01")
        XCTAssertEqual(context?.currentSelection.trimEnd, 4.0,
            "Late setVideo completion must not overwrite a trim committed while setup was pending")
        XCTAssertEqual(provider.playbackWindowEnd, 4.0,
            "Late setVideo completion must preserve the committed playback window")
    }

    // MARK: - Interactive Timeline Scrub Stills

    /// updateVideoStillFramesInteractive routes through the tolerant interactive
    /// generator (not the exact still path), injects the texture, and fires the
    /// render-only callback.
    func test_updateVideoStillFramesInteractive_usesInteractiveGeneratorAndDelivers() async {
        await setupVideoBlock(trimStart: 0, trimEnd: 10.0)

        provider.stillRequestCount = 0
        provider.interactiveStillRequestCount = 0
        fakeTextureProvider.removeTexture(for: "binding_asset_01")

        var stillDeliveredCount = 0
        sut.onStillFrameDelivered = { stillDeliveredCount += 1 }

        sut.updateVideoStillFramesInteractive(sceneFrameIndex: 30, mediaFrameIndex: 30)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertGreaterThanOrEqual(provider.interactiveStillRequestCount, 1,
            "Interactive scrub must use the tolerant interactive still generator")
        XCTAssertEqual(provider.stillRequestCount, 0,
            "Interactive scrub must NOT use the exact still path")
        XCTAssertNotNil(fakeTextureProvider.texture(for: "binding_asset_01"),
            "Interactive scrub must inject the delivered texture")
        XCTAssertGreaterThanOrEqual(stillDeliveredCount, 1,
            "Interactive scrub must fire the render-only onStillFrameDelivered callback")
    }

    /// Rapid interactive scrub calls coalesce: while one request is in flight, the
    /// intermediate ticks collapse into a single pending "latest" time instead of
    /// issuing one request per call. The serviced time is the most recent (latest-wins).
    func test_updateVideoStillFramesInteractive_coalescesRapidCalls() async {
        await setupVideoBlock(trimStart: 0, trimEnd: 10.0)

        provider.interactiveStillRequestCount = 0
        provider.shouldBlockInteractiveStill = true

        // Fire several rapid scrub ticks synchronously. The first schedules the
        // drain loop; the rest only overwrite the pending "latest" time.
        sut.updateVideoStillFramesInteractive(sceneFrameIndex: 10, mediaFrameIndex: 10)
        sut.updateVideoStillFramesInteractive(sceneFrameIndex: 20, mediaFrameIndex: 20)
        sut.updateVideoStillFramesInteractive(sceneFrameIndex: 30, mediaFrameIndex: 30)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Coalesced: exactly one in-flight request, servicing the LATEST time, not
        // one request per tick.
        XCTAssertEqual(provider.interactiveStillRequestCount, 1,
            "Rapid scrub ticks must coalesce: one in-flight request, not one per tick")
        // sceneFPS=30, blockStartFrame=0, trimStart=0 → frame 30 maps to 30/30 = 1.0s.
        XCTAssertEqual(provider.interactiveStillRequestTimes.last ?? -1, 1.0, accuracy: 1e-6,
            "The single coalesced request must service the latest scrub time (frame 30 → 1.0s)")

        // Release; with no newer pending time the loop drains and issues no extra request.
        provider.releaseInteractiveStill()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(provider.interactiveStillRequestCount, 1,
            "No newer pending time arrived, so no additional request is issued after completion")
    }

    // MARK: - Playback Start-Frame Handoff (real playback seam)

    /// Sets up a visible, ready video block granted for playback.
    private func setupVisiblePlaybackBlock(
        blockId: String = "block_01",
        trimStart: Double,
        trimEnd: Double
    ) async {
        await setupVideoBlock(blockId: blockId, trimStart: trimStart, trimEnd: trimEnd)
        fakePlayer.makeVisible(blockId: blockId)
    }

    /// Sync cache hit: `prepareStartFrames` binds the cached start still immediately
    /// (no async still request), replacing the stale texture before transport start.
    func test_prepareStartFrames_synchronousCachedStill_bindsImmediately() async {
        await setupVisiblePlaybackBlock(trimStart: 2.0, trimEnd: 8.0)

        let staleTexture = provider.makeDistinctTexture()
        fakeTextureProvider.setTexture(staleTexture, for: "binding_asset_01")

        let warmStartStill = provider.makeDistinctTexture()
        provider.syncStartStillTexture = warmStartStill
        provider.stillRequestCount = 0

        await sut.prepareStartFrames(
            grantedBlockIds: ["block_01"], sceneFrameIndex: 0, mediaFrameIndex: 0
        )

        let bound = fakeTextureProvider.texture(for: "binding_asset_01")
        XCTAssertTrue(bound === warmStartStill,
            "A matching cached start still must bind synchronously")
        XCTAssertEqual(provider.stillRequestCount, 0,
            "Synchronous cache hit must not trigger an async still request")
    }

    /// Deterministic cold-cache handoff (Codex repair instr. 4): when no synchronous
    /// cached still exists, `prepareStartFrames` AWAITS the exact still and binds it.
    /// The await does not return until the still is delivered, so the stale texture is
    /// never presented at the start boundary — proven by gating the still and checking
    /// the binding both while blocked and after release, with no arbitrary sleep.
    func test_prepareStartFrames_coldCache_awaitsExactStill_noStaleAtBoundary() async {
        await setupVisiblePlaybackBlock(trimStart: 2.0, trimEnd: 8.0)

        let staleTexture = provider.makeDistinctTexture()
        fakeTextureProvider.setTexture(staleTexture, for: "binding_asset_01")

        // Cold cache: no synchronous still available; still request blocks until released.
        provider.syncStartStillTexture = nil
        provider.shouldBlockStill = true

        let handoff = Task { @MainActor in
            await sut.prepareStartFrames(
                grantedBlockIds: ["block_01"], sceneFrameIndex: 0, mediaFrameIndex: 0
            )
        }

        // While the exact still is still being produced, the handoff must NOT have
        // returned, and the still must have been requested (awaited, not skipped).
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(handoff.isCancelled)
        XCTAssertGreaterThanOrEqual(provider.stillRequestCount, 1,
            "Cold cache must await an exact still request")

        // Release the exact still; only now does the handoff complete and bind it.
        provider.releaseStill()
        await handoff.value

        let bound = fakeTextureProvider.texture(for: "binding_asset_01")
        XCTAssertNotNil(bound)
        XCTAssertFalse(bound === staleTexture,
            "Awaited exact still must replace the stale texture before transport start")
        XCTAssertTrue(bound === provider.returnedTextures.last,
            "The bound texture must be the awaited exact start still")
    }

    // MARK: - Playback Start Contract: result-bearing media preparation

    /// Hard-gated contract: a synchronous cached start still yields `.prepared`, the
    /// result that permits opening the shared boundary.
    func test_prepareStartFrames_syncCacheHit_returnsPrepared() async {
        await setupVisiblePlaybackBlock(trimStart: 2.0, trimEnd: 8.0)
        provider.syncStartStillTexture = provider.makeDistinctTexture()

        let result = await sut.prepareStartFrames(
            grantedBlockIds: ["block_01"], sceneFrameIndex: 0, mediaFrameIndex: 0
        )

        XCTAssertEqual(result, .prepared)
        XCTAssertTrue(result == UserMediaStartFrameResult.prepared)
    }

    /// Hard-gated contract: when the awaited exact still FAILS (non-cancellation),
    /// `prepareStartFrames` reports `.failed` instead of silently proceeding
    /// best-effort, so the epoch coordinator can refuse to open the boundary.
    func test_prepareStartFrames_exactStillFailure_returnsFailed_notBestEffort() async {
        await setupVisiblePlaybackBlock(trimStart: 2.0, trimEnd: 8.0)

        // Cold cache + the exact still extraction fails.
        provider.syncStartStillTexture = nil
        provider.stillFailureError = NSError(domain: "test.still", code: 1)

        let result = await sut.prepareStartFrames(
            grantedBlockIds: ["block_01"], sceneFrameIndex: 0, mediaFrameIndex: 0
        )

        XCTAssertEqual(result, .failed(blockId: "block_01"),
            "A failed exact start still must produce .failed, not a best-effort .prepared")
    }

    /// Hard-gated contract: a granted set with no visible video block yields
    /// `.noVisibleVideo`, which DOES permit opening the boundary (nothing to gate on).
    func test_prepareStartFrames_noGrantedVisibleVideo_returnsNoVisibleVideo() async {
        await setupVisiblePlaybackBlock(trimStart: 2.0, trimEnd: 8.0)

        // Grant a block that does not exist / is not visible.
        let result = await sut.prepareStartFrames(
            grantedBlockIds: ["block_does_not_exist"], sceneFrameIndex: 0, mediaFrameIndex: 0
        )

        XCTAssertEqual(result, .noVisibleVideo)
    }

    /// Ordering regression (Codex repair instr. 3/5): a live playback texture must win.
    /// After the deterministic handoff binds the start frame, `startVideoPlayback`
    /// launches NO async still, so a real playback texture injected by a tick is never
    /// overwritten by a late start still.
    func test_startVideoPlayback_noAsyncStartStill_livePlaybackTextureWins() async {
        await setupVisiblePlaybackBlock(trimStart: 2.0, trimEnd: 8.0)

        // Deterministic handoff already bound a start frame (sync cache hit here).
        let startStill = provider.makeDistinctTexture()
        provider.syncStartStillTexture = startStill
        await sut.prepareStartFrames(
            grantedBlockIds: ["block_01"], sceneFrameIndex: 0, mediaFrameIndex: 0
        )

        provider.stillRequestCount = 0

        // A real playback texture arrives on the first tick.
        let playbackTexture = provider.makeDistinctTexture()
        provider.playbackTextureQueue = [playbackTexture]

        sut.startVideoPlayback(
            sceneFrameIndex: 0, mediaFrameIndex: 0,
            grantedBlockIds: ["block_01"], hostTime: nil
        )
        sut.updateVideoFramesForPlayback(
            sceneFrameIndex: 0, mediaFrameIndex: 0,
            grantedBlockIds: ["block_01"], hostTime: nil
        )

        // Give any (incorrectly launched) async still a chance to land and overwrite.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(provider.stillRequestCount, 0,
            "startVideoPlayback must NOT launch an async start still (no late overwrite path)")
        let bound = fakeTextureProvider.texture(for: "binding_asset_01")
        XCTAssertTrue(bound === playbackTexture,
            "The live playback texture must remain bound — no late still overwrite")
    }

    /// The provider's playback start must use the committed trim-mapped video time,
    /// so playback begins inside `[trimStart, trimEnd)`, not at file time 0.
    func test_startVideoPlayback_usesCommittedTrimMappedTime() async {
        await setupVisiblePlaybackBlock(trimStart: 2.0, trimEnd: 8.0)

        provider.startPlaybackTimes = []

        // mediaFrameIndex 0 with blockStartFrame 0, trimStart 2.0, sceneFPS 30 →
        // committed mapped time = trimStart + 0/30 = 2.0s.
        sut.startVideoPlayback(
            sceneFrameIndex: 0, mediaFrameIndex: 0,
            grantedBlockIds: ["block_01"], hostTime: nil
        )

        XCTAssertEqual(provider.startPlaybackTimes.count, 1,
            "Granted visible block must start playback exactly once")
        XCTAssertEqual(provider.startPlaybackTimes.first ?? -1, 2.0, accuracy: 1e-6,
            "Playback must start at the committed trim-mapped time, not file time 0")
    }

    /// Trim-commit → immediate Play (Codex repair instr. 6): after applying a
    /// `trimStart > 0` selection through the runtime fast-apply path, the deterministic
    /// handoff binds the exact start still for the committed trim start before playback.
    func test_prepareStartFrames_afterTrimCommit_bindsCommittedTrimStart() async {
        await setupVisiblePlaybackBlock(trimStart: 0.0, trimEnd: 10.0)

        let staleTexture = provider.makeDistinctTexture()
        fakeTextureProvider.setTexture(staleTexture, for: "binding_asset_01")

        // Commit a new trimStart through the production apply path.
        try? sut.applyPersistedVideoSelection(
            blockId: "block_01", PersistedVideoSelection(trimStart: 3.0, trimEnd: 9.0)
        )

        // Cold cache for the new start; await the exact still at the committed trimStart.
        provider.syncStartStillTexture = nil
        provider.shouldBlockStill = false
        provider.stillRequestTimes = []

        await sut.prepareStartFrames(
            grantedBlockIds: ["block_01"], sceneFrameIndex: 0, mediaFrameIndex: 0
        )

        // Committed trimStart 3.0, blockStartFrame 0, frame 0 → mapped time 3.0s.
        XCTAssertEqual(provider.stillRequestTimes.last ?? -1, 3.0, accuracy: 1e-6,
            "Handoff must request the exact still at the committed trim start, not the old one")
        let bound = fakeTextureProvider.texture(for: "binding_asset_01")
        XCTAssertFalse(bound === staleTexture,
            "Pre-commit/stale texture must be replaced by the committed trim-start still")
    }

    // MARK: - Binding-Writer Exclusivity (stale-writer races)

    /// Writer exclusivity (Codex repair instr. 2/5): an exact still task started BEFORE
    /// Play that completes AFTER `prepareStartFrames` must not overwrite the start frame
    /// or a live playback texture. The handoff takes an exclusive writer epoch that
    /// invalidates the older exact still's generation.
    func test_prepareStartFrames_invalidatesInFlightExactStill_noLateOverwrite() async {
        await setupVisiblePlaybackBlock(trimStart: 2.0, trimEnd: 8.0)

        // An exact still request is in flight (blocked) from before Play.
        provider.shouldBlockStill = true
        sut.updateVideoStillFrames(sceneFrameIndex: 5, mediaFrameIndex: 5)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThanOrEqual(provider.stillRequestCount, 1, "Precondition: an exact still is in flight")

        // Deterministic handoff binds the start frame via a sync cache hit.
        let startStill = provider.makeDistinctTexture()
        provider.syncStartStillTexture = startStill
        await sut.prepareStartFrames(
            grantedBlockIds: ["block_01"], sceneFrameIndex: 0, mediaFrameIndex: 0
        )
        XCTAssertTrue(fakeTextureProvider.texture(for: "binding_asset_01") === startStill,
            "Handoff bound the start frame")

        // The old exact still now completes — it must be invalidated (no overwrite).
        provider.releaseStill()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(fakeTextureProvider.texture(for: "binding_asset_01") === startStill,
            "A stale exact still completing after the handoff must NOT overwrite the start frame")
    }

    /// Writer exclusivity for the pause/scrub → Play flow (Codex repair instr. 2/5):
    /// an interactive scrub still in flight from before Play must not overwrite the
    /// start frame or live playback after the handoff invalidates its generation.
    func test_prepareStartFrames_invalidatesInFlightScrubStill_noLateOverwrite() async {
        await setupVisiblePlaybackBlock(trimStart: 2.0, trimEnd: 8.0)

        // An interactive scrub still is in flight (blocked) from before Play.
        provider.shouldBlockInteractiveStill = true
        sut.updateVideoStillFramesInteractive(sceneFrameIndex: 5, mediaFrameIndex: 5)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThanOrEqual(provider.interactiveStillRequestCount, 1,
            "Precondition: an interactive scrub still is in flight")

        // Deterministic handoff binds the start frame, then a live playback texture wins.
        let startStill = provider.makeDistinctTexture()
        provider.syncStartStillTexture = startStill
        await sut.prepareStartFrames(
            grantedBlockIds: ["block_01"], sceneFrameIndex: 0, mediaFrameIndex: 0
        )

        let playbackTexture = provider.makeDistinctTexture()
        provider.playbackTextureQueue = [playbackTexture]
        sut.startVideoPlayback(
            sceneFrameIndex: 0, mediaFrameIndex: 0, grantedBlockIds: ["block_01"], hostTime: nil
        )
        sut.updateVideoFramesForPlayback(
            sceneFrameIndex: 0, mediaFrameIndex: 0, grantedBlockIds: ["block_01"], hostTime: nil
        )
        XCTAssertTrue(fakeTextureProvider.texture(for: "binding_asset_01") === playbackTexture,
            "Live playback texture is bound")

        // The old scrub still now completes — it must be invalidated (no overwrite).
        provider.releaseInteractiveStill()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(fakeTextureProvider.texture(for: "binding_asset_01") === playbackTexture,
            "A stale interactive scrub still completing after Play must NOT overwrite live playback")
    }
}
