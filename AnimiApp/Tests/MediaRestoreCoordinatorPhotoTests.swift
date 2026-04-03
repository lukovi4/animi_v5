import XCTest
import Metal
import ImageIO
import CoreGraphics
import TVECore
@testable import AnimiApp

/// Phase 2: Tests for MediaRestoreCoordinator photo restore path.
/// Verifies file-based photo restore via setPhoto(blockId:fileURL:).
@MainActor
final class MediaRestoreCoordinatorPhotoTests: XCTestCase {

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

        func blockTiming(for blockId: String) -> BlockTiming? { nil }
        func blockPriorityInfo(blockId: String, at sceneFrameIndex: Int) -> BlockPriorityInfo? { nil }
    }

    final class FakeTextureProvider: MutableTextureProvider {
        private(set) var textures: [String: MTLTexture] = [:]
        func texture(for assetId: String) -> MTLTexture? { textures[assetId] }
        func setTexture(_ texture: MTLTexture, for assetId: String) { textures[assetId] = texture }
        func removeTexture(for assetId: String) { textures.removeValue(forKey: assetId) }
    }

    // MARK: - Properties

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var fakePlayer: FakeScenePlayer!
    private var fakeTextureProvider: FakeTextureProvider!
    private var sut: UserMediaService!
    private var testPhotoURL: URL!
    private var testMediaRelativePath: String!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = metalDevice
        commandQueue = device.makeCommandQueue()!

        fakePlayer = FakeScenePlayer()
        fakePlayer.addBlock(blockId: "block_p1", assetId: "binding_p1")

        fakeTextureProvider = FakeTextureProvider()

        sut = UserMediaService(
            device: device,
            commandQueue: commandQueue,
            scenePlayerForTest: fakePlayer,
            textureProvider: fakeTextureProvider
        )

        // Create a test photo file that ProjectStore can resolve
        let projectsDir = try ProjectStore.shared.projectsDirectoryURL()
        testMediaRelativePath = "Media/TestRestore/test_photo_\(UUID().uuidString).jpg"
        testPhotoURL = projectsDir.appendingPathComponent(testMediaRelativePath)
        try FileManager.default.createDirectory(
            at: testPhotoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write a valid JPEG via ImageIO
        try createTestJPEG(at: testPhotoURL, width: 64, height: 64)
    }

    override func tearDown() async throws {
        if let url = testPhotoURL {
            try? FileManager.default.removeItem(at: url)
        }
        sut = nil
        fakePlayer = nil
        fakeTextureProvider = nil
        device = nil
        commandQueue = nil
        testPhotoURL = nil
        testMediaRelativePath = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makePhotoMediaRef() -> MediaRef {
        MediaRef(kind: .file, id: testMediaRelativePath, mediaKind: .photo)
    }

    private func createTestJPEG(at url: URL, width: Int, height: Int) throws {
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
            throw NSError(domain: "Test", code: -1)
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "Test", code: -1)
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "Test", code: -1)
        }

        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Test", code: -1)
        }
    }

    // MARK: - Tests

    /// Valid persisted JPEG → restore → accepted → eventually ready.
    func test_restorePhoto_validFile_eventuallyReady() async throws {
        let slots: [String: SceneMediaSlot] = [
            "block_p1": .photo(mediaRef: makePhotoMediaRef(), placement: .default(fitMode: .cover))
        ]

        let restored = MediaRestoreCoordinator.restore(slots: slots, to: sut)
        XCTAssertEqual(restored, 1, "Should accept photo restore")

        // Wait for async texture load
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(sut.isSceneMediaReady, "Should be ready after photo restore")
        XCTAssertFalse(sut.hasFailedMedia)
        XCTAssertNotNil(fakeTextureProvider.textures["binding_p1"], "Texture should be injected")
    }

    /// Missing file → markRestoreFailed.
    func test_restorePhoto_missingFile_fails() async throws {
        // Create a media ref pointing to a non-existent file
        let missingPath = "Media/TestRestore/nonexistent_\(UUID().uuidString).jpg"
        let missingRef = MediaRef(kind: .file, id: missingPath, mediaKind: .photo)

        let slots: [String: SceneMediaSlot] = [
            "block_p1": .photo(mediaRef: missingRef, placement: .default(fitMode: .cover))
        ]

        let restored = MediaRestoreCoordinator.restore(slots: slots, to: sut)
        XCTAssertEqual(restored, 0, "Should not accept restore of missing file")
        XCTAssertTrue(sut.hasFailedMedia, "Should have failed media for missing file")
    }

    /// Unreadable file (corrupt data) → restore accepts but async texture load fails.
    func test_restorePhoto_unreadableFile_eventuallyFails() async throws {
        // Overwrite the test photo with garbage
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: testPhotoURL)

        let slots: [String: SceneMediaSlot] = [
            "block_p1": .photo(mediaRef: makePhotoMediaRef(), placement: .default(fitMode: .cover))
        ]

        let restored = MediaRestoreCoordinator.restore(slots: slots, to: sut)
        // setPhoto accepts (file exists), but async load will fail
        XCTAssertEqual(restored, 1, "Should accept (file exists)")

        // Wait for async failure
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(sut.hasFailedMedia, "Should have failed media after corrupt file load")
        XCTAssertFalse(sut.isSceneMediaReady)
    }
}
