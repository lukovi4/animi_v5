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
}
