import Foundation

// MARK: - ShapeItem Enum

/// Shape item in a shape layer (ty=4)
/// Part 1 subset supports: gr (group), sh (path), fl (fill), tr (transform)
/// Decoded but not yet rendered: rc (rectangle)
public enum ShapeItem: Equatable, Sendable {
    case group(LottieShapeGroup)
    case path(LottieShapePath)
    case fill(LottieShapeFill)
    case transform(LottieShapeTransform)
    case rect(LottieShapeRect)
    case ellipse(LottieShapeEllipse)
    case unknown(type: String)
}

// MARK: - ShapeItem Decodable

extension ShapeItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type = "ty"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "gr":
            let group = try LottieShapeGroup(from: decoder)
            self = .group(group)
        case "sh":
            let path = try LottieShapePath(from: decoder)
            self = .path(path)
        case "fl":
            let fill = try LottieShapeFill(from: decoder)
            self = .fill(fill)
        case "tr":
            let transform = try LottieShapeTransform(from: decoder)
            self = .transform(transform)
        case "rc":
            let rect = try LottieShapeRect(from: decoder)
            self = .rect(rect)
        case "el":
            let ellipse = try LottieShapeEllipse(from: decoder)
            self = .ellipse(ellipse)
        default:
            self = .unknown(type: type)
        }
    }
}

// MARK: - LottieShapeGroup (ty="gr")

/// Shape group containing other shape items
public struct LottieShapeGroup: Decodable, Equatable, Sendable {
    /// Shape type (always "gr")
    public let type: String

    /// Shape name
    public let name: String?

    /// Match name (After Effects internal)
    public let matchName: String?

    /// Hidden flag
    public let hidden: Bool?

    /// Group items
    public let items: [ShapeItem]?

    /// Number of properties
    public let numProperties: Int?

    /// Content index
    public let contentIndex: Int?

    /// Blend mode
    public let blendMode: Int?

    /// Index
    public let index: Int?

    public init(
        type: String = "gr",
        name: String? = nil,
        matchName: String? = nil,
        hidden: Bool? = nil,
        items: [ShapeItem]? = nil,
        numProperties: Int? = nil,
        contentIndex: Int? = nil,
        blendMode: Int? = nil,
        index: Int? = nil
    ) {
        self.type = type
        self.name = name
        self.matchName = matchName
        self.hidden = hidden
        self.items = items
        self.numProperties = numProperties
        self.contentIndex = contentIndex
        self.blendMode = blendMode
        self.index = index
    }

    private enum CodingKeys: String, CodingKey {
        case type = "ty"
        case name = "nm"
        case matchName = "mn"
        case hidden = "hd"
        case items = "it"
        case numProperties = "np"
        case contentIndex = "cix"
        case blendMode = "bm"
        case index = "ix"
    }
}

// MARK: - LottieShapePath (ty="sh")

/// Shape path with vertices
public struct LottieShapePath: Decodable, Equatable, Sendable {
    /// Shape type (always "sh")
    public let type: String

    /// Shape name
    public let name: String?

    /// Match name (After Effects internal)
    public let matchName: String?

    /// Hidden flag
    public let hidden: Bool?

    /// Index
    public let index: Int?

    /// Shape path data (vertices)
    public let vertices: LottieAnimatedValue?

    public init(
        type: String = "sh",
        name: String? = nil,
        matchName: String? = nil,
        hidden: Bool? = nil,
        index: Int? = nil,
        vertices: LottieAnimatedValue? = nil
    ) {
        self.type = type
        self.name = name
        self.matchName = matchName
        self.hidden = hidden
        self.index = index
        self.vertices = vertices
    }

    private enum CodingKeys: String, CodingKey {
        case type = "ty"
        case name = "nm"
        case matchName = "mn"
        case hidden = "hd"
        case index = "ix"
        case vertices = "ks"
    }
}

// MARK: - LottieShapeFill (ty="fl")

/// Shape fill with color and opacity
public struct LottieShapeFill: Decodable, Equatable, Sendable {
    /// Shape type (always "fl")
    public let type: String

    /// Shape name
    public let name: String?

    /// Match name (After Effects internal)
    public let matchName: String?

    /// Hidden flag
    public let hidden: Bool?

    /// Index
    public let index: Int?

    /// Fill color
    public let color: LottieAnimatedValue?

    /// Opacity
    public let opacity: LottieAnimatedValue?

    /// Fill rule: 1 = non-zero, 2 = even-odd
    /// Note: In Lottie JSON this is "r" as an Int, NOT an animated value
    public let fillRule: Int?

    /// Blend mode
    public let blendMode: Int?

    public init(
        type: String = "fl",
        name: String? = nil,
        matchName: String? = nil,
        hidden: Bool? = nil,
        index: Int? = nil,
        color: LottieAnimatedValue? = nil,
        opacity: LottieAnimatedValue? = nil,
        fillRule: Int? = nil,
        blendMode: Int? = nil
    ) {
        self.type = type
        self.name = name
        self.matchName = matchName
        self.hidden = hidden
        self.index = index
        self.color = color
        self.opacity = opacity
        self.fillRule = fillRule
        self.blendMode = blendMode
    }

    private enum CodingKeys: String, CodingKey {
        case type = "ty"
        case name = "nm"
        case matchName = "mn"
        case hidden = "hd"
        case index = "ix"
        case color = "c"
        case opacity = "o"
        case fillRule = "r"
        case blendMode = "bm"
    }
}

