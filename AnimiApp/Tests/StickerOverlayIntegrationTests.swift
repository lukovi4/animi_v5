import XCTest
import TVECore
@testable import AnimiApp

/// Integration tests for sticker overlay pipeline (PR10).
/// Covers resolution, export, and mixed overlays.
@MainActor
final class StickerOverlayIntegrationTests: XCTestCase {

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

    // MARK: - Resolution

    func testResolveStickerOverlays_withinRange() {
        var timeline = CanonicalTimeline.empty()
        let scenePayloadId = UUID()
        timeline.payloads[scenePayloadId] = .scene(ScenePayload(sceneTypeId: "scene_0"))
        timeline.tracks[0].items.append(TimelineItem(payloadId: scenePayloadId, kind: .scene, startUs: nil, durationUs: 5_000_000))

        // Add overlay track with sticker
        let stickerPayloadId = UUID()
        timeline.payloads[stickerPayloadId] = .sticker(StickerPayload(stickerId: "star", centerX: 0.3, centerY: 0.7))
        let stickerItem = TimelineItem(payloadId: stickerPayloadId, kind: .sticker, startUs: 1_000_000, durationUs: 2_000_000)
        let overlayTrack = Track(kind: .overlay, items: [stickerItem])
        timeline.tracks.append(overlayTrack)

        let provider = TestStickerProvider()

        // Within range (1.5s)
        let visible = OverlayResolver.resolve(from: timeline, at: 1_500_000, stickerProvider: provider)
            .filter { $0.kind == .sticker }
        XCTAssertEqual(visible.count, 1)
        if case .sticker(let stickerId, _) = visible.first?.content {
            XCTAssertEqual(stickerId, "star")
        } else {
            XCTFail("Expected .sticker content")
        }
        XCTAssertEqual(visible.first?.presentation.centerX, 0.3)
        XCTAssertEqual(visible.first?.presentation.centerY, 0.7)

        // Before range (0.5s)
        let before = OverlayResolver.resolve(from: timeline, at: 500_000, stickerProvider: provider)
            .filter { $0.kind == .sticker }
        XCTAssertTrue(before.isEmpty)

        // After range (3.5s)
        let after = OverlayResolver.resolve(from: timeline, at: 3_500_000, stickerProvider: provider)
            .filter { $0.kind == .sticker }
        XCTAssertTrue(after.isEmpty)
    }

    func testResolveStickerOverlays_mixedWithText() {
        var timeline = CanonicalTimeline.empty()
        let scenePayloadId = UUID()
        timeline.payloads[scenePayloadId] = .scene(ScenePayload(sceneTypeId: "scene_0"))
        timeline.tracks[0].items.append(TimelineItem(payloadId: scenePayloadId, kind: .scene, startUs: nil, durationUs: 5_000_000))

        // Add overlay track with both text and sticker
        let textPayloadId = UUID()
        timeline.payloads[textPayloadId] = .text(TextPayload(text: "Hello"))
        let textItem = TimelineItem(payloadId: textPayloadId, kind: .text, startUs: 0, durationUs: 3_000_000)

        let stickerPayloadId = UUID()
        timeline.payloads[stickerPayloadId] = .sticker(StickerPayload(stickerId: "heart"))
        let stickerItem = TimelineItem(payloadId: stickerPayloadId, kind: .sticker, startUs: 1_000_000, durationUs: 2_000_000)

        let overlayTrack = Track(kind: .overlay, items: [textItem, stickerItem])
        timeline.tracks.append(overlayTrack)

        let provider = TestStickerProvider()

        // At 1.5s: both should be visible
        let allOverlays = OverlayResolver.resolve(from: timeline, at: 1_500_000, stickerProvider: provider)
        let textOverlays = allOverlays.filter { $0.kind == .text }
        let stickerOverlays = allOverlays.filter { $0.kind == .sticker }
        XCTAssertEqual(textOverlays.count, 1)
        XCTAssertEqual(stickerOverlays.count, 1)
    }

    // MARK: - StickerPayload Codable

