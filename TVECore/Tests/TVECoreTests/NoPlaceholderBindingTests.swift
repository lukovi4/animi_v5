import XCTest
@testable import TVECore

/// PR-28: Integration tests for No-Placeholder Binding behavior.
///
/// Verifies:
/// - `bindingLayerVisible: false` suppresses binding layer drawImage
/// - `bindingLayerVisible: true` renders binding layer normally
/// - Non-binding layers are always rendered regardless of binding visibility
/// - ScenePlayer `setUserMediaPresent` controls binding visibility through SceneRenderPlan
/// - Default `userMediaPresent` (empty) hides all binding layers
/// - Commands remain balanced in all cases
final class NoPlaceholderBindingTests: XCTestCase {

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

    private func decodeLottie(_ json: String) throws -> LottieJSON {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(LottieJSON.self, from: data)
    }

    /// Lottie with a binding layer (image_0, nm="media") + a non-binding decoration layer (image_1).
    private func twoLayerLottieJSON() -> String {
        """
        {
          "fr": 30, "ip": 0, "op": 60, "w": 540, "h": 960,
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "photo.png", "e": 0 },
            { "id": "image_1", "w": 540, "h": 960, "u": "images/", "p": "decoration.png", "e": 0 }
          ],
          "layers": [
            {
              "ty": 4, "ind": 10, "nm": "mediaInput", "hd": true,
              "shapes": [
                { "ty": "gr", "it": [
                  { "ty": "sh", "ks": { "a": 0, "k": {
                    "v": [[0,0],[540,0],[540,960],[0,960]],
                    "i": [[0,0],[0,0],[0,0],[0,0]],
                    "o": [[0,0],[0,0],[0,0],[0,0]],
                    "c": true
                  }}},
                  { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
                ]}
              ],
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                "s": { "a": 0, "k": [100,100,100] }
              },
              "ip": 0, "op": 60, "st": 0
            },
            {
              "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                "s": { "a": 0, "k": [100,100,100] }
              },
              "ip": 0, "op": 60, "st": 0
            },
            {
              "ty": 2, "ind": 2, "nm": "decoration", "refId": "image_1",
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                "s": { "a": 0, "k": [100,100,100] }
              },
              "ip": 0, "op": 60, "st": 0
            }
          ]
        }
        """
    }

