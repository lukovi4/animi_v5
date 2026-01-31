import XCTest
@testable import TVECore

/// PR-18: Template Modes — Preview vs Edit
///
/// Tests T1-T5 per task specification:
/// - T1: Preview renders full scene (all blocks, all layers)
/// - T2: Edit renders only binding layers + dependencies
/// - T3: Edit ignores sceneFrameIndex (time frozen at editFrameIndex = 0)
/// - T4: Edit produces fewer commands than preview (no decorative layers)
/// - T5: Determinism — two players produce identical output
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
        // Given
        let player = try compiledPlayer()
        let expectedBlocks = visibleBlockCount(player: player, at: 120)

        // When
        let commands = player.renderCommands(mode: .preview, sceneFrameIndex: 120)

        // Then — each visible block should produce at least one drawImage
        let drawImageCount = commands.filter {
            if case .drawImage = $0 { return true }
            return false
        }.count
        XCTAssertGreaterThanOrEqual(drawImageCount, expectedBlocks,
            "Preview at frame 120 should have at least \(expectedBlocks) drawImage commands")

        // Commands must be balanced
        XCTAssertTrue(commands.isBalanced(),
            "Preview commands should be balanced (matching begin/end pairs)")

        // Should have block groups for all visible blocks
        let blockGroupCount = commands.filter {
            if case .beginGroup(let name) = $0 { return name.hasPrefix("Block:") }
            return false
        }.count
        XCTAssertEqual(blockGroupCount, expectedBlocks,
            "Preview should have \(expectedBlocks) block groups")
    }

    /// T1b: Preview mode matches existing renderCommands API (backward compatibility).
    func testT1b_previewMatchesLegacyAPI() throws {
        // Given
        let player = try compiledPlayer()

        // When
        let previewCommands = player.renderCommands(mode: .preview, sceneFrameIndex: 120)
        let legacyCommands = player.renderCommands(sceneFrameIndex: 120)

        // Then — same command count and structure
        XCTAssertEqual(previewCommands.count, legacyCommands.count,
            "Preview mode should produce same command count as legacy API")

        // Verify command types match
        for (idx, previewCmd) in previewCommands.enumerated() {
            XCTAssertEqual(previewCmd, legacyCommands[idx],
                "Commands should match at index \(idx)")
        }
    }

    // MARK: - T2: Edit renders only binding layers

    /// T2: Edit mode renders only binding layers — exactly one drawImage per visible block.
    ///
    /// Lead correction #4: Shapes are allowed only inside matte/mask scope (as dependencies).
    func testT2_editRendersOnlyBindingLayers() throws {
        // Given
        let player = try compiledPlayer()
        let editFrame = ScenePlayer.editFrameIndex
        let visibleAtEditFrame = visibleBlockCount(player: player, at: editFrame)

        // When
        let editCommands = player.renderCommands(mode: .edit)

        // Then — commands must be balanced
        XCTAssertTrue(editCommands.isBalanced(),
            "Edit commands should be balanced")

        // Block groups should be tagged with "(edit)"
        let editBlockGroups = editCommands.filter {
            if case .beginGroup(let name) = $0 { return name.contains("(edit)") }
            return false
        }
        XCTAssertGreaterThan(editBlockGroups.count, 0,
            "Edit commands should have block groups tagged with '(edit)'")

        // Count drawImage commands — should be exactly one per visible block at editFrameIndex
        let drawImageCount = editCommands.filter {
            if case .drawImage = $0 { return true }
            return false
        }.count
        XCTAssertEqual(drawImageCount, visibleAtEditFrame,
            "Edit mode should produce exactly \(visibleAtEditFrame) drawImage (one binding layer per visible block)")

        // Shapes/strokes should only appear inside matte or mask scope
        assertShapesOnlyInMatteOrMaskScope(editCommands)
    }

    /// T2b: Edit produces fewer drawImage commands than preview at frame 120.
    ///
    /// Preview renders all layers; edit renders only binding layer per block.
    func testT2b_editHasFewerDrawImagesThanPreview() throws {
        // Given
        let player = try compiledPlayer()

        // When
        let previewCommands = player.renderCommands(mode: .preview, sceneFrameIndex: 120)
        let editCommands = player.renderCommands(mode: .edit)

        // Then
        let previewDrawImages = previewCommands.filter {
            if case .drawImage = $0 { return true }
            return false
        }.count

        let editDrawImages = editCommands.filter {
            if case .drawImage = $0 { return true }
            return false
        }.count

        // Edit should have fewer or equal drawImage commands
        // (fewer because decorative layers are skipped in edit)
        XCTAssertLessThanOrEqual(editDrawImages, previewDrawImages,
            "Edit should have ≤ drawImage commands than preview (\(editDrawImages) vs \(previewDrawImages))")
    }

    // MARK: - T3: Edit ignores sceneFrameIndex

    /// T3: Edit mode always renders at editFrameIndex (0), regardless of sceneFrameIndex.
    ///
    /// Lead correction #1: Edit mode always uses editFrameIndex = 0 directly, no timing/loop policies.
    func testT3_editIgnoresSceneFrameIndex() throws {
        // Given
        let player = try compiledPlayer()

        // When — render edit at different sceneFrameIndex values
        let editAt0 = player.renderCommands(mode: .edit, sceneFrameIndex: 0)
        let editAt50 = player.renderCommands(mode: .edit, sceneFrameIndex: 50)
        let editAt150 = player.renderCommands(mode: .edit, sceneFrameIndex: 150)

        // Then — all should produce identical output (edit ignores sceneFrameIndex)
        XCTAssertEqual(editAt0.count, editAt50.count,
            "Edit at frame 0 and frame 50 should have same command count")
        XCTAssertEqual(editAt0.count, editAt150.count,
            "Edit at frame 0 and frame 150 should have same command count")

        // Verify commands are identical
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

    // MARK: - T4: Edit produces fewer commands than preview

    /// T4: Edit produces fewer total commands than preview — no decorative layers.
    ///
    /// Uses frame 120 for preview so all visible blocks render content (matching edit which
    /// sees blocks visible at editFrameIndex per their timing windows).
    func testT4_editFewerCommandsThanPreview() throws {
        // Given
        let player = try compiledPlayer()

        // When — use frame 120 for preview where all blocks render content
        let previewCommands = player.renderCommands(mode: .preview, sceneFrameIndex: 120)
        let editCommands = player.renderCommands(mode: .edit)

        // Then — edit should have fewer total commands (no decorative content)
        XCTAssertLessThan(editCommands.count, previewCommands.count,
            "Edit should have fewer commands than preview (\(editCommands.count) vs \(previewCommands.count))")

        // Both must be balanced
        XCTAssertTrue(previewCommands.isBalanced(), "Preview commands should be balanced")
        XCTAssertTrue(editCommands.isBalanced(), "Edit commands should be balanced")
    }

    /// T4b: Edit drawImage asset IDs are a subset of preview assets at frame 120.
    ///
    /// Uses frame 120 for preview so all blocks are visible and all assets are rendered.
    func testT4b_editExcludesDecorativeLayers() throws {
        // Given
        let player = try compiledPlayer()

        // When — use frame 120 where all blocks are visible and render content
        let previewCommands = player.renderCommands(mode: .preview, sceneFrameIndex: 120)
        let editCommands = player.renderCommands(mode: .edit)

        // Collect drawImage asset IDs from each mode
        let previewAssetIds = Set(previewCommands.compactMap { cmd -> String? in
            if case .drawImage(let assetId, _) = cmd { return assetId }
            return nil
        })
        let editAssetIds = Set(editCommands.compactMap { cmd -> String? in
            if case .drawImage(let assetId, _) = cmd { return assetId }
            return nil
        })

        // Edit asset IDs should be a subset of preview asset IDs
        XCTAssertTrue(editAssetIds.isSubset(of: previewAssetIds),
            "Edit drawImage assets (\(editAssetIds)) should be a subset of preview assets (\(previewAssetIds))")
    }

    // MARK: - T5: Determinism

    /// T5: Two independent ScenePlayer instances produce identical edit commands.
    func testT5_determinism_twoPlayersIdenticalOutput() throws {
        // Given
        let (package, animations) = try loadTestPackage()
        let player1 = ScenePlayer()
        let player2 = ScenePlayer()
        _ = try player1.compile(package: package, loadedAnimations: animations)
        _ = try player2.compile(package: package, loadedAnimations: animations)

        // When
        let editCommands1 = player1.renderCommands(mode: .edit)
        let editCommands2 = player2.renderCommands(mode: .edit)

        // Then — identical output
        XCTAssertEqual(editCommands1.count, editCommands2.count,
            "Two players should produce same edit command count")
        for (idx, cmd1) in editCommands1.enumerated() {
            XCTAssertEqual(cmd1, editCommands2[idx],
                "Edit commands should be identical between two players at index \(idx)")
        }
    }

    /// T5b: Determinism in preview mode — two players produce identical output.
    func testT5b_determinism_previewIdentical() throws {
        // Given
        let (package, animations) = try loadTestPackage()
        let player1 = ScenePlayer()
        let player2 = ScenePlayer()
        _ = try player1.compile(package: package, loadedAnimations: animations)
        _ = try player2.compile(package: package, loadedAnimations: animations)

        // When
        let previewCommands1 = player1.renderCommands(mode: .preview, sceneFrameIndex: 60)
        let previewCommands2 = player2.renderCommands(mode: .preview, sceneFrameIndex: 60)

        // Then
        XCTAssertEqual(previewCommands1.count, previewCommands2.count,
            "Two players should produce same preview command count")
        for (idx, cmd1) in previewCommands1.enumerated() {
            XCTAssertEqual(cmd1, previewCommands2[idx],
                "Preview commands should be identical between two players at index \(idx)")
        }
    }

    // MARK: - Additional: UserTransform in edit mode

    /// UserTransform API works in edit mode — set/get/reset cycle.
    ///
    /// Note: userTransform is only applied to the binding layer when mediaInput
    /// (inputGeometry) is present. Without mediaInput, the transform is stored
    /// but doesn't alter the render output. This test verifies the API contract
    /// and balanced commands.
    func testEditMode_userTransformAPI() throws {
        // Given
        let player = try compiledPlayer()
        guard let firstBlock = player.compiledScene?.runtime.blocks.first else {
            XCTFail("Should have at least one block")
            return
        }

        // When — set a user transform and render
        let transform = Matrix2D(a: 1.5, b: 0, c: 0, d: 1.5, tx: 10, ty: 20)
        player.setUserTransform(blockId: firstBlock.blockId, transform: transform)

        let editCommands = player.renderCommands(mode: .edit)

        // Then — commands should be balanced and non-empty
        XCTAssertTrue(editCommands.isBalanced(), "Edit with user transform should be balanced")
        XCTAssertFalse(editCommands.isEmpty, "Edit with user transform should produce commands")

        // Verify the transform is stored correctly
        let storedTransform = player.userTransform(blockId: firstBlock.blockId)
        XCTAssertEqual(storedTransform, transform, "Stored transform should match set value")

        // Reset and verify
        player.resetAllUserTransforms()
        let resetTransform = player.userTransform(blockId: firstBlock.blockId)
        XCTAssertEqual(resetTransform, .identity, "After reset, transform should be identity")
    }

    // MARK: - Additional: TemplateMode and RenderPolicy enums

    /// Verify TemplateMode raw values match expected strings.
    func testTemplateModeRawValues() {
        XCTAssertEqual(TemplateMode.preview.rawValue, "preview")
        XCTAssertEqual(TemplateMode.edit.rawValue, "edit")
    }

    /// Verify RenderPolicy enum has expected cases.
    func testRenderPolicyCases() {
        let fullPreview = RenderPolicy.fullPreview
        let editInputsOnly = RenderPolicy.editInputsOnly
        XCTAssertNotEqual(fullPreview, editInputsOnly)
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

    // MARK: - Helpers

    /// Asserts that drawShape/drawStroke commands appear only inside matte or mask scope.
    ///
    /// Lead correction #4: shapes are allowed only as matte/mask dependencies.
    private func assertShapesOnlyInMatteOrMaskScope(_ commands: [RenderCommand]) {
        var matteDepth = 0
        var maskDepth = 0

        for (idx, command) in commands.enumerated() {
            switch command {
            case .beginMatte:
                matteDepth += 1
            case .endMatte:
                matteDepth -= 1
            case .beginMask:
                maskDepth += 1
            case .endMask:
                maskDepth -= 1
            case .drawShape:
                XCTAssertTrue(matteDepth > 0 || maskDepth > 0,
                    "drawShape at index \(idx) should be inside matte or mask scope (matteDepth=\(matteDepth), maskDepth=\(maskDepth))")
            case .drawStroke:
                XCTAssertTrue(matteDepth > 0 || maskDepth > 0,
                    "drawStroke at index \(idx) should be inside matte or mask scope (matteDepth=\(matteDepth), maskDepth=\(maskDepth))")
            default:
                break
            }
        }
    }
}
