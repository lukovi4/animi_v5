import Foundation

/// Asset definition in Lottie (image or precomp)
/// Image assets have u/p fields, precomp assets have layers
public struct LottieAsset: Decodable, Equatable, Sendable {
    /// Asset identifier
    public let id: String

    /// Asset name
    public let name: String?

    /// Image directory path (e.g. "images/")
    public let directory: String?

    /// Image filename (e.g. "img_1.png")
    public let filename: String?

    /// Width (for images)
    public let width: Double?

    /// Height (for images)
    public let height: Double?

    /// Embedded flag (0 = external file, 1 = embedded base64)
    public let embedded: Int?

    /// Frame rate (for precomps)
    public let frameRate: Double?

    /// Layers (for precomp assets only)
    public let layers: [LottieLayer]?

    /// Returns true if this is an image asset (has filename)
    public var isImage: Bool {
        guard let filename = filename else { return false }
        return !filename.isEmpty
    }

    /// Returns true if this is a precomp asset (has layers)
    public var isPrecomp: Bool {
        layers != nil
    }

    /// Returns relative path for image assets (e.g. "images/img_1.png")
    public var relativePath: String? {
        guard let dir = directory, let file = filename else { return nil }
        // Normalize path join - ensure directory ends with /
        let normalizedDir = dir.hasSuffix("/") ? dir : dir + "/"
        return normalizedDir + file
    }

    public init(
        id: String,
        name: String? = nil,
        directory: String? = nil,
        filename: String? = nil,
        width: Double? = nil,
        height: Double? = nil,
        embedded: Int? = nil,
        frameRate: Double? = nil,
        layers: [LottieLayer]? = nil
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.filename = filename
        self.width = width
        self.height = height
        self.embedded = embedded
        self.frameRate = frameRate
        self.layers = layers
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name = "nm"
        case directory = "u"
        case filename = "p"
        case width = "w"
        case height = "h"
        case embedded = "e"
        case frameRate = "fr"
        case layers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        width = try container.decodeIfPresent(Double.self, forKey: .width)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        embedded = try container.decodeIfPresent(Int.self, forKey: .embedded)
        frameRate = try container.decodeIfPresent(Double.self, forKey: .frameRate)
        layers = try container.decodeIfPresent([LottieLayer].self, forKey: .layers)
    }
}
