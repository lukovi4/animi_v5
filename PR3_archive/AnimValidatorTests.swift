import XCTest
@testable import TVECore

final class AnimValidatorTests: XCTestCase {
    private var validator: AnimValidator!
    private var loader: AnimLoader!
    private var packageLoader: ScenePackageLoader!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        validator = AnimValidator()
        loader = AnimLoader()
        packageLoader = ScenePackageLoader()
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        validator = nil
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

        let sceneURL = tempDir.appendingPathComponent("scene.json")
        try sceneJSON.write(to: sceneURL, atomically: true, encoding: .utf8)

        for (name, content) in animFiles {
            let url = tempDir.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

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

    private func sceneJSON(
        fps: Int = 30,
        inputWidth: Double = 540,
        inputHeight: Double = 960,
        bindingKey: String = "media",
        animRef: String = "anim-1.json"
    ) -> String {
        """
        {
          "schemaVersion": "0.1",
          "canvas": { "width": 1080, "height": 1920, "fps": \(fps), "durationFrames": 300 },
          "mediaBlocks": [{
            "blockId": "block_01",
            "zIndex": 0,
            "rect": { "x": 0, "y": 0, "width": 540, "height": 960 },
            "containerClip": "slotRect",
            "input": {
              "rect": { "x": 0, "y": 0, "width": \(inputWidth), "height": \(inputHeight) },
              "bindingKey": "\(bindingKey)",
              "allowedMedia": ["photo"]
            },
            "variants": [{ "variantId": "v1", "animRef": "\(animRef)" }]
          }]
        }
        """
    }

    private func animJSON(
        width: Int = 1080,
        height: Int = 1920,
        frameRate: Int = 30,
        inPoint: Int = 0,
        outPoint: Int = 300,
        bindingLayerName: String = "media",
        bindingLayerType: Int = 2,
        bindingRefId: String? = "image_0",
        imageFile: String = "img_1.png",
        includeImage: Bool = true,
        extraLayers: String = "",
        extraAssets: String = "",
        masksJSON: String = "",
        shapesJSON: String = "",
        trackMatteType: Int? = nil,
        matteSource: Int? = nil
    ) -> String {
        let refIdPart = bindingRefId.map { "\"refId\": \"\($0)\"," } ?? ""
        let ttPart = trackMatteType.map { "\"tt\": \($0)," } ?? ""
        let tdPart = matteSource.map { "\"td\": \($0)," } ?? ""
        let masksPart = masksJSON.isEmpty ? "" : "\"hasMask\": true, \"masksProperties\": [\(masksJSON)],"
        let shapesPart = shapesJSON.isEmpty ? "" : "\"shapes\": [\(shapesJSON)],"

        let imageAsset = includeImage
            ? "{ \"id\": \"image_0\", \"w\": 540, \"h\": 960, \"u\": \"images/\", \"p\": \"\(imageFile)\", \"e\": 0 },"
            : ""

        return """
        {
          "v": "5.12.1",
          "fr": \(frameRate),
          "ip": \(inPoint),
          "op": \(outPoint),
          "w": \(width),
          "h": \(height),
          "nm": "Test",
          "ddd": 0,
          "assets": [
            \(imageAsset)
            { "id": "comp_0", "nm": "precomp", "fr": 30,
              "layers": [{
                "ty": \(bindingLayerType),
                "nm": "\(bindingLayerName)",
                \(refIdPart)
                "ind": 1
              }]
            }
            \(extraAssets)
          ],
          "layers": [
            {
              "ty": 0,
              "nm": "precomp_layer",
              "refId": "comp_0",
              "ind": 1,
              "ip": 0,
              "op": 300,
              \(masksPart)
              \(ttPart)
              \(tdPart)
              \(shapesPart)
              "ks": { "o": { "a": 0, "k": 100 } }
            }
            \(extraLayers)
          ]
        }
        """
    }

    private func validatePackage(
        sceneJSON: String,
        animJSON: String,
        animRef: String = "anim-1.json",
        images: [String] = ["img_1.png"]
    ) throws -> ValidationReport {
        let package = try createTempPackage(
            sceneJSON: sceneJSON,
            animFiles: [animRef: animJSON],
            images: images
        )
        let loaded = try loader.loadAnimations(from: package)
        return validator.validate(scene: package.scene, package: package, loaded: loaded)
    }

    // MARK: - Happy Path Tests

    func testValidate_validAnim_noErrors() throws {
        let scene = sceneJSON(inputWidth: 1080, inputHeight: 1920)
        let anim = animJSON()
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        XCTAssertFalse(report.hasErrors)
        XCTAssertEqual(report.errors.count, 0)
    }

    func testValidate_sizeMismatch_returnsWarning() throws {
        let scene = sceneJSON(inputWidth: 540, inputHeight: 960)
        let anim = animJSON(width: 1080, height: 1920)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let warning = report.warnings.first {
            $0.code == AnimValidationCode.warningAnimSizeMismatch
        }
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.message.contains("1080x1920") ?? false)
        XCTAssertTrue(warning?.message.contains("540x960") ?? false)
    }

    // MARK: - FPS Mismatch Tests

