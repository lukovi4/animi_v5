import AVFAudio
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "AudioSession")

enum AppAudioSessionController {
    static func configure() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback
            )
            logger.info("Audio session configured: .playback / .moviePlayback")
        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    static func activate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("Failed to activate audio session: \(error.localizedDescription)")
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }
}
