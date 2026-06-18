import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §7.2, §13 rows "Animation" / parent transforms / fixed-point cubic interpolation
/// (§17 step 9) — deterministic on-demand sampling of a compiled AnimIR program at an exact animation
/// time, plus the local→world transform chain.
///
/// All sampling is exact fixed point (no `Float`/`Double`): keyframe times are AnimIR **frame numbers**
/// (`RationalSourceTime`); an `AnimationPlaybackTime` (240,000 ticks/second) is converted to a frame
/// number via `meta.fps`. Cubic-bezier easing between keyframes uses `CubicBezierSampler`; a `hold`
/// keyframe takes the earlier value verbatim. The local matrix is `T(pos)·R(rot)·S(scale)·T(-anchor)`
/// and `world(child) = world(parent) · local(child)` (parent chain computed root→child); a cycle, a
/// missing parent, an overflow or a malformed track is a typed error.
public enum AnimationSampler {

    /// A layer's sampled draw state: its world transform (source/comp-local → composition space) and
    /// its sampled opacity.
    public struct SampledLayer: Hashable, Sendable {
        public let worldTransform: FixedAffineTransform2D
        public let opacity: OpacityScalar
        public init(worldTransform: FixedAffineTransform2D, opacity: OpacityScalar) {
            self.worldTransform = worldTransform
            self.opacity = opacity
        }
    }

    // MARK: - Animation-request → frame time

    /// The AnimIR frame number to sample for `request`, given the program meta and the layer timing.
    /// Returns `nil` when the layer is inactive (no draw command is emitted).
    ///
    ///   * `.inactive`     → `nil`;
    ///   * `.sample(t)`    → the frame at playback time `t`;
    ///   * `.looped(t)`    → the frame at `t` wrapped into `[0, authoredDuration)`;
    ///   * `.holdLast`     → the program's **last representable authored instant** (corrective #8): the
    ///     frame just inside `meta.outPoint`, so each track clamps to its final keyframe value rather
    ///     than sampling the exclusive end. `outPoint − 1 frame` is the closed-interval last instant.
    public static func frameTime(
        for request: AnimationRequest,
        meta: RenderProgramMeta,
        authoredDurationTicks: Int64
    ) throws -> RationalSourceTime? {
        switch request {
        case .inactive:
            return nil
        case .holdLast:
            // The last representable authored instant is `outPoint − 1 frame` (outPoint is exclusive),
            // clamped to not precede `inPoint`. Tracks then clamp to their final keyframe value.
            let negOne = try RationalSourceTime(numerator: -1, denominator: 1)
            let lastInstant = try meta.outPoint.adding(negOne)
            return lastInstant < meta.inPoint ? meta.inPoint : lastInstant
        case .sample(let t):
            return try frame(atPlaybackTicks: t.ticks, fps: meta.fps)
        case .looped(let t):
            guard authoredDurationTicks > 0 else {
                throw RenderGraphError.malformedTrack(field: "AnimationRequest.looped", detail: "non-positive authored duration")
            }
            // `AnimationPlaybackTime.ticks` is non-negative (validated at construction), so `% d` is
            // already in `[0, d)`; no overflow-prone `+ d` is needed (corrective #8).
            let wrapped = t.ticks % authoredDurationTicks
            return try frame(atPlaybackTicks: wrapped, fps: meta.fps)
        }
    }

    /// `frame = ticks / ticksPerSecond · fps` as an exact `RationalSourceTime`.
    static func frame(atPlaybackTicks ticks: Int64, fps: RationalSourceTime) throws -> RationalSourceTime {
        // ticks/240000 · (fpsNum/fpsDen) = (ticks·fpsNum) / (240000·fpsDen), reduced.
        let ticksRational = try RationalSourceTime(numerator: ticks, denominator: TickClock.ticksPerSecond)
        return try ticksRational.multiplied(by: fps)
    }

    // MARK: - Layer timing (corrective #8)

