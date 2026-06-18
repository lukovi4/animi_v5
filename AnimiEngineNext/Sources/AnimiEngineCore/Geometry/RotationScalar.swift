/// A rotation scalar in fixed point: **1,000 raw units per degree** (Task-002 plan, §5).
public struct RotationScalar: Hashable, Comparable, Sendable {
    /// Raw units; 1,000 per degree.
    public let rawValue: Int64

    public static let unitsPerDegree: Int64 = 1_000

    public static let zero = RotationScalar(rawValue: 0)

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: RotationScalar, rhs: RotationScalar) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
