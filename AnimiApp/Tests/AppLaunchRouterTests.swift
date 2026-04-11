import XCTest
@testable import AnimiApp

final class AppLaunchRouterTests: XCTestCase {

    // MARK: - No Active Draft

    func testNoDraft_doesNotShowPromptOrOpenEditor() {
        var editorOpened = false
        var dismissed = false

        let router = AppLaunchRouter(
            hasActiveDraft: { false },
            clearActiveDraft: { },
            onOpenEditor: { _ in editorOpened = true },
            onDismiss: { dismissed = true }
        )

        let presenter = UIViewController()
        router.handleLaunch(presenter: presenter)

        // handleLaunch is now async internally — give it a tick
        let exp = expectation(description: "async launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertFalse(editorOpened, "Editor should not open when no draft exists")
        XCTAssertTrue(dismissed, "onDismiss should fire when no draft exists")
    }

    // MARK: - Active Draft Exists — Continue (synchronous stub)

    func testActiveDraft_continue_opensResumeDraft() {
        var receivedIntent: EditorLaunchIntent?
        var dismissed = false

        let router = AppLaunchRouter(
            hasActiveDraft: { true },
            clearActiveDraft: { },
            recoveryPrompt: StubRecoveryPrompt(choice: .continueDraft),
            onOpenEditor: { intent in receivedIntent = intent },
            onDismiss: { dismissed = true }
        )

        let presenter = UIViewController()
        router.handleLaunch(presenter: presenter)

        let exp = expectation(description: "async launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        guard let intent = receivedIntent else {
            XCTFail("Expected editor to be opened")
            return
        }

        if case .resumeDraft = intent {
            // Pass
        } else {
            XCTFail("Expected .resumeDraft, got \(intent)")
        }
        XCTAssertFalse(dismissed, "onDismiss should NOT fire on Continue")
    }

    // MARK: - Active Draft Exists — Start Over (synchronous stub)

    func testActiveDraft_startOver_clearsDraftAndDoesNotOpenEditor() {
        var editorOpened = false
        var draftCleared = false
        var dismissed = false

        let router = AppLaunchRouter(
            hasActiveDraft: { true },
            clearActiveDraft: { draftCleared = true },
            recoveryPrompt: StubRecoveryPrompt(choice: .startOver),
            onOpenEditor: { _ in editorOpened = true },
            onDismiss: { dismissed = true }
        )

        let presenter = UIViewController()
        router.handleLaunch(presenter: presenter)

        // Start Over path has nested Task for clearActiveDraft — needs more time
        let exp = expectation(description: "async launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertTrue(draftCleared, "Active draft should be cleared on Start Over")
        XCTAssertFalse(editorOpened, "Editor should not open on Start Over")
        XCTAssertTrue(dismissed, "onDismiss should fire on Start Over")
    }

    // MARK: - Async Lifetime Regression

    func testActiveDraft_asyncChoice_routerStaysAliveUntilChoice() {
        var receivedIntent: EditorLaunchIntent?
        let asyncPrompt = AsyncStubRecoveryPrompt()

        let router = AppLaunchRouter(
            hasActiveDraft: { true },
            clearActiveDraft: { },
            recoveryPrompt: asyncPrompt,
            onOpenEditor: { intent in receivedIntent = intent },
            onDismiss: { }
        )

        let presenter = UIViewController()
        router.handleLaunch(presenter: presenter)

        // Wait for the async hasActiveDraft() to complete and prompt to be presented
        let exp = expectation(description: "prompt presented")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertNil(receivedIntent, "No intent should fire before user chooses")
        XCTAssertNotNil(asyncPrompt.pendingCompletion, "Prompt should be waiting for user choice")

        asyncPrompt.pendingCompletion?(.continueDraft)

        guard let intent = receivedIntent else {
            XCTFail("Expected editor to be opened after async choice")
            return
        }
        if case .resumeDraft = intent {
            // Pass
        } else {
            XCTFail("Expected .resumeDraft, got \(intent)")
        }
    }

    func testActiveDraft_asyncStartOver_routerStaysAliveUntilChoice() {
        var draftCleared = false
        var dismissed = false
        let asyncPrompt = AsyncStubRecoveryPrompt()

        let router = AppLaunchRouter(
            hasActiveDraft: { true },
            clearActiveDraft: { draftCleared = true },
            recoveryPrompt: asyncPrompt,
            onOpenEditor: { _ in },
            onDismiss: { dismissed = true }
        )

        let presenter = UIViewController()
        router.handleLaunch(presenter: presenter)

        let exp1 = expectation(description: "prompt presented")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp1.fulfill() }
        wait(for: [exp1], timeout: 1)

        XCTAssertFalse(draftCleared)
        XCTAssertFalse(dismissed)

        asyncPrompt.pendingCompletion?(.startOver)

        // Wait for nested async clearActiveDraft
        let exp2 = expectation(description: "start over completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp2.fulfill() }
        wait(for: [exp2], timeout: 2)

        XCTAssertTrue(draftCleared)
        XCTAssertTrue(dismissed)
    }

    // MARK: - Caller-Release Regression

    func testActiveDraft_callerReleasesLocalRef_routerSurvivesViaExternalHolder() {
        var receivedIntent: EditorLaunchIntent?
        let asyncPrompt = AsyncStubRecoveryPrompt()

        var externalHolder: AppLaunchRouter?

        do {
            let router = AppLaunchRouter(
                hasActiveDraft: { true },
                clearActiveDraft: { },
                recoveryPrompt: asyncPrompt,
                onOpenEditor: { intent in receivedIntent = intent },
                onDismiss: { externalHolder = nil }
            )
            externalHolder = router

            let presenter = UIViewController()
            router.handleLaunch(presenter: presenter)
        }

        let exp = expectation(description: "prompt presented")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertNotNil(externalHolder, "External holder must keep router alive")
        XCTAssertNil(receivedIntent)

        asyncPrompt.pendingCompletion?(.continueDraft)

        if case .resumeDraft = receivedIntent {
            // Pass
        } else {
            XCTFail("Expected .resumeDraft after caller-release, got \(String(describing: receivedIntent))")
        }
    }
}

// MARK: - Async Stub

private final class AsyncStubRecoveryPrompt: RecoveryPromptCoordinator {
    var pendingCompletion: ((UserChoice) -> Void)?

    override func present(
        over presenter: UIViewController,
        completion: @escaping (UserChoice) -> Void
    ) {
        pendingCompletion = completion
    }
}
