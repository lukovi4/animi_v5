import Foundation

/// Transform properties for a Lottie layer (ks object)
public struct LottieTransform: Decodable, Equatable, Sendable {
    /// Opacity (0-100)
    public let opacity: LottieAnimatedValue?

    /// Rotation in degrees
    public let rotation: LottieAnimatedValue?

    /// Position [x, y, z]
    public let position: LottieAnimatedValue?

    /// Anchor point [x, y, z]
    public let anchor: LottieAnimatedValue?

    /// Scale [x, y, z] in percentage
    public let scale: LottieAnimatedValue?

    /// Skew
    public let skew: LottieAnimatedValue?

    /// Skew axis
    public let skewAxis: LottieAnimatedValue?

    public init(
        opacity: LottieAnimatedValue? = nil,
        rotation: LottieAnimatedValue? = nil,
        position: LottieAnimatedValue? = nil,
        anchor: LottieAnimatedValue? = nil,
        scale: LottieAnimatedValue? = nil,
        skew: LottieAnimatedValue? = nil,
        skewAxis: LottieAnimatedValue? = nil
    ) {
        self.opacity = opacity
        self.rotation = rotation
        self.position = position
        self.anchor = anchor
        self.scale = scale
        self.skew = skew
        self.skewAxis = skewAxis
    }

    private enum CodingKeys: String, CodingKey {
        case opacity = "o"
        case rotation = "r"
        case position = "p"
        case anchor = "a"
        case scale = "s"
        case skew = "sk"
        case skewAxis = "sa"
    }
}

/// Animated value container in Lottie
/// Can be static (a=0) or animated (a=1)
public struct LottieAnimatedValue: Decodable, Equatable, Sendable {
    /// Animation flag: 0 = static, 1 = animated
    public let animated: Int

    /// Static value or keyframe array
    /// For static: single value or array [x, y, z]
    /// For animated: array of keyframe objects
    public let value: LottieValueData?

    /// Property index
    public let index: Int?

    /// Length of value array
    public let length: Int?

    /// Returns true if this value is animated
    public var isAnimated: Bool {
        animated == 1
    }

    public init(animated: Int, value: LottieValueData? = nil, index: Int? = nil, length: Int? = nil) {
        self.animated = animated
        self.value = value
        self.index = index
        self.length = length
    }

    private enum CodingKeys: String, CodingKey {
        case animated = "a"
        case value = "k"
        case index = "ix"
        case length = "l"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        animated = try container.decodeIfPresent(Int.self, forKey: .animated) ?? 0
        value = try container.decodeIfPresent(LottieValueData.self, forKey: .value)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        length = try container.decodeIfPresent(Int.self, forKey: .length)
    }
}

/// Flexible value container that can hold different types
/// Used for both static values and keyframe data
public enum LottieValueData: Decodable, Equatable, Sendable {
    case number(Double)
    case array([Double])
    case keyframes([LottieKeyframe])
    case path(LottiePathData)
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try number first
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }

        // Try simple array
        if let array = try? container.decode([Double].self) {
            self = .array(array)
            return
        }

        // Try keyframes array
        if let keyframes = try? container.decode([LottieKeyframe].self) {
            self = .keyframes(keyframes)
            return
        }

        // Try path data
        if let path = try? container.decode(LottiePathData.self) {
            self = .path(path)
            return
        }

        // Unknown structure - skip gracefully
        self = .unknown
    }
}

/// Keyframe in animated value
public struct LottieKeyframe: Decodable, Equatable, Sendable {
    /// Time in frames
    public let time: Double?

    /// Start value
    public let startValue: [Double]?

    /// End value (legacy format)
    public let endValue: [Double]?

    /// In tangent for easing
    public let inTangent: LottieTangent?

    /// Out tangent for easing
    public let outTangent: LottieTangent?

    /// Hold flag
    public let hold: Int?

    public init(
        time: Double? = nil,
        startValue: [Double]? = nil,
        endValue: [Double]? = nil,
        inTangent: LottieTangent? = nil,
        outTangent: LottieTangent? = nil,
        hold: Int? = nil
    ) {
        self.time = time
        self.startValue = startValue
        self.endValue = endValue
        self.inTangent = inTangent
        self.outTangent = outTangent
        self.hold = hold
    }

    private enum CodingKeys: String, CodingKey {
        case time = "t"
        case startValue = "s"
        case endValue = "e"
        case inTangent = "i"
        case outTangent = "o"
        case hold = "h"
    }
}

/// Bezier tangent for easing curves
public struct LottieTangent: Decodable, Equatable, Sendable {
    public let x: LottieTangentValue?
    public let y: LottieTangentValue?

    public init(x: LottieTangentValue? = nil, y: LottieTangentValue? = nil) {
        self.x = x
        self.y = y
    }
}

/// Tangent value - can be single number or array
public enum LottieTangentValue: Decodable, Equatable, Sendable {
    case single(Double)
    case array([Double])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Double.self) {
            self = .single(value)
        } else if let array = try? container.decode([Double].self) {
            self = .array(array)
        } else {
            self = .single(0)
        }
    }
}

/// Path data for shape/mask vertices
public struct LottiePathData: Decodable, Equatable, Sendable {
    /// In tangents
    public let inTangents: [[Double]]?

    /// Out tangents
    public let outTangents: [[Double]]?

    /// Vertices
    public let vertices: [[Double]]?

    /// Closed path flag
    public let closed: Bool?

    public init(
        inTangents: [[Double]]? = nil,
        outTangents: [[Double]]? = nil,
        vertices: [[Double]]? = nil,
        closed: Bool? = nil
    ) {
        self.inTangents = inTangents
        self.outTangents = outTangents
        self.vertices = vertices
        self.closed = closed
    }

    private enum CodingKeys: String, CodingKey {
        case inTangents = "i"
        case outTangents = "o"
        case vertices = "v"
        case closed = "c"
    }
}
