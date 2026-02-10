import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// PR-30: Layer Toggle tests.
///
/// Tests for layer toggle parsing, validation, API methods, and render integration.
final class LayerToggleTests: XCTestCase {

    private var compiler: AnimIRCompiler!
    private var _testRegistry = PathRegistry()

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
        _testRegistry = PathRegistry()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    // MARK: - T1: Toggle ID Extraction

    func testExtractToggleId_validPrefix() throws {
        let lottieJSON = makeLottieWithToggleLayer(layerName: "toggle:decoration")
        let lottie = try decodeLottie(lottieJSON)

        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: AssetIndex(byId: [:]),
            pathRegistry: &_testRegistry
        )

        // Find the toggle layer in root comp
        let mainComp = ir.comps[AnimIR.rootCompId]!
        let toggleLayer = mainComp.layers.first { $0.name == "toggle:decoration" }
        XCTAssertNotNil(toggleLayer)
        XCTAssertEqual(toggleLayer?.toggleId, "decoration")
    }

    func testExtractToggleId_emptyId_isNil() throws {
        let lottieJSON = makeLottieWithToggleLayer(layerName: "toggle:")
        let lottie = try decodeLottie(lottieJSON)

        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: AssetIndex(byId: [:]),
            pathRegistry: &_testRegistry
        )

        let mainComp = ir.comps[AnimIR.rootCompId]!
        let toggleLayer = mainComp.layers.first { $0.name == "toggle:" }
        XCTAssertNotNil(toggleLayer)
        XCTAssertNil(toggleLayer?.toggleId, "Empty toggle ID should result in nil")
    }

    func testExtractToggleId_noPrefix_isNil() throws {
        let lottieJSON = makeLottieWithToggleLayer(layerName: "decoration")
        let lottie = try decodeLottie(lottieJSON)

        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: AssetIndex(byId: [:]),
            pathRegistry: &_testRegistry
        )

        let mainComp = ir.comps[AnimIR.rootCompId]!
        let regularLayer = mainComp.layers.first { $0.name == "decoration" }
        XCTAssertNotNil(regularLayer)
        XCTAssertNil(regularLayer?.toggleId)
    }

    // MARK: - T2: LayerToggle Model Decoding

    func testLayerToggle_decodesAllFields() throws {
        let json = """
        {
            "id": "hearts",
            "title": "Heart Decoration",
            "group": "decorations",
            "defaultOn": false
        }
        """
        let toggle = try JSONDecoder().decode(LayerToggle.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(toggle.id, "hearts")
        XCTAssertEqual(toggle.title, "Heart Decoration")
        XCTAssertEqual(toggle.group, "decorations")
        XCTAssertEqual(toggle.defaultOn, false)
    }

    func testLayerToggle_decodesWithoutOptionalGroup() throws {
        let json = """
        {
            "id": "stars",
            "title": "Star Decoration",
            "defaultOn": true
        }
        """
        let toggle = try JSONDecoder().decode(LayerToggle.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(toggle.id, "stars")
        XCTAssertEqual(toggle.title, "Star Decoration")
        XCTAssertNil(toggle.group)
        XCTAssertEqual(toggle.defaultOn, true)
    }

    // MARK: - T3: MediaBlock with LayerToggles Decoding

    func testMediaBlock_decodesLayerToggles() throws {
        let json = """
        {
            "blockId": "block_01",
            "zIndex": 0,
            "rect": { "x": 0, "y": 0, "width": 540, "height": 960 },
            "containerClip": "slotRect",
            "timing": { "startFrame": 0, "endFrame": 300 },
            "input": {
                "rect": { "x": 0, "y": 0, "width": 540, "height": 960 },
                "bindingKey": "media",
                "hitTest": "rect",
                "allowedMedia": ["photo"],
                "emptyPolicy": "hideWholeBlock",
                "fitModesAllowed": ["cover"],
                "userTransformsAllowed": { "pan": true, "zoom": true, "rotate": true },
                "defaultFit": "cover",
                "audio": { "enabled": false, "gain": 1.0 }
            },
            "variants": [],
            "layerToggles": [
                { "id": "hearts", "title": "Hearts", "defaultOn": true },
                { "id": "stars", "title": "Stars", "group": "deco", "defaultOn": false }
            ]
        }
        """
        let block = try JSONDecoder().decode(MediaBlock.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(block.layerToggles?.count, 2)
        XCTAssertEqual(block.layerToggles?[0].id, "hearts")
        XCTAssertEqual(block.layerToggles?[1].id, "stars")
        XCTAssertEqual(block.layerToggles?[1].group, "deco")
    }

    func testMediaBlock_decodesWithoutLayerToggles() throws {
        let json = """
        {
            "blockId": "block_01",
            "zIndex": 0,
            "rect": { "x": 0, "y": 0, "width": 540, "height": 960 },
            "containerClip": "slotRect",
            "timing": { "startFrame": 0, "endFrame": 300 },
            "input": {
                "rect": { "x": 0, "y": 0, "width": 540, "height": 960 },
                "bindingKey": "media",
                "hitTest": "rect",
                "allowedMedia": ["photo"],
                "emptyPolicy": "hideWholeBlock",
                "fitModesAllowed": ["cover"],
                "userTransformsAllowed": { "pan": true, "zoom": true, "rotate": true },
                "defaultFit": "cover",
                "audio": { "enabled": false, "gain": 1.0 }
            },
            "variants": []
        }
        """
        let block = try JSONDecoder().decode(MediaBlock.self, from: json.data(using: .utf8)!)
        XCTAssertNil(block.layerToggles)
    }

    // MARK: - T4: SceneValidator - LayerToggle Validation

    func testSceneValidator_layerToggleIdEmpty_reportsIssue() {
        let toggle = LayerToggle(id: "", title: "Empty ID", defaultOn: true)
        let block = makeMediaBlockWithToggles([toggle])
        let scene = makeScene(blocks: [block])

        let validator = SceneValidator()
        let report = validator.validate(scene: scene)
        let hasEmptyIdIssue = report.issues.contains { $0.code == SceneValidationCode.layerToggleIdEmpty }
        XCTAssertTrue(hasEmptyIdIssue, "Should report empty toggle ID")
    }

    func testSceneValidator_layerToggleTitleEmpty_reportsIssue() {
        let toggle = LayerToggle(id: "hearts", title: "", defaultOn: true)
        let block = makeMediaBlockWithToggles([toggle])
        let scene = makeScene(blocks: [block])

        let validator = SceneValidator()
        let report = validator.validate(scene: scene)
        let hasTitleIssue = report.issues.contains { $0.code == SceneValidationCode.layerToggleTitleEmpty }
        XCTAssertTrue(hasTitleIssue, "Should report empty toggle title")
    }

    func testSceneValidator_duplicateToggleIds_reportsIssue() {
        let toggle1 = LayerToggle(id: "hearts", title: "Hearts 1", defaultOn: true)
        let toggle2 = LayerToggle(id: "hearts", title: "Hearts 2", defaultOn: false)
        let block = makeMediaBlockWithToggles([toggle1, toggle2])
        let scene = makeScene(blocks: [block])

        let validator = SceneValidator()
        let report = validator.validate(scene: scene)
        let hasDuplicateIssue = report.issues.contains { $0.code == SceneValidationCode.layerToggleIdDuplicate }
        XCTAssertTrue(hasDuplicateIssue, "Should report duplicate toggle IDs")
    }

    // MARK: - T5: Render - Toggle Layer Skipped When Disabled

    func testRender_disabledToggle_layerNotRendered() throws {
        let lottieJSON = makeLottieWithToggleAndDecoImage(toggleId: "decoration")
        let lottie = try decodeLottie(lottieJSON)

        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: AssetIndex(byId: [:]),
            pathRegistry: &_testRegistry
        )

        // Render with toggle enabled (default)
        let commandsEnabled = ir.renderCommands(
            frameIndex: 0,
            userTransform: Matrix2D.identity,
            bindingLayerVisible: true,
            disabledToggleIds: []
        )
        let enabledAssetIds = commandsEnabled.compactMap { cmd -> String? in
            if case .drawImage(let assetId, _) = cmd { return assetId }
            return nil
        }
        XCTAssertTrue(enabledAssetIds.contains("test.json|deco_image"),
            "With toggle enabled, deco_image should render. Got: \(enabledAssetIds)")

        // Render with toggle disabled
        let commandsDisabled = ir.renderCommands(
            frameIndex: 0,
            userTransform: Matrix2D.identity,
            bindingLayerVisible: true,
            disabledToggleIds: ["decoration"]
        )
        let disabledAssetIds = commandsDisabled.compactMap { cmd -> String? in
            if case .drawImage(let assetId, _) = cmd { return assetId }
            return nil
        }
        XCTAssertFalse(disabledAssetIds.contains("test.json|deco_image"),
            "With toggle disabled, deco_image should NOT render. Got: \(disabledAssetIds)")
    }

    // MARK: - T6: ScenePlayer API - availableToggles

    func testScenePlayer_availableToggles_beforeCompile_returnsEmpty() {
        let player = ScenePlayer()
        XCTAssertTrue(player.availableToggles(blockId: "any").isEmpty)
    }

    // MARK: - T7: ScenePlayer API - setLayerToggle / isLayerToggleEnabled

    func testScenePlayer_toggleAPI_beforeCompile_noOp() {
        let player = ScenePlayer()

        // Should not crash
        player.setLayerToggle(blockId: "block", toggleId: "hearts", enabled: false)
        XCTAssertNil(player.isLayerToggleEnabled(blockId: "block", toggleId: "hearts"))
    }

    // MARK: - T8: LayerToggleStore Protocol

    func testLayerToggleStore_protocolExists() {
        // Compile-time check that protocol exists with correct signature
        final class MockStore: LayerToggleStore, @unchecked Sendable {
            func load(templateId: String, blockId: String, toggleId: String) -> Bool? { nil }
            func save(templateId: String, blockId: String, toggleId: String, value: Bool) {}
        }
        let _: LayerToggleStore = MockStore()
    }

    // MARK: - T9: ScenePlayerError.templateCorrupted

    func testTemplateCorruptedError_hasCorrectDescription() {
        let error = ScenePlayerError.templateCorrupted(reason: "TOGGLE_MISMATCH")
        XCTAssertEqual(error.errorDescription, "Template corrupted: TOGGLE_MISMATCH")
    }

    // MARK: - Helpers

    private func decodeLottie(_ json: String) throws -> LottieJSON {
        try JSONDecoder().decode(LottieJSON.self, from: json.data(using: .utf8)!)
    }

    private func makeLottieWithToggleLayer(layerName: String) -> String {
        """
        {
          "v": "5.12.1",
          "fr": 30,
          "ip": 0,
          "op": 300,
          "w": 1080,
          "h": 1920,
          "nm": "Test",
          "ddd": 0,
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img_1.png", "e": 0 }
          ],
          "layers": [
            {
              "ddd": 0, "ind": 1, "ty": 2, "nm": "\(layerName)",
              "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] },
                "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ip": 0, "op": 300, "st": 0
            },
            {
              "ddd": 0, "ind": 2, "ty": 2, "nm": "media",
              "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] },
                "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ip": 0, "op": 300, "st": 0
            }
          ],
          "markers": []
        }
        """
    }

    private func makeLottieWithToggleAndDecoImage(toggleId: String) -> String {
        """
        {
          "v": "5.12.1",
          "fr": 30,
          "ip": 0,
          "op": 300,
          "w": 1080,
          "h": 1920,
          "nm": "Test",
          "ddd": 0,
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img_1.png", "e": 0 },
            { "id": "deco_image", "w": 100, "h": 100, "u": "images/", "p": "deco.png", "e": 0 }
          ],
          "layers": [
            {
              "ddd": 0, "ind": 1, "ty": 2, "nm": "toggle:\(toggleId)",
              "refId": "deco_image",
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [100, 100, 0] },
                "a": { "a": 0, "k": [50, 50, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ip": 0, "op": 300, "st": 0
            },
            {
              "ddd": 0, "ind": 2, "ty": 2, "nm": "media",
              "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] },
                "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ip": 0, "op": 300, "st": 0
            }
          ],
          "markers": []
        }
        """
    }

    private func makeMediaBlockWithToggles(_ toggles: [LayerToggle]) -> MediaBlock {
        MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: Timing(startFrame: 0, endFrame: 300),
            input: MediaInput(
                rect: Rect(x: 0, y: 0, width: 540, height: 960),
                bindingKey: "media",
                hitTest: .rect,
                allowedMedia: ["photo"]
            ),
            variants: [
                Variant(
                    id: "v1",
                    animRef: "anim.json",
                    defaultDurationFrames: 300,
                    ifAnimationShorter: nil,
                    ifAnimationLonger: nil,
                    loop: nil,
                    loopRange: nil
                )
            ],
            layerToggles: toggles.isEmpty ? nil : toggles
        )
    }

    private func makeScene(blocks: [MediaBlock]) -> Scene {
        Scene(
            schemaVersion: "0.1",
            sceneId: "test_scene",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            mediaBlocks: blocks
        )
    }
}
