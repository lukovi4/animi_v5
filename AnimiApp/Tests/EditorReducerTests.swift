import XCTest
import TVECore
@testable import AnimiApp

/// Unit tests for Release v1: EditorStore/Reducer.
/// Tests cover:
/// - loadProject populates timeline from defaultSceneSequence
/// - trimScene without upper limit (no templateDurationUs cap)
/// - Shift-left applies on project shorten
/// - reorderScene + playhead follows moved scene
/// - addScene, duplicateScene, deleteScene
/// - sceneSequence track invariant enforcement
final class EditorReducerTests: XCTestCase {

    // MARK: - Test Helpers

    /// Creates default scene sequence for testing.
    private func makeDefaultSceneSequence(durations: [TimeUs]) -> [SceneTypeDefault] {
        durations.enumerated().map { index, duration in
            SceneTypeDefault(sceneTypeId: "test_scene_\(index)", baseDurationUs: duration)
        }
    }

    /// Creates a test draft with specified scene durations.
    private func makeDraft(sceneDurations: [TimeUs]) -> ProjectDraft {
        var draft = ProjectDraft.create(for: "test-template")

        // Build canonical timeline with scenes
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

    /// Creates a test draft with scenes and audio/overlay items.
    private func makeDraftWithNonSceneItems(
        sceneDurations: [TimeUs],
        audioItems: [(startUs: TimeUs, durationUs: TimeUs)]
    ) -> ProjectDraft {
        var draft = makeDraft(sceneDurations: sceneDurations)
        var timeline = draft.canonicalTimeline

        // Add audio track with items
        let audioTrack = Track(kind: .audio)
        timeline.tracks.append(audioTrack)

        for (startUs, durationUs) in audioItems {
            let payloadId = UUID()
            timeline.payloads[payloadId] = .audio(AudioPayload(volume: 1.0))
            let item = TimelineItem(
                payloadId: payloadId,
                kind: .audioClip,
                startUs: startUs,
                durationUs: durationUs
            )
            timeline.tracks[1].items.append(item)
        }

        draft.canonicalTimeline = timeline
        return draft
    }

    // MARK: - 1. loadProject Populates Timeline from Template Defaults

    /// Test: loadProject populates empty timeline from defaultSceneSequence.
    func testLoadProject_populatesFromDefaults() {
        // Given: empty draft and template defaults with 3 scenes
        let draft = ProjectDraft.create(for: "test-template")
        let defaults = makeDefaultSceneSequence(durations: [2_000_000, 3_000_000, 5_000_000])

        // When: reduce with loadProject
        let result = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: defaults)
        )

        // Then: timeline has 3 scenes from defaults
        XCTAssertEqual(result.state.sceneItems.count, 3)
        XCTAssertEqual(result.state.sceneItems[0].durationUs, 2_000_000)
        XCTAssertEqual(result.state.sceneItems[1].durationUs, 3_000_000)
        XCTAssertEqual(result.state.sceneItems[2].durationUs, 5_000_000)

        // Then: total duration is sum of scenes
        XCTAssertEqual(result.state.projectDurationUs, 10_000_000)

