import Foundation
import AnimiEngineDiagnostics

/// Deterministic `WallClock` returning a fixed, scriptable sequence of dates.
///
/// Each call to `now()` returns the next scripted date (the last value repeats once exhausted),
/// so manifests are byte-stable under test (Task-001 plan, "Clocks & identity").
public final class TestWallClock: WallClock, @unchecked Sendable {
    private let dates: [Date]
    private var index = 0

    /// - Parameter dates: the scripted sequence; must be non-empty.
    public init(dates: [Date]) {
        precondition(!dates.isEmpty, "TestWallClock requires at least one date")
        self.dates = dates
    }

    public func now() -> Date {
        defer { if index < dates.count - 1 { index += 1 } }
        return dates[index]
    }
}

/// Deterministic `MonotonicClock` returning a fixed, scriptable sequence of nanosecond counters.
public final class TestMonotonicClock: MonotonicClock, @unchecked Sendable {
    private let values: [UInt64]
    private var index = 0

    /// - Parameter values: the scripted sequence; must be non-empty and non-decreasing.
    public init(values: [UInt64]) {
        precondition(!values.isEmpty, "TestMonotonicClock requires at least one value")
        self.values = values
    }

    public func nanoseconds() -> UInt64 {
        defer { if index < values.count - 1 { index += 1 } }
        return values[index]
    }
}

/// Deterministic `IDGenerator` returning a fixed, scriptable sequence of run ids.
public final class TestIDGenerator: IDGenerator, @unchecked Sendable {
    private let ids: [String]
    private var index = 0

    /// - Parameter ids: the scripted sequence; must be non-empty.
    public init(ids: [String]) {
        precondition(!ids.isEmpty, "TestIDGenerator requires at least one id")
        self.ids = ids
    }

    public func makeRunID() -> BenchmarkRunID {
        defer { if index < ids.count - 1 { index += 1 } }
        return BenchmarkRunID(rawValue: ids[index])
    }
}
