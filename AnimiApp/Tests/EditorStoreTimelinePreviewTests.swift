import XCTest
import TVECore
@testable import AnimiApp

/// Unit tests for Timeline Preview/Commit Split.
/// Tests verify that trim preview actions route to preview callback,
/// while commit actions route to timeline changed callback.
@MainActor
final class EditorStoreTimelinePreviewTests: XCTestCase {

    // MARK: - Test Helpers

    /// Creates default scene sequence for testing.
    private func makeDefaultSceneSequence() -> [SceneTypeDefault] {
        [SceneTypeDefault(sceneTypeId: "test_scene_0", baseDurationUs: 3_000_000)]
    }

    /// Creates a store with one scene and returns callback counters.
    private func makeStoreWithCounters() -> (store: EditorStore, previewCount: Box<Int>, commitCount: Box<Int>) {
        let store = EditorStore()
        let previewCount = Box(0)
        let commitCount = Box(0)

        // Load project first
        let draft = ProjectDraft.create(for: "test-template")
        store.dispatch(.loadProject(
            draft: draft,
            templateFPS: 30,
            defaultSceneSequence: makeDefaultSceneSequence()
        ))

        // Setup callbacks AFTER loadProject to avoid counting initial timeline change
        store.onTimelinePreviewChanged = { _ in
            previewCount.value += 1
        }
        store.onTimelineChanged = { _ in
            commitCount.value += 1
        }

        return (store, previewCount, commitCount)
    }

    /// Simple reference wrapper for counters in closures.
    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - Test 1: Trim Preview Calls Preview Callback Only

    /// Test: trimScene with .began/.changed calls preview callback, NOT commit callback.
    func testTrimPreview_callsPreviewCallback_notCommitCallback() {
        // Given: store with one scene
        let (store, previewCount, commitCount) = makeStoreWithCounters()
        let sceneId = store.sceneItems.first!.id

        // When: dispatch trim .began
        store.dispatch(.trimScene(
            sceneId: sceneId,
            phase: .began,
            newDurationUs: 4_000_000,
            edge: .trailing
        ))

        // Then: preview callback called, commit callback NOT called
        XCTAssertEqual(previewCount.value, 1, "Preview callback should be called on .began")
        XCTAssertEqual(commitCount.value, 0, "Commit callback should NOT be called on .began")

        // When: dispatch trim .changed
        store.dispatch(.trimScene(
            sceneId: sceneId,
            phase: .changed,
            newDurationUs: 5_000_000,
            edge: .trailing
        ))

        // Then: preview callback called again, commit still not called
        XCTAssertEqual(previewCount.value, 2, "Preview callback should be called on .changed")
        XCTAssertEqual(commitCount.value, 0, "Commit callback should NOT be called on .changed")
    }

    // MARK: - Test 2: Trim Ended Calls Commit Callback Only

    /// Test: trimScene with .ended calls commit callback, NOT preview callback.
    func testTrimEnded_callsCommitCallback_notPreviewCallback() {
        // Given: store with one scene, after preview actions
        let (store, previewCount, commitCount) = makeStoreWithCounters()
        let sceneId = store.sceneItems.first!.id

        // Simulate preview first
        store.dispatch(.trimScene(sceneId: sceneId, phase: .began, newDurationUs: 4_000_000, edge: .trailing))
        store.dispatch(.trimScene(sceneId: sceneId, phase: .changed, newDurationUs: 5_000_000, edge: .trailing))

        // Reset counters before testing .ended
        previewCount.value = 0
        commitCount.value = 0

        // When: dispatch trim .ended
        store.dispatch(.trimScene(
            sceneId: sceneId,
            phase: .ended,
            newDurationUs: 5_000_000,
            edge: .trailing
        ))

        // Then: commit callback called, preview callback NOT called
        XCTAssertEqual(commitCount.value, 1, "Commit callback should be called on .ended")
        XCTAssertEqual(previewCount.value, 0, "Preview callback should NOT be called on .ended")
    }

    // MARK: - Test 3: Non-Trim Actions Call Commit Callback Only

    /// Test: reorder/add/delete call commit callback, NOT preview callback.
    func testNonTrimActions_callCommitCallback_notPreviewCallback() {
        // Given: store with one scene
        let (store, previewCount, commitCount) = makeStoreWithCounters()

        // When: dispatch addScene
        store.dispatch(.addScene(sceneTypeId: "test_scene_1", durationUs: 2_000_000))

        // Then: commit callback called, preview NOT called
        XCTAssertEqual(commitCount.value, 1, "Commit callback should be called on addScene")
        XCTAssertEqual(previewCount.value, 0, "Preview callback should NOT be called on addScene")

        // Reset counters
        previewCount.value = 0
        commitCount.value = 0

        // When: dispatch reorderScene
        let firstSceneId = store.sceneItems.first!.id
        store.dispatch(.reorderScene(sceneId: firstSceneId, toIndex: 1))

        // Then: commit callback called, preview NOT called
        XCTAssertEqual(commitCount.value, 1, "Commit callback should be called on reorderScene")
        XCTAssertEqual(previewCount.value, 0, "Preview callback should NOT be called on reorderScene")

        // Reset counters
        previewCount.value = 0
        commitCount.value = 0

        // When: dispatch deleteScene (need 2+ scenes)
        let secondSceneId = store.sceneItems.last!.id
        store.dispatch(.deleteScene(sceneId: secondSceneId))

        // Then: commit callback called, preview NOT called
        XCTAssertEqual(commitCount.value, 1, "Commit callback should be called on deleteScene")
        XCTAssertEqual(previewCount.value, 0, "Preview callback should NOT be called on deleteScene")
    }
}