        // Then: no snapshot pushed (loadProject is initialization)
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    /// Test: loadProject preserves existing timeline (doesn't overwrite with defaults).
    func testLoadProject_preservesExistingTimeline() {
        // Given: draft with existing scenes
        let draft = makeDraft(sceneDurations: [4_000_000, 6_000_000])
        let defaults = makeDefaultSceneSequence(durations: [1_000_000]) // Different from draft

        // When: loadProject
        let result = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: defaults)
        )

        // Then: existing timeline preserved (not replaced by defaults)
        XCTAssertEqual(result.state.sceneItems.count, 2)
        XCTAssertEqual(result.state.projectDurationUs, 10_000_000)
    }

    /// Test: loadProject enforces min duration for scenes from template defaults.
    func testLoadProject_enforcesMinDuration() {
        // Given: template defaults with scenes below min duration
        let draft = ProjectDraft.create(for: "test-template")
        let defaults = [
            SceneTypeDefault(sceneTypeId: "s1", baseDurationUs: 50_000), // Below min
            SceneTypeDefault(sceneTypeId: "s2", baseDurationUs: 200_000)
        ]

        // When: loadProject
        let result = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: defaults)
        )

        // Then: scene durations clamped to min
        XCTAssertGreaterThanOrEqual(result.state.sceneItems[0].durationUs, ProjectDraft.minSceneDurationUs)
        XCTAssertEqual(result.state.sceneItems[1].durationUs, 200_000)
    }

    // MARK: - 2. trimScene Without Upper Limit

    /// Test: trimScene has no upper limit (scenes can be as long as needed).
    func testTrimScene_noUpperLimit() {
        // Given: scene of 5s
        let draft = makeDraft(sceneDurations: [5_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state
        let sceneId = state.sceneItems[0].id

        // When: trim to 50s (way beyond any "template duration")
        let result = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: sceneId, phase: .ended, newDurationUs: 50_000_000, edge: .trailing)
        )

        // Then: duration is 50s (no cap)
        XCTAssertEqual(result.state.sceneItems[0].durationUs, 50_000_000)
        XCTAssertEqual(result.state.projectDurationUs, 50_000_000)
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: trimScene enforces min duration.
    func testTrimScene_enforcesMinDuration() {
        // Given
        let draft = makeDraft(sceneDurations: [3_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state
        let sceneId = state.sceneItems[0].id

        // When: try to trim below min duration
        let result = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: sceneId, phase: .ended, newDurationUs: 10_000, edge: .trailing)
        )

        // Then: duration clamped to min
        XCTAssertEqual(result.state.sceneItems[0].durationUs, ProjectDraft.minSceneDurationUs)
    }

    /// Test: trimScene phases push snapshot only on .ended.
    func testTrimScene_pushesSnapshotOnlyOnEnded() {
        // Given
        let draft = makeDraft(sceneDurations: [3_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state
        let sceneId = state.sceneItems[0].id

        // When: .began
        let beganResult = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: sceneId, phase: .began, newDurationUs: 2_000_000, edge: .trailing)
        )
        XCTAssertFalse(beganResult.shouldPushSnapshot)

        // When: .changed
        let changedResult = EditorReducer.reduce(
            state: beganResult.state,
            action: .trimScene(sceneId: sceneId, phase: .changed, newDurationUs: 1_500_000, edge: .trailing)
        )
        XCTAssertFalse(changedResult.shouldPushSnapshot)

        // When: .ended
        let endedResult = EditorReducer.reduce(
            state: changedResult.state,
            action: .trimScene(sceneId: sceneId, phase: .ended, newDurationUs: 1_000_000, edge: .trailing)
        )
        XCTAssertTrue(endedResult.shouldPushSnapshot)
    }

    // MARK: - 3. Shift-Left Applies on Shorten

    /// Test: shift-left applied to audio items when project shortens.
    func testShiftLeft_appliedOnShorten() {
        // Given: scene + audio item
        let draft = makeDraftWithNonSceneItems(
            sceneDurations: [5_000_000],
            audioItems: [(startUs: 3_000_000, durationUs: 2_000_000)]
        )
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state
        let sceneId = state.sceneItems[0].id

        // When: trim scene from 5s to 3s (delta = 2s)
        let result = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: sceneId, phase: .ended, newDurationUs: 3_000_000, edge: .trailing)
        )

        // Then: audio track exists
        guard result.state.canonicalTimeline.tracks.count > 1 else {
            XCTFail("Audio track should exist")
            return
        }

        // Then: audio item shifted left
        let audioTrack = result.state.canonicalTimeline.tracks[1]
        if let audioItem = audioTrack.items.first {
            XCTAssertEqual(audioItem.startUs, 1_000_000, "Audio should shift left by delta")
        }
    }

    // MARK: - 4. reorderScene + Playhead Follow

    /// Test: reorder moves scene to new index.
    func testReorderScene_movesScene() {
        // Given: 3 scenes
        let draft = makeDraft(sceneDurations: [1_000_000, 2_000_000, 3_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let sceneAId = state.sceneItems[0].id
        let sceneBId = state.sceneItems[1].id
        let sceneCId = state.sceneItems[2].id

        // When: move B (index 1) to end (index 2)
        let result = EditorReducer.reduce(
            state: state,
            action: .reorderScene(sceneId: sceneBId, toIndex: 2)
        )

        // Then: order is now A, C, B
        XCTAssertEqual(result.state.sceneItems[0].id, sceneAId)
        XCTAssertEqual(result.state.sceneItems[1].id, sceneCId)
        XCTAssertEqual(result.state.sceneItems[2].id, sceneBId)
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: playhead follows moved scene.
    func testReorderScene_playheadFollowsScene() {
        // Given: 3 scenes, playhead in B
        let draft = makeDraft(sceneDurations: [1_000_000, 2_000_000, 3_000_000])
        var state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let sceneBId = state.sceneItems[1].id
        // Phase 2.1: Use compressed frame (1.5s = 45 frames at 30fps)
        state.playheadCompressedFrame = 45 // 0.5s into scene B (which starts at 1s = 30 frames)

        // When: move B to start (index 0)
        let result = EditorReducer.reduce(
            state: state,
            action: .reorderScene(sceneId: sceneBId, toIndex: 0)
        )

        // Then: playhead follows (0.5s into B at new position = 15 frames)
        XCTAssertEqual(result.state.playheadCompressedFrame, 15)
    }

    // MARK: - 5. addScene, duplicateScene, deleteScene

    /// Test: addScene adds new scene at end.
    func testAddScene_addsAtEnd() {
        // Given: existing scene
        let draft = makeDraft(sceneDurations: [2_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        // When: add new scene
        let result = EditorReducer.reduce(
            state: state,
            action: .addScene(sceneTypeId: "new_scene", durationUs: 3_000_000)
        )

        // Then: 2 scenes, new one at end
        XCTAssertEqual(result.state.sceneItems.count, 2)
        XCTAssertEqual(result.state.sceneItems[1].durationUs, 3_000_000)
        XCTAssertEqual(result.state.projectDurationUs, 5_000_000)
        XCTAssertTrue(result.shouldPushSnapshot)

        // Then: payload has correct sceneTypeId
        let newItem = result.state.sceneItems[1]
        if case .scene(let payload) = result.state.canonicalTimeline.payloads[newItem.payloadId] {
            XCTAssertEqual(payload.sceneTypeId, "new_scene")
        } else {
            XCTFail("Payload should be .scene type")
        }
    }

    /// Test: duplicateScene creates copy with same duration and SceneState.
    func testDuplicateScene_copiesDurationAndState() {
        // Given: scene with custom state
        var draft = makeDraft(sceneDurations: [2_000_000])
        let sceneId = draft.canonicalTimeline.sceneItems[0].id
        draft.sceneInstanceStates[sceneId] = SceneState(layerToggles: ["block1": ["toggle1": true]])

        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        // When: duplicate scene
        let result = EditorReducer.reduce(
            state: state,
            action: .duplicateScene(sceneItemId: sceneId)
        )

        // Then: 2 scenes with same duration
        XCTAssertEqual(result.state.sceneItems.count, 2)
        XCTAssertEqual(result.state.sceneItems[1].durationUs, 2_000_000)
        XCTAssertTrue(result.shouldPushSnapshot)

        // Then: new scene has copied SceneState
        let newSceneId = result.state.sceneItems[1].id
        XCTAssertEqual(
            result.state.draft.sceneInstanceStates[newSceneId]?.layerToggles,
            ["block1": ["toggle1": true]]
        )

        // Then: states are independent
        XCTAssertNotEqual(sceneId, newSceneId)
    }

    /// Test: deleteScene removes scene (cannot delete last).
    func testDeleteScene_removesScene() {
        // Given: 2 scenes
        let draft = makeDraft(sceneDurations: [2_000_000, 3_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let firstSceneId = state.sceneItems[0].id

        // When: delete first scene
        let result = EditorReducer.reduce(
            state: state,
            action: .deleteScene(sceneId: firstSceneId)
        )

        // Then: 1 scene remains
        XCTAssertEqual(result.state.sceneItems.count, 1)
        XCTAssertEqual(result.state.projectDurationUs, 3_000_000)
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: deleteScene cannot delete last scene.
    func testDeleteScene_cannotDeleteLast() {
        // Given: 1 scene
        let draft = makeDraft(sceneDurations: [2_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let sceneId = state.sceneItems[0].id

        // When: try to delete last scene
        let result = EditorReducer.reduce(
            state: state,
            action: .deleteScene(sceneId: sceneId)
        )

        // Then: scene not deleted
        XCTAssertEqual(result.state.sceneItems.count, 1)
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    // MARK: - 6. sceneSequence Track Invariant

    /// Test: ensures exactly one sceneSequence track at index 0.
    func testInvariant_singleSceneSequenceTrackAtIndex0() {
        // Given
        let draft = makeDraft(sceneDurations: [2_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        // Then: tracks[0] is sceneSequence
        XCTAssertFalse(state.canonicalTimeline.tracks.isEmpty)
        XCTAssertEqual(state.canonicalTimeline.tracks[0].kind, .sceneSequence)

        // Then: only one sceneSequence track
        let sceneSequenceTracks = state.canonicalTimeline.tracks.filter { $0.kind == .sceneSequence }
        XCTAssertEqual(sceneSequenceTracks.count, 1)
    }

    /// Test: sceneSequence items have nil startUs.
    func testInvariant_sceneItemsHaveNilStartUs() {
        // Given
        let draft = makeDraft(sceneDurations: [1_000_000, 2_000_000, 3_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        // Then: all scene items have nil startUs
        for item in state.sceneItems {
            XCTAssertNil(item.startUs)
        }
    }

    /// Test: computedStartUs returns correct cumulative sum.
    func testInvariant_computedStartUsIsCumulativeSum() {
        // Given
        let draft = makeDraft(sceneDurations: [1_000_000, 2_000_000, 3_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let timeline = state.canonicalTimeline

        // Then
        XCTAssertEqual(timeline.computedStartUs(forSceneAt: 0), 0)
        XCTAssertEqual(timeline.computedStartUs(forSceneAt: 1), 1_000_000)
        XCTAssertEqual(timeline.computedStartUs(forSceneAt: 2), 3_000_000)
    }

    // MARK: - 7. EditorStore Undo/Redo

    /// Test: EditorStore undo/redo works correctly.
    @MainActor func testEditorStore_undoRedo() {
        // Given
        let draft = makeDraft(sceneDurations: [3_000_000])
        let store = EditorStore()
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        let sceneId = store.sceneItems[0].id
        let originalDuration = store.sceneItems[0].durationUs

        // When: trim scene
        store.dispatch(.trimScene(sceneId: sceneId, phase: .ended, newDurationUs: 1_000_000, edge: .trailing))
        XCTAssertEqual(store.sceneItems[0].durationUs, 1_000_000)

        // When: undo
        XCTAssertTrue(store.canUndo)
        store.dispatch(.undo)
        XCTAssertEqual(store.sceneItems[0].durationUs, originalDuration)

        // When: redo
        XCTAssertTrue(store.canRedo)
        store.dispatch(.redo)
        XCTAssertEqual(store.sceneItems[0].durationUs, 1_000_000)
    }

    /// Test: trim gesture cancelled restores original state.
    @MainActor func testTrimGesture_cancelledRestoresOriginal() {
        // Given
        let draft = makeDraft(sceneDurations: [3_000_000])
        let store = EditorStore()
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        let sceneId = store.sceneItems[0].id
        let originalDuration = store.sceneItems[0].durationUs

        // When: start trim gesture
        store.dispatch(.trimScene(sceneId: sceneId, phase: .began, newDurationUs: 2_000_000, edge: .trailing))
        store.dispatch(.trimScene(sceneId: sceneId, phase: .changed, newDurationUs: 1_000_000, edge: .trailing))

        // When: cancel gesture
        store.dispatch(.trimScene(sceneId: sceneId, phase: .cancelled, newDurationUs: 1_000_000, edge: .trailing))

        // Then: restored to original
        XCTAssertEqual(store.sceneItems[0].durationUs, originalDuration)
        XCTAssertFalse(store.canUndo)
    }

    // MARK: - 8. Leading Edge Trim (Not Supported)

    /// Test: leading trim for sceneSequence is ignored.
    func testTrimScene_leadingEdgeIgnored() {
        // Given
        let draft = makeDraft(sceneDurations: [3_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let sceneId = state.sceneItems[0].id
        let originalDuration = state.sceneItems[0].durationUs

        // When: try leading trim
        let result = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: sceneId, phase: .ended, newDurationUs: 1_000_000, edge: .leading)
        )

        // Then: duration unchanged
        XCTAssertEqual(result.state.sceneItems[0].durationUs, originalDuration)
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    // MARK: - 9. PR9: Scene Instance State Actions

    /// Test: setBlockVariant stores variant override in SceneState.
    func testSetBlockVariant_storesInSceneState() {
        // Given: scene loaded
        let draft = makeDraft(sceneDurations: [2_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let sceneId = state.sceneItems[0].id

        // When: set variant override
        let result = EditorReducer.reduce(
            state: state,
            action: .setBlockVariant(sceneInstanceId: sceneId, blockId: "block1", variantId: "variant_a")
        )

        // Then: variant stored in SceneState
        let sceneState = result.state.draft.sceneInstanceStates[sceneId]
        XCTAssertEqual(sceneState?.variantOverrides["block1"], "variant_a")
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: setBlockToggle stores toggle in SceneState.
    func testSetBlockToggle_storesInSceneState() {
        // Given
        let draft = makeDraft(sceneDurations: [2_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let sceneId = state.sceneItems[0].id

        // When: set toggle
        let result = EditorReducer.reduce(
            state: state,
            action: .setBlockToggle(sceneInstanceId: sceneId, blockId: "block1", toggleId: "toggle1", enabled: true)
        )

        // Then: toggle stored in SceneState
        let sceneState = result.state.draft.sceneInstanceStates[sceneId]
        XCTAssertEqual(sceneState?.layerToggles["block1"]?["toggle1"], true)
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: setMediaSlot stores slot in SceneState.
    func testSetMediaSlot_storesInSceneState() {
        // Given
        let draft = makeDraft(sceneDurations: [2_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let sceneId = state.sceneItems[0].id
        let mediaRef = MediaRef.file("Media/UserMedia/test.jpg")
        let slot = SceneMediaSlot.photo(mediaRef: mediaRef)

        // When: set slot
        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: sceneId, blockId: "block1", slot: slot)
        )

        // Then: slot stored in SceneState
        let sceneState = result.state.draft.sceneInstanceStates[sceneId]
        XCTAssertEqual(sceneState?.mediaSlotsByBlockId?["block1"]?.mediaRef, mediaRef)
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: setMediaSlot with nil clears slot.
    func testSetMediaSlot_nilClearsSlot() {
        // Given: scene with slot
        var draft = makeDraft(sceneDurations: [2_000_000])
        let sceneId = draft.canonicalTimeline.sceneItems[0].id
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = ["block1": .photo(mediaRef: MediaRef.file("old.jpg"))]
        draft.sceneInstanceStates[sceneId] = sceneState

        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        // When: clear slot
        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: sceneId, blockId: "block1", slot: nil)
        )

        // Then: slot cleared
        XCTAssertNil(result.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["block1"])
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: duplicated scene has independent SceneState.
    func testDuplicateScene_independentSceneState() {
        // Given: scene with state
        var draft = makeDraft(sceneDurations: [2_000_000])
        let sceneId = draft.canonicalTimeline.sceneItems[0].id
        var sceneState = SceneState.empty
        sceneState.variantOverrides["block1"] = "variant_a"
        sceneState.userTransforms["block1"] = Matrix2D(a: 1.5, b: 0.1, c: -0.1, d: 1.5, tx: 10, ty: 10)
        draft.sceneInstanceStates[sceneId] = sceneState

        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        // When: duplicate
        let result = EditorReducer.reduce(
            state: state,
            action: .duplicateScene(sceneItemId: sceneId)
        )

        // Then: new scene has copied state
        let newSceneId = result.state.sceneItems[1].id
        let newState = result.state.draft.sceneInstanceStates[newSceneId]
        XCTAssertEqual(newState?.variantOverrides["block1"], "variant_a")
        XCTAssertEqual(newState?.userTransforms["block1"], sceneState.userTransforms["block1"])

        // Then: modify new scene doesn't affect original
        let result2 = EditorReducer.reduce(
            state: result.state,
            action: .setBlockVariant(sceneInstanceId: newSceneId, blockId: "block1", variantId: "variant_b")
        )

        XCTAssertEqual(result2.state.draft.sceneInstanceStates[sceneId]?.variantOverrides["block1"], "variant_a")
        XCTAssertEqual(result2.state.draft.sceneInstanceStates[newSceneId]?.variantOverrides["block1"], "variant_b")
    }

    // MARK: - 10. PR10: Timeline Core Hardening

    /// T10-1: Reorder doesn't break per-instance state.
    /// Given: 3 scenes A, B, A (duplicate sceneType) with unique sceneInstanceStates
    /// When: reorder B to end
    /// Then: instanceIds preserved, sceneInstanceStates intact
    func testReorder_preservesSceneInstanceStates() {
        // Given: 3 scenes with unique states
        var draft = makeDraft(sceneDurations: [2_000_000, 3_000_000, 2_000_000])
        let sceneA1 = draft.canonicalTimeline.sceneItems[0].id
        let sceneB = draft.canonicalTimeline.sceneItems[1].id
        let sceneA2 = draft.canonicalTimeline.sceneItems[2].id

        // Set unique state for each scene
        var stateA1 = SceneState.empty
        stateA1.variantOverrides["block1"] = "variant_a1"
        stateA1.userTransforms["block1"] = Matrix2D(a: 1.1, b: 0, c: 0, d: 1.1, tx: 10, ty: 10)
        draft.sceneInstanceStates[sceneA1] = stateA1

        var stateB = SceneState.empty
        stateB.variantOverrides["block1"] = "variant_b"
        stateB.layerToggles["block1"] = ["toggle1": true]
        draft.sceneInstanceStates[sceneB] = stateB

        var stateA2 = SceneState.empty
        stateA2.variantOverrides["block1"] = "variant_a2"
        stateA2.mediaSlotsByBlockId = ["block1": .photo(mediaRef: MediaRef.file("media_a2.jpg"))]
        draft.sceneInstanceStates[sceneA2] = stateA2

        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        // Verify initial order: A1, B, A2
        XCTAssertEqual(state.sceneItems[0].id, sceneA1)
        XCTAssertEqual(state.sceneItems[1].id, sceneB)
        XCTAssertEqual(state.sceneItems[2].id, sceneA2)

        // When: move B to end (index 2)
        let result = EditorReducer.reduce(
            state: state,
            action: .reorderScene(sceneId: sceneB, toIndex: 2)
        )

        // Then: new order A1, A2, B
        XCTAssertEqual(result.state.sceneItems[0].id, sceneA1)
        XCTAssertEqual(result.state.sceneItems[1].id, sceneA2)
        XCTAssertEqual(result.state.sceneItems[2].id, sceneB)

        // Then: instanceIds preserved (same UUIDs)
        let allIds = result.state.sceneItems.map { $0.id }
        XCTAssertTrue(allIds.contains(sceneA1))
        XCTAssertTrue(allIds.contains(sceneB))
        XCTAssertTrue(allIds.contains(sceneA2))

        // Then: sceneInstanceStates intact
        XCTAssertEqual(result.state.draft.sceneInstanceStates[sceneA1]?.variantOverrides["block1"], "variant_a1")
        XCTAssertEqual(result.state.draft.sceneInstanceStates[sceneA1]?.userTransforms["block1"]?.tx, 10)

        XCTAssertEqual(result.state.draft.sceneInstanceStates[sceneB]?.variantOverrides["block1"], "variant_b")
        XCTAssertEqual(result.state.draft.sceneInstanceStates[sceneB]?.layerToggles["block1"]?["toggle1"], true)

        XCTAssertEqual(result.state.draft.sceneInstanceStates[sceneA2]?.variantOverrides["block1"], "variant_a2")
        XCTAssertEqual(result.state.draft.sceneInstanceStates[sceneA2]?.mediaSlotsByBlockId?["block1"]?.mediaRef, MediaRef.file("media_a2.jpg"))

        // Then: payloadIds preserved
        let payloadIds = result.state.sceneItems.map { $0.payloadId }
        XCTAssertEqual(payloadIds.count, 3)
        for payloadId in payloadIds {
            XCTAssertNotNil(result.state.canonicalTimeline.payloads[payloadId])
        }
    }

    /// T10-2: Trim maintains projectDurationUs and computedStartUs.
    /// Given: 2 scenes 5s + 6s
    /// When: trim first to 3s
    /// Then: projectDurationUs = 9s, computedStartUs[1] = 3s
    func testTrim_maintainsProjectDurationAndComputedStartUs() {
        // Given: 2 scenes 5s + 6s
        let draft = makeDraft(sceneDurations: [5_000_000, 6_000_000])
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let firstSceneId = state.sceneItems[0].id

        // Verify initial state
        XCTAssertEqual(state.projectDurationUs, 11_000_000)
        XCTAssertEqual(state.canonicalTimeline.computedStartUs(forSceneAt: 0), 0)
        XCTAssertEqual(state.canonicalTimeline.computedStartUs(forSceneAt: 1), 5_000_000)

        // When: trim first scene to 3s
        let result = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: firstSceneId, phase: .ended, newDurationUs: 3_000_000, edge: .trailing)
        )

        // Then: projectDurationUs = 9s
        XCTAssertEqual(result.state.projectDurationUs, 9_000_000)

        // Then: first scene = 3s
        XCTAssertEqual(result.state.sceneItems[0].durationUs, 3_000_000)

        // Then: second scene still 6s
        XCTAssertEqual(result.state.sceneItems[1].durationUs, 6_000_000)

        // Then: computedStartUs updated
        XCTAssertEqual(result.state.canonicalTimeline.computedStartUs(forSceneAt: 0), 0)
        XCTAssertEqual(result.state.canonicalTimeline.computedStartUs(forSceneAt: 1), 3_000_000)

        // Then: minSceneDurationUs still enforced if we trim too short
        let result2 = EditorReducer.reduce(
            state: result.state,
            action: .trimScene(sceneId: firstSceneId, phase: .ended, newDurationUs: 10_000, edge: .trailing)
        )
        XCTAssertEqual(result2.state.sceneItems[0].durationUs, ProjectDraft.minSceneDurationUs)
    }

    /// T10-3: Shift-left policy for non-scene items (text overlay).
    /// Given: 10s + 10s scenes, text item starts at 18s
    /// When: trim second scene by 5s (project 20s → 15s)
    /// Then: text startUs shifts 18s → 13s
    func testShiftLeft_textItemShiftsWithProjectShorten() {
        // Given: 2 scenes 10s each + text item at 18s
        var draft = makeDraft(sceneDurations: [10_000_000, 10_000_000])
        var timeline = draft.canonicalTimeline

        // Add overlay track with text item
        let overlayTrack = Track(kind: .overlay)
        timeline.tracks.append(overlayTrack)

        let textPayloadId = UUID()
        timeline.payloads[textPayloadId] = .text(TextPayload(text: "Test"))
        let textItem = TimelineItem(
            payloadId: textPayloadId,
            kind: .text,
            startUs: 18_000_000,  // starts at 18s
            durationUs: 2_000_000  // 2s duration
        )
        timeline.tracks[1].items.append(textItem)

        draft.canonicalTimeline = timeline

        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        // Verify initial state
        XCTAssertEqual(state.projectDurationUs, 20_000_000)
        XCTAssertEqual(state.canonicalTimeline.tracks[1].items[0].startUs, 18_000_000)

        let secondSceneId = state.sceneItems[1].id

        // When: trim second scene from 10s to 5s (project shortens by 5s)
        let result = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: secondSceneId, phase: .ended, newDurationUs: 5_000_000, edge: .trailing)
        )

        // Then: project = 15s
        XCTAssertEqual(result.state.projectDurationUs, 15_000_000)

        // Then: text item shifted left by 5s (18s → 13s)
        guard result.state.canonicalTimeline.tracks.count > 1 else {
            XCTFail("Overlay track should exist")
            return
        }

        let overlayItems = result.state.canonicalTimeline.tracks[1].items
        XCTAssertEqual(overlayItems.count, 1, "Text item should still exist")
        XCTAssertEqual(overlayItems[0].startUs, 13_000_000, "Text should shift left by delta (5s)")

        // Then: duration trimmed if extends beyond project
        // New end would be 13s + 2s = 15s, exactly at project end - should be ok
        XCTAssertEqual(overlayItems[0].durationUs, 2_000_000)
    }

    /// T10-3b: Shift-left removes item when duration becomes 0.
    /// Scenario: item starts exactly at project end, after shift-left lands at newDuration boundary → maxDuration = 0.
    func testShiftLeft_removesItemWhenDurationBecomesZero() {
        // Given: 10s scene + text item at 10s (project end) with 1s duration
        var draft = makeDraft(sceneDurations: [10_000_000])
        var timeline = draft.canonicalTimeline

        let overlayTrack = Track(kind: .overlay)
        timeline.tracks.append(overlayTrack)

        let textPayloadId = UUID()
        timeline.payloads[textPayloadId] = .text(TextPayload(text: "Test"))
        let textItem = TimelineItem(
            payloadId: textPayloadId,
            kind: .text,
            startUs: 10_000_000,
            durationUs: 1_000_000
        )
        timeline.tracks[1].items.append(textItem)

        draft.canonicalTimeline = timeline

        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let sceneId = state.sceneItems[0].id

        // When: trim scene to 2s (delta = 8s)
        // newStartUs = max(0, 10 - 8) = 2s
        // maxDuration = max(0, 2s - 2s) = 0
        // newDurationUs = min(1, 0) = 0 → item should be removed
        let result = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: sceneId, phase: .ended, newDurationUs: 2_000_000, edge: .trailing)
        )

        // Then: project = 2s
        XCTAssertEqual(result.state.projectDurationUs, 2_000_000)

        // Then: text item removed (duration became 0)
        let overlayItems = result.state.canonicalTimeline.tracks[1].items
        XCTAssertEqual(overlayItems.count, 0, "Item with 0 duration should be removed")

        // Then: payload also removed
        XCTAssertNil(result.state.canonicalTimeline.payloads[textPayloadId])
    }

    /// T10-3c: Shift-left clamps start to 0 and trims duration, but keeps item when duration > 0.
    func testShiftLeft_clampsStartToZero_andTrimsDuration_butKeepsItem() {
        // Given: 10s scene + text item at 8s with 3s duration
        var draft = makeDraft(sceneDurations: [10_000_000])
        var timeline = draft.canonicalTimeline

        let overlayTrack = Track(kind: .overlay)
        timeline.tracks.append(overlayTrack)

        let textPayloadId = UUID()
        timeline.payloads[textPayloadId] = .text(TextPayload(text: "Test"))
        let textItem = TimelineItem(
            payloadId: textPayloadId,
            kind: .text,
            startUs: 8_000_000,
            durationUs: 3_000_000
        )
        timeline.tracks[1].items.append(textItem)

        draft.canonicalTimeline = timeline

        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let sceneId = state.sceneItems[0].id

        // When: trim scene to 2s (delta = 8s)
        // newStartUs = max(0, 8 - 8) = 0
        // maxDuration = max(0, 2s - 0) = 2s
        // newDurationUs = min(3, 2) = 2s → item should remain with trimmed duration
        let result = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: sceneId, phase: .ended, newDurationUs: 2_000_000, edge: .trailing)
        )

        // Then: project = 2s
        XCTAssertEqual(result.state.projectDurationUs, 2_000_000)

        // Then: text item remains (duration > 0)
        let overlayItems = result.state.canonicalTimeline.tracks[1].items
        XCTAssertEqual(overlayItems.count, 1, "Item with duration > 0 should remain")

        // Then: startUs clamped to 0
        XCTAssertEqual(overlayItems[0].startUs, 0)

        // Then: durationUs trimmed to 2s
        XCTAssertEqual(overlayItems[0].durationUs, 2_000_000)

        // Then: payload remains
        XCTAssertNotNil(result.state.canonicalTimeline.payloads[textPayloadId])
    }

    /// T10-4: Save/Load ProjectDraft roundtrip preserves all data.
    func testProjectDraft_jsonRoundtrip() throws {
        // Given: ProjectDraft with full data
        var draft = makeDraft(sceneDurations: [3_000_000, 5_000_000])
        let scene1Id = draft.canonicalTimeline.sceneItems[0].id
        let scene2Id = draft.canonicalTimeline.sceneItems[1].id

        // Add sceneInstanceStates
        var state1 = SceneState.empty
        state1.variantOverrides["block1"] = "variant_a"
        state1.userTransforms["block1"] = Matrix2D(a: 1.5, b: 0.1, c: -0.1, d: 1.5, tx: 10, ty: 20)
        state1.layerToggles["block1"] = ["toggle1": true, "toggle2": false]
        state1.mediaSlotsByBlockId = ["block1": .photo(mediaRef: MediaRef.file("Media/test.jpg"))]
        draft.sceneInstanceStates[scene1Id] = state1

        var state2 = SceneState.empty
        state2.variantOverrides["block2"] = "variant_b"
        draft.sceneInstanceStates[scene2Id] = state2

        // Add overlay track with text item
        var timeline = draft.canonicalTimeline
        let overlayTrack = Track(kind: .overlay)
        timeline.tracks.append(overlayTrack)

        let textPayloadId = UUID()
        timeline.payloads[textPayloadId] = .text(TextPayload(text: "Hello", fontFamily: "Arial", fontSize: 24, colorHex: "#FF0000"))
        let textItem = TimelineItem(
            payloadId: textPayloadId,
            kind: .text,
            startUs: 2_000_000,
            durationUs: 1_000_000
        )
        timeline.tracks[1].items.append(textItem)
        draft.canonicalTimeline = timeline

        // Set background
        draft.background = ProjectBackgroundOverride(
            selectedPresetId: nil,
            regions: [
                "bg": RegionOverride(source: .solid(colorHex: "#0000FF"))
            ]
        )

        // When: encode → decode
        let encoder = JSONEncoder()
        let data = try encoder.encode(draft)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ProjectDraft.self, from: data)

        // Then: canonicalTimeline equal
        XCTAssertEqual(decoded.canonicalTimeline.tracks.count, draft.canonicalTimeline.tracks.count)
        XCTAssertEqual(decoded.canonicalTimeline.sceneItems.count, 2)
        XCTAssertEqual(decoded.canonicalTimeline.sceneItems[0].id, scene1Id)
        XCTAssertEqual(decoded.canonicalTimeline.sceneItems[1].id, scene2Id)
        XCTAssertEqual(decoded.canonicalTimeline.sceneItems[0].durationUs, 3_000_000)
        XCTAssertEqual(decoded.canonicalTimeline.sceneItems[1].durationUs, 5_000_000)

        // Then: sceneInstanceStates equal
        XCTAssertEqual(decoded.sceneInstanceStates.count, 2)
        XCTAssertEqual(decoded.sceneInstanceStates[scene1Id]?.variantOverrides["block1"], "variant_a")
        XCTAssertEqual(decoded.sceneInstanceStates[scene1Id]?.userTransforms["block1"]?.tx, 10)
        XCTAssertEqual(decoded.sceneInstanceStates[scene1Id]?.layerToggles["block1"]?["toggle1"], true)
        XCTAssertEqual(decoded.sceneInstanceStates[scene1Id]?.mediaSlotsByBlockId?["block1"]?.mediaRef, MediaRef.file("Media/test.jpg"))
        XCTAssertEqual(decoded.sceneInstanceStates[scene2Id]?.variantOverrides["block2"], "variant_b")

        // Then: overlay track preserved
        XCTAssertEqual(decoded.canonicalTimeline.tracks[1].kind, .overlay)
        XCTAssertEqual(decoded.canonicalTimeline.tracks[1].items.count, 1)
        XCTAssertEqual(decoded.canonicalTimeline.tracks[1].items[0].startUs, 2_000_000)

        // Then: text payload preserved
        if case .text(let textPayload) = decoded.canonicalTimeline.payloads[textPayloadId] {
            XCTAssertEqual(textPayload.text, "Hello")
            XCTAssertEqual(textPayload.fontFamily, "Arial")
            XCTAssertEqual(textPayload.fontSize, 24)
            XCTAssertEqual(textPayload.colorHex, "#FF0000")
        } else {
            XCTFail("Text payload should be preserved")
        }

        // Then: background equal
        XCTAssertEqual(decoded.background, draft.background)
    }

    // MARK: - 11. PR-A: Scene Edit Mode

    // MARK: Test Helpers for Scene Edit

    /// Creates EditorState with N scenes for Scene Edit testing.
    private func makeStateWithScenes(count: Int, durationUs: TimeUs = 2_000_000) -> EditorState {
        let durations = Array(repeating: durationUs, count: count)
        let draft = makeDraft(sceneDurations: durations)
        return EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state
    }

    /// Creates EditorState already in Scene Edit mode (first scene selected).
    private func makeStateInSceneEdit() -> EditorState {
        var state = makeStateWithScenes(count: 2)
        state.uiMode = .sceneEdit(sceneInstanceId: state.canonicalTimeline.sceneItems[0].id)
        return state
    }

    // MARK: Scene Edit Mode Tests

    /// Test: enterSceneEdit saves current playhead for return.
    func test_enterSceneEdit_savesReturnPlayhead() {
        // Given: state with playhead at frame 150 (5s at 30fps)
        var state = makeStateWithScenes(count: 3)
        state.playheadCompressedFrame = 150 // Phase 2.1: use compressed frame
        let sceneId = state.canonicalTimeline.sceneItems[1].id

        // When
        let result = EditorReducer.reduce(state: state, action: .enterSceneEdit(sceneId: sceneId))

        // Then: return position saved as compressed frame
        XCTAssertEqual(result.state.sceneEditReturnCompressedFrame, 150)
        XCTAssertEqual(result.state.uiMode, .sceneEdit(sceneInstanceId: sceneId))
        XCTAssertNil(result.state.selectedBlockId)
        XCTAssertFalse(result.shouldPushSnapshot) // UI transition
    }

    /// Test: enterSceneEdit moves playhead to scene start.
    func test_enterSceneEdit_movesPlayheadToSceneStart() {
        // Given: 3 scenes, each 2 seconds (60 frames at 30fps)
        let state = makeStateWithScenes(count: 3, durationUs: 2_000_000)
        let sceneId = state.canonicalTimeline.sceneItems[1].id // second scene starts at 2s = frame 60

        // When
        let result = EditorReducer.reduce(state: state, action: .enterSceneEdit(sceneId: sceneId))

        // Then: playhead at scene start = compressed frame 60
        XCTAssertEqual(result.state.playheadCompressedFrame, 60)
    }

    /// Test: exitSceneEdit restores playhead to saved position.
    func test_exitSceneEdit_restoresPlayhead() {
        // Given: state in sceneEdit with saved return playhead (frame 45 = 1.5s at 30fps)
        var state = makeStateWithScenes(count: 2)
        state.uiMode = .sceneEdit(sceneInstanceId: state.canonicalTimeline.sceneItems[0].id)
        state.sceneEditReturnCompressedFrame = 45 // Phase 2.1: use compressed frame
        state.playheadCompressedFrame = 0

        // When
        let result = EditorReducer.reduce(state: state, action: .exitSceneEdit)

        // Then: playhead restored to saved compressed frame
        XCTAssertEqual(result.state.playheadCompressedFrame, 45)
        XCTAssertEqual(result.state.uiMode, .timeline)
        XCTAssertNil(result.state.sceneEditReturnCompressedFrame)
        XCTAssertNil(result.state.selectedBlockId)
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    /// Test: selectBlock does not push snapshot.
    func test_selectBlock_doesNotPushSnapshot() {
        let state = makeStateInSceneEdit()

        let result = EditorReducer.reduce(state: state, action: .selectBlock(blockId: "block_1"))

        XCTAssertEqual(result.state.selectedBlockId, "block_1")
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    /// Test: selectBlock with nil clears selection.
    func test_selectBlock_nilClearsSelection() {
        var state = makeStateInSceneEdit()
        state.selectedBlockId = "block_1"

        let result = EditorReducer.reduce(state: state, action: .selectBlock(blockId: nil))

        XCTAssertNil(result.state.selectedBlockId)
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    /// Test: setBlockMediaPresent pushes snapshot and updates slot visibility.
    func test_setBlockMediaPresent_pushesSnapshot() {
        var state = makeStateInSceneEdit()
        let sceneId = state.canonicalTimeline.sceneItems[0].id
        // Need an existing slot for visibility to be updated
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = ["block_1": .photo(mediaRef: MediaRef.file("test.jpg"), visibility: true)]
        state.draft.sceneInstanceStates[sceneId] = sceneState

        let result = EditorReducer.reduce(
            state: state,
            action: .setBlockMediaPresent(sceneInstanceId: sceneId, blockId: "block_1", present: false)
        )

        XCTAssertEqual(result.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["block_1"]?.visibility, false)
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: setBlockMediaPresent with true enables visibility.
    func test_setBlockMediaPresent_enablesVisibility() {
        var state = makeStateInSceneEdit()
        let sceneId = state.canonicalTimeline.sceneItems[0].id
        // Start with disabled slot
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = ["block_1": .photo(mediaRef: MediaRef.file("test.jpg"), visibility: false)]
        state.draft.sceneInstanceStates[sceneId] = sceneState

        let result = EditorReducer.reduce(
            state: state,
            action: .setBlockMediaPresent(sceneInstanceId: sceneId, blockId: "block_1", present: true)
        )

        XCTAssertEqual(result.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["block_1"]?.visibility, true)
    }

    /// Test: resetSceneState resets to empty and pushes snapshot.
    func test_resetSceneState_resetsToEmpty() {
        var state = makeStateInSceneEdit()
        let sceneId = state.canonicalTimeline.sceneItems[0].id
        // Add some state
        var sceneState = SceneState.empty
        sceneState.variantOverrides["block_1"] = "variant_a"
        sceneState.mediaSlotsByBlockId = ["block_1": .photo(mediaRef: MediaRef.file("test.jpg"))]
        state.draft.sceneInstanceStates[sceneId] = sceneState

        let result = EditorReducer.reduce(
            state: state,
            action: .resetSceneState(sceneInstanceId: sceneId)
        )

        XCTAssertEqual(result.state.draft.sceneInstanceStates[sceneId], .empty)
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// Test: setMediaSlot stores slot with visibility=true.
    func test_setMediaSlot_setsVisibilityTrue() {
        let state = makeStateInSceneEdit()
        let sceneId = state.canonicalTimeline.sceneItems[0].id
        let mediaRef = MediaRef.file("Media/UserMedia/test.jpg")
        let slot = SceneMediaSlot.photo(mediaRef: mediaRef)

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: sceneId, blockId: "block_1", slot: slot)
        )

        // Then: slot assigned with visibility=true
        let storedSlot = result.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["block_1"]
        XCTAssertEqual(storedSlot?.mediaRef, mediaRef)
        XCTAssertEqual(storedSlot?.visibility, true)
    }

    /// Test: setMediaSlot with nil clears slot.
    func test_setMediaSlot_nilClearsSlot() {
        var state = makeStateInSceneEdit()
        let sceneId = state.canonicalTimeline.sceneItems[0].id
        // Start with assigned slot
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = ["block_1": .photo(mediaRef: MediaRef.file("old.jpg"))]
        state.draft.sceneInstanceStates[sceneId] = sceneState

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: sceneId, blockId: "block_1", slot: nil)
        )

        // Then: slot cleared
        XCTAssertNil(result.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["block_1"])
    }

    /// Test: enterSceneEdit with invalid sceneId returns unchanged state.
    func test_enterSceneEdit_invalidSceneId() {
        let state = makeStateWithScenes(count: 2)
        let invalidId = UUID()

        let result = EditorReducer.reduce(state: state, action: .enterSceneEdit(sceneId: invalidId))

        XCTAssertEqual(result.state.uiMode, .timeline)
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    /// Test: EditorStore callbacks fire on UI mode change.
    @MainActor func test_editorStore_onUIModeChanged() {
        let draft = makeDraft(sceneDurations: [2_000_000, 3_000_000])
        let store = EditorStore()
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        var callbackFired = false
        var receivedMode: EditorUIMode?
        store.onUIModeChanged = { mode in
            callbackFired = true
            receivedMode = mode
        }

        let sceneId = store.sceneItems[0].id
        store.dispatch(.enterSceneEdit(sceneId: sceneId))

        XCTAssertTrue(callbackFired)
        XCTAssertEqual(receivedMode, .sceneEdit(sceneInstanceId: sceneId))
    }

    /// Test: EditorStore callbacks fire on selected block change.
    @MainActor func test_editorStore_onSelectedBlockChanged() {
        let draft = makeDraft(sceneDurations: [2_000_000])
        let store = EditorStore()
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        let sceneId = store.sceneItems[0].id
        store.dispatch(.enterSceneEdit(sceneId: sceneId))

        var callbackFired = false
        var receivedBlockId: String?
        store.onSelectedBlockChanged = { blockId in
            callbackFired = true
            receivedBlockId = blockId
        }

        store.dispatch(.selectBlock(blockId: "block_1"))

        XCTAssertTrue(callbackFired)
        XCTAssertEqual(receivedBlockId, "block_1")
    }

    /// Test: EditorStore onStateRestoredFromUndoRedo fires after undo.
    @MainActor func test_editorStore_onStateRestoredFromUndoRedo() {
        let draft = makeDraft(sceneDurations: [2_000_000])
        let store = EditorStore()
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        let sceneId = store.sceneItems[0].id

        // Make a change that pushes snapshot
        store.dispatch(.setBlockVariant(sceneInstanceId: sceneId, blockId: "block_1", variantId: "variant_a"))

        var callbackFired = false
        store.onStateRestoredFromUndoRedo = {
            callbackFired = true
        }

        // When: undo
        store.dispatch(.undo)

        XCTAssertTrue(callbackFired)
    }

    /// Test: mediaSlotsByBlockId roundtrip through JSON.
    func test_sceneState_mediaSlots_jsonRoundtrip() throws {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            "block_1": .photo(mediaRef: MediaRef.file("Media/test.jpg"), visibility: true),
            "block_2": .video(
                mediaRef: MediaRef.file("Media/video.mp4", mediaKind: .video),
                visibility: false,
                videoWindow: PersistedVideoSelection(trimStart: 1.0, trimEnd: 5.0)
            )
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SceneState.self, from: data)

        XCTAssertEqual(decoded.mediaSlotsByBlockId?["block_1"]?.visibility, true)
        XCTAssertEqual(decoded.mediaSlotsByBlockId?["block_1"]?.mediaRef, MediaRef.file("Media/test.jpg"))
        XCTAssertEqual(decoded.mediaSlotsByBlockId?["block_2"]?.visibility, false)
        XCTAssertEqual(decoded.mediaSlotsByBlockId?["block_2"]?.videoWindow?.trimStart, 1.0)
        XCTAssertEqual(decoded.mediaSlotsByBlockId?["block_2"]?.videoWindow?.trimEnd, 5.0)
    }

    // MARK: - Video Selection Store Routing

    /// onVideoSelectionChanged fires on committed setVideoSelection.
    @MainActor func test_onVideoSelectionChanged_firesOnCommit() {
        let draft = makeDraft(sceneDurations: [2_000_000])
        let store = EditorStore(initialState: EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state)

        let sceneId = store.state.sceneItems[0].id
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )
        store.dispatch(.setMediaSlot(sceneInstanceId: sceneId, blockId: "block_01", slot: videoSlot))

        var videoChangeFired = false
        store.onVideoSelectionChanged = { _, _, _ in
            videoChangeFired = true
        }

        var sceneChangeFired = false
        store.onSceneStateChanged = { _, _ in
            sceneChangeFired = true
        }

        let newSelection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 9.0)
        store.dispatch(.setVideoSelection(sceneInstanceId: sceneId, blockId: "block_01", selection: newSelection))

        XCTAssertTrue(videoChangeFired, "onVideoSelectionChanged should fire")
        XCTAssertFalse(sceneChangeFired, "onSceneStateChanged should NOT fire for video selection")
    }

    /// onSceneStateChanged does NOT fire for setVideoSelection.
    @MainActor func test_onSceneStateChanged_doesNotFireForVideoSelection() {
        let draft = makeDraft(sceneDurations: [2_000_000])
        let store = EditorStore(initialState: EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state)

        let sceneId = store.state.sceneItems[0].id
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )
        store.dispatch(.setMediaSlot(sceneInstanceId: sceneId, blockId: "block_01", slot: videoSlot))

        var sceneChangeFired = false
        store.onSceneStateChanged = { _, _ in
            sceneChangeFired = true
        }

        let newSelection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 9.0)
        store.dispatch(.setVideoSelection(sceneInstanceId: sceneId, blockId: "block_01", selection: newSelection))

        XCTAssertFalse(sceneChangeFired, "onSceneStateChanged must not fire for video selection changes")
    }

    /// Undo after committed setVideoSelection restores previous selection.
    @MainActor func test_undoAfterVideoSelection_restoresPrevious() {
        let draft = makeDraft(sceneDurations: [2_000_000])
        let store = EditorStore(initialState: EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state)

        let sceneId = store.state.sceneItems[0].id
        let originalSelection = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            videoWindow: originalSelection
        )
        store.dispatch(.setMediaSlot(sceneInstanceId: sceneId, blockId: "block_01", slot: videoSlot))

        let newSelection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        store.dispatch(.setVideoSelection(sceneInstanceId: sceneId, blockId: "block_01", selection: newSelection))

        // Verify new selection applied
        let afterSlot = store.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["block_01"]
        XCTAssertEqual(afterSlot?.videoWindow?.trimStart, 2.0)

        // Undo
        store.dispatch(.undo)

        let undoneSlot = store.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["block_01"]
        XCTAssertEqual(undoneSlot?.videoWindow?.trimStart, 0, "Undo should restore original trimStart")
        XCTAssertEqual(undoneSlot?.videoWindow?.trimEnd, 10.0, "Undo should restore original trimEnd")
    }

    /// Dispatching setVideoSelection with same values as current does not push undo snapshot (idempotent).
    @MainActor func test_setVideoSelection_unchangedSelection_doesNotPushSnapshot() {
        let draft = makeDraft(sceneDurations: [2_000_000])
        let store = EditorStore(initialState: EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state)

        let sceneId = store.state.sceneItems[0].id
        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 9.0)
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            videoWindow: selection
        )
        store.dispatch(.setMediaSlot(sceneInstanceId: sceneId, blockId: "block_01", slot: videoSlot))

        // canUndo is true after setMediaSlot; dispatch same selection
        var callbackFired = false
        store.onVideoSelectionChanged = { _, _, _ in callbackFired = true }

        store.dispatch(.setVideoSelection(sceneInstanceId: sceneId, blockId: "block_01", selection: selection))

        XCTAssertFalse(callbackFired, "Idempotent setVideoSelection should not fire callback (shouldPushSnapshot == false)")
    }

    /// onVideoSelectionChanged callback receives the exact parameters that were dispatched.
    @MainActor func test_setVideoSelection_callbackReceivesExactParameters() {
        let draft = makeDraft(sceneDurations: [2_000_000])
        let store = EditorStore(initialState: EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state)

        let sceneId = store.state.sceneItems[0].id
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )
        store.dispatch(.setMediaSlot(sceneInstanceId: sceneId, blockId: "block_01", slot: videoSlot))

        var receivedInstanceId: UUID?
        var receivedBlockId: String?
        var receivedSelection: PersistedVideoSelection?
        store.onVideoSelectionChanged = { instanceId, blockId, selection in
            receivedInstanceId = instanceId
            receivedBlockId = blockId
            receivedSelection = selection
        }

        let newSelection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 7.0)
        store.dispatch(.setVideoSelection(sceneInstanceId: sceneId, blockId: "block_01", selection: newSelection))

        XCTAssertEqual(receivedInstanceId, sceneId, "Callback should receive dispatched sceneInstanceId")
        XCTAssertEqual(receivedBlockId, "block_01", "Callback should receive dispatched blockId")
        XCTAssertEqual(receivedSelection?.trimStart, 2.0, "Callback should receive dispatched trimStart")
        XCTAssertEqual(receivedSelection?.trimEnd, 7.0, "Callback should receive dispatched trimEnd")
    }
}
