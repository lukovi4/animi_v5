import XCTest
import Metal
import AVFoundation
import TVECore
@testable import AnimiApp

/// TT-03: Tests for UserMediaService grant-aware playback APIs.
/// Verifies:
/// - `playbackCandidates(sceneFrameIndex:)` returns sorted candidates
/// - Grant-aware `startVideoPlayback/updateVideoFramesForPlayback` respect granted blocks
/// - Scene-edit wrappers grant all ready visible playback candidates
@MainActor
final class UserMediaServiceBudgetTests: XCTestCase {

    // MARK: - Test Doubles

    /// Fake scene player with configurable block priorities.
    final class FakeScenePlayer: ScenePlayerForMedia {
        private(set) var assetIdsByBlock: [String: [String: String]] = [:]
        private(set) var userMediaPresentByBlock: [String: Bool] = [:]
        var blockPriorities: [String: BlockPriorityInfo] = [:]
        var blockTimings: [String: BlockTiming] = [:]

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
            blockTimings[blockId]
        }

        func blockPriorityInfo(blockId: String, at sceneFrameIndex: Int) -> BlockPriorityInfo? {
            blockPriorities[blockId]
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

    /// Controllable fake video provider with tracking for playback calls.
    final class TrackingVideoProvider: VideoSetupProviding {
        var isReady: Bool = true
        var state: VideoProviderState { isReady ? .ready : .loading }
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

        // Tracking
        var startPlaybackCalls: [Double] = []
        var stopPlaybackCalls: [Bool] = []  // flush parameter
        var frameTextureForPlaybackCalls: [Double] = []
        var lastTexture: MTLTexture?

        private let device: MTLDevice

        init(device: MTLDevice) {
            self.device = device
            lastTexture = createFakeTexture()
        }

        func requestPoster(at time: Double) async throws -> MTLTexture {
            return createFakeTexture()
        }

        func release() {
            isPlaybackActive = false
        }

        func startPlayback(atVideoTime videoTimeSeconds: Double, hostTime: CFTimeInterval? = nil) {
            startPlaybackCalls.append(videoTimeSeconds)
            isPlaybackActive = true
        }

        func stopPlayback(flush: Bool) {
            stopPlaybackCalls.append(flush)
            isPlaybackActive = false
        }

        func frameTextureForPlayback(expectedVideoTime videoTimeSeconds: Double, hostTime: CFTimeInterval? = nil) -> MTLTexture? {
            frameTextureForPlaybackCalls.append(videoTimeSeconds)
            return lastTexture
        }
        func currentStartStillTexture(atVideoTime videoTimeSeconds: Double) -> MTLTexture? { nil }

        func requestStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
            return lastTexture ?? createFakeTexture()
        }

        func requestInteractiveStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
            return lastTexture ?? createFakeTexture()
        }
        func releaseInteractiveStillResources() {}

