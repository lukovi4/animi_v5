import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// Tests for PR6: Nested precomp inheritance and transform propagation correctness
/// Verifies multi-level precomp transform multiplication, st mapping, visibility, masks, and cycle detection
final class NestedPrecompPropagationTests: XCTestCase {
    var compiler: AnimIRCompiler!
    private var _testRegistry = PathRegistry()

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    // MARK: - Helper

    private func loadAnimIR(_ animRef: String, subdirectory: String = "nested_precomp") throws -> AnimIR {
        let bundle = Bundle.module
        guard let url = bundle.url(
            forResource: animRef.replacingOccurrences(of: ".json", with: ""),
            withExtension: "json",
            subdirectory: subdirectory
        ) else {
            throw XCTSkip("Test resource \(animRef) not found in bundle")
        }

        let data = try Data(contentsOf: url)
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)

        let assetIndex = AssetIndex(byId: ["image_0": "images/img_nested.png"])

        // Compile with scene-level path registry
        var registry = PathRegistry()
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: animRef,
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &registry
        )
        return ir
    }

    private func getDrawImageOpacity(from commands: [RenderCommand]) -> Double? {
        for command in commands {
            if case .drawImage(_, let opacity) = command {
                return opacity
            }
        }
        return nil
    }

    private func hasDrawImage(_ commands: [RenderCommand]) -> Bool {
        commands.contains { cmd in
            if case .drawImage = cmd { return true }
            return false
        }
    }

    /// Simulates the transform stack to compute the effective matrix at DrawImage.
    /// This properly reflects how a renderer would execute the command stream.
    /// - pushTransform(m): current = current.concatenating(m), push to stack
    /// - popTransform: restore previous from stack
    /// - drawImage: capture current as effective matrix
    private func computeEffectiveMatrixAtDrawImage(_ commands: [RenderCommand]) -> Matrix2D? {
        var current = Matrix2D.identity
        var stack: [Matrix2D] = [.identity]

        for command in commands {
            switch command {
            case .pushTransform(let matrix):
                current = current.concatenating(matrix)
                stack.append(current)
            case .popTransform:
                stack.removeLast()
                current = stack.last ?? .identity
            case .drawImage:
                return current
            default:
                break
            }
        }
        return nil
    }

    // MARK: - Test 1: Nested Transform Multiplication

    /// Verifies that effective transform on stack is correctly computed as M_root * M_outer * M_image
    /// Uses transform stack simulation to verify NO double-transform bug.
    /// anim-nested-1.json has:
    /// - root precomp: position=(100,200), rotation=15°, scale=80%
    /// - outer precomp: position=(10,0), rotation=0, scale=100%
    /// - image layer: position=(0,0), rotation=45°, anchor=(50,50)
    func testNestedTransformMultiplication() throws {
        var ir = try loadAnimIR("anim-nested-1.json")
        let commands = ir.renderCommands(frameIndex: 30)

        // Compute effective matrix at DrawImage by simulating the transform stack
        // This catches double-transform bugs that "last push before draw" would miss
        guard let effectiveMatrix = computeEffectiveMatrixAtDrawImage(commands) else {
            XCTFail("No DrawImage found in commands")
            return
        }

        // The matrix should NOT be identity (all three layers have non-trivial transforms)
        XCTAssertNotEqual(effectiveMatrix, .identity, "Effective matrix should not be identity")

        // Compute expected matrix manually:
        // M_root = T(100,200) * R(15°) * S(0.8,0.8) * T(-0,-0)
        let mRoot = Matrix2D.translation(x: 100, y: 200)
            .concatenating(.rotationDegrees(15))
            .concatenating(.scale(x: 0.8, y: 0.8))

        // M_outer = T(10,0) * R(0) * S(1,1) * T(-0,-0) = T(10,0)
        let mOuter = Matrix2D.translation(x: 10, y: 0)

        // M_image = T(0,0) * R(45°) * S(1,1) * T(-50,-50)
        let mImage = Matrix2D.rotationDegrees(45)
            .concatenating(.translation(x: -50, y: -50))

        // Expected = M_root * M_outer * M_image (each layer's transform applied once)
        let expected = mRoot.concatenating(mOuter).concatenating(mImage)

        // Verify matrix components match (with epsilon for floating point)
        // This will FAIL if double-transform bug exists (M_root or M_outer applied twice)
        XCTAssertEqual(effectiveMatrix.a, expected.a, accuracy: 0.0001, "Matrix 'a' component mismatch")
        XCTAssertEqual(effectiveMatrix.b, expected.b, accuracy: 0.0001, "Matrix 'b' component mismatch")
        XCTAssertEqual(effectiveMatrix.c, expected.c, accuracy: 0.0001, "Matrix 'c' component mismatch")
        XCTAssertEqual(effectiveMatrix.d, expected.d, accuracy: 0.0001, "Matrix 'd' component mismatch")
        XCTAssertEqual(effectiveMatrix.tx, expected.tx, accuracy: 0.0001, "Matrix 'tx' component mismatch")
        XCTAssertEqual(effectiveMatrix.ty, expected.ty, accuracy: 0.0001, "Matrix 'ty' component mismatch")
    }

    // MARK: - Test 2: st Mapping on Two Levels

    /// Verifies that st offset is applied correctly at each nesting level
    /// anim-nested-1.json has:
    /// - root precomp st=10
    /// - outer precomp st=20
    /// - image layer has opacity animation 0→100 over frames 0..10
    /// At frameIndex=35: childFrame = 35-10-20 = 5, so opacity should be ~50%
    func testStMappingTwoLevels() throws {
        var ir = try loadAnimIR("anim-nested-1.json")
        let commands = ir.renderCommands(frameIndex: 35)

        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity, "DrawImage should be present")

        // At frameIndex=35, childFrame for inner = 35-10-20 = 5
        // Opacity animation: 0→100 over 0..10, so at frame 5 opacity = 50%
        XCTAssertEqual(opacity ?? 0, 0.5, accuracy: 0.05, "Opacity at frameIndex=35 should be ~0.5")
    }

    /// Verifies st mapping at the boundary: frameIndex=30 → childFrame = 0
    func testStMappingAtBoundary() throws {
        var ir = try loadAnimIR("anim-nested-1.json")
        let commands = ir.renderCommands(frameIndex: 30)

        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity, "DrawImage should be present at frameIndex=30")

        // At frameIndex=30, childFrame for inner = 30-10-20 = 0
        // Opacity animation starts at 0
        XCTAssertEqual(opacity ?? 1, 0.0, accuracy: 0.01, "Opacity at frameIndex=30 should be 0")
    }

    /// Verifies st mapping: frameIndex=40 → childFrame = 10 → opacity = 100%
    func testStMappingFullOpacity() throws {
        var ir = try loadAnimIR("anim-nested-1.json")
        let commands = ir.renderCommands(frameIndex: 40)

        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity, "DrawImage should be present at frameIndex=40")

        // At frameIndex=40, childFrame for inner = 40-10-20 = 10
        // Opacity animation ends at 100%
        XCTAssertEqual(opacity ?? 0, 1.0, accuracy: 0.01, "Opacity at frameIndex=40 should be 1.0")
    }

    // MARK: - Test 3: Visibility Cutoff on Container

    /// Verifies that when container precomp is not visible, entire subtree is not rendered
    /// anim-nested-1.json has root precomp with ip=30
    func testVisibilityCutoffOnContainer_beforeIp() throws {
        var ir = try loadAnimIR("anim-nested-1.json")

        // Frames 0-29 should have no DrawImage (ip=30)
        for frame in [0, 10, 20, 29] {
            let commands = ir.renderCommands(frameIndex: frame)
            XCTAssertFalse(
                hasDrawImage(commands),
                "Frame \(frame): DrawImage should NOT be present before ip=30"
            )
        }
    }

    func testVisibilityCutoffOnContainer_atIp() throws {
        var ir = try loadAnimIR("anim-nested-1.json")
        let commands = ir.renderCommands(frameIndex: 30)

        XCTAssertTrue(hasDrawImage(commands), "Frame 30: DrawImage SHOULD be present at ip=30")
    }

    func testVisibilityCutoffOnContainer_afterIp() throws {
        var ir = try loadAnimIR("anim-nested-1.json")

        for frame in [31, 50, 100, 119] {
            let commands = ir.renderCommands(frameIndex: frame)
            XCTAssertTrue(
                hasDrawImage(commands),
                "Frame \(frame): DrawImage should be present after ip=30"
            )
        }
    }

    // MARK: - Test 4: Mask on Precomp Wraps Subtree

    /// Verifies that mask on precomp layer wraps the entire subtree
    /// DrawImage should be between BeginMask and EndMask
    func testMaskOnPrecompWrapsSubtree() throws {
        var ir = try loadAnimIR("anim-nested-1.json")
        let commands = ir.renderCommands(frameIndex: 30)

        // Find indices of BeginMask (or legacy BeginMaskAdd), DrawImage, and EndMask
        var beginMaskIndex: Int?
        var drawImageIndex: Int?
        var endMaskIndex: Int?

        for (index, command) in commands.enumerated() {
            switch command {
            case .beginMask:
                if beginMaskIndex == nil { beginMaskIndex = index }
            case .drawImage:
                if drawImageIndex == nil { drawImageIndex = index }
            case .endMask:
                endMaskIndex = index // Take the last one
            default:
                break
            }
        }

        XCTAssertNotNil(beginMaskIndex, "BeginMask should be present")
        XCTAssertNotNil(drawImageIndex, "DrawImage should be present")
        XCTAssertNotNil(endMaskIndex, "EndMask should be present")

        if let begin = beginMaskIndex, let draw = drawImageIndex, let end = endMaskIndex {
            XCTAssertLessThan(begin, draw, "BeginMask should come before DrawImage")
            XCTAssertLessThan(draw, end, "DrawImage should come before EndMask")
        }
    }

    // MARK: - Test 5: Precomp Cycle Detection

    /// Verifies that precomp cycles are detected and reported without crashing
    /// anim-precomp-cycle.json has: root → comp_A → comp_B → comp_A (cycle)
    /// comp_A contains: image "media" (renders) + precomp to comp_B (triggers cycle)
    func testPrecompCycleDetection() throws {
        var ir = try loadAnimIR("anim-precomp-cycle.json")
        let commands = ir.renderCommands(frameIndex: 0)

        // Should not crash
        XCTAssertTrue(true, "renderCommands should not crash on cycle")

        // Should have PRECOMP_CYCLE issue
        let cycleIssues = ir.lastRenderIssues.filter { $0.code == RenderIssue.codePrecompCycle }
        XCTAssertFalse(cycleIssues.isEmpty, "PRECOMP_CYCLE issue should be reported")

        // DrawImage IS present because image layer in comp_A renders before the cycle is hit
        // The cycle is detected when comp_B tries to render comp_A again
        XCTAssertTrue(hasDrawImage(commands), "DrawImage should be present (renders before cycle)")

        // Verify issue has correct severity
        if let issue = cycleIssues.first {
            XCTAssertEqual(issue.severity, .error, "PRECOMP_CYCLE should have error severity")
            XCTAssertTrue(
                issue.message.contains("Cycle detected"),
                "Issue message should mention cycle"
            )
        }
    }

    // MARK: - Test 6: Precomp Asset Not Found

    /// Verifies that missing precomp asset is reported as an issue
    func testPrecompAssetNotFound() throws {
        // Create a minimal JSON with invalid refId
        let json = """
        {
          "v": "5.12.1", "fr": 30, "ip": 0, "op": 60, "w": 100, "h": 100,
          "nm": "test", "ddd": 0,
          "assets": [
            { "id": "image_0", "w": 100, "h": 100, "u": "", "p": "test.png", "e": 0 },
            {
              "id": "comp_valid",
              "nm": "valid",
              "fr": 30,
              "layers": [{
                "ddd": 0, "ind": 1, "ty": 2, "nm": "media", "refId": "image_0",
                "ks": {"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
                "ip": 0, "op": 60, "st": 0
              }]
            }
          ],
          "layers": [{
            "ddd": 0, "ind": 1, "ty": 0, "nm": "precomp", "refId": "comp_nonexistent",
            "ks": {"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
            "w": 100, "h": 100, "ip": 0, "op": 60, "st": 0
          }],
          "markers": []
        }
        """

        let data = json.data(using: .utf8)!
        _ = try JSONDecoder().decode(LottieJSON.self, from: data)

        // Need to find a valid binding layer - use comp_valid which has "media"
        // But since root layer refs comp_nonexistent, we need to adjust test
        // Let's create a test where the binding layer exists but a different precomp is missing

        let json2 = """
        {
          "v": "5.12.1", "fr": 30, "ip": 0, "op": 60, "w": 100, "h": 100,
          "nm": "test", "ddd": 0,
          "assets": [
            { "id": "image_0", "w": 100, "h": 100, "u": "", "p": "test.png", "e": 0 },
            {
              "id": "comp_with_media",
              "nm": "comp-media",
              "fr": 30,
              "layers": [
                {
                  "ddd": 0, "ind": 1, "ty": 2, "nm": "media", "refId": "image_0",
                  "ks": {"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
                  "ip": 0, "op": 60, "st": 0
                },
                {
                  "ddd": 0, "ind": 2, "ty": 0, "nm": "broken-ref", "refId": "comp_nonexistent",
                  "ks": {"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
                  "w": 100, "h": 100, "ip": 0, "op": 60, "st": 0
                }
              ]
            }
          ],
          "layers": [{
            "ddd": 0, "ind": 1, "ty": 0, "nm": "root-precomp", "refId": "comp_with_media",
            "ks": {"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
            "w": 100, "h": 100, "ip": 0, "op": 60, "st": 0
          }],
          "markers": []
        }
        """

        let data2 = json2.data(using: .utf8)!
        let lottie2 = try JSONDecoder().decode(LottieJSON.self, from: data2)

        let assetIndex = AssetIndex(byId: ["image_0": "test.png"])
        var ir = try compiler.compile(
            lottie: lottie2,
            animRef: "test-missing-precomp",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        _ = ir.renderCommands(frameIndex: 0)

        // Should have PRECOMP_ASSET_NOT_FOUND issue
        let notFoundIssues = ir.lastRenderIssues.filter {
            $0.code == RenderIssue.codePrecompAssetNotFound
        }
        XCTAssertFalse(notFoundIssues.isEmpty, "PRECOMP_ASSET_NOT_FOUND issue should be reported")

        if let issue = notFoundIssues.first {
            XCTAssertEqual(issue.severity, .error, "PRECOMP_ASSET_NOT_FOUND should have error severity")
            XCTAssertTrue(
                issue.message.contains("comp_nonexistent"),
                "Issue message should mention the missing compId"
            )
        }
    }

    // MARK: - Test 7: No Render Issues on Valid Nested Precomp

    /// Verifies that valid nested precomp produces no render issues
    func testNoRenderIssuesOnValidNestedPrecomp() throws {
        var ir = try loadAnimIR("anim-nested-1.json")

        for frame in [30, 35, 40, 50, 100] {
            _ = ir.renderCommands(frameIndex: frame)
            XCTAssertTrue(
                ir.lastRenderIssues.isEmpty,
                "Frame \(frame): Should have no render issues, got: \(ir.lastRenderIssues)"
            )
        }
    }

    // MARK: - Test 8: Commands Are Balanced

    /// Verifies that all begin/end commands are properly balanced
    func testCommandsAreBalanced() throws {
        var ir = try loadAnimIR("anim-nested-1.json")

        for frame in [30, 35, 50, 100] {
            let commands = ir.renderCommands(frameIndex: frame)
            XCTAssertTrue(
                commands.isBalanced(),
                "Frame \(frame): Commands should be balanced"
            )
        }
    }
}
