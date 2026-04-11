import XCTest
@testable import AnimiApp

@MainActor
final class AppCompositionRootTests: XCTestCase {

    func testBootstrapReturnsNavigationController() {
        let root = AppCompositionRoot()
        let nav = root.bootstrap()

        XCTAssertNotNil(nav.viewControllers.first)
        XCTAssertTrue(nav.viewControllers.first is TemplatesHomeViewController)
    }

    func testBootstrapLoadsBackgroundPresets() {
        let root = AppCompositionRoot()
        _ = root.bootstrap()

        XCTAssertGreaterThan(root.backgroundPresetRepository.count, 0)
    }

    // MARK: - Helpers

    /// Drains the main run loop briefly so that `UINavigationController.pushViewController`
    /// can commit its pending transition under the test harness.
    ///
    /// On modern iOS simulators, a `UIWindow()` constructed without a
    /// `UIWindowScene` is in an orphan state. `pushViewController(animated: true)`
    /// in that state does not update `viewControllers` until the main run loop
    /// drains at least once. Without this drain, `nav.viewControllers.count`
    /// observed immediately after the push call reads the pre-push value.
    ///
    /// Tests that assert the post-push state must call `waitForPushToCommit`
    /// before reading the nav stack. This is a test-harness workaround, not
    /// production behavior — the real UIScene-backed app commits pushes
    /// synchronously at the model level.
    private func waitForPushToCommit() {
        // One full run-loop turn is enough to flush the pending transition.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func testOpenEditorTemplate_pushesPlayerViewController() {
        let root = AppCompositionRoot()
        let nav = root.bootstrap()

        let window = UIWindow()
        window.rootViewController = nav
        window.makeKeyAndVisible()

        root.openEditor(.template(templateId: "test_template"))
        waitForPushToCommit()

        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertTrue(nav.viewControllers.last is PlayerViewController)
    }

    func testOpenEditorResumeDraft_pushesPlayerViewController() {
        let root = AppCompositionRoot()
        let nav = root.bootstrap()

        let window = UIWindow()
        window.rootViewController = nav
        window.makeKeyAndVisible()

        root.openEditor(.resumeDraft)
        waitForPushToCommit()

        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertTrue(nav.viewControllers.last is PlayerViewController)
    }

    func testOpenEditorBlankProject_isNoOp() {
        let root = AppCompositionRoot()
        let nav = root.bootstrap()

        root.openEditor(.blankProject)

        // blankProject is a no-op until PR 7
        XCTAssertEqual(nav.viewControllers.count, 1)
    }

    func testOpenEditorSavedProject_pushesPlayerViewController() {
        let root = AppCompositionRoot()
        let nav = root.bootstrap()

        let window = UIWindow()
        window.rootViewController = nav
        window.makeKeyAndVisible()

        root.openEditor(.savedProject(projectId: UUID()))
        waitForPushToCommit()

        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertTrue(nav.viewControllers.last is PlayerViewController)
    }
}
