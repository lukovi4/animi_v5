import AnimiEngineCore

/// Task-003 plan §17 step 7 (Stage-6 correction item 1) — an immutable scene-level **path resource**
/// referenced by a selected AnimIR, in RenderModel fixed-point/rational types.
///
/// Mirrors the producer `PathResource` (`pathId, vertexCount, indices, keyframeTimes,
/// keyframePositions, keyframeEasing`) with no `Double`:
///   * `indices` are checked non-negative `Int`s;
///   * `keyframePositions` are fixed-point canvas coordinates (65,536 per point);
///   * `keyframeTimes` are exact rationals (no decimal quantization);
///   * `keyframeEasing` elements are optional (a `null` segment marker is `nil`), each carrying
///     dimensionless fixed-point tangents and a `hold` flag.

/// One optional easing segment of a path keyframe.
public struct RenderPathEasing: Hashable, Sendable {
    public let outX: EasingScalar
    public let outY: EasingScalar
    public let inX: EasingScalar
    public let inY: EasingScalar
    public let hold: Bool

    public init(outX: EasingScalar, outY: EasingScalar, inX: EasingScalar, inY: EasingScalar, hold: Bool) {
        self.outX = outX
        self.outY = outY
        self.inX = inX
        self.inY = inY
        self.hold = hold
    }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("hold", .bool(hold)),
            ("inX", .int(inX.rawValue)),
            ("inY", .int(inY.rawValue)),
            ("outX", .int(outX.rawValue)),
            ("outY", .int(outY.rawValue))
        ])
    }
}

/// One scene-level path resource, fully converted.
public struct RenderPathResource: Hashable, Sendable, Comparable {
    public let pathID: Int
    public let vertexCount: Int
    public let indices: [Int]
    /// Keyframe times as exact rationals.
    public let keyframeTimes: [RationalSourceTime]
    /// Keyframe positions as fixed-point canvas scalars (each inner row preserved in order).
    public let keyframePositions: [[CanvasScalar]]
    /// Optional easing per keyframe segment (a `null` marker is `nil`).
    public let keyframeEasing: [RenderPathEasing?]

    public init(
        pathID: Int, vertexCount: Int, indices: [Int],
        keyframeTimes: [RationalSourceTime], keyframePositions: [[CanvasScalar]],
        keyframeEasing: [RenderPathEasing?]
    ) throws {
        // pathID >= 0.
        guard pathID >= 0 else {
            throw RenderModelError.valueOutOfRange(
                field: "RenderPathResource.pathID", value: Int64(pathID), lowerBound: 0, upperBound: Int64.max)
        }
        // vertexCount >= 3.
        guard vertexCount >= 3 else {
            throw RenderModelError.valueOutOfRange(
                field: "RenderPathResource.vertexCount", value: Int64(vertexCount), lowerBound: 3, upperBound: Int64.max)
        }
        // Keyframes non-empty.
        guard !keyframeTimes.isEmpty, !keyframePositions.isEmpty else {
            throw RenderModelError.unsupportedValue(field: "RenderPathResource.keyframes", value: "empty")
        }
        // times.count == positions.count.
        guard keyframeTimes.count == keyframePositions.count else {
            throw RenderModelError.unsupportedValue(
                field: "RenderPathResource.keyframeTimes",
                value: "times \(keyframeTimes.count) != positions \(keyframePositions.count)")
        }
        let keyframeCount = keyframeTimes.count
        // Every position row count == checked(vertexCount * 2).
        let (expectedRow, mulOverflow) = vertexCount.multipliedReportingOverflow(by: 2)
        if mulOverflow { throw RenderModelError.integerOverflow(operation: "RenderPathResource.vertexCount*2") }
        for (i, row) in keyframePositions.enumerated() where row.count != expectedRow {
            throw RenderModelError.unsupportedValue(
                field: "RenderPathResource.keyframePositions[\(i)]",
                value: "row \(row.count) != vertexCount*2 \(expectedRow)")
        }
        // keyframeEasing.count == keyframeCount - 1.
        guard keyframeEasing.count == keyframeCount - 1 else {
            throw RenderModelError.unsupportedValue(
                field: "RenderPathResource.keyframeEasing",
                value: "easing \(keyframeEasing.count) != keyframeCount-1 \(keyframeCount - 1)")
        }
        // indices non-empty and count divisible by 3.
        guard !indices.isEmpty, indices.count % 3 == 0 else {
            throw RenderModelError.unsupportedValue(
                field: "RenderPathResource.indices", value: "count \(indices.count) not a non-zero multiple of 3")
        }
        // every index within 0..<vertexCount and UInt16 range.
        for (i, index) in indices.enumerated() {
            guard index >= 0, index < vertexCount, index <= Int(UInt16.max) else {
                throw RenderModelError.valueOutOfRange(
                    field: "RenderPathResource.indices[\(i)]", value: Int64(index),
                    lowerBound: 0, upperBound: Int64(Swift.min(vertexCount - 1, Int(UInt16.max))))
            }
        }
        self.pathID = pathID
        self.vertexCount = vertexCount
        self.indices = indices
        self.keyframeTimes = keyframeTimes
        self.keyframePositions = keyframePositions
        self.keyframeEasing = keyframeEasing
    }

    public static func < (lhs: RenderPathResource, rhs: RenderPathResource) -> Bool { lhs.pathID < rhs.pathID }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        let times = keyframeTimes.map { t -> RenderCanonicalEncoding.Value in
            .object([("den", .int(t.denominator)), ("num", .int(t.numerator))])
        }
        let positions = keyframePositions.map { row -> RenderCanonicalEncoding.Value in
            .array(row.map { .int($0.rawValue) })
        }
        let easing = keyframeEasing.map { e -> RenderCanonicalEncoding.Value in
            e.map { $0.canonicalValue() } ?? .object([("null", .bool(true))])
        }
        return .object([
            ("indices", .array(indices.map { .int(Int64($0)) })),
            ("keyframeEasing", .array(easing)),
            ("keyframePositions", .array(positions)),
            ("keyframeTimes", .array(times)),
            ("pathID", .int(Int64(pathID))),
            ("vertexCount", .int(Int64(vertexCount)))
        ])
    }
}
