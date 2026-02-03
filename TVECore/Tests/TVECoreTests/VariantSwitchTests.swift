import XCTest
@testable import TVECore

/// PR-20: Variant switching tests.
///
/// Uses `variant_switch` test scene with:
/// - block_01: 2 variants (v1 → anim-v1.json, v2 → anim-v2.json)
/// - block_02: 1 variant  (v1 → anim-b2.json)
///
/// Variant v1 references img_1.png, variant v2 references img_2.png.
/// After switching, the drawImage assetId changes from
/// `anim-v1.json|image_0` to `anim-v2.json|image_0`.
final class VariantSwitchTests: XCTestCase {

    // MARK: - Helpers

    private var testPackageURL: URL {
        Bundle.module.url(
            forResource: "scene",
            withExtension: "json",
            subdirectory: "Resources/variant_switch"
        )!.deletingLastPathComponent()
    }

    private func loadTestPackage() throws -> (ScenePackage, LoadedAnimations) {
        let loader = ScenePackageLoader()
        let package = try loader.load(from: testPackageURL)

        let animLoader = AnimLoader()
        let animations = try animLoader.loadAnimations(from: package)

        return (package, animations)
    }

    /// Compiles the variant_switch scene and returns a ready ScenePlayer.
    private func makePlayer() throws -> ScenePlayer {
        let (package, animations) = try loadTestPackage()
        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)
        return player
    }

    /// Extracts all drawImage asset IDs from render commands.
    private func drawImageAssetIds(from commands: [RenderCommand]) -> [String] {
        commands.compactMap { cmd in
            if case .drawImage(let assetId, _) = cmd { return assetId }
            return nil
        }
    }

    // MARK: - T1: Compilation — block_01 has 2 variants

    func testCompilation_block01HasTwoVariants() throws {
        let player = try makePlayer()
        let compiled = player.compiledScene!

        let block01 = compiled.runtime.blocks.first { $0.blockId == "block_01" }
        XCTAssertNotNil(block01)
        XCTAssertEqual(block01!.variants.count, 3, "block_01 should have 3 compiled variants (v1, v2, no-anim)")
        XCTAssertEqual(block01!.variants[0].variantId, "v1")
        XCTAssertEqual(block01!.variants[1].variantId, "v2")
    }

    func testCompilation_block02HasOneVariant() throws {
        let player = try makePlayer()
        let compiled = player.compiledScene!

        let block02 = compiled.runtime.blocks.first { $0.blockId == "block_02" }
        XCTAssertNotNil(block02)
        XCTAssertEqual(block02!.variants.count, 2, "block_02 should have 2 compiled variants (v1, no-anim)")
    }

    // MARK: - T2: availableVariants

    func testAvailableVariants_returnsCorrectVariantInfo() throws {
        let player = try makePlayer()

        let variants = player.availableVariants(blockId: "block_01")
        XCTAssertEqual(variants.count, 3)
        XCTAssertEqual(variants[0].id, "v1")
        XCTAssertEqual(variants[0].animRef, "anim-v1.json")
        XCTAssertEqual(variants[1].id, "v2")
        XCTAssertEqual(variants[1].animRef, "anim-v2.json")
        XCTAssertEqual(variants[2].id, "no-anim")
        XCTAssertEqual(variants[2].animRef, "no-anim-b1.json")
    }

    func testAvailableVariants_unknownBlock_returnsEmpty() throws {
        let player = try makePlayer()
        XCTAssertTrue(player.availableVariants(blockId: "nonexistent").isEmpty)
    }

    // MARK: - T3: selectedVariantId — default after compilation

    func testSelectedVariantId_defaultIsFirstVariant() throws {
        let player = try makePlayer()

        // block_01 default = v1 (first variant)
        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v1")
        // block_02 default = v1 (only variant)
        XCTAssertEqual(player.selectedVariantId(blockId: "block_02"), "v1")
    }

    func testSelectedVariantId_unknownBlock_returnsNil() throws {
        let player = try makePlayer()
        XCTAssertNil(player.selectedVariantId(blockId: "nonexistent"))
    }

    // MARK: - T4: setSelectedVariant changes active variant

    func testSetSelectedVariant_changesActiveVariant() throws {
        let player = try makePlayer()

        // Initially v1
        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v1")

        // Switch to v2
        player.setSelectedVariant(blockId: "block_01", variantId: "v2")
        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v2")

        // Switch back to v1
        player.setSelectedVariant(blockId: "block_01", variantId: "v1")
        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v1")
    }

    // MARK: - T5: Variant switch affects render commands

    func testVariantSwitch_changesDrawImageAssetId() throws {
        let player = try makePlayer()

        // Default (v1) — should contain anim-v1.json|image_0
        let commandsV1 = player.renderCommands(sceneFrameIndex: 0)
        let assetIdsV1 = drawImageAssetIds(from: commandsV1)
        XCTAssertTrue(assetIdsV1.contains("anim-v1.json|image_0"),
            "Default should render variant v1 asset. Got: \(assetIdsV1)")

        // Switch block_01 to v2
        player.setSelectedVariant(blockId: "block_01", variantId: "v2")
        let commandsV2 = player.renderCommands(sceneFrameIndex: 0)
        let assetIdsV2 = drawImageAssetIds(from: commandsV2)
        XCTAssertTrue(assetIdsV2.contains("anim-v2.json|image_0"),
            "After switch should render variant v2 asset. Got: \(assetIdsV2)")
        XCTAssertFalse(assetIdsV2.contains("anim-v1.json|image_0"),
            "After switch should NOT render variant v1 asset for block_01")
    }

    func testVariantSwitch_doesNotAffectOtherBlocks() throws {
        let player = try makePlayer()

        // block_02 asset should remain unchanged regardless of block_01 switch
        let commandsBefore = player.renderCommands(sceneFrameIndex: 0)
        let b2AssetsBefore = drawImageAssetIds(from: commandsBefore)
            .filter { $0.hasPrefix("anim-b2.json|") }

        player.setSelectedVariant(blockId: "block_01", variantId: "v2")

        let commandsAfter = player.renderCommands(sceneFrameIndex: 0)
        let b2AssetsAfter = drawImageAssetIds(from: commandsAfter)
            .filter { $0.hasPrefix("anim-b2.json|") }

        XCTAssertEqual(b2AssetsBefore, b2AssetsAfter,
            "block_02 assets should not change when block_01 variant switches")
    }

    // MARK: - T6: Edit mode always uses no-anim variant

    func testEditMode_alwaysUsesNoAnimVariant() throws {
        let player = try makePlayer()

        // Edit mode should use no-anim regardless of selected variant
        let editDefault = player.renderCommands(mode: .edit)
        let editAssetsDefault = drawImageAssetIds(from: editDefault)
        XCTAssertTrue(editAssetsDefault.contains("no-anim-b1.json|image_0"),
            "Edit mode should render no-anim variant. Got: \(editAssetsDefault)")

        // Switch to v2 — edit mode should still use no-anim
        player.setSelectedVariant(blockId: "block_01", variantId: "v2")
        let editAfterSwitch = player.renderCommands(mode: .edit)
        let editAssetsAfterSwitch = drawImageAssetIds(from: editAfterSwitch)
        XCTAssertTrue(editAssetsAfterSwitch.contains("no-anim-b1.json|image_0"),
            "Edit mode after variant switch should still render no-anim. Got: \(editAssetsAfterSwitch)")
        XCTAssertFalse(editAssetsAfterSwitch.contains("anim-v2.json|image_0"),
            "Edit mode should NOT render selected animated variant")
    }

    // MARK: - T7: Invalid variant falls back to default

    func testInvalidVariant_fallsBackToDefault() throws {
        let player = try makePlayer()

        // Set invalid variant
        player.setSelectedVariant(blockId: "block_01", variantId: "nonexistent")

        // Should fall back to compilation default (v1)
        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v1",
            "Invalid variantId should revert to compilation default")

        // Render should use default variant
        let commands = player.renderCommands(sceneFrameIndex: 0)
        let assetIds = drawImageAssetIds(from: commands)
        XCTAssertTrue(assetIds.contains("anim-v1.json|image_0"),
            "Invalid variant should render default v1. Got: \(assetIds)")
    }

    func testInvalidVariant_removesExistingOverride() throws {
        let player = try makePlayer()

        // Set valid override first
        player.setSelectedVariant(blockId: "block_01", variantId: "v2")
        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v2")

        // Now set invalid — should clear override and revert to default
        player.setSelectedVariant(blockId: "block_01", variantId: "nonexistent")
        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v1",
            "Invalid variantId should clear existing override")
    }

    // MARK: - T8: applyVariantSelection (scene preset)

    func testApplyVariantSelection_setsMultipleBlocks() throws {
        let player = try makePlayer()

        // Apply preset: block_01 → v2, block_02 → v1 (only option anyway)
        player.applyVariantSelection(["block_01": "v2", "block_02": "v1"])

        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v2")
        XCTAssertEqual(player.selectedVariantId(blockId: "block_02"), "v1")

        // Render reflects the preset
        let commands = player.renderCommands(sceneFrameIndex: 0)
        let assetIds = drawImageAssetIds(from: commands)
        XCTAssertTrue(assetIds.contains("anim-v2.json|image_0"),
            "Preset should activate v2 for block_01. Got: \(assetIds)")
    }

    func testApplyVariantSelection_skipsInvalidEntries() throws {
        let player = try makePlayer()

        // Mix of valid and invalid
        player.applyVariantSelection([
            "block_01": "v2",           // valid
            "nonexistent": "v1",        // invalid block — silently skipped
            "block_02": "invalid_vid"   // invalid variant — clears override
        ])

        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v2")
        XCTAssertEqual(player.selectedVariantId(blockId: "block_02"), "v1",
            "Invalid variant for block_02 should fall back to default")
    }

    // MARK: - T9: clearSelectedVariantOverride

    func testClearOverride_revertsToDefault() throws {
        let player = try makePlayer()

        // Set and then clear
        player.setSelectedVariant(blockId: "block_01", variantId: "v2")
        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v2")

        player.clearSelectedVariantOverride(blockId: "block_01")
        XCTAssertEqual(player.selectedVariantId(blockId: "block_01"), "v1",
            "Clearing override should revert to compilation default")
    }

    // MARK: - T10: Commands are balanced after switch

    func testCommandsBalanced_afterVariantSwitch() throws {
        let player = try makePlayer()

        // Switch and verify balance
        player.setSelectedVariant(blockId: "block_01", variantId: "v2")
        let commands = player.renderCommands(sceneFrameIndex: 0)
        XCTAssertTrue(commands.isBalanced(), "Commands should be balanced after variant switch")
    }

    // MARK: - T11: Determinism — same variant, same frame → same commands

    func testDeterminism_sameVariantSameFrame() throws {
        let player = try makePlayer()
        player.setSelectedVariant(blockId: "block_01", variantId: "v2")

        let commands1 = player.renderCommands(sceneFrameIndex: 0)
        let commands2 = player.renderCommands(sceneFrameIndex: 0)

        XCTAssertEqual(commands1.count, commands2.count,
            "Same variant + same frame must produce same command count")

        let assets1 = drawImageAssetIds(from: commands1)
        let assets2 = drawImageAssetIds(from: commands2)
        XCTAssertEqual(assets1, assets2, "Asset IDs must be deterministic")
    }

    // MARK: - T12: Merged asset index contains all variant assets

    func testMergedAssetIndex_containsAllVariantAssets() throws {
        let player = try makePlayer()
        let compiled = player.compiledScene!

        let mergedIds = Set(compiled.mergedAssetIndex.byId.keys)

        // v1 and v2 assets should both be present (namespaced)
        XCTAssertTrue(mergedIds.contains("anim-v1.json|image_0"),
            "Merged index should contain v1 asset")
        XCTAssertTrue(mergedIds.contains("anim-v2.json|image_0"),
            "Merged index should contain v2 asset")
        XCTAssertTrue(mergedIds.contains("anim-b2.json|image_0"),
            "Merged index should contain block_02 asset")
    }

    // MARK: - T13: InputClip override from editVariant (PR-26)

    /// Preview with anim variant (no mediaInput) must produce inputClip
    /// using geometry from the editVariant (no-anim).
    func testPreviewAnimVariant_hasInputClipFromEditVariant() throws {
        let player = try makePlayer()

        // v1 is an anim variant WITHOUT mediaInput
        player.setSelectedVariant(blockId: "block_01", variantId: "v1")

        let commands = player.renderCommands(mode: .preview, sceneFrameIndex: 0)
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.isBalanced())

        // Must have beginMask(.intersect) — inputClip from editVariant
        let hasIntersectMask = commands.contains { cmd in
            if case .beginMask(mode: .intersect, _, _, _, _) = cmd { return true }
            return false
        }
        XCTAssertTrue(hasIntersectMask,
            "Preview with anim variant must have inputClip from editVariant (no-anim)")
    }

    /// Edit mode uses no-anim directly — inputClip comes from its own inputGeometry.
    func testEditMode_hasInputClip() throws {
        let player = try makePlayer()

        let commands = player.renderCommands(mode: .edit)
        XCTAssertTrue(commands.isBalanced())

        let hasIntersectMask = commands.contains { cmd in
            if case .beginMask(mode: .intersect, _, _, _, _) = cmd { return true }
            return false
        }
        XCTAssertTrue(hasIntersectMask,
            "Edit mode (no-anim) must have inputClip from own inputGeometry")
    }

    // MARK: - T14: No operation before compile

    func testBeforeCompile_apiReturnsDefaults() {
        let player = ScenePlayer()

        XCTAssertTrue(player.availableVariants(blockId: "block_01").isEmpty)
        XCTAssertNil(player.selectedVariantId(blockId: "block_01"))

        // setSelectedVariant should not crash
        player.setSelectedVariant(blockId: "block_01", variantId: "v1")
        player.applyVariantSelection(["block_01": "v1"])
        player.clearSelectedVariantOverride(blockId: "block_01")
    }
}
