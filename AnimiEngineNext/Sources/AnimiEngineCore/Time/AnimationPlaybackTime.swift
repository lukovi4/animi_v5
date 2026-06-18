/// A non-negative **animation-local** playback instant, in 240,000-per-second ticks
/// (Task-002 plan, §4.1, §6.3).
///
/// Animation-local time is the input to a template animation sampler. It is produced explicitly
/// from scene-local or overlay-local time so the domains never mix silently.
public struct AnimationPlaybackTime: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // >= 0

    public init(ticks: Int64) throws {
        guard ticks >= 0 else { throw TimeError.negativeValue(domain: "AnimationPlaybackTime", value: ticks) }
        self.ticks = ticks
    }

    init(uncheckedTicks ticks: Int64) {
        self.ticks = ticks
    }

    public static let zero = AnimationPlaybackTime(uncheckedTicks: 0)

    public static func < (lhs: AnimationPlaybackTime, rhs: AnimationPlaybackTime) -> Bool {
        lhs.ticks < rhs.ticks
    }
}
