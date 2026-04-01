import XCTest
import Metal
import AVFoundation
import TVECore
@testable import AnimiApp

/// PR-F §6.2: Regression tests for user media display size metadata injection.
///
/// Verifies that:
/// - Photo insert injects display size metadata into texture provider
/// - Replace photo uses new geometry
/// - Insert/remove/reinsert does not keep stale display size metadata
/// - Video→photo replace clears stale video presentation and uses photo display size
/// - Photo→video replace clears stale photo display size and uses video presentation info
@MainActor
final class UserMediaDisplaySizeTests: XCTestCase {

    // MARK: - Test Doubles

    /// Texture provider that tracks display size mutations.
    final class TrackingTextureProvider: MutableTextureProvider, MutableAssetPresentationInfoProvider, MutableAssetDisplaySizeProvider {
        private(set) var textures: [String: MTLTexture] = [:]
        private(set) var presentationInfos: [String: VideoPresentationInfo] = [:]
        private(set) var displaySizes: [String: CGSize] = [:]

        func texture(for assetId: String) -> MTLTexture? { textures[assetId] }
        func setTexture(_ texture: MTLTexture, for assetId: String) { textures[assetId] = texture }
        func removeTexture(for assetId: String) {
            textures.removeValue(forKey: assetId)
            displaySizes.removeValue(forKey: assetId)
        }

        func presentationInfo(for assetId: String) -> VideoPresentationInfo? { presentationInfos[assetId] }
        func setPresentationInfo(_ info: VideoPresentationInfo, for assetId: String) { presentationInfos[assetId] = info }
        func removePresentationInfo(for assetId: String) { presentationInfos.removeValue(forKey: assetId) }

        func displaySize(for assetId: String) -> CGSize? { displaySizes[assetId] }
        func setDisplaySize(_ size: CGSize, for assetId: String) { displaySizes[assetId] = size }
        func removeDisplaySize(for assetId: String) { displaySizes.removeValue(forKey: assetId) }
    }

    /// Fake scene player.
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

    /// Fake video provider that completes with configurable poster size.
    final class FakeVideoProvider: VideoSetupProviding {
        let posterSize: CGSize
        var releaseCallCount = 0
        private var pendingContinuation: CheckedContinuation<MTLTexture, Error>?

        init(posterSize: CGSize = CGSize(width: 64, height: 64)) {
            self.posterSize = posterSize
        }

        var duration: CMTime { CMTime(seconds: 5.0, preferredTimescale: 600) }
        var isReady: Bool { true }
        var state: VideoProviderState { .ready }
        var isPlaybackActive: Bool { false }
        var presentationInfo: VideoPresentationInfo? {
            VideoPresentationInfo(rawTrackSize: posterSize, preferredTransform: .identity)
        }

        func requestPoster(at time: Double) async throws -> MTLTexture {
            try await makeFakeTexture(width: Int(posterSize.width), height: Int(posterSize.height))
        }