    /// Applies `RenderLayerTiming` to a composition frame: a layer occupies `[inPoint, outPoint)` in
    /// composition time, and its tracks are sampled at `compFrame − startTime`. Returns `nil` when the
    /// layer is **inactive** at `compFrame` (the compiler emits no draw for it). The bracket is
    /// half-open — `outPoint` is exclusive — and `holdLast` is realised by the **caller** sampling at
    /// the layer's last representable authored instant (the clamp inside `locate`), not by passing
    /// `outPoint` here.
    public static func layerLocalFrame(_ timing: RenderLayerTiming, compFrame: RationalSourceTime) throws -> RationalSourceTime? {
        // Active iff inPoint <= compFrame < outPoint.
        if compFrame < timing.inPoint { return nil }
        if !(compFrame < timing.outPoint) { return nil }
        return try layerTransformFrame(timing, compFrame: compFrame)
    }

    /// The frame a layer's **transform tracks** are sampled at: always `compFrame − startTime`,
    /// independent of the layer's visible interval (step-9 final corrective #3). A parent contributes
    /// its transform to its children even when the parent itself is outside its visible range, so the
    /// parent-chain composition uses this (never a visibility-gated frame). Subtraction is full-width
    /// with no `Int64` negation (issue #2).
    public static func layerTransformFrame(_ timing: RenderLayerTiming, compFrame: RationalSourceTime) throws -> RationalSourceTime {
        try compFrame.subtracting(timing.startTime)
    }

    // MARK: - Track sampling

    /// Samples a vector track (position/anchor) at `frame`, returning `(x, y)` in `CanvasScalar` raw.
    public static func sampleVector(_ track: RenderVectorTrack, at frame: RationalSourceTime, field: String) throws -> (x: Int64, y: Int64) {
        switch track {
        case .static(let v):
            return (v.x.rawValue, v.y.rawValue)
        case .keyframed(let kfs):
            let (lo, hi, s) = try locate(kfs, at: frame, field: field)
            guard let hi else { return (lo.value.x.rawValue, lo.value.y.rawValue) }
            let frac = try easedFraction(s: s, out: lo.outTangent, in: hi.inTangent, hold: lo.hold)
            return (try lerp(lo.value.x.rawValue, hi.value.x.rawValue, frac, "\(field).x"),
                    try lerp(lo.value.y.rawValue, hi.value.y.rawValue, frac, "\(field).y"))
        }
    }

    /// Samples a scale track at `frame`, returning `(sx, sy)` in `ScaleScalar` raw.
    public static func sampleScale(_ track: RenderScaleTrack, at frame: RationalSourceTime, field: String) throws -> (x: Int64, y: Int64) {
        switch track {
        case .static(let v):
            return (v.x.rawValue, v.y.rawValue)
        case .keyframed(let kfs):
            let (lo, hi, s) = try locate(kfs, at: frame, field: field)
            guard let hi else { return (lo.value.x.rawValue, lo.value.y.rawValue) }
            let frac = try easedFraction(s: s, out: lo.outTangent, in: hi.inTangent, hold: lo.hold)
            return (try lerp(lo.value.x.rawValue, hi.value.x.rawValue, frac, "\(field).sx"),
                    try lerp(lo.value.y.rawValue, hi.value.y.rawValue, frac, "\(field).sy"))
        }
    }

    /// Samples a rotation track at `frame`, returning `RotationScalar` raw.
    public static func sampleRotation(_ track: RenderRotationTrack, at frame: RationalSourceTime, field: String) throws -> Int64 {
        switch track {
        case .static(let v):
            return v.rawValue
        case .keyframed(let kfs):
            let (lo, hi, s) = try locate(kfs, at: frame, field: field)
            guard let hi else { return lo.value.rawValue }
            let frac = try easedFraction(s: s, out: lo.outTangent, in: hi.inTangent, hold: lo.hold)
            return try lerp(lo.value.rawValue, hi.value.rawValue, frac, field)
        }
    }

    /// Samples a scalar track (e.g. stroke width) at `frame`, returning `CanvasScalar` raw.
    public static func sampleScalar(_ track: RenderScalarTrack, at frame: RationalSourceTime, field: String) throws -> Int64 {
        switch track {
        case .static(let v):
            return v.rawValue
        case .keyframed(let kfs):
            let (lo, hi, s) = try locate(kfs, at: frame, field: field)
            guard let hi else { return lo.value.rawValue }
            let frac = try easedFraction(s: s, out: lo.outTangent, in: hi.inTangent, hold: lo.hold)
            return try lerp(lo.value.rawValue, hi.value.rawValue, frac, field)
        }
    }

