import XCTest
@testable import TVECore

/// Template Modes — Preview vs Edit (no-anim refactor)
///
/// Tests:
/// - T1: Preview renders full scene (all blocks, all layers)
/// - T2: Edit renders full no-anim variant (not binding-only)
/// - T3: Edit ignores sceneFrameIndex (time frozen at editFrameIndex = 0)
/// - T4: Edit uses no-anim variant override
/// - T5: Determinism — two players produce identical output
/// - T6: Compilation errors for missing no-anim / mediaInput / binding / visibility
/// - T7: Edit overlays/hitTest use no-anim variant
final class TemplateModeTests: XCTestCase {

    // MARK: - Test Resources

    private var testPackageURL: URL {
        Bundle.module.url(
            forResource: "scene",
            withExtension: "json",
            subdirectory: "Resources/example_4blocks"
        )!.deletingLastPathComponent()
    }

    private func loadTestPackage() throws -> (ScenePackage, LoadedAnimations) {
        let loader = ScenePackageLoader()
        let package = try loader.load(from: testPackageURL)

        let animLoader = AnimLoader()
        let animations = try animLoader.loadAnimations(from: package)

        return (package, animations)
    }

    private func compiledPlayer() throws -> ScenePlayer {
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        _ = try player.compile(package: package, loadedAnimations: animations)
        return player
    }

    /// Number of blocks visible at the given frame (computed from runtime, not hardcoded).
    private func visibleBlockCount(player: ScenePlayer, at frame: Int) -> Int {
        guard let runtime = player.compiledScene?.runtime else { return 0 }
        return runtime.blocks.filter { $0.timing.isVisible(at: frame) }.count
    }

    // MARK: - T1: Preview renders full scene

    /// T1: Preview mode at frame 120 renders all visible blocks with full content.
    func testT1_previewRendersFullScene() throws {
        let player = try compiledPlayer()
        let expectedBlocks = visibleBlockCount(player: player, at: 120)

        let commands = player.renderCommands(mode: .preview, sceneFrameIndex: 120)

        let drawImageCount = commands.filter {
            if case .drawImage = $0 { return true }
            return false
        }.count
        XCTAssertGreaterThanOrEqual(drawImageCount, expectedBlocks,
            "Preview at frame 120 should have at least \(expectedBlocks) drawImage commands")

        XCTAssertTrue(commands.isBalanced(),
            "Preview commands should be balanced (matching begin/end pairs)")

        let blockGroupCount = commands.filter {
            if case .beginGroup(let name) = $0 { return name.hasPrefix("Block:") }
            return false
        }.count
        XCTAssertEqual(blockGroupCount, expectedBlocks,
            "Preview should have \(expectedBlocks) block groups")
    }

    /// T1b: Preview mode matches existing renderCommands API (backward compatibility).
    func testT1b_previewMatchesLegacyAPI() throws {
        let player = try compiledPlayer()

        let previewCommands = player.renderCommands(mode: .preview, sceneFrameIndex: 120)
        let legacyCommands = player.renderCommands(sceneFrameIndex: 120)

        XCTAssertEqual(previewCommands.count, legacyCommands.count,
            "Preview mode should produce same command count as legacy API")

        for (idx, previewCmd) in previewCommands.enumerated() {
            XCTAssertEqual(previewCmd, legacyCommands[idx],
                "Commands should match at index \(idx)")
        }
    }

    // MARK: - T2: Edit renders full no-anim variant

