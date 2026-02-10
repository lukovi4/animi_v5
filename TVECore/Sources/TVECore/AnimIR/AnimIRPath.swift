import CoreGraphics
import Foundation

// MARK: - Cubic Bezier Easing

/// Solves cubic bezier easing curve for animation timing
/// Uses Newton-Raphson iteration with binary subdivision fallback
/// Guarantees output in [0,1] range without NaN for any input
public enum CubicBezierEasing {
    /// Maximum iterations for Newton-Raphson
    private static let maxIterations = 8

    /// Convergence threshold
    private static let epsilon: Double = 1e-6

    /// Minimum derivative for Newton-Raphson (below this, use bisection)
    private static let minDerivative: Double = 1e-6

    /// Solves the bezier curve to find the Y value for a given X (time) value
    /// - Parameters:
    ///   - x: Input time value (0.0 to 1.0)
    ///   - x1: First control point X
    ///   - y1: First control point Y
    ///   - x2: Second control point X
    ///   - y2: Second control point Y
    /// - Returns: Eased progress value (0.0 to 1.0), guaranteed without NaN
    public static func solve(x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        // Clamp input to [0, 1]
        let clampedX = max(0, min(1, x))

        // Handle edge cases
        if clampedX <= 0 { return 0 }
        if clampedX >= 1 { return 1 }

        // Clamp control points to valid range [0, 1] for X
        let cx1 = max(0, min(1, x1))
        let cx2 = max(0, min(1, x2))

        // Linear case or degenerate case (both control points at same X)
        if (cx1 == y1 && cx2 == y2) || (cx1 == 0 && cx2 == 0) || (cx1 == 1 && cx2 == 1) {
            return clampedX
        }

        // Find t for given x using Newton-Raphson with bisection fallback
        let t = solveCurveX(x: clampedX, x1: cx1, x2: cx2)

        // Calculate y for found t and clamp output
        let y = bezierY(t: t, y1: y1, y2: y2)

        // Final safety clamp and NaN check
        if y.isNaN || y.isInfinite {
            return clampedX // Fallback to linear
        }

        return max(0, min(1, y))
    }

    /// Solves for t given x using Newton-Raphson with binary subdivision fallback
    private static func solveCurveX(x: Double, x1: Double, x2: Double) -> Double {
        var t = x // Initial guess

        // Newton-Raphson iteration
        for _ in 0..<maxIterations {
            let currentX = bezierX(t: t, x1: x1, x2: x2)
            let error = currentX - x

            if abs(error) < epsilon {
                return max(0, min(1, t))
            }

            let derivative = bezierXDerivative(t: t, x1: x1, x2: x2)

            // If derivative is too small, switch to bisection
            if abs(derivative) < minDerivative {
                return bisectionSolve(x: x, x1: x1, x2: x2)
            }

            t -= error / derivative
            t = max(0, min(1, t))
        }

        // If Newton-Raphson didn't converge, use bisection as final fallback
        return max(0, min(1, t))
    }

    /// Binary subdivision fallback for degenerate curves
    private static func bisectionSolve(x: Double, x1: Double, x2: Double) -> Double {
        var low = 0.0
        var high = 1.0

        for _ in 0..<maxIterations {
            let mid = (low + high) / 2
            let currentX = bezierX(t: mid, x1: x1, x2: x2)

            if abs(currentX - x) < epsilon {
                return mid
            }

            if currentX < x {
                low = mid
            } else {
                high = mid
            }
        }

        return (low + high) / 2
    }

    /// Bezier curve X component: B(t) = 3(1-t)²t·x1 + 3(1-t)t²·x2 + t³
    private static func bezierX(t: Double, x1: Double, x2: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        let mt = 1 - t
        let mt2 = mt * mt
        return 3 * mt2 * t * x1 + 3 * mt * t2 * x2 + t3
    }

    /// Bezier curve Y component: B(t) = 3(1-t)²t·y1 + 3(1-t)t²·y2 + t³
    private static func bezierY(t: Double, y1: Double, y2: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        let mt = 1 - t
        let mt2 = mt * mt
        return 3 * mt2 * t * y1 + 3 * mt * t2 * y2 + t3
    }

    /// Derivative of bezier X: dB/dt
    private static func bezierXDerivative(t: Double, x1: Double, x2: Double) -> Double {
        let mt = 1 - t
        return 3 * mt * mt * x1 + 6 * mt * t * (x2 - x1) + 3 * t * t * (1 - x2)
    }
}

// MARK: - Bezier Path

/// Render-agnostic bezier path representation
public struct BezierPath: Sendable, Equatable, Codable {
    /// Path vertices (control points)
    public let vertices: [Vec2D]

    /// In tangents (relative to vertex)
    public let inTangents: [Vec2D]

    /// Out tangents (relative to vertex)
    public let outTangents: [Vec2D]

    /// Whether the path is closed
    public let closed: Bool

