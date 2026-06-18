import AnimiEngineCore

/// Task-003 plan §5.4, D3-08 — render-only checked fixed-point and rational value types.
///
/// Canonical project time and geometry keep using the Task-002 types (`CanvasScalar`, `ScaleScalar`,
/// `RotationScalar`, `RationalSourceTime`, …). This file adds the *render-only* numeric values §5.4
/// introduces that have no Task-002 owner:
///
///   * `UnitInterval`     — a clamped `[0, 1]` quantity (transition progress, normalized factors),
///                          1,000,000 raw units per 1.0;
///   * `OpacityScalar`    — layer/overlay opacity in `[0, 1]`, 1,000,000 raw units per 1.0;
///   * `NormalizedColorComponent` — a colour component in `[0, 1]`, fixed-point, before any Metal
///                          `Float` conversion (which happens only at the executor upload boundary).
///
/// There is **no `Float`/`Double` in canonical render state** (D3-08, §5.4). All values are checked
/// `Int64` fixed-point; construction rejects out-of-range raw values with a typed
/// ``RenderModelError``. Conversion *from* authoring `Double` is an adapter-boundary concern (§17
/// step 7) and is intentionally absent here.

/// A fixed-point quantity confined to the closed interval `[0, 1]`, 1,000,000 raw units per 1.0.
public struct UnitInterval: Hashable, Comparable, Sendable {
    /// Raw units; `0 ... unitsPerUnit`.
    public let rawValue: Int64

    public static let unitsPerUnit: Int64 = 1_000_000
    public static let zero = UnitInterval(unchecked: 0)
    public static let one = UnitInterval(unchecked: unitsPerUnit)

    private init(unchecked rawValue: Int64) { self.rawValue = rawValue }

    /// Constructs from raw fixed-point units, rejecting values outside `0 ... unitsPerUnit`.
    public init(rawValue: Int64) throws {
        guard rawValue >= 0, rawValue <= Self.unitsPerUnit else {
            throw RenderModelError.valueOutOfRange(
                field: "UnitInterval", value: rawValue, lowerBound: 0, upperBound: Self.unitsPerUnit)
        }
        self.rawValue = rawValue
    }

    public static func < (lhs: UnitInterval, rhs: UnitInterval) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Layer/overlay opacity in `[0, 1]`, 1,000,000 raw units per 1.0. Distinct nominal type from
/// `UnitInterval` so opacity and a generic factor are not silently interchangeable.
public struct OpacityScalar: Hashable, Comparable, Sendable {
    public let rawValue: Int64

    public static let unitsPerUnit: Int64 = 1_000_000
    public static let opaque = OpacityScalar(unchecked: unitsPerUnit)
    public static let transparent = OpacityScalar(unchecked: 0)

    private init(unchecked rawValue: Int64) { self.rawValue = rawValue }

    public init(rawValue: Int64) throws {
        guard rawValue >= 0, rawValue <= Self.unitsPerUnit else {
            throw RenderModelError.valueOutOfRange(
                field: "OpacityScalar", value: rawValue, lowerBound: 0, upperBound: Self.unitsPerUnit)
        }
        self.rawValue = rawValue
    }

    public static func < (lhs: OpacityScalar, rhs: OpacityScalar) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A single colour component in `[0, 1]`, fixed-point with 1,000,000 raw units per 1.0. This is the
/// canonical-state representation; conversion to a Metal `Float` happens only at the executor upload
/// boundary and never returns to canonical or graph state (§5.4).
public struct NormalizedColorComponent: Hashable, Comparable, Sendable {
    public let rawValue: Int64

    public static let unitsPerUnit: Int64 = 1_000_000
    public static let zero = NormalizedColorComponent(unchecked: 0)
    public static let one = NormalizedColorComponent(unchecked: unitsPerUnit)

    private init(unchecked rawValue: Int64) { self.rawValue = rawValue }

    public init(rawValue: Int64) throws {
        guard rawValue >= 0, rawValue <= Self.unitsPerUnit else {
            throw RenderModelError.valueOutOfRange(
                field: "NormalizedColorComponent", value: rawValue,
                lowerBound: 0, upperBound: Self.unitsPerUnit)
        }
        self.rawValue = rawValue
    }

    public static func < (lhs: NormalizedColorComponent, rhs: NormalizedColorComponent) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// An authored frame/time mapping expressed as an exact rational (§5.4: "authored frame/time mapping:
/// exact rational values"). Reuses the Task-002 exact-rational engine; here it carries render-model
/// authored-time semantics without introducing any floating point.
public typealias AuthoredRationalTime = RationalSourceTime

/// A dedicated dimensionless fixed-point quantity for **easing tangents**, 1,000,000 raw units per
/// 1.0 (Stage-6 correction item 2). Distinct nominal type so an easing component is never silently
/// interchanged with a canvas coordinate or a scale. Unlike the `[0,1]` types it is unbounded (easing
/// handles can lie outside the unit square), so any `Int64` raw value is admissible.
public struct EasingScalar: Hashable, Comparable, Sendable {
    public let rawValue: Int64
    public static let unitsPerUnit: Int64 = 1_000_000
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public static func < (lhs: EasingScalar, rhs: EasingScalar) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A dedicated dimensionless fixed-point quantity for a stroke **miter limit**, 1,000,000 raw units
/// per 1.0 (Stage-6 correction item 2). Distinct nominal type from canvas/scale/easing.
public struct MiterScalar: Hashable, Comparable, Sendable {
    public let rawValue: Int64
    public static let unitsPerUnit: Int64 = 1_000_000
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public static func < (lhs: MiterScalar, rhs: MiterScalar) -> Bool { lhs.rawValue < rhs.rawValue }
}
