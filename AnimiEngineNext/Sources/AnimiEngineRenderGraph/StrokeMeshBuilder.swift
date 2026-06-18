import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 / Step-11 (Rev-4 §4) — deterministic stroke-mesh construction in the graph (not in Metal).
///
/// Builds an execution-ready ``SampledTriangleMesh`` from a producer-flattened polyline
/// (``SampledPathMesh``). The geometry is exact fixed point via ``FixedVectorMath`` and
/// ``FixedTrig``: segment quads, caps (butt/square/round), joins (miter/round/bevel) with miter-limit
/// bevel fallback, and one fixed 1-degree angular step for round caps/joins. No `Double`/`Float`, no
/// platform trig, no Bézier re-flattening, no adaptive tolerance.
enum StrokeMeshBuilder {

    /// `RotationScalar` raw units per degree (1,000), per §4.8.
    static let rawUnitsPerDegree: Int64 = 1_000
    /// Maximum authored stroke width: 2048 points (§4.3.7).
    static let maxWidthRaw: Int64 = 2048 * CanvasScalar.unitsPerPoint
    /// Linear scale used for `FixedTrig.cosSin` output (1.0 == 1_000_000 raw).
    static let trigUnitsPerOne: Int64 = 1_000_000

    static func build(
        path: SampledPathMesh,
        width: CanvasScalar,
        lineCap: RenderStrokeLineCap,
        lineJoin: RenderStrokeLineJoin,
        miterLimit: MiterScalar
    ) throws -> SampledTriangleMesh {
        let field = "StrokeMeshBuilder(path \(path.pathID))"

        // §4.3.6/4.3.7 — width bounds.
        guard width.rawValue > 0 else {
            throw RenderGraphError.unsupportedStrokeGeometry(field: field, detail: "non-positive width \(width.rawValue)")
        }
        guard width.rawValue <= maxWidthRaw else {
            throw RenderGraphError.unsupportedStrokeGeometry(field: field, detail: "width \(width.rawValue) exceeds max \(maxWidthRaw)")
        }
        // §4.4 — half-width: checked divide-by-two, nearest, ties away from zero. width > 0 so floor+round.
        let halfWidth = try FixedPointMath.multiplyDivideRounding(width.rawValue, 1, 2, "\(field).halfWidth")
        guard halfWidth > 0 else {
            throw RenderGraphError.unsupportedStrokeGeometry(field: field, detail: "half-width rounds to zero")
        }

        // §4.3.1/4.3.2/4.3.3 — parse + deterministic duplicate removal + closed final-point fold.
        let points = try normalizedPoints(path: path, field: field)

        // §4.3.4/4.3.5 — minimum distinct points.
        if path.closed {
            guard points.count >= 3 else {
                throw RenderGraphError.unsupportedStrokeGeometry(field: field, detail: "closed path needs >= 3 distinct points, got \(points.count)")
            }
        } else {
            guard points.count >= 2 else {
                throw RenderGraphError.unsupportedStrokeGeometry(field: field, detail: "open path needs >= 2 distinct points, got \(points.count)")
            }
        }
        // §4.3.8 — positive miter limit for miter joins.
        if lineJoin == .miter {
            guard miterLimit.rawValue > 0 else {
                throw RenderGraphError.unsupportedStrokeGeometry(field: field, detail: "non-positive miter limit for miter join")
            }
        }

        var builder = MeshAccumulator()

        // The directed segment list (closed paths wrap the last→first segment).
        let segmentCount = path.closed ? points.count : points.count - 1
        var segments: [Segment] = []
        segments.reserveCapacity(segmentCount)
        for s in 0..<segmentCount {
            let a = points[s]
            let b = points[(s + 1) % points.count]
            let dir = try FixedVectorMath.subtract(b, a, "\(field).seg[\(s)]")
            // §4.3.9 — an exact 180-degree reversal (zero-length already removed; check between segments below).
            let offset = try FixedVectorMath.perpendicularOffset(segment: dir, halfWidth: halfWidth, "\(field).seg[\(s)]")
            segments.append(Segment(a: a, b: b, dir: dir, offset: offset))
        }

        // §4.3.9 — reject an exact 180-degree direction reversal at any join.
        try rejectReversals(points: points, closed: path.closed, field: field)

        // §4.5 — segment quads.
        for seg in segments {
            try builder.addSegmentQuad(seg, field: field)
        }

        // §4.7 — joins (interior, plus the wrap join for closed paths).
        let joinCount = path.closed ? segmentCount : segmentCount - 1
        for j in 0..<joinCount {
            let inSeg = segments[j]
            let outSeg = segments[(j + 1) % segmentCount]
            try builder.addJoin(
                incoming: inSeg, outgoing: outSeg, vertex: outSeg.a,
                lineJoin: lineJoin, halfWidth: halfWidth, miterLimit: miterLimit, field: field)
        }

        // §4.6 — caps (open paths only).
        if !path.closed {
            try builder.addCap(at: segments[0].a, segment: segments[0], halfWidth: halfWidth, cap: lineCap, isStart: true, field: field)
            let last = segments[segmentCount - 1]
            try builder.addCap(at: last.b, segment: last, halfWidth: halfWidth, cap: lineCap, isStart: false, field: field)
        }

        return try builder.finish()
    }

