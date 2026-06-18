/// A **signed** time relative to a transition boundary `B`, in 240,000-per-second ticks
/// (Task-002 plan, §4.1, §7.2).
///
/// Negative values are before the boundary; non-negative values are at or after it. This is the
/// only timeline type that is intentionally signed, because it expresses an offset, not a position.
public struct TransitionRelativeTime: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // signed, relative to boundary B

    public init(ticks: Int64) {
        self.ticks = ticks
    }

    public static func < (lhs: TransitionRelativeTime, rhs: TransitionRelativeTime) -> Bool {
        lhs.ticks < rhs.ticks
    }
}