    /// Samples an opacity track at `frame`, returning a validated `OpacityScalar`.
    public static func sampleOpacity(_ track: RenderOpacityTrack, at frame: RationalSourceTime, field: String) throws -> OpacityScalar {
        let raw: Int64
        switch track {
        case .static(let v):
            raw = v.rawValue
        case .keyframed(let kfs):
            let (lo, hi, s) = try locate(kfs, at: frame, field: field)
            if let hi {
                let frac = try easedFraction(s: s, out: lo.outTangent, in: hi.inTangent, hold: lo.hold)
                raw = try lerp(lo.value.rawValue, hi.value.rawValue, frac, field)
            } else {
                raw = lo.value.rawValue
            }
        }
        return try OpacityScalar(rawValue: min(max(raw, 0), OpacityScalar.unitsPerUnit))
    }

    // MARK: - Local / world transform

    /// The local transform of a sampled `RenderTransform`: `T(position)·R(rotation)·S(scale)·T(-anchor)`.
    public static func localTransform(_ transform: RenderTransform, at frame: RationalSourceTime, field: String) throws -> FixedAffineTransform2D {
        let pos = try sampleVector(transform.position, at: frame, field: "\(field).position")
        let anchor = try sampleVector(transform.anchor, at: frame, field: "\(field).anchor")
        let scale = try sampleScale(transform.scale, at: frame, field: "\(field).scale")
        let rotationRaw = try sampleRotation(transform.rotation, at: frame, field: "\(field).rotation")

        let t = FixedAffineTransform2D.translation(tx: pos.x, ty: pos.y)
        let r = try FixedAffineTransform2D.rotation(degreesTimesUnitsPerDegree: rotationRaw)
        let sMatrix = FixedAffineTransform2D.scale(scaleX: scale.x, scaleY: scale.y)
        let negAnchor = FixedAffineTransform2D.translation(
            tx: try CheckedInt64.subtract(0, anchor.x, "anchor.negX"),
            ty: try CheckedInt64.subtract(0, anchor.y, "anchor.negY"))
        // T(pos) · R · S · T(-anchor)
        return try t.concatenating(r).concatenating(sMatrix).concatenating(negAnchor)
    }

    /// The world transform of `layer` within `composition` at `frame`: `world(child)=world(parent)·local(child)`,
    /// parent chain resolved root→child. A cycle or a missing parent is a typed error.
    public static func worldTransform(
        ofLayerID layerID: Int, in composition: RenderComposition, at frame: RationalSourceTime
    ) throws -> FixedAffineTransform2D {
        let layersByID = try indexLayers(composition)
        // Walk parents to the root, detecting cycles, collecting the chain root→child.
        var chain: [RenderLayer] = []
        var seen = Set<Int>()
        var currentID: Int? = layerID
        while let id = currentID {
            guard let layer = layersByID[id] else {
                throw RenderGraphError.missingParentLayer(compID: composition.id, layerID: layerID, parentLayerID: id)
            }
            guard seen.insert(id).inserted else {
                throw RenderGraphError.parentCycle(compID: composition.id, layerID: id)
            }
            chain.append(layer)
            currentID = layer.parentLayerID
        }
        // chain is child→…→root; compose root→child so world = local(root)·…·local(child) applied as
        // world(child)=world(parent)·local(child).
        var world = FixedAffineTransform2D.identity
        for layer in chain.reversed() {
            let local = try localTransform(layer.transform, at: frame, field: "comp[\(composition.id)].layer[\(layer.id)]")
            world = try world.concatenating(local)
        }
        return world
    }

    /// Samples the opacity of a single layer's own transform (not multiplied through the parent chain).
    public static func layerOpacity(_ layer: RenderLayer, at frame: RationalSourceTime) throws -> OpacityScalar {
        try sampleOpacity(layer.transform.opacity, at: frame, field: "comp.layer[\(layer.id)].opacity")
    }

    // MARK: - Helpers

