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

    final class StillTrackingProvider: VideoSetupProviding {
        var isReady: Bool = true
        var state: VideoProviderState { .ready }
        private(set) var isPlaybackActive: Bool = false
        var duration: CMTime = CMTime(seconds: 10.0, preferredTimescale: 600)
        var presentationInfo: VideoPresentationInfo? = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 64, height: 64),
            preferredTransform: .identity
        )

        private let device: MTLDevice
        var stillRequestCount: Int = 0
        var stillRequestTimes: [Double] = []

        /// When true, requestStillTexture blocks until `releaseStill()` is called.
        var shouldBlockStill: Bool = false
        private var stillContinuation: CheckedContinuation<MTLTexture, Error>?

        /// Textures returned by each still request (indexed by request order).
        var returnedTextures: [MTLTexture] = []

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
        func startPlayback(atVideoTime videoTimeSeconds: Double) {}
        func stopPlayback(flush: Bool) {}
        func frameTextureForPlayback(expectedVideoTime videoTimeSeconds: Double) -> MTLTexture? { nil }

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
}
