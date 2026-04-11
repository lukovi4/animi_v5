import XCTest
import struct TVECore.TransitionParams
@testable import AnimiApp

/// Tests for PR-G: Transition Boundary Picker feature.
/// Covers pure functions, reducer actions, and store callbacks.
final class TransitionBoundaryContractsTests: XCTestCase {

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

    /// Loads a draft into EditorState via reducer.
    private func loadDraft(_ draft: ProjectDraft) -> EditorState {
        EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state
    }

    // MARK: - 1. toSceneBoundaryDrafts() Pure Function Tests

    /// Test: 0 scenes returns empty array.
    func test_toSceneBoundaryDrafts_zeroScenes_returnsEmpty() {
        let timeline = CanonicalTimeline.empty()

        let boundaries = timeline.toSceneBoundaryDrafts()

        XCTAssertEqual(boundaries.count, 0)
    }

    /// Test: 1 scene returns empty array (no boundaries).
    func test_toSceneBoundaryDrafts_oneScene_returnsEmpty() {
        let draft = makeDraft(sceneDurations: [2_000_000])

        let boundaries = draft.canonicalTimeline.toSceneBoundaryDrafts()

        XCTAssertEqual(boundaries.count, 0)
    }

    /// Test: 2 scenes returns 1 boundary.
    func test_toSceneBoundaryDrafts_twoScenes_returnsOneBoundary() {
        let draft = makeDraft(sceneDurations: [2_000_000, 3_000_000])
        let sceneItems = draft.canonicalTimeline.sceneItems

        let boundaries = draft.canonicalTimeline.toSceneBoundaryDrafts()

        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(boundaries[0].fromSceneId, sceneItems[0].id)
        XCTAssertEqual(boundaries[0].toSceneId, sceneItems[1].id)
    }

    /// Test: 3 scenes returns 2 boundaries in correct order.
    func test_toSceneBoundaryDrafts_threeScenes_returnsTwoBoundariesInOrder() {
        let draft = makeDraft(sceneDurations: [1_000_000, 2_000_000, 3_000_000])
        let sceneItems = draft.canonicalTimeline.sceneItems

        let boundaries = draft.canonicalTimeline.toSceneBoundaryDrafts()

        XCTAssertEqual(boundaries.count, 2)

        // First boundary: scene[0] -> scene[1]
        XCTAssertEqual(boundaries[0].fromSceneId, sceneItems[0].id)
        XCTAssertEqual(boundaries[0].toSceneId, sceneItems[1].id)

        // Second boundary: scene[1] -> scene[2]
        XCTAssertEqual(boundaries[1].fromSceneId, sceneItems[1].id)
        XCTAssertEqual(boundaries[1].toSceneId, sceneItems[2].id)
    }

    /// Test: Missing registry entry returns .none transition.
    func test_toSceneBoundaryDrafts_missingRegistryEntry_returnsNone() {
        let draft = makeDraft(sceneDurations: [2_000_000, 3_000_000])

        let boundaries = draft.canonicalTimeline.toSceneBoundaryDrafts()

        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(boundaries[0].transition.type, .none)
    }

    /// Test: Existing registry entry preserves transition.
    func test_toSceneBoundaryDrafts_existingRegistryEntry_preservesTransition() {
        var draft = makeDraft(sceneDurations: [2_000_000, 3_000_000])
        let sceneItems = draft.canonicalTimeline.sceneItems
        let key = SceneBoundaryKey(sceneItems[0].id, sceneItems[1].id)
        let fadeTransition = SceneTransition(type: .fade, durationFrames: 14, easingPreset: .linear)
        draft.canonicalTimeline.boundaryTransitions[key] = fadeTransition

        let boundaries = draft.canonicalTimeline.toSceneBoundaryDrafts()

        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(boundaries[0].transition.type, .fade)
        XCTAssertEqual(boundaries[0].transition.durationFrames, 14)
        XCTAssertEqual(boundaries[0].transition.easingPreset, .linear)
    }

    // MARK: - 2. v1Preset(for:) Pure Function Tests

