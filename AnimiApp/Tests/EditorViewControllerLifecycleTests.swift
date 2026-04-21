import XCTest
@testable import AnimiApp

/// Tests for the pure lifecycle decision helper used by EditorViewController.
final class EditorViewControllerLifecycleTests: XCTestCase {

    // Transient disappearance (e.g. fullscreen preview) — no cleanup
    func testTransientDisappearance_noCleanup() {
        XCTAssertFalse(EditorViewController.shouldCleanupOnDisappear(isMovingFromParent: false, isBeingDismissed: false))
    }

    // Pop from navigation stack — cleanup
    func testPopFromNavStack_cleanup() {
        XCTAssertTrue(EditorViewController.shouldCleanupOnDisappear(isMovingFromParent: true, isBeingDismissed: false))
    }

    // Modal dismiss — cleanup
    func testModalDismiss_cleanup() {
        XCTAssertTrue(EditorViewController.shouldCleanupOnDisappear(isMovingFromParent: false, isBeingDismissed: true))
    }

    // Both flags set — cleanup
    func testBothFlags_cleanup() {
        XCTAssertTrue(EditorViewController.shouldCleanupOnDisappear(isMovingFromParent: true, isBeingDismissed: true))
    }
}
