import UIKit

extension Notification.Name {
    static let appDidEnterBackground = Notification.Name("appDidEnterBackground")
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var compositionRoot: AppCompositionRoot?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let root = AppCompositionRoot()
        self.compositionRoot = root

        let navigationController = root.bootstrap()

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        self.window = window

        // After window is visible, check for recovery prompt.
        // Root retains the launch router until the user makes a choice.
        if let homeVC = navigationController.viewControllers.first {
            root.handleLaunchRecovery(presenter: homeVC)
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        NotificationCenter.default.post(name: .appDidEnterBackground, object: nil)
    }
}
