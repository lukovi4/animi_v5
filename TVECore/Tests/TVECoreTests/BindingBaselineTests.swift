import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// Integration tests for BindingBaselineRuntime — the canonical placement contract.
///
/// Verifies:
/// - Baseline is computed from edit variant binding placeholder asset
/// - Baselines are correctly sized from template asset metadata
/// - Polaroid template preserves card rotation/scale
/// - ScenePlayer APIs work correctly
/// - mediaInputGeometry still available for clip/hit-test
final class BindingBaselineTests: XCTestCase {

    // MARK: - Helpers

    private func loadPackage(subdirectory: String) throws -> (ScenePackage, LoadedAnimations) {
        let url = Bundle.module.url(
            forResource: "scene",
            withExtension: "json",
            subdirectory: "Resources/\(subdirectory)"
        )!.deletingLastPathComponent()

        let loader = ScenePackageLoader()
        let package = try loader.load(from: url)
        let animLoader = AnimLoader()
        let animations = try animLoader.loadAnimations(from: package)
        return (package, animations)
    }

    private func compileScene(subdirectory: String) async throws -> CompiledScene {
        let (package, animations) = try loadPackage(subdirectory: subdirectory)
        return try await MainActor.run {
            let player = ScenePlayer()
            return try player.compile(package: package, loadedAnimations: animations)
        }
    }

    // MARK: - example_4blocks: Binding Baseline

    func test_example4blocks_allBlocksHaveBindingBaseline() async throws {
        let compiled = try await compileScene(subdirectory: "example_4blocks")

        for block in compiled.runtime.blocks {
            let baseline = block.bindingBaseline
            XCTAssertFalse(baseline.boundAssetId.isEmpty,
                "Block \(block.blockId) must have boundAssetId")
            XCTAssertGreaterThan(baseline.contentSizeLocal.width, 0,
                "Block \(block.blockId) baseline width must be > 0")
            XCTAssertGreaterThan(baseline.contentSizeLocal.height, 0,
                "Block \(block.blockId) baseline height must be > 0")
            XCTAssertEqual(baseline.contentRectLocal.x, 0,
                "contentRectLocal.x must be 0")
            XCTAssertEqual(baseline.contentRectLocal.y, 0,
                "contentRectLocal.y must be 0")
        }
    }

    func test_example4blocks_baselineMatchesEditVariantAssetSize() async throws {
        let compiled = try await compileScene(subdirectory: "example_4blocks")

        // block_01 has 680x960 baseline, all others have 540x960
        for block in compiled.runtime.blocks {
            let expectedWidth: Double = block.blockId == "block_01" ? 680 : 540
            XCTAssertEqual(block.bindingBaseline.contentSizeLocal.width, expectedWidth, accuracy: 0.1,
                "Block \(block.blockId) baseline width must match edit variant asset")
            XCTAssertEqual(block.bindingBaseline.contentSizeLocal.height, 960, accuracy: 0.1,
                "Block \(block.blockId) baseline height must match edit variant asset")
        }
    }

    func test_block01HasWiderBaselineThanBlock02() async throws {
        let compiled = try await compileScene(subdirectory: "example_4blocks")

        let block01 = compiled.runtime.blocks.first { $0.blockId == "block_01" }!
        let block02 = compiled.runtime.blocks.first { $0.blockId == "block_02" }!

        XCTAssertEqual(block01.bindingBaseline.contentSizeLocal.width, 680, accuracy: 0.1)
        XCTAssertEqual(block02.bindingBaseline.contentSizeLocal.width, 540, accuracy: 0.1)
        XCTAssertGreaterThan(
            block01.bindingBaseline.contentSizeLocal.width,
            block02.bindingBaseline.contentSizeLocal.width,
            "block_01 should have wider baseline than block_02"
        )
    }

    func test_example4blocks_baselineOriginIsAlwaysZero() async throws {
        let compiled = try await compileScene(subdirectory: "example_4blocks")

        for block in compiled.runtime.blocks {
            let baseline = block.bindingBaseline.contentRectLocal
            XCTAssertEqual(baseline.x, 0, "Baseline origin.x must be 0 (renderer quad starts at origin)")
            XCTAssertEqual(baseline.y, 0, "Baseline origin.y must be 0 (renderer quad starts at origin)")
        }
    }

    func test_example4blocks_baselineIndependentFromAperture() async throws {
        let compiled = try await compileScene(subdirectory: "example_4blocks")

        for block in compiled.runtime.blocks {
            // Aperture still exists for clip/hit-test
            let aperture = block.mediaInputGeometry.placementRectLocal
            XCTAssertGreaterThan(aperture.width, 0,
                "Block \(block.blockId) must have mediaInputGeometry for clip")

            // Baseline has origin (0,0), aperture may not
            let baseline = block.bindingBaseline.contentRectLocal
            XCTAssertEqual(baseline.x, 0)
            XCTAssertEqual(baseline.y, 0)
        }
    }

    // MARK: - polaroid_2: Binding Baseline

