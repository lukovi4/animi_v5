import XCTest
@testable import TVECore

/// Tests for PR-B: MaskMode extension and RenderCommand.beginMask
final class MaskModeCommandTests: XCTestCase {
    var compiler: AnimIRCompiler!

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    // MARK: - MaskMode Tests

    func testMaskMode_rawValues() {
        XCTAssertEqual(MaskMode.add.rawValue, "a")
        XCTAssertEqual(MaskMode.subtract.rawValue, "s")
        XCTAssertEqual(MaskMode.intersect.rawValue, "i")
    }

    func testMaskMode_initFromRawValue() {
        XCTAssertEqual(MaskMode(rawValue: "a"), .add)
        XCTAssertEqual(MaskMode(rawValue: "s"), .subtract)
        XCTAssertEqual(MaskMode(rawValue: "i"), .intersect)
        XCTAssertNil(MaskMode(rawValue: "x"))  // unknown mode
        XCTAssertNil(MaskMode(rawValue: ""))   // empty
    }

    // MARK: - RenderCommand.beginMask Tests

    func testBeginMask_isBeginCommand() {
        let cmd = RenderCommand.beginMask(
            mode: .add,
            inverted: false,
            pathId: PathID(1),
            opacity: 1.0,
            frame: 0
        )
        XCTAssertTrue(cmd.isBeginCommand)
        XCTAssertFalse(cmd.isEndCommand)
    }

    func testBeginMask_matchingEndCommand() {
        let cmd = RenderCommand.beginMask(
            mode: .subtract,
            inverted: true,
            pathId: PathID(42),
            opacity: 0.5,
            frame: 10
        )
        XCTAssertEqual(cmd.matchingEndCommand, .endMask)
    }

    func testBeginMask_debugDescription() {
        let cmd = RenderCommand.beginMask(
            mode: .intersect,
            inverted: true,
            pathId: PathID(99),
            opacity: 0.75,
            frame: 5.5
        )
        let desc = cmd.debugDescription
        XCTAssertTrue(desc.contains("BeginMask"))
        XCTAssertTrue(desc.contains("mode:i"))
        XCTAssertTrue(desc.contains("inv:true"))
        XCTAssertTrue(desc.contains("pathId:99"))
    }

    // MARK: - Balance Tests