    // MARK: - Input normalization (§4.3)

    private static func normalizedPoints(path: SampledPathMesh, field: String) throws -> [FixedVectorMath.Vec2] {
        let positions = path.positions
        var pts: [FixedVectorMath.Vec2] = []
        pts.reserveCapacity(positions.count / 2)
        var i = 0
        while i + 1 < positions.count {
            let p = FixedVectorMath.Vec2(x: positions[i].rawValue, y: positions[i + 1].rawValue)
            // §4.3.2 — remove consecutive duplicate points deterministically.
            if let last = pts.last, last == p {
                i += 2
                continue
            }
            pts.append(p)
            i += 2
        }
        // §4.3.3 — closed path: drop a final point equal to the first.
        if path.closed, pts.count >= 2, pts.first == pts.last {
            pts.removeLast()
        }
        return pts
    }

    /// §4.3.9 — at every join the outgoing direction must not be the exact 180-degree reverse of the
    /// incoming direction (cross == 0 and dot < 0 → collinear, opposite). Rejected with a typed error.
    private static func rejectReversals(points: [FixedVectorMath.Vec2], closed: Bool, field: String) throws {
        let n = points.count
        let joinCount = closed ? n : n - 2
        guard joinCount > 0 else { return }
        for j in 0..<joinCount {
            let a = points[j % n]
            let b = points[(j + 1) % n]
            let c = points[(j + 2) % n]
            let inDir = try FixedVectorMath.subtract(b, a, "\(field).rev.in[\(j)]")
            let outDir = try FixedVectorMath.subtract(c, b, "\(field).rev.out[\(j)]")
            let cross = try FixedVectorMath.cross(inDir, outDir, "\(field).rev.cross[\(j)]")
            let dot = try FixedVectorMath.dot(inDir, outDir, "\(field).rev.dot[\(j)]")
            if cross == 0, dot < 0 {
                throw RenderGraphError.unsupportedStrokeGeometry(
                    field: field, detail: "exact 180-degree reversal at join \(j)")
            }
        }
    }

    // MARK: - Segment model

    struct Segment {
        let a: FixedVectorMath.Vec2
        let b: FixedVectorMath.Vec2
        let dir: FixedVectorMath.Vec2
        /// Left-perpendicular half-width offset (+offset = left edge, −offset = right edge).
        let offset: FixedVectorMath.Vec2
    }

    // MARK: - Mesh accumulator

    struct MeshAccumulator {
        private var positions: [CanvasScalar] = []
        private var indices: [Int] = []
        // Deduplicate identical vertices deterministically for compact, stable index buffers.
        private var indexByPoint: [FixedVectorMath.Vec2: Int] = [:]

        mutating func vertex(_ p: FixedVectorMath.Vec2) -> Int {
            if let existing = indexByPoint[p] { return existing }
            let idx = positions.count / 2
            positions.append(CanvasScalar(rawValue: p.x))
            positions.append(CanvasScalar(rawValue: p.y))
            indexByPoint[p] = idx
            return idx
        }

        mutating func triangle(_ p0: FixedVectorMath.Vec2, _ p1: FixedVectorMath.Vec2, _ p2: FixedVectorMath.Vec2) {
            // Skip degenerate (zero-area / duplicate-vertex) triangles deterministically.
            if p0 == p1 || p1 == p2 || p0 == p2 { return }
            indices.append(vertex(p0))
            indices.append(vertex(p1))
            indices.append(vertex(p2))
        }

        mutating func addSegmentQuad(_ seg: Segment, field: String) throws {
            // left = p + offset, right = p − offset.
            let aL = try FixedVectorMath.add(seg.a, seg.offset, "\(field).aL")
            let aR = try FixedVectorMath.subtract(seg.a, seg.offset, "\(field).aR")
            let bL = try FixedVectorMath.add(seg.b, seg.offset, "\(field).bL")
            let bR = try FixedVectorMath.subtract(seg.b, seg.offset, "\(field).bR")
            triangle(aL, aR, bL)
            triangle(bL, aR, bR)
        }