    /// T2: Edit mode renders the full no-anim variant — not just binding layers.
    func testT2_editRendersFullNoAnimVariant() throws {
        let player = try compiledPlayer()
        let editFrame = ScenePlayer.editFrameIndex
        let visibleAtEditFrame = visibleBlockCount(player: player, at: editFrame)

        let editCommands = player.renderCommands(mode: .edit)

        XCTAssertTrue(editCommands.isBalanced(),
            "Edit commands should be balanced")

        // Block groups should exist for each visible block
        let blockGroupCount = editCommands.filter {
            if case .beginGroup(let name) = $0 { return name.hasPrefix("Block:") }
            return false
        }.count
        XCTAssertEqual(blockGroupCount, visibleAtEditFrame,
            "Edit should have \(visibleAtEditFrame) block groups")

        // At least one drawImage per visible block (binding layer in no-anim)
        let drawImageCount = editCommands.filter {
            if case .drawImage = $0 { return true }
            return false
        }.count
        XCTAssertGreaterThanOrEqual(drawImageCount, visibleAtEditFrame,
            "Edit mode should produce at least \(visibleAtEditFrame) drawImage commands")
    }

    /// T2b: Edit uses inputClip from no-anim variant (mediaInput → inputClip mask).
    func testT2b_editUsesInputClip() throws {
        let player = try compiledPlayer()

        let editCommands = player.renderCommands(mode: .edit)

        // no-anim variants have mediaInput → inputClip should produce intersect masks
        let inputClipGroups = editCommands.filter {
            if case .beginGroup(let name) = $0 { return name.contains("(inputClip)") }
            return false
        }.count

        let visibleAtEdit = visibleBlockCount(player: player, at: ScenePlayer.editFrameIndex)
        XCTAssertEqual(inputClipGroups, visibleAtEdit,
            "Edit should have inputClip group for each visible block (has mediaInput)")
    }

    // MARK: - T3: Edit ignores sceneFrameIndex

    /// T3: Edit mode always renders at editFrameIndex (0), regardless of sceneFrameIndex.
    func testT3_editIgnoresSceneFrameIndex() throws {
        let player = try compiledPlayer()

        let editAt0 = player.renderCommands(mode: .edit, sceneFrameIndex: 0)
        let editAt50 = player.renderCommands(mode: .edit, sceneFrameIndex: 50)
        let editAt150 = player.renderCommands(mode: .edit, sceneFrameIndex: 150)

        XCTAssertEqual(editAt0.count, editAt50.count,
            "Edit at frame 0 and frame 50 should have same command count")
        XCTAssertEqual(editAt0.count, editAt150.count,
            "Edit at frame 0 and frame 150 should have same command count")

        for (idx, cmd0) in editAt0.enumerated() {
            XCTAssertEqual(cmd0, editAt50[idx],
                "Edit commands should be identical regardless of sceneFrameIndex (index \(idx))")
            XCTAssertEqual(cmd0, editAt150[idx],
                "Edit commands should be identical regardless of sceneFrameIndex (index \(idx))")
        }
    }

    /// T3b: Verify editFrameIndex constant is 0.
    func testT3b_editFrameIndexIsZero() {
        XCTAssertEqual(ScenePlayer.editFrameIndex, 0,
            "Canonical editFrameIndex should be 0")
    }

    // MARK: - T4: Edit uses no-anim variant override

    /// T4: Edit uses no-anim variant regardless of user's variant selection.
    func testT4_editUsesNoAnimRegardlessOfSelection() throws {
        let player = try compiledPlayer()

        // Select animated variant v1 for first block
        player.setSelectedVariant(blockId: "block_01", variantId: "v1")

        // Edit should still render no-anim (not affected by selection)
        let editCommands = player.renderCommands(mode: .edit)
        XCTAssertTrue(editCommands.isBalanced(), "Edit commands should be balanced")
        XCTAssertFalse(editCommands.isEmpty, "Edit should produce commands")

        // Verify editVariantId is "no-anim" for all blocks
        guard let runtime = player.compiledScene?.runtime else {
            XCTFail("Should have compiled runtime")
            return
        }
        for block in runtime.blocks {
            XCTAssertEqual(block.editVariantId, "no-anim",
                "Block \(block.blockId) editVariantId should be 'no-anim'")
        }
    }

