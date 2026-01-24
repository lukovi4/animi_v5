import Foundation

/// Root structure of a Lottie animation JSON file
/// Designed as a tolerant subset - unknown fields are ignored
public struct LottieJSON: Decodable, Equatable, Sendable {
    /// Lottie version string (e.g. "5.12.1")
    public let version: String?

    /// Frame rate in frames per second
    public let frameRate: Double

    /// In point (start frame)
    public let inPoint: Double

    /// Out point (end frame)
    public let outPoint: Double

    /// Composition width in pixels
    public let width: Double

    /// Composition height in pixels
    public let height: Double

    /// Composition name
    public let name: String?

    /// 3D flag (0 = 2D, 1 = 3D)
    public let is3D: Int?

    /// Assets (images, precomps)
    public let assets: [LottieAsset]

    /// Root layers
    public let layers: [LottieLayer]

    public init(
        version: String? = nil,
        frameRate: Double,
        inPoint: Double,
        outPoint: Double,
        width: Double,
        height: Double,
        name: String? = nil,
        is3D: Int? = nil,
        assets: [LottieAsset] = [],
        layers: [LottieLayer] = []
    ) {
        self.version = version
        self.frameRate = frameRate
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.width = width
        self.height = height
        self.name = name
        self.is3D = is3D
        self.assets = assets
        self.layers = layers
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case frameRate = "fr"
        case inPoint = "ip"
        case outPoint = "op"
        case width = "w"
        case height = "h"
        case name = "nm"
        case is3D = "ddd"
        case assets
        case layers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        version = try container.decodeIfPresent(String.self, forKey: .version)
        frameRate = try container.decodeIfPresent(Double.self, forKey: .frameRate) ?? 0
        inPoint = try container.decodeIfPresent(Double.self, forKey: .inPoint) ?? 0
        outPoint = try container.decodeIfPresent(Double.self, forKey: .outPoint) ?? 0
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name)
        is3D = try container.decodeIfPresent(Int.self, forKey: .is3D)
        assets = try container.decodeIfPresent([LottieAsset].self, forKey: .assets) ?? []
        layers = try container.decodeIfPresent([LottieLayer].self, forKey: .layers) ?? []
    }
}
