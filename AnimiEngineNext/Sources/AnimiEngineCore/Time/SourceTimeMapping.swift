/// A half-open rational source range `[start, end)` (Task-002 plan, §4.2).
public struct RationalSourceRange: Hashable, Sendable {
    public let start: RationalSourceTime
    public let end: RationalSourceTime         // exclusive; end > start

    public init(start: RationalSourceTime, end: RationalSourceTime) throws {
        guard start < end else { throw TimeError.invalidRange(field: "RationalSourceRange") }
        self.start = start
        self.end = end
    }

    /// Half-open containment: `start <= target < end`.
    public func contains(_ target: RationalSourceTime) -> Bool {
        target >= start && target < end
    }
}

/// Maps scene-local playback time to an **exact** rational source presentation time
/// (Task-002 plan, §4.2).
///
/// For scene ticks `s`, rate `rn/rd`, and trim start `a`:
///
///     target = a + (rn * s) / (rd * 240000)
///
/// The result is a normalized exact rational. It is **never** rounded onto `nativeTimescale`.
public struct SourceTimeMapping: Equatable, Sendable {
    public let trimRange: RationalSourceRange
    public let nativeTimescale: SourceTimescale
    public let rate: PlaybackRate               // 1/1 in v1

    public init(trimRange: RationalSourceRange, nativeTimescale: SourceTimescale, rate: PlaybackRate) {
        self.trimRange = trimRange
        self.nativeTimescale = nativeTimescale
        self.rate = rate
    }

    /// The exact rational source target for a scene-local instant.
    ///
    /// `target = trimStart + (rn/rd) · (s/240000)` (corrective plan C-3). The delta is built by
    /// **composing** rational multiplication and addition, so `rn·s` is never pre-multiplied as raw
    /// `Int64` — avoidable intermediate overflow cannot occur even when `rn·s` would exceed `Int64`,
    /// as long as the final reduced target fits.
    public func target(for sceneTime: ScenePlaybackTime) throws -> RationalSourceTime {
        let ratePart = try RationalSourceTime(numerator: rate.numerator, denominator: rate.denominator)
        let scenePart = try RationalSourceTime(numerator: sceneTime.ticks, denominator: TickClock.ticksPerSecond)
        let delta = try ratePart.multiplied(by: scenePart)
        return try trimRange.start.adding(delta)
    }
}
