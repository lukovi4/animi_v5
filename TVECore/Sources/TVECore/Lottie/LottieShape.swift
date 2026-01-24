import Foundation

/// Shape item in a shape layer (ty=4)
/// Part 1 subset supports: gr (group), sh (path), fl (fill), tr (transform)
public struct LottieShape: Decodable, Equatable, Sendable {
    /// Shape type: "gr" = group, "sh" = path, "fl" = fill, "tr" = transform,
    /// "st" = stroke, "rc" = rect, "el" = ellipse, "sr" = polystar, "tm" = trim, etc.
    public let type: String

    /// Shape name
    public let name: String?

    /// Match name (After Effects internal)
    public let matchName: String?

    /// Hidden flag
    public let hidden: Bool?

    /// Group items (for ty="gr")
    public let items: [Self]?

    /// Blend mode
    public let blendMode: Int?

    /// Index
    public let index: Int?

    /// Number of properties
    public let numProperties: Int?

    /// Content index
    public let contentIndex: Int?

    /// Shape path data (for ty="sh")
    public let vertices: LottieAnimatedValue?

    /// Fill color (for ty="fl")
    public let color: LottieAnimatedValue?

    /// Opacity (for ty="fl" and ty="tr")
    public let opacity: LottieAnimatedValue?

    /// Fill rule (for ty="fl"): 1 = non-zero, 2 = even-odd
    /// Also used for rotation (for ty="tr") - both use "r" key in Lottie JSON
    public let fillRuleOrRotation: LottieAnimatedValue?

    /// Position (for ty="tr")
    public let position: LottieAnimatedValue?

    /// Anchor (for ty="tr")
    public let anchor: LottieAnimatedValue?

    /// Scale (for ty="tr")
    public let scale: LottieAnimatedValue?

    /// Skew (for ty="tr")
    public let skew: LottieAnimatedValue?

    /// Skew axis (for ty="tr")
    public let skewAxis: LottieAnimatedValue?

    public init(
        type: String,
        name: String? = nil,
        matchName: String? = nil,
        hidden: Bool? = nil,
        items: [Self]? = nil,
        blendMode: Int? = nil,
        index: Int? = nil,
        numProperties: Int? = nil,
        contentIndex: Int? = nil,
        vertices: LottieAnimatedValue? = nil,
        color: LottieAnimatedValue? = nil,
        opacity: LottieAnimatedValue? = nil,
        fillRuleOrRotation: LottieAnimatedValue? = nil,
        position: LottieAnimatedValue? = nil,
        anchor: LottieAnimatedValue? = nil,
        scale: LottieAnimatedValue? = nil,
        skew: LottieAnimatedValue? = nil,
        skewAxis: LottieAnimatedValue? = nil
    ) {
        self.type = type
        self.name = name
        self.matchName = matchName
        self.hidden = hidden
        self.items = items
        self.blendMode = blendMode
        self.index = index
        self.numProperties = numProperties
        self.contentIndex = contentIndex
        self.vertices = vertices
        self.color = color
        self.opacity = opacity
        self.fillRuleOrRotation = fillRuleOrRotation
        self.position = position
        self.anchor = anchor
        self.scale = scale
        self.skew = skew
        self.skewAxis = skewAxis
    }

    private enum CodingKeys: String, CodingKey {
        case type = "ty"
        case name = "nm"
        case matchName = "mn"
        case hidden = "hd"
        case items = "it"
        case blendMode = "bm"
        case index = "ix"
        case numProperties = "np"
        case contentIndex = "cix"
        case vertices = "ks"
        case color = "c"
        case opacity = "o"
        case fillRuleOrRotation = "r"
        case position = "p"
        case anchor = "a"
        case scale = "s"
        case skew = "sk"
        case skewAxis = "sa"
    }
}
