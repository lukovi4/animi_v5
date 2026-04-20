import XCTest
@testable import AnimiApp

/// Behavior tests for TimelineView overlay lane split (text + sticker).
/// Verifies lane visibility, dynamic height, selection routing, and zoom relayout
/// through TimelineView's public API + accessibility-driven view inspection.
final class TimelineViewOverlayLaneBehaviorTests: XCTestCase {

    // MARK: - Helpers

    private func makeTimelineView(width: CGFloat = 375, height: CGFloat = 200) -> TimelineView {
        let tv = TimelineView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        // Force initial layout so constraints activate
        tv.layoutIfNeeded()
        return tv
    }

    private func findLane(_ id: String, in view: UIView) -> OverlayLaneView? {
        if let lane = view as? OverlayLaneView, lane.accessibilityIdentifier == id {
            return lane
        }
        for sub in view.subviews {
            if let found = findLane(id, in: sub) { return found }
        }
        return nil
    }

    private func textLane(in tv: TimelineView) -> OverlayLaneView? {
        findLane("textOverlayLane", in: tv)
    }

    private func stickerLane(in tv: TimelineView) -> OverlayLaneView? {
        findLane("stickerOverlayLane", in: tv)
    }

    // MARK: - Lane Visibility

    func testTextLane_hiddenWhenEmpty_visibleWithItems() {
        let tv = makeTimelineView()
        let tl = textLane(in: tv)
        XCTAssertNotNil(tl, "Text lane must exist in view hierarchy")
        XCTAssertTrue(tl!.isHidden, "Text lane should be hidden when no items set")

        tv.setTextOverlayItems([
            (id: UUID(), startUs: 0, durationUs: 1_000_000, label: "Hi")
        ], selectedItemId: nil)

        XCTAssertFalse(tl!.isHidden, "Text lane should be visible after setting items")
    }

    func testStickerLane_hiddenWhenEmpty_visibleWithItems() {
        let tv = makeTimelineView()
        let sl = stickerLane(in: tv)
        XCTAssertNotNil(sl, "Sticker lane must exist in view hierarchy")
        XCTAssertTrue(sl!.isHidden, "Sticker lane should be hidden when no items set")

        tv.setStickerOverlayItems([
            (id: UUID(), startUs: 0, durationUs: 1_000_000, label: "star")
        ], selectedItemId: nil)

        XCTAssertFalse(sl!.isHidden, "Sticker lane should be visible after setting items")
    }

    func testLane_becomesHiddenWhenItemsCleared() {
        let tv = makeTimelineView()
        let tl = textLane(in: tv)!

        tv.setTextOverlayItems([
            (id: UUID(), startUs: 0, durationUs: 1_000_000, label: "A")
        ], selectedItemId: nil)
        XCTAssertFalse(tl.isHidden)

        tv.setTextOverlayItems([], selectedItemId: nil)
        XCTAssertTrue(tl.isHidden, "Lane should hide when items are cleared")
    }

    // MARK: - Dynamic Height

    func testSetTextOverlayItems_3overlapping_heightIs88() {
        let tv = makeTimelineView()

        // 3 fully overlapping items → 3 rows → height = 3 * 28 + 4 = 88
        tv.setTextOverlayItems([
            (id: UUID(), startUs: 0, durationUs: 2_000_000, label: "A"),
            (id: UUID(), startUs: 500_000, durationUs: 2_000_000, label: "B"),
            (id: UUID(), startUs: 1_000_000, durationUs: 2_000_000, label: "C"),
        ], selectedItemId: nil)

        tv.layoutIfNeeded()

        let tl = textLane(in: tv)!
        let laneHeight = findHeightConstraint(for: tl)
        XCTAssertEqual(laneHeight?.constant, 88,
                       "3 overlapping items should produce height 88 (3 * 28 + 4)")
    }

    func testSetTextOverlayItems_2nonOverlapping_heightIs60() {
        let tv = makeTimelineView()

        // 2 items → 2 rows → height = 2 * 28 + 4 = 60 (1 item = 1 row, no packing)
        tv.setTextOverlayItems([
            (id: UUID(), startUs: 0, durationUs: 1_000_000, label: "A"),
            (id: UUID(), startUs: 1_000_000, durationUs: 1_000_000, label: "B"),
        ], selectedItemId: nil)

        tv.layoutIfNeeded()

        let tl = textLane(in: tv)!
        let laneHeight = findHeightConstraint(for: tl)
        XCTAssertEqual(laneHeight?.constant, 60,
                       "2 items should produce height 60 (2 * 28 + 4) — each item gets its own row")
    }

