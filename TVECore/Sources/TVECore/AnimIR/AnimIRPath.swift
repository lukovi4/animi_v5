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
public struct BezierPath: Sendable, Equatable {
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

// MARK: - BezierPath from Lottie

extension BezierPath {
    /// Creates BezierPath from LottiePathData
    public init?(from pathData: LottiePathData?) {
        guard let pathData = pathData,
              let vertices = pathData.vertices,
              !vertices.isEmpty else {
            return nil
        }

        self.vertices = vertices.map { arr in
            Vec2D(x: !arr.isEmpty ? arr[0] : 0, y: arr.count > 1 ? arr[1] : 0)
        }

        self.inTangents = (pathData.inTangents ?? []).map { arr in
            Vec2D(x: !arr.isEmpty ? arr[0] : 0, y: arr.count > 1 ? arr[1] : 0)
        }

        self.outTangents = (pathData.outTangents ?? []).map { arr in
            Vec2D(x: !arr.isEmpty ? arr[0] : 0, y: arr.count > 1 ? arr[1] : 0)
        }

        self.closed = pathData.closed ?? false
    }

    /// Creates BezierPath from LottieAnimatedValue (expects static path)
    public init?(from animatedValue: LottieAnimatedValue?) {
        guard let animatedValue = animatedValue,
              let data = animatedValue.value else {
            return nil
        }

        switch data {
        case .path(let pathData):
            self.init(from: pathData)
        default:
            return nil
        }
    }
}

// MARK: - Animated Path

/// Path that can be static or animated
public enum AnimPath: Sendable, Equatable {
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
public struct Mask: Sendable, Equatable {
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

// MARK: - Mask from Lottie

extension Mask {
    /// Creates Mask from LottieMask
    public init?(from lottieMask: LottieMask) {
        // Parse mode from Lottie string (a/s/i → add/subtract/intersect)
        guard let modeString = lottieMask.mode,
              let mode = MaskMode(rawValue: modeString) else {
            return nil
        }
        self.mode = mode

        self.inverted = lottieMask.inverted ?? false

        // Extract opacity (static only in Part 1)
        if let opacityValue = lottieMask.opacity,
           let data = opacityValue.value {
            switch data {
            case .number(let num):
                self.opacity = num
            case .array(let arr) where !arr.isEmpty:
                self.opacity = arr[0]
            default:
                self.opacity = 100
            }
        } else {
            self.opacity = 100
        }

        // Extract path (static or animated)
        guard let pathValue = lottieMask.path else {
            return nil
        }

        if pathValue.isAnimated {
            // Extract animated path with keyframes
            guard let animPath = Self.extractAnimatedMaskPath(from: pathValue) else {
                return nil
            }
            self.path = animPath
        } else {
            // Static path
            guard let bezier = BezierPath(from: pathValue) else {
                return nil
            }
            self.path = .staticBezier(bezier)
        }
    }

    /// Extracts animated path from LottieAnimatedValue for mask
    private static func extractAnimatedMaskPath(from value: LottieAnimatedValue) -> AnimPath? {
        guard let data = value.value,
              case .keyframes(let lottieKeyframes) = data else {
            return nil
        }

        var keyframes: [Keyframe<BezierPath>] = []
        var expectedVertexCount: Int?
        var expectedClosed: Bool?

        for kf in lottieKeyframes {
            guard let time = kf.time else { continue }

            // Extract path data from keyframe
            guard case .path(let pathData) = kf.startValue,
                  let bezier = BezierPath(from: pathData) else {
                continue
            }

            // Validate topology matches across keyframes
            if let expectedCount = expectedVertexCount {
                guard bezier.vertexCount == expectedCount else {
                    // Topology mismatch - cannot interpolate
                    return nil
                }
            } else {
                expectedVertexCount = bezier.vertexCount
            }

            if let expectedClosedFlag = expectedClosed {
                guard bezier.closed == expectedClosedFlag else {
                    return nil
                }
            } else {
                expectedClosed = bezier.closed
            }

            // Extract easing tangents
            let inTan = extractTangent(from: kf.inTangent)
            let outTan = extractTangent(from: kf.outTangent)
            let hold = (kf.hold ?? 0) == 1

            keyframes.append(Keyframe(
                time: time,
                value: bezier,
                inTangent: inTan,
                outTangent: outTan,
                hold: hold
            ))
        }

        guard !keyframes.isEmpty else { return nil }

        if keyframes.count == 1 {
            return .staticBezier(keyframes[0].value)
        }

        return .keyframedBezier(keyframes)
    }

