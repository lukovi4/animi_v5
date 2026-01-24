import XCTest
@testable import TVECore

final class AnimLoaderTests: XCTestCase {
    private var loader: AnimLoader!
    private var packageLoader: ScenePackageLoader!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        loader = AnimLoader()
        packageLoader = ScenePackageLoader()
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        loader = nil
        packageLoader = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func createTempPackage(
        sceneJSON: String,
        animFiles: [String: String],
        images: [String] = []
    ) throws -> ScenePackage {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Write scene.json
        let sceneURL = tempDir.appendingPathComponent("scene.json")
        try sceneJSON.write(to: sceneURL, atomically: true, encoding: .utf8)

        // Write anim files
        for (name, content) in animFiles {
            let url = tempDir.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        // Create images directory and files
        if !images.isEmpty {
            let imagesDir = tempDir.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            for imageName in images {
                let imageURL = imagesDir.appendingPathComponent(imageName)
                try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
            }
        }

        return try packageLoader.load(from: tempDir)
    }

    private func minimalSceneJSON(animRef: String = "anim-1.json") -> String {
        """
        {
          "schemaVersion": "0.1",
          "canvas": { "width": 1080, "height": 1920, "fps": 30, "durationFrames": 300 },
          "mediaBlocks": [{
            "blockId": "block_01",
            "zIndex": 0,
            "rect": { "x": 0, "y": 0, "width": 540, "height": 960 },
            "containerClip": "slotRect",
            "input": {
              "rect": { "x": 0, "y": 0, "width": 540, "height": 960 },
              "bindingKey": "media",
              "allowedMedia": ["photo"]
            },
            "variants": [{
              "variantId": "v1",
              "animRef": "\(animRef)"
            }]
          }]
        }
        """
    }

    private func minimalAnimJSON(
        width: Int = 1080,
        height: Int = 1920,
        frameRate: Int = 30,
        inPoint: Int = 0,
        outPoint: Int = 300,
        assetId: String = "image_0",
        imageFile: String = "img_1.png"
    ) -> String {
        """
        {
          "v": "5.12.1",
          "fr": \(frameRate),
          "ip": \(inPoint),
          "op": \(outPoint),
          "w": \(width),
          "h": \(height),
          "nm": "Test Anim",
          "ddd": 0,
          "assets": [
            { "id": "\(assetId)", "w": 540, "h": 960, "u": "images/", "p": "\(imageFile)", "e": 0 },
            { "id": "comp_0", "nm": "precomp", "fr": 30,
              "layers": [{ "ty": 2, "nm": "media", "refId": "\(assetId)", "ind": 1 }]
            }
          ],
          "layers": [
            { "ty": 0, "nm": "precomp", "refId": "comp_0", "ind": 1, "ip": 0, "op": 300 }
          ]
        }
        """
    }

    // MARK: - Loader Tests

    func testLoadAnimations_singleAnim_success() throws {
        let sceneJSON = minimalSceneJSON(animRef: "anim-1.json")
        let animJSON = minimalAnimJSON()
        let package = try createTempPackage(
            sceneJSON: sceneJSON,
            animFiles: ["anim-1.json": animJSON],
            images: ["img_1.png"]
        )

        let loaded = try loader.loadAnimations(from: package)

        XCTAssertEqual(loaded.lottieByAnimRef.count, 1)
        XCTAssertNotNil(loaded.lottieByAnimRef["anim-1.json"])

        let lottie = loaded.lottieByAnimRef["anim-1.json"]!
        XCTAssertEqual(lottie.width, 1080)
        XCTAssertEqual(lottie.height, 1920)
        XCTAssertEqual(lottie.frameRate, 30)
    }

    func testLoadAnimations_multipleAnims_success() throws {
        let sceneJSON = """
        {
          "schemaVersion": "0.1",
          "canvas": { "width": 1080, "height": 1920, "fps": 30, "durationFrames": 300 },
          "mediaBlocks": [
            {
              "blockId": "b1", "zIndex": 0,
              "rect": { "x": 0, "y": 0, "width": 540, "height": 960 },
              "containerClip": "slotRect",
              "input": { "rect": { "x": 0, "y": 0, "width": 540, "height": 960 },
                "bindingKey": "media", "allowedMedia": ["photo"] },
              "variants": [{ "variantId": "v1", "animRef": "anim-1.json" }]
            },
            {
              "blockId": "b2", "zIndex": 1,
              "rect": { "x": 540, "y": 0, "width": 540, "height": 960 },
              "containerClip": "slotRect",
              "input": { "rect": { "x": 0, "y": 0, "width": 540, "height": 960 },
                "bindingKey": "media", "allowedMedia": ["photo"] },
              "variants": [{ "variantId": "v1", "animRef": "anim-2.json" }]
            }
          ]
        }
        """

        let anim1 = minimalAnimJSON(imageFile: "img_1.png")
        let anim2 = minimalAnimJSON(imageFile: "img_2.png")

        let package = try createTempPackage(
            sceneJSON: sceneJSON,
            animFiles: ["anim-1.json": anim1, "anim-2.json": anim2],
            images: ["img_1.png", "img_2.png"]
        )

        let loaded = try loader.loadAnimations(from: package)

        XCTAssertEqual(loaded.lottieByAnimRef.count, 2)
        XCTAssertNotNil(loaded.lottieByAnimRef["anim-1.json"])
        XCTAssertNotNil(loaded.lottieByAnimRef["anim-2.json"])
    }

    func testAssetIndex_buildsRelativePaths() throws {
        let sceneJSON = minimalSceneJSON()
        let animJSON = minimalAnimJSON(assetId: "image_0", imageFile: "img_1.png")
        let package = try createTempPackage(
            sceneJSON: sceneJSON,
            animFiles: ["anim-1.json": animJSON],
            images: ["img_1.png"]
        )

        let loaded = try loader.loadAnimations(from: package)
        let index = loaded.assetIndexByAnimRef["anim-1.json"]!

        XCTAssertEqual(index.byId["image_0"], "images/img_1.png")
    }

    func testAssetIndex_multipleAssets() throws {
        let sceneJSON = minimalSceneJSON()
        let animJSON = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "img_a", "u": "images/", "p": "a.png" },
            { "id": "img_b", "u": "images/", "p": "b.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "img_a" }] }
          ],
          "layers": [{ "ty": 0, "refId": "comp_0" }]
        }
        """
        let package = try createTempPackage(
            sceneJSON: sceneJSON,
            animFiles: ["anim-1.json": animJSON],
            images: ["a.png", "b.png"]
        )

        let loaded = try loader.loadAnimations(from: package)
        let index = loaded.assetIndexByAnimRef["anim-1.json"]!

        XCTAssertEqual(index.byId.count, 2)
        XCTAssertEqual(index.byId["img_a"], "images/a.png")
        XCTAssertEqual(index.byId["img_b"], "images/b.png")
    }

    func testMissingAnimFile_throws() throws {
        // Create a ScenePackage manually with a reference to a missing file
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let scene = Scene(
            schemaVersion: "0.1",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            mediaBlocks: []
        )

        // Point to a non-existent file
        let missingURL = tempDir.appendingPathComponent("missing.json")
        let package = ScenePackage(
            rootURL: tempDir,
            scene: scene,
            animFilesByRef: ["missing.json": missingURL],
            imagesRootURL: nil
        )

        XCTAssertThrowsError(try loader.loadAnimations(from: package)) { error in
            guard case AnimLoadError.animJSONReadFailed(let animRef, _) = error else {
                XCTFail("Expected animJSONReadFailed, got \(error)")
                return
            }
            XCTAssertEqual(animRef, "missing.json")
        }
    }

    func testInvalidJSON_throws() throws {
        let sceneJSON = minimalSceneJSON()
        let invalidJSON = "{ not valid json }"
        let package = try createTempPackage(
            sceneJSON: sceneJSON,
            animFiles: ["anim-1.json": invalidJSON]
        )

        XCTAssertThrowsError(try loader.loadAnimations(from: package)) { error in
            guard case AnimLoadError.animJSONDecodeFailed(let animRef, _) = error else {
                XCTFail("Expected animJSONDecodeFailed, got \(error)")
                return
            }
            XCTAssertEqual(animRef, "anim-1.json")
        }
    }

    func testLottieJSON_decodesAllFields() throws {
        let sceneJSON = minimalSceneJSON()
        let animJSON = """
        {
          "v": "5.12.1",
          "fr": 24,
          "ip": 10,
          "op": 200,
          "w": 800,
          "h": 600,
          "nm": "Test Animation",
          "ddd": 0,
          "assets": [{ "id": "comp_0", "layers": [{ "ty": 2, "nm": "media" }] }],
          "layers": [{ "ty": 0, "refId": "comp_0" }]
        }
        """
        let package = try createTempPackage(
            sceneJSON: sceneJSON,
            animFiles: ["anim-1.json": animJSON]
        )

        let loaded = try loader.loadAnimations(from: package)
        let lottie = loaded.lottieByAnimRef["anim-1.json"]!

        XCTAssertEqual(lottie.version, "5.12.1")
        XCTAssertEqual(lottie.frameRate, 24)
        XCTAssertEqual(lottie.inPoint, 10)
        XCTAssertEqual(lottie.outPoint, 200)
        XCTAssertEqual(lottie.width, 800)
        XCTAssertEqual(lottie.height, 600)
        XCTAssertEqual(lottie.name, "Test Animation")
        XCTAssertEqual(lottie.is3D, 0)
    }

    func testLottieLayer_decodesTransformAndMasks() throws {
        let sceneJSON = minimalSceneJSON()
        let animJSON = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [{ "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "img" }] }],
          "layers": [{
            "ty": 0,
            "nm": "layer1",
            "refId": "comp_0",
            "ks": {
              "o": { "a": 0, "k": 100 },
              "r": { "a": 0, "k": 0 },
              "p": { "a": 0, "k": [540, 960, 0] },
              "a": { "a": 0, "k": [270, 480, 0] },
              "s": { "a": 0, "k": [100, 100, 100] }
            },
            "hasMask": true,
            "masksProperties": [{
              "mode": "a",
              "inv": false,
              "pt": { "a": 0, "k": { "v": [[0,0], [100,0], [100,100], [0,100]], "c": true } },
              "o": { "a": 0, "k": 100 }
            }]
          }]
        }
        """
        let package = try createTempPackage(
            sceneJSON: sceneJSON,
            animFiles: ["anim-1.json": animJSON]
        )

        let loaded = try loader.loadAnimations(from: package)
        let lottie = loaded.lottieByAnimRef["anim-1.json"]!
        let layer = lottie.layers[0]

        XCTAssertEqual(layer.name, "layer1")
        XCTAssertNotNil(layer.transform)
        XCTAssertEqual(layer.transform?.opacity?.animated, 0)
        XCTAssertEqual(layer.hasMask, true)
        XCTAssertEqual(layer.masksProperties?.count, 1)
        XCTAssertEqual(layer.masksProperties?[0].mode, "a")
        XCTAssertEqual(layer.masksProperties?[0].inverted, false)
    }
}
