import Foundation

/// Wall (calendar) time source. Used **only** for the run manifest's start/end timestamps
/// (Task-001 plan, "Clocks & identity").
///
/// Production wires a real implementation; tests wire a deterministic fake so every manifest byte
/// is stable. No logic reads `Date()`/`Date.now` directly.
public protocol WallClock: Sendable {
    /// The current wall-clock instant.
    func now() -> Date
}

/// Monotonic instant source. Each `DiagnosticEvent` stores **elapsed monotonic time** (ns since
/// run start), never wall time (Task-001 plan, "Clocks & identity").
///
/// The unit of `nanoseconds()` is an opaque monotonic counter; only *differences* are meaningful.
public protocol MonotonicClock: Sendable {
    /// A monotonically non-decreasing instant, in nanoseconds.
    func nanoseconds() -> UInt64
}

// MARK: - Production implementations

/// Real wall clock backed by `Date()`.
public struct SystemWallClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Real monotonic clock backed by `DispatchTime.now().uptimeNanoseconds`.
public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public func nanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
