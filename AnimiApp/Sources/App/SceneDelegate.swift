import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)

        // PR-Templates: Start with Templates Home inside Navigation Controller
        let homeViewController = TemplatesHomeViewController()
        let navigationController = UINavigationController(rootViewController: homeViewController)
        window.rootViewController = navigationController

        window.makeKeyAndVisible()

        self.window = window
    }
}