    func test_polaroid2_allBlocksHaveBindingBaseline() async throws {
        let compiled = try await compileScene(subdirectory: "polaroid_2")
        XCTAssertEqual(compiled.runtime.blocks.count, 2)

        for block in compiled.runtime.blocks {
            XCTAssertGreaterThan(block.bindingBaseline.contentSizeLocal.width, 0)
            XCTAssertGreaterThan(block.bindingBaseline.contentSizeLocal.height, 0)
        }
    }

    func test_polaroid2_blocksHaveSameBaselineSize() async throws {
        let compiled = try await compileScene(subdirectory: "polaroid_2")

        let block01 = compiled.runtime.blocks.first { $0.blockId == "block_01" }!
        let block02 = compiled.runtime.blocks.first { $0.blockId == "block_02" }!

        XCTAssertEqual(
            block01.bindingBaseline.contentSizeLocal.width,
            block02.bindingBaseline.contentSizeLocal.width,
            accuracy: 0.1,
            "Polaroid blocks should have same baseline width"
        )
        XCTAssertEqual(
            block01.bindingBaseline.contentSizeLocal.height,
            block02.bindingBaseline.contentSizeLocal.height,
            accuracy: 0.1,
            "Polaroid blocks should have same baseline height"
        )
    }

    func test_polaroid2_editBindingWorldMatrixIncludesCardRotation() async throws {
        let (package, animations) = try loadPackage(subdirectory: "polaroid_2")

        try await MainActor.run {
            let player = ScenePlayer()
            let _ = try player.compile(package: package, loadedAnimations: animations)

            guard let m1 = player.editBindingToCanvasMatrix(blockId: "block_01"),
                  let m2 = player.editBindingToCanvasMatrix(blockId: "block_02") else {
                XCTFail("editBindingToCanvasMatrix must return non-nil")
                return
            }

            // Matrices must differ (opposite rotations: -10 vs +10)
            XCTAssertFalse(m1.isApproximatelyEqual(to: m2, epsilon: 1e-6),
                "Block matrices must differ due to opposite card rotations")

            // Both non-identity (have rotation + scale from card transform)
            XCTAssertFalse(m1.isApproximatelyEqual(to: .identity, epsilon: 1e-6))
            XCTAssertFalse(m2.isApproximatelyEqual(to: .identity, epsilon: 1e-6))

            // Both must be invertible (for gesture conversion)
            XCTAssertNotNil(m1.inverse, "Canvas matrix must be invertible")
            XCTAssertNotNil(m2.inverse, "Canvas matrix must be invertible")
        }
    }

    // MARK: - ScenePlayer API

    func test_scenePlayer_bindingBaselineAPI() async throws {
        let (package, animations) = try loadPackage(subdirectory: "example_4blocks")

        try await MainActor.run {
            let player = ScenePlayer()
            let _ = try player.compile(package: package, loadedAnimations: animations)

            guard let baseline = player.bindingBaseline(blockId: "block_01") else {
                XCTFail("bindingBaseline must return non-nil for compiled block")
                return
            }
            XCTAssertEqual(baseline.contentSizeLocal.width, 680, accuracy: 0.1)
            XCTAssertEqual(baseline.contentSizeLocal.height, 960, accuracy: 0.1)

            XCTAssertNil(player.bindingBaseline(blockId: "nonexistent"))
        }
    }

    func test_scenePlayer_editBindingToCanvasMatrixAPI() async throws {
        let (package, animations) = try loadPackage(subdirectory: "example_4blocks")

        try await MainActor.run {
            let player = ScenePlayer()
            let _ = try player.compile(package: package, loadedAnimations: animations)

            let matrix = player.editBindingToCanvasMatrix(blockId: "block_01")
            XCTAssertNotNil(matrix)
            XCTAssertNotNil(matrix?.inverse)

            XCTAssertNil(player.editBindingToCanvasMatrix(blockId: "nonexistent"))
        }
    }

    // MARK: - ContentRect Consistency

    func test_bindingBaseline_contentRectMatchesSizeLocal() async throws {
        let compiled = try await compileScene(subdirectory: "example_4blocks")

        for block in compiled.runtime.blocks {
            let baseline = block.bindingBaseline
            XCTAssertEqual(baseline.contentRectLocal.width, baseline.contentSizeLocal.width)
            XCTAssertEqual(baseline.contentRectLocal.height, baseline.contentSizeLocal.height)
            XCTAssertEqual(baseline.contentRectLocal.x, 0)
            XCTAssertEqual(baseline.contentRectLocal.y, 0)
        }
    }

    // MARK: - MediaInputGeometry Still Available

    func test_mediaInputGeometry_stillAvailableForClip() async throws {
        let compiled = try await compileScene(subdirectory: "example_4blocks")

        for block in compiled.runtime.blocks {
            XCTAssertGreaterThan(block.mediaInputGeometry.placementRectLocal.width, 0,
                "Block \(block.blockId) must have mediaInputGeometry for clip")
        }
    }
}
