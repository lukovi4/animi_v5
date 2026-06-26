/// Slice-004 Stage A — the device-output format/route value layer (ADR-006 §3, ADR-012 §4/§5/§7).
///
/// This is the **protocol/value boundary only**. It carries the *actual* hardware output facts that the
/// engine learns **after** audio-session/engine activation — never a requested preference. There is no
/// realtime playback, no `AVAudioEngine`, no clock, no PCM here, and (per the Stage-A no-AV sweep) no
/// audio-framework import and no fractional/floating-point numeric type for canonical values: the
/// sample rate is an exact integer, exactly like `ResolvedAudioSourceDescriptor.sampleRate` (`Int64`).
///
/// ADR-006 §3: *"The engine must query the actual output format after audio-session/engine activation.
/// Requested hardware sample rate and I/O duration are preferences, not facts."* This type is that fact.

// MARK: - Typed errors at the Stage-A realtime boundary

/// Typed failures at the device-format / session-adapter boundary (Slice-004 Stage A).
///
/// Distinct from `AudioEvaluationError` (the pure evaluator boundary) — these concern the realtime
/// device/session boundary only. Stage A *defines* and *raises* the value-construction and
/// query-ordering cases; the realtime-graph cases are introduced by later stages, not here.
public enum RealtimeAudioBoundaryError: Error, Equatable, Sendable {
    /// An `AudioOutputFormat` sample rate was non-positive (`<= 0`). Integer Hz, never clamped.
    case invalidOutputSampleRate(Int64)
    /// An `AudioOutputRoute` was constructed from an empty identifier.
    case invalidOutputRoute
    /// `queryActualOutput()` was called before `activate()` (ADR-006 §3 / ADR-012 §7: the actual
    /// output format/route is only a fact *after* activation; querying earlier is a typed failure).
    case queryBeforeActivation
    /// `queryActualOutput()` was called after `deactivate()` returned the adapter to its inactive,
    /// fail-closed state. There is no last-known format to report when inactive.
    case queryWhileInactive
}

// MARK: - Actual output route

/// The *actual* audio output route reported by the platform after activation (ADR-012 §7 step 4:
/// *"re-queries the actual route and output format before the next play"*; ADR-006 §3).
///
/// A pure value identity (e.g. built-in speaker, headphones, a Bluetooth endpoint). Stage A models it
/// as a stable opaque identifier so a route can never be confused with a raw string at a call site;
/// the concrete platform mapping is an adapter-implementation concern of a later slice. Emptiness is
/// rejected at construction (fail-closed value model, mirroring `AudioStreamIdentity`).
public struct AudioOutputRoute: Hashable, Sendable {
    public let identifier: String

    public init(identifier: String) throws {
        guard !identifier.isEmpty else { throw RealtimeAudioBoundaryError.invalidOutputRoute }
        self.identifier = identifier
    }
}

// MARK: - Actual output format

/// The *actual* hardware output format learned after activation (ADR-006 §3, ADR-012 §4/§5).
///
/// Pure, `Equatable`, `Sendable`. The sample rate is an exact integer (`Int64`, Hz) — **never** a
/// fractional/floating-point rate and **never** a seconds-as-fractional duration. The channel layout reuses the existing
/// canonical `AudioChannelLayoutDescriptor` (mono / stereo / validated discrete). Conversion between
/// the canonical 48 kHz mix grid (ADR-012 §4) and this device grid is a later-stage I/O concern; Stage
/// A only carries the fact.
///
/// Fail-closed: the only initializer validates `sampleRate > 0`, so a non-positive output rate is
/// unrepresentable through the public API (it throws `invalidOutputSampleRate`, never clamps).
public struct AudioOutputFormat: Equatable, Sendable {
    /// Actual hardware output sample rate (Hz), integer. The canonical mix preference is 48 000
    /// (ADR-012 §4) but the device may report another rate; this stores the device fact verbatim.
    public let sampleRate: Int64
    /// Actual output channel layout, via the existing canonical descriptor.
    public let channelLayout: AudioChannelLayoutDescriptor

    public init(sampleRate: Int64, channelLayout: AudioChannelLayoutDescriptor) throws {
        guard sampleRate > 0 else { throw RealtimeAudioBoundaryError.invalidOutputSampleRate(sampleRate) }
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
    }
}

// MARK: - Queried output (format + route together)

/// The pair of *actual* facts a single post-activation query yields: the output format and the output
/// route (ADR-012 §7 step 4 couples them — *"the actual route and output format"*). A pure value so a
/// fake adapter can return it deterministically with no AVFoundation.
public struct AudioOutputQuery: Equatable, Sendable {
    public let format: AudioOutputFormat
    public let route: AudioOutputRoute

    public init(format: AudioOutputFormat, route: AudioOutputRoute) {
        self.format = format
        self.route = route
    }
}
