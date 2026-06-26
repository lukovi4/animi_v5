/// Slice-004 Stage B — the monotonic host master clock (ADR-006 §3, the no-audio-epoch case).
///
/// Conforms to the Slice-3 `MasterClock` protocol. When the remaining playback range has no unmuted
/// canonical audio, an injected monotonic host clock is master (ADR-006 §3). Like the audio clock it
/// is selected once per epoch and never switched inside it.
///
/// The core never reads `Date`, `DispatchTime`, or any wall clock directly (that would make tests
/// non-deterministic and is a Slice-3 invariant). The host time source is therefore an **injected,
/// monotonic, non-negative project-tick provider** (a `Sendable` closure). The provider already
/// reports canonical project ticks advanced from the anchor; this clock only adds them to the anchor.
/// Pure integer math: no audio/device dependency, no audio framework import, no
/// fractional/floating-point numeric type, fail-closed on a negative tick delta or overflow.
public struct MonotonicHostMasterClock: MasterClock {

    /// The epoch's project-time anchor — the canonical project time at tick-delta `0` (frozen per
    /// epoch).
    public let anchorProjectTime: ProjectTime

    /// Injected monotonic source of canonical project ticks advanced since the anchor. Deterministic
    /// in tests; never `Date`/`DispatchTime` inside the core. Must be non-negative and monotonic;
    /// `currentProjectTime()` fails closed if the delta is negative or the anchored sum overflows.
    private let advancedTicks: @Sendable () -> Int64

    public init(
        anchorProjectTime: ProjectTime,
        advancedTicks: @escaping @Sendable () -> Int64
    ) {
        self.anchorProjectTime = anchorProjectTime
        self.advancedTicks = advancedTicks
    }

    /// The current canonical project time = `anchor + advancedTicks` (ADR-006 §3). Fail-closed on a
    /// negative tick delta (typed domain error) or an overflowing anchored sum (checked add).
    public func currentProjectTime() throws -> ProjectTime {
        let delta = advancedTicks()
        guard delta >= 0 else {
            throw TimeError.negativeValue(domain: "MonotonicHostMasterClock.advancedTicks", value: delta)
        }
        return try anchorProjectTime.adding(TickDuration(uncheckedTicks: delta))
    }
}
