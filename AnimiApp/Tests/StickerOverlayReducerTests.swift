import XCTest
import TVECore
@testable import AnimiApp

/// Tests for sticker overlay reducer logic (PR10).
/// Covers add/remove/move/trim/drag + undo/redo + selection.
@MainActor
final class StickerOverlayReducerTests: XCTestCase {

    // MARK: - Helpers

    private func makeDraft(sceneDurations: [TimeUs]) -> ProjectDraft {
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]
        for (index, duration) in sceneDurations.enumerated() {
            let payloadId = UUID()
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "scene_\(index)"))
            let item = TimelineItem(payloadId: payloadId, kind: .scene, startUs: nil, durationUs: duration)
            timeline.tracks[0].items.append(item)
        }
        timeline.payloads = payloads
        draft.canonicalTimeline = timeline
        return draft
    }

    private func loadState(sceneDurations: [TimeUs] = [3_000_000]) -> EditorState {
        let draft = makeDraft(sceneDurations: sceneDurations)
        return EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state
    }

    private func addSticker(to state: EditorState, stickerId: String = "star", startUs: TimeUs = 0, durationUs: TimeUs = 2_000_000) -> ReducerResult {
        EditorReducer.reduce(
            state: state,
            action: .addStickerOverlay(stickerId: stickerId, startUs: startUs, durationUs: durationUs)
        )
    }

    // MARK: - Add Sticker Overlay

    func testAddStickerOverlay_createsTrackItemPayload() {
        let state = loadState()

        let result = addSticker(to: state)

        XCTAssertTrue(result.shouldPushSnapshot)

        // Overlay track created
        let overlayTrack = result.state.canonicalTimeline.overlayTrack
        XCTAssertNotNil(overlayTrack)
        XCTAssertEqual(overlayTrack?.items.count, 1)

        let item = overlayTrack!.items.first!
        XCTAssertEqual(item.kind, .sticker)
        XCTAssertEqual(item.startUs, 0)
        XCTAssertEqual(item.durationUs, 2_000_000)

        // Payload
        let payload = result.state.canonicalTimeline.stickerPayload(for: item.id)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.stickerId, "star")
        XCTAssertEqual(payload?.centerX, 0.5)
        XCTAssertEqual(payload?.centerY, 0.5)
    }

    func testAddStickerOverlay_selectsStickerItem() {
        let state = loadState()
        let result = addSticker(to: state)
        let itemId = result.state.canonicalTimeline.stickerItems.first!.id

        if case .sticker(let selectedId) = result.state.selection {
            XCTAssertEqual(selectedId, itemId)
        } else {
            XCTFail("Expected .sticker selection")
        }
    }

    func testAddStickerOverlay_clampsToProjectDuration() {
        let state = loadState(sceneDurations: [1_000_000])

        let result = addSticker(to: state, startUs: 500_000, durationUs: 3_000_000)
        let item = result.state.canonicalTimeline.stickerItems.first!

        // Duration should be clamped
        XCTAssertLessThanOrEqual(item.startUs! + item.durationUs, state.projectDurationUs)
    }

    func testAddStickerOverlay_atProjectEnd_clampsStart() {
        let state = loadState(sceneDurations: [1_000_000])

        let result = addSticker(to: state, startUs: 5_000_000, durationUs: 1_000_000)
        let item = result.state.canonicalTimeline.stickerItems.first!

        // Start should be clamped to allow minimum duration
        XCTAssertGreaterThanOrEqual(item.durationUs, 500_000)
    }

    // MARK: - Delete Sticker

    func testDeleteItem_removesSticker() {
        var state = loadState()
        state = addSticker(to: state).state
        let itemId = state.canonicalTimeline.stickerItems.first!.id

        let result = EditorReducer.reduce(state: state, action: .deleteItem(itemId: itemId))

        XCTAssertTrue(result.shouldPushSnapshot)
        XCTAssertTrue(result.state.canonicalTimeline.stickerItems.isEmpty)
    }

    func testDeleteItem_clearsStickerSelection() {
        var state = loadState()
        state = addSticker(to: state).state
        let itemId = state.canonicalTimeline.stickerItems.first!.id

        XCTAssertTrue(state.selection.isStickerSelected)

        let result = EditorReducer.reduce(state: state, action: .deleteItem(itemId: itemId))
        XCTAssertEqual(result.state.selection, .none)
    }

    // MARK: - Move/Trim (generic overlay actions)

    func testMoveItem_worksForSticker() {
        var state = loadState()
        state = addSticker(to: state, startUs: 0).state
        let itemId = state.canonicalTimeline.stickerItems.first!.id

        let result = EditorReducer.reduce(state: state, action: .moveItem(itemId: itemId, newStartUs: 500_000, phase: .ended))

        XCTAssertTrue(result.shouldPushSnapshot)
        XCTAssertEqual(result.state.canonicalTimeline.stickerItems.first?.startUs, 500_000)
    }

    func testTrimItem_worksForSticker() {
        var state = loadState()
        state = addSticker(to: state, durationUs: 2_000_000).state
        let itemId = state.canonicalTimeline.stickerItems.first!.id

        let result = EditorReducer.reduce(state: state, action: .trimItem(itemId: itemId, newDurationUs: 1_000_000, phase: .ended))

        XCTAssertTrue(result.shouldPushSnapshot)
        XCTAssertEqual(result.state.canonicalTimeline.stickerItems.first?.durationUs, 1_000_000)
    }

    // MARK: - Drag Position

    func testDragOverlayPosition_worksForSticker() {
        var state = loadState()
        state = addSticker(to: state).state
        let itemId = state.canonicalTimeline.stickerItems.first!.id

        // .began — no snapshot
        let beganResult = EditorReducer.reduce(state: state, action: .dragOverlayPosition(itemId: itemId, centerX: 0.5, centerY: 0.5, phase: .began))
        XCTAssertFalse(beganResult.shouldPushSnapshot)

        // .ended — pushes snapshot
        let endedResult = EditorReducer.reduce(state: state, action: .dragOverlayPosition(itemId: itemId, centerX: 0.3, centerY: 0.7, phase: .ended))
        XCTAssertTrue(endedResult.shouldPushSnapshot)

        let payload = endedResult.state.canonicalTimeline.stickerPayload(for: itemId)
        XCTAssertEqual(payload?.centerX, 0.3)
        XCTAssertEqual(payload?.centerY, 0.7)
    }

    func testDragOverlayPosition_clampsSticker() {
        var state = loadState()
        state = addSticker(to: state).state
        let itemId = state.canonicalTimeline.stickerItems.first!.id

        let result = EditorReducer.reduce(state: state, action: .dragOverlayPosition(itemId: itemId, centerX: -0.5, centerY: 1.5, phase: .ended))

        let payload = result.state.canonicalTimeline.stickerPayload(for: itemId)
        XCTAssertEqual(payload?.centerX, 0)
        XCTAssertEqual(payload?.centerY, 1)
    }

    func testDragOverlayPosition_stillWorksForText() {
        var state = loadState()
        let textResult = EditorReducer.reduce(
            state: state,
            action: .addTextOverlay(text: "Hello", fontSize: 32, colorHex: "#FFFFFF", fontFamily: nil, startUs: 0, durationUs: 2_000_000)
        )
        state = textResult.state
        let itemId = state.canonicalTimeline.textItems.first!.id

        let result = EditorReducer.reduce(state: state, action: .dragOverlayPosition(itemId: itemId, centerX: 0.2, centerY: 0.8, phase: .ended))

        let payload = result.state.canonicalTimeline.textPayload(for: itemId)
        XCTAssertEqual(payload?.centerX, 0.2)
        XCTAssertEqual(payload?.centerY, 0.8)
    }

    // MARK: - Selection

    func testStickerSelection_disablesFollowMode() {
        var state = loadState()
        state = addSticker(to: state).state
        let itemId = state.canonicalTimeline.stickerItems.first!.id

        let result = EditorReducer.reduce(state: state, action: .select(selection: .sticker(itemId: itemId)))
        XCTAssertEqual(result.state.timelineSceneSelectionMode, .inactive)
    }

    // MARK: - Update Sticker Payload

    func testUpdateStickerPayload_updatesPosition() {
        var state = loadState()
        state = addSticker(to: state).state
        let itemId = state.canonicalTimeline.stickerItems.first!.id

        let newPayload = StickerPayload(stickerId: "heart", centerX: 0.2, centerY: 0.8)
        let result = EditorReducer.reduce(state: state, action: .updateStickerPayload(itemId: itemId, payload: newPayload))

        XCTAssertTrue(result.shouldPushSnapshot)
        let updatedPayload = result.state.canonicalTimeline.stickerPayload(for: itemId)
        XCTAssertEqual(updatedPayload?.stickerId, "heart")
        XCTAssertEqual(updatedPayload?.centerX, 0.2)
        XCTAssertEqual(updatedPayload?.centerY, 0.8)
    }

    // MARK: - Undo/Redo

    func testStickerOverlay_undoRedo() {
        let state = loadState()
        let store = EditorStore()
        store.dispatch(.loadProject(draft: makeDraft(sceneDurations: [3_000_000]), templateFPS: 30, defaultSceneSequence: []))

        // Add sticker
        store.dispatch(.addStickerOverlay(stickerId: "star", startUs: 0, durationUs: 2_000_000))
        XCTAssertEqual(store.state.canonicalTimeline.stickerItems.count, 1)

        // Undo
        store.dispatch(.undo)
        XCTAssertEqual(store.state.canonicalTimeline.stickerItems.count, 0)

        // Redo
        store.dispatch(.redo)
        XCTAssertEqual(store.state.canonicalTimeline.stickerItems.count, 1)
    }

    // MARK: - Mixed Overlays

    func testMixedOverlays_textAndStickerCoexist() {
        var state = loadState()
        state = EditorReducer.reduce(
            state: state,
            action: .addTextOverlay(text: "Hello", fontSize: 32, colorHex: "#FFFFFF", fontFamily: nil, startUs: 0, durationUs: 1_000_000)
        ).state
        state = addSticker(to: state, startUs: 1_000_000, durationUs: 1_000_000).state

        XCTAssertEqual(state.canonicalTimeline.textItems.count, 1)
        XCTAssertEqual(state.canonicalTimeline.stickerItems.count, 1)

        // Both on same overlay track
        let overlayTrack = state.canonicalTimeline.overlayTrack
        XCTAssertNotNil(overlayTrack)
        XCTAssertEqual(overlayTrack?.items.count, 2)
    }
}
