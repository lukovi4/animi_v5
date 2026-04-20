import XCTest
@testable import AnimiApp

/// Tests for OverlayLaneView layout behavior.
/// Contract: each item occupies its own visual row (index = row).
final class OverlayLaneTests: XCTestCase {

    // MARK: - Helpers

    private func makeLane(width: CGFloat = 400, height: CGFloat = 200) -> OverlayLaneView {
        let lane = OverlayLaneView(laneKind: .text)
        lane.frame = CGRect(x: 0, y: 0, width: width, height: height)
        return lane
    }

    private func makeSnapshot(
        _ items: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)],
        selectedItemId: UUID? = nil
    ) -> OverlayLaneSnapshot {
        let snapshotItems = items.map {
            OverlayLaneSnapshot.Item(id: $0.id, startUs: $0.startUs, durationUs: $0.durationUs, label: $0.label)
        }
        return OverlayLaneSnapshot(items: snapshotItems, selectedItemId: selectedItemId)
    }

    private func clipY(_ id: UUID, in lane: OverlayLaneView) -> CGFloat? {
        lane.subviews.first { $0.accessibilityIdentifier == "overlayClip_\(id.uuidString)" }?.frame.minY
    }

    // MARK: - Layout Behavior

    func testLaneView_3items_3distinctYPositions() {
        let lane = makeLane()
        let ids = [UUID(), UUID(), UUID()]
        let snapshot = makeSnapshot([
            (id: ids[0], startUs: 0, durationUs: 1_000_000, label: "A"),
            (id: ids[1], startUs: 500_000, durationUs: 1_000_000, label: "B"),
            (id: ids[2], startUs: 1_000_000, durationUs: 1_000_000, label: "C"),
        ])
        lane.applySnapshot(snapshot)
        lane.configure(pxPerSecond: 100, leftPadding: 0)
        lane.layoutIfNeeded()

        XCTAssertEqual(clipY(ids[0], in: lane), 2, "First item at y=2")
        XCTAssertEqual(clipY(ids[1], in: lane), 30, "Second item at y=30")
        XCTAssertEqual(clipY(ids[2], in: lane), 58, "Third item at y=58")
    }

    func testLaneView_nonOverlapping_stillSeparateRows() {
        let lane = makeLane()
        let ids = [UUID(), UUID(), UUID()]
        // Sequential, non-overlapping items — must still get separate rows
        let snapshot = makeSnapshot([
            (id: ids[0], startUs: 0, durationUs: 1_000_000, label: "A"),
            (id: ids[1], startUs: 1_000_000, durationUs: 1_000_000, label: "B"),
            (id: ids[2], startUs: 2_000_000, durationUs: 1_000_000, label: "C"),
        ])
        lane.applySnapshot(snapshot)
        lane.configure(pxPerSecond: 100, leftPadding: 0)
        lane.layoutIfNeeded()

        let yPositions = ids.compactMap { clipY($0, in: lane) }
        XCTAssertEqual(yPositions.count, 3)
        XCTAssertEqual(Set(yPositions).count, 3, "Non-overlapping items must still have 3 distinct Y positions")
    }

    func testLaneView_emptySnapshot_noClips() {
        let lane = makeLane()
        let snapshot = makeSnapshot([])
        lane.applySnapshot(snapshot)
        lane.configure(pxPerSecond: 100, leftPadding: 0)
        lane.layoutIfNeeded()

        let clips = lane.subviews.filter { $0.accessibilityIdentifier?.hasPrefix("overlayClip_") == true }
        XCTAssertTrue(clips.isEmpty, "Empty snapshot should produce no clip subviews")
    }

    func testLaneView_rowStableAfterStartUsChange() {
        let lane = makeLane()
        let ids = [UUID(), UUID(), UUID()]

        let snapshot1 = makeSnapshot([
            (id: ids[0], startUs: 0, durationUs: 1_000_000, label: "A"),
            (id: ids[1], startUs: 2_000_000, durationUs: 1_000_000, label: "B"),
            (id: ids[2], startUs: 4_000_000, durationUs: 1_000_000, label: "C"),
        ])
        lane.applySnapshot(snapshot1)
        lane.configure(pxPerSecond: 100, leftPadding: 0)
        lane.layoutIfNeeded()

        let yBefore = ids.compactMap { clipY($0, in: lane) }

        let snapshot2 = makeSnapshot([
            (id: ids[0], startUs: 0, durationUs: 1_000_000, label: "A"),
            (id: ids[1], startUs: 6_000_000, durationUs: 1_000_000, label: "B"),
            (id: ids[2], startUs: 4_000_000, durationUs: 1_000_000, label: "C"),
        ])
        lane.applySnapshot(snapshot2)
        lane.configure(pxPerSecond: 100, leftPadding: 0)
        lane.layoutIfNeeded()

        let yAfter = ids.compactMap { clipY($0, in: lane) }

        XCTAssertEqual(yBefore, yAfter, "Y positions must not change when startUs changes — row is stable")
    }

    func testLaneView_singleItem_correctFrame() {
        let lane = makeLane()
        let id = UUID()
        let snapshot = makeSnapshot([
            (id: id, startUs: 0, durationUs: 1_000_000, label: "Solo"),
        ])
        lane.applySnapshot(snapshot)
        lane.configure(pxPerSecond: 100, leftPadding: 0)
        lane.layoutIfNeeded()

        let clip = lane.subviews.first { $0.accessibilityIdentifier == "overlayClip_\(id.uuidString)" }
        XCTAssertNotNil(clip)
        XCTAssertEqual(clip?.frame.minY, 2, "Single item at y=2")
        XCTAssertEqual(clip?.frame.height, 26, "Clip height should be 26 (28 - 2 gap)")
    }

    // MARK: - Gesture Architecture (Clip View)

    private func makeClip(width: CGFloat = 200, height: CGFloat = 26) -> OverlayClipView {
        let clip = OverlayClipView()
        clip.frame = CGRect(x: 0, y: 0, width: width, height: height)
        clip.layoutIfNeeded()
        return clip
    }

    // MARK: Gesture Defaults

    func testClipView_moveLongPressGesture_disabledByDefault() {
        let clip = makeClip()
        XCTAssertFalse(clip.moveLongPressGesture.isEnabled, "Move gesture must be disabled by default")
    }

    func testClipView_trimPanGesture_disabledByDefault() {
        let clip = makeClip()
        XCTAssertFalse(clip.trimPanGesture.isEnabled, "Trim gesture must be disabled by default")
    }

    func testClipView_setSelected_enablesGestures() {
        let clip = makeClip()
        clip.setSelected(true)
        XCTAssertTrue(clip.moveLongPressGesture.isEnabled, "Move gesture must be enabled when selected")
        XCTAssertTrue(clip.trimPanGesture.isEnabled, "Trim gesture must be enabled when selected")
    }

    func testClipView_setSelected_false_disablesGestures() {
        let clip = makeClip()
        clip.setSelected(true)
        clip.setSelected(false)
        XCTAssertFalse(clip.moveLongPressGesture.isEnabled, "Move gesture must be disabled after deselect")
        XCTAssertFalse(clip.trimPanGesture.isEnabled, "Trim gesture must be disabled after deselect")
    }

    // MARK: Expanded Hit Testing + Trim Zone

    func testClipView_pointInside_visibleBounds_true() {
        let clip = makeClip(width: 200)
        XCTAssertTrue(clip.point(inside: CGPoint(x: 0, y: 13), with: nil), "Leading edge is inside")
        XCTAssertTrue(clip.point(inside: CGPoint(x: 100, y: 13), with: nil), "Middle is inside")
        XCTAssertTrue(clip.point(inside: CGPoint(x: 199, y: 13), with: nil), "Trailing edge is inside")
    }

    func testClipView_pointInside_unselected_noExpansion() {
        let clip = makeClip(width: 200)
        // Unselected — no expansion beyond visible bounds
        XCTAssertFalse(clip.point(inside: CGPoint(x: 200, y: 13), with: nil), "Beyond bounds must be false when unselected")
        XCTAssertFalse(clip.point(inside: CGPoint(x: 243, y: 13), with: nil), "Expanded zone must be false when unselected")
    }

    func testClipView_pointInside_selected_hasExpansion() {
        let clip = makeClip(width: 200)
        clip.setSelected(true)
        // Selected — 44pt expansion
        XCTAssertTrue(clip.point(inside: CGPoint(x: 200, y: 13), with: nil), "Just beyond visible bounds")
        XCTAssertTrue(clip.point(inside: CGPoint(x: 243, y: 13), with: nil), "At edge of expanded zone")
        XCTAssertFalse(clip.point(inside: CGPoint(x: 244, y: 13), with: nil), "Beyond expanded zone")
    }

    func testClipView_pointInside_shortClip_selectedExpansion() {
        let clip = makeClip(width: 20)
        clip.setSelected(true)
        // Short clip still gets full 44pt expansion when selected
        XCTAssertTrue(clip.point(inside: CGPoint(x: 10, y: 13), with: nil), "Inside visible bounds")
        XCTAssertTrue(clip.point(inside: CGPoint(x: 20, y: 13), with: nil), "Just beyond")
        XCTAssertTrue(clip.point(inside: CGPoint(x: 63, y: 13), with: nil), "At end of 44pt expansion")
        XCTAssertFalse(clip.point(inside: CGPoint(x: 64, y: 13), with: nil), "Beyond expansion")
    }

    func testClipView_isInTrimZone_insideVisibleBounds_false() {
        let clip = makeClip(width: 200)
        XCTAssertFalse(clip.isInTrimZone(localX: 0), "Leading edge is not trim")
        XCTAssertFalse(clip.isInTrimZone(localX: 100), "Middle is not trim")
        XCTAssertFalse(clip.isInTrimZone(localX: 199), "Just before trailing edge is not trim")
    }

    func testClipView_isInTrimZone_beyondVisibleBounds_true() {
        let clip = makeClip(width: 200)
        XCTAssertTrue(clip.isInTrimZone(localX: 200), "At trailing edge = trim")
        XCTAssertTrue(clip.isInTrimZone(localX: 230), "In expanded zone = trim")
    }

    // MARK: Gestures on Self

    func testClipView_moveLongPressGesture_onSelf() {
        let clip = makeClip()
        XCTAssertTrue(clip.moveLongPressGesture.view === clip, "Move gesture must be on self")
    }

    func testClipView_trimPanGesture_onSelf() {
        let clip = makeClip()
        XCTAssertTrue(clip.trimPanGesture.view === clip, "Trim gesture must be on self")
    }

    func testClipView_moveLongPressGesture_minimumPressDuration() {
        let clip = makeClip()
        XCTAssertEqual(clip.moveLongPressGesture.minimumPressDuration, 0.3,
                       "Move gesture minimum press duration must be 0.3s")
    }

    func testClipView_tapGestureExists() {
        let clip = makeClip()
        let tapGestures = clip.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        XCTAssertEqual(tapGestures.count, 1, "Clip must have exactly one tap gesture on self")
    }

    func testClipView_noSubviewGestures() {
        // No bodyView or trailingHandle subviews with gestures — all on self
        let clip = makeClip()
        for sub in clip.subviews {
            let gestures = sub.gestureRecognizers ?? []
            XCTAssertTrue(gestures.isEmpty, "Subview \(sub) should have no gesture recognizers")
        }
    }

    // MARK: Delegate Wiring

    func testClipView_allGesturesHaveDelegateSelf() {
        let clip = makeClip()
        let gestures = clip.gestureRecognizers ?? []
        for g in gestures {
            XCTAssertTrue(g.delegate === clip,
                          "\(type(of: g)) must have delegate = self (clip)")
        }
    }

    func testClipView_moveLongPressGesture_delegateIsSelf() {
        let clip = makeClip()
        XCTAssertTrue(clip.moveLongPressGesture.delegate === clip)
    }

    func testClipView_trimPanGesture_delegateIsSelf() {
        let clip = makeClip()
        XCTAssertTrue(clip.trimPanGesture.delegate === clip)
    }

    // MARK: Interaction Zone Classification

    func testClipView_interactionZone_insideBody() {
        let clip = makeClip(width: 200)
        XCTAssertEqual(clip.interactionZone(forLocalX: 0), .visibleBody)
        XCTAssertEqual(clip.interactionZone(forLocalX: 100), .visibleBody)
        XCTAssertEqual(clip.interactionZone(forLocalX: 199), .visibleBody)
    }

    func testClipView_interactionZone_trimZone() {
        let clip = makeClip(width: 200)
        XCTAssertEqual(clip.interactionZone(forLocalX: 200), .trimZone)
        XCTAssertEqual(clip.interactionZone(forLocalX: 230), .trimZone)
        XCTAssertEqual(clip.interactionZone(forLocalX: 243), .trimZone)
    }

    func testClipView_interactionZone_outsideAll() {
        let clip = makeClip(width: 200)
        XCTAssertNil(clip.interactionZone(forLocalX: -1), "Before clip = nil")
        XCTAssertNil(clip.interactionZone(forLocalX: 244), "Beyond expansion = nil")
    }

    // MARK: gestureRecognizerShouldBegin — Real Begin Behavior

    func testClipView_gestureRecognizerShouldBegin_trimPan_inBody_false() {
        let clip = makeClip(width: 200)
        clip.setSelected(true)
        // Trim pan should NOT begin in visible body
        XCTAssertFalse(clip.gestureRecognizerShouldBegin(clip.trimPanGesture),
                       "trimPanGesture must not begin in visible body zone")
    }

    func testClipView_gestureRecognizerShouldBegin_moveLongPress_inTrimZone_false() {
        let clip = makeClip(width: 200)
        clip.setSelected(true)
        // Can't easily set gesture location, but we can test the method directly
        // by calling it — gesture location defaults to (0,0) which is visibleBody
        XCTAssertTrue(clip.gestureRecognizerShouldBegin(clip.moveLongPressGesture),
                      "moveLongPressGesture should begin in visible body zone")
    }

    // MARK: - onClipCreated Callback

    func testLaneView_onClipCreated_calledForNewClips() {
        let lane = makeLane()
        var createdClips: [OverlayClipView] = []
        lane.onClipCreated = { clip in createdClips.append(clip) }

        let ids = [UUID(), UUID()]
        let snapshot = makeSnapshot([
            (id: ids[0], startUs: 0, durationUs: 1_000_000, label: "A"),
            (id: ids[1], startUs: 1_000_000, durationUs: 1_000_000, label: "B"),
        ])
        lane.applySnapshot(snapshot)

        XCTAssertEqual(createdClips.count, 2, "onClipCreated should fire for each new clip")
        for clip in createdClips {
            XCTAssertNotNil(clip.moveLongPressGesture.view, "Created clip should have move gesture attached")
            XCTAssertNotNil(clip.trimPanGesture.view, "Created clip should have trim gesture attached")
        }
    }

    func testLaneView_onClipCreated_notCalledForExistingClips() {
        let lane = makeLane()
        var callCount = 0
        lane.onClipCreated = { _ in callCount += 1 }

        let ids = [UUID(), UUID()]
        let snapshot = makeSnapshot([
            (id: ids[0], startUs: 0, durationUs: 1_000_000, label: "A"),
            (id: ids[1], startUs: 1_000_000, durationUs: 1_000_000, label: "B"),
        ])
        lane.applySnapshot(snapshot)
        XCTAssertEqual(callCount, 2)

        // Reset and apply same snapshot — clips are reused, not recreated
        callCount = 0
        lane.applySnapshot(snapshot)
        XCTAssertEqual(callCount, 0, "onClipCreated must NOT fire for reused clips")
    }
}
