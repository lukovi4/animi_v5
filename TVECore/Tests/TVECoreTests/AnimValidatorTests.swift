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
        images: [String] = ["img_1.png"],
        options: AnimValidator.Options? = nil
    ) throws -> ValidationReport {
        let package = try createTempPackage(
            sceneJSON: sceneJSON,
            animFiles: [animRef: animJSON],
            images: images
        )
        let loaded = try loader.loadAnimations(from: package)
        let validatorToUse: AnimValidator = options.map { AnimValidator(options: $0) } ?? validator
        return validatorToUse.validate(scene: package.scene, package: package, loaded: loaded)
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

    func testValidate_maskModeSubtract_noError() throws {
        // Subtract mode (s) is now supported
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "s", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskMode
        }
        XCTAssertNil(error, "Subtract mode (s) should be supported")
    }

    func testValidate_maskModeIntersect_noError() throws {
        // Intersect mode (i) is now supported
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "i", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskMode
        }
        XCTAssertNil(error, "Intersect mode (i) should be supported")
    }

    func testValidate_maskModeLighten_returnsError() throws {
        // Lighten mode (l) is NOT supported
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "l", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskMode
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("'l'") ?? false)
        XCTAssertTrue(error?.message.contains("a (add), s (subtract), i (intersect)") ?? false)
    }

    func testValidate_maskModeDarken_returnsError() throws {
        // Darken mode (d) is NOT supported
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "d", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskMode
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("'d'") ?? false)
    }

    func testValidate_maskInverted_noError() throws {
        // Inverted masks are now supported
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": true, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskInvert
        }
        XCTAssertNil(error, "Inverted masks should be supported")
    }

    func testValidate_maskPathAnimated_returnsError_whenDisabled() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": false, "pt": { "a": 1, "k": [] }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        // Explicitly disable animated mask paths to test the error case
        var options = AnimValidator.Options()
        options.allowAnimatedMaskPath = false
        let report = try validatePackage(sceneJSON: scene, animJSON: anim, options: options)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskPathAnimated
        }
        XCTAssertNotNil(error)
    }

    func testValidate_maskPathAnimated_noError_whenEnabled() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": false, "pt": { "a": 1, "k": [] }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        // Default: allowAnimatedMaskPath = true
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskPathAnimated
        }
        XCTAssertNil(error, "Animated mask paths should be allowed by default")
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

    // MARK: - Mask Expansion Tests

    func testValidate_maskExpansionNonZero_returnsError() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 }, "x": { "a": 0, "k": 10 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskExpansionNonZero
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.path.contains(".x.k") ?? false)
        XCTAssertTrue(error?.message.contains("10") ?? false)
    }

    func testValidate_maskExpansionAnimated_returnsError() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 }, "x": { "a": 1, "k": [{"t": 0, "s": [0]}, {"t": 30, "s": [10]}] } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskExpansionAnimated
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.path.contains(".x.a") ?? false)
    }

    func testValidate_maskExpansionZero_noError() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 }, "x": { "a": 0, "k": 0 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskExpansionNonZero ||
            $0.code == AnimValidationCode.unsupportedMaskExpansionAnimated
        }
        XCTAssertNil(error, "Mask expansion x=0 should be allowed")
    }

    func testValidate_maskExpansionAbsent_noError() throws {
        let scene = sceneJSON()
        let maskJSON = """
        { "mode": "a", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskExpansionNonZero ||
            $0.code == AnimValidationCode.unsupportedMaskExpansionAnimated
        }
        XCTAssertNil(error, "Absent mask expansion should be allowed")
    }

    func testValidate_maskExpansionUnknownFormat_returnsError() throws {
        // Test fail-fast: unknown format (e.g., object instead of number) should error
        let scene = sceneJSON()
        // Using keyframes format for static value - this is an invalid/unexpected format
        let maskJSON = """
        { "mode": "a", "inv": false, "pt": { "a": 0, "k": {} }, "o": { "a": 0, "k": 100 }, "x": { "a": 0, "k": {"invalid": "format"} } }
        """
        let anim = animJSON(masksJSON: maskJSON)
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskExpansionFormat
        }
        XCTAssertNotNil(error, "Unknown mask expansion format should produce error (no silent ignore)")
        XCTAssertTrue(error?.path.contains(".x.k") ?? false)
    }

    // MARK: - Track Matte Tests

    func testValidate_unsupportedMatteType_returnsError() throws {
        let scene = sceneJSON()
        // tt=5 is unsupported (only 1-4 are valid)
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "tt": 5 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMatteType
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("type 5") ?? false)
    }

    func testValidate_supportedMatteTypes_noError() throws {
        let scene = sceneJSON()
        // Test all 4 supported matte types: alpha(1), alphaInv(2), luma(3), lumaInv(4)
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
            { "ty": 4, "td": 1, "shapes": [{ "ty": "gr", "it": [{ "ty": "sh" }, { "ty": "fl" }] }] },
            { "ty": 0, "refId": "comp_0", "tt": 2 },
            { "ty": 4, "td": 1, "shapes": [{ "ty": "gr", "it": [{ "ty": "sh" }, { "ty": "fl" }] }] },
            { "ty": 0, "refId": "comp_0", "tt": 3 },
            { "ty": 4, "td": 1, "shapes": [{ "ty": "gr", "it": [{ "ty": "sh" }, { "ty": "fl" }] }] },
            { "ty": 0, "refId": "comp_0", "tt": 4 }
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

    // MARK: - Path Topology Validation Tests

    func testValidate_animatedPathTopologyMismatch_producesValidationError() throws {
        // Create validator with animated paths allowed
        var options = AnimValidator.Options()
        options.allowAnimatedMaskPath = true
        let customValidator = AnimValidator(options: options)

        let scene = sceneJSON()
        // Animated mask with topology mismatch: first keyframe has 4 vertices, second has 3
        let maskJSON = """
        {
          "mode": "a",
          "inv": false,
          "pt": {
            "a": 1,
            "k": [
              {
                "t": 0,
                "s": [{ "v": [[0,0], [100,0], [100,100], [0,100]], "i": [[0,0], [0,0], [0,0], [0,0]], "o": [[0,0], [0,0], [0,0], [0,0]], "c": true }]
              },
              {
                "t": 30,
                "s": [{ "v": [[0,0], [100,0], [100,100]], "i": [[0,0], [0,0], [0,0]], "o": [[0,0], [0,0], [0,0]], "c": true }]
              }
            ]
          },
          "o": { "a": 0, "k": 100 }
        }
        """
        let anim = animJSON(masksJSON: maskJSON)

        let package = try createTempPackage(
            sceneJSON: scene,
            animFiles: ["anim-1.json": anim],
            images: ["img_1.png"]
        )
        let loaded = try loader.loadAnimations(from: package)
        let report = customValidator.validate(scene: package.scene, package: package, loaded: loaded)

        // Should have a topology mismatch error
        let topologyError = report.errors.first {
            $0.code == AnimValidationCode.pathTopologyMismatch
        }
        XCTAssertNotNil(topologyError, "Topology mismatch should produce validation error, not silent nil")
        XCTAssertTrue(topologyError?.message.contains("4") ?? false, "Error should mention expected vertex count")
        XCTAssertTrue(topologyError?.message.contains("3") ?? false, "Error should mention actual vertex count")
    }

    func testValidate_animatedPathTopologyMismatch_closedFlag_producesError() throws {
        // Create validator with animated paths allowed
        var options = AnimValidator.Options()
        options.allowAnimatedMaskPath = true
        let customValidator = AnimValidator(options: options)

        let scene = sceneJSON()
        // Animated mask with closed flag mismatch
        let maskJSON = """
        {
          "mode": "a",
          "inv": false,
          "pt": {
            "a": 1,
            "k": [
              {
                "t": 0,
                "s": [{ "v": [[0,0], [100,0]], "i": [[0,0], [0,0]], "o": [[0,0], [0,0]], "c": true }]
              },
              {
                "t": 30,
                "s": [{ "v": [[0,0], [100,0]], "i": [[0,0], [0,0]], "o": [[0,0], [0,0]], "c": false }]
              }
            ]
          },
          "o": { "a": 0, "k": 100 }
        }
        """
        let anim = animJSON(masksJSON: maskJSON)

        let package = try createTempPackage(
            sceneJSON: scene,
            animFiles: ["anim-1.json": anim],
            images: ["img_1.png"]
        )
        let loaded = try loader.loadAnimations(from: package)
        let report = customValidator.validate(scene: package.scene, package: package, loaded: loaded)

        // Should have a topology mismatch error for closed flag
        let topologyError = report.errors.first {
            $0.code == AnimValidationCode.pathTopologyMismatch
        }
        XCTAssertNotNil(topologyError, "Closed flag mismatch should produce validation error")
        XCTAssertTrue(topologyError?.message.contains("closed") ?? false, "Error should mention closed flag")
    }

    func testValidate_animatedPathConsistentTopology_noError() throws {
        // Create validator with animated paths allowed
        var options = AnimValidator.Options()
        options.allowAnimatedMaskPath = true
        let customValidator = AnimValidator(options: options)

        let scene = sceneJSON()
        // Valid animated mask with consistent topology (same vertex count and closed flag)
        let maskJSON = """
        {
          "mode": "a",
          "inv": false,
          "pt": {
            "a": 1,
            "k": [
              {
                "t": 0,
                "s": [{ "v": [[0,0], [100,0], [100,100], [0,100]], "i": [[0,0], [0,0], [0,0], [0,0]], "o": [[0,0], [0,0], [0,0], [0,0]], "c": true }]
              },
              {
                "t": 30,
                "s": [{ "v": [[10,10], [90,10], [90,90], [10,90]], "i": [[0,0], [0,0], [0,0], [0,0]], "o": [[0,0], [0,0], [0,0], [0,0]], "c": true }]
              }
            ]
          },
          "o": { "a": 0, "k": 100 }
        }
        """
        let anim = animJSON(masksJSON: maskJSON)

        let package = try createTempPackage(
            sceneJSON: scene,
            animFiles: ["anim-1.json": anim],
            images: ["img_1.png"]
        )
        let loaded = try loader.loadAnimations(from: package)
        let report = customValidator.validate(scene: package.scene, package: package, loaded: loaded)

        // Should NOT have topology errors
        let topologyError = report.errors.first {
            $0.code == AnimValidationCode.pathTopologyMismatch ||
            $0.code == AnimValidationCode.pathKeyframesMissing
        }
        XCTAssertNil(topologyError, "Consistent topology should not produce errors")
    }

    // MARK: - Forbidden Layer Flags Tests

    func testValidate_layer3D_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "ddd": 1 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedLayer3D
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.path.contains(".ddd") ?? false)
    }

    func testValidate_layerAutoOrient_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "ao": 1 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedLayerAutoOrient
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.path.contains(".ao") ?? false)
    }

    func testValidate_layerStretch_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "sr": 2 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedLayerStretch
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.path.contains(".sr") ?? false)
        XCTAssertTrue(error?.message.contains("sr=2") ?? false)
    }

    func testValidate_layerCollapseTransform_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "ct": 1 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedLayerCollapseTransform
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.path.contains(".ct") ?? false)
    }

    func testValidate_blendMode_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "bm": 3 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedBlendMode
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.path.contains(".bm") ?? false)
        XCTAssertTrue(error?.message.contains("bm=3") ?? false)
    }

    func testValidate_normalBlendMode_noError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "bm": 0 }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedBlendMode
        }
        XCTAssertNil(error, "Normal blend mode (bm=0) should be allowed")
    }

    // MARK: - Skew Validation Tests

    func testValidate_skewNonZero_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "ks": { "o": { "a": 0, "k": 100 }, "sk": { "a": 0, "k": 15 } } }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedSkew
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.path.contains(".ks.sk.k") ?? false)
        XCTAssertTrue(error?.message.contains("sk=15") ?? false)
    }

    func testValidate_skewAnimated_returnsError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "ks": { "o": { "a": 0, "k": 100 }, "sk": { "a": 1, "k": [{"t": 0, "s": [0]}, {"t": 30, "s": [15]}] } } }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedSkew
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.path.contains(".ks.sk.a") ?? false)
    }

    func testValidate_skewZero_noError() throws {
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "ks": { "o": { "a": 0, "k": 100 }, "sk": { "a": 0, "k": 0 } } }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedSkew
        }
        XCTAssertNil(error, "Skew sk=0 should be allowed")
    }

    func testValidate_skewUnknownFormat_returnsError() throws {
        // Test fail-fast: unknown format (e.g., object instead of number) should error
        let scene = sceneJSON()
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "u": "images/", "p": "img_1.png" },
            { "id": "comp_0", "layers": [{ "ty": 2, "nm": "media", "refId": "image_0" }] }
          ],
          "layers": [
            { "ty": 0, "refId": "comp_0", "ks": { "o": { "a": 0, "k": 100 }, "sk": { "a": 0, "k": {"invalid": "format"} } } }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedSkew
        }
        XCTAssertNotNil(error, "Unknown skew format should produce error (no silent ignore)")
        XCTAssertTrue(error?.path.contains(".ks.sk.k") ?? false)
        XCTAssertTrue(error?.message.contains("unrecognized") ?? false)
    }

    // MARK: - Shape Layer Validation Tests (All ty=4, not just td=1)

    func testValidate_shapeLayerWithTrimPaths_returnsError() throws {
        // Shape layer WITHOUT td=1 (not a matte source) should still be validated
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
            { "ty": 4, "shapes": [{ "ty": "tm", "nm": "Trim Paths" }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem
        }
        XCTAssertNotNil(error, "Shape layer without td=1 should still validate shapes")
        XCTAssertTrue(error?.message.contains("'tm'") ?? false)
    }

    func testValidate_shapeLayerWithRect_noError() throws {
        // Rectangle (rc) is now supported (PR-07)
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
            { "ty": 4, "shapes": [{ "ty": "rc", "nm": "Rectangle 1", "p": {"a": 0, "k": [50, 50]}, "s": {"a": 0, "k": [100, 100]}, "r": {"a": 0, "k": 0} }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem && $0.message.contains("'rc'")
        }
        XCTAssertNil(error, "Rectangle shape should NOT produce unsupportedShapeItem error (supported since PR-07)")
    }

    func testValidate_rectInGroupShape_noError() throws {
        // Rectangle nested inside a group should be allowed
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
            { "ty": 4, "shapes": [{ "ty": "gr", "it": [{ "ty": "rc", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [50, 50]} }, { "ty": "fl" }, { "ty": "tr" }] }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem && $0.message.contains("'rc'")
        }
        XCTAssertNil(error, "Rectangle inside group should NOT produce error (supported since PR-07)")
    }

    func testValidate_rectWithAnimatedRoundness_returnsError() throws {
        // Rectangle with animated roundness should fail (not supported)
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
            { "ty": 4, "shapes": [{ "ty": "rc", "nm": "Animated Roundness Rect", "p": {"a": 0, "k": [50, 50]}, "s": {"a": 0, "k": [100, 100]}, "r": {"a": 1, "k": [{"t": 0, "s": [0]}, {"t": 30, "s": [20]}]} }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedRectRoundnessAnimated
        }
        XCTAssertNotNil(error, "Animated rectangle roundness should produce error")
        XCTAssertTrue(error?.path.contains(".r.a") ?? false, "Error path should point to roundness animation flag")
    }

    func testValidate_rectWithMismatchedKeyframeCounts_returnsError() throws {
        // Rectangle with p having 2 keyframes and s having 3 keyframes should fail
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
            { "ty": 4, "shapes": [{ "ty": "rc", "nm": "Mismatched Rect", "p": {"a": 1, "k": [{"t": 0, "s": [0, 0]}, {"t": 10, "s": [50, 50]}]}, "s": {"a": 1, "k": [{"t": 0, "s": [100, 100]}, {"t": 5, "s": [150, 150]}, {"t": 10, "s": [200, 200]}]}, "r": {"a": 0, "k": 0} }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedRectKeyframesMismatch
        }
        XCTAssertNotNil(error, "Rectangle with mismatched keyframe counts should produce error")
        XCTAssertTrue(error?.message.contains("2 keyframes") ?? false, "Error should mention position keyframe count")
        XCTAssertTrue(error?.message.contains("3") ?? false, "Error should mention size keyframe count")
    }

    func testValidate_rectWithMismatchedKeyframeTimes_returnsError() throws {
        // Rectangle with p and s having same count but different times should fail
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
            { "ty": 4, "shapes": [{ "ty": "rc", "nm": "Time Mismatch Rect", "p": {"a": 1, "k": [{"t": 0, "s": [0, 0]}, {"t": 10, "s": [50, 50]}]}, "s": {"a": 1, "k": [{"t": 0, "s": [100, 100]}, {"t": 15, "s": [200, 200]}]}, "r": {"a": 0, "k": 0} }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedRectKeyframesMismatch
        }
        XCTAssertNotNil(error, "Rectangle with mismatched keyframe times should produce error")
        XCTAssertTrue(error?.message.contains("time mismatch") ?? false, "Error should mention time mismatch")
    }

    func testValidate_rectWithMatchingKeyframes_noError() throws {
        // Rectangle with p and s having matching keyframes should pass
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
            { "ty": 4, "shapes": [{ "ty": "rc", "nm": "Matching Rect", "p": {"a": 1, "k": [{"t": 0, "s": [0, 0]}, {"t": 10, "s": [50, 50]}]}, "s": {"a": 1, "k": [{"t": 0, "s": [100, 100]}, {"t": 10, "s": [200, 200]}]}, "r": {"a": 0, "k": 0} }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let keyframeMismatchError = report.errors.first {
            $0.code == AnimValidationCode.unsupportedRectKeyframesMismatch
        }
        let keyframeFormatError = report.errors.first {
            $0.code == AnimValidationCode.unsupportedRectKeyframeFormat
        }
        XCTAssertNil(keyframeMismatchError, "Rectangle with matching keyframes should NOT produce mismatch error")
        XCTAssertNil(keyframeFormatError, "Rectangle with valid keyframes should NOT produce format error")
    }

    func testValidate_rectWithAnimatedPositionInvalidFormat_returnsError() throws {
        // Rectangle with animated position (a=1) but k is not a keyframes array
        // This tests the fail-fast when keyframes can't be decoded
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
            { "ty": 4, "shapes": [{ "ty": "rc", "nm": "Invalid Anim Rect", "p": {"a": 1, "k": [50, 50]}, "s": {"a": 0, "k": [100, 100]}, "r": {"a": 0, "k": 0} }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedRectKeyframeFormat
        }
        XCTAssertNotNil(error, "Rectangle with animated position but invalid keyframes format should produce error")
        XCTAssertTrue(error?.path.contains(".p") ?? false, "Error path should reference position (.p)")
        XCTAssertTrue(error?.message.contains("could not be decoded") ?? false, "Error should mention keyframes could not be decoded")
    }

    // MARK: - Ellipse Shape Validation (PR-04)

    func testValidate_ellipseShape_returnsErrorWithCorrectPath() throws {
        // Ellipse (el) is decoded but NOT yet supported for rendering (until PR-08)
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
            { "ty": 4, "shapes": [{ "ty": "el", "nm": "Ellipse 1", "p": {"a": 0, "k": [50, 50]}, "s": {"a": 0, "k": [100, 100]} }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem && $0.message.contains("'el'")
        }
        XCTAssertNotNil(error, "Ellipse shape should produce unsupportedShapeItem error")
        // Verify path contains .shapes[0].ty for top-level shape
        XCTAssertTrue(error?.path.contains(".shapes[0].ty") == true, "Path should contain .shapes[0].ty, got: \(error?.path ?? "nil")")
    }

    func testValidate_ellipseInGroupShape_returnsErrorWithCorrectNestedPath() throws {
        // Ellipse nested inside a group should also be caught with correct path
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
            { "ty": 4, "shapes": [{ "ty": "gr", "it": [{ "ty": "el", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [50, 50]} }, { "ty": "fl" }, { "ty": "tr" }] }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem && $0.message.contains("'el'")
        }
        XCTAssertNotNil(error, "Ellipse inside group should also produce error")
        // Verify path is correct: should contain .it[0].ty for nested shape inside group
        XCTAssertTrue(error?.path.contains(".it[0].ty") == true, "Path should contain .it[0].ty for nested shape, got: \(error?.path ?? "nil")")
    }

    // MARK: - Polystar Shape Validation (PR-05)

    func testValidate_polystarShape_returnsErrorWithCorrectPath() throws {
        // Polystar (sr) is decoded but NOT yet supported for rendering (until PR-09)
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
            { "ty": 4, "shapes": [{ "ty": "sr", "sy": 1, "pt": {"a": 0, "k": 5}, "or": {"a": 0, "k": 50} }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem && $0.message.contains("'sr'")
        }
        XCTAssertNotNil(error, "Polystar shape should produce unsupportedShapeItem error")
        // Verify path contains .shapes[0].ty for top-level shape
        XCTAssertTrue(error?.path.contains(".shapes[0].ty") == true, "Path should contain .shapes[0].ty, got: \(error?.path ?? "nil")")
    }

    func testValidate_polystarInGroupShape_returnsErrorWithCorrectNestedPath() throws {
        // Polystar nested inside a group should also be caught with correct path
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
            { "ty": 4, "shapes": [{ "ty": "gr", "it": [{ "ty": "sr", "sy": 1, "pt": {"a": 0, "k": 5}, "or": {"a": 0, "k": 50} }, { "ty": "fl" }, { "ty": "tr" }] }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem && $0.message.contains("'sr'")
        }
        XCTAssertNotNil(error, "Polystar inside group should also produce error")
        // Verify path is correct: should contain .it[0].ty for nested shape inside group
        XCTAssertTrue(error?.path.contains(".it[0].ty") == true, "Path should contain .it[0].ty for nested shape, got: \(error?.path ?? "nil")")
    }

    // MARK: - Stroke Shape Validation (PR-06)

    func testValidate_strokeShape_returnsErrorWithCorrectPath() throws {
        // Stroke (st) is decoded but NOT yet supported for rendering (until PR-10)
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
            { "ty": 4, "shapes": [{ "ty": "st", "c": {"a": 0, "k": [1, 0, 0]}, "o": {"a": 0, "k": 100}, "w": {"a": 0, "k": 5} }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem && $0.message.contains("'st'")
        }
        XCTAssertNotNil(error, "Stroke shape should produce unsupportedShapeItem error")
        // Verify path contains .shapes[0].ty for top-level shape
        XCTAssertTrue(error?.path.contains(".shapes[0].ty") == true, "Path should contain .shapes[0].ty, got: \(error?.path ?? "nil")")
    }

    func testValidate_strokeInGroupShape_returnsErrorWithCorrectNestedPath() throws {
        // Stroke nested inside a group should also be caught with correct path
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
            { "ty": 4, "shapes": [{ "ty": "gr", "it": [{ "ty": "st", "c": {"a": 0, "k": [1, 0, 0]}, "w": {"a": 0, "k": 2} }, { "ty": "sh" }, { "ty": "tr" }] }] }
          ]
        }
        """
        let report = try validatePackage(sceneJSON: scene, animJSON: anim)

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem && $0.message.contains("'st'")
        }
        XCTAssertNotNil(error, "Stroke inside group should also produce error")
        // Verify path is correct: should contain .it[0].ty for nested shape inside group
        XCTAssertTrue(error?.path.contains(".it[0].ty") == true, "Path should contain .it[0].ty for nested shape, got: \(error?.path ?? "nil")")
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

    // MARK: - PR-01 Negative Asset Tests (Bundle.module)

    /// Helper to load and validate a negative test case from Bundle.module
    /// Uses a scene with mediaBlock referencing the anim.json so it gets validated
    private func validateNegativeCase(_ caseName: String) throws -> ValidationReport {
        guard let animURL = Bundle.module.url(
            forResource: "anim",
            withExtension: "json",
            subdirectory: "Resources/negative/\(caseName)"
        ) else {
            XCTFail("Could not find anim.json for negative case: \(caseName)")
            throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing test asset"])
        }

        let animData = try Data(contentsOf: animURL)
        let animJSONString = String(data: animData, encoding: .utf8)!

        // Create scene with a media block that references our anim.json
        // Use a placeholder binding key that may or may not exist in the anim
        let sceneWithBlock = """
        {
          "schemaVersion": "0.1",
          "canvas": { "width": 1080, "height": 1920, "fps": 30, "durationFrames": 90 },
          "mediaBlocks": [{
            "blockId": "test_block",
            "zIndex": 0,
            "rect": { "x": 0, "y": 0, "width": 1080, "height": 1920 },
            "containerClip": "slotRect",
            "input": {
              "rect": { "x": 0, "y": 0, "width": 1080, "height": 1920 },
              "bindingKey": "_test_placeholder_",
              "allowedMedia": ["photo"]
            },
            "variants": [{ "variantId": "v1", "animRef": "anim.json" }]
          }]
        }
        """

        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sceneURL = tempDir.appendingPathComponent("scene.json")
        try sceneWithBlock.write(to: sceneURL, atomically: true, encoding: .utf8)

        let animFileURL = tempDir.appendingPathComponent("anim.json")
        try animJSONString.write(to: animFileURL, atomically: true, encoding: .utf8)

        let package = try packageLoader.load(from: tempDir)
        let loaded = try loader.loadAnimations(from: package)

        return validator.validate(scene: package.scene, package: package, loaded: loaded)
    }

    func testNegativeAsset_trimPaths_returnsUnsupportedShapeItem() throws {
        let report = try validateNegativeCase("neg_trim_paths_tm")

        // Filter to find specifically the tm (trim paths) error
        let tmError = report.errors.first {
            $0.code == AnimValidationCode.unsupportedShapeItem && $0.message.contains("'tm'")
        }
        XCTAssertNotNil(tmError, "neg_trim_paths_tm should produce UNSUPPORTED_SHAPE_ITEM error for 'tm'")
    }

    func testNegativeAsset_maskExpansion_returnsUnsupportedMaskExpansionNonZero() throws {
        let report = try validateNegativeCase("neg_mask_expansion_x")

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskExpansionNonZero
        }
        XCTAssertNotNil(error, "neg_mask_expansion_x should produce UNSUPPORTED_MASK_EXPANSION_NONZERO error")
    }

    func testNegativeAsset_maskOpacityAnimated_returnsUnsupportedMaskOpacityAnimated() throws {
        let report = try validateNegativeCase("neg_mask_opacity_animated")

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedMaskOpacityAnimated
        }
        XCTAssertNotNil(error, "neg_mask_opacity_animated should produce UNSUPPORTED_MASK_OPACITY_ANIMATED error")
    }

    func testNegativeAsset_skewNonZero_returnsUnsupportedSkew() throws {
        let report = try validateNegativeCase("neg_skew_sk_nonzero")

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedSkew
        }
        XCTAssertNotNil(error, "neg_skew_sk_nonzero should produce UNSUPPORTED_SKEW error")
    }

    func testNegativeAsset_layer3D_returnsUnsupportedLayer3D() throws {
        let report = try validateNegativeCase("neg_layer_ddd_3d")

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedLayer3D
        }
        XCTAssertNotNil(error, "neg_layer_ddd_3d should produce UNSUPPORTED_LAYER_3D error")
    }

    func testNegativeAsset_autoOrient_returnsUnsupportedLayerAutoOrient() throws {
        let report = try validateNegativeCase("neg_layer_ao_auto_orient")

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedLayerAutoOrient
        }
        XCTAssertNotNil(error, "neg_layer_ao_auto_orient should produce UNSUPPORTED_LAYER_AUTO_ORIENT error")
    }

    func testNegativeAsset_stretch_returnsUnsupportedLayerStretch() throws {
        let report = try validateNegativeCase("neg_layer_sr_stretch")

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedLayerStretch
        }
        XCTAssertNotNil(error, "neg_layer_sr_stretch should produce UNSUPPORTED_LAYER_STRETCH error")
    }

    func testNegativeAsset_collapseTransform_returnsUnsupportedLayerCollapseTransform() throws {
        let report = try validateNegativeCase("neg_layer_ct_collapse_transform")

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedLayerCollapseTransform
        }
        XCTAssertNotNil(error, "neg_layer_ct_collapse_transform should produce UNSUPPORTED_LAYER_COLLAPSE_TRANSFORM error")
    }

    func testNegativeAsset_blendMode_returnsUnsupportedBlendMode() throws {
        let report = try validateNegativeCase("neg_layer_bm_blend_mode")

        let error = report.errors.first {
            $0.code == AnimValidationCode.unsupportedBlendMode
        }
        XCTAssertNotNil(error, "neg_layer_bm_blend_mode should produce UNSUPPORTED_BLEND_MODE error")
    }
}