    public init(vertices: [Vec2D], inTangents: [Vec2D], outTangents: [Vec2D], closed: Bool) {
        self.vertices = vertices
        self.inTangents = inTangents
        self.outTangents = outTangents
        self.closed = closed
    }

    /// Creates an empty path
    public static let empty = Self(vertices: [], inTangents: [], outTangents: [], closed: false)

    /// Number of vertices in the path
    public var vertexCount: Int {
        vertices.count
    }

    /// Returns true if the path has no vertices
    public var isEmpty: Bool {
        vertices.isEmpty
    }

    /// Axis-aligned bounding box of the path vertices (minX, minY, maxX, maxY)
    public var aabb: (minX: Double, minY: Double, maxX: Double, maxY: Double) { // swiftlint:disable:this large_tuple
        guard !vertices.isEmpty else {
            return (0, 0, 0, 0)
        }
        var minX = vertices[0].x
        var minY = vertices[0].y
        var maxX = vertices[0].x
        var maxY = vertices[0].y
        for vertex in vertices.dropFirst() {
            minX = min(minX, vertex.x)
            minY = min(minY, vertex.y)
            maxX = max(maxX, vertex.x)
            maxY = max(maxY, vertex.y)
        }
        return (minX, minY, maxX, maxY)
    }

    /// Returns a new path with all vertices and tangents transformed by the given matrix
    public func applying(_ matrix: Matrix2D) -> BezierPath {
        // If identity matrix, return self unchanged
        if matrix == .identity {
            return self
        }

        let transformedVertices = vertices.map { matrix.apply(to: $0) }
        let transformedInTangents = inTangents.map { matrix.applyToVector($0) }
        let transformedOutTangents = outTangents.map { matrix.applyToVector($0) }

        return BezierPath(
            vertices: transformedVertices,
            inTangents: transformedInTangents,
            outTangents: transformedOutTangents,
            closed: closed
        )
    }

    /// Interpolates between two paths vertex-by-vertex
    /// Requires paths to have matching topology (same vertex count and closed flag)
    /// - Parameters:
    ///   - other: Target path to interpolate towards
    ///   - t: Interpolation factor (0.0 = self, 1.0 = other)
    /// - Returns: Interpolated path, or nil if topology doesn't match
    public func interpolated(to other: BezierPath, t: Double) -> BezierPath? {
        // Topology must match
        guard vertices.count == other.vertices.count,
              closed == other.closed else {
            return nil
        }

        // Handle edge cases
        if t <= 0 { return self }
        if t >= 1 { return other }

        // Interpolate all components
        let interpVertices = zip(vertices, other.vertices).map { v0, v1 in
            Vec2D(x: lerp(v0.x, v1.x, t), y: lerp(v0.y, v1.y, t))
        }

        let interpInTangents = zip(inTangents, other.inTangents).map { t0, t1 in
            Vec2D(x: lerp(t0.x, t1.x, t), y: lerp(t0.y, t1.y, t))
        }

        let interpOutTangents = zip(outTangents, other.outTangents).map { t0, t1 in
            Vec2D(x: lerp(t0.x, t1.x, t), y: lerp(t0.y, t1.y, t))
        }

        return BezierPath(
            vertices: interpVertices,
            inTangents: interpInTangents,
            outTangents: interpOutTangents,
            closed: closed
        )
    }
}

// MARK: - Animated Path

/// Path that can be static or animated
public enum AnimPath: Sendable, Equatable, Codable {
    /// Static (non-animated) bezier path
    case staticBezier(BezierPath)

    /// Keyframed bezier path animation with easing support
    case keyframedBezier([Keyframe<BezierPath>])

    /// Returns the static path or first keyframe value
    public var staticPath: BezierPath? {
        switch self {
        case .staticBezier(let path):
            return path
        case .keyframedBezier(let keyframes):
            return keyframes.first?.value
        }
    }

    /// Returns true if this path is animated
    public var isAnimated: Bool {
        switch self {
        case .staticBezier:
            return false
        case .keyframedBezier(let keyframes):
            return keyframes.count > 1
        }
    }

    /// Returns a new AnimPath with all paths transformed by the given matrix
    public func applying(_ matrix: Matrix2D) -> AnimPath {
        if matrix == .identity {
            return self
        }

        switch self {
        case .staticBezier(let path):
            return .staticBezier(path.applying(matrix))
        case .keyframedBezier(let keyframes):
            let transformedKeyframes = keyframes.map { kf in
                Keyframe(
                    time: kf.time,
                    value: kf.value.applying(matrix),
                    inTangent: kf.inTangent,
                    outTangent: kf.outTangent,
                    hold: kf.hold
                )
            }
            return .keyframedBezier(transformedKeyframes)
        }
    }

