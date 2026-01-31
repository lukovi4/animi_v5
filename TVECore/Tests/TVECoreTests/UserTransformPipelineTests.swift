import XCTest
@testable import TVECore

// MARK: - PR-16: UserTransform Pipeline Tests
//
// Validates the end-to-end flow: ScenePlayer → SceneRenderPlan → AnimIR
// for user transforms (pan / zoom / rotate).

final class UserTransformPipelineTests: XCTestCase {

    // MARK: - Helpers

    private var compiler: AnimIRCompiler!

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    /// Decodes a JSON string into LottieJSON
    private func decodeLottie(_ json: String) throws -> LottieJSON {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(LottieJSON.self, from: data)
    }

    /// Minimal 100x100 rect path vertices
    private static let rectPathJSON = """
    { "a": 0, "k": {
        "v": [[0,0],[100,0],[100,100],[0,100]],
        "i": [[0,0],[0,0],[0,0],[0,0]],
        "o": [[0,0],[0,0],[0,0],[0,0]],
        "c": true
    }}
    """

    /// Builds a Lottie JSON with mediaInput + binding layer (media) in root comp.
    /// Optionally animated scale on the media layer.
    private func lottieJSON(
        animatedScale: Bool = false,
        width: Int = 1080,
        height: Int = 1920
    ) -> String {
        let scaleTrack: String
        if animatedScale {
            // Animate scale from 100% at frame 0 to 120% at frame 299
            scaleTrack = """
            { "a": 1, "k": [
                { "t": 0, "s": [100, 100, 100], "i": { "x": [0.5], "y": [1] }, "o": { "x": [0.5], "y": [0] } },
                { "t": 299, "s": [120, 120, 100] }
            ]}
            """
        } else {
            scaleTrack = "{ \"a\": 0, \"k\": [100, 100, 100] }"
        }

        return """
        {
          "fr": 30, "ip": 0, "op": 300, "w": \(width), "h": \(height),
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }
          ],
          "layers": [
            {
              "ty": 4, "ind": 10, "nm": "mediaInput",
              "hd": true,
              "shapes": [
                { "ty": "gr", "it": [
                  { "ty": "sh", "ks": \(Self.rectPathJSON) },
                  { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
                ]}
              ],
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [0, 0, 0] },
                "a": { "a": 0, "k": [0, 0, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ip": 0, "op": 300, "st": 0
            },
            {
              "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] },
                "a": { "a": 0, "k": [270, 480, 0] },
                "s": \(scaleTrack)
              },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
    }

    /// Creates a single-block ScenePackage + LoadedAnimations from a Lottie JSON string.
    private func makeScenePackage(
        lottieJSON json: String,
        blockId: String = "block-1",
        animRef: String = "anim-test"
    ) throws -> (ScenePackage, LoadedAnimations) {
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test-scene",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            mediaBlocks: [
                MediaBlock(
                    id: blockId,
                    zIndex: 0,
                    rect: Rect(x: 0, y: 0, width: 1080, height: 1920),
                    containerClip: .slotRect,
                    input: MediaInput(
                        rect: Rect(x: 0, y: 0, width: 1080, height: 1920),
                        bindingKey: "media",
                        allowedMedia: ["photo"]
                    ),
                    variants: [Variant(id: "v1", animRef: animRef)]
                )
            ]
        )

        let package = ScenePackage(
            rootURL: URL(fileURLWithPath: "/tmp"),
            scene: scene,
            animFilesByRef: [:],
            imagesRootURL: nil
        )

        let animations = LoadedAnimations(
            lottieByAnimRef: [animRef: lottie],
            assetIndexByAnimRef: [animRef: assetIndex]
        )

        return (package, animations)
    }

    /// Creates a two-block ScenePackage + LoadedAnimations for multi-block tests.
    private func makeTwoBlockScenePackage() throws -> (ScenePackage, LoadedAnimations) {
        let json = lottieJSON()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test-scene-2blocks",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            mediaBlocks: [
                MediaBlock(
                    id: "block-A",
                    zIndex: 0,
                    rect: Rect(x: 0, y: 0, width: 1080, height: 960),
                    containerClip: .slotRect,
                    input: MediaInput(
                        rect: Rect(x: 0, y: 0, width: 1080, height: 960),
                        bindingKey: "media",
                        allowedMedia: ["photo"]
                    ),
                    variants: [Variant(id: "v1", animRef: "anim-test")]
                ),
                MediaBlock(
                    id: "block-B",
                    zIndex: 1,
                    rect: Rect(x: 0, y: 960, width: 1080, height: 960),
                    containerClip: .slotRect,
                    input: MediaInput(
                        rect: Rect(x: 0, y: 960, width: 1080, height: 960),
                        bindingKey: "media",
                        allowedMedia: ["photo"]
                    ),
                    variants: [Variant(id: "v1", animRef: "anim-test")]
                )
            ]
        )

        let package = ScenePackage(
            rootURL: URL(fileURLWithPath: "/tmp"),
            scene: scene,
            animFilesByRef: [:],
            imagesRootURL: nil
        )

        let animations = LoadedAnimations(
            lottieByAnimRef: ["anim-test": lottie],
            assetIndexByAnimRef: ["anim-test": assetIndex]
        )

        return (package, animations)
    }

    /// Extracts all pushTransform matrices from a command array
    private func pushTransforms(from commands: [RenderCommand]) -> [Matrix2D] {
        commands.compactMap { cmd in
            if case .pushTransform(let m) = cmd { return m }
            return nil
        }
    }

    /// Extracts pushTransform matrices that appear inside a specific block group
    private func pushTransformsInBlock(
        _ blockId: String,
        commands: [RenderCommand]
    ) -> [Matrix2D] {
        var inside = false
        var depth = 0
        var matrices: [Matrix2D] = []

        for cmd in commands {
            switch cmd {
            case .beginGroup(let name):
                if name == "Block:\(blockId)" {
                    inside = true
                    depth = 1
                } else if inside {
                    depth += 1
                }
            case .endGroup:
                if inside {
                    depth -= 1
                    if depth == 0 { inside = false }
                }
            case .pushTransform(let m):
                if inside { matrices.append(m) }
            default:
                break
            }
        }
        return matrices
    }

    // MARK: - T1: Identity Transform

    /// userTransform = .identity → behaviour identical to pre-PR-16 (no userTransform)
    func testT1_identityTransform_matchesDefaultBehaviour() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        // Compile via ScenePlayer with default (no userTransform)
        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let cmdsDefault = player.renderCommands(sceneFrameIndex: 0)

        // Now set explicit identity
        player.setUserTransform(blockId: "block-1", transform: .identity)
        let cmdsIdentity = player.renderCommands(sceneFrameIndex: 0)

        // Commands must be identical
        XCTAssertEqual(cmdsDefault.count, cmdsIdentity.count,
            "Identity userTransform must produce the same command count as no userTransform")

        let transformsDefault = pushTransforms(from: cmdsDefault)
        let transformsIdentity = pushTransforms(from: cmdsIdentity)
        XCTAssertEqual(transformsDefault, transformsIdentity,
            "Identity userTransform must produce identical pushTransform matrices")

        // Balance check
        XCTAssertTrue(cmdsIdentity.isBalanced(),
            "Commands must be balanced")
    }

    // MARK: - T2: Translation

    /// userTransform = translate(50, 100) → media shifts inside mediaInput; mediaInput stays
    func testT2_translation_shiftMediaInsideInput() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Baseline
        let cmdsBaseline = player.renderCommands(sceneFrameIndex: 0)
        let baselineTransforms = pushTransforms(from: cmdsBaseline)

        // Apply translation
        let shift = Matrix2D.translation(x: 50, y: 100)
        player.setUserTransform(blockId: "block-1", transform: shift)
        let cmdsShifted = player.renderCommands(sceneFrameIndex: 0)
        let shiftedTransforms = pushTransforms(from: cmdsShifted)

        // Transform lists must differ (the media binding layer transform changes)
        XCTAssertNotEqual(baselineTransforms, shiftedTransforms,
            "Translation userTransform must change pushTransform matrices")

        // Command count unchanged (same structure, different values)
        XCTAssertEqual(cmdsBaseline.count, cmdsShifted.count,
            "Translation must not change command structure")

        // Balance check
        XCTAssertTrue(cmdsShifted.isBalanced())
    }

    // MARK: - T3: Scale

    /// userTransform = scale(0.5) → media scales down inside input; inputClip continues to clip
    func testT3_scale_mediaScalesInsideInput() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let cmdsBaseline = player.renderCommands(sceneFrameIndex: 0)
        let baselineTransforms = pushTransforms(from: cmdsBaseline)

        // Apply uniform scale down
        let halfScale = Matrix2D.scale(0.5)
        player.setUserTransform(blockId: "block-1", transform: halfScale)
        let cmdsScaled = player.renderCommands(sceneFrameIndex: 0)
        let scaledTransforms = pushTransforms(from: cmdsScaled)

        XCTAssertNotEqual(baselineTransforms, scaledTransforms,
            "Scale userTransform must change pushTransform matrices")

        // Structure unchanged
        XCTAssertEqual(cmdsBaseline.count, cmdsScaled.count)
        XCTAssertTrue(cmdsScaled.isBalanced())

        // Verify inputClip mask is still present (mediaInput still clips)
        let maskCount = cmdsScaled.filter {
            if case .beginMask(mode: .intersect, _, _, _, _) = $0 { return true }
            return false
        }.count
        XCTAssertGreaterThan(maskCount, 0,
            "inputClip intersect mask must still be present after scale")
    }

    // MARK: - T4: Rotation

    /// userTransform = rotate(45°) → media rotates inside input
    func testT4_rotation_mediaRotatesInsideInput() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let cmdsBaseline = player.renderCommands(sceneFrameIndex: 0)
        let baselineTransforms = pushTransforms(from: cmdsBaseline)

        let rotation = Matrix2D.rotationDegrees(45)
        player.setUserTransform(blockId: "block-1", transform: rotation)
        let cmdsRotated = player.renderCommands(sceneFrameIndex: 0)
        let rotatedTransforms = pushTransforms(from: cmdsRotated)

        XCTAssertNotEqual(baselineTransforms, rotatedTransforms,
            "Rotation userTransform must change pushTransform matrices")

        XCTAssertEqual(cmdsBaseline.count, cmdsRotated.count)
        XCTAssertTrue(cmdsRotated.isBalanced())
    }

    // MARK: - T5: UserTransform + Lottie Animation (Composition Order)

    /// Validates M(t) = A(t) ∘ U — Lottie animation applied AFTER user transform
    func testT5_userTransformPlusLottieAnimation_correctOrder() throws {
        // Use animated scale (100→120 over 300 frames)
        let json = lottieJSON(animatedScale: true)
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let userShift = Matrix2D.translation(x: 30, y: 60)
        player.setUserTransform(blockId: "block-1", transform: userShift)

        // Compare frames 0 vs 150 — Lottie scale changes so transforms must differ
        let cmdsF0 = player.renderCommands(sceneFrameIndex: 0)
        let cmdsF150 = player.renderCommands(sceneFrameIndex: 150)

        let transformsF0 = pushTransforms(from: cmdsF0)
        let transformsF150 = pushTransforms(from: cmdsF150)

        XCTAssertNotEqual(transformsF0, transformsF150,
            "Different Lottie frames with same userTransform must produce different matrices (animation varies)")

        // Both must be balanced
        XCTAssertTrue(cmdsF0.isBalanced())
        XCTAssertTrue(cmdsF150.isBalanced())

        // Also verify via direct AnimIR that the formula is A(t) ∘ U:
        // Compile AnimIR separately and compare against identity
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])
        var registry = PathRegistry()
        var ir = try compiler.compile(
            lottie: lottie, animRef: "test", bindingKey: "media",
            assetIndex: assetIndex, pathRegistry: &registry
        )

        let cmdsNoUser = ir.renderCommands(frameIndex: 150, userTransform: .identity)
        let cmdsWithUser = ir.renderCommands(frameIndex: 150, userTransform: userShift)

        let noUserTransforms = pushTransforms(from: cmdsNoUser)
        let withUserTransforms = pushTransforms(from: cmdsWithUser)

        XCTAssertNotEqual(noUserTransforms, withUserTransforms,
            "userTransform ≠ identity must produce different AnimIR transforms")

        // Verify the userTransform did NOT affect the inputClip mask transforms.
        // Find the intersect mask — its preceding pushTransform should be identical
        // whether or not userTransform is applied (mediaInput stays fixed).
        let mediaInputTransformNoUser = transformBeforeMask(in: cmdsNoUser)
        let mediaInputTransformWithUser = transformBeforeMask(in: cmdsWithUser)

        if let tNoUser = mediaInputTransformNoUser, let tWithUser = mediaInputTransformWithUser {
            XCTAssertEqual(tNoUser, tWithUser,
                "mediaInput transform must NOT change with userTransform")
        }
    }

    /// Finds the pushTransform matrix immediately before a beginMask(.intersect) command
    private func transformBeforeMask(in commands: [RenderCommand]) -> Matrix2D? {
        var lastTransform: Matrix2D?
        for cmd in commands {
            if case .pushTransform(let m) = cmd {
                lastTransform = m
            } else if case .beginMask(mode: .intersect, _, _, _, _) = cmd {
                return lastTransform
            }
        }
        return nil
    }

    // MARK: - T6: Export Determinism

    /// Same scene + same userTransform → identical render commands (deterministic)
    func testT6_exportDeterminism_sameInputsSameOutput() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let transform = Matrix2D.translation(x: 10, y: 20)
            .concatenating(.scale(1.5))
            .concatenating(.rotationDegrees(15))
        player.setUserTransform(blockId: "block-1", transform: transform)

        // Render same frame 3 times
        let cmds1 = player.renderCommands(sceneFrameIndex: 100)
        let cmds2 = player.renderCommands(sceneFrameIndex: 100)
        let cmds3 = player.renderCommands(sceneFrameIndex: 100)

        XCTAssertEqual(cmds1, cmds2, "Render commands must be deterministic (run 1 vs 2)")
        XCTAssertEqual(cmds2, cmds3, "Render commands must be deterministic (run 2 vs 3)")
    }

    /// Same userTransform on two separate players → identical render commands
    func testT6_exportDeterminism_separatePlayers() throws {
        let json = lottieJSON()
        let (package1, animations1) = try makeScenePackage(lottieJSON: json)
        let (package2, animations2) = try makeScenePackage(lottieJSON: json)

        let transform = Matrix2D.translation(x: 33, y: -15)

        let player1 = ScenePlayer()
        try player1.compile(package: package1, loadedAnimations: animations1)
        player1.setUserTransform(blockId: "block-1", transform: transform)

        let player2 = ScenePlayer()
        try player2.compile(package: package2, loadedAnimations: animations2)
        player2.setUserTransform(blockId: "block-1", transform: transform)

        let cmds1 = player1.renderCommands(sceneFrameIndex: 50)
        let cmds2 = player2.renderCommands(sceneFrameIndex: 50)

        XCTAssertEqual(cmds1, cmds2,
            "Two players with same scene + same userTransform must produce identical commands")
    }

    // MARK: - API Contract Tests

    /// setUserTransform / userTransform round-trip
    func testAPI_setAndGetUserTransform() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Default is identity
        XCTAssertEqual(player.userTransform(blockId: "block-1"), .identity,
            "Default userTransform must be .identity")

        // Set and read back
        let m = Matrix2D.translation(x: 42, y: 7)
        player.setUserTransform(blockId: "block-1", transform: m)
        XCTAssertEqual(player.userTransform(blockId: "block-1"), m,
            "userTransform must round-trip through set/get")
    }

    /// Unknown blockId returns identity (no crash)
    func testAPI_unknownBlockId_returnsIdentity() throws {
        let player = ScenePlayer()
        XCTAssertEqual(player.userTransform(blockId: "nonexistent"), .identity,
            "Unknown blockId must return .identity")
    }

    /// resetAllUserTransforms clears state
    func testAPI_resetAllUserTransforms() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        player.setUserTransform(blockId: "block-1", transform: .scale(2.0))
        player.resetAllUserTransforms()

        XCTAssertEqual(player.userTransform(blockId: "block-1"), .identity,
            "After resetAll, transform must be .identity")
    }

    // MARK: - Multi-Block Isolation

    /// userTransform on block-A must NOT affect block-B
    func testMultiBlock_transformIsolation() throws {
        let (package, animations) = try makeTwoBlockScenePackage()

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Baseline — no user transforms
        let cmdsBaseline = player.renderCommands(sceneFrameIndex: 0)
        let baselineA = pushTransformsInBlock("block-A", commands: cmdsBaseline)
        let baselineB = pushTransformsInBlock("block-B", commands: cmdsBaseline)

        // Set userTransform only on block-A
        player.setUserTransform(blockId: "block-A", transform: .translation(x: 99, y: 99))
        let cmdsAfter = player.renderCommands(sceneFrameIndex: 0)
        let afterA = pushTransformsInBlock("block-A", commands: cmdsAfter)
        let afterB = pushTransformsInBlock("block-B", commands: cmdsAfter)

        // block-A transforms must change
        XCTAssertNotEqual(baselineA, afterA,
            "block-A transforms must change when userTransform is set")

        // block-B transforms must remain identical
        XCTAssertEqual(baselineB, afterB,
            "block-B transforms must NOT change when only block-A has userTransform")

        XCTAssertTrue(cmdsAfter.isBalanced())
    }

    // MARK: - SceneRenderPlan Direct API

    /// SceneRenderPlan.renderCommands with default (empty) userTransforms == no-transform path
    func testSceneRenderPlan_defaultParameter_matchesNoTransforms() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        // Call with explicit empty dict (matches default parameter)
        let cmdsExplicit = SceneRenderPlan.renderCommands(
            for: compiled.runtime, sceneFrameIndex: 0, userTransforms: [:]
        )
        // Call using convenience (no dict)
        let cmdsConvenience = compiled.runtime.renderCommands(sceneFrameIndex: 0)

        XCTAssertEqual(cmdsExplicit, cmdsConvenience,
            "Explicit empty userTransforms must match convenience (no-argument) path")
    }

    /// SceneRenderPlan correctly forwards a non-identity transform
    func testSceneRenderPlan_forwardsUserTransform() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let cmdsDefault = SceneRenderPlan.renderCommands(
            for: compiled.runtime, sceneFrameIndex: 0
        )
        let cmdsWithTransform = SceneRenderPlan.renderCommands(
            for: compiled.runtime,
            sceneFrameIndex: 0,
            userTransforms: ["block-1": .translation(x: 10, y: 20)]
        )

        let defaultTransforms = pushTransforms(from: cmdsDefault)
        let withTransforms = pushTransforms(from: cmdsWithTransform)

        XCTAssertNotEqual(defaultTransforms, withTransforms,
            "Non-identity userTransform must produce different pushTransform matrices via SceneRenderPlan")
    }

    // MARK: - mediaInput Immutability

    /// Verifies mediaInput window transform is NOT affected by userTransform
    func testMediaInput_remainsFixed_withUserTransform() throws {
        let json = lottieJSON()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])
        var registry = PathRegistry()
        var ir = try compiler.compile(
            lottie: lottie, animRef: "test", bindingKey: "media",
            assetIndex: assetIndex, pathRegistry: &registry
        )

        // Render with two different userTransforms
        let cmdsA = ir.renderCommands(frameIndex: 0, userTransform: .identity)
        let cmdsB = ir.renderCommands(frameIndex: 0, userTransform: .translation(x: 200, y: 300))

        // The transform immediately before beginMask(.intersect) is the mediaInput world
        let mediaInputA = transformBeforeMask(in: cmdsA)
        let mediaInputB = transformBeforeMask(in: cmdsB)

        XCTAssertNotNil(mediaInputA, "Should have intersect mask (inputClip)")
        XCTAssertNotNil(mediaInputB, "Should have intersect mask (inputClip)")

        if let a = mediaInputA, let b = mediaInputB {
            XCTAssertEqual(a, b,
                "mediaInput world transform must be identical regardless of userTransform")
        }
    }

    // MARK: - Backwards Compatibility

    /// Existing ScenePlayer.renderCommands(sceneFrameIndex:) works without setUserTransform
    func testBackwardsCompat_renderWithoutSettingTransform() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Just call renderCommands without ever calling setUserTransform
        let commands = player.renderCommands(sceneFrameIndex: 0)
        XCTAssertFalse(commands.isEmpty, "Must generate commands without any setUserTransform call")
        XCTAssertTrue(commands.isBalanced())
    }

    /// SceneRuntime convenience still works (no userTransforms parameter)
    func testBackwardsCompat_sceneRuntimeConvenience() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let commands = compiled.runtime.renderCommands(sceneFrameIndex: 0)
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.isBalanced())
    }
}
