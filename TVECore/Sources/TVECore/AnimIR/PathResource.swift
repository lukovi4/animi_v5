import Foundation

// MARK: - Path ID

/// Unique identifier for a path resource in the AnimIR.
/// Used to reference paths in RenderCommands instead of passing BezierPath directly.
public struct PathID: Hashable, Sendable, Equatable {
    public let value: Int

    public init(_ value: Int) {
        self.value = value
    }
}

// MARK: - Path Resource

/// GPU-ready path resource with triangulated vertices for all keyframes.
/// Stores flattened vertex positions for each keyframe and shared triangle indices.
///
/// Memory layout:
/// - positions: [keyframeIndex][vertexIndex] -> (x, y)
/// - indices: shared triangulation indices (same topology across keyframes)
public struct PathResource: Sendable, Equatable {
    /// Path identifier (index in registry)
    public let pathId: PathID

    /// Vertex positions for each keyframe.
    /// Outer array: keyframes (count = keyframeCount)
    /// Inner array: flattened [x0, y0, x1, y1, ...] (count = vertexCount * 2)
    public let keyframePositions: [[Float]]

    /// Keyframe times (frame numbers)
    public let keyframeTimes: [Double]

    /// Triangle indices (shared across all keyframes due to fixed topology)
    public let indices: [UInt16]

    /// Number of vertices per keyframe
    public let vertexCount: Int

    /// Number of keyframes (1 for static path)
    public var keyframeCount: Int { keyframePositions.count }

    /// Whether this path is animated (has multiple keyframes)
    public var isAnimated: Bool { keyframeCount > 1 }

    /// Easing data for each keyframe segment.
    /// Count = keyframeCount - 1 (no easing after last keyframe)
    /// Each element is (outX, outY, inX, inY) for cubic bezier, or nil for linear/hold.
    public let keyframeEasing: [KeyframeEasing?]

    /// Easing parameters for a keyframe segment
    public struct KeyframeEasing: Sendable, Equatable {
        /// Out tangent X (0-1)
        public let outX: Double
        /// Out tangent Y (0-1)
        public let outY: Double
        /// In tangent X (0-1)
        public let inX: Double
        /// In tangent Y (0-1)
        public let inY: Double
        /// Hold keyframe (no interpolation)
        public let hold: Bool

        public init(outX: Double, outY: Double, inX: Double, inY: Double, hold: Bool = false) {
            self.outX = outX
            self.outY = outY
            self.inX = inX
            self.inY = inY
            self.hold = hold
        }

        /// Linear easing
        public static let linear = KeyframeEasing(outX: 0, outY: 0, inX: 1, inY: 1)
    }

    public init(
        pathId: PathID,
        keyframePositions: [[Float]],
        keyframeTimes: [Double],
        indices: [UInt16],
        vertexCount: Int,
        keyframeEasing: [KeyframeEasing?] = []
    ) {
        self.pathId = pathId
        self.keyframePositions = keyframePositions
        self.keyframeTimes = keyframeTimes
        self.indices = indices
        self.vertexCount = vertexCount
        self.keyframeEasing = keyframeEasing
    }
}

// MARK: - Triangulated Position Sampling

