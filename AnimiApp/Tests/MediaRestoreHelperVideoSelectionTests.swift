import XCTest
import Metal
import AVFoundation
import TVECore
@testable import AnimiApp

/// Tests for MediaRestoreHelper video selection persistence behavior.
/// Verifies Fix 1 (emitSelectionPersistence suppression on restore) and Fix 2 (single-scene restore).
///
/// These tests exercise the real `MediaRestoreHelper.restore()` production path, including
/// the async ordering of `setVideo()` → poster task → `pendingPersistedSelection` application.
@MainActor
final class MediaRestoreHelperVideoSelectionTests: XCTestCase {

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

    final class FakeTextureFactory: TextureFactoryForMedia {
        private let device: MTLDevice
        init(device: MTLDevice) { self.device = device }
        func makeTexture(from image: UIImage) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
            return device.makeTexture(descriptor: desc)
        }
    }

    final class FakeVideoSetupProvider: VideoSetupProviding {
        var mode: Mode = .success(CMTime(seconds: 10.0, preferredTimescale: 600))

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
        func startPlayback(atSceneFrame sceneFrameIndex: Int) {}
        func stopPlayback(flush: Bool) {}
        func frameTextureForPlayback(sceneFrameIndex: Int) -> MTLTexture? { nil }
        func frameTextureForScrub(sceneFrameIndex: Int) -> MTLTexture? { nil }
        func frameTextureForFrozen(sceneFrameIndex: Int) -> MTLTexture? { nil }
    }

    // MARK: - Properties

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var fakePlayer: FakeScenePlayer!
    private var fakeTextureProvider: FakeTextureProvider!
    private var fakeTextureFactory: FakeTextureFactory!
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

        // Create a test video file that ProjectStore can resolve
        let projectsDir = try ProjectStore.shared.projectsDirectoryURL()
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
        fakeTextureFactory = nil
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
        MediaRef(kind: .file, id: testMediaRelativePath, mediaKind: .video)
    }

    // MARK: - Integration Tests (real MediaRestoreHelper.restore() path)

    /// Fix 1: MediaRestoreHelper.restore() with video does NOT fire onVideoSelectionChanged callback.
    func test_restoreVideo_doesNotEmitPersistenceCallback() async throws {
        var callbackFired = false
        sut.onVideoSelectionChanged = { _, _ in
            callbackFired = true
        }

        let assignments: [String: MediaRef] = ["block_v1": makeVideoMediaRef()]
        MediaRestoreHelper.restore(
            assignments: assignments,
            userMediaPresent: nil,
            videoSelections: nil,
            to: sut
        )

        // Wait for async poster extraction to complete
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(callbackFired, "onVideoSelectionChanged should NOT fire on restore path")
    }

    /// Fix 1: After MediaRestoreHelper.restore() with persisted selection,
    /// exportVideoSelectionsSnapshot returns matching trim/offset/audio params.
    /// This is the critical test: pendingPersistedSelection must be applied INSIDE the async
    /// poster task, not synchronously after setVideo returns.
    func test_restoreVideo_appliesPersistedTrimOffsetMuteVolume() async throws {
        let persisted = PersistedVideoSelection(
            trimStart: 2.0,
            trimEnd: 8.0,
            offset: 1.0,
            isMuted: true,
            volume: 0.5
        )

        let assignments: [String: MediaRef] = ["block_v1": makeVideoMediaRef()]
        let videoSelections: [String: PersistedVideoSelection] = ["block_v1": persisted]

        MediaRestoreHelper.restore(
            assignments: assignments,
            userMediaPresent: nil,
            videoSelections: videoSelections,
            to: sut
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
        XCTAssertEqual(vs.offset, 1.0, accuracy: 0.001)
        XCTAssertTrue(vs.isMuted)
        XCTAssertEqual(vs.volume, 0.5, accuracy: 0.001)
    }

    /// Fix 1: Restore with nil videoSelections keeps default runtime selection (0..duration).
    func test_restoreVideo_withoutPersistedSelection_keepsDefaultRuntimeSelection() async throws {
        let assignments: [String: MediaRef] = ["block_v1": makeVideoMediaRef()]

        MediaRestoreHelper.restore(
            assignments: assignments,
            userMediaPresent: nil,
            videoSelections: nil,
            to: sut
        )

        // Wait for async poster extraction
        try await Task.sleep(nanoseconds: 500_000_000)

        let snapshot = sut.exportVideoSelectionsSnapshot()
        guard let vs = snapshot["block_v1"] else {
            XCTFail("Expected default video selection for block_v1")
            return
        }

        // Default selection: trimStart=0, trimEnd=duration, offset=0
        XCTAssertEqual(vs.trimStart, 0, accuracy: 0.001)
        XCTAssertEqual(vs.offset, 0, accuracy: 0.001)
        XCTAssertFalse(vs.isMuted)
    }

    /// Fix 1: User-driven setVideo (default emitSelectionPersistence=true) fires callback.
    func test_userDrivenSetVideo_emitsPersistenceCallback() async throws {
        var callbackFired = false
        sut.onVideoSelectionChanged = { _, _ in
            callbackFired = true
        }

        // Direct user-driven setVideo — default params (emitSelectionPersistence=true)
        let success = sut.setVideo(
            blockId: "block_v1",
            url: testVideoURL,
            ownership: .temporary,
            presentOnReady: true
        )
        XCTAssertTrue(success)

        // Wait for async poster extraction
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(callbackFired, "onVideoSelectionChanged SHOULD fire for user-driven setVideo")
    }
}
