/// Typed errors for the exact-time and exact-rational core (Task-002 plan, §15.1).
///
/// `AnimiEngineCore` never traps on arithmetic overflow, never silently wraps, and never falls
/// back to `Float`/`Double`/`Decimal`. Every fallible time or rational operation throws one of
/// these cases instead.
public enum TimeError: Error, Equatable, Sendable {
    /// A non-negative-domain value (e.g. ``ProjectTime``, ``TickDuration``) was given a negative
    /// raw value.
    case negativeValue(domain: String, value: Int64)

    /// A denominator, timescale, or rate component that must be strictly positive was not.
    case nonPositiveDenominator(field: String, value: Int64)

    /// A checked `Int64` addition, subtraction, or multiplication overflowed.
    case integerOverflow(operation: String)

    /// A reduced rational's final numerator or denominator does not fit `Int64`.
    case rationalDoesNotFit

    /// An unsupported or invalid frame rate (no exact integer ticks-per-frame).
    case unsupportedFrameRate(numerator: Int64, denominator: Int64)

    /// A half-open range whose end is not strictly greater than its start.
    case invalidRange(field: String)

    /// A subtraction of instants where the left operand is smaller than the right.
    case negativeDifference(field: String)
}

/// Checked `Int64` arithmetic shared across the time and rational layers. Each operation throws
/// ``TimeError/integerOverflow(operation:)`` instead of trapping or wrapping (Task-002 plan,
/// §4.1, §15.1).
public enum CheckedInt64 {
    public static func add(_ a: Int64, _ b: Int64, _ operation: String = "add") throws -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        if overflow { throw TimeError.integerOverflow(operation: operation) }
        return result
    }

    public static func subtract(_ a: Int64, _ b: Int64, _ operation: String = "subtract") throws -> Int64 {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        if overflow { throw TimeError.integerOverflow(operation: operation) }
        return result
    }

    public static func multiply(_ a: Int64, _ b: Int64, _ operation: String = "multiply") throws -> Int64 {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        if overflow { throw TimeError.integerOverflow(operation: operation) }
        return result
    }
}