        private func createFakeTexture() -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 64,
                height: 64,
                mipmapped: false
            )
            return device.makeTexture(descriptor: descriptor)!
        }
    }

    // MARK: - Test Properties

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var fakePlayer: FakeScenePlayer!
    private var fakeTextureProvider: FakeTextureProvider!
    private var sut: UserMediaService!
    private var providers: [String: TrackingVideoProvider] = [:]

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = metalDevice
        commandQueue = device.makeCommandQueue()!

        fakePlayer = FakeScenePlayer()
        fakeTextureProvider = FakeTextureProvider()
        providers = [:]

        sut = UserMediaService(
            device: device,
            commandQueue: commandQueue,
            scenePlayerForTest: fakePlayer,
            textureProvider: fakeTextureProvider
        )

        // Configure factory to create tracking providers
        sut.makeVideoProvider = { [weak self] device, _, _, _ in
            guard let self = self else { return TrackingVideoProvider(device: device) }
            let provider = TrackingVideoProvider(device: device)
            return provider
        }
    }

    override func tearDown() async throws {
        sut = nil
        fakePlayer = nil
        fakeTextureProvider = nil
        providers = [:]
        device = nil
        commandQueue = nil
        try await super.tearDown()
    }

    // MARK: - Helper: Setup video blocks

    /// Sets up video blocks with configurable priorities.
    private func setupVideoBlocks(
        _ blockConfigs: [(id: String, priority: BlockPriorityInfo)]
    ) async throws {
        for config in blockConfigs {
            fakePlayer.addBlock(blockId: config.id, assetId: "asset_\(config.id)")
            fakePlayer.blockPriorities[config.id] = config.priority
            // Make block visible by default
            fakePlayer.blockTimings[config.id] = BlockTiming(startFrame: 0, endFrame: 1000)

            // Track provider for assertions
            let trackingProvider = TrackingVideoProvider(device: device)
            providers[config.id] = trackingProvider

            // Configure factory to return our tracking provider
            var providerIndex = 0
            let allProviders = providers
            sut.makeVideoProvider = { device, _, _, _ in
                let ids = blockConfigs.map { $0.id }
                if providerIndex < ids.count {
                    let id = ids[providerIndex]
                    providerIndex += 1
                    return allProviders[id] ?? TrackingVideoProvider(device: device)
                }
                return TrackingVideoProvider(device: device)
            }
        }

        // Reset provider tracking
        var providerIndex = 0
        sut.makeVideoProvider = { [weak self] device, _, _, _ in
            guard let self = self else { return TrackingVideoProvider(device: device) }
            let ids = blockConfigs.map { $0.id }
            if providerIndex < ids.count {
                let id = ids[providerIndex]
                providerIndex += 1
                let provider = TrackingVideoProvider(device: device)
                self.providers[id] = provider
                return provider
            }
            return TrackingVideoProvider(device: device)
        }

        // Set videos
        for config in blockConfigs {
            _ = sut.setVideo(blockId: config.id, url: URL(fileURLWithPath: "/tmp/\(config.id).mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))
        }

        // Wait for setup
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Test: playbackCandidates sorting

    /// Test: playbackCandidates returns candidates sorted by visibility, area, zIndex, blockId.
    func testPlaybackCandidates_sortsByPriority() async throws {
        // Given: 4 blocks with different priorities
        let configs: [(id: String, priority: BlockPriorityInfo)] = [
            ("block_d", BlockPriorityInfo(isVisible: false, area: 500, zIndex: 1)),
            ("block_a", BlockPriorityInfo(isVisible: true, area: 100, zIndex: 2)),
            ("block_c", BlockPriorityInfo(isVisible: true, area: 100, zIndex: 2)),
            ("block_b", BlockPriorityInfo(isVisible: true, area: 200, zIndex: 1))
        ]

        try await setupVideoBlocks(configs)

        // When
        let candidates = sut.playbackCandidates(sceneFrameIndex: 0)

        // Then: Sorted by isVisible desc → area desc → zIndex desc → blockId asc
        // Expected order:
        // 1. block_b (visible=true, area=200, zIndex=1)
        // 2. block_a (visible=true, area=100, zIndex=2) - tied on area, higher zIndex
        // 3. block_c (visible=true, area=100, zIndex=2, but blockId > block_a)
        // 4. block_d (visible=false)
        XCTAssertEqual(candidates.count, 4)
        XCTAssertEqual(candidates[0].blockId, "block_b")
        XCTAssertEqual(candidates[1].blockId, "block_a")
        XCTAssertEqual(candidates[2].blockId, "block_c")
        XCTAssertEqual(candidates[3].blockId, "block_d")
    }

    /// Test: playbackCandidates only includes ready providers.
    func testPlaybackCandidates_onlyIncludesReadyProviders() async throws {
        // Given: 2 blocks, one ready and one not
        fakePlayer.addBlock(blockId: "block_ready", assetId: "asset_ready")
        fakePlayer.addBlock(blockId: "block_pending", assetId: "asset_pending")
        fakePlayer.blockPriorities["block_ready"] = BlockPriorityInfo(isVisible: true, area: 100, zIndex: 1)
        fakePlayer.blockPriorities["block_pending"] = BlockPriorityInfo(isVisible: true, area: 100, zIndex: 1)

        let readyProvider = TrackingVideoProvider(device: device)
        readyProvider.isReady = true
        providers["block_ready"] = readyProvider

        let pendingProvider = TrackingVideoProvider(device: device)
        pendingProvider.isReady = false
        providers["block_pending"] = pendingProvider

        var providerIndex = 0
        sut.makeVideoProvider = { [weak self] device, _, _, _ in
            guard let self = self else { return TrackingVideoProvider(device: device) }
            let ids = ["block_ready", "block_pending"]
            if providerIndex < ids.count {
                let id = ids[providerIndex]
                providerIndex += 1
                return self.providers[id] ?? TrackingVideoProvider(device: device)
            }
            return TrackingVideoProvider(device: device)
        }

        _ = sut.setVideo(blockId: "block_ready", url: URL(fileURLWithPath: "/tmp/ready.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))
        _ = sut.setVideo(blockId: "block_pending", url: URL(fileURLWithPath: "/tmp/pending.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))
        try await Task.sleep(nanoseconds: 100_000_000)

        // When
        let candidates = sut.playbackCandidates(sceneFrameIndex: 0)

        // Then: Only ready provider included
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].blockId, "block_ready")
    }

    // MARK: - Test: Grant-aware startVideoPlayback

    /// Test: startVideoPlayback with grants starts only granted blocks.
    func testGrantAwareStartPlayback_startsOnlyGrantedBlocks() async throws {
        // Given: 3 blocks
        let configs: [(id: String, priority: BlockPriorityInfo)] = [
            ("block_a", BlockPriorityInfo(isVisible: true, area: 100, zIndex: 1)),
            ("block_b", BlockPriorityInfo(isVisible: true, area: 100, zIndex: 1)),
            ("block_c", BlockPriorityInfo(isVisible: true, area: 100, zIndex: 1))
        ]
        try await setupVideoBlocks(configs)

        // When: Start playback with only block_a and block_c granted
        sut.startVideoPlayback(sceneFrameIndex: 0, mediaFrameIndex: 0, grantedBlockIds: ["block_a", "block_c"])

        // Then: Only granted blocks started
        XCTAssertTrue(providers["block_a"]?.startPlaybackCalls.count ?? 0 > 0, "block_a should be started")
        XCTAssertEqual(providers["block_b"]?.startPlaybackCalls.count ?? 0, 0, "block_b should NOT be started")
        XCTAssertTrue(providers["block_c"]?.startPlaybackCalls.count ?? 0 > 0, "block_c should be started")
    }

    /// Test: startVideoPlayback soft-stops non-granted active providers.
    func testGrantAwareStartPlayback_softStopsNonGrantedActiveProviders() async throws {
        // Given: 2 blocks, both ready
        fakePlayer.addBlock(blockId: "block_a", assetId: "asset_a")
        fakePlayer.addBlock(blockId: "block_b", assetId: "asset_b")
        fakePlayer.blockPriorities["block_a"] = BlockPriorityInfo(isVisible: true, area: 100, zIndex: 1)
        fakePlayer.blockPriorities["block_b"] = BlockPriorityInfo(isVisible: true, area: 100, zIndex: 1)
        fakePlayer.blockTimings["block_a"] = BlockTiming(startFrame: 0, endFrame: 1000)
        fakePlayer.blockTimings["block_b"] = BlockTiming(startFrame: 0, endFrame: 1000)

        let providerA = TrackingVideoProvider(device: device)
        let providerB = TrackingVideoProvider(device: device)
        providers["block_a"] = providerA
        providers["block_b"] = providerB

        var providerIndex = 0
        sut.makeVideoProvider = { [weak self] device, _, _, _ in
            guard let self = self else { return TrackingVideoProvider(device: device) }
            let ids = ["block_a", "block_b"]
            if providerIndex < ids.count {
                let id = ids[providerIndex]
                providerIndex += 1
                return self.providers[id] ?? TrackingVideoProvider(device: device)
            }
            return TrackingVideoProvider(device: device)
        }

        _ = sut.setVideo(blockId: "block_a", url: URL(fileURLWithPath: "/tmp/a.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))
        _ = sut.setVideo(blockId: "block_b", url: URL(fileURLWithPath: "/tmp/b.mov"), persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0))
        try await Task.sleep(nanoseconds: 100_000_000)

        // Simulate both providers are active
        providerA.startPlayback(atVideoTime: 0)
        providerB.startPlayback(atVideoTime: 0)
        XCTAssertTrue(providerB.isPlaybackActive)

        // When: Start with only block_a granted
        sut.startVideoPlayback(sceneFrameIndex: 10, mediaFrameIndex: 10, grantedBlockIds: ["block_a"])

        // Then: block_b should be soft-stopped (flush: false)
        XCTAssertTrue(providerB.stopPlaybackCalls.contains { $0 == false },
                      "block_b should be soft-stopped with flush: false")
    }

    // MARK: - Test: Scene-edit legacy wrapper has no active-provider cap

    /// Test: the scene-edit legacy `startVideoPlayback(sceneFrameIndex:mediaFrameIndex:)`
    /// wrapper starts ALL visible ready video providers — more than three — with no cap.
    func testLegacyStartWrapper_startsMoreThanThreeVisibleVideos_noCap() async throws {
        // Given: 5 visible ready video blocks (more than the removed provider cap of 3)
        let configs: [(id: String, priority: BlockPriorityInfo)] = (0..<5).map { i in
            (id: "block_\(i)", priority: BlockPriorityInfo(isVisible: true, area: Double(100 - i), zIndex: 1))
        }
        try await setupVideoBlocks(configs)

        // When: start playback through the legacy (no-grant) wrapper
        sut.startVideoPlayback(sceneFrameIndex: 0, mediaFrameIndex: 0)

        // Then: every visible video provider is started — none held back by a cap
        for config in configs {
            XCTAssertTrue(providers[config.id]?.startPlaybackCalls.count ?? 0 > 0,
                          "\(config.id) should be started (no active-provider cap)")
        }
    }

    /// Test: the scene-edit legacy `updateVideoFramesForPlayback(sceneFrameIndex:mediaFrameIndex:)`
    /// wrapper ticks ALL visible ready video providers — more than three — with no cap.
    func testLegacyUpdateWrapper_ticksMoreThanThreeVisibleVideos_noCap() async throws {
        // Given: 5 visible ready video blocks (more than the removed provider cap of 3)
        let configs: [(id: String, priority: BlockPriorityInfo)] = (0..<5).map { i in
            (id: "block_\(i)", priority: BlockPriorityInfo(isVisible: true, area: Double(100 - i), zIndex: 1))
        }
        try await setupVideoBlocks(configs)

        // When: tick playback through the legacy (no-grant) wrapper
        sut.updateVideoFramesForPlayback(sceneFrameIndex: 0, mediaFrameIndex: 0)

        // Then: every visible video provider is driven (started + texture fetched) — no cap
        for config in configs {
            let provider = providers[config.id]
            XCTAssertTrue(provider?.startPlaybackCalls.count ?? 0 > 0,
                          "\(config.id) should be started on tick (no active-provider cap)")
            XCTAssertTrue(provider?.frameTextureForPlaybackCalls.count ?? 0 > 0,
                          "\(config.id) should have its frame texture fetched (no active-provider cap)")
        }
    }

}
