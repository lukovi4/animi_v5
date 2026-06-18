/// A non-negative **instant** on the master project timeline, in 240,000-per-second ticks
/// (Task-002 plan, §4.1).
///
/// Instants and durations are different types. `ProjectTime` is a position; ``TickDuration`` is a
/// length. The only arithmetic between them is type-directed:
///
/// - `ProjectTime + TickDuration -> ProjectTime`
/// - `ProjectTime - ProjectTime -> TickDuration` (only when left >= right)
public struct ProjectTime: Hashable, Comparable, Sendable {
    public let ticks: Int64                 // >= 0

    public init(ticks: Int64) throws {
        guard ticks >= 0 else { throw TimeError.negativeValue(domain: "ProjectTime", value: ticks) }
        self.ticks = ticks
    }

    init(uncheckedTicks ticks: Int64) {
        self.ticks = ticks
    }

    public static let zero = ProjectTime(uncheckedTicks: 0)

    public static func < (lhs: ProjectTime, rhs: ProjectTime) -> Bool {
        lhs.ticks < rhs.ticks
    }

    /// `ProjectTime + TickDuration -> ProjectTime`, checked.
    public func adding(_ duration: TickDuration) throws -> ProjectTime {
        ProjectTime(uncheckedTicks: try CheckedInt64.add(ticks, duration.ticks, "ProjectTime.add"))
    }

    /// `ProjectTime - TickDuration -> ProjectTime`, checked; throws if the result is negative.
    public func subtracting(_ duration: TickDuration) throws -> ProjectTime {
        let result = try CheckedInt64.subtract(ticks, duration.ticks, "ProjectTime.subtractDuration")
        guard result >= 0 else { throw TimeError.negativeDifference(field: "ProjectTime.subtractDuration") }
        return ProjectTime(uncheckedTicks: result)
    }

    /// `ProjectTime - ProjectTime -> TickDuration`, only when `self >= other`.
    public func distance(to later: ProjectTime) throws -> TickDuration {
        let result = try CheckedInt64.subtract(later.ticks, ticks, "ProjectTime.distance")
        guard result >= 0 else { throw TimeError.negativeDifference(field: "ProjectTime.distance") }
        return TickDuration(uncheckedTicks: result)
    }
}

/// A half-open project-time range `[start, end)` (Task-002 plan, §2, §6.1).
public struct ProjectTimeRange: Equatable, Sendable {
    public let start: ProjectTime
    public let end: ProjectTime             // exclusive; end > start

    public init(start: ProjectTime, end: ProjectTime) throws {
        guard end > start else { throw TimeError.invalidRange(field: "ProjectTimeRange") }
        self.start = start
        self.end = end
    }

    /// The (checked) length of the range.
    public var duration: TickDuration {
        get throws { try start.distance(to: end) }
    }

    /// Half-open containment: `start <= time < end`.
    public func contains(_ time: ProjectTime) -> Bool {
        time >= start && time < end
    }
}
