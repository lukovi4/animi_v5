import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// PR-B: Edit Mode Timing Bypass Tests
///
/// Tests verify that in edit mode:
/// - All blocks are rendered regardless of timing
/// - hitTest finds blocks with delayed timing
/// - overlays include blocks with delayed timing
/// - preview mode still respects timing
final class ScenePlayerEditModeTests: XCTestCase {

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

    // MARK: - Helpers

    /// Creates a scene with one block that has delayed timing (startFrame > 0).
    /// The block is NOT visible at frame 0 in preview mode, but SHOULD be visible in edit mode.
    private func createSceneWithDelayedBlock() throws -> (ScenePackage, LoadedAnimations) {
        // Minimal no-anim Lottie JSON with mediaInput and binding
        let noAnimJSON = """
        {
          "v": "5.12.1", "fr": 30, "ip": 0, "op": 1, "w": 540, "h": 960,
          "nm": "no-anim", "ddd": 0,
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
        let lottie = try decoder.decode(LottieJSON.self, from: noAnimJSON.data(using: .utf8)!)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img_1.png"])

        // Create scene with TWO blocks:
        // - block_visible: startFrame=0, endFrame=300 (always visible)
        // - block_delayed: startFrame=30, endFrame=300 (NOT visible at frame 0)
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test-delayed-timing",
            canvas: Canvas(width: 540, height: 960, fps: 30, durationFrames: 300),
            mediaBlocks: [
                MediaBlock(
                    id: "block_visible",
                    zIndex: 0,
                    rect: Rect(x: 0, y: 0, width: 540, height: 480),
                    containerClip: .slotRect,
                    timing: Timing(startFrame: 0, endFrame: 300),
                    input: MediaInput(
                        rect: Rect(x: 0, y: 0, width: 540, height: 480),
                        bindingKey: "media",
                        allowedMedia: ["photo"]
                    ),
                    variants: [
                        Variant(id: "no-anim", animRef: "no-anim.json")
                    ]
                ),
                MediaBlock(
                    id: "block_delayed",
                    zIndex: 1,
                    rect: Rect(x: 0, y: 480, width: 540, height: 480),
                    containerClip: .slotRect,
                    // DELAYED: starts at frame 30, so NOT visible at editFrameIndex (0)
                    timing: Timing(startFrame: 30, endFrame: 300),
                    input: MediaInput(
                        rect: Rect(x: 0, y: 0, width: 540, height: 480),
                        bindingKey: "media",
                        allowedMedia: ["photo"]
                    ),
                    variants: [
                        Variant(id: "no-anim", animRef: "no-anim.json")
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
            lottieByAnimRef: ["no-anim.json": lottie],
            assetIndexByAnimRef: ["no-anim.json": assetIndex]
        )

        return (package, animations)
    }

    // MARK: - T1: Edit Mode Shows All Blocks Regardless of Timing

    /// T1: In edit mode, blocks with startFrame > 0 are still rendered.
    /// This is the core PR-B requirement: timing bypass in edit mode.
    func test_editMode_showsAllBlocks_regardlessOfTiming() async throws {
        let (package, animations) = try createSceneWithDelayedBlock()

        try await MainActor.run {
            let player = ScenePlayer()
            _ = try player.compile(package: package, loadedAnimations: animations)

            // Set userMediaPresent for all blocks
            player.setUserMediaPresent(blockId: "block_visible", present: true)
            player.setUserMediaPresent(blockId: "block_delayed", present: true)

            // Edit mode should show BOTH blocks (including delayed one)
            let editCommands = player.renderCommands(mode: .edit)

            // Count block groups
            let blockGroups = editCommands.filter {
                if case .beginGroup(let name) = $0 { return name.hasPrefix("Block:") }
                return false
            }

            XCTAssertEqual(blockGroups.count, 2,
                "Edit mode should render 2 blocks (including delayed block_delayed)")

            // Verify both blocks are present
            let blockNames = editCommands.compactMap { cmd -> String? in
                if case .beginGroup(let name) = cmd, name.hasPrefix("Block:") {
                    return String(name.dropFirst("Block:".count))
                }
                return nil
            }
            XCTAssertTrue(blockNames.contains("block_visible"), "Should contain block_visible")
            XCTAssertTrue(blockNames.contains("block_delayed"), "Should contain block_delayed")
        }
    }

    // MARK: - T2: Preview Mode Respects Timing

    /// T2: In preview mode at frame 0, block with startFrame=30 is NOT rendered.
    /// This verifies the timing filter still works in preview mode.
    func test_previewMode_hidesBlockBeforeStartFrame() async throws {
        let (package, animations) = try createSceneWithDelayedBlock()

        try await MainActor.run {
            let player = ScenePlayer()
            _ = try player.compile(package: package, loadedAnimations: animations)

            // Set userMediaPresent for all blocks
            player.setUserMediaPresent(blockId: "block_visible", present: true)
            player.setUserMediaPresent(blockId: "block_delayed", present: true)

            // Preview at frame 0: delayed block should NOT be visible
            let previewCommandsAt0 = player.renderCommands(mode: .preview, sceneFrameIndex: 0)

            let blockGroupsAt0 = previewCommandsAt0.filter {
                if case .beginGroup(let name) = $0 { return name.hasPrefix("Block:") }
                return false
            }

            XCTAssertEqual(blockGroupsAt0.count, 1,
                "Preview at frame 0 should render only 1 block (block_delayed not visible yet)")

            // Preview at frame 30: delayed block SHOULD be visible
            let previewCommandsAt30 = player.renderCommands(mode: .preview, sceneFrameIndex: 30)

            let blockGroupsAt30 = previewCommandsAt30.filter {
                if case .beginGroup(let name) = $0 { return name.hasPrefix("Block:") }
                return false
            }

            XCTAssertEqual(blockGroupsAt30.count, 2,
                "Preview at frame 30 should render 2 blocks (block_delayed now visible)")
        }
    }

    // MARK: - T3: Edit Mode hitTest Finds Delayed Block

    /// T3: hitTest in edit mode finds a block with delayed timing.
    func test_editMode_hitTest_findsBlockWithDelayedTiming() async throws {
        let (package, animations) = try createSceneWithDelayedBlock()

        try await MainActor.run {
            let player = ScenePlayer()
            _ = try player.compile(package: package, loadedAnimations: animations)

            // Set userMediaPresent for all blocks
            player.setUserMediaPresent(blockId: "block_visible", present: true)
            player.setUserMediaPresent(blockId: "block_delayed", present: true)

            // Hit test at center of delayed block (y: 480-960, so center is ~720)
            // Using frame 0 (edit always uses editFrameIndex)
            let delayedBlockCenter = Vec2D(x: 270, y: 720)

            // Edit mode: should find delayed block
            let editHit = player.hitTest(point: delayedBlockCenter, frame: 0, mode: .edit)
            XCTAssertEqual(editHit, "block_delayed",
                "Edit mode hitTest should find block_delayed despite timing")

            // Preview mode at frame 0: should NOT find delayed block
            let previewHit = player.hitTest(point: delayedBlockCenter, frame: 0, mode: .preview)
            XCTAssertNil(previewHit,
                "Preview mode hitTest at frame 0 should NOT find block_delayed (not visible yet)")

            // Preview mode at frame 30: SHOULD find delayed block
            let previewHitAt30 = player.hitTest(point: delayedBlockCenter, frame: 30, mode: .preview)
            XCTAssertEqual(previewHitAt30, "block_delayed",
                "Preview mode hitTest at frame 30 should find block_delayed (now visible)")
        }
    }

    // MARK: - T4: Edit Mode overlays Includes Delayed Block

    /// T4: overlays in edit mode includes a block with delayed timing.
    func test_editMode_overlays_includesBlockWithDelayedTiming() async throws {
        let (package, animations) = try createSceneWithDelayedBlock()

        try await MainActor.run {
            let player = ScenePlayer()
            _ = try player.compile(package: package, loadedAnimations: animations)

            // Set userMediaPresent for all blocks
            player.setUserMediaPresent(blockId: "block_visible", present: true)
            player.setUserMediaPresent(blockId: "block_delayed", present: true)

            // Edit mode overlays at frame 0
            let editOverlays = player.overlays(frame: 0, mode: .edit)

            XCTAssertEqual(editOverlays.count, 2,
                "Edit mode overlays should include 2 blocks (including delayed)")

            let overlayBlockIds = Set(editOverlays.map { $0.blockId })
            XCTAssertTrue(overlayBlockIds.contains("block_visible"), "Should have overlay for block_visible")
            XCTAssertTrue(overlayBlockIds.contains("block_delayed"), "Should have overlay for block_delayed")

            // Preview mode overlays at frame 0: should NOT include delayed block
            let previewOverlays = player.overlays(frame: 0, mode: .preview)

            XCTAssertEqual(previewOverlays.count, 1,
                "Preview mode overlays at frame 0 should include only 1 block")
            XCTAssertEqual(previewOverlays.first?.blockId, "block_visible",
                "Only block_visible should have overlay in preview at frame 0")
        }
    }

    // MARK: - T5: BlockVisibilityPolicy Direct Test

    /// T5: SceneRenderPlan.renderCommands respects BlockVisibilityPolicy.
    func test_sceneRenderPlan_visibilityPolicy() async throws {
        let (package, animations) = try createSceneWithDelayedBlock()

        try await MainActor.run {
            let player = ScenePlayer()
            let compiled = try player.compile(package: package, loadedAnimations: animations)

            // Test .timeline policy at frame 0 (should filter delayed block)
            let timelineCommands = SceneRenderPlan.renderCommands(
                for: compiled.runtime,
                sceneFrameIndex: 0,
                userMediaPresent: ["block_visible": true, "block_delayed": true],
                visibility: .timeline
            )

            let timelineBlockCount = timelineCommands.filter {
                if case .beginGroup(let name) = $0 { return name.hasPrefix("Block:") }
                return false
            }.count

            XCTAssertEqual(timelineBlockCount, 1,
                "visibility: .timeline should render only 1 block at frame 0")

            // Test .all policy at frame 0 (should include delayed block)
            let allCommands = SceneRenderPlan.renderCommands(
                for: compiled.runtime,
                sceneFrameIndex: 0,
                userMediaPresent: ["block_visible": true, "block_delayed": true],
                visibility: .all
            )

            let allBlockCount = allCommands.filter {
                if case .beginGroup(let name) = $0 { return name.hasPrefix("Block:") }
                return false
            }.count

            XCTAssertEqual(allBlockCount, 2,
                "visibility: .all should render 2 blocks at frame 0 (including delayed)")
        }
    }
}
