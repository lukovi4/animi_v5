import Foundation
import AVFoundation
import AnimiEngineCore

/// Slice-005 Stage A — maps the app's `AudioSessionEvent` (`AudioSessionManager`) to the canonical
/// `RealtimeAudioSessionEvent` (`AnimiEngineCore`, Slice-004 Stage G) (plan §3.6).
///
/// Every mapped event is, canonically, **pause-only**: the session invalidates and waits for an explicit
/// user play. In particular `newDeviceAvailable` maps to the pause-only `.newDeviceAvailable` — this
/// mapping deliberately introduces **no** restart/resume; the legacy reprepare+restart is NOT ported.
///
/// Stage A scope: the pure value mapping only. It does NOT call `handleSessionEvent` on any session or
/// drive lifecycle (Stage B/C wire it in).
enum RealtimeAudioSessionEventMapping {

    /// Map one app event to its canonical equivalent. `interruptionEnded(shouldResume:)` drops the
    /// `shouldResume` hint entirely — canonical semantics never auto-resume. Throws for an event with no
    /// exact canonical mapping (`activationFailed`) rather than inventing one.
    static func map(_ event: AudioSessionEvent) throws -> RealtimeAudioSessionEvent {
        switch event {
        case .interruptionBegan:
            return .interruptionBegan
        case .interruptionEnded:
            // The `shouldResume` flag is intentionally ignored — no auto-resume in the canonical model.
            return .interruptionEnded
        case .routeChanged(let reason):
            return mapRouteChange(reason)
        case .mediaServicesReset:
            // No dedicated canonical case; the actual route/format must be re-queried before the next
            // play, which `.outputFormatOrRouteChanged` expresses (pause-only).
            return .outputFormatOrRouteChanged
        case .activationFailed:
            // Not a discontinuity of an *audible* session — there is no exact canonical event.
            throw AppRealtimeAudioIntegrationError.unmappableSessionEvent(detail: "activationFailed")
        }
    }

    /// Map a raw `AVAudioSession.RouteChangeReason` (carried as `UInt` in the app event) to the canonical
    /// route event. `newDeviceAvailable` is distinguished as `.newDeviceAvailable` (pause-only); every
    /// other reason maps to `.routeChanged(<closest canonical reason>)`.
    static func mapRouteChange(_ rawReason: UInt) -> RealtimeAudioSessionEvent {
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        switch reason {
        case .newDeviceAvailable:
            // Distinguished, common case — pause-only, NEVER restart/resume.
            return .newDeviceAvailable
        case .oldDeviceUnavailable:
            return .routeChanged(.oldDeviceUnavailable)
        case .categoryChange:
            return .routeChanged(.categoryChange)
        case .override:
            return .routeChanged(.override)
        case .wakeFromSleep:
            return .routeChanged(.wakeFromSleep)
        case .noSuitableRouteForCategory:
            return .routeChanged(.noSuitableRouteForCategory)
        case .routeConfigurationChange:
            return .routeChanged(.routeConfigurationChange)
        case .unknown:
            return .routeChanged(.unknown)
        case .none:
            // An unrecognised raw value — still pause-only.
            return .routeChanged(.unknown)
        @unknown default:
            return .routeChanged(.unknown)
        }
    }
}
