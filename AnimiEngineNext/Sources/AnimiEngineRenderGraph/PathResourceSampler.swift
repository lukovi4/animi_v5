import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 / Step-11 (Rev-4 §3.3) — exact sampling of a producer **flattened** path mesh.
///
/// This is distinct from `AnimationSampler.samplePath`, which samples authored Bézier control anchors
/// (`SampledBezier`). `PathResourceSampler` samples `RenderPathResource.keyframePositions` — the
/// producer-flattened vertices the producer triangle `indices` address — into a ``SampledPathMesh``.
///
/// All arithmetic is exact fixed point: no `Double`, `Float`, platform trig, or Bézier re-flattening.
/// Times are exact rationals; easing reuses the existing `CubicBezierSampler`; coordinate interpolation
/// reuses `AnimationSampler.lerp` (full-width checked fixed-point). The resource's authoritative indices
/// are returned unchanged.
enum PathResourceSampler {

    static func sample(
        resource: RenderPathResource,
        closed: Bool,
        at time: RationalSourceTime,
        field: String
    ) throws -> SampledPathMesh {
        // 1) Strictly increasing keyframe times.
        let times = resource.keyframeTimes
        guard !times.isEmpty else {
            throw RenderGraphError.malformedTrack(field: field, detail: "empty keyframe times")
        }
        for i in 1..<times.count where !(times[i - 1] < times[i]) {
            throw RenderGraphError.malformedTrack(field: field, detail: "keyframe times not strictly increasing")
        }

        // 2) Every row has exactly vertexCount*2 coordinates.
        let expectedRow = try CheckedInt64.multiply(Int64(resource.vertexCount), 2, "\(field).vertexCount*2")
        guard times.count == resource.keyframePositions.count else {
            throw RenderGraphError.malformedTrack(
                field: field, detail: "times \(times.count) != positions \(resource.keyframePositions.count)")
        }
        for (i, row) in resource.keyframePositions.enumerated() where Int64(row.count) != expectedRow {
            throw RenderGraphError.malformedTrack(
                field: field, detail: "keyframePositions[\(i)] row \(row.count) != vertexCount*2 \(expectedRow)")
        }

        // 3) Indices against vertexCount (the mesh initializer re-validates against sampled positions).
        try SampledMeshValidation.validateIndices(
            resource.indices, vertexCount: resource.vertexCount, field: "\(field).indices")

        // 4)/5)/6) Select or interpolate the sampled row.
        let sampledRow = try sampledPositions(resource: resource, at: time, expectedRow: Int(expectedRow), field: field)

        // 7) Authoritative indices unchanged.
        return try SampledPathMesh(
            pathID: resource.pathID, positions: sampledRow, indices: resource.indices, closed: closed)
    }

    /// The sampled `vertexCount*2` coordinate row at `time`, as `CanvasScalar`.
    private static func sampledPositions(
        resource: RenderPathResource, at time: RationalSourceTime, expectedRow: Int, field: String
    ) throws -> [CanvasScalar] {
        let times = resource.keyframeTimes
        let rows = resource.keyframePositions

        // 4) Before the first keyframe → first row.
        if time < times[0] {
            return rows[0]
        }
        // 5) At or after the last keyframe → last row.
        if !(time < times[times.count - 1]) {
            return rows[times.count - 1]
        }
        // 6) Between keyframes: find segment [i, i+1).
        var i = 0
        while i + 1 < times.count, !(time < times[i + 1]) { i += 1 }

        // Easing index: keyframeEasing.count == keyframeCount - 1, segment i uses easing[i].
        guard i < resource.keyframeEasing.count else {
            throw RenderGraphError.malformedTrack(
                field: field, detail: "no easing segment for keyframe \(i)")
        }
        let easing = resource.keyframeEasing[i]

        // Hold semantics: a hold segment keeps the lower row across the segment.
        if easing?.hold == true {
            return rows[i]
        }

        // Eased fraction: normalized segment position → cubic-bezier ease (reusing the existing sampler).
        let s = try AnimationSampler.normalizedPosition(
            frame: time, t0: times[i], t1: times[i + 1], field: field)
        let outTangent: RenderEasingVec2?
        let inTangent: RenderEasingVec2?
        if let e = easing {
            outTangent = RenderEasingVec2(x: e.outX, y: e.outY)
            inTangent = RenderEasingVec2(x: e.inX, y: e.inY)
        } else {
            outTangent = nil
            inTangent = nil
        }
        let frac = try CubicBezierSampler.ease(s: s, outTangent: outTangent, inTangent: inTangent)

        // Linearly interpolate every coordinate with full-width checked fixed-point arithmetic.
        let lo = rows[i], hi = rows[i + 1]
        var out: [CanvasScalar] = []
        out.reserveCapacity(expectedRow)
        for k in 0..<expectedRow {
            let v = try AnimationSampler.lerp(lo[k].rawValue, hi[k].rawValue, frac, "\(field).coord[\(k)]")
            out.append(CanvasScalar(rawValue: v))
        }
        return out
    }
}

/// Rev-4 §3.2 — resolves the `closed` flag of an animated path, requiring it to be invariant across all
/// keyframes (a `closed` flag changing across keyframes is a typed `pathResourceMismatch`).
enum PathClosedResolver {
    static func invariantClosed(_ path: RenderAnimatedPath, pathID: Int, field: String) throws -> Bool {
        switch path {
        case .static(let bezier):
            return bezier.closed
        case .keyframed(let kfs):
            guard let first = kfs.first else {
                throw RenderGraphError.pathResourceMismatch(pathID: pathID, field: field, detail: "empty keyframed path")
            }
            let closed = first.value.closed
            for kf in kfs where kf.value.closed != closed {
                throw RenderGraphError.pathResourceMismatch(
                    pathID: pathID, field: field, detail: "closed flag changes across keyframes")
            }
            return closed
        }
    }
}
