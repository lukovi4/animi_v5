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

    func testOpenEditorTemplate_pushesPlayerViewController() {
        let root = AppCompositionRoot()
        let nav = root.bootstrap()

        let window = UIWindow()
        window.rootViewController = nav
        window.makeKeyAndVisible()

        root.openEditor(.template(templateId: "test_template"))

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

        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertTrue(nav.viewControllers.last is PlayerViewController)
    }
}
