import XCTest
@testable import AnimiApp
@testable import TVECore

/// Tests for ExportMediaSnapshot and ExportBackgroundSnapshot.
final class ExportMediaSnapshotTests: XCTestCase {

    // MARK: - ExportMediaSnapshot

    func test_buildFromCompiledScene_noBindings() {
        let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 100)
        let scene = Scene(
            schemaVersion: "1.0",
            sceneId: "test",
            canvas: canvas,
            background: nil,
            mediaBlocks: []
        )
        let runtime = SceneRuntime(
            scene: scene,
            canvas: canvas,
            blocks: [],
            durationFrames: 100,
            fps: 30
        )
        let compiled = CompiledScene(
            runtime: runtime,
            mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry(),
            bindingAssetIds: []
        )
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)

        let snapshot = ExportMediaSnapshot.build(
            from: compiled,
            resolver: resolver,
            videoSelections: [:],
            runtime: runtime
        )

        XCTAssertTrue(snapshot.imageRefs.isEmpty, "No bindings → no image refs")
        XCTAssertTrue(snapshot.videoRefs.isEmpty, "No video selections → no video refs")
    }

    // MARK: - ExportBackgroundSnapshot

    func test_buildFromNilOverride_returnsNil() {
        let result = ExportBackgroundSnapshot.build(
            from: nil,
            effectiveState: nil
        )
        XCTAssertNil(result, "Nil override should return nil snapshot")
    }

    func test_buildFromEmptyRegions_returnsNil() {
        let override = ProjectBackgroundOverride(regions: [:])
        // We can't easily construct EffectiveBackgroundState without a preset,
        // so just verify the nil case
        let result = ExportBackgroundSnapshot.build(
            from: override,
            effectiveState: nil
        )
        XCTAssertNil(result)
    }
}