    func testSetStickerOverlayItems_2nonOverlapping_heightIs60() {
        let tv = makeTimelineView()

        // 2 sequential stickers → 2 rows → height = 2 * 28 + 4 = 60
        tv.setStickerOverlayItems([
            (id: UUID(), startUs: 0, durationUs: 1_000_000, label: "star"),
            (id: UUID(), startUs: 1_000_000, durationUs: 1_000_000, label: "heart"),
        ], selectedItemId: nil)

        tv.layoutIfNeeded()

        let sl = stickerLane(in: tv)!
        let laneHeight = findHeightConstraint(for: sl)
        XCTAssertEqual(laneHeight?.constant, 60,
                       "2 sticker items should produce height 60 (2 * 28 + 4) — each item gets its own row")
    }

    // MARK: - Selection Routing

    func testSetSelection_text_highlightsOnlyTextLane() {
        let tv = makeTimelineView()
        let textId = UUID()
        let stickerId = UUID()

        tv.setTextOverlayItems([
            (id: textId, startUs: 0, durationUs: 1_000_000, label: "A")
        ], selectedItemId: nil)
        tv.setStickerOverlayItems([
            (id: stickerId, startUs: 0, durationUs: 1_000_000, label: "star")
        ], selectedItemId: nil)

        tv.setSelection(.text(itemId: textId))

        // Verify via clip accessibility identifiers
        let textClip = findClip("overlayClip_\(textId.uuidString)", in: tv)
        let stickerClip = findClip("overlayClip_\(stickerId.uuidString)", in: tv)

        XCTAssertNotNil(textClip, "Text clip should exist")
        XCTAssertEqual(textClip?.layer.borderWidth, 2, "Text clip should be selected (border = 2)")
        if let stickerClip {
            XCTAssertEqual(stickerClip.layer.borderWidth, 0, "Sticker clip should not be selected")
        }
    }

    func testSetSelection_sticker_highlightsOnlyStickerLane() {
        let tv = makeTimelineView()
        let textId = UUID()
        let stickerId = UUID()

        tv.setTextOverlayItems([
            (id: textId, startUs: 0, durationUs: 1_000_000, label: "A")
        ], selectedItemId: nil)
        tv.setStickerOverlayItems([
            (id: stickerId, startUs: 0, durationUs: 1_000_000, label: "star")
        ], selectedItemId: nil)

        tv.setSelection(.sticker(itemId: stickerId))

        let textClip = findClip("overlayClip_\(textId.uuidString)", in: tv)
        let stickerClip = findClip("overlayClip_\(stickerId.uuidString)", in: tv)

        XCTAssertNotNil(stickerClip, "Sticker clip should exist")
        XCTAssertEqual(stickerClip?.layer.borderWidth, 2, "Sticker clip should be selected")
        if let textClip {
            XCTAssertEqual(textClip.layer.borderWidth, 0, "Text clip should not be selected")
        }
    }

    func testSetSelection_scene_clearsBothOverlayLanes() {
        let tv = makeTimelineView()
        let textId = UUID()
        let stickerId = UUID()

        tv.setTextOverlayItems([
            (id: textId, startUs: 0, durationUs: 1_000_000, label: "A")
        ], selectedItemId: textId)
        tv.setStickerOverlayItems([
            (id: stickerId, startUs: 0, durationUs: 1_000_000, label: "star")
        ], selectedItemId: nil)

        // Select a scene → should clear both overlay selections
        tv.setSelection(.scene(id: UUID()))

        let textClip = findClip("overlayClip_\(textId.uuidString)", in: tv)
        let stickerClip = findClip("overlayClip_\(stickerId.uuidString)", in: tv)

        if let textClip {
            XCTAssertEqual(textClip.layer.borderWidth, 0, "Text clip should be deselected after scene selection")
        }
        if let stickerClip {
            XCTAssertEqual(stickerClip.layer.borderWidth, 0, "Sticker clip should be deselected after scene selection")
        }
    }

    // MARK: - Zoom Relayout