extension PathResource {
    /// Samples flattened triangulated positions (x,y,x,y,...) at the given frame.
    ///
    /// For static paths, copies positions directly. For animated paths, interpolates
    /// between keyframes using easing curves.
    ///
    /// Caller MUST reuse `out` to avoid steady-state allocations.
    ///
    /// - Parameters:
    ///   - frame: Animation frame to sample
    ///   - out: Reusable output buffer (will be cleared and filled)
    public func sampleTriangulatedPositions(at frame: Double, into out: inout [Float]) {
        out.removeAll(keepingCapacity: true)
        // PR-C3 (I5): Reserve capacity upfront to avoid reallocation during append
        out.reserveCapacity(vertexCount * 2)

        // Static path: copy directly
        guard keyframePositions.count > 1 else {
            if let first = keyframePositions.first {
                out.append(contentsOf: first)
            }
            return
        }

        // Animated path: find keyframe segment and interpolate
        let times = keyframeTimes

        // Safety guard: keyframeTimes and keyframePositions must have same count
        guard !times.isEmpty, times.count == keyframePositions.count else {
            if let first = keyframePositions.first {
                out.append(contentsOf: first)
            }
            return
        }

        // Before first keyframe
        if frame <= times[0] {
            out.append(contentsOf: keyframePositions[0])
            return
        }

        // After last keyframe
        if frame >= times[times.count - 1] {
            out.append(contentsOf: keyframePositions[times.count - 1])
            return
        }

        // Find segment containing frame
        for idx in 0..<(times.count - 1) {
            if frame >= times[idx] && frame < times[idx + 1] {
                let t0 = times[idx]
                let t1 = times[idx + 1]
                var linearT = (frame - t0) / (t1 - t0)

                // Apply easing if available
                if idx < keyframeEasing.count, let easing = keyframeEasing[idx] {
                    if easing.hold {
                        linearT = 0 // Hold at start value
                    } else {
                        linearT = CubicBezierEasing.solve(
                            x: linearT,
                            x1: easing.outX,
                            y1: easing.outY,
                            x2: easing.inX,
                            y2: easing.inY
                        )
                    }
                }

                // Interpolate positions
                let pos0 = keyframePositions[idx]
                let pos1 = keyframePositions[idx + 1]

                for pIdx in 0..<pos0.count {
                    let interpolated = pos0[pIdx] + Float(linearT) * (pos1[pIdx] - pos0[pIdx])
                    out.append(interpolated)
                }
                return
            }
        }

        // Fallback: use last keyframe
        out.append(contentsOf: keyframePositions[keyframePositions.count - 1])
    }
}

// MARK: - Path Registry Generation Counter (PR-14B)

/// Thread-safe counter for PathRegistry generation IDs.
/// Ensures each PathRegistry gets a unique ID for path sampling cache key differentiation.
private final class RegistryGenerationCounter: @unchecked Sendable {
    static let shared = RegistryGenerationCounter()
    private var counter: Int = 0
    private let lock = NSLock()

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = counter
        counter += 1
        return id
    }
}

// MARK: - Path Registry

/// Registry of path resources for an AnimIR.
/// Paths are registered during compilation and referenced by pathId in RenderCommands.
public struct PathRegistry: Sendable, Equatable {
    /// Unique generation ID for this registry instance (PR-14B).
    /// Monotonically increasing; prevents path sampling cache collisions
    /// when a MetalRenderer is reused across scene recompilations.
    public let generationId: Int

    /// All registered path resources
    public private(set) var paths: [PathResource] = []

    /// Creates an empty registry with a unique generationId.
    public init() {
        self.generationId = RegistryGenerationCounter.shared.next()
    }

    /// Equatable compares paths only (generationId is an identity marker, not content).
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.paths == rhs.paths
    }

    /// Registers a new path resource and returns its ID.
    /// - Parameter resource: Path resource to register
    /// - Returns: PathID for referencing this path in RenderCommands
    @discardableResult
    public mutating func register(_ resource: PathResource) -> PathID {
        let pathId = PathID(paths.count)
        // Ensure pathId matches index
        let updatedResource = PathResource(
            pathId: pathId,
            keyframePositions: resource.keyframePositions,
            keyframeTimes: resource.keyframeTimes,
            indices: resource.indices,
            vertexCount: resource.vertexCount,
            keyframeEasing: resource.keyframeEasing
        )
        paths.append(updatedResource)
        return pathId
    }

    /// Registers a path resource preserving its original pathId.
    /// Use this when adding paths from another registry that already have assigned IDs.
    /// - Parameter resource: Path resource with pre-assigned pathId
    /// - Returns: The original pathId of the resource
    @discardableResult
    public mutating func registerPreserving(_ resource: PathResource) -> PathID {
        // Extend paths array if needed to accommodate the pathId
        while paths.count <= resource.pathId.value {
            // Add placeholder (will be replaced or skipped during lookup)
            paths.append(PathResource(
                pathId: PathID(paths.count),
                keyframePositions: [[]],
                keyframeTimes: [0],
                indices: [],
                vertexCount: 0
            ))
        }
        paths[resource.pathId.value] = resource
        return resource.pathId
    }

    /// Gets a path resource by ID.
    /// - Parameter pathId: Path ID
    /// - Returns: Path resource, or nil if not found
    public func path(for pathId: PathID) -> PathResource? {
        guard pathId.value >= 0 && pathId.value < paths.count else { return nil }
        return paths[pathId.value]
    }

    /// Number of registered paths
    public var count: Int { paths.count }
}

