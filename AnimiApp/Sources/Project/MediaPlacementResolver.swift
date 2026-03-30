import Foundation
import TVECore

/// Pure resolver: converts `MediaPlacementState` + geometry → `Matrix2D`.
///
/// Used by both preview and export paths to guarantee placement parity.
/// No side effects, no runtime dependencies.
///
/// ## Transform formula
/// ```
/// final = T(offset) * T(center) * R(rotation) * S(userScale) * T(-center) * baseFit
/// center = center of slot rect
/// ```
///
/// `baseFit` scales and positions media to fit the slot according to `fitMode`.
public enum MediaPlacementResolver {

    /// Input geometry for resolution.
    public struct SlotGeometry: Equatable, Sendable {
        /// Slot rectangle in local block coordinates (from `mediaInput.rect`).
        public let slotRect: Rect
        /// Presentation-correct media size (after EXIF for photos, from `presentationInfo` for videos).
        public let mediaWidth: Double
        public let mediaHeight: Double

        public init(slotRect: Rect, mediaWidth: Double, mediaHeight: Double) {
            self.slotRect = slotRect
            self.mediaWidth = mediaWidth
            self.mediaHeight = mediaHeight
        }
    }

    // MARK: - Public API

    /// Resolves a `MediaPlacementState` into a `Matrix2D` for rendering.
    ///
    /// - Parameters:
    ///   - placement: The persisted placement state.
    ///   - geometry: Slot and media dimensions.
    /// - Returns: A `Matrix2D` suitable for `ScenePlayer.setUserTransform`.
    public static func resolve(
        placement: MediaPlacementState,
        geometry: SlotGeometry
    ) -> Matrix2D {
        let baseFit = baseFitTransform(
            fitMode: placement.fitMode,
            geometry: geometry
        )

        let snapped = snapRotation(placement.rotationDegrees)
        let radians = snapped * .pi / 180.0

        // Center of the slot rect (pivot for rotation/scale)
        let cx = geometry.slotRect.x + geometry.slotRect.width / 2.0
        let cy = geometry.slotRect.y + geometry.slotRect.height / 2.0

        // Build: T(offset) * T(center) * R(rotation) * S(userScale) * T(-center) * baseFit
        let tNegCenter = Matrix2D.translation(x: -cx, y: -cy)
        let scale = Matrix2D.scale(placement.userScale)
        let rotation = Matrix2D.rotation(radians)
        let tCenter = Matrix2D.translation(x: cx, y: cy)
        let tOffset = Matrix2D.translation(x: placement.offsetX, y: placement.offsetY)

        // Matrix concatenation: self.concatenating(other) = self * other
        // We need: tOffset * tCenter * rotation * scale * tNegCenter * baseFit
        // Build right to left:
        let m1 = tNegCenter.concatenating(baseFit)       // T(-center) * baseFit
        let m2 = scale.concatenating(m1)                   // S * T(-center) * baseFit
        let m3 = rotation.concatenating(m2)                // R * S * T(-center) * baseFit
        let m4 = tCenter.concatenating(m3)                 // T(center) * R * S * T(-center) * baseFit
        let m5 = tOffset.concatenating(m4)                 // T(offset) * T(center) * R * S * T(-center) * baseFit

        return m5
    }

    /// Resolves a default identity placement for the given fit mode.
    /// Equivalent to `resolve(placement: .default(fitMode:), geometry:)`.
    public static func resolveDefault(
        fitMode: FitMode,
        geometry: SlotGeometry
    ) -> Matrix2D {
        resolve(placement: .default(fitMode: fitMode), geometry: geometry)
    }

    // MARK: - Base Fit

    /// Computes the base fit transform that scales and centers media within the slot.
    ///
    /// - `cover`: scale to fill (may crop), centered
    /// - `contain`: scale to fit (may letterbox), centered
    /// - `fill`: stretch to fill exactly (non-uniform scale)
    public static func baseFitTransform(
        fitMode: FitMode,
        geometry: SlotGeometry
    ) -> Matrix2D {
        let slotW = geometry.slotRect.width
        let slotH = geometry.slotRect.height
        let mediaW = geometry.mediaWidth
        let mediaH = geometry.mediaHeight

        guard mediaW > 0, mediaH > 0, slotW > 0, slotH > 0 else {
            return .identity
        }

        let scaleX: Double
        let scaleY: Double

        switch fitMode {
        case .cover:
            let s = max(slotW / mediaW, slotH / mediaH)
            scaleX = s
            scaleY = s
        case .contain:
            let s = min(slotW / mediaW, slotH / mediaH)
            scaleX = s
            scaleY = s
        case .fill:
            scaleX = slotW / mediaW
            scaleY = slotH / mediaH
        }

        // Center the scaled media within the slot
        let scaledW = mediaW * scaleX
        let scaledH = mediaH * scaleY
        let tx = geometry.slotRect.x + (slotW - scaledW) / 2.0
        let ty = geometry.slotRect.y + (slotH - scaledH) / 2.0

        // Combined scale + translate
        return Matrix2D(
            a: scaleX, b: 0,
            c: 0, d: scaleY,
            tx: tx, ty: ty
        )
    }

    // MARK: - Rotation Snap

    /// Snaps rotation to nearest cardinal (0/90/180/270) if within threshold.
    /// - Parameters:
    ///   - degrees: Input rotation in degrees.
    ///   - threshold: Snap threshold in degrees (default: 4°).
    /// - Returns: Snapped rotation in degrees.
    public static func snapRotation(
        _ degrees: Double,
        threshold: Double = MediaPlacementState.snapThresholdDegrees
    ) -> Double {
        let cardinals: [Double] = [-180, -90, 0, 90, 180]
        for cardinal in cardinals {
            if abs(degrees - cardinal) <= threshold {
                return cardinal
            }
        }
        return degrees
    }
}
