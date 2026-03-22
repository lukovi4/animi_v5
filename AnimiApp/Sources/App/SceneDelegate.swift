import UIKit

extension Notification.Name {
    static let appDidEnterBackground = Notification.Name("appDidEnterBackground")
}

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

        let homeViewController = TemplatesHomeViewController()
        let navigationController = UINavigationController(rootViewController: homeViewController)

        // Auto-resume: if active draft exists, push editor immediately
        if ProjectStore.shared.hasActiveDraft() {
            let editorVC = PlayerViewController(entryContext: .resumeActiveDraft)
            navigationController.pushViewController(editorVC, animated: false)
        }

        window.rootViewController = navigationController
        window.makeKeyAndVisible()

        self.window = window
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        NotificationCenter.default.post(name: .appDidEnterBackground, object: nil)
    }

    // MARK: - Background Presets

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