    func testSetTextOverlayItems_overlappingZoomChange() {
        let tv = makeTimelineView(width: 400)
        let itemId = UUID()

        // Configure timeline with a scene so pxPerSecond is meaningful
        tv.configure(
            scenes: [SceneDraft(durationUs: 5_000_000)],
            boundaries: [],
            templateFPS: 30
        )

        tv.setTextOverlayItems([
            (id: itemId, startUs: 1_000_000, durationUs: 2_000_000, label: "ZoomTest")
        ], selectedItemId: nil)

        tv.layoutIfNeeded()

        let clip = findClip("overlayClip_\(itemId.uuidString)", in: tv)
        XCTAssertNotNil(clip, "Clip should exist after setting items")

        let widthBefore = clip!.frame.width

        // Simulate zoom by restoring state at higher zoom
        // (restoreState sets currentZoom and calls updateContentSize)
        tv.restoreState(compressedFrame: 0, zoom: 2.0, mapper: .empty)
        tv.layoutIfNeeded()

        let widthAfter = clip!.frame.width
        XCTAssertGreaterThan(widthAfter, widthBefore, "Clip width should increase after zoom in")
    }

    // MARK: - Private Helpers

    /// Finds the height constraint for a view (checks both self.constraints and superview.constraints).
    private func findHeightConstraint(for view: UIView) -> NSLayoutConstraint? {
        // Height constraints owned by the view itself
        if let c = view.constraints.first(where: {
            $0.firstAttribute == .height && $0.firstItem === view && $0.secondItem == nil
        }) { return c }
        // Height constraints owned by superview
        return view.superview?.constraints.first {
            $0.firstAttribute == .height && ($0.firstItem as AnyObject) === view && $0.secondItem == nil
        }
    }

    private func findClip(_ accessibilityId: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == accessibilityId {
            return view
        }
        for sub in view.subviews {
            if let found = findClip(accessibilityId, in: sub) { return found }
        }
        return nil
    }

    // MARK: - Scroll Arbitration (require(toFail:) proof)

    func testScrollArbitration_textLane_requireToFailWired() {
        let tv = makeTimelineView()
        let ids = [UUID(), UUID()]

        tv.setTextOverlayItems([
            (id: ids[0], startUs: 0, durationUs: 1_000_000, label: "A"),
            (id: ids[1], startUs: 1_000_000, durationUs: 1_000_000, label: "B"),
        ], selectedItemId: nil)

        // 2 clips × 2 gestures (trimPan + moveLongPress) = 4 deps
        XCTAssertEqual(tv.overlayScrollFailureDeps.count, 4,
                       "Each text overlay clip must register 2 gestures as scroll failure deps")

        // Verify each recorded gesture is attached to an OverlayClipView
        for dep in tv.overlayScrollFailureDeps {
            XCTAssertTrue(dep.view is OverlayClipView,
                          "Failure dep gesture must be attached to an OverlayClipView")
        }
    }

    func testScrollArbitration_stickerLane_requireToFailWired() {
        let tv = makeTimelineView()
        let stickerId = UUID()

        tv.setStickerOverlayItems([
            (id: stickerId, startUs: 0, durationUs: 1_000_000, label: "star")
        ], selectedItemId: nil)

        // 1 clip × 2 gestures = 2 deps
        XCTAssertEqual(tv.overlayScrollFailureDeps.count, 2,
                       "Sticker overlay clip must register 2 gestures as scroll failure deps")
        XCTAssertTrue(tv.overlayScrollFailureDeps[0].view is OverlayClipView)
        XCTAssertTrue(tv.overlayScrollFailureDeps[1].view is OverlayClipView)
    }

    func testScrollArbitration_notDuplicatedOnReuse() {
        let tv = makeTimelineView()
        let id = UUID()

        tv.setTextOverlayItems([
            (id: id, startUs: 0, durationUs: 1_000_000, label: "A")
        ], selectedItemId: nil)
        // 1 clip × 2 gestures = 2 deps
        XCTAssertEqual(tv.overlayScrollFailureDeps.count, 2)

        // Apply same snapshot again — clip is reused, onClipCreated should NOT fire
        tv.setTextOverlayItems([
            (id: id, startUs: 0, durationUs: 1_000_000, label: "A")
        ], selectedItemId: nil)
        XCTAssertEqual(tv.overlayScrollFailureDeps.count, 2,
                       "Reused clips must not re-register scroll failure dependencies")
    }
}
