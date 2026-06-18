/// A non-negative project-domain **duration** in 240,000-per-second ticks (Task-002 plan, §4.1).
///
/// Durations and instants are intentionally different types. A `TickDuration` is a length of time,
/// never a position on the timeline.
public struct TickDuration: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // >= 0

    /// Throws ``TimeError/negativeValue(domain:value:)`` if `ticks` is negative.
    public init(ticks: Int64) throws {
        guard ticks >= 0 else { throw TimeError.negativeValue(domain: "TickDuration", value: ticks) }
        self.ticks = ticks
    }

    /// The zero-length duration.
    public static let zero = TickDuration(uncheckedTicks: 0)

    /// Internal non-throwing constructor for already-validated values.
    init(uncheckedTicks ticks: Int64) {
        self.ticks = ticks
    }

    public static func < (lhs: TickDuration, rhs: TickDuration) -> Bool {
        lhs.ticks < rhs.ticks
    }

    /// Checked duration addition.
    public func adding(_ other: TickDuration) throws -> TickDuration {
        TickDuration(uncheckedTicks: try CheckedInt64.add(ticks, other.ticks, "TickDuration.add"))
    }

    /// Checked duration subtraction; throws if the result would be negative.
    public func subtracting(_ other: TickDuration) throws -> TickDuration {
        let result = try CheckedInt64.subtract(ticks, other.ticks, "TickDuration.subtract")
        guard result >= 0 else { throw TimeError.negativeDifference(field: "TickDuration.subtract") }
        return TickDuration(uncheckedTicks: result)
    }

    /// Checked multiplication by a non-negative integer factor.
    public func multiplied(by factor: Int64) throws -> TickDuration {
        guard factor >= 0 else { throw TimeError.negativeValue(domain: "TickDuration.factor", value: factor) }
        return TickDuration(uncheckedTicks: try CheckedInt64.multiply(ticks, factor, "TickDuration.multiply"))
    }
}
