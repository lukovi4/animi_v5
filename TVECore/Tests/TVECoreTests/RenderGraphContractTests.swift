import XCTest
@testable import TVECore

final class RenderGraphContractTests: XCTestCase {
    var compiler: AnimIRCompiler!

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    // MARK: - Test Data

    /// Minimal Lottie with image layer
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
        { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }
      ],
      "layers": [
        {
          "ind": 1, "ty": 2, "nm": "media", "refId": "image_0",
          "ks": {
            "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [270, 480, 0] }, "a": { "a": 0, "k": [270, 480, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "ip": 0, "op": 300, "st": 0
        }
      ]
    }
    """

    /// Lottie with precomp and mask (like anim-1)
    private let lottieWithMaskJSON = """
    {
      "v": "5.12.1",
      "fr": 30,
      "ip": 0,
      "op": 300,
      "w": 1080,
      "h": 1920,
      "nm": "WithMask",
      "ddd": 0,
      "assets": [
        { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 },
        {
          "id": "comp_0",
          "nm": "precomp",
          "fr": 30,
          "layers": [
            {
              "ind": 1, "ty": 2, "nm": "media", "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] }, "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "hasMask": true,
              "masksProperties": [
                {
                  "inv": false, "mode": "a",
                  "pt": { "a": 0, "k": { "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]], "v": [[540,0],[0,314],[0,960],[540,645]], "c": true } },
                  "o": { "a": 0, "k": 100 }
                }
              ],
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
      ],
      "layers": [
        {
          "ind": 1, "ty": 0, "nm": "precomp_layer", "refId": "comp_0",
          "ks": {
            "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [270, 480, 0] }, "a": { "a": 0, "k": [270, 480, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "w": 540, "h": 960, "ip": 0, "op": 300, "st": 0
        }
      ]
    }
    """

    /// Lottie with matte (like anim-2)
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
        { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 },
        {
          "id": "comp_0",
          "nm": "precomp",
          "fr": 30,
          "layers": [
            {
              "ind": 1, "ty": 2, "nm": "media", "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] }, "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
      ],
      "layers": [
        {
          "ind": 1, "ty": 3, "nm": "null_parent",
          "ks": {
            "o": { "a": 0, "k": 0 }, "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [810, 480, 0] }, "a": { "a": 0, "k": [50, 50, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "ip": 30, "op": 330, "st": 30
        },
        {
          "ind": 2, "ty": 4, "nm": "matte_source", "parent": 1, "td": 1,
          "ks": {
            "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [50, 50, 0] }, "a": { "a": 0, "k": [0, 0, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "shapes": [
            {
              "ty": "gr",
              "it": [
                { "ty": "sh", "ks": { "a": 0, "k": { "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]], "v": [[270,-160],[270,480],[-270,160],[-270,-480]], "c": true } } },
                { "ty": "fl", "c": { "a": 0, "k": [0, 0, 0, 1] }, "o": { "a": 0, "k": 100 } },
                { "ty": "tr", "p": { "a": 0, "k": [0, 0] }, "a": { "a": 0, "k": [0, 0] }, "s": { "a": 0, "k": [100, 100] }, "r": { "a": 0, "k": 0 }, "o": { "a": 0, "k": 100 } }
              ]
            }
          ],
          "ip": 30, "op": 330, "st": 30
        },
        {
          "ind": 3, "ty": 0, "nm": "precomp_consumer", "parent": 1, "tt": 1, "tp": 2, "refId": "comp_0",
          "ks": {
            "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
            "p": { "a": 0, "k": [50, 50, 0] }, "a": { "a": 0, "k": [270, 480, 0] },
            "s": { "a": 0, "k": [100, 100, 100] }
          },
          "w": 540, "h": 960, "ip": 30, "op": 330, "st": 30
        }
      ]
    }
    """

    private func compileIR(_ json: String, animRef: String = "test.json") throws -> AnimIR {
        let data = json.data(using: .utf8)!
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: animRef,
            bindingKey: "media",
            assetIndex: assetIndex
        )
        // Register paths for mask and shape rendering
        ir.registerPaths()
        return ir
    }

    // MARK: - Balance Tests

    func testRenderCommands_minimal_isBalanced() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands = ir.renderCommands(frameIndex: 0)
        XCTAssertTrue(commands.isBalanced(), "Commands should be balanced")
    }

    func testRenderCommands_withMask_isBalanced() throws {
        var ir = try compileIR(lottieWithMaskJSON)
        let commands = ir.renderCommands(frameIndex: 0)
        XCTAssertTrue(commands.isBalanced(), "Commands should be balanced")
    }

    func testRenderCommands_withMatte_isBalanced() throws {
        var ir = try compileIR(lottieWithMatteJSON)
        let commands = ir.renderCommands(frameIndex: 0)
        XCTAssertTrue(commands.isBalanced(), "Commands should be balanced")
    }

    // MARK: - Group Balance Tests

    func testRenderCommands_beginEndGroupBalanced() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands = ir.renderCommands(frameIndex: 0)
        let counts = commands.commandCounts()

        XCTAssertEqual(counts["beginGroup"], counts["endGroup"])
    }

    func testRenderCommands_pushPopTransformBalanced() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands = ir.renderCommands(frameIndex: 0)
        let counts = commands.commandCounts()

        XCTAssertEqual(counts["pushTransform"], counts["popTransform"])
    }

    // MARK: - Mask Tests

    func testRenderCommands_withMask_containsMaskCommands() throws {
        var ir = try compileIR(lottieWithMaskJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        XCTAssertTrue(commands.hasMaskCommands, "Should have mask commands")

        let counts = commands.commandCounts()
        XCTAssertEqual(counts["beginMaskAdd"], counts["endMask"], "Mask begin/end should be balanced")
    }

    func testRenderCommands_maskBeforeDrawImage() throws {
        var ir = try compileIR(lottieWithMaskJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        var foundMaskBeforeImage = false
        var inMask = false

        for command in commands {
            if case .beginMaskAdd = command {
                inMask = true
            } else if case .drawImage = command, inMask {
                foundMaskBeforeImage = true
                break
            } else if case .endMask = command {
                inMask = false
            }
        }

        XCTAssertTrue(foundMaskBeforeImage, "Should have BeginMaskAdd before DrawImage")
    }

    // MARK: - Matte Tests

    func testRenderCommands_withMatte_containsMatteCommands() throws {
        var ir = try compileIR(lottieWithMatteJSON)
        // Note: matte layers have ip=30, so test at frame 30 when they're visible
        let commands = ir.renderCommands(frameIndex: 30)

        XCTAssertTrue(commands.hasMatteCommands, "Should have matte commands")

        let counts = commands.commandCounts()
        // PR9: use unified beginMatte command instead of separate alpha/alphaInverted
        let matteBegins = counts["beginMatte"] ?? 0
        let matteEnds = counts["endMatte"] ?? 0
        XCTAssertEqual(matteBegins, matteEnds, "Matte begin/end should be balanced")
    }

    func testRenderCommands_matteSourceNotRendered() throws {
        var ir = try compileIR(lottieWithMatteJSON)
        // Note: matte layers have ip=30, so test at frame 30 when they're visible
        let commands = ir.renderCommands(frameIndex: 30)

        // PR9: Matte source layer should only appear inside "matteSource" group
        // and NOT at the top level (directly under root)
        // Track nesting to find top-level layer groups
        var topLevelLayerGroupNames: [String] = []
        var insideMatteSource = false
        var matteSourceDepth = 0

        for command in commands {
            switch command {
            case .beginGroup(let name):
                if name == "matteSource" {
                    insideMatteSource = true
                    matteSourceDepth = 1
                } else if insideMatteSource {
                    matteSourceDepth += 1
                } else if name.hasPrefix("Layer:") {
                    topLevelLayerGroupNames.append(name)
                }
            case .endGroup:
                if insideMatteSource {
                    matteSourceDepth -= 1
                    if matteSourceDepth == 0 {
                        insideMatteSource = false
                    }
                }
            default:
                break
            }
        }

        // Matte source (nm="matte_source") should NOT be in top-level layer groups
        let hasMatteSourceAtTopLevel = topLevelLayerGroupNames.contains { $0.contains("matte_source") }
        XCTAssertFalse(hasMatteSourceAtTopLevel, "Matte source layer should not be rendered at top level")
    }

    // MARK: - Command Structure Tests

    func testRenderCommands_startsWithRootGroup() throws {
        var ir = try compileIR(minimalLottieJSON, animRef: "my-anim.json")
        let commands = ir.renderCommands(frameIndex: 0)

        guard let firstCommand = commands.first else {
            XCTFail("No commands")
            return
        }

        if case .beginGroup(let name) = firstCommand {
            XCTAssertTrue(name.hasPrefix("AnimIR:"), "Root group should start with AnimIR:")
            XCTAssertTrue(name.contains("my-anim.json"), "Root group should contain animRef")
        } else {
            XCTFail("First command should be beginGroup")
        }
    }

    func testRenderCommands_endsWithEndGroup() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        guard let lastCommand = commands.last else {
            XCTFail("No commands")
            return
        }

        if case .endGroup = lastCommand {
            // OK
        } else {
            XCTFail("Last command should be endGroup")
        }
    }

    // MARK: - Determinism Tests

    func testRenderCommands_deterministic() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands1 = ir.renderCommands(frameIndex: 0)
        let commands2 = ir.renderCommands(frameIndex: 0)

        XCTAssertEqual(commands1.count, commands2.count)
        for (c1, c2) in zip(commands1, commands2) {
            XCTAssertEqual(c1, c2, "Commands should be identical")
        }
    }

    func testRenderCommands_differentFramesSameStructure() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands0 = ir.renderCommands(frameIndex: 0)
        let commands100 = ir.renderCommands(frameIndex: 100)

        // For static animations (no animated properties), structure should be same at all frames
        XCTAssertEqual(commands0.count, commands100.count, "Command count should be same at different frames for static anim")
        XCTAssertTrue(commands100.isBalanced())
    }

    // MARK: - DrawImage Tests

    func testRenderCommands_containsDrawImage() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        let hasDrawImage = commands.contains { cmd in
            if case .drawImage = cmd { return true }
            return false
        }
        XCTAssertTrue(hasDrawImage, "Should contain DrawImage command")
    }

    func testRenderCommands_drawImageHasCorrectAssetId() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        var foundAssetId: String?
        for command in commands {
            if case .drawImage(let assetId, _) = command {
                foundAssetId = assetId
                break
            }
        }

        // Asset ID is namespaced with animRef (default "test.json")
        XCTAssertEqual(foundAssetId, "test.json|image_0")
    }

    func testRenderCommands_drawImageOpacity_isComputed() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        var foundOpacity: Double?
        for command in commands {
            if case .drawImage(_, let opacity) = command {
                foundOpacity = opacity
                break
            }
        }

        // Opacity is now computed from transform track (100% in minimalLottie = 1.0)
        XCTAssertNotNil(foundOpacity)
        XCTAssertEqual(foundOpacity ?? 0, 1.0, accuracy: 0.001, "Opacity should be computed from transform")
    }

    // MARK: - PushTransform Tests

    func testRenderCommands_pushTransform_computedFromTrack() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        // For minimalLottie: position=(270,480), anchor=(270,480), scale=100%, rotation=0
        // Transform = T(p) * R(0) * S(1) * T(-a) = T(270,480) * I * I * T(-270,-480) = identity
        for command in commands {
            if case .pushTransform(let matrix) = command {
                // This specific test animation has identity transforms due to matching anchor/position
                XCTAssertEqual(matrix, .identity, "This static anim should have identity transforms")
            }
        }
    }

    // MARK: - Command Count Sanity

    func testRenderCommands_hasReasonableCommandCount() throws {
        var ir = try compileIR(minimalLottieJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        XCTAssertGreaterThan(commands.count, 5, "Should have meaningful number of commands")
        XCTAssertLessThan(commands.count, 1000, "Should not have unreasonable number of commands")
    }
}
