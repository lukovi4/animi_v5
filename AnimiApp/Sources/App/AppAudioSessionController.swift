// Legacy audio session controller — replaced by AudioSessionManager.
// File kept in project for compilation but all methods are unavailable.
// Remove entirely once AudioSessionManager is fully validated.

import AVFAudio

@available(*, unavailable, message: "Use AudioSessionManager instead")
enum AppAudioSessionController {
    static func configure() {}
    static func activate() {}
    static func deactivate() {}
}
