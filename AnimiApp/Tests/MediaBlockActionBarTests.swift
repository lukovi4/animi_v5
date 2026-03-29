import XCTest
@testable import AnimiApp

/// Phase 6: Tests for MediaBlockActionBar ingest status behavior.
/// Verifies button disable/enable logic and status container visibility.
@MainActor
final class MediaBlockActionBarTests: XCTestCase {

    private func makeBar() -> MediaBlockActionBar {
        let bar = MediaBlockActionBar(frame: CGRect(x: 0, y: 0, width: 400, height: 72))
        // Force layout so lazy properties are initialized
        bar.layoutIfNeeded()
        return bar
    }

    /// Finds the stack view inside the scroll view (the main arrangedSubviews container).
    private func mainStackView(of bar: MediaBlockActionBar) -> UIStackView? {
        // bar > scrollView > stackView
        guard let scrollView = bar.subviews.first(where: { $0 is UIScrollView }) else { return nil }
        return scrollView.subviews.first(where: { $0 is UIStackView }) as? UIStackView
    }

    /// Finds the status container (first UIStackView arranged subview of the main stack).
    private func statusContainer(of bar: MediaBlockActionBar) -> UIStackView? {
        guard let stack = mainStackView(of: bar) else { return nil }
        return stack.arrangedSubviews.first(where: { $0 is UIStackView }) as? UIStackView
    }

    /// Finds buttons by title in the main stack.
    private func button(titled title: String, in bar: MediaBlockActionBar) -> UIButton? {
        guard let stack = mainStackView(of: bar) else { return nil }
        return stack.arrangedSubviews.compactMap { $0 as? UIButton }.first { button in
            button.configuration?.title == title
        }
    }

    // MARK: - Processing State

    /// .processing disables Add Photo, Add Video, Trim buttons.
    func test_processing_disablesMediaButtons() {
        let bar = makeBar()
        bar.configure(
            blockId: "b1",
            allowedMedia: ["photo", "video"],
            hasVariants: true,
            hasMedia: true,
            isEnabled: true,
            mediaKind: .video,
            canTrimVideo: true,
            ingestStatus: .processing,
            showsIngestStatus: true
        )

        let addPhoto = button(titled: "Photo", in: bar)
        let addVideo = button(titled: "Video", in: bar)
        let editVideo = button(titled: "Trim", in: bar)
        let animation = button(titled: "Animation", in: bar)

        XCTAssertNotNil(addPhoto, "Should find Photo button")
        XCTAssertEqual(addPhoto?.isEnabled, false, "Add Photo should be disabled during processing")
        XCTAssertEqual(addVideo?.isEnabled, false, "Add Video should be disabled during processing")
        XCTAssertEqual(editVideo?.isEnabled, false, "Trim should be disabled during processing")
        XCTAssertEqual(animation?.isEnabled, true, "Animation should NOT be disabled during processing")
    }

    /// .processing shows status container.
    func test_processing_showsStatusContainer() {
        let bar = makeBar()
        bar.configure(
            blockId: "b1",
            allowedMedia: nil,
            hasVariants: false,
            hasMedia: false,
            isEnabled: true,
            ingestStatus: .processing,
            showsIngestStatus: true
        )

        let status = statusContainer(of: bar)
        XCTAssertNotNil(status, "Should find status container")
        XCTAssertEqual(status?.isHidden, false, "Status container should be visible during processing")
    }

    // MARK: - Failed State

    /// .failed shows status but re-enables media buttons.
    func test_failed_showsStatusAndEnablesButtons() {
        let bar = makeBar()
        bar.configure(
            blockId: "b1",
            allowedMedia: ["photo", "video"],
            hasVariants: false,
            hasMedia: false,
            isEnabled: true,
            ingestStatus: .failed(reason: "Network error"),
            showsIngestStatus: true
        )

        let addPhoto = button(titled: "Photo", in: bar)
        let addVideo = button(titled: "Video", in: bar)
        let status = statusContainer(of: bar)

        // Failed: buttons should be re-enabled (existing configure logic applies)
        XCTAssertEqual(addPhoto?.isEnabled, true, "Add Photo should be enabled on failure")
        XCTAssertEqual(addVideo?.isEnabled, true, "Add Video should be enabled on failure")
        XCTAssertEqual(status?.isHidden, false, "Status container should be visible on failure")
    }

    // MARK: - showsIngestStatus == false

    /// showsIngestStatus false hides status container, no button overrides.
    func test_showsIngestStatusFalse_hidesStatusContainer() {
        let bar = makeBar()
        bar.configure(
            blockId: "b1",
            allowedMedia: ["photo", "video"],
            hasVariants: false,
            hasMedia: false,
            isEnabled: true,
            ingestStatus: .processing,
            showsIngestStatus: false
        )

        let status = statusContainer(of: bar)
        XCTAssertNotNil(status, "Should find status container")
        XCTAssertEqual(status?.isHidden, true, "Status container should be hidden when showsIngestStatus is false")
    }

    // MARK: - Idle State

