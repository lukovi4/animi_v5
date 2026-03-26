import XCTest
import Metal
import ImageIO
import AVFoundation
import TVECore
@testable import AnimiApp

/// P0: Tests for UserMediaService readiness contract via public API.
/// Uses injectable seam for VideoSetupProviding to control setup outcomes.
/// Phase 2: Photo tests use file URL fixtures and await async completion.
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

        var overrideIsReady: Bool?
        var isReady: Bool { overrideIsReady ?? true }
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
    private var sut: UserMediaService!
    private var fakeProvider: FakeVideoSetupProvider!

    /// Temporary photo fixture URL — valid JPEG for setPhoto tests.
    private var photoFixtureURL: URL!

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

        fakeProvider = FakeVideoSetupProvider()
        sut.makeVideoProvider = { [weak self] _, _, _, _ in
            self?.fakeProvider ?? FakeVideoSetupProvider()
        }

        // Create photo fixture (64x64 red PNG on disk)
        photoFixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_photo_\(UUID().uuidString).png")
        try createTestImage(at: photoFixtureURL, width: 64, height: 64)
    }

    override func tearDown() async throws {
        if let url = photoFixtureURL {
            try? FileManager.default.removeItem(at: url)
        }
        sut = nil
        fakePlayer = nil
        fakeTextureProvider = nil
        device = nil
        commandQueue = nil
        fakeProvider = nil
        photoFixtureURL = nil
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
        let accepted = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))

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
        let accepted = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))
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
        let accepted = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))
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
        _ = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))
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
        _ = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(sut.hasFailedMedia, "Precondition: should have failed video")

        // When: Replace with photo using file URL
        let accepted = sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        XCTAssertTrue(accepted, "setPhoto should accept")

        // Wait for async texture load
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        // Then
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after photo replacement")
        XCTAssertFalse(sut.hasFailedMedia, "Should have no failed media after photo replacement")
    }

    // MARK: - Test: Pending Video → setPhoto() Clears Pending

    /// Test: setPhoto() on pending video cancels video and eventually becomes ready.
    func testPendingVideo_setPhotoClearsPending() async throws {
        // Given: Pending video (never completes)
        fakeProvider.mode = .pending
        _ = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))

        XCTAssertFalse(sut.isSceneMediaReady, "Precondition: should not be ready while pending")

        // When: Replace with photo
        let accepted = sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        XCTAssertTrue(accepted, "setPhoto should accept")

        // Wait for async texture load
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        // Then
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after photo replacement")
        XCTAssertFalse(sut.hasFailedMedia, "Should have no failed media")
    }

    // MARK: - Test: Photo Failure → Not Ready

    /// Test: setPhoto with missing file sets hasFailedMedia == true.
    func testPhotoFailure_hasFailedMedia() async throws {
        // Given: Non-existent file
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).png")

        // When: Try to set photo with missing file
        let accepted = sut.setPhoto(blockId: "block_01", fileURL: missingURL)
        XCTAssertTrue(accepted, "setPhoto should accept (failure is async)")

        // Wait for async failure
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        // Then
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
            presentOnReady: false,
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
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
        _ = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))

        // Wait for async poster generation to complete
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Then: userMediaPresent should be true
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], true,
                       "userMediaPresent should be true after success with presentOnReady: true")
    }

    // MARK: - Test: setPhoto with presentOnReady

    /// Test: setPhoto with presentOnReady: false respects the flag after async completion.
    func testPhotoWithPresentOnReadyFalse_doesNotSetPresent() async throws {
        // When: Set photo with presentOnReady: false
        let accepted = sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL, presentOnReady: false)
        XCTAssertTrue(accepted)

        // Wait for async texture load
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        // Then
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], false,
                       "userMediaPresent should be false with presentOnReady: false")
    }

    /// Test: setPhoto with presentOnReady: true (default) DOES set userMediaPresent after completion.
    func testPhotoWithPresentOnReadyTrue_setsPresent() async throws {
        // When: Set photo with default presentOnReady (true)
        let accepted = sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        XCTAssertTrue(accepted)

        // Wait for async texture load
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        // Then
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], true,
                       "userMediaPresent should be true with presentOnReady: true")
    }

    // MARK: - Test: Accepted Photo → Eventually Ready

    /// Test: accepted photo file → eventually ready.
    func testAcceptedPhotoFile_eventuallyReady() async throws {
        // When
        let accepted = sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        XCTAssertTrue(accepted)

        // Immediately after: should be pending
        XCTAssertFalse(sut.isSceneMediaReady, "Should not be ready immediately (async)")

        // Wait for async texture load
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        // Then
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after async load")
        XCTAssertFalse(sut.hasFailedMedia)
        XCTAssertNotNil(fakeTextureProvider.textures["binding_asset_01"], "Texture should be injected")
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
    func testMarkRestoreFailed_clearsTextures() async throws {
        // Given: Photo already set
        _ = sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        try await Task.sleep(nanoseconds: 200_000_000)
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

        let defaultSel = PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
        _ = sut.setVideo(blockId: "block_01", url: URL(fileURLWithPath: "/tmp/test1.mov"), persistedSelection: defaultSel)
        _ = sut.setVideo(blockId: "block_02", url: URL(fileURLWithPath: "/tmp/test2.mov"), persistedSelection: defaultSel)
        _ = sut.setVideo(blockId: "block_03", url: URL(fileURLWithPath: "/tmp/test3.mov"), persistedSelection: defaultSel)

        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify mixed state before clearAll
        XCTAssertFalse(sut.isSceneMediaReady, "Precondition: should not be ready with mixed state")

        // When
        sut.clearAll()

        // Then
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after clearAll")
        XCTAssertFalse(sut.hasFailedMedia, "Should have no failed videos after clearAll")
    }

    // MARK: - Test: Valid Photo → Replace with Corrupt/Missing File

    /// Regression: replacing a valid photo with a corrupt file must clean up the old texture and mediaState.
    func testValidPhoto_thenReplaceWithUnreadableFile_clearsOldTexture() async throws {
        // Given: Valid photo loaded
        _ = sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(sut.isSceneMediaReady, "Precondition: should be ready")
        XCTAssertNotNil(fakeTextureProvider.textures["binding_asset_01"], "Precondition: texture should exist")

        // When: Replace with corrupt file
        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt_\(UUID().uuidString).jpg")
        try Data([0xDE, 0xAD]).write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        _ = sut.setPhoto(blockId: "block_01", fileURL: corruptURL)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Then: Old texture cleaned up, block in failed state, no stale mediaState
        XCTAssertNil(fakeTextureProvider.textures["binding_asset_01"], "Old texture should be removed")
        XCTAssertFalse(sut.hasMedia(blockId: "block_01"), "Stale mediaState should be cleared")
        XCTAssertFalse(sut.isSceneMediaReady)
        XCTAssertTrue(sut.hasFailedMedia)
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], false)
    }

    /// Regression: replacing a valid photo with a missing file must clean up the old texture and mediaState.
    func testValidPhoto_thenReplaceWithMissingFile_clearsOldTexture() async throws {
        // Given: Valid photo loaded
        _ = sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(sut.isSceneMediaReady, "Precondition: should be ready")
        XCTAssertNotNil(fakeTextureProvider.textures["binding_asset_01"], "Precondition: texture should exist")

        // When: Replace with non-existent file
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).png")

        _ = sut.setPhoto(blockId: "block_01", fileURL: missingURL)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Then: Old texture cleaned up, block in failed state, no stale mediaState
        XCTAssertNil(fakeTextureProvider.textures["binding_asset_01"], "Old texture should be removed")
        XCTAssertFalse(sut.hasMedia(blockId: "block_01"), "Stale mediaState should be cleared")
        XCTAssertFalse(sut.isSceneMediaReady)
        XCTAssertTrue(sut.hasFailedMedia)
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], false)
    }

    // MARK: - Test: Effective window exceeds duration via offset → Failed

    /// Regression: persisted selection where offset pushes winEnd past actual duration must fail.
    /// Example: duration=5, trimStart=0, trimEnd=4, offset=2 → winEnd=6 > 5.
    func testSetVideo_offsetPushesWinEndPastDuration_fails() async throws {
        // Given: Provider that succeeds with duration 5s
        fakeProvider.mode = .success(CMTime(seconds: 5.0, preferredTimescale: 600))

        // Persisted selection: trimEnd=4, offset=2 → effective winEnd = trimEnd+offset = 6 > 5
        let badSelection = PersistedVideoSelection(
            trimStart: 0,
            trimEnd: 4.0,
            offset: 2.0
        )

        // When
        let accepted = sut.setVideo(
            blockId: "block_01",
            url: URL(fileURLWithPath: "/tmp/test.mov"),
            persistedSelection: badSelection
        )
        XCTAssertTrue(accepted, "setVideo should accept synchronously")

        // Wait for async validation to fail
        try await Task.sleep(nanoseconds: 200_000_000)

        // Then: must be in failed state
        XCTAssertTrue(sut.hasFailedMedia, "Should have failed media when winEnd exceeds duration")
        XCTAssertFalse(sut.isSceneMediaReady, "Should not be ready")
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], false,
                       "userMediaPresent should be false after validation failure")
        XCTAssertNil(fakeTextureProvider.textures["binding_asset_01"],
                     "No texture should be injected after validation failure")
    }

    /// Regression: persisted selection with negative offset producing negative winStart must fail.
    /// Example: trimStart=0, trimEnd=2, offset=-1 → winStart=-1 < 0.
    func testSetVideo_negativeWinStart_fails() async throws {
        // Given: Provider with duration 5s
        fakeProvider.mode = .success(CMTime(seconds: 5.0, preferredTimescale: 600))

        let badSelection = PersistedVideoSelection(
            trimStart: 0,
            trimEnd: 2.0,
            offset: -1.0  // winStart = 0 + (-1) = -1
        )

        // When
        _ = sut.setVideo(
            blockId: "block_01",
            url: URL(fileURLWithPath: "/tmp/test.mov"),
            persistedSelection: badSelection
        )

        try await Task.sleep(nanoseconds: 200_000_000)

        // Then
        XCTAssertTrue(sut.hasFailedMedia, "Should fail when winStart is negative")
        XCTAssertFalse(sut.isSceneMediaReady)
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_01"], false)
    }

    /// Valid selection with offset stays within duration → succeeds.
    func testSetVideo_offsetWithinDuration_succeeds() async throws {
        // Given: Provider with duration 10s
        fakeProvider.mode = .success(CMTime(seconds: 10.0, preferredTimescale: 600))

        // trimEnd=6, offset=2 → winEnd=8 <= 10 ✓
        let goodSelection = PersistedVideoSelection(
            trimStart: 1.0,
            trimEnd: 6.0,
            offset: 2.0
        )

        // When
        _ = sut.setVideo(
            blockId: "block_01",
            url: URL(fileURLWithPath: "/tmp/test.mov"),
            persistedSelection: goodSelection
        )

        try await Task.sleep(nanoseconds: 200_000_000)

        // Then
        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready with valid offset selection")
        XCTAssertFalse(sut.hasFailedMedia)
    }

    // MARK: - Test Helpers

    /// Creates a test image on disk using CGContext + CGImageDestination (no UIKit).
    private func createTestImage(at url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create context"])
        }

        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to make image"])
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination"])
        }

        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize"])
        }
    }

    // MARK: - Phase 5: Video Selection Edit Context

    /// videoSelectionEditContext returns context for ready video block.
    func testVideoSelectionEditContext_readyVideo_returnsContext() async throws {
        fakeProvider.mode = .success(CMTime(seconds: 10.0, preferredTimescale: 600))
        let url = URL(fileURLWithPath: "/tmp/test.mov")

        let accepted = sut.setVideo(
            blockId: "block_01", url: url,
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )
        XCTAssertTrue(accepted)

        // Wait for setup to complete
        try await Task.sleep(nanoseconds: 200_000_000)

        let context = sut.videoSelectionEditContext(blockId: "block_01")
        XCTAssertNotNil(context, "Should return context for ready video")
        if let ctx = context {
            XCTAssertEqual(ctx.actualDuration, 10.0, accuracy: 0.01)
            XCTAssertEqual(ctx.currentSelection.trimEnd, 10.0)
        }
    }

    /// videoSelectionEditContext returns nil for missing block.
    func testVideoSelectionEditContext_missingBlock_returnsNil() {
        let context = sut.videoSelectionEditContext(blockId: "nonexistent")
        XCTAssertNil(context, "Should return nil for missing block")
    }

    /// videoSelectionEditContext returns nil when provider is not ready.
    func testVideoSelectionEditContext_providerNotReady_returnsNil() async throws {
        fakeProvider.mode = .success(CMTime(seconds: 10.0, preferredTimescale: 600))
        let url = URL(fileURLWithPath: "/tmp/test.mov")

        _ = sut.setVideo(
            blockId: "block_01", url: url,
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )

        // Wait for setup to complete so mediaState has .video
        try await Task.sleep(nanoseconds: 200_000_000)

        // Now simulate provider becoming not-ready (e.g. budget eviction)
        fakeProvider.overrideIsReady = false

        let context = sut.videoSelectionEditContext(blockId: "block_01")
        XCTAssertNil(context, "Should return nil when provider is not ready")
    }

    // MARK: - Phase 5: Validated Apply

    /// applyPersistedVideoSelection with valid selection updates mediaState.
    func testApplyPersistedVideoSelection_valid_updatesMediaState() async throws {
        fakeProvider.mode = .success(CMTime(seconds: 10.0, preferredTimescale: 600))
        let url = URL(fileURLWithPath: "/tmp/test.mov")

        _ = sut.setVideo(
            blockId: "block_01", url: url,
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )

        // Wait for setup to complete
        try await Task.sleep(nanoseconds: 200_000_000)

        let newSelection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 8.0, offset: 0.5)
        XCTAssertNoThrow(
            try sut.applyPersistedVideoSelection(blockId: "block_01", newSelection),
            "Valid selection should not throw"
        )

        // Verify updated via videoSelectionEditContext
        let context = sut.videoSelectionEditContext(blockId: "block_01")
        XCTAssertEqual(context?.currentSelection.trimStart, 1.0)
        XCTAssertEqual(context?.currentSelection.trimEnd, 8.0)
        XCTAssertEqual(context?.currentSelection.offset, 0.5)
    }

    /// applyPersistedVideoSelection with invalid selection throws and keeps previous.
    func testApplyPersistedVideoSelection_invalid_throwsKeepsPrevious() async throws {
        fakeProvider.mode = .success(CMTime(seconds: 10.0, preferredTimescale: 600))
        let url = URL(fileURLWithPath: "/tmp/test.mov")

        _ = sut.setVideo(
            blockId: "block_01", url: url,
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )

        // Wait for setup to complete
        try await Task.sleep(nanoseconds: 200_000_000)

        // Invalid: trimEnd exceeds duration significantly
        let badSelection = PersistedVideoSelection(trimStart: 0, trimEnd: 100.0, offset: 50.0)
        XCTAssertThrowsError(
            try sut.applyPersistedVideoSelection(blockId: "block_01", badSelection),
            "Invalid selection should throw"
        )

        // Verify previous selection preserved
        let context = sut.videoSelectionEditContext(blockId: "block_01")
        XCTAssertEqual(context?.currentSelection.trimEnd, 10.0, "Previous selection should be preserved on throw")
    }

    /// applyPersistedVideoSelection on non-video block throws blockNotVideo.
    func testApplyPersistedVideoSelection_nonVideoBlock_throws() {
        let selection = PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
        XCTAssertThrowsError(
            try sut.applyPersistedVideoSelection(blockId: "nonexistent", selection)
        ) { error in
            guard case VideoSelectionApplyError.blockNotVideo = error else {
                XCTFail("Expected blockNotVideo error, got \(error)")
                return
            }
        }
    }

    /// applyPersistedVideoSelection does NOT mark block as failed on invalid selection.
    func testApplyPersistedVideoSelection_invalid_doesNotMarkFailed() async throws {
        fakeProvider.mode = .success(CMTime(seconds: 10.0, preferredTimescale: 600))
        let url = URL(fileURLWithPath: "/tmp/test.mov")

        _ = sut.setVideo(
            blockId: "block_01", url: url,
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )

        try await Task.sleep(nanoseconds: 200_000_000)

        let badSelection = PersistedVideoSelection(trimStart: 0, trimEnd: 100.0, offset: 50.0)
        _ = try? sut.applyPersistedVideoSelection(blockId: "block_01", badSelection)

        XCTAssertFalse(sut.hasFailedMedia, "Invalid apply should not mark media as failed")
        XCTAssertTrue(sut.isSceneMediaReady, "Media should still be ready after invalid apply")
    }

    // MARK: - Phase 6: Restore-Specific Failure Tracking

    /// didBlockFailRestore returns true after markRestoreFailed.
    func test_didBlockFailRestore_trueAfterMarkRestoreFailed() {
        sut.markRestoreFailed(blockId: "block_01", reason: "file not found")
        XCTAssertTrue(sut.didBlockFailRestore(blockId: "block_01"))
    }

    /// didBlockFailRestore returns false for blocks that haven't failed restore.
    func test_didBlockFailRestore_falseForUnknownBlock() {
        XCTAssertFalse(sut.didBlockFailRestore(blockId: "block_01"))
    }

    /// didBlockFailRestore returns false after normal video setup failure (not restore failure).
    func test_didBlockFailRestore_falseAfterNormalVideoFailure() async throws {
        fakeProvider.mode = .failure(NSError(domain: "Test", code: 1))
        _ = sut.setVideo(
            blockId: "block_01",
            url: URL(fileURLWithPath: "/tmp/test.mov"),
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        // hasFailedMedia is true (generic failure), but didBlockFailRestore is false
        XCTAssertTrue(sut.hasFailedMedia)
        XCTAssertFalse(sut.didBlockFailRestore(blockId: "block_01"),
                       "Normal video setup failure should NOT set restore-failed flag")
    }

    /// didBlockFailRestore clears on successful setPhoto rebind.
    func test_didBlockFailRestore_clearsOnSetPhoto() async throws {
        sut.markRestoreFailed(blockId: "block_01", reason: "file not found")
        XCTAssertTrue(sut.didBlockFailRestore(blockId: "block_01"))

        let accepted = sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        XCTAssertTrue(accepted)

        // After setPhoto acceptance, restore-failed flag is cleared immediately
        XCTAssertFalse(sut.didBlockFailRestore(blockId: "block_01"),
                       "setPhoto should clear restore-failed flag")
    }

    /// didBlockFailRestore clears on successful setVideo rebind.
    func test_didBlockFailRestore_clearsOnSetVideo() {
        sut.markRestoreFailed(blockId: "block_01", reason: "file not found")
        XCTAssertTrue(sut.didBlockFailRestore(blockId: "block_01"))

        fakeProvider.mode = .success(CMTime(seconds: 5.0, preferredTimescale: 600))
        _ = sut.setVideo(
            blockId: "block_01",
            url: URL(fileURLWithPath: "/tmp/test.mov"),
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
        )

        // After setVideo acceptance, restore-failed flag is cleared immediately
        XCTAssertFalse(sut.didBlockFailRestore(blockId: "block_01"),
                       "setVideo should clear restore-failed flag")
    }

    /// didBlockFailRestore clears on clear(blockId:).
    func test_didBlockFailRestore_clearsOnClear() {
        sut.markRestoreFailed(blockId: "block_01", reason: "file not found")
        XCTAssertTrue(sut.didBlockFailRestore(blockId: "block_01"))

        sut.clear(blockId: "block_01")
        XCTAssertFalse(sut.didBlockFailRestore(blockId: "block_01"),
                       "clear(blockId:) should clear restore-failed flag")
    }
}
