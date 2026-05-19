import XCTest
import Metal
import TVECore
@testable import AnimiApp

// MARK: - Mock Provider

private final class MockExportVideoFrameProvider: ExportVideoFrameProviding {
    let config: ExportVideoFrameProvider.Config
    let blockId: String

    var providerError: ExportVideoFrameProviderError?
    var presentationInfo: VideoPresentationInfo?

    var prepareCallCount = 0
    var finishCallCount = 0
    var cancelCallCount = 0
    var textureCallCount = 0
    var suspendCallCount = 0
    var resumeCallCount = 0
    var releaseDecodedStateCallCount = 0

    var textureToReturn: MTLTexture?
    var shouldThrowOnPrepare = false

    init(blockId: String, config: ExportVideoFrameProvider.Config) {
        self.blockId = blockId
        self.config = config
    }

    func prepareIfNeeded() throws {
        prepareCallCount += 1
        if shouldThrowOnPrepare {
            throw ExportVideoFrameProviderError.missingVideoTrack
        }
    }

    func texture(forTargetVideoTime targetTimeSeconds: Double) -> MTLTexture? {
        textureCallCount += 1
        return textureToReturn
    }

    func finish() {
        finishCallCount += 1
    }

    func cancel() {
        cancelCallCount += 1
    }

    func suspend() {
        suspendCallCount += 1
    }

    func resume() throws {
        resumeCallCount += 1
    }

    func releaseDecodedState() {
        releaseDecodedStateCallCount += 1
    }
}

// MARK: - Mock Texture Provider

private final class MockMutableTextureProvider: MutableTextureProvider, MutableAssetPresentationInfoProvider {
    var textures: [String: MTLTexture] = [:]
    var presentationInfos: [String: VideoPresentationInfo] = [:]
    var setTextureCallsByAssetId: [String: Int] = [:]
    var removeTextureCallsByAssetId: [String: Int] = [:]
    var setPresentationInfoCallsByAssetId: [String: Int] = [:]
    var removePresentationInfoCallsByAssetId: [String: Int] = [:]

    func texture(for assetId: String) -> MTLTexture? {
        textures[assetId]
    }

    func setTexture(_ texture: MTLTexture, for assetId: String) {
        textures[assetId] = texture
        setTextureCallsByAssetId[assetId, default: 0] += 1
    }

    func removeTexture(for assetId: String) {
        textures.removeValue(forKey: assetId)
        removeTextureCallsByAssetId[assetId, default: 0] += 1
    }

    func presentationInfo(for assetId: String) -> VideoPresentationInfo? {
        presentationInfos[assetId]
    }

    func setPresentationInfo(_ info: VideoPresentationInfo, for assetId: String) {
        presentationInfos[assetId] = info
        setPresentationInfoCallsByAssetId[assetId, default: 0] += 1
    }

    func removePresentationInfo(for assetId: String) {
        presentationInfos.removeValue(forKey: assetId)
        removePresentationInfoCallsByAssetId[assetId, default: 0] += 1
    }
}

// MARK: - Tests

final class ExportVideoSlotsCoordinatorTests: XCTestCase {

    private var device: MTLDevice!
    private var textureCache: CVMetalTextureCache!
    private var commandQueue: MTLCommandQueue!
    private var textureProvider: MockMutableTextureProvider!
    private var createdProviders: [MockExportVideoFrameProvider]!

