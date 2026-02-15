import Foundation
@testable import TVECore

// MARK: - Lottie Rotation Convention Helper

/// Lottie/AE uses Y-down where positive rotation is clockwise.
/// Our Matrix2D.rotationDegrees assumes math convention (positive = CCW in Y-up).
/// Convert Lottie degrees to Matrix2D degrees by negating.
func lottieRotationDegrees(_ degrees: Double) -> Matrix2D {
    .rotationDegrees(-degrees)
}