    private static func indexLayers(_ composition: RenderComposition) throws -> [Int: RenderLayer] {
        var byID: [Int: RenderLayer] = [:]
        for layer in composition.layers {
            guard byID[layer.id] == nil else {
                throw RenderGraphError.malformedTrack(
                    field: "comp[\(composition.id)].layers", detail: "duplicate layer id \(layer.id)")
            }
            byID[layer.id] = layer
        }
        return byID
    }

    /// Locates the bracketing keyframes for `frame`. Returns `(lo, hi?, s)` where `hi == nil` means the
    /// sample is clamped to `lo` (before the first or at/after the last keyframe), and `s` is the
    /// normalized `[0,1]` segment position when `hi != nil`. Rejects an empty or non-increasing track.
    private static func locate<V>(
        _ kfs: [RenderKeyframe<V>], at frame: RationalSourceTime, field: String
    ) throws -> (lo: RenderKeyframe<V>, hi: RenderKeyframe<V>?, s: UnitInterval) {
        guard !kfs.isEmpty else {
            throw RenderGraphError.malformedTrack(field: field, detail: "empty keyframe list")
        }
        // Strictly increasing times.
        for i in 1..<kfs.count where !(kfs[i - 1].time < kfs[i].time) {
            throw RenderGraphError.malformedTrack(field: field, detail: "keyframe times not strictly increasing")
        }
        // Before the first / at-or-after the last → clamp.
        if frame < kfs[0].time { return (kfs[0], nil, .zero) }
        if !(frame < kfs[kfs.count - 1].time) { return (kfs[kfs.count - 1], nil, .zero) }
        // Find the segment [i, i+1) containing `frame`.
        var i = 0
        while i + 1 < kfs.count, !(frame < kfs[i + 1].time) { i += 1 }
        let lo = kfs[i], hi = kfs[i + 1]
        let s = try normalizedPosition(frame: frame, t0: lo.time, t1: hi.time, field: field)
        return (lo, hi, s)
    }

    /// `s = (frame − t0) / (t1 − t0)` as a `UnitInterval`, exact and overflow-free (corrective #8): the
    /// division is formed with the 128-bit-safe `RationalSourceTime` arithmetic (which cross-cancels),
    /// then scaled into unit units with one full-width multiply/divide — no intermediate `a·b·c` that
    /// could overflow `Int64`.
    static func normalizedPosition(frame: RationalSourceTime, t0: RationalSourceTime, t1: RationalSourceTime, field: String) throws -> UnitInterval {
        // Subtraction is full-width with no Int64 negation (issue #2).
        let num = try frame.subtracting(t0)                     // frame − t0  (>= 0 in the segment)
        let den = try t1.subtracting(t0)                        // t1 − t0     (> 0 since t0 < t1)
        guard den.numerator > 0 else {
            throw RenderGraphError.malformedTrack(field: field, detail: "non-positive segment length")
        }
        // ratio = num / den, formed with the cross-cancelling 128-bit-safe rational multiply
        // (num · (den.denominator / den.numerator)). `ratio ∈ [0, 1]` within the segment.
        let denReciprocal = try RationalSourceTime(numerator: den.denominator, denominator: den.numerator)
        let ratio = try num.multiplied(by: denReciprocal)
        guard ratio.denominator > 0 else {
            throw RenderGraphError.malformedTrack(field: field, detail: "non-positive normalized denom")
        }
        // s_raw = round(ratio.numerator · u / ratio.denominator) — single full-width multiply/divide.
        let u = UnitInterval.unitsPerUnit
        let raw = try FixedPointMath.multiplyDivideRounding(ratio.numerator, u, ratio.denominator, "\(field).s")
        return try UnitInterval(rawValue: min(max(raw, 0), u))
    }

    /// The eased interpolation fraction for a segment. A `hold` lower keyframe returns `0` (no
    /// interpolation — the value stays at `lo` across the segment).
    private static func easedFraction(s: UnitInterval, out: RenderEasingVec2?, in inTan: RenderEasingVec2?, hold: Bool) throws -> UnitInterval {
        if hold { return .zero }
        return try CubicBezierSampler.ease(s: s, outTangent: out, inTangent: inTan)
    }

