import XCTest
@testable import AnimiApp
@testable import TVECore

/// Regression test for bootstrap overlay track sync.
/// Proves that when a saved project with overlays is reopened,
/// the `configureTimelineUI → syncTimelineSupplementalUI → updateOverlayTrack` path
/// correctly extracts overlay items from CanonicalTimeline for the timeline UI.
///
/// Uses the production extraction helper: EditorViewController.extractOverlayLaneItems(from:).
final class BootstrapOverlayTrackSyncTests: XCTestCase {

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
    /// must produce correct text lane items through the production extraction path.
    func testBootstrap_savedProjectWithTextOverlay_extractsCorrectly() {
        let timeline = makeSavedProjectTimeline()
        let (textItems, _) = EditorViewController.extractOverlayLaneItems(from: timeline)

        XCTAssertEqual(textItems.count, 1, "Bootstrap must find 1 text overlay from saved project")
        XCTAssertEqual(textItems[0].label, "Welcome Back")
        XCTAssertEqual(textItems[0].startUs, 500_000)
        XCTAssertEqual(textItems[0].durationUs, 2_000_000)
    }

    /// Simulates reopening a saved project: CanonicalTimeline with overlays
    /// must produce correct sticker lane items through the production extraction path.
    func testBootstrap_savedProjectWithStickerOverlay_extractsCorrectly() {
        let timeline = makeSavedProjectTimeline()
        let (_, stickerItems) = EditorViewController.extractOverlayLaneItems(from: timeline)

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

        let (textItems, stickerItems) = EditorViewController.extractOverlayLaneItems(from: timeline)
        XCTAssertTrue(textItems.isEmpty)
        XCTAssertTrue(stickerItems.isEmpty)
    }

    /// Bootstrap extraction feeds into TimelineView and items actually arrive in lanes.
    /// This is the full bootstrap → UI path proof.
    func testBootstrap_overlaysReachTimelineViewLanes() {
        let timeline = makeSavedProjectTimeline()
        let (textItems, stickerItems) = EditorViewController.extractOverlayLaneItems(from: timeline)

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

        let (textItems, _) = EditorViewController.extractOverlayLaneItems(from: timeline)
        XCTAssertEqual(textItems.count, 3, "All 3 text overlays must be extracted at bootstrap")
        XCTAssertEqual(textItems[0].label, "Overlay 0")
        XCTAssertEqual(textItems[1].label, "Overlay 1")
        XCTAssertEqual(textItems[2].label, "Overlay 2")
    }

    // MARK: - Row Count & Height Proofs

