import XCTest
import Metal
import AVFoundation
import TVECore
@testable import AnimiApp

/// Tests for MediaRestoreCoordinator video selection persistence behavior.
/// Verifies restore via unified SceneMediaSlot (replacing old MediaRestoreHelper).
///
/// These tests exercise the real `MediaRestoreCoordinator.restore()` production path, including
/// the async ordering of `setVideo()` → poster task → `persistedSelection` validation and application.
@MainActor
final class MediaRestoreCoordinatorVideoSelectionTests: XCTestCase {

    // MARK: - Test Doubles (reused from UserMediaServiceReadinessTests pattern)

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

        func blockTiming(for blockId: String) -> BlockTiming? { nil }
        func blockPriorityInfo(blockId: String, at sceneFrameIndex: Int) -> BlockPriorityInfo? { nil }
    }

    final class FakeTextureProvider: MutableTextureProvider {
        private(set) var textures: [String: MTLTexture] = [:]
        func texture(for assetId: String) -> MTLTexture? { textures[assetId] }
        func setTexture(_ texture: MTLTexture, for assetId: String) { textures[assetId] = texture }
        func removeTexture(for assetId: String) { textures.removeValue(forKey: assetId) }
    }

    final class FakeVideoSetupProvider: VideoSetupProviding {
        var mode: Mode = .success(CMTime(seconds: 10.0, preferredTimescale: 600))

        var playbackWindowStart: Double?
        var playbackWindowEnd: Double?
        func setPlaybackWindow(start: Double, end: Double) {
            playbackWindowStart = start
            playbackWindowEnd = end
        }

        enum Mode {
            case success(CMTime)
        }

        var duration: CMTime {
            switch mode {
            case .success(let d): return d
            }
        }

        var isReady: Bool { true }
        var state: VideoProviderState { .ready }
        var isPlaybackActive: Bool { false }
        var presentationInfo: VideoPresentationInfo? = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 64, height: 64),
            preferredTransform: .identity
        )

        func requestPoster(at time: Double) async throws -> MTLTexture {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw NSError(domain: "Test", code: 1)
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
            guard let texture = device.makeTexture(descriptor: desc) else {
                throw NSError(domain: "Test", code: 2)
            }
            return texture
        }

        func release() {}
        func startPlayback(atVideoTime videoTimeSeconds: Double, hostTime: CFTimeInterval? = nil) {}
        func stopPlayback(flush: Bool) {}
        func frameTextureForPlayback(expectedVideoTime videoTimeSeconds: Double, hostTime: CFTimeInterval? = nil) -> MTLTexture? { nil }
        func currentStartStillTexture(atVideoTime videoTimeSeconds: Double) -> MTLTexture? { nil }
        func requestStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
            guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "Test", code: 1) }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
            guard let texture = device.makeTexture(descriptor: desc) else { throw NSError(domain: "Test", code: 2) }
            return texture
        }

        func requestInteractiveStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
            guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "Test", code: 1) }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
            guard let texture = device.makeTexture(descriptor: desc) else { throw NSError(domain: "Test", code: 2) }
            return texture
        }
        func releaseInteractiveStillResources() {}
    }

    // MARK: - Properties

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var fakePlayer: FakeScenePlayer!
    private var fakeTextureProvider: FakeTextureProvider!
    private var sut: UserMediaService!
    private var fakeProvider: FakeVideoSetupProvider!
    /// MediaRef relative path for test video (resolved by ProjectStore)
    private var testMediaRelativePath: String!
    /// Absolute URL of the test video file
    private var testVideoURL: URL!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = metalDevice
        commandQueue = device.makeCommandQueue()!

        fakePlayer = FakeScenePlayer()
        fakePlayer.addBlock(blockId: "block_v1", assetId: "binding_v1")

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

        // Create a test video file that ProjectStore can resolve
        let projectsDir = try ProjectStore().projectsDirectoryURL()
        testMediaRelativePath = "Media/TestRestore/test_\(UUID().uuidString).mp4"
        testVideoURL = projectsDir.appendingPathComponent(testMediaRelativePath)
        try FileManager.default.createDirectory(
            at: testVideoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x00]).write(to: testVideoURL)
    }

    override func tearDown() async throws {
        // Clean up test file
        if let url = testVideoURL {
            try? FileManager.default.removeItem(at: url)
        }
        sut = nil
        fakePlayer = nil
        fakeTextureProvider = nil
        device = nil
        commandQueue = nil
        fakeProvider = nil
        testMediaRelativePath = nil
        testVideoURL = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Builds a MediaRef that points to the test video via ProjectStore.
    private func makeVideoMediaRef() -> MediaRef {
        MediaRef(storagePath: testMediaRelativePath, mediaKind: .video)
    }

    /// Builds a `ResolvedMediaMap` by path-resolving each slot's `mediaRef`
    /// against the real projects directory. Replaces the old
    /// `makeResolveURL` closure.
    private func makeResolvedMap(for slots: [String: SceneMediaSlot]) -> ResolvedMediaMap {
        let projectsDir = try! ProjectStore().projectsDirectoryURL()
        var map: [ProjectAssetID: URL] = [:]
        for (_, slot) in slots {
            map[slot.mediaRef.assetId] = projectsDir.appendingPathComponent(slot.mediaRef.storagePath)
        }
        return ResolvedMediaMap(urlsByAssetId: map)
    }

    // MARK: - Integration Tests (real MediaRestoreCoordinator.restore() path)

    /// MediaRestoreCoordinator.restore() with video slot applies persisted trim/offset/audio.
    func test_restoreVideo_appliesPersistedTrimOffsetMuteVolume() async throws {
        let persisted = PersistedVideoSelection(
            trimStart: 2.0,
            trimEnd: 8.0,
            isMuted: true,
            volume: 0.5
        )

        let slots: [String: SceneMediaSlot] = [
            "block_v1": .video(mediaRef: makeVideoMediaRef(), placement: .default(fitMode: .cover), videoWindow: persisted)
        ]

        MediaRestoreCoordinator.restore(
            slots: slots,
            to: sut,
            resolved: makeResolvedMap(for: slots)
        )

        // Wait for async poster extraction to complete
        try await Task.sleep(nanoseconds: 500_000_000)

        let snapshot = sut.exportVideoSelectionsSnapshot()
        guard let vs = snapshot["block_v1"] else {
            XCTFail("Expected video selection for block_v1 after restore")
            return
        }

        XCTAssertEqual(vs.trimStart, 2.0, accuracy: 0.001)
        XCTAssertEqual(vs.trimEnd, 8.0, accuracy: 0.001)
        XCTAssertTrue(vs.isMuted)
        XCTAssertEqual(vs.volume, 0.5, accuracy: 0.001)
    }

    /// Restore with nil videoWindow explicitly fails (missing videoWindow).
    func test_restoreVideo_withoutVideoWindow_failsExplicitly() async throws {
        // Construct a slot with nil videoWindow (legacy/corrupt data)
        let slots: [String: SceneMediaSlot] = [
            "block_v1": SceneMediaSlot(asset: SceneMediaAsset(mediaRef: makeVideoMediaRef(), placement: .defaultCover, videoWindow: nil))
        ]

        MediaRestoreCoordinator.restore(
            slots: slots,
            to: sut,
            resolved: makeResolvedMap(for: slots)
        )

        // Wait for any async processing
        try await Task.sleep(nanoseconds: 200_000_000)

        // Should be marked as failed, not silently accepted
        XCTAssertTrue(sut.hasFailedMedia, "Video with nil videoWindow should fail restore")
        XCTAssertFalse(sut.isSceneMediaReady, "Scene should not be ready with failed video")
    }

    /// Restore respects slot visibility (presentOnReady).
    func test_restoreVideo_respectsSlotVisibility() async throws {
        let persisted = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        let slots: [String: SceneMediaSlot] = [
            "block_v1": .video(mediaRef: makeVideoMediaRef(), visibility: false, placement: .default(fitMode: .cover), videoWindow: persisted)
        ]

        MediaRestoreCoordinator.restore(
            slots: slots,
            to: sut,
            resolved: makeResolvedMap(for: slots)
        )

        // Wait for async poster extraction
        try await Task.sleep(nanoseconds: 500_000_000)

        // Visibility should be false (presentOnReady=false)
        XCTAssertEqual(fakePlayer.userMediaPresentByBlock["block_v1"], false)
    }
}