    func testStickerPayload_codableRoundTrip() throws {
        let original = StickerPayload(stickerId: "fire", centerX: 0.3, centerY: 0.7)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StickerPayload.self, from: data)
        XCTAssertEqual(decoded.stickerId, "fire")
        XCTAssertEqual(decoded.centerX, 0.3)
        XCTAssertEqual(decoded.centerY, 0.7)
    }

    func testTimelinePayload_stickerRoundTrip() throws {
        let original = TimelinePayload.sticker(StickerPayload(stickerId: "star", centerX: 0.1, centerY: 0.9))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TimelinePayload.self, from: data)
        if case .sticker(let sp) = decoded {
            XCTAssertEqual(sp.stickerId, "star")
            XCTAssertEqual(sp.centerX, 0.1)
            XCTAssertEqual(sp.centerY, 0.9)
        } else {
            XCTFail("Expected .sticker payload")
        }
    }
    // MARK: - Production Wiring: OverlayPositionDragView for Stickers

    /// Verifies that OverlayPositionDragView drag callback wired through production path
    /// dispatches .dragOverlayPosition and mutates session state for sticker items.
    func testSelectedStickerOverlay_dragPositionDispatchesThroughProductionOverlayPath() {
        // 1. Create store with sticker overlay
        let store = EditorStore()
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_sticker_drag"))
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 5_000_000))
        draft.canonicalTimeline = timeline
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        // Add sticker via reducer
        store.dispatch(.addStickerOverlay(stickerId: "star", startUs: 1_000_000, durationUs: 2_000_000))

        let itemId = store.state.canonicalTimeline.stickerItems.first!.id
        XCTAssertTrue(store.state.selection.isStickerSelected)

        // 2. Create real OverlayPositionDragView and wire exactly as production does
        let overlay = OverlayPositionDragView()
        overlay.canvasSize = CGSize(width: 1080, height: 1920)
        overlay.canvasToView = CGAffineTransform(scaleX: 0.5, y: 0.5)

        // Wire callback exactly as EditorViewController does
        overlay.onDragPosition = { [weak store] dragItemId, centerX, centerY, phase in
            store?.dispatch(.dragOverlayPosition(itemId: dragItemId, centerX: centerX, centerY: centerY, phase: phase))
        }

        // 3. Set selected sticker item (as EditorViewController.updateOverlayPositionDrag does for .sticker)
        let payload = store.state.canonicalTimeline.stickerPayload(for: itemId)!
        overlay.setSelectedItem(itemId: itemId, centerX: payload.centerX, centerY: payload.centerY)
        XCTAssertNotNil(overlay.selectedItem)
        XCTAssertEqual(overlay.selectedItem?.centerX, 0.5)
        XCTAssertEqual(overlay.selectedItem?.centerY, 0.5)

        // 4. Simulate drag via production callback (as gesture would fire)
        overlay.onDragPosition?(itemId, 0.5, 0.5, .began)
        overlay.onDragPosition?(itemId, 0.2, 0.9, .changed)
        overlay.onDragPosition?(itemId, 0.2, 0.9, .ended)

        // 5. Verify session state changed through production dispatch path
        let updatedPayload = store.state.canonicalTimeline.stickerPayload(for: itemId)
        XCTAssertEqual(updatedPayload?.centerX, 0.2, "centerX should be updated via production drag path")
        XCTAssertEqual(updatedPayload?.centerY, 0.9, "centerY should be updated via production drag path")
        // stickerId must be preserved
        XCTAssertEqual(updatedPayload?.stickerId, "star")
    }

    /// Verifies full sticker lifecycle through EditorStore production dispatch path.
    func testStickerFullLifecycle_addSelectChangeDragDelete() {
        let store = EditorStore()
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_sticker_lifecycle"))
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 5_000_000))
        draft.canonicalTimeline = timeline
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        // 1. Add sticker
        store.dispatch(.addStickerOverlay(stickerId: "fire", startUs: 0, durationUs: 2_000_000))
        XCTAssertEqual(store.state.canonicalTimeline.stickerItems.count, 1)
        let itemId = store.state.canonicalTimeline.stickerItems.first!.id
        XCTAssertTrue(store.state.selection.isStickerSelected)

        // 2. Update sticker (change stickerId)
        store.dispatch(.updateStickerPayload(itemId: itemId, payload: StickerPayload(stickerId: "heart", centerX: 0.3, centerY: 0.7)))
        XCTAssertEqual(store.state.canonicalTimeline.stickerPayload(for: itemId)?.stickerId, "heart")
        XCTAssertEqual(store.state.canonicalTimeline.stickerPayload(for: itemId)?.centerX, 0.3)

        // 3. Drag position
        store.dispatch(.dragOverlayPosition(itemId: itemId, centerX: 0.1, centerY: 0.1, phase: .began))
        store.dispatch(.dragOverlayPosition(itemId: itemId, centerX: 0.1, centerY: 0.1, phase: .ended))
        XCTAssertEqual(store.state.canonicalTimeline.stickerPayload(for: itemId)?.centerX, 0.1)

        // 4. Delete
        store.dispatch(.deleteItem(itemId: itemId))
        XCTAssertEqual(store.state.canonicalTimeline.stickerItems.count, 0)
        XCTAssertEqual(store.state.selection, .none)

        // 5. Undo restores
        store.dispatch(.undo)
        XCTAssertEqual(store.state.canonicalTimeline.stickerItems.count, 1)
    }
}

// MARK: - Test Sticker Provider

private final class TestStickerProvider: StickerProviding {
    func loadFromBundle() throws {}

    func descriptor(for stickerId: String) -> StickerDescriptor? {
        StickerDescriptor(id: stickerId, displayName: stickerId, filename: "\(stickerId).png")
    }

    func resourceURL(for stickerId: String) -> URL? {
        // Return a dummy URL — renderer tests would need real resources
        URL(fileURLWithPath: "/tmp/sticker_\(stickerId).png")
    }

    var allDescriptors: [StickerDescriptor] {
        [
            StickerDescriptor(id: "star", displayName: "Star", filename: "star.png"),
            StickerDescriptor(id: "heart", displayName: "Heart", filename: "heart.png"),
        ]
    }

    var count: Int { 2 }
}