        mutating func addJoin(
            incoming: Segment, outgoing: Segment, vertex v: FixedVectorMath.Vec2,
            lineJoin: RenderStrokeLineJoin, halfWidth: Int64, miterLimit: MiterScalar, field: String
        ) throws {
            let turn = try FixedVectorMath.cross(incoming.dir, outgoing.dir, "\(field).join.turn")
            // §4.7 — collinear same-direction join emits nothing.
            if turn == 0 {
                let dot = try FixedVectorMath.dot(incoming.dir, outgoing.dir, "\(field).join.dot")
                if dot >= 0 { return }   // straight continuation (reversal already rejected upstream)
            }
            // Outer side of the turn. turn > 0 (left turn) → outer is the right edge (−offset);
            // turn < 0 (right turn) → outer is the left edge (+offset).
            let incomingOuter: FixedVectorMath.Vec2
            let outgoingOuter: FixedVectorMath.Vec2
            if turn > 0 {
                incomingOuter = try FixedVectorMath.subtract(v, incoming.offset, "\(field).join.io")
                outgoingOuter = try FixedVectorMath.subtract(v, outgoing.offset, "\(field).join.oo")
            } else {
                incomingOuter = try FixedVectorMath.add(v, incoming.offset, "\(field).join.io")
                outgoingOuter = try FixedVectorMath.add(v, outgoing.offset, "\(field).join.oo")
            }

            switch lineJoin {
            case .bevel:
                triangle(v, incomingOuter, outgoingOuter)
            case .miter:
                let apex = try miterApex(
                    vertex: v, incomingOuter: incomingOuter, incomingDir: incoming.dir,
                    outgoingOuter: outgoingOuter, outgoingDir: outgoing.dir, field: field)
                if let apex,
                   try miterAcceptable(vertex: v, apex: apex, halfWidth: halfWidth, miterLimit: miterLimit) {
                    triangle(v, incomingOuter, apex)
                    triangle(v, apex, outgoingOuter)
                } else {
                    // §4.7 — miter-limit (or parallel) fallback to bevel.
                    triangle(v, incomingOuter, outgoingOuter)
                }
            case .round:
                try addArcFan(center: v, from: incomingOuter, to: outgoingOuter, clockwise: turn < 0, halfWidth: halfWidth, field: field)
            }
        }

        private func miterApex(
            vertex v: FixedVectorMath.Vec2,
            incomingOuter: FixedVectorMath.Vec2, incomingDir: FixedVectorMath.Vec2,
            outgoingOuter: FixedVectorMath.Vec2, outgoingDir: FixedVectorMath.Vec2, field: String
        ) throws -> FixedVectorMath.Vec2? {
            // Intersect the two outer offset lines.
            try FixedVectorMath.lineIntersection(
                p0: incomingOuter, d0: incomingDir, p1: outgoingOuter, d1: outgoingDir, "\(field).miter")
        }

        private func miterAcceptable(
            vertex v: FixedVectorMath.Vec2, apex: FixedVectorMath.Vec2, halfWidth: Int64, miterLimit: MiterScalar
        ) throws -> Bool {
            let miterVec = try FixedVectorMath.subtract(apex, v, "miter.len")
            let miterLength = try FixedVectorMath.length(miterVec, "miter.len")
            return FixedVectorMath.miterWithinLimit(
                miterLength: miterLength, halfWidth: halfWidth,
                miterLimitRaw: miterLimit.rawValue, miterUnitsPerOne: MiterScalar.unitsPerUnit)
        }

        /// §4.8 — round cap/join arc fan, one fixed 1-degree step. The start radius-vector
        /// (`start − center`) is rotated by successive 1-degree increments via `FixedTrig.cosSin`, the
        /// sweep direction taken from the cross-product sign, until the rotated vector crosses the end
        /// radius-vector (`end − center`); the final triangle is forced to the exact `end` so there is no
        /// accumulated endpoint drift. No atan2, no adaptive tolerance.
        mutating func addArcFan(
            center: FixedVectorMath.Vec2, from start: FixedVectorMath.Vec2, to end: FixedVectorMath.Vec2,
            clockwise: Bool, halfWidth: Int64, field: String
        ) throws {
            let startVec = try FixedVectorMath.subtract(start, center, "\(field).arc.start")
            let endVec = try FixedVectorMath.subtract(end, center, "\(field).arc.end")
            // Whole-degree sweep count in the chosen direction. The exterior turn is in (0°, 360°); we
            // derive it from start/end without trig by stepping 1° at a time and detecting when the rotated
            // vector crosses the `end` ray. To disambiguate the 180° (antiparallel) case — where
            // cross(start,end)==0 at both endpoints — we require the sweep to have advanced past 1° before
            // the crossing test can fire, and we cap at a full turn (deterministic upper bound).
            let step = (clockwise ? -1 : 1) * StrokeMeshBuilder.rawUnitsPerDegree
            var prev = start
            var k = 1
            while k < 360 {
                let angleRaw = step * Int64(k)
                let rotated = try rotate(startVec, byRaw: angleRaw, field: "\(field).arc[\(k)]")
                // Have we reached/passed the end ray? Detect via the sign of cross(rotated, end) relative
                // to the half we are sweeping into. After at least one step, the rotated vector lies on the
                // far side of `end` when the dot with end is positive AND cross has the terminal sign.
                let crossToEnd = try FixedVectorMath.cross(rotated, endVec, "\(field).arc.cmp[\(k)]")
                let dotToEnd = try FixedVectorMath.dot(rotated, endVec, "\(field).arc.dot[\(k)]")
                // Terminal condition (CCW): cross(rotated,end) <= 0 reached after we have entered the
                // positive-dot region (so we don't trip on the antiparallel start where dot < 0).
                let reached = clockwise
                    ? (crossToEnd >= 0 && dotToEnd > 0)
                    : (crossToEnd <= 0 && dotToEnd > 0)
                if reached { break }
                let p = FixedVectorMath.Vec2(
                    x: try CheckedInt64.add(center.x, rotated.x, "\(field).arc.px[\(k)]"),
                    y: try CheckedInt64.add(center.y, rotated.y, "\(field).arc.py[\(k)]"))
                triangle(center, prev, p)
                prev = p
                k += 1
            }
            // Force the final triangle to the exact target offset (avoids endpoint drift).
            triangle(center, prev, end)
        }

