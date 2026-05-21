import UIKit
import os.log

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // PR5: GC expired derived-artifact caches on launch
        DispatchQueue.global(qos: .utility).async {
            PhotoProxyCache.shared.collectExpired()
            VideoPosterCache.shared.collectExpired()
        }
        do {
            try AudioSessionManager.configureOnLaunch()
        } catch {
            // Log but don't crash — per-runtime manager will re-attempt.
            Logger(subsystem: "com.animi.app", category: "AudioSession")
                .error("audio.session.configureOnLaunch.failed: \(error.localizedDescription)")
            #if DEBUG
            MemoryDiagnostics.event("audio.session.configureOnLaunch", "ok=0 error=\(error.localizedDescription)")
            #endif
        }
        return true
    }

    // MARK: - UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }
}
