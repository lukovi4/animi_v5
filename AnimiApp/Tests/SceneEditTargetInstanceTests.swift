import XCTest
import TVECore
@testable import AnimiApp

/// Regression tests for scene-edit write-target resolution.
/// Verifies that persistence always targets the editor uiMode scene (not runtime tracking).
@MainActor
final class SceneEditTargetInstanceTests: XCTestCase {

    // MARK: - Unit: resolveWriteTargetForSceneEdit

    func testWriteTarget_sceneEdit_returnsDuplicateId_evenWhenRuntimePointsToOriginal() {
        let originalId = UUID()
        let duplicateId = UUID()
        let target = SceneEditToolModule.resolveWriteTargetForSceneEdit(
            uiMode: .sceneEdit(sceneInstanceId: duplicateId),
            activeSceneInstanceId: originalId
        )
        XCTAssertEqual(target, duplicateId, "Must write to duplicate, not original")
        XCTAssertNotEqual(target, originalId)
    }

    func testWriteTarget_sceneEdit_ignoresNilRuntime() {
        let duplicateId = UUID()
        let target = SceneEditToolModule.resolveWriteTargetForSceneEdit(
            uiMode: .sceneEdit(sceneInstanceId: duplicateId),
            activeSceneInstanceId: nil
        )
        XCTAssertEqual(target, duplicateId)
    }

    func testWriteTarget_timeline_returnsRuntimeId() {
        let runtimeId = UUID()
        let target = SceneEditToolModule.resolveWriteTargetForSceneEdit(
            uiMode: .timeline,
            activeSceneInstanceId: runtimeId
        )
        XCTAssertEqual(target, runtimeId)
    }

    func testWriteTarget_timeline_noRuntime_returnsNil() {
        let target = SceneEditToolModule.resolveWriteTargetForSceneEdit(
            uiMode: .timeline,
            activeSceneInstanceId: nil
        )
        XCTAssertNil(target)
    }

    // MARK: - Handler regression: reset/toggle/remove use editor target

    func testWriteTarget_reset_usesEditorTarget() {
        let originalId = UUID()
        let duplicateId = UUID()
        let target = SceneEditToolModule.resolveWriteTargetForSceneEdit(
            uiMode: .sceneEdit(sceneInstanceId: duplicateId),
            activeSceneInstanceId: originalId
        )
        XCTAssertEqual(target, duplicateId, "Reset must target editor uiMode scene")
    }

    // MARK: - Integration: duplicate → edit → verify isolation

    @MainActor func testDuplicateScene_editDuplicate_originalUnchanged() {
        // Setup: load project with 1 scene
        let store = EditorStore()
        let draft = makeDraft(sceneDurations: [2_000_000])
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))
        let originalId = store.sceneItems[0].id

        // Duplicate
        store.dispatch(.duplicateScene(sceneItemId: originalId))
        XCTAssertEqual(store.sceneItems.count, 2)
        let duplicateId = store.sceneItems[1].id

        // Enter scene edit on duplicate
        store.dispatch(.enterSceneEdit(sceneId: duplicateId))

        // Resolve write target (simulates what EditorViewController does)
        let writeTarget = SceneEditToolModule.resolveWriteTargetForSceneEdit(
            uiMode: store.state.uiMode,
            activeSceneInstanceId: originalId // runtime still points to original!
        )
        XCTAssertEqual(writeTarget, duplicateId)

        // Dispatch edits to write target
        store.dispatch(.setBlockVariant(
            sceneInstanceId: writeTarget!,
            blockId: "b1",
            variantId: "v2"
        ))
        // Verify: duplicate changed, original untouched
        XCTAssertEqual(
            store.state.draft.sceneInstanceStates[duplicateId]?.variantOverrides["b1"],
            "v2"
        )
        XCTAssertNil(
            store.state.draft.sceneInstanceStates[originalId]?.variantOverrides["b1"]
        )
    }

    // MARK: - Helpers

    private func makeDraft(sceneDurations: [TimeUs]) -> ProjectDraft {
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]

        for (index, duration) in sceneDurations.enumerated() {
            let payloadId = UUID()
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "test_scene_\(index)"))
            let item = TimelineItem(
                payloadId: payloadId,
                kind: .scene,
                startUs: nil,
                durationUs: duration
            )
            timeline.tracks[0].items.append(item)
        }

        timeline.payloads = payloads
        draft.canonicalTimeline = timeline
        return draft
    }
}
