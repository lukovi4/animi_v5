import UIKit

/// Presents the recovery prompt when an active draft is detected at launch.
/// Pure presentation coordinator — decision logic lives in `AppLaunchRouter`.
class RecoveryPromptCoordinator {

    enum UserChoice {
        case continueDraft
        case startOver
    }

    /// Shows a recovery alert on the given view controller.
    /// Returns the user's choice via the completion handler.
    func present(
        over presenter: UIViewController,
        completion: @escaping (UserChoice) -> Void
    ) {
        let alert = UIAlertController(
            title: "Resume Project?",
            message: "You have an unfinished project. Would you like to continue editing or start over?",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in
            completion(.continueDraft)
        })

        alert.addAction(UIAlertAction(title: "Start Over", style: .destructive) { _ in
            completion(.startOver)
        })

        presenter.present(alert, animated: true)
    }
}
