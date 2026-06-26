/// Slice-004 Stage B — exact 48 kHz sample-time → canonical project-time mapping (ADR-006 §3/§4).
///
/// The Slice-1 grid (`AudioSampleGrid`) maps **project ticks → sample index** by `ceilDiv5`. The
/// realtime master clock needs the **inverse**: an audio render reports a sample index advanced since
/// the epoch anchor, and the scheduler must learn the canonical `ProjectTime` it represents (ADR-006
/// §3: *"derives project time from `AVAudioTime` sample time anchored to the epoch's project start"*).
///
/// That inverse is exact and lossless: the 48 kHz grid sits exactly on the 240,000-tick grid at
/// `5 ticks/sample` (ADR-006 §4), so sample `N` is exactly tick `5N` — no rounding, no `ceil`. Stage B
/// is pure integer math: no audio framework, no fractional/floating-point numeric type, fail-closed on
/// negative sample counts and on any multiply/add overflow (reusing the checked `CheckedInt64` core).
public enum SampleTimeMapping {

    /// Exactly five project ticks per canonical 48 kHz sample — reused from the Slice-1 grid so the
    /// forward (`ceilDiv5`) and inverse mappings can never disagree on the constant.
    public static var ticksPerSample: Int64 { AudioSampleGrid.ticksPerSample }

    /// The exact canonical tick **duration** of `sampleCount` 48 kHz samples (`sampleCount * 5`).
    ///
    /// Fail-closed: a negative `sampleCount` is a typed domain error; a product that does not fit
    /// `Int64` throws a typed overflow (never wraps, never falls back to floating point).
    public static func ticks(forSampleCount sampleCount: Int64) throws -> TickDuration {
        guard sampleCount >= 0 else {
            throw TimeError.negativeValue(domain: "SampleTimeMapping.sampleCount", value: sampleCount)
        }
        let rawTicks = try CheckedInt64.multiply(
            sampleCount, AudioSampleGrid.ticksPerSample, "SampleTimeMapping.ticks")
        return TickDuration(uncheckedTicks: rawTicks)
    }

    /// The canonical `ProjectTime` of a `sampleTime` (samples since the epoch anchor) measured from
    /// an `anchor` project time: `anchor + sampleTime * 5 ticks`.
    ///
    /// Fail-closed on a negative `sampleTime` and on any overflow in the multiply or the anchor add
    /// (the anchor add is the checked `ProjectTime.adding`). The result is exact for every
    /// non-negative `sampleTime` whose tick product and anchored sum fit `Int64`.
    public static func projectTime(
        anchor: ProjectTime,
        sampleTime: Int64
    ) throws -> ProjectTime {
        let advanced = try ticks(forSampleCount: sampleTime)
        return try anchor.adding(advanced)
    }
}
