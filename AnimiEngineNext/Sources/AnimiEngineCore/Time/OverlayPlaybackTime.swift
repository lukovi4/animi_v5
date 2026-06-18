/// A non-negative **overlay-local** playback instant, in 240,000-per-second ticks
/// (Task-002 plan, §4.1, §6.4).
///
/// Overlay-local time is measured from the overlay's own project-time start. It is produced
/// explicitly from a project-local delta and can be converted explicitly to animation-local time.
public struct OverlayPlaybackTime: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // >= 0

    public init(ticks: Int64) throws {
        guard ticks >= 0 else { throw TimeError.negativeValue(domain: "OverlayPlaybackTime", value: ticks) }
        self.ticks = ticks
    }

    init(uncheckedTicks ticks: Int64) {
        self.ticks = ticks
    }

    public static let zero = OverlayPlaybackTime(uncheckedTicks: 0)

    public static func < (lhs: OverlayPlaybackTime, rhs: OverlayPlaybackTime) -> Bool {
        lhs.ticks < rhs.ticks
    }

    /// Explicit conversion from a project-local delta to overlay-local ticks (Task-002 plan, §4.1).
    ///
    /// The delta is the gap between the overlay's project-time start and the evaluated project
    /// time; it is already non-negative as a ``TickDuration``.
    public static func from(projectLocalDelta delta: TickDuration) -> OverlayPlaybackTime {
        OverlayPlaybackTime(uncheckedTicks: delta.ticks)
    }

    /// Explicit conversion from overlay-local ticks to animation-local ticks (Task-002 plan, §4.1).
    public func asAnimationPlaybackTime() -> AnimationPlaybackTime {
        AnimationPlaybackTime(uncheckedTicks: ticks)
    }
}