    /// T4b: Edit drawImage asset IDs are a subset of all compiled assets.
    func testT4b_editAssetsAreSubsetOfCompiled() throws {
        let player = try compiledPlayer()

        let editCommands = player.renderCommands(mode: .edit)

        let editAssetIds = Set(editCommands.compactMap { cmd -> String? in
            if case .drawImage(let assetId, _) = cmd { return assetId }
            return nil
        })

        // All edit asset IDs should be in the compiled asset index
        guard let mergedAssets = player.compiledScene?.mergedAssetIndex else {
            XCTFail("Should have compiled assets")
            return
        }
        for assetId in editAssetIds {
            XCTAssertNotNil(mergedAssets.byId[assetId],
                "Edit asset '\(assetId)' should exist in merged asset index")
        }
    }

    // MARK: - T5: Determinism

    /// T5: Two independent ScenePlayer instances produce identical edit commands.
    func testT5_determinism_twoPlayersIdenticalOutput() throws {
        let (package, animations) = try loadTestPackage()
        let player1 = ScenePlayer()
        let player2 = ScenePlayer()
        _ = try player1.compile(package: package, loadedAnimations: animations)
        _ = try player2.compile(package: package, loadedAnimations: animations)

        let editCommands1 = player1.renderCommands(mode: .edit)
        let editCommands2 = player2.renderCommands(mode: .edit)

        XCTAssertEqual(editCommands1.count, editCommands2.count,
            "Two players should produce same edit command count")
        for (idx, cmd1) in editCommands1.enumerated() {
            XCTAssertEqual(cmd1, editCommands2[idx],
                "Edit commands should be identical between two players at index \(idx)")
        }
    }

    /// T5b: Determinism in preview mode — two players produce identical output.
    func testT5b_determinism_previewIdentical() throws {
        let (package, animations) = try loadTestPackage()
        let player1 = ScenePlayer()
        let player2 = ScenePlayer()
        _ = try player1.compile(package: package, loadedAnimations: animations)
        _ = try player2.compile(package: package, loadedAnimations: animations)

        let previewCommands1 = player1.renderCommands(mode: .preview, sceneFrameIndex: 60)
        let previewCommands2 = player2.renderCommands(mode: .preview, sceneFrameIndex: 60)

        XCTAssertEqual(previewCommands1.count, previewCommands2.count,
            "Two players should produce same preview command count")
        for (idx, cmd1) in previewCommands1.enumerated() {
            XCTAssertEqual(cmd1, previewCommands2[idx],
                "Preview commands should be identical between two players at index \(idx)")
        }
    }

    // MARK: - T6: Compilation errors

    /// T6a: Missing no-anim variant triggers compilation error.
    func testT6a_missingNoAnimVariantThrows() throws {
        let (package, animations) = try loadTestPackage()

        // Reconstruct block_01 without its no-anim variant
        let originalBlock = package.scene.mediaBlocks[0]
        let strippedBlock = MediaBlock(
            id: originalBlock.id,
            zIndex: originalBlock.zIndex,
            rect: originalBlock.rect,
            containerClip: originalBlock.containerClip,
            timing: originalBlock.timing,
            input: originalBlock.input,
            variants: originalBlock.variants.filter { $0.id != "no-anim" }
        )

        var modifiedBlocks = package.scene.mediaBlocks
        modifiedBlocks[0] = strippedBlock

        let modifiedScene = Scene(
            schemaVersion: package.scene.schemaVersion,
            sceneId: package.scene.sceneId,
            canvas: package.scene.canvas,
            background: package.scene.background,
            mediaBlocks: modifiedBlocks
        )
        let modifiedPackage = ScenePackage(
            rootURL: package.rootURL,
            scene: modifiedScene,
            animFilesByRef: package.animFilesByRef,
            imagesRootURL: package.imagesRootURL
        )

        let player = ScenePlayer()
        XCTAssertThrowsError(try player.compile(package: modifiedPackage, loadedAnimations: animations)) { error in
            guard let sceneError = error as? ScenePlayerError else {
                XCTFail("Expected ScenePlayerError, got \(error)")
                return
            }
            if case .missingNoAnimVariant(let blockId) = sceneError {
                XCTAssertEqual(blockId, "block_01")
            } else {
                XCTFail("Expected missingNoAnimVariant, got \(sceneError)")
            }
        }
    }

