/// A non-negative **scene-local** playback instant, in 240,000-per-second ticks
/// (Task-002 plan, §4.1).
///
/// Scene-local time is measured from the scene's own start. During an animated transition the
/// outgoing scene's local time continues past its nominal duration at normal speed; the incoming
/// scene's local time is zero before the boundary and `T - boundary` at/after it.
public struct ScenePlaybackTime: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // >= 0

    public init(ticks: Int64) throws {
        guard ticks >= 0 else { throw TimeError.negativeValue(domain: "ScenePlaybackTime", value: ticks) }
        self.ticks = ticks
    }

    init(uncheckedTicks ticks: Int64) {
        self.ticks = ticks
    }

    public static let zero = ScenePlaybackTime(uncheckedTicks: 0)

    public static func < (lhs: ScenePlaybackTime, rhs: ScenePlaybackTime) -> Bool {
        lhs.ticks < rhs.ticks
    }

    /// `ScenePlaybackTime + TickDuration -> ScenePlaybackTime`, checked.
    public func adding(_ duration: TickDuration) throws -> ScenePlaybackTime {
        ScenePlaybackTime(uncheckedTicks: try CheckedInt64.add(ticks, duration.ticks, "ScenePlaybackTime.add"))
    }

    /// Explicit conversion from scene-local ticks to animation-local ticks (Task-002 plan, §4.1).
    ///
    /// In v1 the animation timeline shares the project tick grid; the conversion is the identity on
    /// raw ticks but is an explicit, type-changing operation so the two domains never mix silently.
    public func asAnimationPlaybackTime() -> AnimationPlaybackTime {
        AnimationPlaybackTime(uncheckedTicks: ticks)
    }
}

/// A half-open scene-local range `[start, end)` (Task-002 plan, §6.2).
public struct ScenePlaybackRange: Equatable, Sendable {
    public let start: ScenePlaybackTime
    public let end: ScenePlaybackTime             // exclusive; end > start

    public init(start: ScenePlaybackTime, end: ScenePlaybackTime) throws {
        guard end > start else { throw TimeError.invalidRange(field: "ScenePlaybackRange") }
        self.start = start
        self.end = end
    }

    /// Half-open containment: `start <= time < end`.
    public func contains(_ time: ScenePlaybackTime) -> Bool {
        time >= start && time < end
    }
}
