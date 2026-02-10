import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// PR-23: Verifies that inputClip world transform includes shape groupTransforms.
///
/// Root cause: `computeMediaInputWorld` returned only the layer's world transform
/// (position/anchor/rotation/scale) but ignored the shape group transforms (the "tr"
/// element inside the shape group). Since paths are stored in shape-local coordinates
/// (PR-11 contract), the group transforms must be composed into the world matrix
/// at render time — otherwise the inputClip mask renders at the wrong position.
final class InputClipGroupTransformTests: XCTestCase {

    // MARK: - Test: groupTransforms included in inputClipWorld

    /// Verifies the inputClip pushTransform includes shape groupTransforms.
    ///
    /// Setup:
    ///   - mediaInput layer: position (100, 200), anchor (0, 0)
    ///     → layerLocal = translate(100, 200)
    ///   - shape group transform: translate(-30, -50)
    ///
    /// Expected inputClipWorld:
    ///   translate(100, 200) * translate(-30, -50) = translate(70, 150)
    func testInputClipWorld_includesGroupTransforms() throws {
        let json = Self.lottieWithMediaInput(
            mediaInputPosition: [100, 200],
            mediaInputAnchor: [0, 0],
            groupTransformPosition: [-30, -50]
        )

        let (commands, _) = try compileAndRender(json: json, frame: 0)

        // Find the inputClip group
        guard let groupIdx = commands.firstIndex(where: {
            if case .beginGroup(let name) = $0 { return name.contains("inputClip") }
            return false
        }) else {
            XCTFail("Should have inputClip group in commands")
            return
        }

        // Next command = pushTransform(inputClipWorld)
        guard case .pushTransform(let inputClipWorld) = commands[groupIdx + 1] else {
            XCTFail("Expected pushTransform after inputClip beginGroup, got \(commands[groupIdx + 1])")
            return
        }

        // Verify: translate(100,200) * translate(-30,-50) = translate(70, 150)
        XCTAssertEqual(inputClipWorld.a, 1.0, accuracy: 1e-6, "scale-x should be 1")
        XCTAssertEqual(inputClipWorld.d, 1.0, accuracy: 1e-6, "scale-y should be 1")
        XCTAssertEqual(inputClipWorld.b, 0.0, accuracy: 1e-6, "skew-x should be 0")
        XCTAssertEqual(inputClipWorld.c, 0.0, accuracy: 1e-6, "skew-y should be 0")
        XCTAssertEqual(inputClipWorld.tx, 70.0, accuracy: 1e-3, "tx = 100 + (-30) = 70")
        XCTAssertEqual(inputClipWorld.ty, 150.0, accuracy: 1e-3, "ty = 200 + (-50) = 150")
    }

    /// Verifies the inverse compensation also accounts for groupTransforms.
    func testInputClipInverse_matchesGroupTransformWorld() throws {
        let json = Self.lottieWithMediaInput(
            mediaInputPosition: [100, 200],
            mediaInputAnchor: [0, 0],
            groupTransformPosition: [-30, -50]
        )

        let (commands, _) = try compileAndRender(json: json, frame: 0)

        // Find inputClip group → pushTransform(world) → beginMask → pushTransform(inverse)
        guard let groupIdx = commands.firstIndex(where: {
            if case .beginGroup(let name) = $0 { return name.contains("inputClip") }
            return false
        }) else {
            XCTFail("Should have inputClip group")
            return
        }

        guard case .pushTransform(let world) = commands[groupIdx + 1] else {
            XCTFail("Expected pushTransform(world)")
            return
        }

        // beginMask is at groupIdx + 2, inverse is at groupIdx + 3
        guard case .beginMask = commands[groupIdx + 2] else {
            XCTFail("Expected beginMask at index \(groupIdx + 2), got \(commands[groupIdx + 2])")
            return
        }

        guard case .pushTransform(let inverse) = commands[groupIdx + 3] else {
            XCTFail("Expected pushTransform(inverse) at index \(groupIdx + 3)")
            return
        }

        // world * inverse should be identity
        let product = world.concatenating(inverse)
        XCTAssertEqual(product.a, 1.0, accuracy: 1e-6)
        XCTAssertEqual(product.d, 1.0, accuracy: 1e-6)
        XCTAssertEqual(product.b, 0.0, accuracy: 1e-6)
        XCTAssertEqual(product.c, 0.0, accuracy: 1e-6)
        XCTAssertEqual(product.tx, 0.0, accuracy: 1e-3, "world * inverse tx should be 0")
        XCTAssertEqual(product.ty, 0.0, accuracy: 1e-3, "world * inverse ty should be 0")
    }

    /// Verifies that commands pass RenderCommandValidator (scope-balanced).
    func testInputClipWithGroupTransforms_validatorPasses() throws {
        let json = Self.lottieWithMediaInput(
            mediaInputPosition: [100, 200],
            mediaInputAnchor: [0, 0],
            groupTransformPosition: [-30, -50]
        )

        let (commands, _) = try compileAndRender(json: json, frame: 0)

        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertTrue(errors.isEmpty, "Commands should be scope-balanced, got: \(errors)")
    }

