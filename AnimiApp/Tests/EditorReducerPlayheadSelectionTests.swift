import XCTest
import TVECore
@testable import AnimiApp

/// Tests for explicit scene selection + follow-playhead mode.
/// Verifies that selection is an explicit user action and follow mode
/// is activated only after focusScene.
final class EditorReducerPlayheadSelectionTests: XCTestCase {

    // MARK: - Test Helpers

    /// Creates a test draft with specified scene durations.
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

    /// Creates a loaded EditorState from a draft.
    private func makeLoadedState(sceneDurations: [TimeUs], fps: Int = 30) -> EditorState {
        let draft = makeDraft(sceneDurations: sceneDurations)
        let defaults = sceneDurations.enumerated().map {
            SceneTypeDefault(sceneTypeId: "test_scene_\($0.offset)", baseDurationUs: $0.element)
        }
        let result = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: fps, defaultSceneSequence: defaults)
        )
        return result.state
    }

    // MARK: - 1. loadProject → selection = .none, mode = .inactive

    func test_loadProject_selectionNone_modeInactive() {
        let state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000])

        XCTAssertEqual(state.selection, .none)
        XCTAssertEqual(state.timelineSceneSelectionMode, .inactive)
        XCTAssertEqual(state.playheadCompressedFrame, 0)
    }

    // MARK: - 2. focusScene → sets selection and followPlayhead mode

    func test_focusScene_setsSelection_and_followMode() {
        let state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000, 1_000_000])
        let scene2Id = state.sceneItems[1].id

        let result = EditorReducer.reduce(state: state, action: .focusScene(sceneId: scene2Id))

        XCTAssertEqual(result.state.selection, .scene(id: scene2Id))
        XCTAssertEqual(result.state.timelineSceneSelectionMode, .followPlayhead)

        // Playhead should be at scene 2 boundary
        let mapper = result.state.makePlayheadMapper()
        let expectedFrame = mapper.sceneBoundaryCompressedFrame(forSceneAt: 1)
        XCTAssertEqual(result.state.playheadCompressedFrame, expectedFrame)
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    // MARK: - 3. setPlayhead in inactive mode → does NOT change selection

    func test_setPlayhead_inactive_doesNotChangeSelection() {
        let state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000, 1_000_000])
        // State starts with selection = .none, mode = .inactive

        // Move playhead to middle of scene 2
        let mapper = state.makePlayheadMapper()
        let scene2Start = mapper.sceneBoundaryCompressedFrame(forSceneAt: 1)

        let result = EditorReducer.reduce(state: state, action: .setPlayhead(compressedFrame: scene2Start + 5))

        // Selection should remain .none (mode is inactive)
        XCTAssertEqual(result.state.selection, .none)
        XCTAssertEqual(result.state.timelineSceneSelectionMode, .inactive)
    }

    // MARK: - 4. setPlayhead in followPlayhead mode → updates selection

    func test_setPlayhead_followPlayhead_updatesSelection() {
        var state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000, 1_000_000])
        let scene1Id = state.sceneItems[0].id
        let scene2Id = state.sceneItems[1].id

        // Activate follow mode by focusing scene 1
        let focusResult = EditorReducer.reduce(state: state, action: .focusScene(sceneId: scene1Id))
        state = focusResult.state
        XCTAssertEqual(state.timelineSceneSelectionMode, .followPlayhead)

        // Move playhead to scene 2
        let mapper = state.makePlayheadMapper()
        let scene2Start = mapper.sceneBoundaryCompressedFrame(forSceneAt: 1)
        let result = EditorReducer.reduce(state: state, action: .setPlayhead(compressedFrame: scene2Start + 5))

        // Selection should follow to scene 2
        XCTAssertEqual(result.state.selection, .scene(id: scene2Id))
        XCTAssertEqual(result.state.timelineSceneSelectionMode, .followPlayhead)
    }

    // MARK: - 5. select(.none) → clears selection and mode

    func test_selectNone_clearsSelection_and_mode() {
        var state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000])
        let scene1Id = state.sceneItems[0].id

        // Activate follow mode first
        let focusResult = EditorReducer.reduce(state: state, action: .focusScene(sceneId: scene1Id))
        state = focusResult.state
        XCTAssertEqual(state.timelineSceneSelectionMode, .followPlayhead)

        // Clear selection
        let result = EditorReducer.reduce(state: state, action: .select(selection: .none))

        XCTAssertEqual(result.state.selection, .none)
        XCTAssertEqual(result.state.timelineSceneSelectionMode, .inactive)
    }

    // MARK: - 6. select(.audio) → clears follow mode, playhead does not reselect

    func test_selectAudio_clearsFollowMode_playheadDoesNotReselect() {
        var state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000])
        let scene1Id = state.sceneItems[0].id

        // Activate follow mode
        let focusResult = EditorReducer.reduce(state: state, action: .focusScene(sceneId: scene1Id))
        state = focusResult.state

        // Select audio
        let audioResult = EditorReducer.reduce(state: state, action: .select(selection: .audio))
        state = audioResult.state
        XCTAssertEqual(state.selection, .audio)
        XCTAssertEqual(state.timelineSceneSelectionMode, .inactive)

        // Move playhead — should NOT re-select scene (mode is inactive)
        let result = EditorReducer.reduce(state: state, action: .setPlayhead(compressedFrame: 5))
        XCTAssertEqual(result.state.selection, .audio)
    }

    // MARK: - 7. select(.scene) in timeline mode → no-op

    func test_selectScene_inTimelineMode_isNoOp() {
        let state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000])
        let scene2Id = state.sceneItems[1].id

        let result = EditorReducer.reduce(state: state, action: .select(selection: .scene(id: scene2Id)))

        // Selection should stay .none (direct .select(.scene) is no-op in timeline mode)
        XCTAssertEqual(result.state.selection, .none)
        XCTAssertEqual(result.state.timelineSceneSelectionMode, .inactive)
    }

    // MARK: - 8. exitSceneEdit with followPlayhead → rebinds selection

    func test_exitSceneEdit_followPlayhead_rebindsSelection() {
        var state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000, 1_000_000])
        let scene2Id = state.sceneItems[1].id
        let scene3Id = state.sceneItems[2].id

        // Focus scene 3 (activates follow mode)
        let focusResult = EditorReducer.reduce(state: state, action: .focusScene(sceneId: scene3Id))
        state = focusResult.state
        XCTAssertEqual(state.timelineSceneSelectionMode, .followPlayhead)

        // Enter scene edit on scene 2 (saves playhead)
        let enterResult = EditorReducer.reduce(state: state, action: .enterSceneEdit(sceneId: scene2Id))
        state = enterResult.state
        XCTAssertEqual(state.uiMode, .sceneEdit(sceneInstanceId: scene2Id))

        // Exit scene edit — follow mode preserved, selection rebinds from restored playhead
        let exitResult = EditorReducer.reduce(state: state, action: .exitSceneEdit)

        XCTAssertEqual(exitResult.state.uiMode, .timeline)
        XCTAssertEqual(exitResult.state.timelineSceneSelectionMode, .followPlayhead)
        XCTAssertEqual(exitResult.state.selection, .scene(id: scene3Id))
    }

    // MARK: - 9. exitSceneEdit with inactive mode → does not auto-select

    func test_exitSceneEdit_inactive_doesNotAutoSelect() {
        var state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000])
        let scene1Id = state.sceneItems[0].id

        // Don't activate follow mode — enter scene edit directly
        // First focus to get into scene edit, then deactivate follow mode
        // Simulate: mode is inactive when entering scene edit
        state.timelineSceneSelectionMode = .inactive
        state.selection = .none

        // Enter scene edit
        let enterResult = EditorReducer.reduce(state: state, action: .enterSceneEdit(sceneId: scene1Id))
        state = enterResult.state

        // Exit scene edit — mode still inactive, no auto-selection
        let exitResult = EditorReducer.reduce(state: state, action: .exitSceneEdit)

        XCTAssertEqual(exitResult.state.uiMode, .timeline)
        XCTAssertEqual(exitResult.state.timelineSceneSelectionMode, .inactive)
        XCTAssertEqual(exitResult.state.selection, .none)
    }

    // MARK: - 10. focusScene with invalid ID → no-op

    func test_focusScene_invalidId_isNoOp() {
        let state = makeLoadedState(sceneDurations: [1_000_000])
        let originalPlayhead = state.playheadCompressedFrame
        let originalSelection = state.selection

        let result = EditorReducer.reduce(state: state, action: .focusScene(sceneId: UUID()))

        XCTAssertEqual(result.state.playheadCompressedFrame, originalPlayhead)
        XCTAssertEqual(result.state.selection, originalSelection)
        XCTAssertEqual(result.state.timelineSceneSelectionMode, .inactive)
    }

    // MARK: - 11. sceneIdAtPlayhead returns correct scene

    func test_sceneIdAtPlayhead_returnsCorrectScene() {
        let state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000, 1_000_000])

        // At frame 0 → first scene
        XCTAssertEqual(state.sceneIdAtPlayhead(), state.sceneItems[0].id)

        // At scene 2 start → second scene
        var state2 = state
        let mapper = state.makePlayheadMapper()
        state2.playheadCompressedFrame = mapper.sceneBoundaryCompressedFrame(forSceneAt: 1)
        XCTAssertEqual(state2.sceneIdAtPlayhead(), state.sceneItems[1].id)
    }

    // MARK: - 12. restoreSnapshot with inactive mode → does not auto-select

    func test_restoreSnapshot_inactive_doesNotAutoSelect() {
        var state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000])
        // State is inactive by default after load
        XCTAssertEqual(state.timelineSceneSelectionMode, .inactive)

        // Create snapshot (inactive mode, .none selection)
        let snapshot = EditorSnapshot(from: state)

        // Simulate undo restore
        state.restore(from: snapshot)

        // In inactive mode, restoreNormalizedSnapshot should NOT auto-select
        // (mimics EditorStore.restoreNormalizedSnapshot logic)
        if state.uiMode == .timeline && state.timelineSceneSelectionMode == .followPlayhead {
            if let sceneId = state.sceneIdAtPlayhead() {
                state.selection = .scene(id: sceneId)
            }
        }

        XCTAssertEqual(state.selection, .none)
        XCTAssertEqual(state.timelineSceneSelectionMode, .inactive)
    }

    // MARK: - 13. restoreSnapshot with followPlayhead → rebinds selection

    func test_restoreSnapshot_followPlayhead_rebindsSelection() {
        var state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000])
        let scene1Id = state.sceneItems[0].id

        // Activate follow mode
        let focusResult = EditorReducer.reduce(state: state, action: .focusScene(sceneId: scene1Id))
        state = focusResult.state
        XCTAssertEqual(state.timelineSceneSelectionMode, .followPlayhead)

        // Create snapshot (follow mode, scene selected)
        let snapshot = EditorSnapshot(from: state)

        // Mutate state (simulate some change)
        state.selection = .none

        // Restore from snapshot
        state.restore(from: snapshot)

        // In follow mode, restoreNormalizedSnapshot re-derives selection
        if state.uiMode == .timeline && state.timelineSceneSelectionMode == .followPlayhead {
            if let sceneId = state.sceneIdAtPlayhead() {
                state.selection = .scene(id: sceneId)
            }
        }

        XCTAssertEqual(state.selection, .scene(id: scene1Id))
        XCTAssertEqual(state.timelineSceneSelectionMode, .followPlayhead)
    }

    // MARK: - 14. deleteScene in followPlayhead → rebinds selection

    func test_deleteScene_followPlayhead_rebindsSelection() {
        var state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000, 1_000_000])
        let scene2Id = state.sceneItems[1].id

        // Focus scene 2 (activates follow mode)
        let focusResult = EditorReducer.reduce(state: state, action: .focusScene(sceneId: scene2Id))
        state = focusResult.state
        XCTAssertEqual(state.selection, .scene(id: scene2Id))
        XCTAssertEqual(state.timelineSceneSelectionMode, .followPlayhead)

        // Delete scene 2
        let deleteResult = EditorReducer.reduce(state: state, action: .deleteScene(sceneId: scene2Id))
        let newState = deleteResult.state

        // Selection must not point to deleted scene — should rebind to scene under playhead
        XCTAssertEqual(newState.timelineSceneSelectionMode, .followPlayhead)
        if case .scene(let selectedId) = newState.selection {
            XCTAssertNotEqual(selectedId, scene2Id, "Selection must not point to deleted scene")
            XCTAssertTrue(newState.sceneItems.contains(where: { $0.id == selectedId }),
                          "Selected scene must exist in timeline")
        } else {
            XCTFail("Expected .scene selection after delete in follow mode")
        }
    }

    // MARK: - 15. reorderScene in followPlayhead → rebinds selection

    func test_reorderScene_followPlayhead_rebindsSelection() {
        var state = makeLoadedState(sceneDurations: [1_000_000, 1_000_000, 1_000_000])
        let scene1Id = state.sceneItems[0].id

        // Focus scene 1 (activates follow mode, playhead at scene 1 start)
        let focusResult = EditorReducer.reduce(state: state, action: .focusScene(sceneId: scene1Id))
        state = focusResult.state
        XCTAssertEqual(state.selection, .scene(id: scene1Id))

        // Reorder scene 1 to index 2 (playhead follows the moved scene)
        let reorderResult = EditorReducer.reduce(state: state, action: .reorderScene(sceneId: scene1Id, toIndex: 2))
        let newState = reorderResult.state

        // Selection should rebind to scene under new playhead position
        XCTAssertEqual(newState.timelineSceneSelectionMode, .followPlayhead)
        if case .scene(let selectedId) = newState.selection {
            let sceneAtPlayhead = newState.sceneIdAtPlayhead()
            XCTAssertEqual(selectedId, sceneAtPlayhead,
                           "Selection must match scene at playhead after reorder")
        } else {
            XCTFail("Expected .scene selection after reorder in follow mode")
        }
    }

    // MARK: - 16. trimScene in followPlayhead → selection preserved

    func test_trimScene_followPlayhead_rebindsSelection() {
        var state = makeLoadedState(sceneDurations: [2_000_000, 2_000_000])
        let scene1Id = state.sceneItems[0].id

        // Focus scene 1 (activates follow mode)
        let focusResult = EditorReducer.reduce(state: state, action: .focusScene(sceneId: scene1Id))
        state = focusResult.state
        XCTAssertEqual(state.selection, .scene(id: scene1Id))

        // Trim scene 1 shorter (began + ended)
        let beganResult = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: scene1Id, phase: .began, newDurationUs: 1_500_000, edge: .trailing)
        )
        let endedResult = EditorReducer.reduce(
            state: beganResult.state,
            action: .trimScene(sceneId: scene1Id, phase: .ended, newDurationUs: 1_000_000, edge: .trailing)
        )
        let newState = endedResult.state

        // Selection should still be scene 1 (playhead clamped within scene 1)
        XCTAssertEqual(newState.timelineSceneSelectionMode, .followPlayhead)
        XCTAssertEqual(newState.selection, .scene(id: scene1Id))
    }

    // MARK: - 17. setBoundaryTransition in followPlayhead → rebinds selection

    func test_setBoundaryTransition_followPlayhead_rebindsSelection() {
        var state = makeLoadedState(sceneDurations: [2_000_000, 2_000_000])
        let scene1Id = state.sceneItems[0].id

        // Focus scene 1 (activates follow mode)
        let focusResult = EditorReducer.reduce(state: state, action: .focusScene(sceneId: scene1Id))
        state = focusResult.state
        XCTAssertEqual(state.selection, .scene(id: scene1Id))

        // Set boundary transition (fade, 14 frames) between scene 1 and scene 2
        let scene2Id = state.sceneItems[1].id
        let fadeTransition = SceneTransition.v1Preset(for: .fade)
        let result = EditorReducer.reduce(
            state: state,
            action: .setBoundaryTransition(
                fromSceneId: scene1Id,
                toSceneId: scene2Id,
                transition: fadeTransition
            )
        )
        let newState = result.state

        // Selection should rebind to scene at playhead after compressed mapping changes
        XCTAssertEqual(newState.timelineSceneSelectionMode, .followPlayhead)
        if case .scene(let selectedId) = newState.selection {
            let sceneAtPlayhead = newState.sceneIdAtPlayhead()
            XCTAssertEqual(selectedId, sceneAtPlayhead,
                           "Selection must match scene at playhead after transition change")
        } else {
            XCTFail("Expected .scene selection after setBoundaryTransition in follow mode")
        }
    }
}