    /// T6b: Binding layer visible but unreachable (precomp container ip=10) triggers error.
    func testT6b_unreachableBindingThrows() throws {
        // no-anim Lottie: binding is inside comp_0, but precomp container in root has ip=10
        // → binding layer itself is visible at frame 0, but full render skips the precomp
        let unreachableNoAnimJSON = """
        {
          "v": "5.12.1", "fr": 30, "ip": 0, "op": 30, "w": 540, "h": 960,
          "nm": "no-anim-unreachable", "ddd": 0,
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img_1.png", "e": 0 },
            {
              "id": "comp_0", "nm": "media_comp", "fr": 30,
              "layers": [
                {
                  "ddd": 0, "ind": 1, "ty": 4, "nm": "mediaInput", "hd": true,
                  "ks": {
                    "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                    "p": { "a": 0, "k": [0, 0, 0] }, "a": { "a": 0, "k": [0, 0, 0] },
                    "s": { "a": 0, "k": [100, 100, 100] }
                  },
                  "shapes": [{ "ty": "gr", "it": [
                    { "ty": "sh", "ks": { "a": 0, "k": {
                      "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]],
                      "v": [[0,0],[540,0],[540,960],[0,960]], "c": true
                    }}},
                    { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
                  ]}],
                  "ip": 0, "op": 300, "st": 0
                },
                {
                  "ddd": 0, "ind": 2, "ty": 2, "nm": "media", "refId": "image_0",
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
              "ddd": 0, "ind": 1, "ty": 0, "nm": "media_comp", "refId": "comp_0",
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] }, "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "w": 540, "h": 960,
              "ip": 10, "op": 300, "st": 0
            }
          ],
          "markers": [], "props": {}
        }
        """

        // Normal no-anim for v1 (binding in root comp, always reachable)
        let goodNoAnimJSON = """
        {
          "v": "5.12.1", "fr": 30, "ip": 0, "op": 1, "w": 540, "h": 960,
          "nm": "good-no-anim", "ddd": 0,
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img_1.png", "e": 0 }
          ],
          "layers": [
            {
              "ddd": 0, "ind": 1, "ty": 4, "nm": "mediaInput", "hd": true,
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [0, 0, 0] }, "a": { "a": 0, "k": [0, 0, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "shapes": [{ "ty": "gr", "it": [
                { "ty": "sh", "ks": { "a": 0, "k": {
                  "i": [[0,0],[0,0],[0,0],[0,0]], "o": [[0,0],[0,0],[0,0],[0,0]],
                  "v": [[0,0],[540,0],[540,960],[0,960]], "c": true
                }}},
                { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
              ]}],
              "ip": 0, "op": 1, "st": 0
            },
            {
              "ddd": 0, "ind": 2, "ty": 2, "nm": "media", "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] }, "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ip": 0, "op": 1, "st": 0
            }
          ],
          "markers": [], "props": {}
        }
        """

        let decoder = JSONDecoder()
        let unreachableLottie = try decoder.decode(LottieJSON.self, from: unreachableNoAnimJSON.data(using: .utf8)!)
        let goodLottie = try decoder.decode(LottieJSON.self, from: goodNoAnimJSON.data(using: .utf8)!)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test-unreachable",
            canvas: Canvas(width: 540, height: 960, fps: 30, durationFrames: 300),
            mediaBlocks: [
                MediaBlock(
                    id: "block-test",
                    zIndex: 0,
                    rect: Rect(x: 0, y: 0, width: 540, height: 960),
                    containerClip: .slotRect,
                    input: MediaInput(
                        rect: Rect(x: 0, y: 0, width: 540, height: 960),
                        bindingKey: "media",
                        allowedMedia: ["photo"]
                    ),
                    variants: [
                        Variant(id: "v1", animRef: "good.json"),
                        Variant(id: "no-anim", animRef: "unreachable.json")
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
                "good.json": goodLottie,
                "unreachable.json": unreachableLottie
            ],
            assetIndexByAnimRef: [
                "good.json": assetIndex,
                "unreachable.json": assetIndex
            ]
        )

        let player = ScenePlayer()
        XCTAssertThrowsError(try player.compile(package: package, loadedAnimations: animations)) { error in
            guard let sceneError = error as? ScenePlayerError else {
                XCTFail("Expected ScenePlayerError, got \(error)")
                return
            }
            if case .noAnimBindingNotRenderedAtEditFrame(let blockId, let animRef, let editFrameIndex) = sceneError {
                XCTAssertEqual(blockId, "block-test")
                XCTAssertEqual(animRef, "unreachable.json")
                XCTAssertEqual(editFrameIndex, 0)
            } else {
                XCTFail("Expected noAnimBindingNotRenderedAtEditFrame, got \(sceneError)")
            }
        }
    }

    // MARK: - T7: Edit overlays/hitTest use no-anim

    /// T7: Overlays in edit mode resolve from no-anim variant.
    func testT7_editOverlaysUseNoAnimVariant() throws {
        let player = try compiledPlayer()

        let editOverlays = player.overlays(frame: ScenePlayer.editFrameIndex, mode: .edit)
        let visibleAtEdit = visibleBlockCount(player: player, at: ScenePlayer.editFrameIndex)

        XCTAssertEqual(editOverlays.count, visibleAtEdit,
            "Edit overlays should have one entry per visible block")

        for overlay in editOverlays {
            XCTAssertFalse(overlay.hitPath.vertices.isEmpty,
                "Overlay for \(overlay.blockId) should have non-empty hit path")
        }
    }

    // MARK: - Additional: UserTransform in edit mode

    /// UserTransform API works in edit mode.
    func testEditMode_userTransformAPI() throws {
        let player = try compiledPlayer()
        guard let firstBlock = player.compiledScene?.runtime.blocks.first else {
            XCTFail("Should have at least one block")
            return
        }

        let transform = Matrix2D(a: 1.5, b: 0, c: 0, d: 1.5, tx: 10, ty: 20)
        player.setUserTransform(blockId: firstBlock.blockId, transform: transform)

        let editCommands = player.renderCommands(mode: .edit)

        XCTAssertTrue(editCommands.isBalanced(), "Edit with user transform should be balanced")
        XCTAssertFalse(editCommands.isEmpty, "Edit with user transform should produce commands")

        let storedTransform = player.userTransform(blockId: firstBlock.blockId)
        XCTAssertEqual(storedTransform, transform, "Stored transform should match set value")

        player.resetAllUserTransforms()
        let resetTransform = player.userTransform(blockId: firstBlock.blockId)
        XCTAssertEqual(resetTransform, .identity, "After reset, transform should be identity")
    }

    // MARK: - Additional: TemplateMode enum

    /// Verify TemplateMode raw values match expected strings.
    func testTemplateModeRawValues() {
        XCTAssertEqual(TemplateMode.preview.rawValue, "preview")
        XCTAssertEqual(TemplateMode.edit.rawValue, "edit")
    }

    // MARK: - Additional: Uncompiled player returns empty

    /// renderCommands(mode:) returns empty array before compile.
    func testUncompiledPlayerReturnsEmpty() {
        let player = ScenePlayer()

        let previewCommands = player.renderCommands(mode: .preview, sceneFrameIndex: 0)
        XCTAssertTrue(previewCommands.isEmpty, "Uncompiled player should return empty for preview")

        let editCommands = player.renderCommands(mode: .edit)
        XCTAssertTrue(editCommands.isEmpty, "Uncompiled player should return empty for edit")
    }
}