        /// Rotate a radius-vector by `angleRaw` (RotationScalar raw) about the origin, exact fixed point:
        /// `x' = x·cos − y·sin`, `y' = x·sin + y·cos`, scaled by `trigUnitsPerOne`.
        private func rotate(_ v: FixedVectorMath.Vec2, byRaw angleRaw: Int64, field: String) throws -> FixedVectorMath.Vec2 {
            let (cos, sin) = try FixedTrig.cosSin(rotationRaw: angleRaw, linearUnitsPerOne: StrokeMeshBuilder.trigUnitsPerOne)
            let u = StrokeMeshBuilder.trigUnitsPerOne
            let negSin = try CheckedInt64.subtract(0, sin, "\(field).negSin")
            // x' = (x·cos + y·(−sin)) / u ; y' = (x·sin + y·cos) / u — full-width, no Int64 overflow.
            let xr = try FixedPointMath.weightedSumDivide(v.x, cos, v.y, negSin, u, "\(field).xr")
            let yr = try FixedPointMath.weightedSumDivide(v.x, sin, v.y, cos, u, "\(field).yr")
            return FixedVectorMath.Vec2(x: xr, y: yr)
        }

        mutating func addCap(
            at point: FixedVectorMath.Vec2, segment seg: Segment, halfWidth: Int64,
            cap: RenderStrokeLineCap, isStart: Bool, field: String
        ) throws {
            switch cap {
            case .butt:
                return   // no extension
            case .square:
                // Extend by one half-width along the (out-pointing) segment direction.
                let dirLen = try FixedVectorMath.length(seg.dir, "\(field).cap.len")
                guard dirLen > 0 else { return }
                // Out-pointing direction: start cap points backward (−dir), end cap forward (+dir).
                let sign: Int64 = isStart ? -1 : 1
                let ex = try FixedPointMath.multiplyDivideRounding(seg.dir.x, sign * halfWidth, dirLen, "\(field).cap.ex")
                let ey = try FixedPointMath.multiplyDivideRounding(seg.dir.y, sign * halfWidth, dirLen, "\(field).cap.ey")
                let ext = FixedVectorMath.Vec2(x: ex, y: ey)
                let pL = try FixedVectorMath.add(point, seg.offset, "\(field).cap.pL")
                let pR = try FixedVectorMath.subtract(point, seg.offset, "\(field).cap.pR")
                let pLe = try FixedVectorMath.add(pL, ext, "\(field).cap.pLe")
                let pRe = try FixedVectorMath.add(pR, ext, "\(field).cap.pRe")
                triangle(pL, pR, pLe)
                triangle(pLe, pR, pRe)
            case .round:
                // Semicircle fan from one edge to the other through the out-pointing direction.
                let pL = try FixedVectorMath.add(point, seg.offset, "\(field).cap.pL")
                let pR = try FixedVectorMath.subtract(point, seg.offset, "\(field).cap.pR")
                // Start cap sweeps the outer semicircle (backward); end cap forward. The fan direction is
                // chosen so the arc bulges away from the segment body.
                if isStart {
                    try addArcFan(center: point, from: pR, to: pL, clockwise: false, halfWidth: halfWidth, field: "\(field).cap.arc")
                } else {
                    try addArcFan(center: point, from: pL, to: pR, clockwise: false, halfWidth: halfWidth, field: "\(field).cap.arc")
                }
            }
        }

        func finish() throws -> SampledTriangleMesh {
            try SampledTriangleMesh(positions: positions, indices: indices)
        }
    }
}