// MARK: - LottieShapeTransform (ty="tr")

/// Shape transform with position, scale, rotation, etc.
public struct LottieShapeTransform: Decodable, Equatable, Sendable {
    /// Shape type (always "tr")
    public let type: String

    /// Shape name
    public let name: String?

    /// Match name (After Effects internal)
    public let matchName: String?

    /// Hidden flag
    public let hidden: Bool?

    /// Index
    public let index: Int?

    /// Position
    public let position: LottieAnimatedValue?

    /// Anchor point
    public let anchor: LottieAnimatedValue?

    /// Scale
    public let scale: LottieAnimatedValue?

    /// Rotation (animated value)
    /// Note: In Lottie JSON this is "r" as an animated value object, NOT an Int
    public let rotation: LottieAnimatedValue?

    /// Opacity
    public let opacity: LottieAnimatedValue?

    /// Skew
    public let skew: LottieAnimatedValue?

    /// Skew axis
    public let skewAxis: LottieAnimatedValue?

    public init(
        type: String = "tr",
        name: String? = nil,
        matchName: String? = nil,
        hidden: Bool? = nil,
        index: Int? = nil,
        position: LottieAnimatedValue? = nil,
        anchor: LottieAnimatedValue? = nil,
        scale: LottieAnimatedValue? = nil,
        rotation: LottieAnimatedValue? = nil,
        opacity: LottieAnimatedValue? = nil,
        skew: LottieAnimatedValue? = nil,
        skewAxis: LottieAnimatedValue? = nil
    ) {
        self.type = type
        self.name = name
        self.matchName = matchName
        self.hidden = hidden
        self.index = index
        self.position = position
        self.anchor = anchor
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.skew = skew
        self.skewAxis = skewAxis
    }

    private enum CodingKeys: String, CodingKey {
        case type = "ty"
        case name = "nm"
        case matchName = "mn"
        case hidden = "hd"
        case index = "ix"
        case position = "p"
        case anchor = "a"
        case scale = "s"
        case rotation = "r"
        case opacity = "o"
        case skew = "sk"
        case skewAxis = "sa"
    }
}

// MARK: - LottieShapeRect (ty="rc")

/// Rectangle path shape
/// Note: "r" field is roundness (LottieAnimatedValue), different from:
/// - fill "r" which is fillRule (Int)
/// - transform "r" which is rotation (LottieAnimatedValue)
public struct LottieShapeRect: Decodable, Equatable, Sendable {
    /// Shape type (always "rc")
    public let type: String

    /// Shape name
    public let name: String?

    /// Match name (After Effects internal)
    public let matchName: String?

    /// Hidden flag
    public let hidden: Bool?

    /// Index
    public let index: Int?

    /// Position - center of rectangle in local shape group space
    public let position: LottieAnimatedValue?

    /// Size - width and height [w, h]
    public let size: LottieAnimatedValue?

    /// Roundness - corner radius (can be animated)
    public let roundness: LottieAnimatedValue?

    /// Direction - path direction
    public let direction: Int?

    public init(
        type: String = "rc",
        name: String? = nil,
        matchName: String? = nil,
        hidden: Bool? = nil,
        index: Int? = nil,
        position: LottieAnimatedValue? = nil,
        size: LottieAnimatedValue? = nil,
        roundness: LottieAnimatedValue? = nil,
        direction: Int? = nil
    ) {
        self.type = type
        self.name = name
        self.matchName = matchName
        self.hidden = hidden
        self.index = index
        self.position = position
        self.size = size
        self.roundness = roundness
        self.direction = direction
    }

    private enum CodingKeys: String, CodingKey {
        case type = "ty"
        case name = "nm"
        case matchName = "mn"
        case hidden = "hd"
        case index = "ix"
        case position = "p"
        case size = "s"
        case roundness = "r"
        case direction = "d"
    }
}

// MARK: - LottieShapeEllipse (ty="el")

/// Ellipse path shape
public struct LottieShapeEllipse: Decodable, Equatable, Sendable {
    /// Shape type (always "el")
    public let type: String

    /// Shape name
    public let name: String?

    /// Match name (After Effects internal)
    public let matchName: String?

    /// Hidden flag
    public let hidden: Bool?

    /// Index
    public let index: Int?

    /// Position - center of ellipse in local shape group space
    public let position: LottieAnimatedValue?

    /// Size - width and height [w, h]
    public let size: LottieAnimatedValue?

    /// Direction - path direction
    public let direction: Int?

    public init(
        type: String = "el",
        name: String? = nil,
        matchName: String? = nil,
        hidden: Bool? = nil,
        index: Int? = nil,
        position: LottieAnimatedValue? = nil,
        size: LottieAnimatedValue? = nil,
        direction: Int? = nil
    ) {
        self.type = type
        self.name = name
        self.matchName = matchName
        self.hidden = hidden
        self.index = index
        self.position = position
        self.size = size
        self.direction = direction
    }

    private enum CodingKeys: String, CodingKey {
        case type = "ty"
        case name = "nm"
        case matchName = "mn"
        case hidden = "hd"
        case index = "ix"
        case position = "p"
        case size = "s"
        case direction = "d"
    }
}

// MARK: - Legacy LottieShape (deprecated, kept for compatibility)

/// Legacy shape item structure - use ShapeItem enum instead
@available(*, deprecated, message: "Use ShapeItem enum instead")
public typealias LottieShape = ShapeItem
