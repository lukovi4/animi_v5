import XCTest
@testable import AnimiApp
import TVECore

/// Tests for SceneStateMigrationHelper: runtime hydration of placement state.
final class SceneStateMigrationHelperTests: XCTestCase {

    // MARK: - Test Helpers

    /// Simple MediaInputProvider for testing.
    private struct MockMediaInputProvider: MediaInputProvider {
        var fitModes: [String: FitMode] = [:]

        func defaultFit(forBlockId blockId: String) -> FitMode? {
            fitModes[blockId]
        }
    }

    // MARK: - Default Placement Hydration

    func test_slotWithNilPlacement_andContainDefault_getsContainPlacement() {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]

        let provider = MockMediaInputProvider(fitModes: ["block1": .contain])
        let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)

        let placement = hydrated.mediaSlotsByBlockId?["block1"]?.placement
        XCTAssertNotNil(placement)
        XCTAssertEqual(placement?.fitMode, .contain)
        XCTAssertTrue(placement?.isDefault ?? false)
    }

    func test_slotWithNilPlacement_andNoDefault_getsCoverPlacement() {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]

        let provider = MockMediaInputProvider(fitModes: [:])  // no defaultFit
        let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)

        let placement = hydrated.mediaSlotsByBlockId?["block1"]?.placement
        XCTAssertNotNil(placement)
        XCTAssertEqual(placement?.fitMode, .cover, "Fallback must be .cover")
    }

    func test_slotWithExistingPlacement_isNotOverwritten() {
        var state = SceneState.empty
        let existingPlacement = MediaPlacementState(fitMode: .fill, offsetX: 10, offsetY: 20, userScale: 1.5, rotationDegrees: 30)
        state.mediaSlotsByBlockId = [
            "block1": .photo(
                mediaRef: .file("Media/photo.jpg", mediaKind: .photo),
                placement: existingPlacement
            )
        ]

        let provider = MockMediaInputProvider(fitModes: ["block1": .cover])
        let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)

        let placement = hydrated.mediaSlotsByBlockId?["block1"]?.placement
        XCTAssertEqual(placement, existingPlacement, "Existing placement must not be overwritten")
    }

    // MARK: - Matrix2D Decompose Migration

    func test_legacyTransform_cleanMatrix_decomposedIntoPlacement() {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]
        // Legacy: T(10, 20) * R(45°) * S(2.0)
        let s = Matrix2D.scale(2.0)
        let r = Matrix2D.rotationDegrees(45)
        let t = Matrix2D.translation(x: 10, y: 20)
        state.userTransforms["block1"] = t.concatenating(r.concatenating(s))

        let provider = MockMediaInputProvider(fitModes: ["block1": .cover])
        let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)

        let placement = hydrated.mediaSlotsByBlockId?["block1"]?.placement
        XCTAssertNotNil(placement)
        XCTAssertEqual(placement?.fitMode, .cover)
        XCTAssertEqual(placement?.offsetX ?? 0, 10, accuracy: 1e-3)
        XCTAssertEqual(placement?.offsetY ?? 0, 20, accuracy: 1e-3)
        XCTAssertEqual(placement?.userScale ?? 0, 2.0, accuracy: 1e-3)
        XCTAssertEqual(placement?.rotationDegrees ?? 0, 45, accuracy: 1e-2)
    }

    func test_legacyTransform_dirtyMatrix_fallsBackToDefault() {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]
        // Non-uniform scale — will fail decompose
        state.userTransforms["block1"] = Matrix2D.scale(x: 2.0, y: 3.0)

        let provider = MockMediaInputProvider(fitModes: ["block1": .contain])
        let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)

        let placement = hydrated.mediaSlotsByBlockId?["block1"]?.placement
        XCTAssertNotNil(placement)
        XCTAssertEqual(placement?.fitMode, .contain, "Failed decompose must fall back to default")
        XCTAssertTrue(placement?.isDefault ?? false)
    }

    func test_legacyTransform_identityMatrix_producesDefaultPlacement() {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]
        state.userTransforms["block1"] = .identity

        let provider = MockMediaInputProvider(fitModes: ["block1": .cover])
        let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)

        let placement = hydrated.mediaSlotsByBlockId?["block1"]?.placement
        XCTAssertNotNil(placement)
        XCTAssertTrue(placement?.isDefault ?? false)
    }

    // MARK: - userTransforms Cleanup

    func test_mediaBlockTransform_removedAfterMigration() {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]
        state.userTransforms["block1"] = Matrix2D.translation(x: 5, y: 5)

        let provider = MockMediaInputProvider(fitModes: [:])
        let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)

        XCTAssertNil(
            hydrated.userTransforms["block1"],
            "Media block's userTransform must be removed after migration"
        )
    }

    func test_staleTransform_withoutSlot_discarded() {
        var state = SceneState.empty
        // No media slot for "orphan", but has a transform
        state.userTransforms["orphan"] = Matrix2D.translation(x: 100, y: 200)

        let provider = MockMediaInputProvider(fitModes: [:])
        let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)

        XCTAssertTrue(
            hydrated.userTransforms.isEmpty,
            "Stale transform without media slot must be discarded"
        )
    }

    func test_allTransforms_cleanedUp() {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]
        state.userTransforms = [
            "block1": Matrix2D.translation(x: 1, y: 2),
            "stale1": .identity,
            "stale2": Matrix2D.scale(1.5)
        ]

        let provider = MockMediaInputProvider(fitModes: [:])
        let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)

        XCTAssertTrue(
            hydrated.userTransforms.isEmpty,
            "All userTransforms must be cleaned up after hydration"
        )
    }

    // MARK: - needsHydration

    func test_needsHydration_nilPlacement_returnsTrue() {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]

        XCTAssertTrue(SceneStateMigrationHelper.needsHydration(state))
    }

    func test_needsHydration_staleTransform_returnsTrue() {
        var state = SceneState.empty
        state.userTransforms["block1"] = .identity

        XCTAssertTrue(SceneStateMigrationHelper.needsHydration(state))
    }

    func test_needsHydration_fullyHydrated_returnsFalse() {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .photo(
                mediaRef: .file("Media/photo.jpg", mediaKind: .photo),
                placement: .default(fitMode: .cover)
            )
        ]

        XCTAssertFalse(SceneStateMigrationHelper.needsHydration(state))
    }

    func test_needsHydration_emptyState_returnsFalse() {
        XCTAssertFalse(SceneStateMigrationHelper.needsHydration(.empty))
    }

    // MARK: - MediaPlacementState Normalization

    func test_rotationDegrees_normalized() {
        let p1 = MediaPlacementState(fitMode: .cover, rotationDegrees: 270)
        XCTAssertEqual(p1.rotationDegrees, -90, accuracy: 1e-10, "270° should normalize to -90°")

        let p2 = MediaPlacementState(fitMode: .cover, rotationDegrees: -270)
        XCTAssertEqual(p2.rotationDegrees, 90, accuracy: 1e-10, "-270° should normalize to 90°")

        let p3 = MediaPlacementState(fitMode: .cover, rotationDegrees: 180)
        XCTAssertEqual(p3.rotationDegrees, 180, accuracy: 1e-10, "180° should stay 180° ((-180, 180])")

        let p4 = MediaPlacementState(fitMode: .cover, rotationDegrees: -180)
        // -180 is excluded from range, should become 180
        XCTAssertEqual(p4.rotationDegrees, 180, accuracy: 1e-10, "-180° should normalize to 180°")

        let p5 = MediaPlacementState(fitMode: .cover, rotationDegrees: 0)
        XCTAssertEqual(p5.rotationDegrees, 0, accuracy: 1e-10)

        let p6 = MediaPlacementState(fitMode: .cover, rotationDegrees: 540)
        XCTAssertEqual(p6.rotationDegrees, 180, accuracy: 1e-10, "540° should normalize to 180°")
    }

    func test_userScale_clamped() {
        let p1 = MediaPlacementState(fitMode: .cover, userScale: 0.1)
        XCTAssertEqual(p1.userScale, 0.25, "Scale below 0.25 must clamp to 0.25")

        let p2 = MediaPlacementState(fitMode: .cover, userScale: 10.0)
        XCTAssertEqual(p2.userScale, 6.0, "Scale above 6.0 must clamp to 6.0")

        let p3 = MediaPlacementState(fitMode: .cover, userScale: 3.0)
        XCTAssertEqual(p3.userScale, 3.0, "Scale within range must not be clamped")
    }

    // MARK: - Video Slot Migration

    func test_videoSlot_nilPlacement_hydrated() {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block1": .video(
                mediaRef: .file("Media/UserMedia/clip.mp4", mediaKind: .video),
                videoWindow: PersistedVideoSelection(trimStart: 1.0, trimEnd: 10.0)
            )
        ]

        let provider = MockMediaInputProvider(fitModes: ["block1": .fill])
        let hydrated = SceneStateMigrationHelper.hydrate(state, mediaInputProvider: provider)

        let slot = hydrated.mediaSlotsByBlockId?["block1"]
        XCTAssertNotNil(slot?.placement)
        XCTAssertEqual(slot?.placement?.fitMode, .fill)
        // Video window must be preserved
        XCTAssertEqual(slot?.videoWindow?.trimStart, 1.0)
        XCTAssertEqual(slot?.videoWindow?.trimEnd, 10.0)
    }
}