// MARK: - Path Resource Builder

/// Builds PathResource from BezierPath or AnimPath.
public enum PathResourceBuilder {
    /// Default flatness for bezier curve flattening (in path coordinate units)
    public static let defaultFlatness: Double = 0.5

    /// Creates a PathResource from a static BezierPath.
    /// - Parameters:
    ///   - path: BezierPath to convert
    ///   - pathId: ID for the resource
    ///   - flatness: Curve flattening tolerance
    /// - Returns: PathResource, or nil if path has insufficient vertices
    public static func build(
        from path: BezierPath,
        pathId: PathID,
        flatness: Double = defaultFlatness
    ) -> PathResource? {
        // Flatten bezier curves to polyline
        let flatVertices = Earcut.flattenPath(path, flatness: flatness)
        guard flatVertices.count >= 6 else { return nil } // At least 3 vertices

        // Triangulate
        let indices = Earcut.triangulate(vertices: flatVertices)
        guard !indices.isEmpty else { return nil }

        // Convert to Float positions
        let positions = flatVertices.map { Float($0) }

        // Convert indices to UInt16
        let indices16 = indices.map { UInt16($0) }

        return PathResource(
            pathId: pathId,
            keyframePositions: [positions],
            keyframeTimes: [0],
            indices: indices16,
            vertexCount: flatVertices.count / 2,
            keyframeEasing: []
        )
    }

    /// Creates a PathResource from an AnimPath (potentially animated).
    /// - Parameters:
    ///   - animPath: AnimPath to convert
    ///   - pathId: ID for the resource
    ///   - flatness: Curve flattening tolerance
    /// - Returns: PathResource, or nil if path has insufficient vertices or topology mismatch
    public static func build(
        from animPath: AnimPath,
        pathId: PathID,
        flatness: Double = defaultFlatness
    ) -> PathResource? {
        switch animPath {
        case .staticBezier(let path):
            return build(from: path, pathId: pathId, flatness: flatness)

        case .keyframedBezier(let keyframes):
            guard !keyframes.isEmpty else { return nil }

            // Flatten first keyframe to establish topology
            let firstPath = keyframes[0].value
            let firstFlat = Earcut.flattenPath(firstPath, flatness: flatness)
            guard firstFlat.count >= 6 else { return nil }

            let vertexCount = firstFlat.count / 2

            // Triangulate using first keyframe topology
            let indices = Earcut.triangulate(vertices: firstFlat)
            guard !indices.isEmpty else { return nil }

            var allPositions: [[Float]] = []
            var keyframeTimes: [Double] = []
            var easingData: [PathResource.KeyframeEasing?] = []

            for (idx, kf) in keyframes.enumerated() {
                let flatPath = Earcut.flattenPath(kf.value, flatness: flatness)

                // Validate topology matches (same vertex count)
                guard flatPath.count / 2 == vertexCount else {
                    // Topology mismatch - cannot interpolate
                    return nil
                }

                allPositions.append(flatPath.map { Float($0) })
                keyframeTimes.append(kf.time)

                // Extract easing for this keyframe (except last)
                if idx < keyframes.count - 1 {
                    if kf.hold {
                        easingData.append(PathResource.KeyframeEasing(outX: 0, outY: 0, inX: 1, inY: 1, hold: true))
                    } else if let outTan = kf.outTangent, let inTan = keyframes[idx + 1].inTangent {
                        easingData.append(PathResource.KeyframeEasing(
                            outX: outTan.x,
                            outY: outTan.y,
                            inX: inTan.x,
                            inY: inTan.y
                        ))
                    } else {
                        easingData.append(.linear)
                    }
                }
            }

            return PathResource(
                pathId: pathId,
                keyframePositions: allPositions,
                keyframeTimes: keyframeTimes,
                indices: indices.map { UInt16($0) },
                vertexCount: vertexCount,
                keyframeEasing: easingData
            )
        }
    }
}
