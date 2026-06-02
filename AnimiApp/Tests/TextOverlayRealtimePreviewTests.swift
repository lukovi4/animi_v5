import XCTest
import TVECore
@testable import AnimiApp

/// Regression for the live text-box transform architecture AFTER the realtime
/// engine path was removed. The hard boundary: live `.began`/`.changed` must NOT
/// mutate the persisted model or fire the heavy `onTimelineChanged` sync — the
/// transient Core Animation live layer owns the gesture. Only `.ended` commits.
@MainActor
final class TextOverlayRealtimePreviewTests: XCTestCase {

    private func makeDraft() -> ProjectDraft {
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "scene_0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 5_000_000)
        )
        draft.canonicalTimeline = timeline
        return draft
    }

    private func addTextStore() -> (EditorStore, UUID) {
        let store = EditorStore.create(draft: makeDraft(), templateFPS: 30, defaultSceneSequence: [])
        store.dispatch(.addTextOverlay(text: "Live", fontSize: 32, colorHex: "#FFFFFF", fontFamily: nil, startUs: 0, durationUs: 2_000_000))
        return (store, store.state.canonicalTimeline.textItems.first!.id)
    }

    private func textCenter(_ store: EditorStore, _ itemId: UUID) -> (CGFloat, CGFloat) {
        let p = store.state.canonicalTimeline.textPayload(for: itemId)!
        return (p.geometry.centerX, p.geometry.centerY)
    }

    /// Live `.began`/`.changed` must not mutate the model and must not fire the
    /// full-timeline sync — the live layer handles them entirely off-store.
    func testLivePhases_doNotMutateModel_norFireTimelineSync() {
        let (store, itemId) = addTextStore()
        let (baseX, baseY) = textCenter(store, itemId)

        var timelineSyncCount = 0
        store.onTimelineChanged = { _ in timelineSyncCount += 1 }

        store.dispatch(.transformTextBox(itemId: itemId, centerX: baseX, centerY: baseY, boxWidth: 0.6, fontSize: 32, rotation: 0, phase: .began))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.2, centerY: 0.8, boxWidth: 0.6, fontSize: 40, rotation: 0.3, phase: .changed))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.1, centerY: 0.9, boxWidth: 0.6, fontSize: 50, rotation: 0.5, phase: .changed))

        XCTAssertEqual(timelineSyncCount, 0, "Live .began/.changed must not fire the full-timeline sync")
        let (x, y) = textCenter(store, itemId)
        XCTAssertEqual(x, baseX, accuracy: 1e-9, "model center must be unchanged during live phases")
        XCTAssertEqual(y, baseY, accuracy: 1e-9)
    }

    /// `.ended` commits the final geometry/style once and fires one sync.
    func testEnded_commitsOnce_withFinalGeometry() {
        let (store, itemId) = addTextStore()

        var timelineSyncCount = 0
        store.onTimelineChanged = { _ in timelineSyncCount += 1 }

        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.5, centerY: 0.5, boxWidth: 0.6, fontSize: 32, rotation: 0, phase: .began))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.3, centerY: 0.6, boxWidth: 0.7, fontSize: 44, rotation: 0.4, phase: .changed))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.25, centerY: 0.65, boxWidth: 0.7, fontSize: 44, rotation: 0.4, phase: .ended))

        XCTAssertEqual(timelineSyncCount, 1, "commit fires the full sync exactly once")
        let payload = store.state.canonicalTimeline.textPayload(for: itemId)!
        XCTAssertEqual(payload.geometry.centerX, 0.25, accuracy: 1e-6)
        XCTAssertEqual(payload.geometry.centerY, 0.65, accuracy: 1e-6)
        XCTAssertEqual(payload.geometry.boxWidth, 0.7, accuracy: 1e-6)
        XCTAssertEqual(payload.style.fontSize, 44, accuracy: 1e-6)
        XCTAssertEqual(payload.geometry.rotation, 0.4, accuracy: 1e-6)
    }

    /// `.cancelled` after live changes leaves the model at the pre-gesture
    /// baseline and pushes no undo snapshot.
    func testCancelled_restoresBaseline_noModelChange_noSnapshot() {
        let (store, itemId) = addTextStore()
        let (baseX, baseY) = textCenter(store, itemId)
        let canUndoBefore = store.canUndo

        store.dispatch(.transformTextBox(itemId: itemId, centerX: baseX, centerY: baseY, boxWidth: 0.6, fontSize: 32, rotation: 0, phase: .began))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.1, centerY: 0.1, boxWidth: 0.6, fontSize: 80, rotation: 1.0, phase: .changed))
        store.dispatch(.transformTextBox(itemId: itemId, centerX: 0.1, centerY: 0.1, boxWidth: 0.6, fontSize: 80, rotation: 1.0, phase: .cancelled))

        let (x, y) = textCenter(store, itemId)
        XCTAssertEqual(x, baseX, accuracy: 1e-9, "cancel must not mutate the model")
        XCTAssertEqual(y, baseY, accuracy: 1e-9)
        XCTAssertEqual(store.canUndo, canUndoBefore, "cancel must not push an undo snapshot")
    }
}
