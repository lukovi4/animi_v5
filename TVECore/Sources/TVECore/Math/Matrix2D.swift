import Foundation

// swiftlint:disable identifier_name

/// 2D affine transformation matrix
/// Represents transformations in homogeneous coordinates:
/// | a  b  tx |
/// | c  d  ty |
/// | 0  0  1  |
public struct Matrix2D: Equatable, Sendable {
    public let a: Double   // scale x
    public let b: Double   // skew y
    public let c: Double   // skew x
    public let d: Double   // scale y
    public let tx: Double  // translate x
    public let ty: Double  // translate y

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    /// Identity matrix (no transformation)
    public static let identity = Self(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// Creates a translation matrix
    public static func translation(x: Double, y: Double) -> Self {
        Self(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    /// Creates a scale matrix
    public static func scale(x: Double, y: Double) -> Self {
        Self(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0)
    }

    /// Creates a uniform scale matrix
    public static func scale(_ factor: Double) -> Self {
        scale(x: factor, y: factor)
    }

    /// Creates a rotation matrix (angle in radians)
    public static func rotation(_ radians: Double) -> Self {
        let cos = Darwin.cos(radians)
        let sin = Darwin.sin(radians)
        return Self(a: cos, b: sin, c: -sin, d: cos, tx: 0, ty: 0)
    }

    /// Creates a rotation matrix (angle in degrees)
    public static func rotationDegrees(_ degrees: Double) -> Self {
        rotation(degrees * .pi / 180.0)
    }

    /// Concatenates this matrix with another (self * other)
    /// Result applies other first, then self
    public func concatenating(_ other: Self) -> Self {
        Self(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: a * other.tx + b * other.ty + tx,
            ty: c * other.tx + d * other.ty + ty
        )
    }

    /// Applies this transformation to a point
    public func apply(to point: Vec2D) -> Vec2D {
        Vec2D(
            x: a * point.x + b * point.y + tx,
            y: c * point.x + d * point.y + ty
        )
    }

    /// Applies rotation and scale (but NOT translation) to a vector
    /// Used for transforming tangent vectors which are relative to their vertex
    public func applyToVector(_ vector: Vec2D) -> Vec2D {
        Vec2D(
            x: a * vector.x + b * vector.y,
            y: c * vector.x + d * vector.y
        )
    }

    /// Returns the inverse matrix, or nil if not invertible
    public var inverse: Self? {
        let det = a * d - b * c
        guard abs(det) > 1e-10 else { return nil }

        let invDet = 1.0 / det
        return Self(
            a: d * invDet,
            b: -b * invDet,
            c: -c * invDet,
            d: a * invDet,
            tx: (b * ty - d * tx) * invDet,
            ty: (c * tx - a * ty) * invDet
        )
    }
}

// MARK: - Approximate Equality

extension Matrix2D {
    /// Checks if two matrices are approximately equal within epsilon
    public func isApproximatelyEqual(to other: Self, epsilon: Double = 1e-6) -> Bool {
        abs(a - other.a) < epsilon &&
        abs(b - other.b) < epsilon &&
        abs(c - other.c) < epsilon &&
        abs(d - other.d) < epsilon &&
        abs(tx - other.tx) < epsilon &&
        abs(ty - other.ty) < epsilon
    }
}

// MARK: - Debug Description

extension Matrix2D: CustomDebugStringConvertible {
    public var debugDescription: String {
        "Matrix2D(a: \(a), b: \(b), c: \(c), d: \(d), tx: \(tx), ty: \(ty))"
    }
}

// swiftlint:enable identifier_name
