import XCTest
@testable import TVECore

final class AnimIRCompilerTests: XCTestCase {
    var compiler: AnimIRCompiler!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        compiler = nil
        super.tearDown()
    }

    // MARK: - Test Data

    /// Minimal valid Lottie JSON for testing
    private let minimalLottieJSON = """
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
        {
          "id": "image_0",
          "w": 540,
          "h": 960,
          "u": "images/",
          "p": "img_1.png",
          "e": 0
        }
      ],
      "layers": [
        {
          "ddd": 0,
          "ind": 1,
          "ty": 2,
          "nm": "media",
          "refId": "image_0",
          "ks": {
            "o": { "a": 0, "k": 100 },
            "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [270, 480, 0] },
            "a": { "a": 0, "k": [270, 480, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "ip": 0,
          "op": 300,
          "st": 0
        }
      ],
      "markers": []
    }
    """

    /// Lottie JSON with precomp (like anim-1)
    private let lottieWithPrecompJSON = """
    {
      "v": "5.12.1",
      "fr": 30,
      "ip": 0,
      "op": 300,
      "w": 1080,
      "h": 1920,
      "nm": "WithPrecomp",
      "ddd": 0,
      "assets": [
        {
          "id": "image_0",
          "w": 540,
          "h": 960,
          "u": "images/",
          "p": "img_1.png",
          "e": 0
        },
        {
          "id": "comp_0",
          "nm": "precomp",
          "fr": 30,
          "layers": [
            {
              "ddd": 0,
              "ind": 1,
              "ty": 2,
              "nm": "media",
              "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] },
                "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "hasMask": true,
              "masksProperties": [
                {
                  "inv": false,
                  "mode": "a",
                  "pt": {
                    "a": 0,
                    "k": {
                      "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
                      "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
                      "v": [[540, 0], [0, 314], [0, 960], [540, 645]],
                      "c": true
                    }
                  },
                  "o": { "a": 0, "k": 100 }
                }
              ],
              "ip": 0,
              "op": 300,
              "st": 0
            }
          ]
        }
      ],
      "layers": [
        {
          "ddd": 0,
          "ind": 1,
          "ty": 0,
          "nm": "precomp_layer",
          "refId": "comp_0",
          "ks": {
            "o": { "a": 0, "k": 100 },
            "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [270, 480, 0] },
            "a": { "a": 0, "k": [270, 480, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "w": 540,
          "h": 960,
          "ip": 0,
          "op": 300,
          "st": 0
        }
      ],
      "markers": []
    }
    """

    /// Lottie JSON with matte (like anim-2)
    private let lottieWithMatteJSON = """
    {
      "v": "5.12.1",
      "fr": 30,
      "ip": 0,
      "op": 300,
      "w": 1080,
      "h": 1920,
      "nm": "WithMatte",
      "ddd": 0,
      "assets": [
        {
          "id": "image_0",
          "w": 540,
          "h": 960,
          "u": "images/",
          "p": "img_2.png",
          "e": 0
        },
        {
          "id": "comp_0",
          "nm": "precomp",
          "fr": 30,
          "layers": [
            {
              "ddd": 0,
              "ind": 1,
              "ty": 2,
              "nm": "media",
              "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] },
                "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ip": 0,
              "op": 300,
              "st": 0
            }
          ]
        }
      ],
      "layers": [
        {
          "ddd": 0,
          "ind": 1,
          "ty": 3,
          "nm": "null_parent",
          "ks": {
            "o": { "a": 0, "k": 0 },
            "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [810, 480, 0] },
            "a": { "a": 0, "k": [50, 50, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "ip": 30,
          "op": 330,
          "st": 30
        },
        {
          "ddd": 0,
          "ind": 2,
          "ty": 4,
          "nm": "matte_source",
          "parent": 1,
          "td": 1,
          "ks": {
            "o": { "a": 0, "k": 100 },
            "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [50, 50, 0] },
            "a": { "a": 0, "k": [0, 0, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "shapes": [
            {
              "ty": "gr",
              "it": [
                {
                  "ty": "sh",
                  "ks": {
                    "a": 0,
                    "k": {
                      "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
                      "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
                      "v": [[270, -160], [270, 480], [-270, 160], [-270, -480]],
                      "c": true
                    }
                  }
                },
                {
                  "ty": "fl",
                  "c": { "a": 0, "k": [0, 0, 0, 1] },
                  "o": { "a": 0, "k": 100 }
                },
                {
                  "ty": "tr",
                  "p": { "a": 0, "k": [0, 0] },
                  "a": { "a": 0, "k": [0, 0] },
                  "s": { "a": 0, "k": [100, 100] },
                  "r": { "a": 0, "k": 0 },
                  "o": { "a": 0, "k": 100 }
                }
              ],
              "nm": "Group"
            }
          ],
          "ip": 30,
          "op": 330,
          "st": 30
        },
        {
          "ddd": 0,
          "ind": 3,
          "ty": 0,
          "nm": "precomp_consumer",
          "parent": 1,
          "tt": 1,
          "tp": 2,
          "refId": "comp_0",
          "ks": {
            "o": { "a": 0, "k": 100 },
            "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [50, 50, 0] },
            "a": { "a": 0, "k": [270, 480, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "w": 540,
          "h": 960,
          "ip": 30,
          "op": 330,
          "st": 30
        }
      ],
      "markers": []
    }
    """

    private func decodeLottie(_ json: String) throws -> LottieJSON {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(LottieJSON.self, from: data)
    }

    // MARK: - Basic Compilation Tests

    func testCompile_minimalLottie_succeeds() throws {
        // Given
        let lottie = try decodeLottie(minimalLottieJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        XCTAssertEqual(ir.meta.fps, 30)
        XCTAssertEqual(ir.meta.width, 1080)
        XCTAssertEqual(ir.meta.height, 1920)
        XCTAssertEqual(ir.meta.inPoint, 0)
        XCTAssertEqual(ir.meta.outPoint, 300)
    }

    func testCompile_withPrecomp_createsMultipleComps() throws {
        // Given
        let lottie = try decodeLottie(lottieWithPrecompJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        XCTAssertNotNil(ir.comps[AnimIR.rootCompId])
        XCTAssertNotNil(ir.comps["comp_0"])
        XCTAssertEqual(ir.comps.count, 2)
    }

    // MARK: - Meta Tests

    func testCompile_metaContainsSourceAnimRef() throws {
        // Given
        let lottie = try decodeLottie(minimalLottieJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "my-animation.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        XCTAssertEqual(ir.meta.sourceAnimRef, "my-animation.json")
    }

    // MARK: - Binding Tests

    func testCompile_bindingInRootLayer_found() throws {
        // Given
        let lottie = try decodeLottie(minimalLottieJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        XCTAssertEqual(ir.binding.bindingKey, "media")
        XCTAssertEqual(ir.binding.boundCompId, AnimIR.rootCompId)
        XCTAssertEqual(ir.binding.boundAssetId, "image_0")
    }

    func testCompile_bindingInPrecomp_found() throws {
        // Given
        let lottie = try decodeLottie(lottieWithPrecompJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        XCTAssertEqual(ir.binding.bindingKey, "media")
        XCTAssertEqual(ir.binding.boundCompId, "comp_0")
    }

    func testCompile_bindingNotFound_throws() throws {
        // Given
        let lottie = try decodeLottie(minimalLottieJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When/Then
        XCTAssertThrowsError(try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "nonexistent",
            assetIndex: assetIndex
        )) { error in
            guard case AnimIRCompilerError.bindingLayerNotFound = error else {
                XCTFail("Expected bindingLayerNotFound error")
                return
            }
        }
    }

    // MARK: - Layer Tests

    func testCompile_layerHasCorrectTiming() throws {
        // Given
        let lottie = try decodeLottie(minimalLottieJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        guard let rootComp = ir.comps[AnimIR.rootCompId],
              let layer = rootComp.layers.first else {
            XCTFail("No layers")
            return
        }

        XCTAssertEqual(layer.timing.inPoint, 0)
        XCTAssertEqual(layer.timing.outPoint, 300)
        XCTAssertEqual(layer.timing.startTime, 0)
    }

    func testCompile_layerHasCorrectType() throws {
        // Given
        let lottie = try decodeLottie(minimalLottieJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        guard let rootComp = ir.comps[AnimIR.rootCompId],
              let layer = rootComp.layers.first else {
            XCTFail("No layers")
            return
        }

        XCTAssertEqual(layer.type, .image)
        XCTAssertEqual(layer.name, "media")
    }

    // MARK: - Mask Tests

    func testCompile_maskOnLayer_compiled() throws {
        // Given
        let lottie = try decodeLottie(lottieWithPrecompJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        guard let precomp = ir.comps["comp_0"],
              let mediaLayer = precomp.layers.first(where: { $0.name == "media" }) else {
            XCTFail("Media layer not found")
            return
        }

        XCTAssertFalse(mediaLayer.masks.isEmpty)
        XCTAssertEqual(mediaLayer.masks.first?.mode, .add)
    }

    // MARK: - Matte Tests

    func testCompile_matteRelationship_established() throws {
        // Given
        let lottie = try decodeLottie(lottieWithMatteJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_2.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        guard let rootComp = ir.comps[AnimIR.rootCompId] else {
            XCTFail("Root comp not found")
            return
        }

        // Find matte source
        let matteSource = rootComp.layers.first { $0.isMatteSource }
        XCTAssertNotNil(matteSource)
        XCTAssertEqual(matteSource?.id, 2)

        // Find consumer
        let consumer = rootComp.layers.first { $0.matte != nil }
        XCTAssertNotNil(consumer)
        XCTAssertEqual(consumer?.matte?.mode, .alpha)
        XCTAssertEqual(consumer?.matte?.sourceLayerId, 2)
    }

    // MARK: - Asset Index Tests

    func testCompile_assetIndexPreserved() throws {
        // Given
        let lottie = try decodeLottie(minimalLottieJSON)
        let assetIndex = AssetIndex(byId: [
            "image_0": "images/img_1.png",
            "image_1": "images/img_2.png"
        ])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        XCTAssertEqual(ir.assets.byId["image_0"], "images/img_1.png")
        XCTAssertEqual(ir.assets.byId["image_1"], "images/img_2.png")
    }

    // MARK: - Determinism Tests

    func testCompile_deterministic() throws {
        // Given
        let lottie = try decodeLottie(minimalLottieJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When
        let ir1 = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )
        let ir2 = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        XCTAssertEqual(ir1.meta, ir2.meta)
        XCTAssertEqual(ir1.rootComp, ir2.rootComp)
        XCTAssertEqual(ir1.binding, ir2.binding)
        XCTAssertEqual(ir1.assets, ir2.assets)
    }

    // MARK: - Transform Tests

    func testCompile_layerHasTransform() throws {
        // Given
        let lottie = try decodeLottie(minimalLottieJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex
        )

        // Then
        guard let rootComp = ir.comps[AnimIR.rootCompId],
              let layer = rootComp.layers.first else {
            XCTFail("No layers")
            return
        }

        // Check transform has expected values
        XCTAssertEqual(layer.transform.position.staticValue, Vec2D(x: 270, y: 480))
        XCTAssertEqual(layer.transform.scale.staticValue, Vec2D(x: 100, y: 100))
        XCTAssertEqual(layer.transform.rotation.staticValue, 0)
        XCTAssertEqual(layer.transform.opacity.staticValue, 100)
    }
}
