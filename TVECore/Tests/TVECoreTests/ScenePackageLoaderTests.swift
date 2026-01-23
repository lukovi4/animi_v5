import XCTest
@testable import TVECore

final class ScenePackageLoaderTests: XCTestCase {
    private var loader: ScenePackageLoader!
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        loader = ScenePackageLoader()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        // Clean up temp directory if created
        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        loader = nil
        super.tearDown()
    }

    // MARK: - Success Tests

    func testLoadExamplePackage_success() throws {
        // Given
        let packageURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "example_4blocks",
                withExtension: nil,
                subdirectory: "Resources"
            )
        )

        // When
        let package = try loader.load(from: packageURL)

        // Then
        XCTAssertEqual(package.scene.schemaVersion, "0.1")
        XCTAssertEqual(package.scene.canvas.width, 1080)
        XCTAssertEqual(package.scene.canvas.height, 1920)
        XCTAssertEqual(package.scene.canvas.fps, 30)
        XCTAssertEqual(package.scene.canvas.durationFrames, 300)
        XCTAssertEqual(package.scene.mediaBlocks.count, 4)
        XCTAssertEqual(package.animFilesByRef.count, 4)

        // Verify each anim file exists
        for (ref, url) in package.animFilesByRef {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Anim file should exist: \(ref)"
            )
        }

        // Verify images directory exists
        XCTAssertNotNil(package.imagesRootURL)
    }

    func testLoadExamplePackage_blocksHaveCorrectData() throws {
        // Given
        let packageURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "example_4blocks",
                withExtension: nil,
                subdirectory: "Resources"
            )
        )

        // When
        let package = try loader.load(from: packageURL)

        // Then - verify first block
        let block1 = try XCTUnwrap(package.scene.mediaBlocks.first)
        XCTAssertEqual(block1.id, "block_01")
        XCTAssertEqual(block1.zIndex, 0)
        XCTAssertEqual(block1.rect.x, 0)
        XCTAssertEqual(block1.rect.y, 0)
        XCTAssertEqual(block1.rect.width, 540)
        XCTAssertEqual(block1.rect.height, 960)
        XCTAssertEqual(block1.containerClip, .slotRect)
        XCTAssertEqual(block1.input.bindingKey, "media")
        XCTAssertEqual(block1.variants.count, 1)
        XCTAssertEqual(block1.variants.first?.animRef, "anim-1.json")
    }

    func testLoadExamplePackage_allBlocksHaveVariants() throws {
        // Given
        let packageURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "example_4blocks",
                withExtension: nil,
                subdirectory: "Resources"
            )
        )

        // When
        let package = try loader.load(from: packageURL)

        // Then
        for block in package.scene.mediaBlocks {
            XCTAssertFalse(
                block.variants.isEmpty,
                "Block \(block.id) should have variants"
            )
        }
    }

    // MARK: - Error Tests

    func testLoad_missingSceneJson_fails() throws {
        // Given - create empty directory
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )

        // When/Then
        XCTAssertThrowsError(try loader.load(from: tempDirectory)) { error in
            guard let loadError = error as? ScenePackageLoadError else {
                XCTFail("Expected ScenePackageLoadError, got \(error)")
                return
            }
            XCTAssertEqual(loadError, .sceneJSONNotFound)
        }
    }

    func testLoad_missingAnimRef_fails() throws {
        // Given - copy package and remove one anim file
        let sourceURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "example_4blocks",
                withExtension: nil,
                subdirectory: "Resources"
            )
        )

        try FileManager.default.copyItem(at: sourceURL, to: tempDirectory)

        // Remove anim-1.json
        let animFile = tempDirectory.appendingPathComponent("anim-1.json")
        try FileManager.default.removeItem(at: animFile)

        // When/Then
        XCTAssertThrowsError(try loader.load(from: tempDirectory)) { error in
            guard let loadError = error as? ScenePackageLoadError else {
                XCTFail("Expected ScenePackageLoadError, got \(error)")
                return
            }
            XCTAssertEqual(loadError, .animFileNotFound(animRef: "anim-1.json"))
        }
    }

    func testLoad_invalidJson_fails() throws {
        // Given - create directory with invalid JSON
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )

        let invalidJSON = "{ not valid json }"
        let sceneURL = tempDirectory.appendingPathComponent("scene.json")
        try invalidJSON.write(to: sceneURL, atomically: true, encoding: .utf8)

        // When/Then
        XCTAssertThrowsError(try loader.load(from: tempDirectory)) { error in
            guard let loadError = error as? ScenePackageLoadError else {
                XCTFail("Expected ScenePackageLoadError, got \(error)")
                return
            }
            if case .sceneJSONDecodeFailed = loadError {
                // Expected
            } else {
                XCTFail("Expected sceneJSONDecodeFailed, got \(loadError)")
            }
        }
    }

    func testLoad_notDirectory_fails() throws {
        // Given - point to a file, not directory
        let fileURL = tempDirectory.appendingPathComponent("test.txt")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)

        // When/Then
        XCTAssertThrowsError(try loader.load(from: fileURL)) { error in
            guard let loadError = error as? ScenePackageLoadError else {
                XCTFail("Expected ScenePackageLoadError, got \(error)")
                return
            }
            if case .invalidPackageStructure = loadError {
                // Expected
            } else {
                XCTFail("Expected invalidPackageStructure, got \(loadError)")
            }
        }
    }

    // MARK: - AnimRef Resolution Tests

    func testLoad_animRefWithoutExtension_resolves() throws {
        // Given - create package with animRef without .json extension
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )

        let sceneJSON = """
        {
            "schemaVersion": "0.1",
            "canvas": { "width": 100, "height": 100, "fps": 30, "durationFrames": 100 },
            "mediaBlocks": [{
                "blockId": "b1",
                "zIndex": 0,
                "rect": { "x": 0, "y": 0, "width": 100, "height": 100 },
                "containerClip": "slotRect",
                "input": {
                    "rect": { "x": 0, "y": 0, "width": 100, "height": 100 },
                    "bindingKey": "media",
                    "allowedMedia": ["photo"]
                },
                "variants": [{ "variantId": "v1", "animRef": "test-anim" }]
            }]
        }
        """

        try sceneJSON.write(
            to: tempDirectory.appendingPathComponent("scene.json"),
            atomically: true,
            encoding: .utf8
        )

        // Create anim file with .json extension
        try "{}".write(
            to: tempDirectory.appendingPathComponent("test-anim.json"),
            atomically: true,
            encoding: .utf8
        )

        // When
        let package = try loader.load(from: tempDirectory)

        // Then - should resolve "test-anim" to "test-anim.json"
        XCTAssertNotNil(package.animFilesByRef["test-anim"])
    }
}