    /// Test: v1Preset for .none returns 0 frames.
    func test_v1Preset_none_returnsZeroFrames() {
        let preset = SceneTransition.v1Preset(for: .none)

        XCTAssertEqual(preset.type, .none)
        XCTAssertEqual(preset.durationFrames, 0)
        XCTAssertEqual(preset.easingPreset, .linear)
    }

    /// Test: v1Preset for .fade returns 14 frames + linear.
    func test_v1Preset_fade_returns14FramesLinear() {
        let preset = SceneTransition.v1Preset(for: .fade)

        XCTAssertEqual(preset.type, .fade)
        XCTAssertEqual(preset.durationFrames, 14)
        XCTAssertEqual(preset.easingPreset, .linear)
    }

    /// Test: v1Preset for .slide returns 14 frames + easeInOut.
    func test_v1Preset_slide_returns14FramesEaseInOut() {
        let preset = SceneTransition.v1Preset(for: .slide(direction: .left))

        XCTAssertEqual(preset.type, .slide(direction: .left))
        XCTAssertEqual(preset.durationFrames, 14)
        XCTAssertEqual(preset.easingPreset, .easeInOut)
    }

    /// Test: v1Preset for .push returns 14 frames + easeInOut.
    func test_v1Preset_push_returns14FramesEaseInOut() {
        let preset = SceneTransition.v1Preset(for: .push(direction: .right))

        XCTAssertEqual(preset.type, .push(direction: .right))
        XCTAssertEqual(preset.durationFrames, 14)
        XCTAssertEqual(preset.easingPreset, .easeInOut)
    }

    /// Test: v1Preset for .dipToBlack returns 14 frames + easeInOut.
    func test_v1Preset_dipToBlack_returns14FramesEaseInOut() {
        let preset = SceneTransition.v1Preset(for: .dipToBlack)

        XCTAssertEqual(preset.type, .dipToBlack)
        XCTAssertEqual(preset.durationFrames, 14)
        XCTAssertEqual(preset.easingPreset, .easeInOut)
    }

    /// Test: v1Preset for .dipToWhite returns 14 frames + easeInOut.
    func test_v1Preset_dipToWhite_returns14FramesEaseInOut() {
        let preset = SceneTransition.v1Preset(for: .dipToWhite)

        XCTAssertEqual(preset.type, .dipToWhite)
        XCTAssertEqual(preset.durationFrames, 14)
        XCTAssertEqual(preset.easingPreset, .easeInOut)
    }

    /// Test: v1Preset preserves all slide directions.
    func test_v1Preset_slide_preservesAllDirections() {
        let directions: [TransitionDirection] = [.left, .right, .up, .down]

        for direction in directions {
            let preset = SceneTransition.v1Preset(for: .slide(direction: direction))
            XCTAssertEqual(preset.type, .slide(direction: direction))
        }
    }

    /// Test: v1Preset preserves all push directions.
    func test_v1Preset_push_preservesAllDirections() {
        let directions: [TransitionDirection] = [.left, .right, .up, .down]

        for direction in directions {
            let preset = SceneTransition.v1Preset(for: .push(direction: direction))
            XCTAssertEqual(preset.type, .push(direction: direction))
        }
    }

    // MARK: - 3. Reducer Tests: setBoundaryTransition