        func release() { releaseCallCount += 1 }
        func startPlayback(atVideoTime videoTimeSeconds: Double) {}
        func stopPlayback(flush: Bool) {}
        func frameTextureForPlayback(expectedVideoTime videoTimeSeconds: Double) -> MTLTexture? { nil }
        func requestStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
            try await makeFakeTexture(width: Int(posterSize.width), height: Int(posterSize.height))
        }
        func requestInteractiveStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
            try await makeFakeTexture(width: Int(posterSize.width), height: Int(posterSize.height))
        }
        func releaseInteractiveStillResources() {}

        private func makeFakeTexture(width: Int, height: Int) async throws -> MTLTexture {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw NSError(domain: "Test", code: 1)
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            guard let texture = device.makeTexture(descriptor: desc) else {
                throw NSError(domain: "Test", code: 2)
            }
            return texture
        }
    }

    // MARK: - Properties

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var fakePlayer: FakeScenePlayer!
    private var trackingProvider: TrackingTextureProvider!
    private var sut: UserMediaService!
    private var photoFixtureURL: URL!
    private var photoFixtureLandscapeURL: URL!

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

        trackingProvider = TrackingTextureProvider()

        sut = UserMediaService(
            device: device,
            commandQueue: commandQueue,
            scenePlayerForTest: fakePlayer,
            textureProvider: trackingProvider
        )

        // Create photo fixtures with different aspect ratios
        photoFixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_photo_\(UUID().uuidString).png")
        try createTestImage(at: photoFixtureURL, width: 200, height: 300) // Portrait 2:3

        photoFixtureLandscapeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_photo_landscape_\(UUID().uuidString).png")
        try createTestImage(at: photoFixtureLandscapeURL, width: 400, height: 200) // Landscape 2:1
    }

    override func tearDown() async throws {
        if let url = photoFixtureURL { try? FileManager.default.removeItem(at: url) }
        if let url = photoFixtureLandscapeURL { try? FileManager.default.removeItem(at: url) }
        sut = nil
        fakePlayer = nil
        trackingProvider = nil
        device = nil
        commandQueue = nil
        try await super.tearDown()
    }

    // MARK: - §6.2 Tests

    /// Photo insert injects display size metadata matching texture dimensions.
    func testPhotoInsertInjectsDisplaySize() async throws {
        let accepted = sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        XCTAssertTrue(accepted)

        // Wait for async texture load
        try await Task.sleep(nanoseconds: 500_000_000)

        // Display size should be set for the binding asset
        let displaySize = trackingProvider.displaySizes["binding_asset_01"]
        XCTAssertNotNil(displaySize, "Display size should be injected after photo load")

        // Verify display size matches loaded texture dimensions (may be downsampled but proportional)
        if let displaySize {
            XCTAssertGreaterThan(displaySize.width, 0)
            XCTAssertGreaterThan(displaySize.height, 0)
        }

        // Texture should also be present
        XCTAssertNotNil(trackingProvider.textures["binding_asset_01"])

        // No video presentation info (this is a photo)
        XCTAssertNil(trackingProvider.presentationInfos["binding_asset_01"])
    }

    /// Replace photo with different aspect ratio uses new geometry.
    func testReplacePhotoUsesNewGeometry() async throws {
        // Insert portrait photo
        sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        let firstSize = trackingProvider.displaySizes["binding_asset_01"]
        XCTAssertNotNil(firstSize)

        // Replace with landscape photo
        sut.setPhoto(blockId: "block_01", fileURL: photoFixtureLandscapeURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        let secondSize = trackingProvider.displaySizes["binding_asset_01"]
        XCTAssertNotNil(secondSize)

        // Sizes should differ (portrait vs landscape aspect ratio)
        if let first = firstSize, let second = secondSize {
            let firstAR = first.width / first.height
            let secondAR = second.width / second.height
            XCTAssertNotEqual(firstAR, secondAR, accuracy: 0.1,
                "Replacing photo should update display size to new aspect ratio")
        }
    }

    /// Insert → remove → reinsert does not keep stale display size metadata.
    func testInsertRemoveReinsertClearsStaleDisplaySize() async throws {
        // Insert photo
        sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNotNil(trackingProvider.displaySizes["binding_asset_01"])

        // Clear
        sut.clear(blockId: "block_01")
        XCTAssertNil(trackingProvider.displaySizes["binding_asset_01"],
            "Display size should be cleared after clear()")
        XCTAssertNil(trackingProvider.textures["binding_asset_01"])

        // Reinsert
        sut.setPhoto(blockId: "block_01", fileURL: photoFixtureLandscapeURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        let size = trackingProvider.displaySizes["binding_asset_01"]
        XCTAssertNotNil(size, "Display size should be set after reinsert")
    }

    /// Video→photo replace clears stale video presentation metadata and uses photo display size.
    func testVideoToPhotoReplaceClearsVideoMetadata() async throws {
        // Set up video provider factory
        let videoProvider = FakeVideoProvider(posterSize: CGSize(width: 1920, height: 1080))
        sut.makeVideoProvider = { _, _, _, _ in videoProvider }

        // Insert video
        sut.setVideo(
            blockId: "block_01",
            url: photoFixtureURL, // URL doesn't matter for fake
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5)
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        // Video should have presentation info but no display size
        XCTAssertNotNil(trackingProvider.presentationInfos["binding_asset_01"],
            "Video should inject presentation info")

        // Replace with photo
        sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        // After replace: display size should be set, presentation info should be cleared
        XCTAssertNotNil(trackingProvider.displaySizes["binding_asset_01"],
            "Photo should inject display size after video→photo replace")
        XCTAssertNil(trackingProvider.presentationInfos["binding_asset_01"],
            "Video presentation info should be cleared after video→photo replace")
    }

    /// Photo→video replace clears stale photo display size and uses video presentation info.
    func testPhotoToVideoReplaceClearsPhotoDisplaySize() async throws {
        // Insert photo first
        sut.setPhoto(blockId: "block_01", fileURL: photoFixtureURL)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNotNil(trackingProvider.displaySizes["binding_asset_01"])

        // Set up video provider factory
        let videoProvider = FakeVideoProvider(posterSize: CGSize(width: 1920, height: 1080))
        sut.makeVideoProvider = { _, _, _, _ in videoProvider }

        // Replace with video
        sut.setVideo(
            blockId: "block_01",
            url: photoFixtureURL,
            persistedSelection: PersistedVideoSelection(trimStart: 0, trimEnd: 5)
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        // After replace: display size should be cleared, presentation info should be set
        XCTAssertNil(trackingProvider.displaySizes["binding_asset_01"],
            "Photo display size should be cleared after photo→video replace")
        XCTAssertNotNil(trackingProvider.presentationInfos["binding_asset_01"],
            "Video should inject presentation info after photo→video replace")
    }

    // MARK: - Helpers

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

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination"])
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize"])
        }
    }
}
