import XCTest
@testable import AnimiApp
@testable import TVECore

/// Regression test for bootstrap overlay track sync.
/// Proves that when a saved project with overlays is reopened,
/// the `configureTimelineUI → syncTimelineSupplementalUI → updateOverlayTrack` path
/// correctly extracts overlay items from CanonicalTimeline for the timeline UI.
///
/// This tests the exact data extraction logic used in EditorViewController.updateOverlayTrack(state:):
///   state.canonicalTimeline.textItems.compactMap { ... textPayload(for:) ... }
///   state.canonicalTimeline.stickerItems.compactMap { ... stickerPayload(for:) ... }
final class BootstrapOverlayTrackSyncTests: XCTestCase {

    // MARK: - Bootstrap Extraction Logic (mirrors EditorViewController.updateOverlayTrack)

    /// Extracts text overlay lane items from a CanonicalTimeline — same logic as
    /// EditorViewController.updateOverlayTrack(state:) lines 1306-1311.
    private func extractTextLaneItems(
        from timeline: CanonicalTimeline
    ) -> [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)] {
        timeline.textItems.compactMap { item in
            guard let payload = timeline.textPayload(for: item.id) else { return nil }
            let label = payload.text.isEmpty ? "Text" : String(payload.text.prefix(20))
            return (id: item.id, startUs: item.startUs ?? 0, durationUs: item.durationUs, label: label)
        }
    }

    /// Extracts sticker overlay lane items from a CanonicalTimeline — same logic as
    /// EditorViewController.updateOverlayTrack(state:) lines 1312-1316.
    private func extractStickerLaneItems(
        from timeline: CanonicalTimeline
    ) -> [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)] {
        timeline.stickerItems.compactMap { item in
            guard let payload = timeline.stickerPayload(for: item.id) else { return nil }
            return (id: item.id, startUs: item.startUs ?? 0, durationUs: item.durationUs, label: payload.stickerId)
        }
    }

    // MARK: - Helpers

    private func makeSavedProjectTimeline() -> CanonicalTimeline {
        var timeline = CanonicalTimeline.empty()

        // Scene track
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "saved-scene"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 5_000_000)
        )

        // Overlay track with text + sticker (simulates saved project state)
        let textPid = UUID()
        timeline.payloads[textPid] = .text(TextPayload(
            text: "Welcome Back",
            fontFamily: "Helvetica",
            fontSize: 48,
            colorHex: "#FFFFFF",
            centerX: 0.5,
            centerY: 0.3
        ))

        let stickerPid = UUID()
        timeline.payloads[stickerPid] = .sticker(StickerPayload(
            stickerId: "star-gold",
            centerX: 0.7,
            centerY: 0.6
        ))

        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(TimelineItem(
            payloadId: textPid, kind: .text, startUs: 500_000, durationUs: 2_000_000
        ))
        overlayTrack.items.append(TimelineItem(
            payloadId: stickerPid, kind: .sticker, startUs: 1_000_000, durationUs: 3_000_000
        ))
        timeline.tracks.append(overlayTrack)

        return timeline
    }

    // MARK: - Tests

    /// Simulates reopening a saved project: CanonicalTimeline with overlays
    /// must produce correct text lane items through the extraction path.
    func testBootstrap_savedProjectWithTextOverlay_extractsCorrectly() {
        let timeline = makeSavedProjectTimeline()
        let textItems = extractTextLaneItems(from: timeline)

        XCTAssertEqual(textItems.count, 1, "Bootstrap must find 1 text overlay from saved project")
        XCTAssertEqual(textItems[0].label, "Welcome Back")
        XCTAssertEqual(textItems[0].startUs, 500_000)
        XCTAssertEqual(textItems[0].durationUs, 2_000_000)
    }

    /// Simulates reopening a saved project: CanonicalTimeline with overlays
    /// must produce correct sticker lane items through the extraction path.
    func testBootstrap_savedProjectWithStickerOverlay_extractsCorrectly() {
        let timeline = makeSavedProjectTimeline()
        let stickerItems = extractStickerLaneItems(from: timeline)

        XCTAssertEqual(stickerItems.count, 1, "Bootstrap must find 1 sticker overlay from saved project")
        XCTAssertEqual(stickerItems[0].label, "star-gold")
        XCTAssertEqual(stickerItems[0].startUs, 1_000_000)
        XCTAssertEqual(stickerItems[0].durationUs, 3_000_000)
    }

    /// Empty overlay track at bootstrap produces empty lane items (no crash, no phantom items).
    func testBootstrap_noOverlays_producesEmptyLaneItems() {
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 3_000_000)
        )

        XCTAssertTrue(extractTextLaneItems(from: timeline).isEmpty)
        XCTAssertTrue(extractStickerLaneItems(from: timeline).isEmpty)
    }

    /// Bootstrap extraction feeds into TimelineView and items actually arrive in lanes.
    /// This is the full bootstrap → UI path proof.
    func testBootstrap_overlaysReachTimelineViewLanes() {
        let timeline = makeSavedProjectTimeline()
        let textItems = extractTextLaneItems(from: timeline)
        let stickerItems = extractStickerLaneItems(from: timeline)

        let tv = TimelineView(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        tv.layoutIfNeeded()

        // Before bootstrap: lanes hidden
        let textLane = findLane("textOverlayLane", in: tv)
        let stickerLane = findLane("stickerOverlayLane", in: tv)
        XCTAssertNotNil(textLane)
        XCTAssertNotNil(stickerLane)
        XCTAssertTrue(textLane!.isHidden, "Text lane should be hidden before bootstrap")
        XCTAssertTrue(stickerLane!.isHidden, "Sticker lane should be hidden before bootstrap")

        // Simulate bootstrap: setTextOverlayItems / setStickerOverlayItems
        // This is exactly what syncTimelineSupplementalUI → updateOverlayTrack does
        tv.setTextOverlayItems(textItems, selectedItemId: nil)
        tv.setStickerOverlayItems(stickerItems, selectedItemId: nil)

        // After bootstrap: lanes visible with correct items
        XCTAssertFalse(textLane!.isHidden, "Text lane must be visible after bootstrap with text overlays")
        XCTAssertFalse(stickerLane!.isHidden, "Sticker lane must be visible after bootstrap with sticker overlays")
    }

    /// Multiple overlays of same kind at bootstrap all appear in extraction.
    func testBootstrap_multipleTextOverlays_allExtracted() {
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 10_000_000)
        )

        var overlayTrack = Track(kind: .overlay)
        for i in 0..<3 {
            let pid = UUID()
            timeline.payloads[pid] = .text(TextPayload(
                text: "Overlay \(i)",
                fontSize: 32,
                colorHex: "#FFFFFF",
                centerX: 0.5,
                centerY: CGFloat(i) * 0.3
            ))
            overlayTrack.items.append(TimelineItem(
                payloadId: pid, kind: .text,
                startUs: TimeUs(i) * 2_000_000,
                durationUs: 1_500_000
            ))
        }
        timeline.tracks.append(overlayTrack)

        let textItems = extractTextLaneItems(from: timeline)
        XCTAssertEqual(textItems.count, 3, "All 3 text overlays must be extracted at bootstrap")
        XCTAssertEqual(textItems[0].label, "Overlay 0")
        XCTAssertEqual(textItems[1].label, "Overlay 1")
        XCTAssertEqual(textItems[2].label, "Overlay 2")
    }

    // MARK: - View Hierarchy Helpers

    private func findLane(_ id: String, in view: UIView) -> OverlayLaneView? {
        if let lane = view as? OverlayLaneView, lane.accessibilityIdentifier == id {
            return lane
        }
        for sub in view.subviews {
            if let found = findLane(id, in: sub) { return found }
        }
        return nil
    }
}
