import XCTest
@testable import TVECore
@testable import TVECompilerCore

final class ScenePlayerTests: XCTestCase {

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

    // MARK: - Tests

    /// Test: ScenePlayer loads example_4blocks and compiles all anim refs
    func testScenePlayerLoadsExample4Blocks_compilesAllAnimRefs() async throws {
        let (package, animations) = try loadTestPackage()

        try await MainActor.run {
            let player = ScenePlayer()
            let compiled = try player.compile(package: package, loadedAnimations: animations)

            XCTAssertEqual(compiled.runtime.blocks.count, 4, "Should have 4 blocks")

            for block in compiled.runtime.blocks {
                XCTAssertFalse(block.variants.isEmpty, "Block \(block.blockId) should have variants")
                XCTAssertNotNil(block.selectedVariant, "Block \(block.blockId) should have selected variant")
            }

            XCTAssertEqual(compiled.runtime.canvas.width, 1080)
            XCTAssertEqual(compiled.runtime.canvas.height, 1920)
            XCTAssertEqual(compiled.runtime.fps, 30)
            XCTAssertEqual(compiled.runtime.durationFrames, 300)
        }
    }

    /// Test: Frame 0 generates commands for visible blocks
    func testScenePlayer_frame0_generatesCommandsForVisibleBlocks() async throws {
        let (package, animations) = try loadTestPackage()

        try await MainActor.run {
            let player = ScenePlayer()
            let compiled = try player.compile(package: package, loadedAnimations: animations)

            for block in compiled.runtime.blocks {
                player.setUserMediaPresent(blockId: block.blockId, present: true)
            }

            let commands = player.renderCommands(sceneFrameIndex: 0)

            XCTAssertFalse(commands.isEmpty, "Should generate commands at frame 0")

            let drawImageCount = commands.filter {
                if case .drawImage = $0 { return true }
                return false
            }.count
            XCTAssertGreaterThanOrEqual(drawImageCount, 1, "Should have at least 1 drawImage at frame 0")
        }
    }

    /// Test: Frame 120 has commands from all 4 blocks (all animations are visible)
    func testScenePlayer_frame120_allBlocksRenderContent() async throws {
        let (package, animations) = try loadTestPackage()

        try await MainActor.run {
            let player = ScenePlayer()
            let compiled = try player.compile(package: package, loadedAnimations: animations)

            for block in compiled.runtime.blocks {
                player.setUserMediaPresent(blockId: block.blockId, present: true)
            }

            let commands = player.renderCommands(sceneFrameIndex: 120)

            let drawImageCount = commands.filter {
                if case .drawImage = $0 { return true }
                return false
            }.count
            XCTAssertGreaterThanOrEqual(drawImageCount, 4, "Should have at least 4 drawImage at frame 120")
        }
    }

    /// Test: Scene applies block transform and clip
    func testScenePlayer_appliesBlockTransformAndClip() async throws {
        let (package, animations) = try loadTestPackage()

        try await MainActor.run {
            let player = ScenePlayer()
            let compiled = try player.compile(package: package, loadedAnimations: animations)

            for block in compiled.runtime.blocks {
                player.setUserMediaPresent(blockId: block.blockId, present: true)
            }

            let commands = player.renderCommands(sceneFrameIndex: 0)

            let clipRectCount = commands.filter {
                if case .pushClipRect = $0 { return true }
                return false
            }.count
            XCTAssertEqual(clipRectCount, 4, "Should have 4 pushClipRect commands")

            let transformCount = commands.filter {
                if case .pushTransform = $0 { return true }
                return false
            }.count
            XCTAssertGreaterThanOrEqual(transformCount, 4, "Should have at least 4 transform commands")

            var clipRects: [RectD] = []
            for command in commands {
                if case .pushClipRect(let rect) = command {
                    clipRects.append(rect)
                }
            }

            let expectedOrigins: [(Double, Double)] = [(0, 0), (540, 0), (0, 960), (540, 960)]
            for (x, y) in expectedOrigins {
                let found = clipRects.contains { abs($0.x - x) < 1 && abs($0.y - y) < 1 }
                XCTAssertTrue(found, "Should have clip rect at (\(x), \(y))")
            }
        }
    }

