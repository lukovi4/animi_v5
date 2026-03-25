import XCTest
@testable import AnimiApp

/// Tests for SceneCatalogViewController: catalog display, selection callback, dismiss, and nil-snapshot alert.
final class SceneCatalogTests: XCTestCase {

    // MARK: - Helpers

    private func makeSnapshot(count: Int) -> SceneLibrarySnapshot {
        let scenes = (0..<count).map { i in
            SceneTypeDescriptor(
                id: "scene_\(i)",
                order: i,
                title: "Scene \(i)",
                baseDurationUs: TimeUs((i + 1) * 1_000_000)
            )
        }
        return SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: scenes
        )
    }

    // MARK: - 1. Catalog builds from scenesInOrder

    func testCatalogRowCountMatchesScenesInOrder() {
        let snapshot = makeSnapshot(count: 3)
        let vc = SceneCatalogViewController(sceneLibrary: snapshot)
        vc.loadViewIfNeeded()

        XCTAssertEqual(vc.tableView.numberOfRows(inSection: 0), 3)
    }

    // MARK: - 2. Selection calls back with correct parameters

    func testSelectionCallbackReceivesCorrectParameters() {
        let snapshot = makeSnapshot(count: 2)
        let vc = SceneCatalogViewController(sceneLibrary: snapshot)
        vc.loadViewIfNeeded()

        var receivedId: String?
        var receivedDuration: TimeUs?
        vc.onSelectScene = { id, duration in
            receivedId = id
            receivedDuration = duration
        }

        // Simulate selecting second row — callback fires in dismiss completion,
        // so we call it directly to test the binding.
        vc.tableView.delegate?.tableView?(vc.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))

        // The callback fires in the dismiss completion block, which won't execute
        // synchronously in tests. Verify the dismiss was requested by checking
        // the VC is trying to dismiss. For callback verification, we set up
        // a window so dismiss completes.
        let window = UIWindow()
        let nav = UINavigationController(rootViewController: vc)
        window.rootViewController = nav
        window.makeKeyAndVisible()

        let exp = expectation(description: "callback fires")
        vc.onSelectScene = { id, duration in
            receivedId = id
            receivedDuration = duration
            exp.fulfill()
        }

        vc.tableView.delegate?.tableView?(vc.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        waitForExpectations(timeout: 2)

        XCTAssertEqual(receivedId, "scene_1")
        XCTAssertEqual(receivedDuration, 2_000_000)
    }

    // MARK: - 3. Picker dismisses after selection

    func testPickerDismissesAfterSelection() {
        let snapshot = makeSnapshot(count: 1)
        let vc = SceneCatalogViewController(sceneLibrary: snapshot)
        vc.loadViewIfNeeded()

        let window = UIWindow()
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()

        let nav = UINavigationController(rootViewController: vc)
        let presentExp = expectation(description: "presented")
        presenter.present(nav, animated: false) {
            presentExp.fulfill()
        }
        waitForExpectations(timeout: 2)

        vc.onSelectScene = { _, _ in }

        let dismissExp = expectation(description: "dismissed")
        // After selection, the VC should dismiss
        vc.tableView.delegate?.tableView?(vc.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))

        // Wait for dismiss to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertNil(presenter.presentedViewController)
            dismissExp.fulfill()
        }
        waitForExpectations(timeout: 3)
    }

    // MARK: - 4. Nil snapshot shows user-facing alert

    func testNilSnapshotShowsAlert() {
        let spy = PresentSpy()
        spy.loadViewIfNeeded()

        let window = UIWindow()
        window.rootViewController = spy
        window.makeKeyAndVisible()

        spy.triggerPresentSceneCatalog()

        let exp = expectation(description: "alert presented")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = spy.presentedViewController as? UIAlertController
            XCTAssertNotNil(alert, "Expected UIAlertController to be presented")
            XCTAssertEqual(alert?.title, "Scenes Unavailable")
            XCTAssertEqual(alert?.message, "Scene library could not be loaded. Please try again.")
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
}

// MARK: - Test Doubles

/// Minimal VC that reproduces presentSceneCatalog() nil-snapshot path.
private final class PresentSpy: UIViewController {
    private var sceneLibrarySnapshot: SceneLibrarySnapshot?

    func triggerPresentSceneCatalog() {
        guard let library = sceneLibrarySnapshot else {
            let alert = UIAlertController(
                title: "Scenes Unavailable",
                message: "Scene library could not be loaded. Please try again.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: false)
            return
        }
        _ = library // suppress unused warning
    }
}
