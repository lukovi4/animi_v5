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

        case .rect(let rect):
            // Rectangle shape - build bezier path from position, size, roundness
            return buildRectBezierPath(from: rect)

        case .ellipse(let ellipse):
            // Ellipse shape - build bezier path from position and size
            return buildEllipseBezierPath(from: ellipse)

        case .polystar(let polystar):
            // Polystar shape - build bezier path from position, points, radii, rotation
            return buildPolystarBezierPath(from: polystar)

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

        case .rect(let rect):
            // Rectangle shape - extract static or animated path
            return extractRectAnimPath(from: rect)

        case .ellipse(let ellipse):
            // Ellipse shape - extract static or animated path
            return extractEllipseAnimPath(from: ellipse)

        case .polystar(let polystar):
            // Polystar shape - extract static or animated path
            return extractPolystarAnimPath(from: polystar)

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

    // MARK: - Rectangle Path Building

    /// Kappa constant for circular arc approximation with cubic Bezier
    /// This produces a quarter circle with < 0.02% error
    private static let kappa: Double = 0.5522847498307936

    /// Builds a static BezierPath from a LottieShapeRect
    /// - Parameter rect: The rectangle shape definition
    /// - Returns: BezierPath or nil if position/size cannot be extracted
    private static func buildRectBezierPath(from rect: LottieShapeRect) -> BezierPath? {
        // Extract static position [cx, cy]
        guard let position = extractVec2D(from: rect.position) else { return nil }

        // Extract static size [w, h]
        guard let size = extractVec2D(from: rect.size) else { return nil }

        // Extract static roundness (default 0)
        let roundness = extractDouble(from: rect.roundness) ?? 0

        // Direction: 1 = clockwise (default), 2 = counter-clockwise
        let direction = rect.direction ?? 1

        return buildRectBezierPath(
            cx: position.x,
            cy: position.y,
            width: size.x,
            height: size.y,
            roundness: roundness,
            direction: direction
        )
    }

    /// Builds a BezierPath for a rectangle with given parameters
    /// - Parameters:
    ///   - cx: Center X position
    ///   - cy: Center Y position
    ///   - width: Rectangle width
    ///   - height: Rectangle height
    ///   - roundness: Corner radius (will be clamped to valid range)
    ///   - direction: 1 = clockwise, 2 = counter-clockwise
    /// - Returns: BezierPath representing the rectangle
    private static func buildRectBezierPath(
        cx: Double,
        cy: Double,
        width: Double,
        height: Double,
        roundness: Double,
        direction: Int
    ) -> BezierPath {
        let halfW = width / 2
        let halfH = height / 2

        // Clamp roundness to valid range: 0 <= r <= min(halfW, halfH)
        let radius = max(0, min(roundness, min(halfW, halfH)))

        if radius == 0 {
            // Sharp corners: 4 vertices, no tangents
            return buildSharpRectPath(cx: cx, cy: cy, halfW: halfW, halfH: halfH, direction: direction)
        } else {
            // Rounded corners: 8 vertices with cubic bezier tangents
            return buildRoundedRectPath(cx: cx, cy: cy, halfW: halfW, halfH: halfH, radius: radius, direction: direction)
        }
    }

    /// Builds a sharp-cornered rectangle (4 vertices)
    private static func buildSharpRectPath(
        cx: Double,
        cy: Double,
        halfW: Double,
        halfH: Double,
        direction: Int
    ) -> BezierPath {
        // Vertices in clockwise order (d=1): top-left, top-right, bottom-right, bottom-left
        let topLeft = Vec2D(x: cx - halfW, y: cy - halfH)
        let topRight = Vec2D(x: cx + halfW, y: cy - halfH)
        let bottomRight = Vec2D(x: cx + halfW, y: cy + halfH)
        let bottomLeft = Vec2D(x: cx - halfW, y: cy + halfH)

        var vertices = [topLeft, topRight, bottomRight, bottomLeft]

        // Reverse for counter-clockwise (d=2)
        if direction == 2 {
            vertices.reverse()
        }

        // Zero tangents for sharp corners
        let zeroTangents = [Vec2D.zero, Vec2D.zero, Vec2D.zero, Vec2D.zero]

        return BezierPath(
            vertices: vertices,
            inTangents: zeroTangents,
            outTangents: zeroTangents,
            closed: true
        )
    }

    /// Builds a rounded rectangle (8 vertices with bezier tangents)
    /// Each corner has 2 vertices: one at the start of the arc, one at the end
    private static func buildRoundedRectPath(
        cx: Double,
        cy: Double,
        halfW: Double,
        halfH: Double,
        radius: Double,
        direction: Int
    ) -> BezierPath {
        // Control point offset for quarter circle
        let c = radius * kappa

        // Build vertices and tangents for clockwise direction (d=1)
        // Starting from top edge, going clockwise: TR corner, right edge, BR corner, etc.

        // Top edge end (before top-right corner arc)
        let p0 = Vec2D(x: cx + halfW - radius, y: cy - halfH)
        // Top-right corner arc end (start of right edge)
        let p1 = Vec2D(x: cx + halfW, y: cy - halfH + radius)
        // Right edge end (before bottom-right corner arc)
        let p2 = Vec2D(x: cx + halfW, y: cy + halfH - radius)
        // Bottom-right corner arc end (start of bottom edge)
        let p3 = Vec2D(x: cx + halfW - radius, y: cy + halfH)
        // Bottom edge end (before bottom-left corner arc)
        let p4 = Vec2D(x: cx - halfW + radius, y: cy + halfH)
        // Bottom-left corner arc end (start of left edge)
        let p5 = Vec2D(x: cx - halfW, y: cy + halfH - radius)
        // Left edge end (before top-left corner arc)
        let p6 = Vec2D(x: cx - halfW, y: cy - halfH + radius)
        // Top-left corner arc end (start of top edge)
        let p7 = Vec2D(x: cx - halfW + radius, y: cy - halfH)

        var vertices = [p0, p1, p2, p3, p4, p5, p6, p7]

        // Tangents for clockwise direction
        // For each arc: outTangent points toward next vertex, inTangent points toward previous
        // Straight segments have zero tangents at their endpoints

        // p0 (before TR arc): in=0 (from straight), out=(+c, 0) toward arc
        // p1 (after TR arc): in=(0, -c) from arc, out=0 (to straight)
        // p2 (before BR arc): in=0 (from straight), out=(0, +c) toward arc
        // p3 (after BR arc): in=(+c, 0) from arc, out=0 (to straight) -- note: in is toward p2
        // p4 (before BL arc): in=0 (from straight), out=(-c, 0) toward arc
        // p5 (after BL arc): in=(0, +c) from arc, out=0 (to straight)
        // p6 (before TL arc): in=0 (from straight), out=(0, -c) toward arc
        // p7 (after TL arc): in=(-c, 0) from arc, out=0 (to straight)

        var inTangents = [
            Vec2D.zero,            // p0: straight segment before
            Vec2D(x: 0, y: -c),    // p1: from TR arc
            Vec2D.zero,            // p2: straight segment before
            Vec2D(x: c, y: 0),     // p3: from BR arc
            Vec2D.zero,            // p4: straight segment before
            Vec2D(x: 0, y: c),     // p5: from BL arc
            Vec2D.zero,            // p6: straight segment before
            Vec2D(x: -c, y: 0)     // p7: from TL arc
        ]

        var outTangents = [
            Vec2D(x: c, y: 0),     // p0: to TR arc
            Vec2D.zero,            // p1: straight segment after
            Vec2D(x: 0, y: c),     // p2: to BR arc
            Vec2D.zero,            // p3: straight segment after
            Vec2D(x: -c, y: 0),    // p4: to BL arc
            Vec2D.zero,            // p5: straight segment after
            Vec2D(x: 0, y: -c),    // p6: to TL arc
            Vec2D.zero             // p7: straight segment after (to p0)
        ]

        // For counter-clockwise (d=2), reverse vertices and swap in/out tangents
        if direction == 2 {
            vertices.reverse()
            inTangents.reverse()
            outTangents.reverse()

            // After reversing, we need to swap in/out and negate tangent directions
            // But since we reversed the array, we actually need to swap in<->out at each position
            let tempIn = inTangents
            inTangents = outTangents.map { Vec2D(x: -$0.x, y: -$0.y) }
            outTangents = tempIn.map { Vec2D(x: -$0.x, y: -$0.y) }
        }

        return BezierPath(
            vertices: vertices,
            inTangents: inTangents,
            outTangents: outTangents,
            closed: true
        )
    }

    /// Extracts AnimPath from a LottieShapeRect (supports animated position/size)
    /// - Parameter rect: The rectangle shape definition
    /// - Returns: AnimPath (static or keyframed) or nil if extraction fails
    private static func extractRectAnimPath(from rect: LottieShapeRect) -> AnimPath? {
        let positionAnimated = rect.position?.isAnimated ?? false
        let sizeAnimated = rect.size?.isAnimated ?? false
        let roundnessAnimated = rect.roundness?.isAnimated ?? false

        // Animated roundness not supported in PR-07 (topology would change)
        if roundnessAnimated {
            return nil
        }

        // Static roundness value (default 0)
        let roundness = extractDouble(from: rect.roundness) ?? 0

        // Direction (static)
        let direction = rect.direction ?? 1

        // If both position and size are static, return static path
        if !positionAnimated && !sizeAnimated {
            if let bezier = buildRectBezierPath(from: rect) {
                return .staticBezier(bezier)
            }
            return nil
        }

        // Extract keyframes arrays
        let positionKeyframes: [LottieKeyframe]?
        let sizeKeyframes: [LottieKeyframe]?

        if positionAnimated {
            guard let posValue = rect.position,
                  let posData = posValue.value,
                  case .keyframes(let posKfs) = posData else {
                return nil
            }
            positionKeyframes = posKfs
        } else {
            positionKeyframes = nil
        }

        if sizeAnimated {
            guard let sizeValue = rect.size,
                  let sizeData = sizeValue.value,
                  case .keyframes(let sizeKfs) = sizeData else {
                return nil
            }
            sizeKeyframes = sizeKfs
        } else {
            sizeKeyframes = nil
        }

        // STRICT VALIDATION: If both p and s are animated, they must have matching keyframes
        if let posKfs = positionKeyframes, let sizeKfs = sizeKeyframes {
            // Check count match
            guard posKfs.count == sizeKfs.count else {
                return nil // Keyframe count mismatch - fail-fast
            }

            // Check time match for each keyframe
            for i in 0..<posKfs.count {
                let posTime = posKfs[i].time
                let sizeTime = sizeKfs[i].time

                // Both must have time
                guard let pt = posTime, let st = sizeTime else {
                    return nil // Missing time - fail-fast
                }

                // Times must match (using small epsilon for floating point)
                guard abs(pt - st) < 0.001 else {
                    return nil // Time mismatch - fail-fast
                }
            }
        }

        // Extract static values strictly (no fallbacks for animated properties)
        let staticPosition: Vec2D?
        if !positionAnimated {
            // Position is static - must extract successfully
            guard let pos = extractVec2D(from: rect.position) else {
                return nil // Cannot extract static position - fail-fast
            }
            staticPosition = pos
        } else {
            staticPosition = nil
        }

        let staticSize: Vec2D?
        if !sizeAnimated {
            // Size is static - must extract successfully
            guard let sz = extractVec2D(from: rect.size) else {
                return nil // Cannot extract static size - fail-fast
            }
            staticSize = sz
        } else {
            staticSize = nil
        }

        // Determine driver keyframes (prefer size, then position)
        let driverKeyframes: [LottieKeyframe]
        if let sizeKfs = sizeKeyframes {
            driverKeyframes = sizeKfs
        } else if let posKfs = positionKeyframes {
            driverKeyframes = posKfs
        } else {
            return nil // Should not happen given earlier checks
        }

        var keyframes: [Keyframe<BezierPath>] = []

        for (index, driverKf) in driverKeyframes.enumerated() {
            // Time is required - fail-fast if missing
            guard let time = driverKf.time else {
                return nil // Missing keyframe time - fail-fast
            }

            // Get position at this keyframe - no fallbacks
            let position: Vec2D
            if let posKfs = positionKeyframes {
                // Position is animated - must extract from keyframe
                guard let pos = extractVec2DFromKeyframe(posKfs[index]) else {
                    return nil // Cannot extract animated position - fail-fast
                }
                position = pos
            } else if let staticPos = staticPosition {
                // Position is static - use extracted value
                position = staticPos
            } else {
                return nil // Should not happen
            }

            // Get size at this keyframe - no fallbacks
            let size: Vec2D
            if let sizeKfs = sizeKeyframes {
                // Size is animated - must extract from keyframe
                guard let sz = extractVec2DFromKeyframe(sizeKfs[index]) else {
                    return nil // Cannot extract animated size - fail-fast
                }
                size = sz
            } else if let staticSz = staticSize {
                // Size is static - use extracted value
                size = staticSz
            } else {
                return nil // Should not happen
            }

            // Build bezier path for this keyframe
            let bezier = buildRectBezierPath(
                cx: position.x,
                cy: position.y,
                width: size.x,
                height: size.y,
                roundness: roundness,
                direction: direction
            )

            // Extract easing from driver keyframe
            let inTan = extractTangent(from: driverKf.inTangent)
            let outTan = extractTangent(from: driverKf.outTangent)
            let hold = (driverKf.hold ?? 0) == 1

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

    /// Extracts Vec2D from a keyframe's startValue
    private static func extractVec2DFromKeyframe(_ kf: LottieKeyframe) -> Vec2D? {
        guard let startValue = kf.startValue else { return nil }
        switch startValue {
        case .numbers(let arr) where arr.count >= 2:
            return Vec2D(x: arr[0], y: arr[1])
        default:
            return nil
        }
    }

    // MARK: - Ellipse Path Building

    /// Builds a static BezierPath from a LottieShapeEllipse
    /// - Parameter ellipse: The ellipse shape definition
    /// - Returns: BezierPath or nil if position/size cannot be extracted or size is invalid
    private static func buildEllipseBezierPath(from ellipse: LottieShapeEllipse) -> BezierPath? {
        // Extract static position [cx, cy]
        guard let position = extractVec2D(from: ellipse.position) else { return nil }

        // Extract static size [w, h]
        guard let size = extractVec2D(from: ellipse.size) else { return nil }

        // Validate size - must be positive
        guard size.x > 0 && size.y > 0 else { return nil }

        // Direction: 1 = clockwise (default), 2 = counter-clockwise
        let direction = ellipse.direction ?? 1

        return buildEllipseBezierPath(
            cx: position.x,
            cy: position.y,
            width: size.x,
            height: size.y,
            direction: direction
        )
    }

    /// Builds a BezierPath for an ellipse with given parameters
    /// Uses 4-point cubic bezier approximation (kappa constant)
    /// - Parameters:
    ///   - cx: Center X position
    ///   - cy: Center Y position
    ///   - width: Ellipse width
    ///   - height: Ellipse height
    ///   - direction: 1 = clockwise, 2 = counter-clockwise
    /// - Returns: BezierPath representing the ellipse (always 4 vertices)
    private static func buildEllipseBezierPath(
        cx: Double,
        cy: Double,
        width: Double,
        height: Double,
        direction: Int
    ) -> BezierPath {
        let rx = width / 2   // horizontal radius
        let ry = height / 2  // vertical radius

        // Control point offsets for quarter-circle arc approximation
        let cpx = rx * kappa
        let cpy = ry * kappa

        // 4 anchor points in clockwise order (d=1): top, right, bottom, left
        let top = Vec2D(x: cx, y: cy - ry)
        let right = Vec2D(x: cx + rx, y: cy)
        let bottom = Vec2D(x: cx, y: cy + ry)
        let left = Vec2D(x: cx - rx, y: cy)

        var vertices = [top, right, bottom, left]

        // Tangents for clockwise direction
        // Each vertex has in-tangent (from previous segment) and out-tangent (to next segment)
        // Tangents are RELATIVE to the vertex

        // top: in from left arc (-cpx, 0), out to right arc (+cpx, 0)
        // right: in from top arc (0, -cpy), out to bottom arc (0, +cpy)
        // bottom: in from right arc (+cpx, 0), out to left arc (-cpx, 0)
        // left: in from bottom arc (0, +cpy), out to top arc (0, -cpy)

        var inTangents = [
            Vec2D(x: -cpx, y: 0),    // top: from left arc
            Vec2D(x: 0, y: -cpy),    // right: from top arc
            Vec2D(x: cpx, y: 0),     // bottom: from right arc
            Vec2D(x: 0, y: cpy)      // left: from bottom arc
        ]

        var outTangents = [
            Vec2D(x: cpx, y: 0),     // top: to right arc
            Vec2D(x: 0, y: cpy),     // right: to bottom arc
            Vec2D(x: -cpx, y: 0),    // bottom: to left arc
            Vec2D(x: 0, y: -cpy)     // left: to top arc
        ]

        // For counter-clockwise (d=2), reverse vertices and swap/negate tangents
        if direction == 2 {
            vertices.reverse()
            inTangents.reverse()
            outTangents.reverse()

            // After reversing, swap in/out and negate tangent directions
            let tempIn = inTangents
            inTangents = outTangents.map { Vec2D(x: -$0.x, y: -$0.y) }
            outTangents = tempIn.map { Vec2D(x: -$0.x, y: -$0.y) }
        }

        return BezierPath(
            vertices: vertices,
            inTangents: inTangents,
            outTangents: outTangents,
            closed: true
        )
    }

    /// Extracts AnimPath from a LottieShapeEllipse (supports animated position/size)
    /// - Parameter ellipse: The ellipse shape definition
    /// - Returns: AnimPath (static or keyframed) or nil if extraction fails
    private static func extractEllipseAnimPath(from ellipse: LottieShapeEllipse) -> AnimPath? {
        let positionAnimated = ellipse.position?.isAnimated ?? false
        let sizeAnimated = ellipse.size?.isAnimated ?? false

        // Direction (static)
        let direction = ellipse.direction ?? 1

        // If both position and size are static, return static path
        if !positionAnimated && !sizeAnimated {
            if let bezier = buildEllipseBezierPath(from: ellipse) {
                return .staticBezier(bezier)
            }
            return nil
        }

        // Extract keyframes arrays
        let positionKeyframes: [LottieKeyframe]?
        let sizeKeyframes: [LottieKeyframe]?

        if positionAnimated {
            guard let posValue = ellipse.position,
                  let posData = posValue.value,
                  case .keyframes(let posKfs) = posData else {
                return nil
            }
            positionKeyframes = posKfs
        } else {
            positionKeyframes = nil
        }

        if sizeAnimated {
            guard let sizeValue = ellipse.size,
                  let sizeData = sizeValue.value,
                  case .keyframes(let sizeKfs) = sizeData else {
                return nil
            }
            sizeKeyframes = sizeKfs
        } else {
            sizeKeyframes = nil
        }

        // STRICT VALIDATION: If both p and s are animated, they must have matching keyframes
        if let posKfs = positionKeyframes, let sizeKfs = sizeKeyframes {
            // Check count match
            guard posKfs.count == sizeKfs.count else {
                return nil // Keyframe count mismatch - fail-fast
            }

            // Check time match for each keyframe
            for i in 0..<posKfs.count {
                let posTime = posKfs[i].time
                let sizeTime = sizeKfs[i].time

                // Both must have time
                guard let pt = posTime, let st = sizeTime else {
                    return nil // Missing time - fail-fast
                }

                // Times must match (using small epsilon for floating point)
                guard abs(pt - st) < 0.001 else {
                    return nil // Time mismatch - fail-fast
                }
            }
        }

        // Extract static values strictly (no fallbacks for animated properties)
        let staticPosition: Vec2D?
        if !positionAnimated {
            // Position is static - must extract successfully
            guard let pos = extractVec2D(from: ellipse.position) else {
                return nil // Cannot extract static position - fail-fast
            }
            staticPosition = pos
        } else {
            staticPosition = nil
        }

        let staticSize: Vec2D?
        if !sizeAnimated {
            // Size is static - must extract successfully
            guard let sz = extractVec2D(from: ellipse.size) else {
                return nil // Cannot extract static size - fail-fast
            }
            // Validate static size is positive
            guard sz.x > 0 && sz.y > 0 else {
                return nil // Invalid size - fail-fast
            }
            staticSize = sz
        } else {
            staticSize = nil
        }

        // Determine driver keyframes (prefer size, then position)
        let driverKeyframes: [LottieKeyframe]
        if let sizeKfs = sizeKeyframes {
            driverKeyframes = sizeKfs
        } else if let posKfs = positionKeyframes {
            driverKeyframes = posKfs
        } else {
            return nil // Should not happen given earlier checks
        }

        var keyframes: [Keyframe<BezierPath>] = []

        for (index, driverKf) in driverKeyframes.enumerated() {
            // Time is required - fail-fast if missing
            guard let time = driverKf.time else {
                return nil // Missing keyframe time - fail-fast
            }

            // Get position at this keyframe - no fallbacks
            let position: Vec2D
            if let posKfs = positionKeyframes {
                // Position is animated - must extract from keyframe
                guard let pos = extractVec2DFromKeyframe(posKfs[index]) else {
                    return nil // Cannot extract animated position - fail-fast
                }
                position = pos
            } else if let staticPos = staticPosition {
                // Position is static - use extracted value
                position = staticPos
            } else {
                return nil // Should not happen
            }

            // Get size at this keyframe - no fallbacks
            let size: Vec2D
            if let sizeKfs = sizeKeyframes {
                // Size is animated - must extract from keyframe
                guard let sz = extractVec2DFromKeyframe(sizeKfs[index]) else {
                    return nil // Cannot extract animated size - fail-fast
                }
                // Validate animated size is positive
                guard sz.x > 0 && sz.y > 0 else {
                    return nil // Invalid size in keyframe - fail-fast
                }
                size = sz
            } else if let staticSz = staticSize {
                // Size is static - use extracted value
                size = staticSz
            } else {
                return nil // Should not happen
            }

            // Build bezier path for this keyframe
            let bezier = buildEllipseBezierPath(
                cx: position.x,
                cy: position.y,
                width: size.x,
                height: size.y,
                direction: direction
            )

            // Extract easing from driver keyframe
            let inTan = extractTangent(from: driverKf.inTangent)
            let outTan = extractTangent(from: driverKf.outTangent)
            let hold = (driverKf.hold ?? 0) == 1

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

    // MARK: - Polystar Path Building

    /// Builds a static BezierPath from a LottieShapePolystar
    /// - Parameter polystar: The polystar shape definition
    /// - Returns: BezierPath or nil if parameters cannot be extracted or are invalid
    private static func buildPolystarBezierPath(from polystar: LottieShapePolystar) -> BezierPath? {
        // Extract star type (1 = star, 2 = polygon)
        guard let starType = polystar.starType, (starType == 1 || starType == 2) else { return nil }

        // Extract static position [cx, cy]
        guard let position = extractVec2D(from: polystar.position) else { return nil }

        // Extract static points count (must be integer in 3...100)
        guard let points = extractDouble(from: polystar.points),
              points >= 3, points <= 100, points == points.rounded() else { return nil }
        let pointsInt = Int(points)

        // Extract static outer radius
        guard let outerRadius = extractDouble(from: polystar.outerRadius),
              outerRadius > 0 else { return nil }

        // Extract inner radius (required for star, ignored for polygon)
        let innerRadius: Double
        if starType == 1 {
            guard let ir = extractDouble(from: polystar.innerRadius),
                  ir > 0, ir < outerRadius else { return nil }
            innerRadius = ir
        } else {
            innerRadius = 0 // Not used for polygon
        }

        // Extract static rotation (default 0)
        let rotationDeg = extractDouble(from: polystar.rotation) ?? 0

        // Validate roundness is zero (or absent)
        if let innerRoundness = extractDouble(from: polystar.innerRoundness), abs(innerRoundness) > 0.001 {
            return nil
        }
        if let outerRoundness = extractDouble(from: polystar.outerRoundness), abs(outerRoundness) > 0.001 {
            return nil
        }

        // Direction: 1 = clockwise (default), 2 = counter-clockwise
        let direction = polystar.direction ?? 1

        return buildPolystarBezierPath(
            cx: position.x,
            cy: position.y,
            points: pointsInt,
            outerRadius: outerRadius,
            innerRadius: innerRadius,
            rotationDeg: rotationDeg,
            starType: starType,
            direction: direction
        )
    }

    /// Builds a BezierPath for a polystar with given parameters
    /// - Parameters:
    ///   - cx: Center X position
    ///   - cy: Center Y position
    ///   - points: Number of points (>= 3)
    ///   - outerRadius: Outer radius (> 0)
    ///   - innerRadius: Inner radius (only used for star, > 0 and < outerRadius)
    ///   - rotationDeg: Rotation in degrees
    ///   - starType: 1 = star (2N vertices), 2 = polygon (N vertices)
    ///   - direction: 1 = clockwise, 2 = counter-clockwise
    /// - Returns: BezierPath representing the polystar (sharp corners, no roundness)
    private static func buildPolystarBezierPath(
        cx: Double,
        cy: Double,
        points: Int,
        outerRadius: Double,
        innerRadius: Double,
        rotationDeg: Double,
        starType: Int,
        direction: Int
    ) -> BezierPath {
        // Convert rotation to radians
        let rotationRad = rotationDeg * .pi / 180.0

        // Start angle: -π/2 so that 0° rotation points "up" (matching AE/Lottie convention)
        let startAngle = -.pi / 2.0

        var vertices: [Vec2D] = []

        if starType == 2 {
            // Polygon: N vertices at equal angles
            let step = 2.0 * .pi / Double(points)
            for i in 0..<points {
                let angle = startAngle + rotationRad + Double(i) * step
                let x = cx + outerRadius * cos(angle)
                let y = cy + outerRadius * sin(angle)
                vertices.append(Vec2D(x: x, y: y))
            }
        } else {
            // Star: 2N vertices alternating outer/inner radius
            let step = .pi / Double(points)
            let totalVertices = points * 2
            for k in 0..<totalVertices {
                let angle = startAngle + rotationRad + Double(k) * step
                let radius = (k % 2 == 0) ? outerRadius : innerRadius
                let x = cx + radius * cos(angle)
                let y = cy + radius * sin(angle)
                vertices.append(Vec2D(x: x, y: y))
            }
        }

        // For counter-clockwise (d=2), reverse vertices
        if direction == 2 {
            vertices.reverse()
        }

        // Sharp corners: all tangents are zero
        let zeroTangents = Array(repeating: Vec2D.zero, count: vertices.count)

        return BezierPath(
            vertices: vertices,
            inTangents: zeroTangents,
            outTangents: zeroTangents,
            closed: true
        )
    }

    /// Extracts AnimPath from a LottieShapePolystar (supports animated position/rotation/radii)
    /// - Parameter polystar: The polystar shape definition
    /// - Returns: AnimPath (static or keyframed) or nil if extraction fails
    private static func extractPolystarAnimPath(from polystar: LottieShapePolystar) -> AnimPath? {
        // Extract star type (1 = star, 2 = polygon)
        guard let starType = polystar.starType, (starType == 1 || starType == 2) else { return nil }
        let isStar = starType == 1

        // Validate roundness is zero or absent
        if polystar.innerRoundness?.isAnimated == true || polystar.outerRoundness?.isAnimated == true {
            return nil
        }
        if let innerRoundness = extractDouble(from: polystar.innerRoundness), abs(innerRoundness) > 0.001 {
            return nil
        }
        if let outerRoundness = extractDouble(from: polystar.outerRoundness), abs(outerRoundness) > 0.001 {
            return nil
        }

        // Points must be static (animated would change topology)
        if polystar.points?.isAnimated == true {
            return nil
        }
        // Points must be integer in 3...100
        guard let points = extractDouble(from: polystar.points),
              points >= 3, points <= 100, points == points.rounded() else { return nil }
        let pointsInt = Int(points)

        // Direction (static)
        let direction = polystar.direction ?? 1

        // Check which fields are animated
        let positionAnimated = polystar.position?.isAnimated ?? false
        let rotationAnimated = polystar.rotation?.isAnimated ?? false
        let outerRadiusAnimated = polystar.outerRadius?.isAnimated ?? false
        let innerRadiusAnimated = isStar && (polystar.innerRadius?.isAnimated ?? false)

        // If nothing is animated, return static path
        if !positionAnimated && !rotationAnimated && !outerRadiusAnimated && !innerRadiusAnimated {
            if let bezier = buildPolystarBezierPath(from: polystar) {
                return .staticBezier(bezier)
            }
            return nil
        }

        // Extract keyframes from animated fields
        let positionKeyframes: [LottieKeyframe]?
        let rotationKeyframes: [LottieKeyframe]?
        let outerRadiusKeyframes: [LottieKeyframe]?
        let innerRadiusKeyframes: [LottieKeyframe]?

        if positionAnimated {
            guard let posValue = polystar.position,
                  let posData = posValue.value,
                  case .keyframes(let kfs) = posData else { return nil }
            positionKeyframes = kfs
        } else {
            positionKeyframes = nil
        }

        if rotationAnimated {
            guard let rotValue = polystar.rotation,
                  let rotData = rotValue.value,
                  case .keyframes(let kfs) = rotData else { return nil }
            rotationKeyframes = kfs
        } else {
            rotationKeyframes = nil
        }

        if outerRadiusAnimated {
            guard let orValue = polystar.outerRadius,
                  let orData = orValue.value,
                  case .keyframes(let kfs) = orData else { return nil }
            outerRadiusKeyframes = kfs
        } else {
            outerRadiusKeyframes = nil
        }

        if innerRadiusAnimated {
            guard let irValue = polystar.innerRadius,
                  let irData = irValue.value,
                  case .keyframes(let kfs) = irData else { return nil }
            innerRadiusKeyframes = kfs
        } else {
            innerRadiusKeyframes = nil
        }

        // Collect all animated keyframe arrays
        var allKeyframeArrays: [[LottieKeyframe]] = []
        if let kfs = outerRadiusKeyframes { allKeyframeArrays.append(kfs) }
        if let kfs = positionKeyframes { allKeyframeArrays.append(kfs) }
        if let kfs = rotationKeyframes { allKeyframeArrays.append(kfs) }
        if let kfs = innerRadiusKeyframes { allKeyframeArrays.append(kfs) }

        // If 2+ animated fields, validate they match
        if allKeyframeArrays.count >= 2 {
            let referenceCount = allKeyframeArrays[0].count
            for i in 1..<allKeyframeArrays.count {
                guard allKeyframeArrays[i].count == referenceCount else {
                    return nil // Count mismatch - fail-fast
                }
            }

            // Validate time match
            for i in 0..<referenceCount {
                let refTime = allKeyframeArrays[0][i].time
                guard let rt = refTime else { return nil }
                for j in 1..<allKeyframeArrays.count {
                    guard let ot = allKeyframeArrays[j][i].time else { return nil }
                    guard abs(rt - ot) < 0.001 else { return nil }
                }
            }
        }

        // Extract static values for non-animated fields
        let staticPosition: Vec2D?
        if !positionAnimated {
            guard let pos = extractVec2D(from: polystar.position) else { return nil }
            staticPosition = pos
        } else {
            staticPosition = nil
        }

        let staticRotation: Double?
        if !rotationAnimated {
            staticRotation = extractDouble(from: polystar.rotation) ?? 0
        } else {
            staticRotation = nil
        }

        let staticOuterRadius: Double?
        if !outerRadiusAnimated {
            guard let or = extractDouble(from: polystar.outerRadius), or > 0 else { return nil }
            staticOuterRadius = or
        } else {
            staticOuterRadius = nil
        }

        let staticInnerRadius: Double?
        if isStar && !innerRadiusAnimated {
            guard let ir = extractDouble(from: polystar.innerRadius), ir > 0 else { return nil }
            staticInnerRadius = ir
        } else {
            staticInnerRadius = nil
        }

        // Determine driver keyframes (priority: or > p > r > ir)
        let driverKeyframes: [LottieKeyframe]
        if let kfs = outerRadiusKeyframes {
            driverKeyframes = kfs
        } else if let kfs = positionKeyframes {
            driverKeyframes = kfs
        } else if let kfs = rotationKeyframes {
            driverKeyframes = kfs
        } else if let kfs = innerRadiusKeyframes {
            driverKeyframes = kfs
        } else {
            return nil // Should not happen
        }

        var keyframes: [Keyframe<BezierPath>] = []

        for (index, driverKf) in driverKeyframes.enumerated() {
            // Time is required - fail-fast if missing
            guard let time = driverKf.time else { return nil }

            // Get position at this keyframe
            let position: Vec2D
            if let posKfs = positionKeyframes {
                guard let pos = extractVec2DFromKeyframe(posKfs[index]) else { return nil }
                position = pos
            } else if let staticPos = staticPosition {
                position = staticPos
            } else {
                return nil
            }

            // Get rotation at this keyframe
            let rotationDeg: Double
            if let rotKfs = rotationKeyframes {
                guard let rot = extractDoubleFromKeyframe(rotKfs[index]) else { return nil }
                rotationDeg = rot
            } else if let staticRot = staticRotation {
                rotationDeg = staticRot
            } else {
                rotationDeg = 0
            }

            // Get outer radius at this keyframe
            let outerRadius: Double
            if let orKfs = outerRadiusKeyframes {
                guard let or = extractDoubleFromKeyframe(orKfs[index]), or > 0 else { return nil }
                outerRadius = or
            } else if let staticOr = staticOuterRadius {
                outerRadius = staticOr
            } else {
                return nil
            }

            // Get inner radius at this keyframe (only for star)
            let innerRadius: Double
            if isStar {
                if let irKfs = innerRadiusKeyframes {
                    guard let ir = extractDoubleFromKeyframe(irKfs[index]), ir > 0, ir < outerRadius else { return nil }
                    innerRadius = ir
                } else if let staticIr = staticInnerRadius {
                    guard staticIr < outerRadius else { return nil }
                    innerRadius = staticIr
                } else {
                    return nil
                }
            } else {
                innerRadius = 0
            }

            // Build bezier path for this keyframe
            let bezier = buildPolystarBezierPath(
                cx: position.x,
                cy: position.y,
                points: pointsInt,
                outerRadius: outerRadius,
                innerRadius: innerRadius,
                rotationDeg: rotationDeg,
                starType: starType,
                direction: direction
            )

            // Extract easing from driver keyframe
            let inTan = extractTangent(from: driverKf.inTangent)
            let outTan = extractTangent(from: driverKf.outTangent)
            let hold = (driverKf.hold ?? 0) == 1

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

    /// Extracts Double from a keyframe's startValue
    private static func extractDoubleFromKeyframe(_ kf: LottieKeyframe) -> Double? {
        guard let startValue = kf.startValue else { return nil }
        switch startValue {
        case .numbers(let arr) where !arr.isEmpty:
            return arr[0]
        default:
            return nil
        }
    }

    // MARK: - Path Keyframe Extraction

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
