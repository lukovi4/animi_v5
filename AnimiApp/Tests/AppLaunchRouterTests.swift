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

        XCTAssertTrue(draftCleared, "Active draft should be cleared on Start Over")
        XCTAssertFalse(editorOpened, "Editor should not open on Start Over")
        XCTAssertTrue(dismissed, "onDismiss should fire on Start Over")
    }

    // MARK: - Async Lifetime Regression

    /// Validates that the router works correctly when the prompt completion fires
    /// asynchronously — i.e. after `handleLaunch` has returned. This is the real
    /// shipped path where UIAlertController calls back on button tap.
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

        // At this point handleLaunch has returned but no choice has been made.
        XCTAssertNil(receivedIntent, "No intent should fire before user chooses")
        XCTAssertNotNil(asyncPrompt.pendingCompletion, "Prompt should be waiting for user choice")

        // Simulate user tapping "Continue" after a delay.
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

        XCTAssertFalse(draftCleared)
        XCTAssertFalse(dismissed)

        // Simulate user tapping "Start Over" after a delay.
        asyncPrompt.pendingCompletion?(.startOver)

        XCTAssertTrue(draftCleared)
        XCTAssertTrue(dismissed)
    }

    // MARK: - Caller-Release Regression

    /// Models the real shipped path: the only strong reference to the router
    /// is the one held by AppCompositionRoot. After handleLaunch returns,
    /// the local scope releases — the router must survive via the external holder.
    func testActiveDraft_callerReleasesLocalRef_routerSurvivesViaExternalHolder() {
        var receivedIntent: EditorLaunchIntent?
        let asyncPrompt = AsyncStubRecoveryPrompt()

        // Simulate AppCompositionRoot holding the router
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
            // `router` local goes out of scope here
        }

        // The only reference left is externalHolder — same as AppCompositionRoot.launchRouter
        XCTAssertNotNil(externalHolder, "External holder must keep router alive")
        XCTAssertNil(receivedIntent)

        // User taps Continue after local scope is gone
        asyncPrompt.pendingCompletion?(.continueDraft)

        if case .resumeDraft = receivedIntent {
            // Pass — the router was alive and delivered the intent
        } else {
            XCTFail("Expected .resumeDraft after caller-release, got \(String(describing: receivedIntent))")
        }
    }
}

// MARK: - Async Stub

/// Captures the completion instead of calling it immediately.
/// Simulates the real UIAlertController path where the callback fires on user tap.
private final class AsyncStubRecoveryPrompt: RecoveryPromptCoordinator {
    var pendingCompletion: ((UserChoice) -> Void)?

    override func present(
        over presenter: UIViewController,
        completion: @escaping (UserChoice) -> Void
    ) {
        pendingCompletion = completion
    }
}