    /// .idle hides status container.
    func test_idle_hidesStatusContainer() {
        let bar = makeBar()
        bar.configure(
            blockId: "b1",
            allowedMedia: nil,
            hasVariants: false,
            hasMedia: false,
            isEnabled: true,
            ingestStatus: .idle,
            showsIngestStatus: true
        )

        let status = statusContainer(of: bar)
        XCTAssertNotNil(status, "Should find status container")
        XCTAssertEqual(status?.isHidden, true, "Status container should be hidden for idle status")
    }

    // MARK: - Transition Tests (sticky-disabled regression coverage)

    /// processing -> failed: media buttons re-enabled.
    func test_transition_processingToFailed_reEnablesMediaButtons() {
        let bar = makeBar()

        // Step 1: configure with .processing
        bar.configure(
            blockId: "b1",
            allowedMedia: ["photo", "video"],
            hasVariants: false,
            hasMedia: true,
            isEnabled: true,
            mediaKind: .video,
            canTrimVideo: true,
            ingestStatus: .processing,
            showsIngestStatus: true
        )

        // Verify disabled
        let addPhoto = button(titled: "Photo", in: bar)
        let addVideo = button(titled: "Video", in: bar)
        let editVideo = button(titled: "Trim", in: bar)
        XCTAssertEqual(addPhoto?.isEnabled, false)
        XCTAssertEqual(addVideo?.isEnabled, false)
        XCTAssertEqual(editVideo?.isEnabled, false)

        // Step 2: re-configure same bar with .failed
        bar.configure(
            blockId: "b1",
            allowedMedia: ["photo", "video"],
            hasVariants: false,
            hasMedia: true,
            isEnabled: true,
            mediaKind: .video,
            canTrimVideo: true,
            ingestStatus: .failed(reason: "Network error"),
            showsIngestStatus: true
        )

        // Verify re-enabled
        XCTAssertEqual(addPhoto?.isEnabled, true, "Add Photo must re-enable after processing -> failed")
        XCTAssertEqual(addVideo?.isEnabled, true, "Add Video must re-enable after processing -> failed")
        XCTAssertEqual(editVideo?.isEnabled, true, "Trim must return to baseline (canTrimVideo=true) after processing -> failed")

        let status = statusContainer(of: bar)
        XCTAssertEqual(status?.isHidden, false, "Status container should be visible on failed")
    }

    /// processing -> idle: media buttons re-enabled.
    func test_transition_processingToIdle_reEnablesMediaButtons() {
        let bar = makeBar()

        // Step 1: configure with .processing
        bar.configure(
            blockId: "b1",
            allowedMedia: ["photo", "video"],
            hasVariants: false,
            hasMedia: false,
            isEnabled: true,
            ingestStatus: .processing,
            showsIngestStatus: true
        )

        let addPhoto = button(titled: "Photo", in: bar)
        let addVideo = button(titled: "Video", in: bar)
        XCTAssertEqual(addPhoto?.isEnabled, false)
        XCTAssertEqual(addVideo?.isEnabled, false)

        // Step 2: re-configure same bar with .idle
        bar.configure(
            blockId: "b1",
            allowedMedia: ["photo", "video"],
            hasVariants: false,
            hasMedia: false,
            isEnabled: true,
            ingestStatus: .idle,
            showsIngestStatus: true
        )

        XCTAssertEqual(addPhoto?.isEnabled, true, "Add Photo must re-enable after processing -> idle")
        XCTAssertEqual(addVideo?.isEnabled, true, "Add Video must re-enable after processing -> idle")

        let status = statusContainer(of: bar)
        XCTAssertEqual(status?.isHidden, true, "Status container should be hidden for idle")
    }

    /// processing -> showsIngestStatus=false: media buttons re-enabled, status hidden.
    func test_transition_processingToStatusHidden_reEnablesMediaButtons() {
        let bar = makeBar()

        // Step 1: configure with .processing, showsIngestStatus: true
        bar.configure(
            blockId: "b1",
            allowedMedia: ["photo", "video"],
            hasVariants: false,
            hasMedia: false,
            isEnabled: true,
            ingestStatus: .processing,
            showsIngestStatus: true
        )

        let addPhoto = button(titled: "Photo", in: bar)
        let addVideo = button(titled: "Video", in: bar)
        XCTAssertEqual(addPhoto?.isEnabled, false)
        XCTAssertEqual(addVideo?.isEnabled, false)

        // Step 2: re-configure same bar with showsIngestStatus: false
        bar.configure(
            blockId: "b1",
            allowedMedia: ["photo", "video"],
            hasVariants: false,
            hasMedia: false,
            isEnabled: true,
            ingestStatus: .processing,
            showsIngestStatus: false
        )

        XCTAssertEqual(addPhoto?.isEnabled, true, "Add Photo must re-enable when status UI hidden")
        XCTAssertEqual(addVideo?.isEnabled, true, "Add Video must re-enable when status UI hidden")

        let status = statusContainer(of: bar)
        XCTAssertEqual(status?.isHidden, true, "Status container should be hidden")
    }
}
