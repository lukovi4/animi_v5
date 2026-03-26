import XCTest
import TVECore
@testable import AnimiApp

/// Phase 6: Tests for MediaIngestStatusOverlayView rendering behavior.
@MainActor
final class MediaIngestStatusOverlayViewTests: XCTestCase {

    private func makeSUT() -> MediaIngestStatusOverlayView {
        let view = MediaIngestStatusOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.canvasToView = .identity
        return view
    }

    private func makeOverlay(blockId: String) -> MediaInputOverlay {
        MediaInputOverlay(
            blockId: blockId,
            hitPath: BezierPath(vertices: [], inTangents: [], outTangents: [], closed: false),
            rectCanvas: RectD(x: 10, y: 10, width: 100, height: 100)
        )
    }

    // MARK: - Idle / Ready produce no subviews

    func test_idle_producesNoSubviews() {
        let sut = makeSUT()
        sut.update(
            overlays: [makeOverlay(blockId: "b1")],
            statusesByBlockId: ["b1": .idle],
            showsStatus: true
        )
        XCTAssertEqual(sut.subviews.count, 0, "Idle status should produce no subviews")
    }

    func test_ready_producesNoSubviews() {
        let sut = makeSUT()
        sut.update(
            overlays: [makeOverlay(blockId: "b1")],
            statusesByBlockId: ["b1": .ready],
            showsStatus: true
        )
        XCTAssertEqual(sut.subviews.count, 0, "Ready status should produce no subviews")
    }

    func test_noStatus_producesNoSubviews() {
        let sut = makeSUT()
        sut.update(
            overlays: [makeOverlay(blockId: "b1")],
            statusesByBlockId: [:],
            showsStatus: true
        )
        XCTAssertEqual(sut.subviews.count, 0, "Missing status should produce no subviews")
    }

    // MARK: - Processing adds spinner + label

    func test_processing_addsSubview() {
        let sut = makeSUT()
        sut.update(
            overlays: [makeOverlay(blockId: "b1")],
            statusesByBlockId: ["b1": .processing],
            showsStatus: true
        )
        XCTAssertEqual(sut.subviews.count, 1, "Processing should add one container subview")

        // Container should have processing indicator (tag 100)
        XCTAssertEqual(sut.subviews.first?.tag, 100, "Container should be tagged as processing")
    }

    // MARK: - Failed adds error badge

    func test_failed_addsSubview() {
        let sut = makeSUT()
        sut.update(
            overlays: [makeOverlay(blockId: "b1")],
            statusesByBlockId: ["b1": .failed(reason: "error")],
            showsStatus: true
        )
        XCTAssertEqual(sut.subviews.count, 1, "Failed should add one container subview")

        // Container should have failed indicator (tag 200)
        XCTAssertEqual(sut.subviews.first?.tag, 200, "Container should be tagged as failed")
    }

    // MARK: - showsStatus: false clears all subviews

    func test_showsStatusFalse_clearsAllSubviews() {
        let sut = makeSUT()

        // First add some processing indicators
        sut.update(
            overlays: [makeOverlay(blockId: "b1")],
            statusesByBlockId: ["b1": .processing],
            showsStatus: true
        )
        XCTAssertEqual(sut.subviews.count, 1, "Precondition: should have subview")

        // Now set showsStatus to false
        sut.update(
            overlays: [makeOverlay(blockId: "b1")],
            statusesByBlockId: ["b1": .processing],
            showsStatus: false
        )
        XCTAssertEqual(sut.subviews.count, 0, "showsStatus false should clear all subviews")
    }

    // MARK: - Stale blocks removed

    func test_staleBlocks_removed() {
        let sut = makeSUT()

        // Add two processing blocks
        sut.update(
            overlays: [makeOverlay(blockId: "b1"), makeOverlay(blockId: "b2")],
            statusesByBlockId: ["b1": .processing, "b2": .processing],
            showsStatus: true
        )
        XCTAssertEqual(sut.subviews.count, 2)

        // Update with only b1 — b2 should be removed
        sut.update(
            overlays: [makeOverlay(blockId: "b1")],
            statusesByBlockId: ["b1": .processing],
            showsStatus: true
        )
        XCTAssertEqual(sut.subviews.count, 1, "Stale block container should be removed")
    }
}
