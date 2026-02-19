import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // PR3: Load background presets at app startup (fail-fast)
        loadBackgroundPresets()

        let window = UIWindow(windowScene: windowScene)

        // PR-Templates: Start with Templates Home inside Navigation Controller
        let homeViewController = TemplatesHomeViewController()
        let navigationController = UINavigationController(rootViewController: homeViewController)
        window.rootViewController = navigationController

        window.makeKeyAndVisible()

        self.window = window
    }

    // MARK: - PR3: Background Presets

    /// Loads background presets from bundle at app startup.
    /// Fail-fast: logs error in DEBUG, continues with fallback in RELEASE.
    private func loadBackgroundPresets() {
        do {
            try BackgroundPresetLibrary.shared.loadFromBundle()
            #if DEBUG
            print("[SceneDelegate] Loaded \(BackgroundPresetLibrary.shared.count) background presets")
            #endif
        } catch {
            #if DEBUG
            assertionFailure("[SceneDelegate] Failed to load background presets: \(error)")
            #else
            print("[SceneDelegate] ERROR: Failed to load background presets: \(error)")
            #endif
        }
    }
}