    /// Samples the path at the given frame with bezier easing interpolation
    /// - Parameter frame: Frame number (can be fractional)
    /// - Returns: Interpolated BezierPath at the given frame
    public func sample(frame: Double) -> BezierPath? {
        switch self {
        case .staticBezier(let path):
            return path

        case .keyframedBezier(let keyframes):
            guard !keyframes.isEmpty else { return nil }

            // Before first keyframe - return first value
            if frame <= keyframes[0].time {
                return keyframes[0].value
            }

            // After last keyframe - return last value
            if frame >= keyframes[keyframes.count - 1].time {
                return keyframes[keyframes.count - 1].value
            }

            // Find the segment containing this frame
            for i in 0..<(keyframes.count - 1) {
                let kf0 = keyframes[i]
                let kf1 = keyframes[i + 1]

                if frame >= kf0.time && frame < kf1.time {
                    // Check for hold keyframe
                    if kf0.hold {
                        return kf0.value
                    }

                    // Calculate linear progress
                    let duration = kf1.time - kf0.time
                    guard duration > 0 else { return kf1.value }

                    let linearT = (frame - kf0.time) / duration

                    // Apply bezier easing if tangents are present
                    let easedT: Double
                    if let outTan = kf0.outTangent, let inTan = kf1.inTangent {
                        // Lottie easing: outTangent of current kf, inTangent of next kf
                        easedT = CubicBezierEasing.solve(
                            x: linearT,
                            x1: outTan.x,
                            y1: outTan.y,
                            x2: inTan.x,
                            y2: inTan.y
                        )
                    } else {
                        easedT = linearT
                    }

                    // Interpolate paths
                    return kf0.value.interpolated(to: kf1.value, t: easedT)
                }
            }

            // Fallback - return last value
            return keyframes[keyframes.count - 1].value
        }
    }
}

// MARK: - Mask

/// IR representation of a layer mask
public struct Mask: Sendable, Equatable, Codable {
    /// Mask mode (only .add supported in Part 1)
    public let mode: MaskMode

    /// Inverted flag
    public let inverted: Bool

    /// Mask opacity (0-100)
    public let opacity: Double

    /// Mask path (source data for compilation)
    public let path: AnimPath

    /// Path ID in PathRegistry (set during compilation)
    /// nil means path was not registered (will be registered during first render)
    public var pathId: PathID?

    public init(mode: MaskMode, inverted: Bool, opacity: Double, path: AnimPath, pathId: PathID? = nil) {
        self.mode = mode
        self.inverted = inverted
        self.opacity = opacity
        self.path = path
        self.pathId = pathId
    }
}

// MARK: - BezierPath → CGPath (PR-17)

extension BezierPath {

    /// Converts this `BezierPath` to a `CGPath`.
    ///
    /// The conversion is deterministic: same `BezierPath` always produces the same `CGPath`.
    /// Handles line segments (zero tangents) and cubic curves identically to `ShapeCache.buildCGPath`,
    /// ensuring overlay and hit-test geometry matches the rasterised render output.
    public var cgPath: CGPath {
        let path = CGMutablePath()
        guard !vertices.isEmpty else { return path }

        let count = vertices.count

        // Move to first vertex
        let start = vertices[0]
        path.move(to: CGPoint(x: start.x, y: start.y))

        // Draw segments
        for i in 0..<count {
            let nextIdx = (i + 1) % count
            if !closed && nextIdx == 0 {
                break // Don't close open path
            }

            let currentVertex = vertices[i]
            let nextVertex = vertices[nextIdx]
            let outTan = outTangents[i]
            let inTan = inTangents[nextIdx]

            // Check if this is a straight line (both tangents are nearly zero)
            let isLine = Quantization.isNearlyZero(outTan.x) &&
                         Quantization.isNearlyZero(outTan.y) &&
                         Quantization.isNearlyZero(inTan.x) &&
                         Quantization.isNearlyZero(inTan.y)

            if isLine {
                path.addLine(to: CGPoint(x: nextVertex.x, y: nextVertex.y))
            } else {
                let cp1x = currentVertex.x + outTan.x
                let cp1y = currentVertex.y + outTan.y
                let cp2x = nextVertex.x + inTan.x
                let cp2y = nextVertex.y + inTan.y
                path.addCurve(
                    to: CGPoint(x: nextVertex.x, y: nextVertex.y),
                    control1: CGPoint(x: cp1x, y: cp1y),
                    control2: CGPoint(x: cp2x, y: cp2y)
                )
            }
        }

        if closed {
            path.closeSubpath()
        }

        return path
    }

    /// Tests whether a point lies inside this closed path using the even-odd fill rule.
    ///
    /// Returns `false` for open paths or paths with fewer than 3 vertices.
    /// The path must already be in the target coordinate space before calling.
    ///
    /// - Parameter point: Point to test (same coordinate space as path vertices)
    /// - Returns: `true` if the point is inside the closed path
    public func contains(point: Vec2D) -> Bool {
        guard closed, vertices.count >= 3 else { return false }
        return cgPath.contains(CGPoint(x: point.x, y: point.y), using: .evenOdd)
    }
}