    /// Test: Determinism - same frame produces same command structure
    func testScenePlayer_determinism_sameFrameSameCommandsStructure() async throws {
        let (package, animations) = try loadTestPackage()

        try await MainActor.run {
            let player = ScenePlayer()
            let compiled = try player.compile(package: package, loadedAnimations: animations)

            for block in compiled.runtime.blocks {
                player.setUserMediaPresent(blockId: block.blockId, present: true)
            }

            let commands1 = player.renderCommands(sceneFrameIndex: 50)
            let commands2 = player.renderCommands(sceneFrameIndex: 50)
            let commands3 = player.renderCommands(sceneFrameIndex: 50)

            XCTAssertEqual(commands1.count, commands2.count, "Command count should be deterministic")
            XCTAssertEqual(commands2.count, commands3.count, "Command count should be deterministic")

            for (idx, cmd1) in commands1.enumerated() {
                let cmd2 = commands2[idx]
                XCTAssertEqual(
                    String(describing: type(of: cmd1)),
                    String(describing: type(of: cmd2)),
                    "Command types should match at index \(idx)"
                )
            }
        }
    }

    /// Test: Blocks are sorted by zIndex
    func testScenePlayer_blocksSortedByZIndex() async throws {
        let (package, animations) = try loadTestPackage()

        try await MainActor.run {
            let player = ScenePlayer()
            let compiled = try player.compile(package: package, loadedAnimations: animations)

            var previousZIndex = Int.min
            for block in compiled.runtime.blocks {
                XCTAssertGreaterThanOrEqual(
                    block.zIndex,
                    previousZIndex,
                    "Blocks should be sorted by zIndex ascending"
                )
                previousZIndex = block.zIndex
            }
        }
    }

    /// Test: Merged asset index contains all animations' assets
    func testScenePlayer_mergedAssetIndexContainsAllAssets() async throws {
        let (package, animations) = try loadTestPackage()

        try await MainActor.run {
            let player = ScenePlayer()
            let compiled = try player.compile(package: package, loadedAnimations: animations)

            let mergedIndex = compiled.mergedAssetIndex

            XCTAssertGreaterThanOrEqual(mergedIndex.byId.count, 4, "Should have at least 4 assets")

            for assetId in mergedIndex.byId.keys {
                XCTAssertTrue(
                    assetId.contains("|"),
                    "Asset ID '\(assetId)' should be namespaced with |"
                )
            }
        }
    }

    /// Test: Block timing visibility (no MainActor needed - pure data)
    func testScenePlayer_blockTimingVisibility() {
        let timing = BlockTiming(startFrame: 10, endFrame: 100)

        XCTAssertFalse(timing.isVisible(at: 9), "Should not be visible before startFrame")
        XCTAssertTrue(timing.isVisible(at: 10), "Should be visible at startFrame")
        XCTAssertTrue(timing.isVisible(at: 50), "Should be visible in middle")
        XCTAssertTrue(timing.isVisible(at: 99), "Should be visible at endFrame-1")
        XCTAssertFalse(timing.isVisible(at: 100), "Should not be visible at endFrame (exclusive)")
        XCTAssertFalse(timing.isVisible(at: 101), "Should not be visible after endFrame")
    }

    /// Test: Commands are balanced
    func testScenePlayer_commandsAreBalanced() async throws {
        let (package, animations) = try loadTestPackage()

        try await MainActor.run {
            let player = ScenePlayer()
            let compiled = try player.compile(package: package, loadedAnimations: animations)

            for block in compiled.runtime.blocks {
                player.setUserMediaPresent(blockId: block.blockId, present: true)
            }

            let commands = player.renderCommands(sceneFrameIndex: 0)

            XCTAssertTrue(commands.isBalanced(), "Commands should be balanced (matching begin/end)")
        }
    }

    /// Test: Error when no media blocks
    func testScenePlayer_errorWhenNoMediaBlocks() async throws {
        let emptyScene = Scene(
            schemaVersion: "0.1",
            canvas: Canvas(width: 100, height: 100, fps: 30, durationFrames: 100),
            mediaBlocks: []
        )
        let package = ScenePackage(
            rootURL: URL(fileURLWithPath: "/tmp"),
            scene: emptyScene,
            animFilesByRef: [:],
            imagesRootURL: nil
        )
        let animations = LoadedAnimations()

        try await MainActor.run {
            let player = ScenePlayer()

            XCTAssertThrowsError(try player.compile(package: package, loadedAnimations: animations)) { error in
                guard let sceneError = error as? ScenePlayerError else {
                    XCTFail("Expected ScenePlayerError")
                    return
                }
                if case .noMediaBlocks = sceneError {
                    // Expected
                } else {
                    XCTFail("Expected noMediaBlocks error, got \(sceneError)")
                }
            }
        }
    }
}