    /// 3 text overlays → lane height 88 (3 * 28 + 4).
    func testBootstrap_3textOverlays_laneHeight88() {
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
                text: "T\(i)", fontSize: 32, colorHex: "#FFF", centerX: 0.5, centerY: 0.5
            ))
            overlayTrack.items.append(TimelineItem(
                payloadId: pid, kind: .text,
                startUs: TimeUs(i) * 2_000_000, durationUs: 1_500_000
            ))
        }
        timeline.tracks.append(overlayTrack)

        let (textItems, _) = EditorViewController.extractOverlayLaneItems(from: timeline)

        let tv = TimelineView(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        tv.layoutIfNeeded()
        tv.setTextOverlayItems(textItems, selectedItemId: nil)
        tv.layoutIfNeeded()

        let tl = findLane("textOverlayLane", in: tv)!
        let h = findHeightConstraint(for: tl)
        XCTAssertEqual(h?.constant, 88, "3 text items → height 88 (3 * 28 + 4)")
    }

    /// 2 sticker overlays → lane height 60 (2 * 28 + 4).
    func testBootstrap_2stickerOverlays_laneHeight60() {
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 10_000_000)
        )

        var overlayTrack = Track(kind: .overlay)
        for i in 0..<2 {
            let pid = UUID()
            timeline.payloads[pid] = .sticker(StickerPayload(
                stickerId: "s\(i)", centerX: 0.5, centerY: 0.5
            ))
            overlayTrack.items.append(TimelineItem(
                payloadId: pid, kind: .sticker,
                startUs: TimeUs(i) * 2_000_000, durationUs: 1_500_000
            ))
        }
        timeline.tracks.append(overlayTrack)

        let (_, stickerItems) = EditorViewController.extractOverlayLaneItems(from: timeline)

        let tv = TimelineView(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        tv.layoutIfNeeded()
        tv.setStickerOverlayItems(stickerItems, selectedItemId: nil)
        tv.layoutIfNeeded()

        let sl = findLane("stickerOverlayLane", in: tv)!
        let h = findHeightConstraint(for: sl)
        XCTAssertEqual(h?.constant, 60, "2 sticker items → height 60 (2 * 28 + 4)")
    }

    /// 3 non-overlapping text items → lane height 88, not 32.
    func testBootstrap_nonOverlapping_stillSeparateRows() {
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 10_000_000)
        )

        var overlayTrack = Track(kind: .overlay)
        // 3 sequential non-overlapping text items
        for i in 0..<3 {
            let pid = UUID()
            timeline.payloads[pid] = .text(TextPayload(
                text: "Seq\(i)", fontSize: 32, colorHex: "#FFF", centerX: 0.5, centerY: 0.5
            ))
            overlayTrack.items.append(TimelineItem(
                payloadId: pid, kind: .text,
                startUs: TimeUs(i) * 2_000_000, durationUs: 1_000_000
            ))
        }
        timeline.tracks.append(overlayTrack)

        let (textItems, _) = EditorViewController.extractOverlayLaneItems(from: timeline)

        let tv = TimelineView(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        tv.layoutIfNeeded()
        tv.setTextOverlayItems(textItems, selectedItemId: nil)
        tv.layoutIfNeeded()

        let tl = findLane("textOverlayLane", in: tv)!
        let h = findHeightConstraint(for: tl)
        XCTAssertEqual(h?.constant, 88,
                       "3 non-overlapping items → height 88 (3 * 28 + 4), NOT 32 — each item gets its own row")
    }

    // MARK: - Ordering Contract

    /// Same startUs → extraction preserves overlay track insertion order (stable tie-break).
    func testExtraction_sameStartUs_preservesOverlayTrackOrder() {
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 10_000_000)
        )

        var overlayTrack = Track(kind: .overlay)
        // 3 text items all at startUs=0 — insertion order must be preserved
        let labels = ["First", "Second", "Third"]
        for label in labels {
            let pid = UUID()
            timeline.payloads[pid] = .text(TextPayload(
                text: label, fontSize: 32, colorHex: "#FFF", centerX: 0.5, centerY: 0.5
            ))
            overlayTrack.items.append(TimelineItem(
                payloadId: pid, kind: .text,
                startUs: 0, durationUs: 1_000_000
            ))
        }
        timeline.tracks.append(overlayTrack)

        let (textItems, _) = EditorViewController.extractOverlayLaneItems(from: timeline)
        XCTAssertEqual(textItems.count, 3)
        XCTAssertEqual(textItems[0].label, "First")
        XCTAssertEqual(textItems[1].label, "Second")
        XCTAssertEqual(textItems[2].label, "Third")
    }

    // MARK: - Bootstrap Path Proof

    /// Proves the real bootstrap path: extractOverlayLaneItems → setTextOverlayItems / setStickerOverlayItems.
    /// This is exactly what EditorViewController.updateOverlayTrack(state:) does, which is called by
    /// configureTimelineUI → syncTimelineSupplementalUI → updateOverlayTrack.
    /// The test exercises the same two production methods in the same order.
    func testBootstrapPath_extractionThroughTimelineView_fullChain() {
        // Build a saved project with 2 text + 2 sticker overlays
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 10_000_000)
        )

        var overlayTrack = Track(kind: .overlay)
        for i in 0..<2 {
            let pid = UUID()
            timeline.payloads[pid] = .text(TextPayload(
                text: "Text\(i)", fontSize: 32, colorHex: "#FFF", centerX: 0.5, centerY: 0.5
            ))
            overlayTrack.items.append(TimelineItem(
                payloadId: pid, kind: .text,
                startUs: TimeUs(i) * 2_000_000, durationUs: 1_500_000
            ))
        }
        for i in 0..<2 {
            let pid = UUID()
            timeline.payloads[pid] = .sticker(StickerPayload(
                stickerId: "s\(i)", centerX: 0.5, centerY: 0.5
            ))
            overlayTrack.items.append(TimelineItem(
                payloadId: pid, kind: .sticker,
                startUs: TimeUs(i) * 3_000_000, durationUs: 2_000_000
            ))
        }
        timeline.tracks.append(overlayTrack)

        // Step 1: Production extraction (same as updateOverlayTrack line 1328)
        let (textItems, stickerItems) = EditorViewController.extractOverlayLaneItems(from: timeline)

        // Step 2: Feed into TimelineView (same as updateOverlayTrack lines 1333-1334)
        let tv = TimelineView(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        tv.layoutIfNeeded()
        tv.setTextOverlayItems(textItems, selectedItemId: nil)
        tv.setStickerOverlayItems(stickerItems, selectedItemId: nil)
        tv.layoutIfNeeded()

        // Verify: lanes visible
        let textLane = findLane("textOverlayLane", in: tv)!
        let stickerLane = findLane("stickerOverlayLane", in: tv)!
        XCTAssertFalse(textLane.isHidden, "Text lane visible after bootstrap")
        XCTAssertFalse(stickerLane.isHidden, "Sticker lane visible after bootstrap")

        // Verify: lane heights match 1-item-per-row contract
        let textH = findHeightConstraint(for: textLane)
        let stickerH = findHeightConstraint(for: stickerLane)
        XCTAssertEqual(textH?.constant, 60, "2 text items → height 60 (2 * 28 + 4)")
        XCTAssertEqual(stickerH?.constant, 60, "2 sticker items → height 60 (2 * 28 + 4)")

        // Verify: extraction order is sorted by startUs
        XCTAssertEqual(textItems[0].label, "Text0")
        XCTAssertEqual(textItems[1].label, "Text1")
        XCTAssertEqual(stickerItems[0].label, "s0")
        XCTAssertEqual(stickerItems[1].label, "s1")
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

    private func findHeightConstraint(for view: UIView) -> NSLayoutConstraint? {
        if let c = view.constraints.first(where: {
            $0.firstAttribute == .height && $0.firstItem === view && $0.secondItem == nil
        }) { return c }
        return view.superview?.constraints.first {
            $0.firstAttribute == .height && ($0.firstItem as AnyObject) === view && $0.secondItem == nil
        }
    }
}
