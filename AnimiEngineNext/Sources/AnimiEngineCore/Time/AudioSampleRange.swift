/// Exact 48 kHz tick↔sample mapping (Slice 001, plan §3.6, §8; ADR-006 §4).
///
/// The 48 kHz sample grid is the only canonical sample identity. A project tick (240,000/sec) maps
/// to a sample index by `ceilDiv5` (`240_000 / 48_000 == 5` ticks per sample). **No floating
/// point** — the entire mapping is integer.
public enum AudioSampleGrid {
    /// Exactly 48,000 samples per second.
    public static let samplesPerSecond: Int64 = 48_000
    /// Exactly 5 = `TickClock.ticksPerSecond / samplesPerSecond` (asserted by a test).
    public static let ticksPerSample: Int64 = 5

    /// `ceilDiv5(t) = t/5 + (t % 5 == 0 ? 0 : 1)`, for `t >= 0`.
    ///
    /// PROOF (no overflow): for `t` in `[0, Int64.max]`, `t/5 <= floor(Int64.max/5) =
    /// 1_844_674_407_370_955_161`, and adding at most 1 yields at most
    /// `1_844_674_407_370_955_162 < Int64.max = 9_223_372_036_854_775_807`. The `+1` therefore
    /// CANNOT overflow for any non-negative `Int64`; the result is exact. A non-negative
    /// precondition is still enforced — negative `t` is a typed domain error.
    public static func ceilDiv5(_ tick: Int64) throws -> Int64 {
        guard tick >= 0 else {
            throw TimeError.negativeValue(domain: "AudioSampleGrid.ceilDiv5", value: tick)
        }
        let q = tick / 5
        let add: Int64 = (tick % 5 == 0) ? 0 : 1
        return q + add                              // proven not to overflow for tick >= 0
    }
}

/// A half-open 48 kHz sample interval `[start, end)`, the only canonical sample identity
/// (ADR-006 §4).
///
/// EMPTY ranges are valid: `start == end` means zero samples (the clip rounds to no audio at the
/// 48 kHz grid). Only `end < start` is forbidden.
public struct AudioSampleRange: Hashable, Sendable {
    public let start: Int64                 // >= 0
    public let end: Int64                   // >= start  (empty allowed; only end < start forbidden)

    init(uncheckedStart start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    /// Maps a half-open project tick range to its half-open sample range (ADR-006 §4).
    ///
    /// May return an EMPTY range (`start == end`) when both endpoints ceil to the same sample. A
    /// `ProjectTimeRange` guarantees `end.ticks > start.ticks`, but two distinct ticks can collapse
    /// to one sample, so `start == end` is a legitimate empty result. Only `end < start` (which
    /// `ceilDiv5` monotonicity makes unreachable from a valid range, but is guarded for safety) is
    /// rejected.
    public static func from(projectTicks range: ProjectTimeRange) throws -> AudioSampleRange {
        let s = try AudioSampleGrid.ceilDiv5(range.start.ticks)
        let e = try AudioSampleGrid.ceilDiv5(range.end.ticks)
        guard e >= s else { throw TimeError.invalidRange(field: "AudioSampleRange") }   // end < start only
        return AudioSampleRange(uncheckedStart: s, end: e)
    }

    /// `true` when the range carries zero samples (`start == end`).
    public var isEmpty: Bool { end == start }

    /// The sample count (`end - start`), always `>= 0` (since `end >= start`); no overflow.
    public var sampleCount: Int64 { end - start }
}
