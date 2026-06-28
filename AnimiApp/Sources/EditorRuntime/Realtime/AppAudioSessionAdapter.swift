import Foundation
import AnimiEngineCore

/// Slice-005 Stage A — the app implementation of the canonical `AudioSessionAdapter`
/// (`AnimiEngineCore`), bridging an `AVAudioSession`-style output to the engine's pure value query
/// (plan §3.2). Contract: activate → (re)query the *actual* output; querying before activation is a
/// typed failure; the queried sample rate, route, and channel layout are validated fail-closed.
///
/// The real AVFoundation probing is isolated behind an injected `OutputProbe` so that:
/// (a) unit tests inject a fake (no device, no `AVAudioSession`);
/// (b) all AVFoundation stays in app-side code, never in `AnimiEngineCore`.
///
/// Stage A scope: the adapter + its validation only. It does not start any audio engine, schedule, or
/// drive playback (Stage B/C).
final class AppAudioSessionAdapter: AudioSessionAdapter, @unchecked Sendable {

    /// Raw output facts a probe yields after activation. Floating sample rate is intentional here — the
    /// device reports a Double; the adapter converts it to canonical `Int64` fail-closed.
    struct RawOutput: Equatable {
        let sampleRate: Double
        let channelCount: Int
        let routeIdentifier: String

        init(sampleRate: Double, channelCount: Int, routeIdentifier: String) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.routeIdentifier = routeIdentifier
        }
    }

    /// Injected activation + output probe. The real implementation calls `AVAudioSession`; tests fake it.
    protocol OutputProbe {
        func activate() throws
        func deactivate() throws
        /// The actual output facts. Only called by the adapter after a successful `activate()`.
        func currentOutput() throws -> RawOutput
    }

    private let probe: OutputProbe
    private var active = false

    /// Canonical `AudioSessionAdapter` requirement — `false` until the first successful `activate()` and
    /// after `deactivate()` (fail-closed).
    var isActive: Bool { active }

    init(probe: OutputProbe) {
        self.probe = probe
    }

    func activate() throws {
        try probe.activate()
        active = true
    }

    func deactivate() throws {
        try probe.deactivate()
        active = false
    }

    /// Re-query the actual output (ADR-006 §3 / ADR-012 §7 step 4). Fails closed before activation.
    func queryActualOutput() throws -> AudioOutputQuery {
        guard active else {
            throw AppRealtimeAudioIntegrationError.queryBeforeActivation
        }
        let raw = try probe.currentOutput()

        // Sample rate: Double → exact Int64 (integral, positive), else fail closed (never clamp/round).
        guard raw.sampleRate.isFinite,
              raw.sampleRate > 0,
              raw.sampleRate == raw.sampleRate.rounded(),
              raw.sampleRate <= Double(Int64.max) else {
            throw AppRealtimeAudioIntegrationError.invalidOutputSampleRate(raw: raw.sampleRate)
        }
        let sampleRate = Int64(raw.sampleRate)

        guard !raw.routeIdentifier.isEmpty else {
            throw AppRealtimeAudioIntegrationError.emptyOutputRoute
        }
        let layout = try AppAudioSourceDescriptorResolver.channelLayout(count: raw.channelCount)

        // The canonical fail-closed constructors re-assert the invariants.
        guard let format = try? AudioOutputFormat(sampleRate: sampleRate, channelLayout: layout) else {
            throw AppRealtimeAudioIntegrationError.invalidOutputSampleRate(raw: raw.sampleRate)
        }
        guard let route = try? AudioOutputRoute(identifier: raw.routeIdentifier) else {
            throw AppRealtimeAudioIntegrationError.emptyOutputRoute
        }
        return AudioOutputQuery(format: format, route: route)
    }
}
