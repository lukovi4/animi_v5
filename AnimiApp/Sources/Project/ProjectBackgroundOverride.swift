import Foundation

// MARK: - Project Background Override

/// User's background customization for a project.
/// Stored in <projectId>.json.
public struct ProjectBackgroundOverride: Codable, Equatable, Sendable {
    /// Selected preset ID (nil = use template default)
    public var selectedPresetId: String?

    /// Per-region overrides (key = regionId)
    public var regions: [String: RegionOverride]

    public init(
        selectedPresetId: String? = nil,
        regions: [String: RegionOverride] = [:]
    ) {
        self.selectedPresetId = selectedPresetId
        self.regions = regions
    }

    /// Empty override (no customizations)
    public static let empty = ProjectBackgroundOverride()
}

// MARK: - Region Override

/// Override configuration for a single background region.
public struct RegionOverride: Codable, Equatable, Sendable {
    /// Source configuration for this region
    public var source: RegionSourceOverride

    public init(source: RegionSourceOverride) {
        self.source = source
    }

    /// Returns the media reference if source is image, nil otherwise.
    public var imageMediaRef: MediaRef? {
        if case .image(let imageOverride) = source {
            return imageOverride.mediaRef
        }
        return nil
    }
}

// MARK: - Region Source Override

/// Source type override for a background region.
public enum RegionSourceOverride: Codable, Equatable, Sendable {
    case solid(colorHex: String)
    case gradient(GradientOverride)
    case image(ImageOverride)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case colorHex
        case gradient
        case image
    }

    private enum SourceType: String, Codable {
        case solid
        case gradient
        case image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SourceType.self, forKey: .type)

        switch type {
        case .solid:
            let colorHex = try container.decode(String.self, forKey: .colorHex)
            self = .solid(colorHex: colorHex)
        case .gradient:
            let gradient = try container.decode(GradientOverride.self, forKey: .gradient)
            self = .gradient(gradient)
        case .image:
            let image = try container.decode(ImageOverride.self, forKey: .image)
            self = .image(image)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .solid(let colorHex):
            try container.encode(SourceType.solid, forKey: .type)
            try container.encode(colorHex, forKey: .colorHex)
        case .gradient(let gradient):
            try container.encode(SourceType.gradient, forKey: .type)
            try container.encode(gradient, forKey: .gradient)
        case .image(let image):
            try container.encode(SourceType.image, forKey: .type)
            try container.encode(image, forKey: .image)
        }
    }
}

// MARK: - Gradient Override

/// Linear gradient configuration for persistence.
public struct GradientOverride: Codable, Equatable, Sendable {
    /// Gradient stops (v1: exactly 2 stops)
    public var stops: [GradientStopOverride]

    /// Start point in canvas space
    public var p0: Point2

    /// End point in canvas space
    public var p1: Point2

    public init(stops: [GradientStopOverride], p0: Point2, p1: Point2) {
        self.stops = stops
        self.p0 = p0
        self.p1 = p1
    }
}

/// Single gradient color stop.
public struct GradientStopOverride: Codable, Equatable, Sendable {
    /// Position along gradient (0.0 to 1.0)
    public var t: Double

    /// Color in hex format (#RRGGBB or #RRGGBBAA)
    public var colorHex: String

    public init(t: Double, colorHex: String) {
        self.t = t
        self.colorHex = colorHex
    }
}

// MARK: - Image Override

/// Image source configuration for persistence.
public struct ImageOverride: Codable, Equatable, Sendable {
    /// Reference to the image file
    public var mediaRef: MediaRef

    /// User transform applied to the image
    public var transform: BgImageTransformOverride

    public init(mediaRef: MediaRef, transform: BgImageTransformOverride = .identity) {
        self.mediaRef = mediaRef
        self.transform = transform
    }
}

// MARK: - Image Transform Override

/// Transform applied to background image for persistence.
/// Decoupled from TVECore.ImageTransform.
public struct BgImageTransformOverride: Codable, Equatable, Sendable {
    /// Pan offset in normalized bbox space (0..1)
    public var pan: Point2

    /// Zoom factor (1.0 = no zoom)
    public var zoom: Double

    /// Rotation in radians
    public var rotationRadians: Double

    /// Flip horizontally
    public var flipX: Bool

    /// Flip vertically
    public var flipY: Bool

    /// Fit mode: "fill" or "fit"
    public var fitMode: String

    public init(
        pan: Point2 = .zero,
        zoom: Double = 1.0,
        rotationRadians: Double = 0.0,
        flipX: Bool = false,
        flipY: Bool = false,
        fitMode: String = "fill"
    ) {
        self.pan = pan
        self.zoom = zoom
        self.rotationRadians = rotationRadians
        self.flipX = flipX
        self.flipY = flipY
        self.fitMode = fitMode
    }

    /// Identity transform (no modification)
    public static let identity = BgImageTransformOverride()
}