    /// Extracts easing tangent from LottieTangent
    private static func extractTangent(from tangent: LottieTangent?) -> Vec2D? {
        guard let tangent = tangent else { return nil }

        let x: Double
        let y: Double

        switch tangent.x {
        case .single(let val):
            x = val
        case .array(let arr) where !arr.isEmpty:
            x = arr[0]
        default:
            x = 0
        }

        switch tangent.y {
        case .single(let val):
            y = val
        case .array(let arr) where !arr.isEmpty:
            y = arr[0]
        default:
            y = 0
        }

        return Vec2D(x: x, y: y)
    }
}

// MARK: - Shape Path Extraction

/// Extracts bezier path from shape layer shapes
public enum ShapePathExtractor {
    /// Extracts the first path from a list of Lottie shapes (static only)
    public static func extractPath(from shapes: [ShapeItem]?) -> BezierPath? {
        guard let shapes = shapes else { return nil }

        for shape in shapes {
            if let path = extractPathFromShape(shape) {
                return path
            }
        }
        return nil
    }

    /// Extracts animated path (AnimPath) from a list of Lottie shapes
    /// Supports both static and keyframed paths with topology validation
    public static func extractAnimPath(from shapes: [ShapeItem]?) -> AnimPath? {
        guard let shapes = shapes else { return nil }

        for shape in shapes {
            if let animPath = extractAnimPathFromShape(shape) {
                return animPath
            }
        }
        return nil
    }

    private static func extractPathFromShape(_ shape: ShapeItem) -> BezierPath? {
        switch shape {
        case .path(let pathShape):
            // Path shape - extract vertices
            return BezierPath(from: pathShape.vertices)

        case .group(let shapeGroup):
            // Group - recurse into items and apply group transform
            guard let items = shapeGroup.items else { return nil }

            // 1) Extract group transform matrix from tr element (identity if absent)
            let groupMatrix = extractGroupTransformMatrix(from: items)

            // 2) Extract path from items (recursive)
            guard let path = extractPath(from: items) else { return nil }

            // 3) Apply group matrix to path vertices and tangents
            return path.applying(groupMatrix)

        default:
            return nil
        }
    }

    private static func extractAnimPathFromShape(_ shape: ShapeItem) -> AnimPath? {
        switch shape {
        case .path(let pathShape):
            // Path shape - check if animated
            guard let vertices = pathShape.vertices else { return nil }

            if vertices.isAnimated {
                // Extract keyframed path
                return extractKeyframedPath(from: vertices)
            } else {
                // Static path
                if let bezier = BezierPath(from: vertices) {
                    return .staticBezier(bezier)
                }
                return nil
            }

        case .group(let shapeGroup):
            // Group - recurse into items and apply group transform
            guard let items = shapeGroup.items else { return nil }

            // 1) Extract group transform matrix from tr element (identity if absent)
            let groupMatrix = extractGroupTransformMatrix(from: items)

            // 2) Extract AnimPath from items (recursive)
            guard let animPath = extractAnimPath(from: items) else { return nil }

            // 3) Apply group matrix to all paths in AnimPath
            return animPath.applying(groupMatrix)

        default:
            return nil
        }
    }

    /// Extracts keyframed path from LottieAnimatedValue
    /// Validates topology: all keyframes must have same vertex count and closed flag
    private static func extractKeyframedPath(from value: LottieAnimatedValue) -> AnimPath? {
        guard let data = value.value,
              case .keyframes(let lottieKeyframes) = data else {
            return nil
        }

        var keyframes: [Keyframe<BezierPath>] = []
        var expectedVertexCount: Int?
        var expectedClosed: Bool?

        for kf in lottieKeyframes {
            guard let time = kf.time else { continue }

            // Extract path data from keyframe
            guard case .path(let pathData) = kf.startValue,
                  let bezier = BezierPath(from: pathData) else {
                continue
            }

            // Validate topology matches
            if let expectedCount = expectedVertexCount {
                guard bezier.vertexCount == expectedCount else {
                    // Topology mismatch - return nil
                    return nil
                }
            } else {
                expectedVertexCount = bezier.vertexCount
            }

            if let expectedClosedFlag = expectedClosed {
                guard bezier.closed == expectedClosedFlag else {
                    // Topology mismatch - return nil
                    return nil
                }
            } else {
                expectedClosed = bezier.closed
            }

            // Extract easing tangents
            let inTan = extractTangent(from: kf.inTangent)
            let outTan = extractTangent(from: kf.outTangent)
            let hold = (kf.hold ?? 0) == 1

            keyframes.append(Keyframe(
                time: time,
                value: bezier,
                inTangent: inTan,
                outTangent: outTan,
                hold: hold
            ))
        }

        guard !keyframes.isEmpty else { return nil }

        if keyframes.count == 1 {
            return .staticBezier(keyframes[0].value)
        }

        return .keyframedBezier(keyframes)
    }

