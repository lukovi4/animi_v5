import Foundation

/// Mask properties in Lottie layer
public struct LottieMask: Decodable, Equatable, Sendable {
    /// Mask mode: "a" = add, "s" = subtract, "i" = intersect, "l" = lighten, "d" = darken, "f" = difference
    public let mode: String?

    /// Inverted mask flag
    public let inverted: Bool?

    /// Mask path (animated shape)
    public let path: LottieAnimatedValue?

    /// Mask opacity (0-100)
    public let opacity: LottieAnimatedValue?

    /// Mask expansion
    public let expansion: LottieAnimatedValue?

    /// Mask name
    public let name: String?

    public init(
        mode: String? = nil,
        inverted: Bool? = nil,
        path: LottieAnimatedValue? = nil,
        opacity: LottieAnimatedValue? = nil,
        expansion: LottieAnimatedValue? = nil,
        name: String? = nil
    ) {
        self.mode = mode
        self.inverted = inverted
        self.path = path
        self.opacity = opacity
        self.expansion = expansion
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case inverted = "inv"
        case path = "pt"
        case opacity = "o"
        case expansion = "x"
        case name = "nm"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        inverted = try container.decodeIfPresent(Bool.self, forKey: .inverted)
        path = try container.decodeIfPresent(LottieAnimatedValue.self, forKey: .path)
        opacity = try container.decodeIfPresent(LottieAnimatedValue.self, forKey: .opacity)
        expansion = try container.decodeIfPresent(LottieAnimatedValue.self, forKey: .expansion)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }
}
