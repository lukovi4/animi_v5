import Foundation

/// 2D size with double precision
public struct SizeD: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Self(width: 0, height: 0)
}

/// 2D rectangle with double precision
public struct RectD: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: Vec2D, size: SizeD) {
        self.x = origin.x
        self.y = origin.y
        self.width = size.width
        self.height = size.height
    }

    public var origin: Vec2D { Vec2D(x: x, y: y) }
    public var size: SizeD { SizeD(width: width, height: height) }

    public static let zero = Self(x: 0, y: 0, width: 0, height: 0)
}

/// 2D vector with double precision
public struct Vec2D: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Self(x: 0, y: 0)
}

// MARK: - Geometry Mapping

/// Provides geometry transformation utilities for animation rendering
public enum GeometryMapping {
    /// Returns matrix that maps animation local space (0..w, 0..h) into inputRect local space
    /// using contain policy with centering.
    ///
    /// Policy: Scale uniformly to fit inside inputRect while preserving aspect ratio,
    /// then center the result within inputRect.
    ///
    /// - Parameters:
    ///   - animSize: Size of the animation in its local coordinate space
    ///   - inputRect: Target rectangle to fit the animation into
    /// - Returns: Transformation matrix from anim space to inputRect space
    public static func animToInputContain(animSize: SizeD, inputRect: RectD) -> Matrix2D {
        // Handle edge cases
        guard animSize.width > 0, animSize.height > 0 else {
            return .translation(x: inputRect.x, y: inputRect.y)
        }
        guard inputRect.width > 0, inputRect.height > 0 else {
            return .translation(x: inputRect.x, y: inputRect.y)
        }

        // Calculate uniform scale to fit (contain policy)
        let scaleX = inputRect.width / animSize.width
        let scaleY = inputRect.height / animSize.height
        let scale = min(scaleX, scaleY)

        // Calculate scaled dimensions
        let scaledWidth = animSize.width * scale
        let scaledHeight = animSize.height * scale

        // Calculate centering offset within inputRect
        let dx = inputRect.x + (inputRect.width - scaledWidth) / 2.0
        let dy = inputRect.y + (inputRect.height - scaledHeight) / 2.0

        // Result: Translate(dx, dy) * Scale(scale, scale)
        // Matrix multiplication order: first scale, then translate
        return Matrix2D(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: dx,
            ty: dy
        )
    }
}

// MARK: - Rect Conversion

extension RectD {
    /// Creates RectD from the existing Rect type
    public init(from rect: Rect) {
        self.x = rect.x
        self.y = rect.y
        self.width = rect.width
        self.height = rect.height
    }
}
