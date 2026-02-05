import XCTest
@testable import TVECore

/// PR-28: Unit tests for SharedAssetsIndex, LocalAssetsIndex, CompositeAssetResolver,
/// and AssetResolutionError.
final class SharedAssetsResolverTests: XCTestCase {

    // MARK: - Temp dir helper

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedAssetsResolverTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }

    /// Writes a dummy 1-byte file at the given relative path under tempDir.
    private func writeDummy(_ relativePath: String) {
        let url = tempDir.appendingPathComponent(relativePath)
        let parentDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data([0xFF]))
    }

    // MARK: - SharedAssetsIndex

    func testSharedIndex_nilRoot_isEmpty() throws {
        let index = try SharedAssetsIndex(rootURL: nil)
        XCTAssertEqual(index.count, 0)
        XCTAssertNil(index.url(forKey: "anything"))
    }

    func testSharedIndex_emptyDir_isEmpty() throws {
        let index = try SharedAssetsIndex(rootURL: tempDir)
        XCTAssertEqual(index.count, 0)
    }

    func testSharedIndex_scansPngJpgWebp() throws {
        writeDummy("frame_gold.png")
        writeDummy("overlay.jpg")
        writeDummy("sticker.webp")

        let index = try SharedAssetsIndex(rootURL: tempDir)
        XCTAssertEqual(index.count, 3)
        XCTAssertNotNil(index.url(forKey: "frame_gold"))
        XCTAssertNotNil(index.url(forKey: "overlay"))
        XCTAssertNotNil(index.url(forKey: "sticker"))
    }

    func testSharedIndex_skipsNonImageFiles() throws {
        writeDummy("readme.txt")
        writeDummy("data.json")
        writeDummy("image.png")

        let index = try SharedAssetsIndex(rootURL: tempDir)
        XCTAssertEqual(index.count, 1)
        XCTAssertNotNil(index.url(forKey: "image"))
        XCTAssertNil(index.url(forKey: "readme"))
    }

    func testSharedIndex_scansSubdirectories() throws {
        writeDummy("category_a/frame1.png")
        writeDummy("category_b/frame2.png")

        let index = try SharedAssetsIndex(rootURL: tempDir)
        XCTAssertEqual(index.count, 2)
        XCTAssertNotNil(index.url(forKey: "frame1"))
        XCTAssertNotNil(index.url(forKey: "frame2"))
    }

    func testSharedIndex_duplicateBasename_throws() throws {
        writeDummy("folder_a/dupe.png")
        writeDummy("folder_b/dupe.jpg")

        XCTAssertThrowsError(try SharedAssetsIndex(rootURL: tempDir)) { error in
            guard case AssetResolutionError.duplicateBasenameShared(let key, _, _) = error else {
                XCTFail("Expected duplicateBasenameShared, got: \(error)")
                return
            }
            XCTAssertEqual(key, "dupe")
        }
    }

    func testSharedIndex_caseSensitiveKeys() throws {
        writeDummy("Image.png")

        let index = try SharedAssetsIndex(rootURL: tempDir)
        XCTAssertNotNil(index.url(forKey: "Image"))
        // Note: on macOS (case-insensitive FS) "image" might collide with "Image",
        // but the key stored in the dictionary uses the actual filename casing.
    }

    func testSharedIndex_emptyStatic() {
        XCTAssertEqual(SharedAssetsIndex.empty.count, 0)
    }

    func testSharedIndex_keys_returnsAllBasenames() throws {
        writeDummy("a.png")
        writeDummy("b.jpg")

        let index = try SharedAssetsIndex(rootURL: tempDir)
        XCTAssertEqual(index.keys, ["a", "b"])
    }

    // MARK: - LocalAssetsIndex

    func testLocalIndex_nilRoot_isEmpty() throws {
        let index = try LocalAssetsIndex(imagesRootURL: nil)
        XCTAssertEqual(index.count, 0)
    }

    func testLocalIndex_scansImagesDir() throws {
        writeDummy("img_1.png")
        writeDummy("img_2.jpg")

        let index = try LocalAssetsIndex(imagesRootURL: tempDir)
        XCTAssertEqual(index.count, 2)
        XCTAssertNotNil(index.url(forKey: "img_1"))
        XCTAssertNotNil(index.url(forKey: "img_2"))
    }

    func testLocalIndex_duplicateBasename_throws() throws {
        writeDummy("sub/photo.png")
        writeDummy("other/photo.webp")

        XCTAssertThrowsError(try LocalAssetsIndex(imagesRootURL: tempDir)) { error in
            guard case AssetResolutionError.duplicateBasenameLocal(let key, _, _) = error else {
                XCTFail("Expected duplicateBasenameLocal, got: \(error)")
                return
            }
            XCTAssertEqual(key, "photo")
        }
    }

    func testLocalIndex_emptyStatic() {
        XCTAssertEqual(LocalAssetsIndex.empty.count, 0)
    }

    // MARK: - CompositeAssetResolver

    func testResolver_localWins() throws {
        // Local has "frame"
        writeDummy("local/frame.png")
        let localIndex = try LocalAssetsIndex(imagesRootURL: tempDir.appendingPathComponent("local"))

        // Shared also has "frame"
        let sharedDir = tempDir.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: sharedDir.appendingPathComponent("frame.png").path,
            contents: Data([0x00])
        )
        let sharedIndex = try SharedAssetsIndex(rootURL: sharedDir)

        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)

        let url = try resolver.resolveURL(forKey: "frame")
        XCTAssertTrue(url.path.contains("local"), "Local should win over shared")
        XCTAssertEqual(resolver.resolvedStage(forKey: "frame"), .local)
    }

    func testResolver_fallsBackToShared() throws {
        let localIndex = LocalAssetsIndex.empty

        writeDummy("shared/overlay.png")
        let sharedIndex = try SharedAssetsIndex(rootURL: tempDir.appendingPathComponent("shared"))

        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)

        let url = try resolver.resolveURL(forKey: "overlay")
        XCTAssertTrue(url.path.contains("shared"))
        XCTAssertEqual(resolver.resolvedStage(forKey: "overlay"), .shared)
    }

    func testResolver_throwsWhenNotFound() throws {
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)

        XCTAssertThrowsError(try resolver.resolveURL(forKey: "missing")) { error in
            guard case AssetResolutionError.assetNotFound(let key, let stage) = error else {
                XCTFail("Expected assetNotFound, got: \(error)")
                return
            }
            XCTAssertEqual(key, "missing")
            XCTAssertEqual(stage, .shared)
        }
    }

    func testResolver_canResolve() throws {
        writeDummy("local/exists.png")
        let localIndex = try LocalAssetsIndex(imagesRootURL: tempDir.appendingPathComponent("local"))
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: .empty)

        XCTAssertTrue(resolver.canResolve(key: "exists"))
        XCTAssertFalse(resolver.canResolve(key: "nonexistent"))
    }

    func testResolver_resolvedStage_nilWhenNotFound() throws {
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        XCTAssertNil(resolver.resolvedStage(forKey: "ghost"))
    }

    // MARK: - AssetResolutionError descriptions

    func testError_descriptions() {
        let e1 = AssetResolutionError.assetNotFound(key: "bg", stage: .shared)
        XCTAssertNotNil(e1.errorDescription)
        XCTAssertTrue(e1.errorDescription!.contains("bg"))

        let dummy = URL(fileURLWithPath: "/a.png")
        let e2 = AssetResolutionError.duplicateBasenameLocal(key: "x", url1: dummy, url2: dummy)
        XCTAssertNotNil(e2.errorDescription)
        XCTAssertTrue(e2.errorDescription!.contains("x"))

        let e3 = AssetResolutionError.duplicateBasenameShared(key: "y", url1: dummy, url2: dummy)
        XCTAssertNotNil(e3.errorDescription)
        XCTAssertTrue(e3.errorDescription!.contains("y"))
    }

    // MARK: - basenameById in AssetIndexIR

    func testAssetIndexIR_basenameById() {
        let index = AssetIndexIR(
            byId: ["anim.json|image_0": "images/photo.png"],
            sizeById: [:],
            basenameById: ["anim.json|image_0": "photo"]
        )
        XCTAssertEqual(index.basenameById["anim.json|image_0"], "photo")
    }

    func testAssetIndexIR_basenameById_default_isEmpty() {
        let index = AssetIndexIR()
        XCTAssertTrue(index.basenameById.isEmpty)
    }
}
