import AVFAudio
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "AudioSessionManager")

// MARK: - Event

enum AudioSessionEvent {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(reason: UInt)
    case mediaServicesReset
    case activationFailed(Error)
}

// MARK: - Protocol

@MainActor
protocol AudioSessionManaging: AnyObject {
    func configureForPlayback() throws
    func activateForPlayback() throws
    func deactivateAfterPlayback() throws
    var onEvent: ((AudioSessionEvent) -> Void)? { get set }
}

// MARK: - Session Adapter

/// Thin wrapper around AVAudioSession for unit-testability.
@MainActor
protocol AudioSessionAdapting: AnyObject {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

@MainActor
final class SharedAVAudioSessionAdapter: AudioSessionAdapting {
    private let session = AVAudioSession.sharedInstance()
    var category: AVAudioSession.Category { session.category }
    var mode: AVAudioSession.Mode { session.mode }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode) throws {
        try session.setCategory(category, mode: mode)
    }
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        try session.setActive(active, options: options)
    }
}

// MARK: - Production Implementation

@MainActor
final class AudioSessionManager: AudioSessionManaging {

    var onEvent: ((AudioSessionEvent) -> Void)?

    private let session: AudioSessionAdapting
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var isConfigured = false

    convenience init() {
        self.init(session: SharedAVAudioSessionAdapter(), notificationCenter: .default)
    }

    init(session: AudioSessionAdapting, notificationCenter: NotificationCenter) {
        self.session = session
        self.notificationCenter = notificationCenter
        registerObservers()
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    func configureForPlayback() throws {
        try session.setCategory(.playback, mode: .moviePlayback)
        isConfigured = true
        logger.info("audio.session.configure ok category=playback mode=moviePlayback")
        #if DEBUG
        MemoryDiagnostics.event("audio.session.configure", "ok=1")
        #endif
    }

    func activateForPlayback() throws {
        if !isConfigured {
            try configureForPlayback()
        }
        if session.category != .playback || session.mode != .moviePlayback {
            try configureForPlayback()
        }
        #if DEBUG
        MemoryDiagnostics.event("audio.session.activate.begin", "")
        #endif
        do {
            try session.setActive(true, options: [])
        } catch {
            onEvent?(.activationFailed(error))
            throw error
        }
        #if DEBUG
        MemoryDiagnostics.event("audio.session.activate.end", "ok=1")
        #endif
    }

    func deactivateAfterPlayback() throws {
        #if DEBUG
        MemoryDiagnostics.event("audio.session.deactivate.begin", "")
        #endif
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        #if DEBUG
        MemoryDiagnostics.event("audio.session.deactivate.end", "ok=1")
        #endif
    }

    // MARK: - Observers

    private func registerObservers() {
        let nc = notificationCenter
        let avSession = AVAudioSession.sharedInstance()

        let interruptionObs = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: avSession,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleInterruption(note)
            }
        }

        let routeObs = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: avSession,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(note)
            }
        }

        let resetObs = nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        }

        observers = [interruptionObs, routeObs, resetObs]
    }

    private func handleInterruption(_ note: Notification) {
        let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
        #if DEBUG
        MemoryDiagnostics.event("audio.session.interruption", "type=\(typeRaw)")
        #endif
        if typeRaw == AVAudioSession.InterruptionType.began.rawValue {
            onEvent?(.interruptionBegan)
        } else if typeRaw == AVAudioSession.InterruptionType.ended.rawValue {
            let optionsRaw = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let shouldResume = (optionsRaw & AVAudioSession.InterruptionOptions.shouldResume.rawValue) != 0
            onEvent?(.interruptionEnded(shouldResume: shouldResume))
        }
    }

    private func handleRouteChange(_ note: Notification) {
        let reasonRaw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        #if DEBUG
        MemoryDiagnostics.event("audio.session.routeChange", "reason=\(reasonRaw)")
        #endif
        onEvent?(.routeChanged(reason: reasonRaw))
    }

    private func handleMediaServicesReset() {
        logger.warning("audio.session.mediaServicesReset — reconfiguring")
        #if DEBUG
        MemoryDiagnostics.event("audio.session.mediaServicesReset", "")
        #endif
        isConfigured = false
        do {
            try configureForPlayback()
        } catch {
            logger.error("audio.session.reconfigure.failed: \(error.localizedDescription)")
        }
        onEvent?(.mediaServicesReset)
    }

    // MARK: - App Launch

    @MainActor
    static func configureOnLaunch() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        logger.info("audio.session.configureOnLaunch ok")
        #if DEBUG
        MemoryDiagnostics.event("audio.session.configureOnLaunch", "ok=1")
        #endif
    }
}
