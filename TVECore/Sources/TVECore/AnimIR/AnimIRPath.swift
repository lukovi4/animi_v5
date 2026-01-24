import Foundation

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

    /// Keyframed bezier path animation (reserved for future use)
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

    /// Mask path
    public let path: AnimPath

    public init(mode: MaskMode, inverted: Bool, opacity: Double, path: AnimPath) {
        self.mode = mode
        self.inverted = inverted
        self.opacity = opacity
        self.path = path
    }
}

// MARK: - Mask from Lottie

extension Mask {
    /// Creates Mask from LottieMask
    public init?(from lottieMask: LottieMask) {
        // Mode must be "a" (add) for Part 1
        guard let mode = MaskMode(lottieMode: lottieMask.mode) else {
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

        // Extract path
        guard let pathValue = lottieMask.path else {
            return nil
        }

        if pathValue.isAnimated {
            // Animated paths - extract keyframes (for future use, currently validated against in PR3)
            guard let data = pathValue.value,
                  case .keyframes(let kfs) = data else {
                return nil
            }

            // For now, just use first keyframe as static (PR3 validates no animated paths)
            if let firstPath = kfs.first,
               let startValue = firstPath.startValue {
                // Reconstruct path data from keyframe
                let pathData = LottiePathData(
                    inTangents: nil,
                    outTangents: nil,
                    vertices: [startValue],
                    closed: true
                )
                if let bezier = BezierPath(from: pathData) {
                    self.path = .staticBezier(bezier)
                } else {
                    return nil
                }
            } else {
                return nil
            }
        } else {
            // Static path
            guard let bezier = BezierPath(from: pathValue) else {
                return nil
            }
            self.path = .staticBezier(bezier)
        }
    }
}

// MARK: - Shape Path Extraction

/// Extracts bezier path from shape layer shapes
public enum ShapePathExtractor {
    /// Extracts the first path from a list of Lottie shapes
    public static func extractPath(from shapes: [ShapeItem]?) -> BezierPath? {
        guard let shapes = shapes else { return nil }

        for shape in shapes {
            if let path = extractPathFromShape(shape) {
                return path
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
            // Group - recurse into items
            guard let items = shapeGroup.items else { return nil }
            return extractPath(from: items)

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