    /// Verifies numeric match with production data from anim-1.1.json:
    ///   - mediaInput: p=(270,480), a=(0,0), groupTransform p=(-71.094,-65.998)
    ///   - Expected: translate(270-71.094, 480-65.998) = translate(198.906, 414.002)
    func testInputClipWorld_anim11ProductionValues() throws {
        let json = Self.lottieWithMediaInput(
            mediaInputPosition: [270, 480],
            mediaInputAnchor: [0, 0],
            groupTransformPosition: [-71.094, -65.998]
        )

        let (commands, _) = try compileAndRender(json: json, frame: 0)

        guard let groupIdx = commands.firstIndex(where: {
            if case .beginGroup(let name) = $0 { return name.contains("inputClip") }
            return false
        }) else {
            XCTFail("Should have inputClip group")
            return
        }

        guard case .pushTransform(let world) = commands[groupIdx + 1] else {
            XCTFail("Expected pushTransform(world)")
            return
        }

        XCTAssertEqual(world.tx, 198.906, accuracy: 0.01, "tx = 270 + (-71.094)")
        XCTAssertEqual(world.ty, 414.002, accuracy: 0.01, "ty = 480 + (-65.998)")
    }

    // MARK: - Helpers

    private func compileAndRender(json: String, frame: Int) throws -> ([RenderCommand], [RenderIssue]) {
        let data = json.data(using: .utf8)!
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)

        var compiler = AnimIRCompiler()
        var pathRegistry = PathRegistry()
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        var animIR = try compiler.compile(
            lottie: lottie,
            animRef: "test_inputclip",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &pathRegistry
        )

        return animIR.renderCommandsWithIssues(frameIndex: frame)
    }

    /// Builds minimal Lottie JSON with a pre-comp containing mediaInput + media layers.
    ///
    /// - Parameters:
    ///   - mediaInputPosition: [x, y] position of the mediaInput layer
    ///   - mediaInputAnchor: [x, y] anchor of the mediaInput layer
    ///   - groupTransformPosition: [x, y] position of the shape group transform ("tr" element)
    private static func lottieWithMediaInput(
        mediaInputPosition: [Double],
        mediaInputAnchor: [Double],
        groupTransformPosition: [Double]
    ) -> String {
        let px = mediaInputPosition[0]
        let py = mediaInputPosition[1]
        let ax = mediaInputAnchor[0]
        let ay = mediaInputAnchor[1]
        let gx = groupTransformPosition[0]
        let gy = groupTransformPosition[1]

        return """
        {
          "v": "5.12.1",
          "fr": 30,
          "ip": 0,
          "op": 300,
          "w": 540,
          "h": 960,
          "nm": "test_inputclip_gt",
          "ddd": 0,
          "assets": [
            {
              "id": "image_0",
              "w": 100,
              "h": 100,
              "u": "images/",
              "p": "img.png",
              "e": 0
            },
            {
              "id": "comp_0",
              "nm": "innerComp",
              "fr": 30,
              "layers": [
                {
                  "ddd": 0,
                  "ind": 1,
                  "ty": 4,
                  "nm": "mediaInput",
                  "hd": true,
                  "sr": 1,
                  "ks": {
                    "o": { "a": 0, "k": 100 },
                    "r": { "a": 0, "k": 0 },
                    "p": { "a": 0, "k": [\(px), \(py), 0] },
                    "a": { "a": 0, "k": [\(ax), \(ay), 0] },
                    "s": { "a": 0, "k": [100, 100, 100] }
                  },
                  "ao": 0,
                  "shapes": [
                    {
                      "ty": "gr",
                      "it": [
                        {
                          "ty": "sh",
                          "ks": {
                            "a": 0,
                            "k": {
                              "i": [[0,0],[0,0],[0,0],[0,0]],
                              "o": [[0,0],[0,0],[0,0],[0,0]],
                              "v": [[0,0],[100,0],[100,100],[0,100]],
                              "c": true
                            }
                          }
                        },
                        {
                          "ty": "fl",
                          "c": { "a": 0, "k": [0,0,0,1] },
                          "o": { "a": 0, "k": 100 }
                        },
                        {
                          "ty": "tr",
                          "p": { "a": 0, "k": [\(gx), \(gy)] },
                          "a": { "a": 0, "k": [0, 0] },
                          "s": { "a": 0, "k": [100, 100] },
                          "r": { "a": 0, "k": 0 },
                          "o": { "a": 0, "k": 100 }
                        }
                      ],
                      "nm": "Shape",
                      "bm": 0
                    }
                  ],
                  "ip": 0,
                  "op": 300,
                  "st": 0,
                  "bm": 0
                },
                {
                  "ddd": 0,
                  "ind": 2,
                  "ty": 2,
                  "nm": "media",
                  "cl": "png",
                  "refId": "image_0",
                  "sr": 1,
                  "ks": {
                    "o": { "a": 0, "k": 100 },
                    "r": { "a": 0, "k": 0 },
                    "p": { "a": 0, "k": [50, 80, 0] },
                    "a": { "a": 0, "k": [50, 80, 0] },
                    "s": { "a": 0, "k": [100, 100, 100] }
                  },
                  "ao": 0,
                  "ip": 0,
                  "op": 300,
                  "st": 0,
                  "bm": 0
                }
              ]
            }
          ],
          "layers": [
            {
              "ddd": 0,
              "ind": 1,
              "ty": 0,
              "nm": "innerComp",
              "refId": "comp_0",
              "sr": 1,
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] },
                "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ao": 0,
              "w": 540,
              "h": 960,
              "ip": 0,
              "op": 300,
              "st": 0,
              "bm": 0
            }
          ],
          "markers": [],
          "props": {}
        }
        """
    }
}
