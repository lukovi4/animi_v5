import XCTest
@testable import AnimiApp
import TVECore

/// Tests for PR2: media placement actions, reducers, callbacks, and video import default.
final class MediaPlacementReducerTests: XCTestCase {

    // MARK: - Helpers

    private func makeStateWithMediaSlot(
        fitMode: FitMode = .cover,
        placement: MediaPlacementState? = nil
    ) -> (EditorState, UUID, String) {
        var draft = ProjectDraft.create(for: "test-template")
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]
        let payloadId = UUID()
        payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "test_scene"))
        let item = TimelineItem(payloadId: payloadId, kind: .scene, startUs: nil, durationUs: 3_000_000)
        timeline.tracks[0].items.append(item)
        timeline.payloads = payloads
        draft.canonicalTimeline = timeline

        let sceneInstanceId = item.id
        let blockId = "block1"

        let slot = SceneMediaSlot.photo(
            mediaRef: .file("Media/UserMedia/photo.jpg", mediaKind: .photo),
            placement: placement ?? .default(fitMode: fitMode)
        )
        draft.sceneInstanceStates[sceneInstanceId] = SceneState(
            mediaSlotsByBlockId: [blockId: slot]
        )

        let loadResult = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        )
        return (loadResult.state, sceneInstanceId, blockId)
    }

    private func makeStateWithoutSlot() -> (EditorState, UUID, String) {
        var draft = ProjectDraft.create(for: "test-template")
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]
        let payloadId = UUID()
        payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "test_scene"))
        let item = TimelineItem(payloadId: payloadId, kind: .scene, startUs: nil, durationUs: 3_000_000)
        timeline.tracks[0].items.append(item)
        timeline.payloads = payloads
        draft.canonicalTimeline = timeline

        let sceneInstanceId = item.id
        let blockId = "block1"

        draft.sceneInstanceStates[sceneInstanceId] = SceneState()

        let loadResult = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        )
        return (loadResult.state, sceneInstanceId, blockId)
    }

    // MARK: - setMediaPlacement

    func test_setMediaPlacement_began_doesNotPushSnapshot() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()
        let placement = MediaPlacementState(fitMode: .cover, offsetX: 10, offsetY: 20)

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaPlacement(sceneInstanceId: instanceId, blockId: blockId, placement: placement, phase: .began)
        )

        XCTAssertFalse(result.shouldPushSnapshot)
        let updatedPlacement = result.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.asset.placement
        XCTAssertEqual(updatedPlacement?.offsetX, 10)
    }

    func test_setMediaPlacement_changed_doesNotPushSnapshot() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()
        let placement = MediaPlacementState(fitMode: .cover, offsetX: 50, offsetY: -30, userScale: 1.5)

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaPlacement(sceneInstanceId: instanceId, blockId: blockId, placement: placement, phase: .changed)
        )

        XCTAssertFalse(result.shouldPushSnapshot)
        let updatedPlacement = result.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.asset.placement
        XCTAssertEqual(updatedPlacement?.userScale, 1.5)
    }

    func test_setMediaPlacement_ended_pushesSnapshot() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()
        let placement = MediaPlacementState(fitMode: .cover, offsetX: 10, offsetY: 20, userScale: 2.0, rotationDegrees: 45)

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaPlacement(sceneInstanceId: instanceId, blockId: blockId, placement: placement, phase: .ended)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        let updatedPlacement = result.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.asset.placement
        XCTAssertEqual(updatedPlacement?.offsetX, 10)
        XCTAssertEqual(updatedPlacement?.offsetY, 20)
        XCTAssertEqual(updatedPlacement?.userScale, 2.0)
        XCTAssertEqual(updatedPlacement?.rotationDegrees, 45)
    }

    func test_setMediaPlacement_cancelled_revertsState() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()
        let placement = MediaPlacementState(fitMode: .cover, offsetX: 999)

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaPlacement(sceneInstanceId: instanceId, blockId: blockId, placement: placement, phase: .cancelled)
        )

        XCTAssertFalse(result.shouldPushSnapshot)
        // State should be reverted (original placement preserved)
        let updatedPlacement = result.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.asset.placement
        XCTAssertEqual(updatedPlacement?.offsetX, 0, "Cancelled should revert to original state")
    }

    func test_setMediaPlacement_noSlot_noop() {
        let (state, instanceId, blockId) = makeStateWithoutSlot()
        let placement = MediaPlacementState(fitMode: .cover, offsetX: 10)

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaPlacement(sceneInstanceId: instanceId, blockId: blockId, placement: placement, phase: .ended)
        )

        XCTAssertFalse(result.shouldPushSnapshot, "No slot = no-op")
    }

    // MARK: - setMediaFitMode

    func test_setMediaFitMode_resetsOffsetScaleRotation() {
        let customPlacement = MediaPlacementState(fitMode: .cover, offsetX: 50, offsetY: 30, userScale: 2.0, rotationDegrees: 90)
        let (state, instanceId, blockId) = makeStateWithMediaSlot(placement: customPlacement)

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaFitMode(sceneInstanceId: instanceId, blockId: blockId, fitMode: .contain)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        let updatedPlacement = result.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.asset.placement
        XCTAssertEqual(updatedPlacement?.fitMode, .contain)
        XCTAssertEqual(updatedPlacement?.offsetX, 0)
        XCTAssertEqual(updatedPlacement?.offsetY, 0)
        XCTAssertEqual(updatedPlacement?.userScale, 1.0)
        XCTAssertEqual(updatedPlacement?.rotationDegrees, 0)
    }

    func test_setMediaFitMode_noSlot_noop() {
        let (state, instanceId, blockId) = makeStateWithoutSlot()

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaFitMode(sceneInstanceId: instanceId, blockId: blockId, fitMode: .fill)
        )

        XCTAssertFalse(result.shouldPushSnapshot)
    }

    // MARK: - resetMediaPlacement

    func test_resetMediaPlacement_preservesFitMode() {
        let customPlacement = MediaPlacementState(fitMode: .contain, offsetX: 100, offsetY: -50, userScale: 3.0, rotationDegrees: -45)
        let (state, instanceId, blockId) = makeStateWithMediaSlot(placement: customPlacement)

        let result = EditorReducer.reduce(
            state: state,
            action: .resetMediaPlacement(sceneInstanceId: instanceId, blockId: blockId)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        let updatedPlacement = result.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.asset.placement
        XCTAssertEqual(updatedPlacement?.fitMode, .contain, "fitMode must be preserved")
        XCTAssertEqual(updatedPlacement?.offsetX, 0)
        XCTAssertEqual(updatedPlacement?.offsetY, 0)
        XCTAssertEqual(updatedPlacement?.userScale, 1.0)
        XCTAssertEqual(updatedPlacement?.rotationDegrees, 0)
        XCTAssertTrue(updatedPlacement?.isDefault ?? false)
    }

    func test_resetMediaPlacement_noPlacement_noop() {
        // Slot exists but placement is nil (legacy, not yet hydrated)
        let (state, instanceId, blockId) = makeStateWithMediaSlot(placement: nil)

        // Override placement to nil
        var mutState = state
        mutState.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.asset.placement = nil

        let result = EditorReducer.reduce(
            state: mutState,
            action: .resetMediaPlacement(sceneInstanceId: instanceId, blockId: blockId)
        )

        XCTAssertFalse(result.shouldPushSnapshot, "No placement = no-op")
    }

    // MARK: - Operations Table (from task.md)

    func test_insertMedia_createsSlotWithDefaultPlacement() {
        let (state, instanceId, _) = makeStateWithoutSlot()
        let newBlockId = "block_new"
        let slot = SceneMediaSlot.photo(
            mediaRef: .file("Media/UserMedia/new.jpg", mediaKind: .photo)
        )

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: instanceId, blockId: newBlockId, slot: slot)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        let insertedSlot = result.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[newBlockId]
        XCTAssertNotNil(insertedSlot)
        XCTAssertEqual(insertedSlot?.visibility, true)
    }

    func test_replaceMedia_createsNewSlot() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()
        let newSlot = SceneMediaSlot.photo(
            mediaRef: .file("Media/UserMedia/replacement.jpg", mediaKind: .photo)
        )

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: instanceId, blockId: blockId, slot: newSlot)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        let updatedSlot = result.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]
        XCTAssertEqual(updatedSlot?.mediaRef.id, "Media/UserMedia/replacement.jpg")
    }

    func test_replaceMedia_preservesHiddenVisibility() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()

        // First: hide the slot
        let hideResult = EditorReducer.reduce(
            state: state,
            action: .setBlockMediaPresent(sceneInstanceId: instanceId, blockId: blockId, present: false)
        )
        XCTAssertEqual(
            hideResult.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.visibility,
            false
        )

        // Then: replace media — visibility must stay false
        let newSlot = SceneMediaSlot.photo(
            mediaRef: .file("Media/UserMedia/replacement.jpg", mediaKind: .photo)
        )
        let replaceResult = EditorReducer.reduce(
            state: hideResult.state,
            action: .setMediaSlot(sceneInstanceId: instanceId, blockId: blockId, slot: newSlot)
        )

        let updatedSlot = replaceResult.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]
        XCTAssertEqual(updatedSlot?.mediaRef.id, "Media/UserMedia/replacement.jpg")
        XCTAssertEqual(updatedSlot?.visibility, false, "Replace must preserve hidden visibility")
    }

    func test_removeMedia_clearsSlot() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()

        let result = EditorReducer.reduce(
            state: state,
            action: .setMediaSlot(sceneInstanceId: instanceId, blockId: blockId, slot: nil)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        let removedSlot = result.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]
        XCTAssertNil(removedSlot)
    }

    func test_hideShow_togglesVisibility() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()

        // Hide
        let hideResult = EditorReducer.reduce(
            state: state,
            action: .setBlockMediaPresent(sceneInstanceId: instanceId, blockId: blockId, present: false)
        )
        XCTAssertEqual(
            hideResult.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.visibility,
            false
        )

        // Show
        let showResult = EditorReducer.reduce(
            state: hideResult.state,
            action: .setBlockMediaPresent(sceneInstanceId: instanceId, blockId: blockId, present: true)
        )
        XCTAssertEqual(
            showResult.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.visibility,
            true
        )
    }

    func test_resetSceneState_clearsAllSlots() {
        let (state, instanceId, _) = makeStateWithMediaSlot()

        let result = EditorReducer.reduce(
            state: state,
            action: .resetSceneState(sceneInstanceId: instanceId)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        let sceneState = result.state.draft.sceneInstanceStates[instanceId]
        XCTAssertNil(sceneState?.mediaSlotsByBlockId)
    }

    func test_duplicateScene_copiesMediaState() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot(
            placement: MediaPlacementState(fitMode: .contain, offsetX: 42, offsetY: 7, userScale: 1.5, rotationDegrees: 30)
        )

        let result = EditorReducer.reduce(
            state: state,
            action: .duplicateScene(sceneItemId: instanceId)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        // Find the new scene (should be at index 1)
        let scenes = result.state.sceneItems
        XCTAssertEqual(scenes.count, 2)
        let newInstanceId = scenes[1].id
        XCTAssertNotEqual(newInstanceId, instanceId)

        let copiedSlot = result.state.draft.sceneInstanceStates[newInstanceId]?.mediaSlotsByBlockId?[blockId]
        XCTAssertNotNil(copiedSlot)
        XCTAssertEqual(copiedSlot?.asset.placement?.fitMode, .contain)
        XCTAssertEqual(copiedSlot?.asset.placement?.offsetX, 42)
        XCTAssertEqual(copiedSlot?.asset.placement?.userScale, 1.5)
    }

    // MARK: - Callback Routing (EditorStore level)

    @MainActor
    func test_callbackRouting_setMediaPlacement_ended_firesPlacementCallback() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()
        let store = EditorStore(initialState: state)

        var placementCallbackFired = false
        var sceneStateCallbackFired = false
        store.onMediaPlacementChanged = { _, _, _ in placementCallbackFired = true }
        store.onSceneStateChanged = { _, _ in sceneStateCallbackFired = true }

        let placement = MediaPlacementState(fitMode: .cover, offsetX: 10)
        store.dispatch(.setMediaPlacement(sceneInstanceId: instanceId, blockId: blockId, placement: placement, phase: .began))
        store.dispatch(.setMediaPlacement(sceneInstanceId: instanceId, blockId: blockId, placement: placement, phase: .ended))

        XCTAssertTrue(placementCallbackFired)
        XCTAssertTrue(sceneStateCallbackFired)
    }

    @MainActor
    func test_callbackRouting_setMediaSlot_firesSlotCallback() {
        let (state, instanceId, _) = makeStateWithoutSlot()
        let store = EditorStore(initialState: state)

        var slotCallbackFired = false
        store.onMediaSlotChanged = { _, _, _ in slotCallbackFired = true }

        let slot = SceneMediaSlot.photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        store.dispatch(.setMediaSlot(sceneInstanceId: instanceId, blockId: "block1", slot: slot))

        XCTAssertTrue(slotCallbackFired)
    }

    @MainActor
    func test_callbackRouting_setBlockMediaPresent_firesVisibilityCallback() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()
        let store = EditorStore(initialState: state)

        var visibilityCallbackFired = false
        store.onMediaVisibilityChanged = { _, _, _ in visibilityCallbackFired = true }

        store.dispatch(.setBlockMediaPresent(sceneInstanceId: instanceId, blockId: blockId, present: false))

        XCTAssertTrue(visibilityCallbackFired)
    }

    @MainActor
    func test_callbackRouting_setMediaPlacement_changed_doesNotFireCallbacks() {
        let (state, instanceId, blockId) = makeStateWithMediaSlot()
        let store = EditorStore(initialState: state)

        var anyCallbackFired = false
        store.onMediaPlacementChanged = { _, _, _ in anyCallbackFired = true }
        store.onSceneStateChanged = { _, _ in anyCallbackFired = true }

        let placement = MediaPlacementState(fitMode: .cover, offsetX: 50)
        store.dispatch(.setMediaPlacement(sceneInstanceId: instanceId, blockId: blockId, placement: placement, phase: .changed))

        XCTAssertFalse(anyCallbackFired, "Live preview (changed) must not fire callbacks")
    }

    // MARK: - setBlockVariant preserves placement

    func test_setBlockVariant_preservesMediaPlacement() {
        let customPlacement = MediaPlacementState(
            fitMode: .contain, offsetX: 42, offsetY: -17,
            userScale: 2.5, rotationDegrees: 63
        )
        let (state, instanceId, blockId) = makeStateWithMediaSlot(placement: customPlacement)

        let result = EditorReducer.reduce(
            state: state,
            action: .setBlockVariant(sceneInstanceId: instanceId, blockId: blockId, variantId: "variant_b")
        )

        // Variant updated
        XCTAssertEqual(
            result.state.draft.sceneInstanceStates[instanceId]?.variantOverrides[blockId],
            "variant_b"
        )
        XCTAssertTrue(result.shouldPushSnapshot)

        // Placement untouched
        let placement = result.state.draft.sceneInstanceStates[instanceId]?
            .mediaSlotsByBlockId?[blockId]?.asset.placement
        XCTAssertEqual(placement?.fitMode, .contain)
        XCTAssertEqual(placement?.offsetX, 42)
        XCTAssertEqual(placement?.offsetY, -17)
        XCTAssertEqual(placement?.userScale, 2.5)
        XCTAssertEqual(placement?.rotationDegrees, 63)
    }

    // MARK: - Gesture Lifecycle Integration (Store level)

    @MainActor
    func test_beganChangedCancelled_restoresBaselineInDraft() {
        let originalPlacement = MediaPlacementState(fitMode: .cover, offsetX: 0, offsetY: 0, userScale: 1.0)
        let (state, instanceId, blockId) = makeStateWithMediaSlot(placement: originalPlacement)
        let store = EditorStore(initialState: state)

        // began → store captures baseline snapshot
        store.dispatch(.setMediaPlacement(
            sceneInstanceId: instanceId, blockId: blockId,
            placement: originalPlacement, phase: .began
        ))

        // changed → mutates draft (live preview)
        let midPlacement = MediaPlacementState(fitMode: .cover, offsetX: 100, offsetY: 50, userScale: 2.0)
        store.dispatch(.setMediaPlacement(
            sceneInstanceId: instanceId, blockId: blockId,
            placement: midPlacement, phase: .changed
        ))

        // Verify mid-gesture state is applied
        let midSlot = store.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]
        XCTAssertEqual(midSlot?.asset.placement?.offsetX, 100, "Changed should update draft")

        // cancelled → restores baseline
        store.dispatch(.setMediaPlacement(
            sceneInstanceId: instanceId, blockId: blockId,
            placement: originalPlacement, phase: .cancelled
        ))

        let restoredSlot = store.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]
        XCTAssertEqual(restoredSlot?.asset.placement?.offsetX, 0, "Cancel must restore baseline")
        XCTAssertEqual(restoredSlot?.asset.placement?.userScale, 1.0, "Cancel must restore baseline scale")
    }

    @MainActor
    func test_beganChangedEnded_thenUndo_restoresBaseline() {
        let originalPlacement = MediaPlacementState(fitMode: .cover, offsetX: 0, offsetY: 0)
        let (state, instanceId, blockId) = makeStateWithMediaSlot(placement: originalPlacement)
        let store = EditorStore(initialState: state)

        // Full gesture lifecycle
        store.dispatch(.setMediaPlacement(
            sceneInstanceId: instanceId, blockId: blockId,
            placement: originalPlacement, phase: .began
        ))
        let finalPlacement = MediaPlacementState(fitMode: .cover, offsetX: 200, offsetY: -50, userScale: 3.0, rotationDegrees: 45)
        store.dispatch(.setMediaPlacement(
            sceneInstanceId: instanceId, blockId: blockId,
            placement: finalPlacement, phase: .ended
        ))

        // Verify ended state
        let endedSlot = store.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]
        XCTAssertEqual(endedSlot?.asset.placement?.offsetX, 200)
        XCTAssertEqual(endedSlot?.asset.placement?.rotationDegrees, 45)

        // Undo → restores pre-began baseline
        store.dispatch(.undo)

        let undoneSlot = store.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]
        XCTAssertEqual(undoneSlot?.asset.placement?.offsetX, 0, "Undo must restore pre-gesture baseline")
        XCTAssertEqual(undoneSlot?.asset.placement?.userScale, 1.0, "Undo must restore baseline scale")
        XCTAssertEqual(undoneSlot?.asset.placement?.rotationDegrees, 0, "Undo must restore baseline rotation")
    }
}
