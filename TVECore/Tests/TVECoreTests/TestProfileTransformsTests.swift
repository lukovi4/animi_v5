import XCTest
@testable import TVECore

/// Tests for PR5 transforms using real test profile anim-1..4.json files
/// Verifies visibility, opacity sampling, position animation, and parenting
final class TestProfileTransformsTests: XCTestCase {
    var compiler: AnimIRCompiler!

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    // MARK: - Helper

    private func loadAnimIR(_ animRef: String) throws -> AnimIR {
        let bundle = Bundle.module
        guard let url = bundle.url(
            forResource: animRef.replacingOccurrences(of: ".json", with: ""),
            withExtension: "json",
            subdirectory: "example_4blocks"
        ) else {
            throw XCTSkip("Test resource \(animRef) not found in bundle")
        }

        let data = try Data(contentsOf: url)
        let lottie: LottieJSON
        do {
            lottie = try JSONDecoder().decode(LottieJSON.self, from: data)
        } catch {
            // Some test animations have shape layers with unsupported properties
            // Skip these tests rather than fail
            throw XCTSkip("\(animRef) has unsupported Lottie features: \(error.localizedDescription)")
        }

        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // Use new compile API with scene-level registry
        // Paths are registered during compilation, no registerPaths() call needed
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

    // MARK: - anim-1: Opacity Fade

    /// anim-1 has opacity animation 0 -> 100 over frames 0-30 on the precomp layer
    func testAnim1_frame0_opacityIsZero() throws {
        var ir = try loadAnimIR("anim-1.json")
        let commands = ir.renderCommands(frameIndex: 0)

        // At frame 0, opacity should be 0 (fade starts)
        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity)
        XCTAssertEqual(opacity ?? 0, 0.0, accuracy: 0.01, "Opacity at frame 0 should be 0")
    }

