/// Slice-003 Stage B — the injected master-clock abstraction (ADR-006 §3, control portion only).
///
/// The scheduler derives canonical project time from exactly one master clock per playback epoch. This
/// slice models the clock as an **injected protocol** returning canonical `ProjectTime`; it does NOT
/// implement any realtime clock. The two real kinds — a monotonic host clock (no-audio projects) and an
/// audio-sample clock anchored to `AVAudioTime` (audio-bearing epochs) — are deployment concerns of a
/// later slice. Here there is no `AVAudioTime`, no device time, and no host wall clock; any conforming
/// value is a deterministic, caller-supplied source of canonical ticks.
public protocol MasterClock: Sendable {
    /// The epoch's project-time anchor: the canonical project time at which the master clock starts.
    var anchorProjectTime: ProjectTime { get }

    /// The current canonical project time for the active epoch. Deterministic in tests; the real
    /// host/audio derivation is a later slice.
    func currentProjectTime() throws -> ProjectTime
}

/// Which master clock governs an epoch (ADR-006 §3). Selected once per epoch by
/// ``MasterClockSelector`` and intended to be frozen for that epoch's lifetime.
public enum MasterClockKind: Sendable, Equatable {
    /// An injected monotonic host clock — used when the remaining playback range has no unmuted
    /// canonical audio.
    case monotonicHost

    /// The audio output render clock — used when the remaining playback range contains unmuted
    /// canonical audio (including audio that starts after an initial silent gap).
    case audioSample
}