    /// Test: setBoundaryTransition with fade stores transition.
    func test_setBoundaryTransition_fade_storesTransition() {
        let draft = makeDraft(sceneDurations: [2_000_000, 3_000_000])
        let state = loadDraft(draft)
        let sceneItems = state.sceneItems
        let fadeTransition = SceneTransition.v1Preset(for: .fade)

        let result = EditorReducer.reduce(
            state: state,
            action: .setBoundaryTransition(
                fromSceneId: sceneItems[0].id,
                toSceneId: sceneItems[1].id,
                transition: fadeTransition
            )
        )

        let key = SceneBoundaryKey(sceneItems[0].id, sceneItems[1].id)
        let stored = result.state.canonicalTimeline.boundaryTransitions[key]
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.type, .fade)
        XCTAssertEqual(stored?.durationFrames, 14)
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: setBoundaryTransition with .none removes key.
    func test_setBoundaryTransition_none_removesKey() {
        var draft = makeDraft(sceneDurations: [2_000_000, 3_000_000])
        let sceneItems = draft.canonicalTimeline.sceneItems
        let key = SceneBoundaryKey(sceneItems[0].id, sceneItems[1].id)
        // Pre-set a fade transition
        draft.canonicalTimeline.boundaryTransitions[key] = SceneTransition.v1Preset(for: .fade)

        let state = loadDraft(draft)

        // Now set to .none
        let result = EditorReducer.reduce(
            state: state,
            action: .setBoundaryTransition(
                fromSceneId: sceneItems[0].id,
                toSceneId: sceneItems[1].id,
                transition: .none
            )
        )

        let stored = result.state.canonicalTimeline.boundaryTransitions[key]
        XCTAssertNil(stored, "Setting .none should remove the key")
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: Playhead clamps after compressed duration changes.
    func test_setBoundaryTransition_clampsPlayheadAfterCompressionChange() {
        // Given: 2 scenes of 30 frames each = 60 nominal frames
        // Playhead at frame 55 (near end)
        var draft = makeDraft(sceneDurations: [1_000_000, 1_000_000]) // 30 frames each at 30fps
        let state = loadDraft(draft)
        var stateWithPlayhead = state
        stateWithPlayhead.playheadCompressedFrame = 55 // Near end of 60 frames

        let sceneItems = stateWithPlayhead.sceneItems

        // When: Add fade transition (compresses by 7 frames)
        // New compressed duration = 60 - 7 = 53 frames
        // Playhead at 55 should clamp to 52 (max = 53 - 1)
        let result = EditorReducer.reduce(
            state: stateWithPlayhead,
            action: .setBoundaryTransition(
                fromSceneId: sceneItems[0].id,
                toSceneId: sceneItems[1].id,
                transition: SceneTransition.v1Preset(for: .fade)
            )
        )

        XCTAssertLessThanOrEqual(
            result.state.playheadCompressedFrame,
            result.state.compressedDurationFrames - 1,
            "Playhead should be clamped to valid range"
        )
    }

    // MARK: - 4. Notice Emission Tests

    /// Test: Notice emitted when boundary transitions reset during reorder.
    func test_reorderScene_emitsNoticeWhenBoundaryReset() {
        // Given: 3 scenes with transition between 0-1
        var draft = makeDraft(sceneDurations: [1_000_000, 1_000_000, 1_000_000])
        let sceneItems = draft.canonicalTimeline.sceneItems
        let key01 = SceneBoundaryKey(sceneItems[0].id, sceneItems[1].id)
        draft.canonicalTimeline.boundaryTransitions[key01] = SceneTransition.v1Preset(for: .fade)

        let state = loadDraft(draft)

        // When: Reorder scene[0] to end (breaks boundary 0-1)
        let result = EditorReducer.reduce(
            state: state,
            action: .reorderScene(sceneId: sceneItems[0].id, toIndex: 2)
        )

        // Then: Notice should contain the reset key
        XCTAssertFalse(result.notices.isEmpty, "Should emit notice when boundary is reset")
        if case .boundaryTransitionsReset(let keys) = result.notices.first {
            XCTAssertTrue(keys.contains(key01), "Notice should contain the reset boundary key")
        } else {
            XCTFail("Expected boundaryTransitionsReset notice")
        }
    }

    /// Test: No notice when no boundaries are reset.
    func test_setBoundaryTransition_noNoticeWhenNoBoundariesReset() {
        let draft = makeDraft(sceneDurations: [2_000_000, 3_000_000])
        let state = loadDraft(draft)
        let sceneItems = state.sceneItems

        let result = EditorReducer.reduce(
            state: state,
            action: .setBoundaryTransition(
                fromSceneId: sceneItems[0].id,
                toSceneId: sceneItems[1].id,
                transition: SceneTransition.v1Preset(for: .fade)
            )
        )

        // Setting a new transition doesn't reset any existing boundaries
        XCTAssertTrue(result.notices.isEmpty, "No notice when simply setting a transition")
    }

    // MARK: - 5. EditorStore.onNotice Callback Tests

    /// Test: EditorStore.onNotice fires when notice is emitted.
    @MainActor func test_editorStore_onNoticeFires() {
        // Given: 3 scenes with transition between 0-1
        var draft = makeDraft(sceneDurations: [1_000_000, 1_000_000, 1_000_000])
        let sceneItems = draft.canonicalTimeline.sceneItems
        let key01 = SceneBoundaryKey(sceneItems[0].id, sceneItems[1].id)
        draft.canonicalTimeline.boundaryTransitions[key01] = SceneTransition.v1Preset(for: .fade)

        let store = EditorStore()
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        var receivedNotice: EditorNotice?
        store.onNotice = { notice in
            receivedNotice = notice
        }

        // When: Reorder that breaks the boundary
        store.dispatch(.reorderScene(sceneId: sceneItems[0].id, toIndex: 2))

        // Then: Callback fired with correct notice
        XCTAssertNotNil(receivedNotice, "onNotice should be called")
        if case .boundaryTransitionsReset(let keys) = receivedNotice {
            XCTAssertTrue(keys.contains(key01))
        } else {
            XCTFail("Expected boundaryTransitionsReset notice")
        }
    }

    /// Test: EditorStore.onNotice fires after state update.
    @MainActor func test_editorStore_onNoticeFiresAfterStateUpdate() {
        var draft = makeDraft(sceneDurations: [1_000_000, 1_000_000, 1_000_000])
        let sceneItems = draft.canonicalTimeline.sceneItems
        let key01 = SceneBoundaryKey(sceneItems[0].id, sceneItems[1].id)
        draft.canonicalTimeline.boundaryTransitions[key01] = SceneTransition.v1Preset(for: .fade)

        let store = EditorStore()
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        var stateAtNoticeTime: EditorState?
        store.onNotice = { [weak store] _ in
            stateAtNoticeTime = store?.state
        }

        // When: Reorder
        store.dispatch(.reorderScene(sceneId: sceneItems[0].id, toIndex: 2))

        // Then: State should already be updated when notice fires
        XCTAssertNotNil(stateAtNoticeTime)
        // The reordered scene should be at index 2
        XCTAssertEqual(stateAtNoticeTime?.sceneItems[2].id, sceneItems[0].id)
    }

    // MARK: - 6. TT-06: toTransitionParams() Tests

    /// Test: Fade transition converts to linear easing.
    func testSceneTransition_toTransitionParams_fadeUsesLinear() {
        let transition = SceneTransition(type: .fade, durationFrames: 14, easingPreset: .linear)
        let params = transition.toTransitionParams()

        XCTAssertEqual(params.easing, .linear)
        // Verify type is fade
        if case .fade = params.type {} else {
            XCTFail("Expected .fade type, got \(params.type)")
        }
    }

    /// Test: Slide transition converts to easeInOut easing.
    func testSceneTransition_toTransitionParams_slideUsesEaseInOut() {
        let transition = SceneTransition(type: .slide(direction: .left), durationFrames: 14, easingPreset: .easeInOut)
        let params = transition.toTransitionParams()

        XCTAssertEqual(params.easing, .easeInOut)
        if case .slide(let dir) = params.type {
            XCTAssertEqual(dir, .left)
        } else {
            XCTFail("Expected .slide type, got \(params.type)")
        }
    }

    /// Test: Push transition preserves direction through conversion.
    func testSceneTransition_toTransitionParams_preservesDirection() {
        let appDirections: [AnimiApp.TransitionDirection] = [.left, .right, .up, .down]

        for appDir in appDirections {
            let transition = SceneTransition(type: .push(direction: appDir), durationFrames: 14, easingPreset: .easeInOut)
            let params = transition.toTransitionParams()

            if case .push(let direction) = params.type {
                // Direction name should match
                XCTAssertEqual("\(direction)", "\(appDir)", "Direction \(appDir) should map correctly")
            } else {
                XCTFail("Expected .push type, got \(params.type)")
            }
        }
    }
}