    override func setUpWithError() throws {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available on this device")
        }
        device = d
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache!
        commandQueue = device.makeCommandQueue()!
        textureProvider = MockMutableTextureProvider()
        createdProviders = []
    }

    private func makeCoordinator(
        maxActiveProviders: Int = 4,
        prefetchFrames: Int = 15
    ) -> ExportVideoSlotsCoordinator {
        ExportVideoSlotsCoordinator(
            device: device,
            textureCache: textureCache,
            commandQueue: commandQueue,
            sceneFPS: 30,
            exportTextureProvider: textureProvider,
            videoPrefetchFrames: prefetchFrames,
            maxActiveProviders: maxActiveProviders,
            providerFactory: { [weak self] blockId, config in
                let p = MockExportVideoFrameProvider(blockId: blockId, config: config)
                self?.createdProviders.append(p)
                return p
            }
        )
    }

    private func dummyConfig() -> ExportVideoFrameProvider.Config {
        let selection = VideoSelection(
            url: URL(fileURLWithPath: "/tmp/test.mp4"),
            duration: 5
        )
        return ExportVideoFrameProvider.Config(selection: selection)
    }

    // MARK: - Tests

    func testConfigureDoesNotCreateProviders() {
        let coordinator = makeCoordinator()
        coordinator.configureSlots([
            (blockId: "block1", config: dummyConfig(), bindingAssetIds: ["asset1"], startFrame: 0, endFrame: 30),
            (blockId: "block2", config: dummyConfig(), bindingAssetIds: ["asset2"], startFrame: 30, endFrame: 60)
        ])

        XCTAssertEqual(createdProviders.count, 0, "configureSlots should not create any providers")
    }

    func testVisibleSlotCreatesProviderOnDemand() {
        let coordinator = makeCoordinator()
        coordinator.configureSlots([
            (blockId: "block1", config: dummyConfig(), bindingAssetIds: ["asset1"], startFrame: 0, endFrame: 30)
        ])

        coordinator.updateTextures(visibilityFrameIndex: 5, mediaFrameIndex: 5)

        XCTAssertEqual(createdProviders.count, 1, "Visible slot should create provider on demand")
        XCTAssertEqual(createdProviders[0].prepareCallCount, 1, "Provider should be prepared")
    }

    func testVisibleProvidersAreNeverEvictedByBudget() {
        let coordinator = makeCoordinator(maxActiveProviders: 3)
        coordinator.configureSlots([
            (blockId: "block1", config: dummyConfig(), bindingAssetIds: ["a1"], startFrame: 0, endFrame: 100),
            (blockId: "block2", config: dummyConfig(), bindingAssetIds: ["a2"], startFrame: 0, endFrame: 100),
            (blockId: "block3", config: dummyConfig(), bindingAssetIds: ["a3"], startFrame: 0, endFrame: 100),
            (blockId: "block4", config: dummyConfig(), bindingAssetIds: ["a4"], startFrame: 0, endFrame: 100)
        ])

        // All 4 slots visible at frame 50 with maxActiveProviders=3
        coordinator.updateTextures(visibilityFrameIndex: 50, mediaFrameIndex: 50)

        XCTAssertEqual(createdProviders.count, 4, "All 4 visible slots should have providers")
        for provider in createdProviders {
            XCTAssertEqual(provider.finishCallCount, 0, "Visible providers must never be evicted")
        }
    }

    func testPrefetchProvidersRespectRemainingCapacity() {
        let coordinator = makeCoordinator(maxActiveProviders: 4, prefetchFrames: 20)
        coordinator.configureSlots([
            // 2 visible at frame 50
            (blockId: "vis1", config: dummyConfig(), bindingAssetIds: ["a1"], startFrame: 0, endFrame: 100),
            (blockId: "vis2", config: dummyConfig(), bindingAssetIds: ["a2"], startFrame: 0, endFrame: 100),
            // 3 prefetch: start at 55, 60, 65 — distances 5, 10, 15
            (blockId: "pre1", config: dummyConfig(), bindingAssetIds: ["a3"], startFrame: 55, endFrame: 90),
            (blockId: "pre2", config: dummyConfig(), bindingAssetIds: ["a4"], startFrame: 60, endFrame: 95),
            (blockId: "pre3", config: dummyConfig(), bindingAssetIds: ["a5"], startFrame: 65, endFrame: 100)
        ])

        coordinator.updateTextures(visibilityFrameIndex: 50, mediaFrameIndex: 50)

        // 2 visible consume capacity → remaining = 4-2 = 2
        // Closest prefetch: pre1 (dist=5), pre2 (dist=10) get providers
        // pre3 (dist=15) should NOT get a provider
        let prefetchProviders = createdProviders.filter { $0.blockId == "pre1" || $0.blockId == "pre2" }
        let farPrefetch = createdProviders.filter { $0.blockId == "pre3" }

        XCTAssertEqual(prefetchProviders.count, 2, "2 closest prefetch slots should get providers")
        XCTAssertEqual(farPrefetch.count, 0, "Farthest prefetch should not get a provider (over capacity)")
    }

    func testVisibleInjectsTexture_PrefetchDoesNot() {
        // Create a real texture to return from visible provider
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
        let testTexture = device.makeTexture(descriptor: desc)!

        let coordinator = ExportVideoSlotsCoordinator(
            device: device,
            textureCache: textureCache,
            commandQueue: commandQueue,
            sceneFPS: 30,
            exportTextureProvider: textureProvider,
            videoPrefetchFrames: 20,
            maxActiveProviders: 4,
            providerFactory: { [weak self] blockId, config in
                let p = MockExportVideoFrameProvider(blockId: blockId, config: config)
                if blockId == "vis" {
                    p.textureToReturn = testTexture
                }
                self?.createdProviders.append(p)
                return p
            }
        )
        coordinator.configureSlots([
            // Visible at frame 10
            (blockId: "vis", config: dummyConfig(), bindingAssetIds: ["vis_asset"], startFrame: 0, endFrame: 30),
            // Prefetch at frame 10 (starts at 25, prefetch window = 25-20=5..25)
            (blockId: "pre", config: dummyConfig(), bindingAssetIds: ["pre_asset"], startFrame: 25, endFrame: 60)
        ])

        coordinator.updateTextures(visibilityFrameIndex: 10, mediaFrameIndex: 10)

        let visProvider = createdProviders.first { $0.blockId == "vis" }
        let preProvider = createdProviders.first { $0.blockId == "pre" }

        // Both created and prepared
        XCTAssertNotNil(visProvider)
        XCTAssertNotNil(preProvider)
        XCTAssertEqual(visProvider?.prepareCallCount, 1)
        XCTAssertEqual(preProvider?.prepareCallCount, 1)

        // Visible called texture(), prefetch did NOT
        XCTAssertEqual(visProvider?.textureCallCount, 1, "Visible provider should have texture() called")
        XCTAssertEqual(preProvider?.textureCallCount, 0, "Prefetch provider must NOT have texture() called")

        // Visible DID inject texture
        XCTAssertEqual(textureProvider.setTextureCallsByAssetId["vis_asset"], 1,
            "Visible slot must inject texture")
        XCTAssertNotNil(textureProvider.textures["vis_asset"],
            "Visible texture must be present in provider")

        // Prefetch did NOT inject texture
        XCTAssertNil(textureProvider.setTextureCallsByAssetId["pre_asset"],
            "Prefetch slot must not inject texture into texture provider")
    }

    func testFarSlotsFinishAndRemoveInjectedTextures() {
        let coordinator = makeCoordinator()
        coordinator.configureSlots([
            (blockId: "block1", config: dummyConfig(), bindingAssetIds: ["asset1", "asset2"], startFrame: 0, endFrame: 30)
        ])

        // Make visible → creates provider
        coordinator.updateTextures(visibilityFrameIndex: 5, mediaFrameIndex: 5)
        XCTAssertEqual(createdProviders.count, 1)

        let provider = createdProviders[0]

        // Move far away → teardown
        coordinator.updateTextures(visibilityFrameIndex: 100, mediaFrameIndex: 100)

        XCTAssertEqual(provider.finishCallCount, 1, "Far slot provider should be finished")
        XCTAssertEqual(textureProvider.removeTextureCallsByAssetId["asset1"], 1)
        XCTAssertEqual(textureProvider.removeTextureCallsByAssetId["asset2"], 1)
    }

    func testReleaseProvidersKeepsMetadataButDropsProviders() {
        let coordinator = makeCoordinator()
        coordinator.configureSlots([
            (blockId: "block1", config: dummyConfig(), bindingAssetIds: ["a1"], startFrame: 0, endFrame: 60),
            (blockId: "block2", config: dummyConfig(), bindingAssetIds: ["a2"], startFrame: 0, endFrame: 60)
        ])

        // Make visible so providers are created
        coordinator.updateTextures(visibilityFrameIndex: 10, mediaFrameIndex: 10)
        XCTAssertEqual(createdProviders.count, 2)

        // Release providers
        coordinator.releaseProviders()

        for provider in createdProviders {
            XCTAssertEqual(provider.finishCallCount, 1, "releaseProviders should finish each provider")
        }

        #if DEBUG
        let snapshot = coordinator.debugSlotSnapshot()
        XCTAssertEqual(snapshot.count, 2, "Slots metadata should still exist")
        for s in snapshot {
            XCTAssertFalse(s.hasProvider, "Provider should be nil after release")
        }
        #endif
    }

    func testFinishClearsAllSlots() {
        let coordinator = makeCoordinator()
        coordinator.configureSlots([
            (blockId: "block1", config: dummyConfig(), bindingAssetIds: ["a1"], startFrame: 0, endFrame: 60)
        ])

        // Make visible
        coordinator.updateTextures(visibilityFrameIndex: 5, mediaFrameIndex: 5)
        XCTAssertEqual(createdProviders.count, 1)

        coordinator.finish()

        XCTAssertEqual(createdProviders[0].finishCallCount, 1, "finish() should finish all providers")

        #if DEBUG
        let snapshot = coordinator.debugSlotSnapshot()
        XCTAssertEqual(snapshot.count, 0, "finish() should clear all slots")
        #endif
    }

    func testFailedPrepareTearsDownProviderAndClearsSlot() {
        let coordinator = ExportVideoSlotsCoordinator(
            device: device,
            textureCache: textureCache,
            commandQueue: commandQueue,
            sceneFPS: 30,
            exportTextureProvider: textureProvider,
            videoPrefetchFrames: 15,
            maxActiveProviders: 4,
            providerFactory: { [weak self] blockId, config in
                let p = MockExportVideoFrameProvider(blockId: blockId, config: config)
                p.shouldThrowOnPrepare = true
                self?.createdProviders.append(p)
                return p
            }
        )
        coordinator.configureSlots([
            (blockId: "fail_block", config: dummyConfig(), bindingAssetIds: ["fail_asset"], startFrame: 0, endFrame: 60)
        ])

        // Trigger visible → provider created → prepare throws → teardown
        coordinator.updateTextures(visibilityFrameIndex: 5, mediaFrameIndex: 5)

        let provider = createdProviders.first { $0.blockId == "fail_block" }
        XCTAssertNotNil(provider)
        XCTAssertEqual(provider?.prepareCallCount, 1, "Prepare should have been attempted")
        XCTAssertEqual(provider?.finishCallCount, 1, "Failed provider must be finished (teardown)")

        // Textures and presentation info cleaned
        XCTAssertEqual(textureProvider.removeTextureCallsByAssetId["fail_asset"], 1,
            "Teardown must remove textures for binding assets")
        XCTAssertEqual(textureProvider.removePresentationInfoCallsByAssetId["fail_asset"], 1,
            "Teardown must remove presentation info for binding assets")

        // Provider error propagated
        XCTAssertNotNil(coordinator.providerError, "Provider error should be propagated")

        #if DEBUG
        let snapshot = coordinator.debugSlotSnapshot()
        let slot = snapshot.first { $0.blockId == "fail_block" }
        XCTAssertNotNil(slot, "Slot metadata should still exist")
        XCTAssertFalse(slot!.hasProvider, "Provider should be nil after failed prepare teardown")
        #endif
    }
}
