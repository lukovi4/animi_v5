import XCTest
import TVECore
@testable import AnimiApp

/// Tests for text overlay reducer logic (PR9).
/// Covers add/delete/update/move/trim/drag + undo/redo + selection.
@MainActor
final class TextOverlayReducerTests: XCTestCase {

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

    private func addText(to state: EditorState, text: String = "Hello", startUs: TimeUs = 0, durationUs: TimeUs = 2_000_000) -> ReducerResult {
        EditorReducer.reduce(
            state: state,
            action: .addTextOverlay(text: text, fontSize: 32, colorHex: "#FFFFFF", fontFamily: nil, startUs: startUs, durationUs: durationUs)
        )
    }

    // MARK: - Add Text Overlay

    func testAddTextOverlay_createsTrackItemPayload() {
        let state = loadState()

        let result = addText(to: state)

        XCTAssertTrue(result.shouldPushSnapshot)

        let timeline = result.state.canonicalTimeline
        XCTAssertNotNil(timeline.overlayTrack, "Overlay track should be created")
        XCTAssertEqual(timeline.textItems.count, 1)

        let item = timeline.textItems.first!
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.startUs, 0)
        XCTAssertEqual(item.durationUs, 2_000_000)

        let payload = timeline.textPayload(for: item.id)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.text, "Hello")
        XCTAssertEqual(payload?.fontSize, 32)
        XCTAssertEqual(payload?.colorHex, "#FFFFFF")
        XCTAssertEqual(payload?.centerX, 0.5)
        XCTAssertEqual(payload?.centerY, 0.5)
    }

    func testAddTextOverlay_selectsNewItem() {
        let state = loadState()
        let result = addText(to: state)

        XCTAssertTrue(result.state.selection.isTextSelected)
        if case .text(let itemId) = result.state.selection {
            XCTAssertEqual(itemId, result.state.canonicalTimeline.textItems.first?.id)
        }
    }

    func testAddTextOverlay_reusesExistingOverlayTrack() {
        var state = loadState()
        state = addText(to: state).state

        // Add second text
        let result = addText(to: state, text: "World", startUs: 1_000_000)

        XCTAssertEqual(result.state.canonicalTimeline.textItems.count, 2)
        // Should still be one overlay track
        let overlayTracks = result.state.canonicalTimeline.tracks.filter { $0.kind == .overlay }
        XCTAssertEqual(overlayTracks.count, 1)
    }

    func testAddTextOverlay_clampsDurationToProjectEnd() {
        let state = loadState(sceneDurations: [3_000_000]) // 3s project

        let result = addText(to: state, startUs: 2_000_000, durationUs: 5_000_000) // would exceed project

        let item = result.state.canonicalTimeline.textItems.first!
        XCTAssertEqual(item.startUs, 2_000_000)
        XCTAssertEqual(item.durationUs, 1_000_000) // Clamped to fit
    }

    func testAddTextOverlay_atProjectEnd_shiftsStartAndKeepsNonZeroDuration() {
        let state = loadState(sceneDurations: [3_000_000]) // 3s project

        // Add at exact project end
        let result = addText(to: state, startUs: 3_000_000, durationUs: 2_000_000)

        let item = result.state.canonicalTimeline.textItems.first!
        let itemStart = item.startUs ?? 0
        XCTAssertGreaterThanOrEqual(item.durationUs, 500_000, "Duration must be at least 0.5s")
        XCTAssertLessThanOrEqual(itemStart + item.durationUs, 3_000_000, "Item must fit within project")
        XCTAssertLessThanOrEqual(itemStart, 2_500_000, "Start must shift left to fit min duration")
    }

    func testAddTextOverlay_shortRemainingDuration_clampsToMinimumVisibleClip() {
        let state = loadState(sceneDurations: [1_000_000]) // 1s project

        // Add near end with large requested duration
        let result = addText(to: state, startUs: 800_000, durationUs: 5_000_000)

        let item = result.state.canonicalTimeline.textItems.first!
        let itemStart = item.startUs ?? 0
        XCTAssertGreaterThanOrEqual(item.durationUs, 500_000, "Duration must be at least 0.5s minimum")
        XCTAssertLessThanOrEqual(itemStart + item.durationUs, 1_000_000, "Item must fit within project")
        // Start should shift left to accommodate min duration
        XCTAssertLessThanOrEqual(itemStart, 500_000)
    }

    func testAddTextOverlay_neverCreatesZeroDurationItem() {
        let state = loadState(sceneDurations: [3_000_000])

        // Try various edge positions
        for startUs: TimeUs in [0, 1_000_000, 2_500_000, 2_999_999, 3_000_000, 5_000_000] {
            let result = addText(to: state, startUs: startUs, durationUs: 2_000_000)
            let item = result.state.canonicalTimeline.textItems.first!
            XCTAssertGreaterThan(item.durationUs, 0, "Duration must never be zero for startUs=\(startUs)")
            XCTAssertGreaterThanOrEqual(item.durationUs, 500_000, "Duration must meet minimum for startUs=\(startUs)")
        }
    }

    // MARK: - Delete Item

    func testDeleteItem_removesItemAndPayload() {
        var state = loadState()
        state = addText(to: state).state

        let itemId = state.canonicalTimeline.textItems.first!.id

        let result = EditorReducer.reduce(state: state, action: .deleteItem(itemId: itemId))

        XCTAssertTrue(result.shouldPushSnapshot)
        XCTAssertTrue(result.state.canonicalTimeline.textItems.isEmpty)
        // Payload should be cleaned up
        let payloadCount = result.state.canonicalTimeline.payloads.values.filter {
            if case .text = $0 { return true }
            return false
        }.count
        XCTAssertEqual(payloadCount, 0)
    }

    func testDeleteItem_clearsSelectionIfSelected() {
        var state = loadState()
        state = addText(to: state).state // Selection is .text(itemId)

        let itemId = state.canonicalTimeline.textItems.first!.id
        XCTAssertTrue(state.selection.isTextSelected)

        let result = EditorReducer.reduce(state: state, action: .deleteItem(itemId: itemId))

        XCTAssertEqual(result.state.selection, .none)
    }

    // MARK: - Update Text Payload

    func testUpdateTextPayload_replacesContent() {
        var state = loadState()
        state = addText(to: state).state

        let itemId = state.canonicalTimeline.textItems.first!.id
        var newPayload = state.canonicalTimeline.textPayload(for: itemId)!
        newPayload.text = "Updated"
        newPayload.fontSize = 48

        let result = EditorReducer.reduce(state: state, action: .updateTextPayload(itemId: itemId, payload: newPayload))

        XCTAssertTrue(result.shouldPushSnapshot)
        let payload = result.state.canonicalTimeline.textPayload(for: itemId)
        XCTAssertEqual(payload?.text, "Updated")
        XCTAssertEqual(payload?.fontSize, 48)
    }

    // MARK: - Move Item

    func testMoveItem_gesturePhases() {
        var state = loadState(sceneDurations: [5_000_000])
        state = addText(to: state, startUs: 0, durationUs: 1_000_000).state

        let itemId = state.canonicalTimeline.textItems.first!.id

        // .began — no snapshot
        let beganResult = EditorReducer.reduce(state: state, action: .moveItem(itemId: itemId, newStartUs: 500_000, phase: .began))
        XCTAssertFalse(beganResult.shouldPushSnapshot)

        // .changed — no snapshot, item moves
        let changedResult = EditorReducer.reduce(state: state, action: .moveItem(itemId: itemId, newStartUs: 1_000_000, phase: .changed))
        XCTAssertFalse(changedResult.shouldPushSnapshot)
        XCTAssertEqual(changedResult.state.canonicalTimeline.textItems.first?.startUs, 1_000_000)

        // .ended — pushes snapshot
        let endedResult = EditorReducer.reduce(state: state, action: .moveItem(itemId: itemId, newStartUs: 2_000_000, phase: .ended))
        XCTAssertTrue(endedResult.shouldPushSnapshot)
        XCTAssertEqual(endedResult.state.canonicalTimeline.textItems.first?.startUs, 2_000_000)
    }

    func testMoveItem_clampsToProjectDuration() {
        var state = loadState(sceneDurations: [3_000_000])
        state = addText(to: state, startUs: 0, durationUs: 1_000_000).state

        let itemId = state.canonicalTimeline.textItems.first!.id

        // Try to move past project end
        let result = EditorReducer.reduce(state: state, action: .moveItem(itemId: itemId, newStartUs: 10_000_000, phase: .ended))

        // Should be clamped to max(0, projectDuration - itemDuration)
        XCTAssertEqual(result.state.canonicalTimeline.textItems.first?.startUs, 2_000_000) // 3s - 1s
    }

    // MARK: - Trim Item

    func testTrimItem_gesturePhases() {
        var state = loadState(sceneDurations: [5_000_000])
        state = addText(to: state, startUs: 0, durationUs: 2_000_000).state

        let itemId = state.canonicalTimeline.textItems.first!.id

        // .ended — pushes snapshot
        let result = EditorReducer.reduce(state: state, action: .trimItem(itemId: itemId, newDurationUs: 3_000_000, phase: .ended))
        XCTAssertTrue(result.shouldPushSnapshot)
        XCTAssertEqual(result.state.canonicalTimeline.textItems.first?.durationUs, 3_000_000)
    }

    func testTrimItem_minDuration() {
        var state = loadState()
        state = addText(to: state, startUs: 0, durationUs: 2_000_000).state

        let itemId = state.canonicalTimeline.textItems.first!.id

        let result = EditorReducer.reduce(state: state, action: .trimItem(itemId: itemId, newDurationUs: 100_000, phase: .ended))

        // Should clamp to 500_000 (0.5s min)
        XCTAssertEqual(result.state.canonicalTimeline.textItems.first?.durationUs, 500_000)
    }

    // MARK: - Drag Text Position

    func testDragTextPosition_gesturePhases() {
        var state = loadState()
        state = addText(to: state).state

        let itemId = state.canonicalTimeline.textItems.first!.id

        // .began — no snapshot
        let beganResult = EditorReducer.reduce(state: state, action: .dragOverlayPosition(itemId: itemId, centerX: 0.5, centerY: 0.5, phase: .began))
        XCTAssertFalse(beganResult.shouldPushSnapshot)

        // .ended — pushes snapshot
        let endedResult = EditorReducer.reduce(state: state, action: .dragOverlayPosition(itemId: itemId, centerX: 0.3, centerY: 0.7, phase: .ended))
        XCTAssertTrue(endedResult.shouldPushSnapshot)

        let payload = endedResult.state.canonicalTimeline.textPayload(for: itemId)
        XCTAssertEqual(payload?.centerX, 0.3)
        XCTAssertEqual(payload?.centerY, 0.7)
    }

    func testDragTextPosition_clampsToUnitRange() {
        var state = loadState()
        state = addText(to: state).state

        let itemId = state.canonicalTimeline.textItems.first!.id

        let result = EditorReducer.reduce(state: state, action: .dragOverlayPosition(itemId: itemId, centerX: -0.5, centerY: 1.5, phase: .ended))

        let payload = result.state.canonicalTimeline.textPayload(for: itemId)
        XCTAssertEqual(payload?.centerX, 0)
        XCTAssertEqual(payload?.centerY, 1)
    }

    // MARK: - Selection

    func testTextSelection_deactivatesFollowMode() {
        var state = loadState()
        state.timelineSceneSelectionMode = .followPlayhead

        let result = EditorReducer.reduce(state: state, action: .select(selection: .text(itemId: UUID())))

        XCTAssertEqual(result.state.timelineSceneSelectionMode, .inactive)
    }

    // MARK: - Shift-Left

    func testShiftLeft_shiftsTextItemsOnProjectShrink() {
        var state = loadState(sceneDurations: [5_000_000])
        state = addText(to: state, startUs: 2_000_000, durationUs: 2_000_000).state

        // Shrink project by trimming scene to 3s
        let sceneId = state.canonicalTimeline.sceneItems.first!.id
        let result = EditorReducer.reduce(
            state: state,
            action: .trimScene(sceneId: sceneId, phase: .ended, newDurationUs: 3_000_000, edge: .trailing)
        )

        // Text item should be shifted left by 2s delta
        let textItem = result.state.canonicalTimeline.textItems.first
        XCTAssertNotNil(textItem)
        XCTAssertEqual(textItem?.startUs, 0) // max(0, 2_000_000 - 2_000_000)
    }

    // MARK: - Undo/Redo

    func testUndoRedo_addTextOverlay() {
        let draft = makeDraft(sceneDurations: [3_000_000])
        let store = EditorStore.create(draft: draft, templateFPS: 30, defaultSceneSequence: [])

        // Add text
        store.dispatch(.addTextOverlay(text: "Test", fontSize: 32, colorHex: "#FFFFFF", fontFamily: nil, startUs: 0, durationUs: 2_000_000))
        XCTAssertEqual(store.state.canonicalTimeline.textItems.count, 1)

        // Undo
        store.dispatch(.undo)
        XCTAssertEqual(store.state.canonicalTimeline.textItems.count, 0)

        // Redo
        store.dispatch(.redo)
        XCTAssertEqual(store.state.canonicalTimeline.textItems.count, 1)
    }

    // MARK: - Transform Text Box (move + boxWidth + fontSize + rotation)

    private func addTextStore() -> (EditorStore, UUID) {
        let draft = makeDraft(sceneDurations: [3_000_000])
        let store = EditorStore.create(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        store.dispatch(.addTextOverlay(text: "Box", fontSize: 32, colorHex: "#FFFFFF", fontFamily: nil, startUs: 0, durationUs: 2_000_000))
        return (store, store.state.canonicalTimeline.textItems.first!.id)
    }

    func testTransformTextBox_endedUpdatesGeometryAndStyle() {
        let (store, itemId) = addTextStore()

        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.3, centerY: 0.7, boxWidth: 0.4, fontSize: 48, rotation: 0.6, phase: .began))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.3, centerY: 0.7, boxWidth: 0.4, fontSize: 48, rotation: 0.6, phase: .changed))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.3, centerY: 0.7, boxWidth: 0.4, fontSize: 48, rotation: 0.6, phase: .ended))

        let p = store.state.canonicalTimeline.textPayload(for: itemId)!
        XCTAssertEqual(p.geometry.centerX, 0.3, accuracy: 1e-6)
        XCTAssertEqual(p.geometry.centerY, 0.7, accuracy: 1e-6)
        XCTAssertEqual(p.geometry.boxWidth, 0.4, accuracy: 1e-6)
        XCTAssertEqual(p.geometry.rotation, 0.6, accuracy: 1e-6)
        XCTAssertEqual(p.style.fontSize, 48, accuracy: 1e-6)
    }

    func testTransformTextBox_oneUndoSnapshotPerGesture() {
        let (store, itemId) = addTextStore()
        let canUndoBefore = store.canUndo

        // One full gesture (began → changed → ended) = one undo step.
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.5, centerY: 0.5, boxWidth: 0.6, fontSize: 32, rotation: 0, phase: .began))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.4, centerY: 0.6, boxWidth: 0.5, fontSize: 40, rotation: 0.2, phase: .changed))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.4, centerY: 0.6, boxWidth: 0.5, fontSize: 40, rotation: 0.2, phase: .ended))

        XCTAssertTrue(canUndoBefore, "Add created an undo step")
        // Undo once reverts the whole gesture back to the post-add baseline.
        store.dispatch(.undo)
        let reverted = store.state.canonicalTimeline.textPayload(for: itemId)!
        XCTAssertEqual(reverted.geometry.centerX, 0.5, accuracy: 1e-6)
        XCTAssertEqual(reverted.geometry.boxWidth, 0.6, accuracy: 1e-6)
        XCTAssertEqual(reverted.geometry.rotation, 0, accuracy: 1e-6)
        XCTAssertEqual(reverted.style.fontSize, 32, accuracy: 1e-6)
    }

    func testTransformTextBox_cancelledRestoresBaseline() {
        let (store, itemId) = addTextStore()

        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.5, centerY: 0.5, boxWidth: 0.6, fontSize: 32, rotation: 0, phase: .began))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.1, centerY: 0.1, boxWidth: 0.2, fontSize: 80, rotation: 1.0, phase: .changed))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.1, centerY: 0.1, boxWidth: 0.2, fontSize: 80, rotation: 1.0, phase: .cancelled))

        let p = store.state.canonicalTimeline.textPayload(for: itemId)!
        XCTAssertEqual(p.geometry.centerX, 0.5, accuracy: 1e-6, "Cancel restores gesture baseline")
        XCTAssertEqual(p.geometry.boxWidth, 0.6, accuracy: 1e-6)
        XCTAssertEqual(p.geometry.rotation, 0, accuracy: 1e-6)
        XCTAssertEqual(p.style.fontSize, 32, accuracy: 1e-6)
    }

    /// Live `.began`/`.changed` no longer route through the store at all (the
    /// Core Animation live layer owns them): they must not mutate the model nor
    /// fire any timeline sync. Only `.ended` commits, once.
    func testTransformTextBox_livePhasesDoNotSync_endedCommitsOnce() {
        let (store, itemId) = addTextStore()

        var fullSyncCount = 0
        var trimPreviewCount = 0
        store.onTimelineChanged = { _ in fullSyncCount += 1 }
        store.onTimelinePreviewChanged = { _ in trimPreviewCount += 1 }

        let baseline = store.state.canonicalTimeline.textPayload(for: itemId)!

        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.5, centerY: 0.5, boxWidth: 0.6, fontSize: 32, rotation: 0, phase: .began))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.45, centerY: 0.55, boxWidth: 0.55, fontSize: 36, rotation: 0.1, phase: .changed))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.4, centerY: 0.6, boxWidth: 0.5, fontSize: 40, rotation: 0.2, phase: .changed))

        XCTAssertEqual(fullSyncCount, 0, "Live phases must not fire the full-timeline sync")
        XCTAssertEqual(trimPreviewCount, 0, "Live phases must not reuse the trim-preview path")
        let duringLive = store.state.canonicalTimeline.textPayload(for: itemId)!
        XCTAssertEqual(duringLive.geometry.centerX, baseline.geometry.centerX, accuracy: 1e-9, "model unchanged during live phases")

        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.4, centerY: 0.6, boxWidth: 0.5, fontSize: 40, rotation: 0.2, phase: .ended))
        XCTAssertEqual(fullSyncCount, 1, "Commit performs the full timeline sync once")
        let committed = store.state.canonicalTimeline.textPayload(for: itemId)!
        XCTAssertEqual(committed.geometry.centerX, 0.4, accuracy: 1e-6, "commit persists the final center")
        XCTAssertEqual(committed.geometry.centerY, 0.6, accuracy: 1e-6)
    }

    func testTransformTextBox_allowsOffCanvasCenter_notClampedTo01() {
        let (store, itemId) = addTextStore()
        // Drag the center well past the canvas edge; reducer must allow off-canvas
        // placement (clipping is visual), bounded only by the off-canvas bound.
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 1.3, centerY: -0.2, boxWidth: 0.6, fontSize: 32, rotation: 0, phase: .began))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 1.3, centerY: -0.2, boxWidth: 0.6, fontSize: 32, rotation: 0, phase: .ended))

        let p = store.state.canonicalTimeline.textPayload(for: itemId)!
        XCTAssertEqual(p.geometry.centerX, 1.3, accuracy: 1e-6, "center > 1 allowed off-canvas")
        XCTAssertEqual(p.geometry.centerY, -0.2, accuracy: 1e-6, "center < 0 allowed off-canvas")
    }
}
