import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// PR4 Smoke Tests: Verifies compiled template (.tve) loading and playback
final class CompiledTemplateTests: XCTestCase {

    // MARK: - Test Resources

    private var compiledTemplateURL: URL? {
        // Look for compiled.tve in test resources
        Bundle.module.url(
            forResource: "compiled",
            withExtension: "tve",
            subdirectory: "Resources/example_4blocks"
        )?.deletingLastPathComponent()
    }

    // MARK: - Compiled Package Loading Tests

    /// Test: CompiledScenePackageLoader loads compiled.tve from a template folder
    func testCompiledPackageLoader_loadsFromTemplateFolder() throws {
        // Skip if no compiled.tve in test bundle
        guard let templateURL = compiledTemplateURL else {
            throw XCTSkip("compiled.tve not found in test resources - run Scripts/compile_templates.sh first")
        }

        // Given
        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)

        // When
        let package = try loader.load(from: templateURL)

        // Then
        XCTAssertFalse(package.compiled.runtime.blocks.isEmpty, "Compiled scene should have blocks")
        XCTAssertEqual(package.compiled.runtime.blocks.count, 4, "example_4blocks should have 4 blocks")
        XCTAssertEqual(package.rootURL, templateURL, "Root URL should match input")
    }

    /// Test: ScenePlayer can load a pre-compiled scene and generate render commands
    func testScenePlayer_loadsCompiledScene_generatesCommands() throws {
        guard let templateURL = compiledTemplateURL else {
            throw XCTSkip("compiled.tve not found in test resources")
        }

        // Given
        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)
        let package = try loader.load(from: templateURL)
        let player = ScenePlayer()

        // When
        player.loadCompiledScene(package.compiled)

        // Set userMediaPresent=true for all blocks so binding layers render
        for block in package.compiled.runtime.blocks {
            player.setUserMediaPresent(blockId: block.blockId, present: true)
        }

        let commands = player.renderCommands(sceneFrameIndex: 0)

        // Then
        XCTAssertNotNil(player.compiledScene, "Player should have loaded scene")
        XCTAssertFalse(commands.isEmpty, "Should generate render commands at frame 0")
    }

    /// Test: Compiled scene has correct metadata (canvas, fps, duration)
    func testCompiledScene_hasCorrectMetadata() throws {
        guard let templateURL = compiledTemplateURL else {
            throw XCTSkip("compiled.tve not found in test resources")
        }

        // Given
        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)
        let package = try loader.load(from: templateURL)

        // Then - validate canvas metadata
        let runtime = package.compiled.runtime
        XCTAssertEqual(runtime.canvas.width, 1080, "Canvas width should be 1080")
        XCTAssertEqual(runtime.canvas.height, 1920, "Canvas height should be 1920")
        XCTAssertEqual(runtime.fps, 30, "FPS should be 30")
        XCTAssertEqual(runtime.durationFrames, 300, "Duration should be 300 frames")
    }

    /// Test: Each block has valid variants and selected variant
    func testCompiledScene_blocksHaveValidVariants() throws {
        guard let templateURL = compiledTemplateURL else {
            throw XCTSkip("compiled.tve not found in test resources")
        }

        // Given
        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)
        let package = try loader.load(from: templateURL)

        // Then - verify each block
        for block in package.compiled.runtime.blocks {
            XCTAssertFalse(block.variants.isEmpty, "Block \(block.blockId) should have variants")
            XCTAssertNotNil(block.selectedVariant, "Block \(block.blockId) should have selected variant")

            // Verify variant has animIR with layers
            if let selectedVariant = block.selectedVariant {
                XCTAssertFalse(selectedVariant.variantId.isEmpty, "Variant should have valid ID")
                XCTAssertFalse(selectedVariant.animRef.isEmpty, "Variant should have animRef")
            }
        }
    }

    /// Test: Path registry is populated with compiled paths
    func testCompiledScene_pathRegistryPopulated() throws {
        guard let templateURL = compiledTemplateURL else {
            throw XCTSkip("compiled.tve not found in test resources")
        }

        // Given
        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)
        let package = try loader.load(from: templateURL)

        // Then
        XCTAssertGreaterThan(package.compiled.pathRegistry.count, 0, "Path registry should have paths")
    }

    /// Test: Merged asset index is populated
    func testCompiledScene_mergedAssetIndexPopulated() throws {
        guard let templateURL = compiledTemplateURL else {
            throw XCTSkip("compiled.tve not found in test resources")
        }

        // Given
        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)
        let package = try loader.load(from: templateURL)

        // Then
        XCTAssertFalse(package.compiled.mergedAssetIndex.byId.isEmpty, "Merged assets should be populated")
    }
}
