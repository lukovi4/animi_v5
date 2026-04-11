import XCTest
import TVECore
@testable import AnimiApp

/// Tests that EditorReducer guards against resurrecting deleted scenes.
///
/// Verifies:
/// - setMediaSlot for a deleted sceneInstanceId is a no-op
/// - setVideoSelection for a deleted sceneInstanceId is a no-op
/// - setBlockMediaPresent for a deleted sceneInstanceId is a no-op
/// - None of these create a new sceneInstanceState for a non-existent scene
final class EditorReducerSceneExistenceTests: XCTestCase {

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

    private func makeStateWithOneScene() -> EditorState {
        let draft = makeDraft(sceneDurations: [2_000_000])
        return EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state
    }

    // MARK: - setMediaSlot

    /// setMediaSlot for a scene that exists in the timeline succeeds normally.
    func test_setMediaSlot_existingScene_succeeds() {
        let state = makeStateWithOneScene()
        let sceneId = state.sceneItems[0].id
        let slot = SceneMediaSlot.photo(mediaRef: MediaRef.file("Media/test.jpg"), placement: .default(fitMode: .cover))

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: sceneId, blockId: "block_01", slot: slot)
        )

        XCTAssertNotNil(result.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["block_01"])
        XCTAssertTrue(result.shouldPushSnapshot)
    }

    /// setMediaSlot for a sceneInstanceId NOT in the timeline is a no-op.
    /// Must not create sceneInstanceState for deleted scene.
    func test_setMediaSlot_deletedScene_isNoOp() {
        let state = makeStateWithOneScene()
        let deletedSceneId = UUID() // Not in the timeline
        let slot = SceneMediaSlot.photo(mediaRef: MediaRef.file("Media/test.jpg"), placement: .default(fitMode: .cover))

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: deletedSceneId, blockId: "block_01", slot: slot)
        )

        // Must not create state for deleted scene
        XCTAssertNil(result.state.draft.sceneInstanceStates[deletedSceneId])
        // Must not push snapshot
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    // MARK: - setVideoSelection

    /// setVideoSelection for a deleted scene is a no-op.
    func test_setVideoSelection_deletedScene_isNoOp() {
        let state = makeStateWithOneScene()
        let deletedSceneId = UUID()
        let selection = PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)

        let result = EditorReducer.reduce(
            state: state,
            action: .setVideoSelection(sceneInstanceId: deletedSceneId, blockId: "block_01", selection: selection)
        )

        XCTAssertNil(result.state.draft.sceneInstanceStates[deletedSceneId])
    }

    /// setVideoSelection on a photo slot is a no-op (mediaKind guard).
    func test_setVideoSelection_onPhotoSlot_isNoOp() {
        var state = makeStateWithOneScene()
        let sceneId = state.sceneItems[0].id
        let photoSlot = SceneMediaSlot.photo(mediaRef: MediaRef.file("Media/test.jpg"), placement: .default(fitMode: .cover))

        // First, assign a photo slot
        state = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: sceneId, blockId: "block_01", slot: photoSlot)
        ).state

        // Then try to set video selection on the photo slot
        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 4.0)
        let result = EditorReducer.reduce(
            state: state,
            action: .setVideoSelection(sceneInstanceId: sceneId, blockId: "block_01", selection: selection)
        )

        // Should be a no-op — videoWindow should remain nil
        let slot = result.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["block_01"]
        XCTAssertNil(slot?.videoWindow, "setVideoSelection on photo slot should be a no-op")
    }

    /// setVideoSelection on a missing slot is a no-op.
    func test_setVideoSelection_onMissingSlot_isNoOp() {
        let state = makeStateWithOneScene()
        let sceneId = state.sceneItems[0].id
        let selection = PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)

        let result = EditorReducer.reduce(
            state: state,
            action: .setVideoSelection(sceneInstanceId: sceneId, blockId: "nonexistent_block", selection: selection)
        )

        // Should be a no-op — no slot created
        let slot = result.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["nonexistent_block"]
        XCTAssertNil(slot, "setVideoSelection on missing slot should not create one")
    }

    /// setVideoSelection on a video slot updates videoWindow and pushes snapshot.
    func test_setVideoSelection_onVideoSlot_updatesVideoWindow() {
        var state = makeStateWithOneScene()
        let sceneId = state.sceneItems[0].id
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            placement: .defaultCover,
            videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )

        // First, assign a video slot
        state = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: sceneId, blockId: "block_01", slot: videoSlot)
        ).state

        // Then update video selection
        let newSelection = PersistedVideoSelection(trimStart: 2.0, trimEnd: 8.0)
        let result = EditorReducer.reduce(
            state: state,
            action: .setVideoSelection(sceneInstanceId: sceneId, blockId: "block_01", selection: newSelection)
        )

        let slot = result.state.draft.sceneInstanceStates[sceneId]?.mediaSlotsByBlockId?["block_01"]
        XCTAssertEqual(slot?.videoWindow?.trimStart, 2.0)
        XCTAssertEqual(slot?.videoWindow?.trimEnd, 8.0)
        XCTAssertTrue(result.shouldPushSnapshot, "Changed selection should push undo snapshot")
    }

    /// setVideoSelection with identical selection is a no-op (no snapshot).
    func test_setVideoSelection_unchangedSelection_noSnapshot() {
        var state = makeStateWithOneScene()
        let sceneId = state.sceneItems[0].id
        let selection = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            placement: .defaultCover,
            videoWindow: selection
        )

        // Assign a video slot
        state = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: sceneId, blockId: "block_01", slot: videoSlot)
        ).state

        // Set the same selection again
        let result = EditorReducer.reduce(
            state: state,
            action: .setVideoSelection(sceneInstanceId: sceneId, blockId: "block_01", selection: selection)
        )

        XCTAssertFalse(result.shouldPushSnapshot, "Unchanged selection should not push snapshot")
    }

    // MARK: - setBlockMediaPresent

    /// setBlockMediaPresent for a deleted scene is a no-op.
    func test_setBlockMediaPresent_deletedScene_isNoOp() {
        let state = makeStateWithOneScene()
        let deletedSceneId = UUID()

        let result = EditorReducer.reduce(
            state: state,
            action: .setBlockMediaPresent(sceneInstanceId: deletedSceneId, blockId: "block_01", present: true)
        )

        XCTAssertNil(result.state.draft.sceneInstanceStates[deletedSceneId])
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    // MARK: - Full scenario: delete scene then ingest completes

    /// Simulates: ingest starts for scene A → scene A deleted → ingest completes → dispatch setMediaSlot.
    /// The dispatch must be a no-op because scene A is no longer in the timeline.
    func test_deleteScene_thenSetMediaSlot_isNoOp() {
        // Given: two scenes
        let draft = makeDraft(sceneDurations: [2_000_000, 3_000_000])
        var state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state

        let sceneAId = state.sceneItems[0].id

        // When: delete scene A
        state = EditorReducer.reduce(
            state: state,
            action: .deleteScene(sceneId: sceneAId)
        ).state

        // Then: scene A no longer in timeline
        XCTAssertFalse(state.sceneItems.contains(where: { $0.id == sceneAId }))

        // When: late ingest completion dispatches setMediaSlot for deleted scene A
        let lateResult = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(
                sceneInstanceId: sceneAId,
                blockId: "block_01",
                slot: .photo(mediaRef: MediaRef.file("Media/test.jpg"), placement: .default(fitMode: .cover))
            )
        )

        // Then: no state created for deleted scene
        XCTAssertNil(lateResult.state.draft.sceneInstanceStates[sceneAId])
        XCTAssertFalse(lateResult.shouldPushSnapshot)
    }
}