    func testBeginMask_balanceWithEndMask() {
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask
        ]
        XCTAssertTrue(commands.isBalanced())
    }

    func testBeginMask_nestedBalanced() {
        // Simulates reversed emission: M2 → M1 → M0 → content → end × 3
        let commands: [RenderCommand] = [
            .beginMask(mode: .intersect, inverted: false, pathId: PathID(3), opacity: 1.0, frame: 0),
            .beginMask(mode: .subtract, inverted: true, pathId: PathID(2), opacity: 0.5, frame: 0),
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 0.8, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .endMask,
            .endMask
        ]
        XCTAssertTrue(commands.isBalanced())
    }

    func testMixedMaskCommands_balanced() {
        // Two beginMask commands (both add mode)
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .beginMask(mode: .add, inverted: false, pathId: PathID(2), opacity: 0.5, frame: 0),
            .endMask,
            .endMask
        ]
        XCTAssertTrue(commands.isBalanced())
    }

    // MARK: - commandCounts Tests

    func testCommandCounts_includesBeginMask() {
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .beginMask(mode: .subtract, inverted: true, pathId: PathID(2), opacity: 0.5, frame: 0),
            .endMask,
            .endMask
        ]
        let counts = commands.commandCounts()
        XCTAssertEqual(counts["beginMask"], 2)
        XCTAssertEqual(counts["endMask"], 2)
    }

    // MARK: - hasMaskCommands Tests

    func testHasMaskCommands_withBeginMask() {
        let commands: [RenderCommand] = [
            .beginGroup(name: "test"),
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .endMask,
            .endGroup
        ]
        XCTAssertTrue(commands.hasMaskCommands)
    }

    func testHasMaskCommands_withoutMask() {
        let commands: [RenderCommand] = [
            .beginGroup(name: "test"),
            .drawImage(assetId: "test", opacity: 1.0),
            .endGroup
        ]
        XCTAssertFalse(commands.hasMaskCommands)
    }

    // MARK: - Lottie JSON Test Data

    /// Lottie with single add mask (on non-binding layer; separate "media" layer is binding)
    private let lottieWithAddMaskJSON = """
    {
      "v": "5.12.1", "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920, "nm": "Test",
      "assets": [{ "id": "img", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
      "layers": [
        {
          "ind": 1, "ty": 2, "nm": "masked_layer", "refId": "img",
          "ks": { "o": {"a":0,"k":100}, "r": {"a":0,"k":0}, "p": {"a":0,"k":[270,480,0]}, "a": {"a":0,"k":[270,480,0]}, "s": {"a":0,"k":[100,100,100]} },
          "hasMask": true,
          "masksProperties": [{
            "inv": false, "mode": "a",
            "pt": { "a": 0, "k": { "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]], "v": [[0,0],[540,0],[540,960],[0,960]], "c": true } },
            "o": { "a": 0, "k": 80 }
          }],
          "ip": 0, "op": 300, "st": 0
        },
        {
          "ind": 99, "ty": 2, "nm": "media", "refId": "img",
          "ks": { "o": {"a":0,"k":100}, "r": {"a":0,"k":0}, "p": {"a":0,"k":[0,0,0]}, "a": {"a":0,"k":[0,0,0]}, "s": {"a":0,"k":[100,100,100]} },
          "ip": 0, "op": 300, "st": 0
        }
      ]
    }
    """

    /// Lottie with subtract mask (inverted, on non-binding layer)
    private let lottieWithSubtractMaskJSON = """
    {
      "v": "5.12.1", "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920, "nm": "Test",
      "assets": [{ "id": "img", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
      "layers": [
        {
          "ind": 1, "ty": 2, "nm": "masked_layer", "refId": "img",
          "ks": { "o": {"a":0,"k":100}, "r": {"a":0,"k":0}, "p": {"a":0,"k":[270,480,0]}, "a": {"a":0,"k":[270,480,0]}, "s": {"a":0,"k":[100,100,100]} },
          "hasMask": true,
          "masksProperties": [{
            "inv": true, "mode": "s",
            "pt": { "a": 0, "k": { "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]], "v": [[100,100],[200,100],[200,200],[100,200]], "c": true } },
            "o": { "a": 0, "k": 50 }
          }],
          "ip": 0, "op": 300, "st": 0
        },
        {
          "ind": 99, "ty": 2, "nm": "media", "refId": "img",
          "ks": { "o": {"a":0,"k":100}, "r": {"a":0,"k":0}, "p": {"a":0,"k":[0,0,0]}, "a": {"a":0,"k":[0,0,0]}, "s": {"a":0,"k":[100,100,100]} },
          "ip": 0, "op": 300, "st": 0
        }
      ]
    }
    """

    /// Lottie with multiple masks (add, subtract, intersect) on non-binding layer
    private let lottieWithMultipleMasksJSON = """
    {
      "v": "5.12.1", "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920, "nm": "Test",
      "assets": [{ "id": "img", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
      "layers": [
        {
          "ind": 1, "ty": 2, "nm": "masked_layer", "refId": "img",
          "ks": { "o": {"a":0,"k":100}, "r": {"a":0,"k":0}, "p": {"a":0,"k":[270,480,0]}, "a": {"a":0,"k":[270,480,0]}, "s": {"a":0,"k":[100,100,100]} },
          "hasMask": true,
          "masksProperties": [
            { "inv": false, "mode": "a", "pt": { "a": 0, "k": { "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]], "v": [[0,0],[100,0],[100,100],[0,100]], "c": true } }, "o": { "a": 0, "k": 100 } },
            { "inv": true, "mode": "s", "pt": { "a": 0, "k": { "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]], "v": [[50,50],[150,50],[150,150],[50,150]], "c": true } }, "o": { "a": 0, "k": 75 } },
            { "inv": false, "mode": "i", "pt": { "a": 0, "k": { "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]], "v": [[25,25],[125,25],[125,125],[25,125]], "c": true } }, "o": { "a": 0, "k": 60 } }
          ],
          "ip": 0, "op": 300, "st": 0
        },
        {
          "ind": 99, "ty": 2, "nm": "media", "refId": "img",
          "ks": { "o": {"a":0,"k":100}, "r": {"a":0,"k":0}, "p": {"a":0,"k":[0,0,0]}, "a": {"a":0,"k":[0,0,0]}, "s": {"a":0,"k":[100,100,100]} },
          "ip": 0, "op": 300, "st": 0
        }
      ]
    }
    """

    private func compileIR(_ json: String) throws -> AnimIR {
        let data = json.data(using: .utf8)!
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)
        let assetIndex = AssetIndex(byId: ["img": "images/img.png"])
        var registry = PathRegistry()
        return try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &registry
        )
    }

    // MARK: - AnimIR Emission Tests

    func testAnimIR_emitsBeginMaskWithMode() throws {
        var ir = try compileIR(lottieWithAddMaskJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        let maskCmd = commands.first { cmd in
            if case .beginMask = cmd { return true }
            return false
        }
        XCTAssertNotNil(maskCmd, "Should emit beginMask command")

        if case .beginMask(let mode, let inverted, _, let opacity, _) = maskCmd! {
            XCTAssertEqual(mode, .add)
            XCTAssertFalse(inverted)
            XCTAssertEqual(opacity, 0.8, accuracy: 0.001)  // 80/100
        } else {
            XCTFail("Expected beginMask command")
        }
    }

    func testAnimIR_emitsSubtractMaskWithInverted() throws {
        var ir = try compileIR(lottieWithSubtractMaskJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        let maskCmd = commands.first { cmd in
            if case .beginMask = cmd { return true }
            return false
        }
        XCTAssertNotNil(maskCmd, "Should emit beginMask command")

        if case .beginMask(let mode, let inverted, _, let opacity, _) = maskCmd! {
            XCTAssertEqual(mode, .subtract)
            XCTAssertTrue(inverted)
            XCTAssertEqual(opacity, 0.5, accuracy: 0.001)  // 50/100
        } else {
            XCTFail("Expected beginMask command")
        }
    }

    func testAnimIR_emitsMasksInReversedOrder() throws {
        var ir = try compileIR(lottieWithMultipleMasksJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        // Extract beginMask commands in order of emission
        var maskCommands: [(mode: MaskMode, inverted: Bool, opacity: Double)] = []
        for cmd in commands {
            if case .beginMask(let mode, let inverted, _, let opacity, _) = cmd {
                maskCommands.append((mode, inverted, opacity))
            }
        }

        // Original order in JSON: [add, subtract, intersect]
        // Reversed emission order: [intersect, subtract, add]
        XCTAssertEqual(maskCommands.count, 3, "Should have 3 mask commands")

        // First emitted (outermost): intersect
        XCTAssertEqual(maskCommands[0].mode, .intersect)
        XCTAssertFalse(maskCommands[0].inverted)
        XCTAssertEqual(maskCommands[0].opacity, 0.6, accuracy: 0.001)

        // Second: subtract (inverted)
        XCTAssertEqual(maskCommands[1].mode, .subtract)
        XCTAssertTrue(maskCommands[1].inverted)
        XCTAssertEqual(maskCommands[1].opacity, 0.75, accuracy: 0.001)

        // Third (innermost): add
        XCTAssertEqual(maskCommands[2].mode, .add)
        XCTAssertFalse(maskCommands[2].inverted)
        XCTAssertEqual(maskCommands[2].opacity, 1.0, accuracy: 0.001)
    }

    func testAnimIR_maskCommandsBalanced() throws {
        var ir = try compileIR(lottieWithMultipleMasksJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        XCTAssertTrue(commands.isBalanced())

        let counts = commands.commandCounts()
        XCTAssertEqual(counts["beginMask"], counts["endMask"])
    }

    func testAnimIR_noMaskNormalization() throws {
        // PR-B should NOT normalize modes - just pass through honestly
        var ir = try compileIR(lottieWithMultipleMasksJSON)
        let commands = ir.renderCommands(frameIndex: 0)

        // Verify all three modes are present
        var modes: [MaskMode] = []
        for cmd in commands {
            if case .beginMask(let mode, _, _, _, _) = cmd {
                modes.append(mode)
            }
        }

        XCTAssertTrue(modes.contains(.add))
        XCTAssertTrue(modes.contains(.subtract))
        XCTAssertTrue(modes.contains(.intersect))
    }

    // MARK: - Compiler Error Tests (Fix 1)

    /// Lottie with unknown mask mode "x" - should fail compilation
    private let lottieWithUnknownMaskModeJSON = """
    {
      "v": "5.12.1", "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920, "nm": "Test",
      "assets": [{ "id": "img", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
      "layers": [{
        "ind": 1, "ty": 2, "nm": "media", "refId": "img",
        "ks": { "o": {"a":0,"k":100}, "r": {"a":0,"k":0}, "p": {"a":0,"k":[270,480,0]}, "a": {"a":0,"k":[270,480,0]}, "s": {"a":0,"k":[100,100,100]} },
        "hasMask": true,
        "masksProperties": [{
          "inv": false, "mode": "x",
          "pt": { "a": 0, "k": { "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]], "v": [[0,0],[100,0],[100,100],[0,100]], "c": true } },
          "o": { "a": 0, "k": 100 }
        }],
        "ip": 0, "op": 300, "st": 0
      }]
    }
    """

    func testCompiler_unknownMaskMode_throwsError() throws {
        let data = lottieWithUnknownMaskModeJSON.data(using: .utf8)!
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)
        let assetIndex = AssetIndex(byId: ["img": "images/img.png"])
        var registry = PathRegistry()

        do {
            _ = try compiler.compile(
                lottie: lottie,
                animRef: "test.json",
                bindingKey: "media",
                assetIndex: assetIndex,
                pathRegistry: &registry
            )
            XCTFail("Should throw error for unknown mask mode")
        } catch let error as UnsupportedFeature {
            XCTAssertEqual(error.code, "UNSUPPORTED_MASK_MODE")
            XCTAssertTrue(error.message.contains("x"), "Error should mention the unknown mode")
            XCTAssertTrue(error.path.contains("mask[0]"), "Error should mention mask index")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testCompiler_nilMaskMode_throwsError() throws {
        // Lottie with nil mask mode (mode key missing)
        let lottieWithNilMaskModeJSON = """
        {
          "v": "5.12.1", "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920, "nm": "Test",
          "assets": [{ "id": "img", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
          "layers": [{
            "ind": 1, "ty": 2, "nm": "media", "refId": "img",
            "ks": { "o": {"a":0,"k":100}, "r": {"a":0,"k":0}, "p": {"a":0,"k":[270,480,0]}, "a": {"a":0,"k":[270,480,0]}, "s": {"a":0,"k":[100,100,100]} },
            "hasMask": true,
            "masksProperties": [{
              "inv": false,
              "pt": { "a": 0, "k": { "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]], "v": [[0,0],[100,0],[100,100],[0,100]], "c": true } },
              "o": { "a": 0, "k": 100 }
            }],
            "ip": 0, "op": 300, "st": 0
          }]
        }
        """

        let data = lottieWithNilMaskModeJSON.data(using: .utf8)!
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)
        let assetIndex = AssetIndex(byId: ["img": "images/img.png"])
        var registry = PathRegistry()

        do {
            _ = try compiler.compile(
                lottie: lottie,
                animRef: "test.json",
                bindingKey: "media",
                assetIndex: assetIndex,
                pathRegistry: &registry
            )
            XCTFail("Should throw error for nil mask mode")
        } catch let error as UnsupportedFeature {
            XCTAssertEqual(error.code, "UNSUPPORTED_MASK_MODE")
            XCTAssertTrue(error.message.contains("nil"), "Error should mention nil mode")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
