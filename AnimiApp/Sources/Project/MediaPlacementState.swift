import Foundation
import TVECore

/// Persisted placement state for user media within a slot.
/// Replaces raw `Matrix2D` in `userTransforms` for media blocks.
public struct MediaPlacementState: Codable, Equatable, Sendable {

    /// How media fits the slot (cover/contain/fill).
    public var fitMode: FitMode

    /// User pan offset in slot-local points.
    public var offsetX: Double

    /// User pan offset in slot-local points.
    public var offsetY: Double

    /// User scale factor relative to base fit. Clamped to `scaleRange`.
    public var userScale: Double

    /// User rotation in degrees, normalized to `(-180, 180]`.
    public var rotationDegrees: Double

    // MARK: - Constants

    public static let scaleRange: ClosedRange<Double> = 0.25...6.0
    public static let defaultScale: Double = 1.0
    public static let snapThresholdDegrees: Double = 4.0

    // MARK: - Initialization

    public init(
        fitMode: FitMode,
        offsetX: Double = 0,
        offsetY: Double = 0,
        userScale: Double = defaultScale,
        rotationDegrees: Double = 0
    ) {
        self.fitMode = fitMode
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.userScale = Self.clampScale(userScale)
        self.rotationDegrees = Self.normalizeRotation(rotationDegrees)
    }

    // MARK: - Factories

    /// Default placement for a given fit mode (identity transform).
    public static func `default`(fitMode: FitMode) -> MediaPlacementState {
        MediaPlacementState(fitMode: fitMode)
    }

    /// Default placement with the standard cover fit mode.
    public static let defaultCover = MediaPlacementState(fitMode: .cover)

    // MARK: - Queries

    /// Whether this placement is the identity (no user modifications beyond fit mode).
    public var isDefault: Bool {
        offsetX == 0 && offsetY == 0
            && userScale == Self.defaultScale
            && rotationDegrees == 0
    }

    /// Epsilon-based check for UI purposes (reset button visibility).
    /// Thresholds: offset 1e-6, scale 1e-6, rotationDegrees 1e-4.
    public var isNearDefault: Bool {
        abs(offsetX) < 1e-6 && abs(offsetY) < 1e-6
            && abs(userScale - Self.defaultScale) < 1e-6
            && abs(rotationDegrees) < 1e-4
    }

    // MARK: - Normalization

    /// Clamps scale to allowed range.
    public static func clampScale(_ scale: Double) -> Double {
        min(max(scale, scaleRange.lowerBound), scaleRange.upperBound)
    }

    /// Normalizes rotation to `(-180, 180]`.
    public static func normalizeRotation(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}