    /// Compiles a two-layer Lottie into AnimIR.
    private func compileTwoLayerIR() throws -> AnimIR {
        let json = twoLayerLottieJSON()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: [
            "image_0": "images/photo.png",
            "image_1": "images/decoration.png"
        ])
        var registry = PathRegistry()
        return try compiler.compile(
            lottie: lottie, animRef: "test-anim", bindingKey: "media",
            assetIndex: assetIndex, pathRegistry: &registry
        )
    }

    /// Extracts drawImage asset IDs from render commands.
    private func drawImageAssetIds(from commands: [RenderCommand]) -> [String] {
        commands.compactMap { cmd in
            if case .drawImage(let assetId, _) = cmd { return assetId }
            return nil
        }
    }

    // MARK: - AnimIR level: bindingLayerVisible

    func testBindingLayerVisible_true_emitsBindingDrawImage() throws {
        var ir = try compileTwoLayerIR()

        let commands = ir.renderCommands(frameIndex: 0, bindingLayerVisible: true)
        let assetIds = drawImageAssetIds(from: commands)

        XCTAssertTrue(assetIds.contains("test-anim|image_0"),
            "Binding layer image should appear when bindingLayerVisible=true. Got: \(assetIds)")
        XCTAssertTrue(assetIds.contains("test-anim|image_1"),
            "Decoration layer should always appear. Got: \(assetIds)")
        XCTAssertTrue(commands.isBalanced())
    }

    func testBindingLayerVisible_false_suppressesBindingDrawImage() throws {
        var ir = try compileTwoLayerIR()

        let commands = ir.renderCommands(frameIndex: 0, bindingLayerVisible: false)
        let assetIds = drawImageAssetIds(from: commands)

        XCTAssertFalse(assetIds.contains("test-anim|image_0"),
            "Binding layer image should NOT appear when bindingLayerVisible=false. Got: \(assetIds)")
        XCTAssertTrue(assetIds.contains("test-anim|image_1"),
            "Non-binding decoration layer must still render. Got: \(assetIds)")
        XCTAssertTrue(commands.isBalanced())
    }

    func testBindingLayerVisible_default_isTrue() throws {
        var ir = try compileTwoLayerIR()

        // Default parameter = true (backward compat)
        let commands = ir.renderCommands(frameIndex: 0)
        let assetIds = drawImageAssetIds(from: commands)

        XCTAssertTrue(assetIds.contains("test-anim|image_0"),
            "Default bindingLayerVisible must be true for backward compatibility")
    }

    func testBindingLayerVisible_false_commandCountReduced() throws {
        var ir = try compileTwoLayerIR()

        let commandsVisible = ir.renderCommands(frameIndex: 0, bindingLayerVisible: true)
        let commandsHidden = ir.renderCommands(frameIndex: 0, bindingLayerVisible: false)

        XCTAssertGreaterThan(commandsVisible.count, commandsHidden.count,
            "Hiding binding layer should produce fewer render commands")
    }

    // MARK: - SceneRenderPlan level: userMediaPresent

    func testSceneRenderPlan_userMediaPresentTrue_showsBinding() throws {
        let (package, animations) = try makeSingleBlockPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let commands = SceneRenderPlan.renderCommands(
            for: compiled.runtime,
            sceneFrameIndex: 0,
            userMediaPresent: ["block-1": true]
        )

        let assetIds = drawImageAssetIds(from: commands)
        XCTAssertTrue(assetIds.contains("test-anim|image_0"),
            "userMediaPresent=true should show binding layer")
        XCTAssertTrue(commands.isBalanced())
    }

    func testSceneRenderPlan_userMediaPresentFalse_hidesBinding() throws {
        let (package, animations) = try makeSingleBlockPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let commands = SceneRenderPlan.renderCommands(
            for: compiled.runtime,
            sceneFrameIndex: 0,
            userMediaPresent: ["block-1": false]
        )

        let assetIds = drawImageAssetIds(from: commands)
        XCTAssertFalse(assetIds.contains("test-anim|image_0"),
            "userMediaPresent=false should hide binding layer. Got: \(assetIds)")
        XCTAssertTrue(commands.isBalanced())
    }

    func testSceneRenderPlan_missingKey_defaultsFalse() throws {
        let (package, animations) = try makeSingleBlockPackage()
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        // Empty dict — block-1 not present → defaults to false
        let commands = SceneRenderPlan.renderCommands(
            for: compiled.runtime,
            sceneFrameIndex: 0,
            userMediaPresent: [:]
        )

        let assetIds = drawImageAssetIds(from: commands)
        XCTAssertFalse(assetIds.contains("test-anim|image_0"),
            "Missing key should default to false (binding hidden)")
    }

    // MARK: - ScenePlayer level: setUserMediaPresent API

    func testScenePlayer_setUserMediaPresent_controlsBinding() throws {
        let (package, animations) = try makeSingleBlockPackage()
        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Initially no media — binding hidden
        let cmdsHidden = player.renderCommands(sceneFrameIndex: 0)
        let hiddenAssets = drawImageAssetIds(from: cmdsHidden)
        XCTAssertFalse(hiddenAssets.contains("test-anim|image_0"),
            "Before setUserMediaPresent, binding should be hidden")

        // Set media present
        player.setUserMediaPresent(blockId: "block-1", present: true)
        let cmdsVisible = player.renderCommands(sceneFrameIndex: 0)
        let visibleAssets = drawImageAssetIds(from: cmdsVisible)
        XCTAssertTrue(visibleAssets.contains("test-anim|image_0"),
            "After setUserMediaPresent(true), binding should render")

        // Remove media
        player.setUserMediaPresent(blockId: "block-1", present: false)
        let cmdsHiddenAgain = player.renderCommands(sceneFrameIndex: 0)
        let hiddenAgainAssets = drawImageAssetIds(from: cmdsHiddenAgain)
        XCTAssertFalse(hiddenAgainAssets.contains("test-anim|image_0"),
            "After setUserMediaPresent(false), binding should be hidden again")
    }

    func testScenePlayer_isUserMediaPresent_queryAPI() throws {
        let (package, animations) = try makeSingleBlockPackage()
        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        XCTAssertFalse(player.isUserMediaPresent(blockId: "block-1"),
            "Default should be false")

        player.setUserMediaPresent(blockId: "block-1", present: true)
        XCTAssertTrue(player.isUserMediaPresent(blockId: "block-1"))

        player.setUserMediaPresent(blockId: "block-1", present: false)
        XCTAssertFalse(player.isUserMediaPresent(blockId: "block-1"))
    }

    func testScenePlayer_nonBindingLayersAlwaysRender() throws {
        let (package, animations) = try makeSingleBlockPackage()
        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Without media — decoration layer still renders
        let cmds = player.renderCommands(sceneFrameIndex: 0)
        let assetIds = drawImageAssetIds(from: cmds)
        XCTAssertTrue(assetIds.contains("test-anim|image_1"),
            "Non-binding decoration layer must always render regardless of userMediaPresent")
    }

    // MARK: - Balance & determinism

    func testCommands_balanced_withAndWithoutBinding() throws {
        var ir = try compileTwoLayerIR()

        let cmdsTrue = ir.renderCommands(frameIndex: 0, bindingLayerVisible: true)
        let cmdsFalse = ir.renderCommands(frameIndex: 0, bindingLayerVisible: false)

        XCTAssertTrue(cmdsTrue.isBalanced(), "Commands with binding visible must be balanced")
        XCTAssertTrue(cmdsFalse.isBalanced(), "Commands with binding hidden must be balanced")
    }

    func testDeterminism_sameBindingVisibility() throws {
        var ir = try compileTwoLayerIR()

        let cmds1 = ir.renderCommands(frameIndex: 0, bindingLayerVisible: false)
        let cmds2 = ir.renderCommands(frameIndex: 0, bindingLayerVisible: false)

        XCTAssertEqual(cmds1.count, cmds2.count, "Same parameters must produce same command count")
        XCTAssertEqual(
            drawImageAssetIds(from: cmds1),
            drawImageAssetIds(from: cmds2),
            "Asset IDs must be deterministic"
        )
    }

    // MARK: - Package helpers

    private func makeSingleBlockPackage(
        blockId: String = "block-1",
        animRef: String = "test-anim"
    ) throws -> (ScenePackage, LoadedAnimations) {
        let json = twoLayerLottieJSON()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: [
            "image_0": "images/photo.png",
            "image_1": "images/decoration.png"
        ])

        let noAnimRef = "no-anim-test"

        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test-scene",
            canvas: Canvas(width: 540, height: 960, fps: 30, durationFrames: 60),
            mediaBlocks: [
                MediaBlock(
                    id: blockId,
                    zIndex: 0,
                    rect: Rect(x: 0, y: 0, width: 540, height: 960),
                    containerClip: .slotRect,
                    input: MediaInput(
                        rect: Rect(x: 0, y: 0, width: 540, height: 960),
                        bindingKey: "media",
                        allowedMedia: ["photo"]
                    ),
                    variants: [
                        Variant(id: "v1", animRef: animRef),
                        Variant(id: "no-anim", animRef: noAnimRef)
                    ]
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
            lottieByAnimRef: [
                animRef: lottie,
                noAnimRef: lottie
            ],
            assetIndexByAnimRef: [
                animRef: assetIndex,
                noAnimRef: assetIndex
            ]
        )

        return (package, animations)
    }
}
