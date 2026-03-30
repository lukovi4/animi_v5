import Foundation
import TVECore

/// Decomposes a `Matrix2D` into offset, uniform scale, and rotation.
/// Validates the result by rebuilding the SRT matrix and comparing with epsilon.
///
/// Used by `SceneStateMigrationHelper` to migrate legacy `userTransforms` into `MediaPlacementState`.
public enum Matrix2DDecomposer {

    /// Result of a successful decomposition.
    public struct Components: Equatable, Sendable {
        public let offsetX: Double
        public let offsetY: Double
        public let scale: Double
        public let rotationDegrees: Double
    }

    /// Errors from decomposition validation.
    public enum DecomposeError: Error, Equatable {
        case notFinite
        case notInvertible
        case hasShear
        case nonUniformScale
        case hasReflection
        case roundtripMismatch
    }

    // MARK: - Public API

    /// Attempts to decompose the matrix into SRT components.
    ///
    /// Validation steps:
    /// 1. All components finite
    /// 2. Invertible (det != 0)
    /// 3. No shear (pure rotation + uniform scale)
    /// 4. scaleX ≈ scaleY (uniform scale)
    /// 5. No reflection (det > 0)
    /// 6. Rebuild SRT matrix matches original within epsilon
    ///
    /// - Returns: Decomposed components
    /// - Throws: `DecomposeError` if matrix cannot be cleanly decomposed
    public static func decompose(
        _ matrix: Matrix2D,
        epsilon: Double = 1e-4
    ) throws -> Components {
        // 1. Finite check
        guard matrix.a.isFinite, matrix.b.isFinite,
              matrix.c.isFinite, matrix.d.isFinite,
              matrix.tx.isFinite, matrix.ty.isFinite else {
            throw DecomposeError.notFinite
        }

        // 2. Invertible check
        let det = matrix.a * matrix.d - matrix.b * matrix.c
        guard abs(det) > 1e-10 else {
            throw DecomposeError.notInvertible
        }

        // 5. No reflection (det must be positive for a rotation+scale matrix)
        guard det > 0 else {
            throw DecomposeError.hasReflection
        }

        // Extract scale from column vectors
        let scaleX = sqrt(matrix.a * matrix.a + matrix.c * matrix.c)
        let scaleY = sqrt(matrix.b * matrix.b + matrix.d * matrix.d)

        // 4. Uniform scale check
        guard abs(scaleX - scaleY) < epsilon else {
            throw DecomposeError.nonUniformScale
        }

        let scale = (scaleX + scaleY) / 2.0

        // Extract rotation from normalized first column
        // For a rotation matrix: a = cos*s, c = -sin*s (but our Matrix2D has b=sin, c=-sin)
        // Matrix layout: | a  b  tx |  where a=cos*s, b=sin*s, c=-sin*s, d=cos*s
        //                | c  d  ty |
        let rotationRadians = atan2(matrix.b, matrix.a)
        let rotationDeg = rotationRadians * 180.0 / .pi

        // 3. Shear check: verify the matrix is purely rotation+scale
        // For a clean rotation+scale matrix:
        //   a =  cos*s, b = sin*s
        //   c = -sin*s, d = cos*s
        let cosR = cos(rotationRadians)
        let sinR = sin(rotationRadians)
        let expectedA = cosR * scale
        let expectedB = sinR * scale
        let expectedC = -sinR * scale
        let expectedD = cosR * scale

        if abs(matrix.a - expectedA) > epsilon ||
           abs(matrix.b - expectedB) > epsilon ||
           abs(matrix.c - expectedC) > epsilon ||
           abs(matrix.d - expectedD) > epsilon {
            throw DecomposeError.hasShear
        }

        let components = Components(
            offsetX: matrix.tx,
            offsetY: matrix.ty,
            scale: scale,
            rotationDegrees: rotationDeg
        )

        // 6. Roundtrip validation: rebuild and compare
        let rebuilt = rebuildMatrix(from: components)
        guard rebuilt.isApproximatelyEqual(to: matrix, epsilon: epsilon) else {
            throw DecomposeError.roundtripMismatch
        }

        return components
    }

    // MARK: - Internal

    /// Rebuilds a Matrix2D from decomposed SRT components.
    /// Formula: T(offset) * R(rotation) * S(scale)
    static func rebuildMatrix(from c: Components) -> Matrix2D {
        let radians = c.rotationDegrees * .pi / 180.0
        let cosR = cos(radians)
        let sinR = sin(radians)
        return Matrix2D(
            a: cosR * c.scale,
            b: sinR * c.scale,
            c: -sinR * c.scale,
            d: cosR * c.scale,
            tx: c.offsetX,
            ty: c.offsetY
        )
    }
}