    /// `lo + (hi − lo)·frac` in fixed point, computed as `(lo·(u − frac) + hi·frac) / u` so there is
    /// **no `hi − lo` intermediate** to overflow and only the final result is range-checked (issue #2).
    /// `u − frac ∈ [0, u]` and `frac ∈ [0, u]` are both non-negative, so no negation occurs.
    static func lerp(_ lo: Int64, _ hi: Int64, _ frac: UnitInterval, _ field: String) throws -> Int64 {
        let u = UnitInterval.unitsPerUnit
        let oneMinus = u - frac.rawValue            // in [0, u], no overflow
        return try FixedPointMath.weightedSumDivide(lo, oneMinus, hi, frac.rawValue, u, "\(field).lerp")
    }

    // MARK: - Path sampling (corrective #5)

    /// Samples a `RenderAnimatedPath` at `frame` into a flat `SampledBezier` (vertices/tangents in
    /// `CanvasScalar` raw units). A static path is returned verbatim; a keyframed path interpolates
    /// per-vertex with the same clamp/segment logic as the scalar tracks. An empty/invalid bezier
    /// (mismatched vertex/tangent counts) is a typed failure.
    public static func samplePath(_ path: RenderAnimatedPath, at frame: RationalSourceTime, pathID: Int?, field: String) throws -> SampledBezier {
        switch path {
        case .static(let bezier):
            return try flatten(bezier, pathID: pathID, field: field)
        case .keyframed(let kfs):
            let (lo, hi, s) = try locate(kfs, at: frame, field: field)
            guard let hi else { return try flatten(lo.value, pathID: pathID, field: field) }
            let frac = try easedFractionPublic(s: s, out: lo.outTangent, in: hi.inTangent, hold: lo.hold)
            return try interpolate(lo.value, hi.value, frac, pathID: pathID, field: field)
        }
    }

    private static func flatten(_ bezier: RenderBezier, pathID: Int?, field: String) throws -> SampledBezier {
        let n = bezier.vertices.count
        guard n > 0, bezier.inTangents.count == n, bezier.outTangents.count == n else {
            throw RenderGraphError.malformedTrack(field: field, detail: "empty or mismatched bezier vertex/tangent counts")
        }
        var v: [Int64] = [], i: [Int64] = [], o: [Int64] = []
        v.reserveCapacity(n * 2); i.reserveCapacity(n * 2); o.reserveCapacity(n * 2)
        for k in 0..<n {
            v.append(bezier.vertices[k].x.rawValue); v.append(bezier.vertices[k].y.rawValue)
            i.append(bezier.inTangents[k].x.rawValue); i.append(bezier.inTangents[k].y.rawValue)
            o.append(bezier.outTangents[k].x.rawValue); o.append(bezier.outTangents[k].y.rawValue)
        }
        return SampledBezier(vertices: v, inTangents: i, outTangents: o, closed: bezier.closed, pathID: pathID)
    }

    private static func interpolate(_ a: RenderBezier, _ b: RenderBezier, _ frac: UnitInterval, pathID: Int?, field: String) throws -> SampledBezier {
        guard a.vertices.count == b.vertices.count, a.closed == b.closed else {
            throw RenderGraphError.malformedTrack(field: field, detail: "keyframed bezier shape changed across keyframes")
        }
        let fa = try flatten(a, pathID: pathID, field: field)
        let fb = try flatten(b, pathID: pathID, field: field)
        func mix(_ x: [Int64], _ y: [Int64]) throws -> [Int64] {
            try zip(x, y).map { try lerp($0, $1, frac, field) }
        }
        return SampledBezier(
            vertices: try mix(fa.vertices, fb.vertices), inTangents: try mix(fa.inTangents, fb.inTangents),
            outTangents: try mix(fa.outTangents, fb.outTangents), closed: a.closed, pathID: pathID)
    }

    /// Exposed eased-fraction helper for path interpolation (mirrors the private scalar-track helper).
    private static func easedFractionPublic(s: UnitInterval, out: RenderEasingVec2?, in inTan: RenderEasingVec2?, hold: Bool) throws -> UnitInterval {
        if hold { return .zero }
        return try CubicBezierSampler.ease(s: s, outTangent: out, inTangent: inTan)
    }
}
