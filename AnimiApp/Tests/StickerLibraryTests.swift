import XCTest
@testable import AnimiApp

/// Tests for StickerLibrary and StickerRepository (PR10).
final class StickerLibraryTests: XCTestCase {

    func testStickerLibrary_freshInstanceIsEmpty() {
        let library = StickerLibrary(bundle: .main)
        library.reset()
        XCTAssertEqual(library.count, 0)
        XCTAssertTrue(library.allDescriptors.isEmpty)
    }

    func testStickerLibrary_registerDescriptor() {
        let library = StickerLibrary(bundle: .main)
        library.reset()

        let desc = StickerDescriptor(id: "test_star", displayName: "Star", filename: "sticker_star.png")
        library.register(desc)

        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library.descriptor(for: "test_star")?.displayName, "Star")
        XCTAssertNil(library.descriptor(for: "nonexistent"))
    }

    func testStickerRepository_delegatesToLibrary() {
        let library = StickerLibrary(bundle: .main)
        library.reset()

        let desc = StickerDescriptor(id: "heart", displayName: "Heart", filename: "sticker_heart.png")
        library.register(desc)

        let repo = StickerRepository(library: library)
        XCTAssertEqual(repo.count, 1)
        XCTAssertEqual(repo.descriptor(for: "heart")?.displayName, "Heart")
        XCTAssertEqual(repo.allDescriptors.count, 1)
    }

    func testStickerDescriptor_codableRoundTrip() throws {
        let original = StickerDescriptor(id: "fire", displayName: "Fire", filename: "sticker_fire.png")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StickerDescriptor.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.displayName, original.displayName)
        XCTAssertEqual(decoded.filename, original.filename)
    }

    func testNullStickerProvider_returnsEmpty() {
        let provider = NullStickerProvider()
        XCTAssertEqual(provider.count, 0)
        XCTAssertTrue(provider.allDescriptors.isEmpty)
        XCTAssertNil(provider.descriptor(for: "anything"))
        XCTAssertNil(provider.resourceURL(for: "anything"))
    }

    // MARK: - Fail-Fast Validation

    func testLoadFromBundle_missingFile_throwsStickerFileNotFound() throws {
        // Create a temp bundle with an index referencing a non-existent PNG
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stickersDir = tempDir.appendingPathComponent("Stickers")
        try FileManager.default.createDirectory(at: stickersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write index referencing a file that doesn't exist
        let indexJSON = """
        [{"id":"ghost","displayName":"Ghost","filename":"sticker_ghost.png"}]
        """
        try indexJSON.data(using: .utf8)!.write(to: stickersDir.appendingPathComponent("stickers_index.json"))

        let bundle = Bundle(url: tempDir)!
        let library = StickerLibrary(bundle: bundle)

        do {
            try library.loadFromBundle()
            XCTFail("Expected stickerFileNotFound error")
        } catch let error as StickerLibraryError {
            if case .stickerFileNotFound(let stickerId, let filename) = error {
                XCTAssertEqual(stickerId, "ghost")
                XCTAssertEqual(filename, "sticker_ghost.png")
            } else {
                XCTFail("Expected .stickerFileNotFound, got: \(error)")
            }
        }

        // Library should NOT be loaded after failure
        XCTAssertEqual(library.count, 0)
    }
}
