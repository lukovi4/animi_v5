import Foundation

// MARK: - Background Preset Models

/// A background preset defines a reusable background configuration with multiple regions.
public struct BackgroundPreset: Codable, Equatable, Sendable {
    /// Unique identifier for the preset (e.g., "wave_split", "solid_fullscreen")
    public let presetId: String

    /// Display title for UI
    public let title: String

    /// Canvas size this preset is designed for [width, height]
    public let canvasSize: [Int]

    /// Regions that make up this preset (up to 8 in v1)
    public let regions: [BackgroundRegionPreset]

    public init(
        presetId: String,
        title: String,
        canvasSize: [Int],
        regions: [BackgroundRegionPreset]
    ) {
        self.presetId = presetId
        self.title = title
        self.canvasSize = canvasSize
        self.regions = regions
    }
}

/// A single region within a background preset.
public struct BackgroundRegionPreset: Codable, Equatable, Sendable {
    /// Unique identifier for this region within the preset (e.g., "top", "wave", "bottom")
    public let regionId: String

    /// Display name for UI
    public let displayName: String

    /// Shape mask defining this region's boundaries
    public let mask: BackgroundMask

    /// UV mapping strategy: "bbox" in v1 (UV normalized to region bounding box)
    public let uvMapping: String

    public init(
        regionId: String,
        displayName: String,
        mask: BackgroundMask,
        uvMapping: String = "bbox"
    ) {
        self.regionId = regionId
        self.displayName = displayName
        self.mask = mask
        self.uvMapping = uvMapping
    }
}

/// Shape mask for a background region.
/// Supports polygon (straight edges) and bezier (curved edges) types.
public struct BackgroundMask: Codable, Equatable, Sendable {
    /// Type of mask shape
    public let type: MaskType

    /// Vertices in canvas space (may extend beyond canvas bounds for overscan)
    public let vertices: [Vec2D]

    /// In tangents for bezier curves (relative to vertex). Required for bezier type.
    public let inTangents: [Vec2D]?

    /// Out tangents for bezier curves (relative to vertex). Required for bezier type.
    public let outTangents: [Vec2D]?

    /// Whether the path is closed
    public let closed: Bool

    /// Mask type enumeration
    public enum MaskType: String, Codable, Sendable {
        /// Simple polygon with straight edges (tangents auto-generated as zero)
        case polygon
        /// Bezier path with curves (requires inTangents and outTangents)
        case bezier
    }

    public init(
        type: MaskType,
        vertices: [Vec2D],
        inTangents: [Vec2D]? = nil,
        outTangents: [Vec2D]? = nil,
        closed: Bool = true
    ) {
        self.type = type
        self.vertices = vertices
        self.inTangents = inTangents
        self.outTangents = outTangents
        self.closed = closed
    }
}

// MARK: - Errors

/// Errors that can occur when working with background presets.
public enum BackgroundPresetError: Error, Equatable {
    /// Invalid mask configuration
    case invalidMask(reason: String)
    /// Preset not found
    case presetNotFound(presetId: String)
    /// Failed to load preset data
    case loadFailed(reason: String)
}

// MARK: - BackgroundMask -> BezierPath Conversion

extension BackgroundMask {
    /// Converts this mask to a BezierPath for rendering.
    /// - Throws: `BackgroundPresetError.invalidMask` if the mask configuration is invalid.
    /// - Returns: A BezierPath representing this mask's shape.
    public func toBezierPath() throws -> BezierPath {
        guard vertices.count >= 3 else {
            throw BackgroundPresetError.invalidMask(
                reason: "vertices.count must be >= 3, got \(vertices.count)"
            )
        }

        switch type {
        case .polygon:
            // Polygon: generate zero tangents for straight lines
            return BezierPath(
                vertices: vertices,
                inTangents: Array(repeating: .zero, count: vertices.count),
                outTangents: Array(repeating: .zero, count: vertices.count),
                closed: closed
            )

        case .bezier:
            // Bezier: validate and use provided tangents
            guard let inT = inTangents, let outT = outTangents else {
                throw BackgroundPresetError.invalidMask(
                    reason: "bezier mask requires inTangents and outTangents"
                )
            }
            guard inT.count == vertices.count else {
                throw BackgroundPresetError.invalidMask(
                    reason: "inTangents count mismatch: vertices=\(vertices.count), inTangents=\(inT.count)"
                )
            }
            guard outT.count == vertices.count else {
                throw BackgroundPresetError.invalidMask(
                    reason: "outTangents count mismatch: vertices=\(vertices.count), outTangents=\(outT.count)"
                )
            }
            return BezierPath(
                vertices: vertices,
                inTangents: inT,
                outTangents: outT,
                closed: closed
            )
        }
    }
}
