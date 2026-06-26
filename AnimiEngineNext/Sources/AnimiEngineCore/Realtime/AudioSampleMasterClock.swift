/// Slice-004 Stage B — the audio-sample master clock (ADR-006 §3, the audio-bearing-epoch case).
///
/// Conforms to the Slice-3 `MasterClock` protocol. For an audio-bearing epoch the audio render clock
/// is master: the scheduler derives canonical `ProjectTime` from the sample time advanced since the
/// epoch's project-start anchor (ADR-006 §3). The clock is **selected once per epoch and never
/// switched inside it** — the anchor is fixed at construction and the sample-time provider is the only
/// progressing input.
///
/// Stage B keeps this pure and device-free: the actual `AVAudioTime` sample reads are a later-stage
/// I/O concern, modelled here as an **injected sample-time provider** (a `Sendable` closure). Any
/// conforming provider is a deterministic source of a monotonic, non-negative sample index. There is
/// no audio framework import, no clock arithmetic in fractional/floating-point numeric form, and the
/// mapping fails closed on a negative sample time or overflow (`SampleTimeMapping`).
public struct AudioSampleMasterClock: MasterClock {

    /// The epoch's project-time anchor — the canonical project time at sample `0` (frozen per epoch).
    public let anchorProjectTime: ProjectTime

    /// Injected source of the current sample time (samples advanced since the anchor). Deterministic
    /// in tests; the real `AVAudioTime`-backed derivation is a later slice. Must be non-negative;
    /// `currentProjectTime()` fails closed via `SampleTimeMapping` if it is not.
    private let currentSampleTime: @Sendable () -> Int64

    public init(
        anchorProjectTime: ProjectTime,
        currentSampleTime: @escaping @Sendable () -> Int64
    ) {
        self.anchorProjectTime = anchorProjectTime
        self.currentSampleTime = currentSampleTime
    }

    /// The current canonical project time = `anchor + currentSampleTime * 5 ticks` (ADR-006 §3/§4).
    /// Fail-closed on negative sample time or overflow.
    public func currentProjectTime() throws -> ProjectTime {
        try SampleTimeMapping.projectTime(
            anchor: anchorProjectTime,
            sampleTime: currentSampleTime()
        )
    }
}
