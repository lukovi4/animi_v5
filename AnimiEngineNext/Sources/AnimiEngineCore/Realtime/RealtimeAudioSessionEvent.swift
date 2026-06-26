/// Slice-004 Stage G — the injected realtime audio-session event model (ADR-005 §4, ADR-006 §3,
/// ADR-012 §7).
///
/// An audio-session interruption, a route change, a newly-available device, or an output format/route
/// change is, canonically, a **pause-only** discontinuity for the preview: the current audible session
/// is invalidated, further audio scheduling is refused, and the engine waits for an **explicit user
/// play** to mint a fresh epoch+session. There is **no auto-resume** and **no legacy reprepare+restart**
/// — `newDeviceAvailable` pauses exactly like the others (ADR-005 §4: every discontinuity advances the
/// epoch; nothing resumes the old one).
///
/// This file is a **pure value/enumeration boundary**: no AVFoundation, no device, no floating-point,
/// no clock read here. The platform notification → `RealtimeAudioSessionEvent` mapping is an adapter
/// concern of a later (app-integration) slice; the session consumes these injected values deterministically.

// MARK: - Why a route changed

/// The canonical reasons a platform route change is reported (ADR-012 §7). Every reason is treated as a
/// pause-only discontinuity by the session; the distinction is carried for honest diagnosis only, never
/// to select an auto-resume path.
public enum RealtimeRouteChangeReason: String, Sendable, Equatable, CaseIterable {
    /// A new output device became available (e.g. headphones plugged in). Pause-only — NOT a restart.
    case newDeviceAvailable
    /// The previously-active output device became unavailable (e.g. headphones unplugged).
    case oldDeviceUnavailable
    /// The audio-session category/mode changed.
    case categoryChange
    /// An explicit route override occurred.
    case override
    /// The route changed on wake from sleep.
    case wakeFromSleep
    /// No suitable route exists for the current category.
    case noSuitableRouteForCategory
    /// The route configuration changed without a device add/remove.
    case routeConfigurationChange
    /// An unmapped/unknown reason — still pause-only.
    case unknown
}

// MARK: - The session event

/// One injected realtime audio-session event (ADR-005 §4, ADR-012 §7). A pure value; the session maps
/// **every** case to the same pause-only outcome (invalidate + flush + stay paused), differing only in
/// the typed reason it records.
public enum RealtimeAudioSessionEvent: Sendable, Equatable {
    /// An audio-session interruption began (e.g. a phone call). Pause immediately.
    case interruptionBegan
    /// An audio-session interruption ended. This does **not** auto-resume — it only clears the
    /// interruption flag; audible playback still requires an explicit user play of a new epoch.
    case interruptionEnded
    /// The output route changed, with the platform-reported reason.
    case routeChanged(RealtimeRouteChangeReason)
    /// A new output device became available (a distinguished, common route change). Pause-only — the
    /// legacy reprepare+restart path is intentionally NOT ported.
    case newDeviceAvailable
    /// The actual output format and/or route changed (ADR-012 §7 step 4: re-query before the next play).
    case outputFormatOrRouteChanged

    /// Whether this event, on its own, invalidates the current audible session (everything except a bare
    /// `interruptionEnded`, which only clears the interruption flag without resuming).
    public var invalidatesAudiblePlayback: Bool {
        switch self {
        case .interruptionEnded: return false
        case .interruptionBegan, .routeChanged, .newDeviceAvailable, .outputFormatOrRouteChanged:
            return true
        }
    }
}

// MARK: - The paused outcome

/// The immutable record produced when a session event pauses the preview (Slice-004 Stage G). It
/// captures which epoch/revision was invalidated, the last confirmed project time (read from the
/// injected master clock, when available), the triggering event, and whether the next explicit play
/// must re-query the output format/route first. Pure value — no PCM, no device, no resume handle.
public struct PausedPreviewState: Sendable, Equatable {
    /// The epoch that was playing/preparing when the event arrived and is now invalidated.
    public let invalidatedEpoch: PlaybackEpoch
    /// The revision of that invalidated epoch.
    public let invalidatedRevision: ProjectRevision
    /// The triggering event.
    public let event: RealtimeAudioSessionEvent
    /// The last confirmed canonical project time captured from the injected master clock, or `nil` when
    /// no clock reading was available (e.g. nothing had started). Never a resume point — diagnostics and
    /// a hint for where the next explicit play may seek.
    public let lastConfirmedProjectTime: ProjectTime?
    /// Whether the next explicit play must re-query the actual output format/route before configuring a
    /// new session (set for route / output-format / new-device events; not for a bare interruption).
    public let requiresOutputRequeryBeforeNextPlay: Bool

    public init(
        invalidatedEpoch: PlaybackEpoch,
        invalidatedRevision: ProjectRevision,
        event: RealtimeAudioSessionEvent,
        lastConfirmedProjectTime: ProjectTime?,
        requiresOutputRequeryBeforeNextPlay: Bool
    ) {
        self.invalidatedEpoch = invalidatedEpoch
        self.invalidatedRevision = invalidatedRevision
        self.event = event
        self.lastConfirmedProjectTime = lastConfirmedProjectTime
        self.requiresOutputRequeryBeforeNextPlay = requiresOutputRequeryBeforeNextPlay
    }
}
