import UIKit
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "AppLaunchRouter")

/// Determines the initial app flow at launch and handles the recovery prompt decision.
///
/// Responsibilities:
/// - Check if an active draft exists.
/// - If yes, show recovery prompt via `RecoveryPromptCoordinator`.
/// - On "Continue", invoke `onOpenEditor(.resumeDraft)`.
/// - On "Start Over", clear the active draft and invoke `onDismiss`.
/// - If no draft, just show home (no-op, the home is already the root).
///
/// **Lifetime:** Must be retained by the caller until the user makes a choice.
/// `AppCompositionRoot` holds a strong reference and nils it out after the choice.
final class AppLaunchRouter {

    private let hasActiveDraft: () async -> Bool
    private let clearActiveDraft: () async throws -> Void
    private let recoveryPrompt: RecoveryPromptCoordinator
    private let onOpenEditor: (EditorLaunchIntent) -> Void
    private let onDismiss: () -> Void

    init(
        hasActiveDraft: @escaping () async -> Bool,
        clearActiveDraft: @escaping () async throws -> Void,
        recoveryPrompt: RecoveryPromptCoordinator = RecoveryPromptCoordinator(),
        onOpenEditor: @escaping (EditorLaunchIntent) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.hasActiveDraft = hasActiveDraft
        self.clearActiveDraft = clearActiveDraft
        self.recoveryPrompt = recoveryPrompt
        self.onOpenEditor = onOpenEditor
        self.onDismiss = onDismiss
    }

    /// Call once after the window is visible and the home VC is on screen.
    func handleLaunch(presenter: UIViewController) {
        Task { @MainActor in
            guard await hasActiveDraft() else {
                onDismiss()
                return
            }

            recoveryPrompt.present(over: presenter) { [self] choice in
                switch choice {
                case .continueDraft:
                    self.onOpenEditor(.resumeDraft)
                case .startOver:
                    Task { @MainActor in
                        do {
                            try await self.clearActiveDraft()
                        } catch {
                            logger.error("[AppLaunchRouter] Failed to clear active draft on Start Over: \(error.localizedDescription, privacy: .public)")
                        }
                        self.onDismiss()
                    }
                }
            }
        }
    }
}
