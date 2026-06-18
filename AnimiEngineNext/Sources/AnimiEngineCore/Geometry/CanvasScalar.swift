/// A canvas-space scalar in fixed point: **65,536 raw units per canvas point**
/// (Task-002 plan, §5).
///
/// All canonical persisted geometry is fixed-point `Int64`; conversion from authoring `Double`
/// belongs to a future adapter, never the core.
public struct CanvasScalar: Hashable, Comparable, Sendable {
    /// Raw units; 65,536 per canvas point.
    public let rawValue: Int64

    public static let unitsPerPoint: Int64 = 65_536

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Constructs from a whole number of canvas points, checked.
    public init(points: Int64) throws {
        rawValue = try CheckedInt64.multiply(points, Self.unitsPerPoint, "CanvasScalar.points")
    }

    public static func < (lhs: CanvasScalar, rhs: CanvasScalar) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func adding(_ other: CanvasScalar) throws -> CanvasScalar {
        CanvasScalar(rawValue: try CheckedInt64.add(rawValue, other.rawValue, "CanvasScalar.add"))
    }

    public func subtracting(_ other: CanvasScalar) throws -> CanvasScalar {
        CanvasScalar(rawValue: try CheckedInt64.subtract(rawValue, other.rawValue, "CanvasScalar.subtract"))
    }
}