    func testValidate_fpsMismatch_returnsError() throws {
        let scene = sceneJSON(fps: 30)
        let anim = animJSON(frameRate: 25)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.animFPSMismatch
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.path.contains("anim(anim-1.json).fr") ?? false)
        XCTAssertTrue(error?.message.contains("fps=30") ?? false)
        XCTAssertTrue(error?.message.contains("fr=25") ?? false)
    }

    // MARK: - Root Sanity Tests

    func testValidate_invalidWidth_returnsError() throws {
        let scene = sceneJSON()
        let anim = animJSON(width: 0)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.animRootInvalid && $0.path.contains(".w")
        }
        XCTAssertNotNil(error)
    }

    func testValidate_invalidHeight_returnsError() throws {
        let scene = sceneJSON()
        let anim = animJSON(height: -100)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.animRootInvalid && $0.path.contains(".h")
        }
        XCTAssertNotNil(error)
    }

    func testValidate_invalidFrameRate_returnsError() throws {
        let scene = sceneJSON()
        let anim = animJSON(frameRate: 0)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.animRootInvalid && $0.path.contains(".fr")
        }
        XCTAssertNotNil(error)
    }

    func testValidate_invalidDuration_returnsError() throws {
        let scene = sceneJSON()
        let anim = animJSON(inPoint: 100, outPoint: 50)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.animRootInvalid && $0.path.contains(".op")
        }
        XCTAssertNotNil(error)
    }

    // MARK: - Binding Layer Tests

    func testValidate_bindingLayerNotFound_returnsError() throws {
        let scene = sceneJSON(bindingKey: "user_photo")
        let anim = animJSON(bindingLayerName: "media")
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.bindingLayerNotFound
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("user_photo") ?? false)
    }

    func testValidate_bindingLayerAmbiguous_returnsError() throws {
        let scene = sceneJSON(bindingKey: "media")
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [
              { "ty": 2, "nm": "media", "refId": "image_0" },
              { "ty": 2, "nm": "media", "refId": "image_0" }
            ]}
          ],
          "layers": [{ "ty": 0, "refId": "comp_0" }]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.bindingLayerAmbiguous
        }
        XCTAssertNotNil(error)
    }

    func testValidate_bindingLayerNotImage_returnsError() throws {
        let scene = sceneJSON()
        let anim = animJSON(bindingLayerType: 3) // null layer
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.bindingLayerNotImage
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("ty=3") ?? false)
    }

    func testValidate_bindingLayerNoAsset_returnsError() throws {
        let scene = sceneJSON()
        let anim = animJSON(bindingRefId: nil)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.bindingLayerNoAsset
        }
        XCTAssertNotNil(error)
    }

    // MARK: - Asset Missing Tests

    func testValidate_assetMissing_returnsError() throws {
        let scene = sceneJSON()
        let anim = animJSON(imageFile: "missing.png")
        let report = try validatePackage(sceneJSON: scene, animJSON: anim, images: [])

        let error = report.errors.first {
            $0.code == AnimValidationCode.assetMissing
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("missing.png") ?? false)
    }

    // MARK: - Precomp Ref Tests

    func testValidate_precompRefMissing_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "missing_comp" }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.precompRefMissing
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("missing_comp") ?? false)
    }

    // MARK: - Unsupported Layer Type Tests

    func testValidate_unsupportedLayerType_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0" },
            { "ty": 1, "nm": "solid_layer" }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedLayerType
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("type 1") ?? false)
    }

    // MARK: - Mask Validation Tests

    func testValidate_maskModeSubtract_returnsError() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "s", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskMode
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("'s'") ?? false)
    }

    func testValidate_maskInverted_returnsError() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": true, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskInvert
        }
        XCTAssertNotNil(error)
    }

    func testValidate_maskPathAnimated_returnsError() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": false, "pt": { "a": 1, "k": [] }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskPathAnimated
        }
        XCTAssertNotNil(error)
    }

    func testValidate_maskOpacityAnimated_returnsError() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 1, "k": [] } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskOpacityAnimated
        }
        XCTAssertNotNil(error)
    }

    // MARK: - Track Matte Tests

    func testValidate_unsupportedMatteType_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "tt": 3 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMatteType
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("type 3") ?? false)
    }

    func testValidate_supportedMatteTypes_noError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 4, "td": 1, "shapes": [{ "ty": "gr", "it": [{ "ty": "sh" }, { "ty": "fl" }] }] },
            { "ty": 0, "refId": "comp_0", "tt": 1 },
            { "ty": 0, "refId": "comp_0", "tt": 2 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let matteError = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMatteType
        }
        XCTAssertNil(matteError)
    }

    // MARK: - Shape Subset Tests

    func testValidate_unsupportedShapeItem_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 4, "td": 1, "shapes": [{ "ty": "st", "nm": "Stroke" }] },
            { "ty": 0, "refId": "comp_0", "tt": 1 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("'st'") ?? false)
    }

    func testValidate_supportedShapeItems_noError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            {
              "ty": 4,
              "td": 1,
              "shapes": [{
                "ty": "gr",
                "it": [
                  { "ty": "sh", "ks": { "a": 0, "k": {} } },
                  { "ty": "fl", "c": { "a": 0, "k": [0, 0, 0, 1] } },
                  { "ty": "tr", "p": { "a": 0, "k": [0, 0] } }
                ]
              }]
            },
            { "ty": 0, "refId": "comp_0", "tt": 1 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let shapeError = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem
        }
        XCTAssertNil(shapeError)
    }

    // MARK: - Integration Tests

    func testValidate_validMask_noError() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let maskErrors = report.errors.filter {
            $0.code.hasPrefix("UNSUPPORTED_MASK")
        }
        XCTAssertEqual(maskErrors.count, 0)
    }

    func testValidate_bindingInPrecomp_found() throws {
        let scene = sceneJSON(bindingKey: "media")
        let anim = animJSON(bindingLayerName: "media")
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let bindingError = report.errors.first {
            $0.code == AnimValidationCode.bindingLayerNotFound
        }
        XCTAssertNil(bindingError)
    }
}
