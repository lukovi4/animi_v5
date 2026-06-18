/// A scale scalar in fixed point: **1,000,000 raw units per 1.0** (Task-002 plan, §5).
public struct ScaleScalar: Hashable, Comparable, Sendable {
    /// Raw units; 1,000,000 per 1.0.
    public let rawValue: Int64

    public static let unitsPerUnit: Int64 = 1_000_000

    /// The identity scale (1.0).
    public static let one = ScaleScalar(rawValue: unitsPerUnit)

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Constructs a strictly-positive scale, checked. Used where a non-positive scale is invalid.
    public init(positiveRawValue rawValue: Int64) throws {
        guard rawValue > 0 else { throw TimeError.negativeValue(domain: "ScaleScalar.positive", value: rawValue) }
        self.rawValue = rawValue
    }

    public static func < (lhs: ScaleScalar, rhs: ScaleScalar) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