    /// Extracts easing tangent from LottieTangent
    private static func extractTangent(from tangent: LottieTangent?) -> Vec2D? {
        guard let tangent = tangent else { return nil }

        let x: Double
        let y: Double

        switch tangent.x {
        case .single(let val):
            x = val
        case .array(let arr) where !arr.isEmpty:
            x = arr[0]
        default:
            x = 0
        }

        switch tangent.y {
        case .single(let val):
            y = val
        case .array(let arr) where !arr.isEmpty:
            y = arr[0]
        default:
            y = 0
        }

        return Vec2D(x: x, y: y)
    }

    /// Extracts transform matrix from group items (ty="tr")
    /// Formula: T(position) * R(rotation) * S(scale) * T(-anchor)
    /// Returns identity if no transform found
    private static func extractGroupTransformMatrix(from items: [ShapeItem]) -> Matrix2D {
        // Find transform item in group
        let transformItem = items.compactMap { item -> LottieShapeTransform? in
            if case .transform(let transform) = item { return transform }
            return nil
        }.first

        guard let transform = transformItem else {
            return .identity
        }

        // Extract static values (animated values not supported for group transform in Part 1)
        let position = extractVec2D(from: transform.position) ?? Vec2D(x: 0, y: 0)
        let anchor = extractVec2D(from: transform.anchor) ?? Vec2D(x: 0, y: 0)
        let scale = extractVec2D(from: transform.scale) ?? Vec2D(x: 100, y: 100)
        let rotation = extractDouble(from: transform.rotation) ?? 0

        // Normalize scale from percentage (100 = 1.0)
        let scaleX = scale.x / 100.0
        let scaleY = scale.y / 100.0

        // Build matrix: T(position) * R(rotation) * S(scale) * T(-anchor)
        return Matrix2D.translation(x: position.x, y: position.y)
            .concatenating(.rotationDegrees(rotation))
            .concatenating(.scale(x: scaleX, y: scaleY))
            .concatenating(.translation(x: -anchor.x, y: -anchor.y))
    }

    /// Extracts Vec2D from LottieAnimatedValue (static only)
    private static func extractVec2D(from value: LottieAnimatedValue?) -> Vec2D? {
        guard let value = value, let data = value.value else { return nil }
        switch data {
        case .array(let arr) where arr.count >= 2:
            return Vec2D(x: arr[0], y: arr[1])
        default:
            return nil
        }
    }

    /// Extracts Double from LottieAnimatedValue (static only)
    private static func extractDouble(from value: LottieAnimatedValue?) -> Double? {
        guard let value = value, let data = value.value else { return nil }
        switch data {
        case .number(let num):
            return num
        case .array(let arr) where !arr.isEmpty:
            return arr[0]
        default:
            return nil
        }
    }

    /// Extracts fill color from shape layer shapes
    public static func extractFillColor(from shapes: [ShapeItem]?) -> [Double]? {
        guard let shapes = shapes else { return nil }

        for shape in shapes {
            if let color = extractFillFromShape(shape) {
                return color
            }
        }
        return nil
    }

    private static func extractFillFromShape(_ shape: ShapeItem) -> [Double]? {
        switch shape {
        case .fill(let fill):
            // Fill shape - extract color
            guard let colorValue = fill.color,
                  let data = colorValue.value,
                  case .array(let arr) = data else {
                return nil
            }
            return arr

        case .group(let shapeGroup):
            // Group - recurse into items
            guard let items = shapeGroup.items else { return nil }
            return extractFillColor(from: items)

        default:
            return nil
        }
    }

    /// Extracts fill opacity from shape layer shapes
    public static func extractFillOpacity(from shapes: [ShapeItem]?) -> Double {
        guard let shapes = shapes else { return 100 }

        for shape in shapes {
            if let opacity = extractFillOpacityFromShape(shape) {
                return opacity
            }
        }
        return 100
    }

    private static func extractFillOpacityFromShape(_ shape: ShapeItem) -> Double? {
        switch shape {
        case .fill(let fill):
            // Fill shape - extract opacity
            guard let opacityValue = fill.opacity,
                  let data = opacityValue.value else {
                return nil
            }
            switch data {
            case .number(let num):
                return num
            case .array(let arr) where !arr.isEmpty:
                return arr[0]
            default:
                return nil
            }

        case .group(let shapeGroup):
            // Group - recurse into items
            guard let items = shapeGroup.items else { return nil }
            return extractFillOpacity(from: items)

        default:
            return nil
        }
    }
}