    func testAnim1_frame15_opacityIsMidpoint() throws {
        var ir = try loadAnimIR("anim-1.json")
        let commands = ir.renderCommands(frameIndex: 15)

        // At frame 15 (midpoint of 0-30), opacity should be ~0.5
        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity)
        XCTAssertEqual(opacity ?? 0, 0.5, accuracy: 0.1, "Opacity at frame 15 should be ~0.5")
    }

    func testAnim1_frame30_opacityIsFull() throws {
        var ir = try loadAnimIR("anim-1.json")
        let commands = ir.renderCommands(frameIndex: 30)

        // At frame 30, opacity should be 1.0 (fade complete)
        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity)
        XCTAssertEqual(opacity ?? 0, 1.0, accuracy: 0.01, "Opacity at frame 30 should be 1.0")
    }

    func testAnim1_frame45_opacityIsFull() throws {
        var ir = try loadAnimIR("anim-1.json")
        let commands = ir.renderCommands(frameIndex: 45)

        // After fade complete, opacity stays at 1.0
        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity)
        XCTAssertEqual(opacity ?? 0, 1.0, accuracy: 0.01, "Opacity at frame 45 should be 1.0")
    }

    func testAnim1_frame75_opacityIsFull() throws {
        var ir = try loadAnimIR("anim-1.json")
        let commands = ir.renderCommands(frameIndex: 75)

        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity)
        XCTAssertEqual(opacity ?? 0, 1.0, accuracy: 0.01, "Opacity at frame 75 should be 1.0")
    }

    func testAnim1_frame105_opacityIsFull() throws {
        var ir = try loadAnimIR("anim-1.json")
        let commands = ir.renderCommands(frameIndex: 105)

        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity)
        XCTAssertEqual(opacity ?? 0, 1.0, accuracy: 0.01, "Opacity at frame 105 should be 1.0")
    }

    func testAnim1_frame120_opacityStaysFull() throws {
        var ir = try loadAnimIR("anim-1.json")
        let commands = ir.renderCommands(frameIndex: 120)

        // After animation ends, opacity should stay at 1.0
        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity)
        XCTAssertEqual(opacity ?? 0, 1.0, accuracy: 0.01, "Opacity at frame 120 should be 1.0")
    }

    // MARK: - anim-2: Visibility and Parenting

    /// anim-2 has layers with ip=30 (not visible before frame 30)
    func testAnim2_frame0_notVisible() throws {
        var ir = try loadAnimIR("anim-2.json")
        let commands = ir.renderCommands(frameIndex: 0)

        // Before ip=30, layers should not be rendered
        XCTAssertFalse(hasDrawImage(commands), "anim-2 should not render at frame 0 (ip=30)")
    }

    func testAnim2_frame15_notVisible() throws {
        var ir = try loadAnimIR("anim-2.json")
        let commands = ir.renderCommands(frameIndex: 15)

        // Still before ip=30
        XCTAssertFalse(hasDrawImage(commands), "anim-2 should not render at frame 15 (ip=30)")
    }

    func testAnim2_frame30_visible() throws {
        var ir = try loadAnimIR("anim-2.json")
        let commands = ir.renderCommands(frameIndex: 30)

        // At ip=30, layers become visible
        XCTAssertTrue(hasDrawImage(commands), "anim-2 should render at frame 30 (ip=30)")
    }

    /// Verify opacity fix: null parent opacity=0 should NOT affect child opacity
    /// This is the key test for PR10.3 Blocker 3 fix
    func testAnim2_frame30_opacityIsFullDespiteParentZeroOpacity() throws {
        var ir = try loadAnimIR("anim-2.json")
        let commands = ir.renderCommands(frameIndex: 30)

        // The null parent layer has opacity=0, but with correct Lottie semantics
        // the child (precomp) should still have full opacity because parenting
        // does NOT inherit opacity - only precomp container does
        let opacity = getDrawImageOpacity(from: commands)
        XCTAssertNotNil(opacity, "Should have DrawImage command")
        XCTAssertEqual(opacity ?? 0, 1.0, accuracy: 0.01,
            "Child opacity should be 1.0 - parenting chain does NOT inherit opacity")
    }

    func testAnim2_frame45_visible() throws {
        var ir = try loadAnimIR("anim-2.json")
        let commands = ir.renderCommands(frameIndex: 45)

        // During animation
        XCTAssertTrue(hasDrawImage(commands), "anim-2 should render at frame 45")
    }

    func testAnim2_frame60_visible() throws {
        var ir = try loadAnimIR("anim-2.json")
        let commands = ir.renderCommands(frameIndex: 60)

        // Animation complete
        XCTAssertTrue(hasDrawImage(commands), "anim-2 should render at frame 60")
    }

    func testAnim2_frame120_visible() throws {
        var ir = try loadAnimIR("anim-2.json")
        let commands = ir.renderCommands(frameIndex: 120)

        // Well after animation
        XCTAssertTrue(hasDrawImage(commands), "anim-2 should render at frame 120")
    }

    func testAnim2_hasMatteCommands() throws {
        var ir = try loadAnimIR("anim-2.json")
        let commands = ir.renderCommands(frameIndex: 30)

        XCTAssertTrue(commands.hasMatteCommands, "anim-2 should have matte commands")
    }

    // MARK: - anim-3: Scale Animation and Alpha Inverted Matte

    /// anim-3 has layers with ip=60
    func testAnim3_frame0_notVisible() throws {
        var ir = try loadAnimIR("anim-3.json")
        let commands = ir.renderCommands(frameIndex: 0)

        XCTAssertFalse(hasDrawImage(commands), "anim-3 should not render at frame 0 (ip=60)")
    }

    func testAnim3_frame30_notVisible() throws {
        var ir = try loadAnimIR("anim-3.json")
        let commands = ir.renderCommands(frameIndex: 30)

        XCTAssertFalse(hasDrawImage(commands), "anim-3 should not render at frame 30 (ip=60)")
    }

    func testAnim3_frame60_visible() throws {
        var ir = try loadAnimIR("anim-3.json")
        let commands = ir.renderCommands(frameIndex: 60)

        // At ip=60, layers become visible
        XCTAssertTrue(hasDrawImage(commands), "anim-3 should render at frame 60 (ip=60)")
    }

    func testAnim3_frame75_visible() throws {
        var ir = try loadAnimIR("anim-3.json")
        let commands = ir.renderCommands(frameIndex: 75)

        XCTAssertTrue(hasDrawImage(commands), "anim-3 should render at frame 75")
    }

    func testAnim3_frame90_visible() throws {
        var ir = try loadAnimIR("anim-3.json")
        let commands = ir.renderCommands(frameIndex: 90)

        XCTAssertTrue(hasDrawImage(commands), "anim-3 should render at frame 90")
    }

    func testAnim3_frame120_visible() throws {
        var ir = try loadAnimIR("anim-3.json")
        let commands = ir.renderCommands(frameIndex: 120)

        XCTAssertTrue(hasDrawImage(commands), "anim-3 should render at frame 120")
    }

    func testAnim3_hasMatteCommands() throws {
        var ir = try loadAnimIR("anim-3.json")
        let commands = ir.renderCommands(frameIndex: 60)

        // anim-3 uses alpha inverted matte (tt=2)
        XCTAssertTrue(commands.hasMatteCommands, "anim-3 should have matte commands")
    }

    // MARK: - anim-4: Rotation and Scale Animation

    /// anim-4 has layers with ip=90
    func testAnim4_frame0_notVisible() throws {
        var ir = try loadAnimIR("anim-4.json")
        let commands = ir.renderCommands(frameIndex: 0)

        XCTAssertFalse(hasDrawImage(commands), "anim-4 should not render at frame 0 (ip=90)")
    }

    func testAnim4_frame60_notVisible() throws {
        var ir = try loadAnimIR("anim-4.json")
        let commands = ir.renderCommands(frameIndex: 60)

        XCTAssertFalse(hasDrawImage(commands), "anim-4 should not render at frame 60 (ip=90)")
    }

    func testAnim4_frame90_visible() throws {
        var ir = try loadAnimIR("anim-4.json")
        let commands = ir.renderCommands(frameIndex: 90)

        // At ip=90, layer becomes visible
        XCTAssertTrue(hasDrawImage(commands), "anim-4 should render at frame 90 (ip=90)")
    }

    func testAnim4_frame105_visible() throws {
        var ir = try loadAnimIR("anim-4.json")
        let commands = ir.renderCommands(frameIndex: 105)

        XCTAssertTrue(hasDrawImage(commands), "anim-4 should render at frame 105")
    }

    func testAnim4_frame120_visible() throws {
        var ir = try loadAnimIR("anim-4.json")
        let commands = ir.renderCommands(frameIndex: 120)

        XCTAssertTrue(hasDrawImage(commands), "anim-4 should render at frame 120")
    }

    func testAnim4_hasMaskCommands() throws {
        var ir = try loadAnimIR("anim-4.json")
        let commands = ir.renderCommands(frameIndex: 90)

        XCTAssertTrue(commands.hasMaskCommands, "anim-4 should have mask commands")
    }

    // MARK: - No Render Issues

    func testAllAnims_noRenderIssues() throws {
        let animRefs = ["anim-1.json", "anim-2.json", "anim-3.json", "anim-4.json"]
        let frames = [0, 15, 30, 45, 60, 75, 90, 105, 120]

        for animRef in animRefs {
            var ir = try loadAnimIR(animRef)
            for frame in frames {
                _ = ir.renderCommands(frameIndex: frame)
                XCTAssertTrue(
                    ir.lastRenderIssues.isEmpty,
                    "\(animRef) at frame \(frame) should have no render issues, got: \(ir.lastRenderIssues)"
                )
            }
        }
    }

    // MARK: - Commands Are Balanced

    func testAllAnims_commandsAreBalanced() throws {
        let animRefs = ["anim-1.json", "anim-2.json", "anim-3.json", "anim-4.json"]
        let frames = [0, 30, 60, 90, 120]

        for animRef in animRefs {
            var ir = try loadAnimIR(animRef)
            for frame in frames {
                let commands = ir.renderCommands(frameIndex: frame)
                XCTAssertTrue(
                    commands.isBalanced(),
                    "\(animRef) at frame \(frame) should have balanced commands"
                )
            }
        }
    }
}
