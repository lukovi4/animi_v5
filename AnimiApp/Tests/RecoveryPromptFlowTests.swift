import XCTest
@testable import AnimiApp

final class RecoveryPromptFlowTests: XCTestCase {

    func testRecoveryPromptHasTwoActions() {
        let coordinator = RecoveryPromptCoordinator()
        let presenter = UIViewController()
        let window = UIWindow()
        window.rootViewController = presenter
        window.makeKeyAndVisible()

        let presented = expectation(description: "alert presented")

        coordinator.present(over: presenter) { _ in }

        DispatchQueue.main.async {
            guard let alert = presenter.presentedViewController as? UIAlertController else {
                XCTFail("Expected UIAlertController")
                presented.fulfill()
                return
            }
            XCTAssertEqual(alert.title, "Resume Project?")
            XCTAssertEqual(alert.actions.count, 2)
            XCTAssertEqual(alert.actions[0].title, "Continue")
            XCTAssertEqual(alert.actions[0].style, .default)
            XCTAssertEqual(alert.actions[1].title, "Start Over")
            XCTAssertEqual(alert.actions[1].style, .destructive)
            alert.dismiss(animated: false)
            presented.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    func testRecoveryPromptViaStub_continue() {
        let stub = StubRecoveryPrompt(choice: .continueDraft)
        let presenter = UIViewController()
        var receivedChoice: RecoveryPromptCoordinator.UserChoice?

        stub.present(over: presenter) { choice in
            receivedChoice = choice
        }

        XCTAssertEqual(receivedChoice, .continueDraft)
    }

    func testRecoveryPromptViaStub_startOver() {
        let stub = StubRecoveryPrompt(choice: .startOver)
        let presenter = UIViewController()
        var receivedChoice: RecoveryPromptCoordinator.UserChoice?

        stub.present(over: presenter) { choice in
            receivedChoice = choice
        }

        XCTAssertEqual(receivedChoice, .startOver)
    }
}

// MARK: - Stub (shared with AppLaunchRouterTests)

final class StubRecoveryPrompt: RecoveryPromptCoordinator {
    private let choice: UserChoice

    init(choice: UserChoice) {
        self.choice = choice
        super.init()
    }

    override func present(
        over presenter: UIViewController,
        completion: @escaping (UserChoice) -> Void
    ) {
        completion(choice)
    }
}

// MARK: - Equatable conformance for test assertions

extension RecoveryPromptCoordinator.UserChoice: @retroactive Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.continueDraft, .continueDraft): return true
        case (.startOver, .startOver): return true
        default: return false
        }
    }
}
