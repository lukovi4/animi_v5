import XCTest
import Metal
import AVFoundation
import TVECore
@testable import AnimiApp

/// P0: Tests for UserMediaService readiness contract via public API.
/// Uses injectable seam for VideoSetupProviding to control setup outcomes.
@MainActor
final class UserMediaServiceReadinessTests: XCTestCase {

    // MARK: - Test Doubles

    /// Fake scene player for testing.
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
            nil  // Not needed for readiness tests
        }

        func blockPriorityInfo(blockId: String, at sceneFrameIndex: Int) -> BlockPriorityInfo? {
            nil  // Not needed for readiness tests
        }
    }

    /// Fake texture provider for testing.
    final class FakeTextureProvider: MutableTextureProvider {
        private(set) var textures: [String: MTLTexture] = [:]

        func texture(for assetId: String) -> MTLTexture? {
            textures[assetId]
        }

        func setTexture(_ texture: MTLTexture, for assetId: String) {
            textures[assetId] = texture
        }

        func removeTexture(for assetId: String) {
            textures.removeValue(forKey: assetId)
        }
    }

    /// Fake texture factory for testing setPhoto() path.
    final class FakeTextureFactory: TextureFactoryForMedia {
        private let device: MTLDevice

        init(device: MTLDevice) {
            self.device = device
        }

        func makeTexture(from image: UIImage) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 64,
                height: 64,
                mipmapped: false
            )
            return device.makeTexture(descriptor: descriptor)
        }
    }

    /// Controllable fake video provider for testing setup outcomes.
    final class FakeVideoSetupProvider: VideoSetupProviding {
        enum Mode {
            case success(CMTime)
            case failure(Error)
            case pending  // Never completes
        }

        var mode: Mode = .success(CMTime(seconds: 5.0, preferredTimescale: 600))
        var releaseCallCount = 0
        var posterRequestCallCount = 0

        private var pendingContinuation: CheckedContinuation<MTLTexture, Error>?

        var duration: CMTime {
            switch mode {
            case .success(let duration):
                return duration
            case .failure, .pending:
                return .zero
            }
        }

        var isReady: Bool { true }
        var state: VideoProviderState { .ready }
        var isPlaybackActive: Bool { false }

        func requestPoster(at time: Double) async throws -> MTLTexture {
            posterRequestCallCount += 1

            switch mode {
            case .success:
                // Return a minimal fake texture
                return try await createFakeTexture()
            case .failure(let error):
                throw error
            case .pending:
                // Never complete - wait forever
                return try await withCheckedThrowingContinuation { continuation in
                    pendingContinuation = continuation
                }
            }
        }

        func release() {
            releaseCallCount += 1
            // Cancel pending continuation if any
            pendingContinuation?.resume(throwing: CancellationError())
            pendingContinuation = nil
        }

        func startPlayback(atSceneFrame sceneFrameIndex: Int) {}
        func stopPlayback(flush: Bool) {}
        func frameTextureForPlayback(sceneFrameIndex: Int) -> MTLTexture? { nil }
        func frameTextureForScrub(sceneFrameIndex: Int) -> MTLTexture? { nil }
        func frameTextureForFrozen(sceneFrameIndex: Int) -> MTLTexture? { nil }

        private func createFakeTexture() async throws -> MTLTexture {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Metal device"])
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 64,
                height: 64,
                mipmapped: false
            )
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
            }
            return texture
        }
    }

    // MARK: - Test Properties

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var fakePlayer: FakeScenePlayer!
    private var fakeTextureProvider: FakeTextureProvider!
    private var fakeTextureFactory: FakeTextureFactory!
    private var sut: UserMediaService!
    private var fakeProvider: FakeVideoSetupProvider!

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
        fakeTextureFactory = FakeTextureFactory(device: device)

        sut = UserMediaService(
            device: device,
            commandQueue: commandQueue,
            scenePlayerForTest: fakePlayer,
            textureProvider: fakeTextureProvider,
            textureFactory: fakeTextureFactory
        )

        fakeProvider = FakeVideoSetupProvider()
        sut.makeVideoProvider = { [weak self] _, _, _, _ in
            self?.fakeProvider ?? FakeVideoSetupProvider()
        }
    }

    override func tearDown() async throws {
        sut = nil
        fakePlayer = nil
        fakeTextureProvider = nil
        fakeTextureFactory = nil
        device = nil
        commandQueue = nil
        fakeProvider = nil
        try await super.tearDown()
    }

    // MARK: - Test: No Video → Ready

    /// Test: No video blocks means isSceneMediaReady == true, hasFailedMedia == false.
    func testNoVideo_isReady() {
        // Given: Fresh service with no videos set

        // Then
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready when no videos")
        XCTAssertFalse(sut.hasFailedMedia, "Should have no failed videos when none set")
    }

    // MARK: - Test: setVideo Start → Pending

    /// Test: setVideo start sets isSceneMediaReady == false.
    func testSetVideoStart_isPending() async throws {
        // Given: Provider that never completes
        fakeProvider.mode = .pending

        // When: Start video setup
        let accepted = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"))

        // Then: Should be accepted but not ready
        XCTAssertTrue(accepted, "setVideo should return true")
        XCTAssertFalse(sut.isSceneMediaReady, "Should not be ready while pending")
        XCTAssertFalse(sut.hasFailedMedia, "Should not have failed videos while pending")
    }

    // MARK: - Test: setVideo Success → Ready

    /// Test: setVideo success sets isSceneMediaReady == true.
    func testSetVideoSuccess_isReady() async throws {
        // Given: Provider that succeeds
        fakeProvider.mode = .success(CMTime(seconds: 5.0, preferredTimescale: 600))

        // When: Start video setup and wait for completion
        let accepted = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"))
        XCTAssertTrue(accepted)

        // Wait for async poster generation to complete
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Then
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after success")
        XCTAssertFalse(sut.hasFailedMedia, "Should have no failed videos after success")
    }

    // MARK: - Test: setVideo Failure → Failed

    /// Test: setVideo failure sets hasFailedMedia == true.
    func testSetVideoFailure_hasFailed() async throws {
        // Given: Provider that fails
        let testError = NSError(domain: "Test", code: 100, userInfo: [NSLocalizedDescriptionKey: "Test failure"])
        fakeProvider.mode = .failure(testError)

        // When: Start video setup
        let accepted = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"))
        XCTAssertTrue(accepted)

        // Wait for async poster generation to fail
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Then
        XCTAssertFalse(sut.isSceneMediaReady, "Should not be ready after failure")
        XCTAssertTrue(sut.hasFailedMedia, "Should have failed videos after failure")
    }

    // MARK: - Test: Failed Video → clear() Clears Failure

    /// Test: clear() on failed video clears the failure state.
    func testFailedVideo_clearClearsFailure() async throws {
        // Given: Failed video
        fakeProvider.mode = .failure(NSError(domain: "Test", code: 1))
        _ = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(sut.hasFailedMedia, "Precondition: should have failed video")

        // When: Clear the block
        sut.clear(blockId: "block_01")

        // Then
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after clear")
        XCTAssertFalse(sut.hasFailedMedia, "Should have no failed videos after clear")
    }

    // MARK: - Test: Failed Video → setPhoto() Clears Failure

    /// Test: setPhoto() on failed video clears the failure state.
    func testFailedVideo_setPhotoClearsFailure() async throws {
        // Given: Failed video
        fakeProvider.mode = .failure(NSError(domain: "Test", code: 1))
        _ = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(sut.hasFailedMedia, "Precondition: should have failed video")

        // When: Replace with photo using real setPhoto() API
        let testImage = createTestImage()
        let success = sut.setPhoto(blockId: "block_01", image: testImage)

        // Then
        XCTAssertTrue(success, "setPhoto should succeed")
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after photo replacement")
        XCTAssertFalse(sut.hasFailedMedia, "Should have no failed videos after photo replacement")
    }

    // MARK: - Test: Pending Video → setPhoto() Clears Pending

    /// Test: setPhoto() on pending video clears the pending state.
    func testPendingVideo_setPhotoClearsPending() async throws {
        // Given: Pending video (never completes)
        fakeProvider.mode = .pending
        _ = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"))

        XCTAssertFalse(sut.isSceneMediaReady, "Precondition: should not be ready while pending")

        // When: Replace with photo using real setPhoto() API
        let testImage = createTestImage()
        let success = sut.setPhoto(blockId: "block_01", image: testImage)

        // Then
        XCTAssertTrue(success, "setPhoto should succeed")
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after photo replacement")
        XCTAssertFalse(sut.hasFailedMedia, "Should have no failed videos")
    }

    // MARK: - Test: Photo Failure → Not Ready

    /// Test: setPhoto failure (texture creation failed) sets hasFailedMedia == true.
    func testPhotoFailure_hasFailedMedia() async throws {
        // Given: Texture factory that fails
        let failingFactory = FailingTextureFactory()
        sut = UserMediaService(
            device: device,
            commandQueue: commandQueue,
            scenePlayerForTest: fakePlayer,
            textureProvider: fakeTextureProvider,
            textureFactory: failingFactory
        )

        // When: Try to set photo
        let testImage = createTestImage()
        let success = sut.setPhoto(blockId: "block_01", image: testImage)

        // Then
        XCTAssertFalse(success, "setPhoto should fail with failing texture factory")
        XCTAssertFalse(sut.isSceneMediaReady, "Should not be ready after photo failure")
        XCTAssertTrue(sut.hasFailedMedia, "Should have failed media after photo failure")
    }

    // MARK: - Test: Video Pending → presentOnReady Respected

    /// Test: setVideo with presentOnReady: false does NOT set userMediaPresent while pending.
    func testVideoWithPresentOnReadyFalse_doesNotSetPresentWhilePending() async throws {
        // Given: Provider that never completes
        fakeProvider.mode = .pending

        // When: Start video setup with presentOnReady: false
        let accepted = sut.setVideo(
            blockId: "block_01",
            url: URL(fileURLWithPath: "/tmp/test.mov"),
            presentOnReady: false
        )

        // Then: Video accepted but present not set
        XCTAssertTrue(accepted, "setVideo should return true")
        XCTAssertNil(fakePlayer.userMediaPresentByBlock["block_01"],
                     "userMediaPresent should not be set while pending with presentOnReady: false")
    }

    /// Test: setVideo with presentOnReady: true DOES set userMediaPresent after success.
    func testVideoWithPresentOnReadyTrue_setsPresentAfterSuccess() async throws {
        // Given: Provider that succeeds
        fakeProvider.mode = .success(CMTime(seconds: 5.0, preferredTimescale: 600))

        // When: Start video setup with presentOnReady: true (default)
        _ = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"))

        // Wait for async poster generation to complete
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Then: userMediaPresent should be true
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], true,
                       "userMediaPresent should be true after success with presentOnReady: true")
    }

    // MARK: - Test: setPhoto with presentOnReady

    /// Test: setPhoto with presentOnReady: false does NOT set userMediaPresent.
    func testPhotoWithPresentOnReadyFalse_doesNotSetPresent() {
        // When: Set photo with presentOnReady: false
        let testImage = createTestImage()
        let success = sut.setPhoto(blockId: "block_01", image: testImage, presentOnReady: false)

        // Then
        XCTAssertTrue(success, "setPhoto should succeed")
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], false,
                       "userMediaPresent should be false with presentOnReady: false")
    }

    /// Test: setPhoto with presentOnReady: true (default) DOES set userMediaPresent.
    func testPhotoWithPresentOnReadyTrue_setsPresent() {
        // When: Set photo with default presentOnReady (true)
        let testImage = createTestImage()
        let success = sut.setPhoto(blockId: "block_01", image: testImage)

        // Then
        XCTAssertTrue(success, "setPhoto should succeed")
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], true,
                       "userMediaPresent should be true with presentOnReady: true")
    }

    // MARK: - Test: markRestoreFailed

    /// Test: markRestoreFailed sets failed state and cleans up.
    func testMarkRestoreFailed_setsFailedState() {
        // Given: Service with player
        XCTAssertTrue(sut.isSceneMediaReady, "Precondition: should be ready")

        // When: Mark restore failed
        sut.markRestoreFailed(blockId: "block_01", reason: "test failure")

        // Then
        XCTAssertFalse(sut.isSceneMediaReady, "Should not be ready after markRestoreFailed")
        XCTAssertTrue(sut.hasFailedMedia, "Should have failed media after markRestoreFailed")
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], false,
                       "userMediaPresent should be false after markRestoreFailed")
    }

    /// Test: markRestoreFailed clears existing textures.
    func testMarkRestoreFailed_clearsTextures() {
        // Given: Photo already set
        let testImage = createTestImage()
        _ = sut.setPhoto(blockId: "block_01", image: testImage)
        XCTAssertNotNil(fakeTextureProvider.textures["binding_asset_01"], "Precondition: texture should exist")

        // When: Mark restore failed
        sut.markRestoreFailed(blockId: "block_01", reason: "test failure")

        // Then: Texture should be removed
        XCTAssertNil(fakeTextureProvider.textures["binding_asset_01"], "Texture should be removed after markRestoreFailed")
    }

    // MARK: - Test: clear() After markRestoreFailed

    /// Test: clear() after markRestoreFailed returns service to neutral ready state.
    func testClearAfterMarkRestoreFailed_returnsToReady() {
        // Given: Block marked as failed
        sut.markRestoreFailed(blockId: "block_01", reason: "test failure")
        XCTAssertTrue(sut.hasFailedMedia, "Precondition: should have failed media")

        // When: Clear the block
        sut.clear(blockId: "block_01")

        // Then: Service should be ready again
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after clear")
        XCTAssertFalse(sut.hasFailedMedia, "Should have no failed media after clear")
    }

    // MARK: - Test Helpers

    /// Failing texture factory for testing photo failure path.
    final class FailingTextureFactory: TextureFactoryForMedia {
        func makeTexture(from image: UIImage) -> MTLTexture? {
            return nil  // Always fail
        }
    }

    /// Creates a minimal test image for setPhoto() tests.
    private func createTestImage() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        UIColor.red.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return image
    }

    // MARK: - Test: clearAll() Removes All State

    /// Test: clearAll() removes all stale residue.
    func testClearAll_removesAllState() async throws {
        // Given: Multiple blocks in various states
        fakePlayer.addBlock(blockId: "block_02", assetId: "binding_asset_02")
        fakePlayer.addBlock(blockId: "block_03", assetId: "binding_asset_03")

        // Set up one success, one failure, one pending
        let successProvider = FakeVideoSetupProvider()
        successProvider.mode = .success(CMTime(seconds: 5.0, preferredTimescale: 600))

        let failureProvider = FakeVideoSetupProvider()
        failureProvider.mode = .failure(NSError(domain: "Test", code: 1))

        let pendingProvider = FakeVideoSetupProvider()
        pendingProvider.mode = .pending

        var providerIndex = 0
        let providers = [successProvider, failureProvider, pendingProvider]
        sut.makeVideoProvider = { _, _, _, _ in
            let provider = providers[providerIndex]
            providerIndex += 1
            return provider
        }

        _ = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test1.mov"))
        _ = sut.setVideo(blockId: "block_02", url: URL(fileURLWithPath: "/tmp/test2.mov"))
        _ = sut.setVideo(blockId: "block_03", url: URL(fileURLWithPath: "/tmp/test3.mov"))

        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify mixed state before clearAll
        XCTAssertFalse(sut.isSceneMediaReady, "Precondition: should not be ready with mixed state")

        // When
        sut.clearAll()

        // Then
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after clearAll")
        XCTAssertFalse(sut.hasFailedMedia, "Should have no failed videos after clearAll")
    }
}
