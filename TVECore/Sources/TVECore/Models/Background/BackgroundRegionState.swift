import Foundation

// MARK: - Background Region State

/// Runtime state for a single background region.
/// Defines the source type and configuration for rendering.
public struct BackgroundRegionState: Equatable, Sendable {
    /// The region identifier this state applies to
    public let regionId: String

    /// The source configuration for this region
    public let source: RegionSource

    public init(regionId: String, source: RegionSource) {
        self.regionId = regionId
        self.source = source
    }
}

// MARK: - Region Source

/// Source type for a background region.
public enum RegionSource: Equatable, Sendable {
    /// Solid color fill
    case solid(SolidConfig)

    /// Linear gradient fill (2 stops in v1)
    case gradient(GradientConfig)

    /// Image fill with transform
    case image(ImageConfig)
}

// MARK: - Solid Config

/// Configuration for solid color region source.
public struct SolidConfig: Equatable, Sendable {
    /// The fill color (RGBA, 0-1)
    public let color: ClearColor

    public init(color: ClearColor) {
        self.color = color
    }
}

// MARK: - Gradient Config

/// Configuration for linear gradient region source.
public struct GradientConfig: Equatable, Sendable {
    /// Gradient stops (must be exactly 2 in v1)
    public let stops: [BackgroundGradientStop]

    /// Start point in canvas space (pixels)
    public let p0: Vec2D

    /// End point in canvas space (pixels)
    public let p1: Vec2D

    public init(stops: [BackgroundGradientStop], p0: Vec2D, p1: Vec2D) {
        self.stops = stops
        self.p0 = p0
        self.p1 = p1
    }

    /// Validates that the gradient has exactly 2 stops (v1 requirement).
    public func validate() throws {
        guard stops.count == 2 else {
            throw BackgroundRendererError.invalidGradientStops(
                expected: 2,
                actual: stops.count
            )
        }
    }
}

/// A single gradient color stop.
public struct BackgroundGradientStop: Equatable, Sendable {
    /// Position along the gradient (0.0 to 1.0)
    public let t: Double

    /// Color at this stop (RGBA, 0-1)
    public let color: ClearColor

    public init(t: Double, color: ClearColor) {
        self.t = t
        self.color = color
    }
}

// MARK: - Image Config

/// Configuration for image region source.
public struct ImageConfig: Equatable, Sendable {
    /// Slot key for texture lookup (e.g., "bg/wave_split/top")
    public let slotKey: String

    /// User transform to apply
    public let transform: ImageTransform

    public init(slotKey: String, transform: ImageTransform = ImageTransform()) {
        self.slotKey = slotKey
        self.transform = transform
    }
}

/// Transform applied to image within a region.
/// Applied after fitMode base mapping.
public struct ImageTransform: Equatable, Sendable {
    /// Pan offset in normalized bbox space (0..1)
    public var pan: Vec2D

    /// Zoom factor (1.0 = no zoom)
    public var zoom: Double

    /// Rotation in radians
    public var rotationRadians: Double

    /// Flip horizontally
    public var flipX: Bool

    /// Flip vertically
    public var flipY: Bool

    /// Fit mode for image placement
    public var fitMode: BackgroundFitMode

    public init(
        pan: Vec2D = .zero,
        zoom: Double = 1.0,
        rotationRadians: Double = 0.0,
        flipX: Bool = false,
        flipY: Bool = false,
        fitMode: BackgroundFitMode = .fill
    ) {
        self.pan = pan
        self.zoom = zoom
        self.rotationRadians = rotationRadians
        self.flipX = flipX
        self.flipY = flipY
        self.fitMode = fitMode
    }

    /// Identity transform (no modification)
    public static let identity = ImageTransform()
}

/// Fit mode for image placement within region bbox.
public enum BackgroundFitMode: String, Codable, Equatable, Sendable {
    /// Scale to cover bbox completely (may crop)
    case fill

    /// Scale to fit within bbox (may have transparent areas)
    case fit
}

// MARK: - Effective Background State

/// Complete background state for rendering.
public struct EffectiveBackgroundState: Equatable, Sendable {
    /// The preset being used
    public let preset: BackgroundPreset

    /// Per-region states (keyed by regionId)
    public let regionStates: [String: BackgroundRegionState]

    public init(preset: BackgroundPreset, regionStates: [String: BackgroundRegionState]) {
        self.preset = preset
        self.regionStates = regionStates
    }

    /// Returns the state for a specific region, or nil if not found.
    public func state(for regionId: String) -> BackgroundRegionState? {
        return regionStates[regionId]
    }
}

// MARK: - Errors

/// Errors that can occur during background rendering.
public enum BackgroundRendererError: Error, Equatable {
    /// Invalid gradient stop count (v1 requires exactly 2)
    case invalidGradientStops(expected: Int, actual: Int)

    /// Failed to create mask texture
    case maskCreationFailed(regionId: String)

    /// Missing pipeline state
    case missingPipelineState(name: String)
}
