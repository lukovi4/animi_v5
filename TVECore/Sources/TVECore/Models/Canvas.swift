import Foundation

/// Canvas defines the scene dimensions, frame rate, and duration
public struct Canvas: Codable, Equatable, Sendable {
    /// Width of the canvas in pixels
    public let width: Int

    /// Height of the canvas in pixels
    public let height: Int

    /// Frame rate in frames per second
    public let fps: Int

    /// Total duration of the scene in frames
    public let durationFrames: Int

    public init(width: Int, height: Int, fps: Int, durationFrames: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.durationFrames = durationFrames
    }
}

/// Background configuration for the scene.
/// Supports legacy "solid" type and new "preset" type for customizable backgrounds.
public struct Background: Codable, Equatable, Sendable {
    /// Type of background: "solid" (legacy) or "preset" (new)
    public let type: String

    /// Color value for solid backgrounds (e.g., "#0B0D1A"). Used when type="solid".
    public let color: String?

    /// Preset identifier for preset-based backgrounds. Used when type="preset".
    public let presetId: String?

    /// Per-region default configurations. Keys are regionIds.
    public let defaults: [String: RegionDefault]?

    public init(
        type: String,
        color: String? = nil,
        presetId: String? = nil,
        defaults: [String: RegionDefault]? = nil
    ) {
        self.type = type
        self.color = color
        self.presetId = presetId
        self.defaults = defaults
    }

    // MARK: - Backward Compatibility

    /// Returns the effective preset ID, handling legacy "solid" type.
    /// - Legacy "solid" type maps to "solid_fullscreen" preset.
    public var effectivePresetId: String {
        if type == "preset", let presetId = presetId {
            return presetId
        }
        // Legacy solid type maps to solid_fullscreen preset
        return "solid_fullscreen"
    }

    /// Returns the effective color for the default region (for legacy solid backgrounds).
    public var effectiveColor: String? {
        color
    }
}

/// Default configuration for a single background region.
public struct RegionDefault: Codable, Equatable, Sendable {
    /// Source type for this region: "solid", "gradient", or "image"
    public let sourceType: String

    /// Color for solid source (e.g., "#FFFFFF")
    public let solidColor: String?

    /// Linear gradient configuration
    public let gradientLinear: GradientLinearDefault?

    public init(
        sourceType: String,
        solidColor: String? = nil,
        gradientLinear: GradientLinearDefault? = nil
    ) {
        self.sourceType = sourceType
        self.solidColor = solidColor
        self.gradientLinear = gradientLinear
    }
}

/// Linear gradient configuration for region defaults.
public struct GradientLinearDefault: Codable, Equatable, Sendable {
    /// Gradient stops (2 stops in v1)
    public let stops: [GradientStop]

    /// Start point in canvas space
    public let p0: Vec2D

    /// End point in canvas space
    public let p1: Vec2D

    public init(stops: [GradientStop], p0: Vec2D, p1: Vec2D) {
        self.stops = stops
        self.p0 = p0
        self.p1 = p1
    }
}

/// A single gradient color stop.
public struct GradientStop: Codable, Equatable, Sendable {
    /// Position along the gradient (0.0 to 1.0)
    public let position: Double

    /// Color at this stop (e.g., "#FF0000")
    public let color: String

    public init(position: Double, color: String) {
        self.position = position
        self.color = color
    }
}
