import Metal
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §7 — clip math + image-draw geometry, all in checked fixed-point integer arithmetic.
///
/// This type is pure value-math (no Metal device); it produces the integer `MTLScissorRect`/empty-flag for
/// a clip (plan §7.5, approved R4-A) and the four NDC quad corners for an image draw (plan §7.2/§7.3).
/// Every addition/subtraction is checked (`CheckedInt64`); `ceilDiv` uses quotient/remainder and never
/// negates `Int64.min` (plan §7.5, Rev-4 correction #6).
enum MetalSceneCompositor {

    /// Corrective §5a — the pure, total classification of a command payload as supported (returns `nil`) or
    /// a deferred Step-11/12 category (returns its `(category, step)`). Extracted from the executor preflight
    /// so all **seven** deferred categories — including the unreachable-via-public-graph `endMask` — can be
    /// unit-tested without a device or a graph. Production preflight calls this for every command.
    static func unsupportedCommand(for payload: RenderCommandPayload) -> (category: String, step: Int)? {
        switch payload {
        case .drawShape, .beginMask, .endMask, .matteLink:
            // Step-11 categories are SUPPORTED (Rev-4 §7.8).
            return nil
        case .fadeTransition, .slideTransition, .pushTransition, .dipTransition, .overlay:
            // Step-12 + CP5.5 categories are SUPPORTED (cut/fade/slide/push/dip/overlay execution); no
            // category remains deferred.
            return nil
        case .clearBackground, .declareResource, .offscreenSurface, .beginScene, .endScene,
             .drawImage, .drawVideoFrame, .beginClip, .endClip, .finalLinearToSRGB, .finalOutput:
            return nil
        }
    }

    /// `ceil(a / b)` for `b > 0`, exact for every `Int64 a` including `Int64.min`. Uses quotient/remainder
    /// (`a == q*b + r`, `r` has the sign of `a`), never `-((-a)/b)` (Rev-4 correction #6). The `q + 1`
    /// add is checked. Returns a typed failure on a non-positive divisor (never produced: only `U` is used).
    static func ceilDiv(_ a: Int64, _ b: Int64) throws -> Int64 {
        guard b > 0 else {
            throw MetalRenderError.geometryOverflow(detail: "ceilDiv non-positive divisor \(b)")
        }
        let q = a / b
        let r = a % b
        if r > 0 {
            return try CheckedInt64.add(q, 1, "ceilDiv.+1")
        }
        return q
    }

    /// An integer scissor in target-pixel space, or an explicit empty flag (plan §7.5).
    struct ScissorBounds: Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let isEmpty: Bool

        static func empty() -> ScissorBounds { ScissorBounds(x: 0, y: 0, width: 0, height: 0, isEmpty: true) }
    }

    /// Compute one axis's half-open pixel span `[sx, sxEnd)` for clip canvas-raw bounds `[lo, hi)` against
    /// a target axis size `sizePx` (plan §7.5). Pixel `px` is included iff its center `px·U + U/2` lies in
    /// `[lo, hi)`. All arithmetic checked; result clamped to `[0, sizePx]`.
    static func axisSpan(lo: Int64, hi: Int64, sizePx: Int) throws -> (start: Int, end: Int) {
        let u = CanvasScalar.unitsPerPoint
        let h = u / 2  // 32_768
        // smallest px with px·U + H ≥ lo  ⟺  px ≥ (lo − H)/U  ⟹  pxMin = ceilDiv(lo − H, U)
        let loMinusH = try CheckedInt64.subtract(lo, h, "clip.lo-H")
        let pxMin = try ceilDiv(loMinusH, u)
        // largest px with px·U + H < hi  ⟺  px < (hi − H)/U  ⟹  pxMax = ceilDiv(hi − H, U) − 1
        let hiMinusH = try CheckedInt64.subtract(hi, h, "clip.hi-H")
        let pxMaxPlus1 = try ceilDiv(hiMinusH, u)         // == pxMax + 1
        // Clamp to [0, sizePx] in Int64, then to Int.
        let startRaw = clamp64(pxMin, 0, Int64(sizePx))
        let endRaw = clamp64(pxMaxPlus1, 0, Int64(sizePx))
        let start = Int(startRaw)
        let end = Int(max(startRaw, endRaw))
        return (start, end)
    }

    /// Compute the scissor for a single clip rect against the target pixel grid (plan §7.5).
    static func scissor(for rect: FixedRect, surfaceWidth: Int, surfaceHeight: Int) throws -> ScissorBounds {
        let x0 = rect.x.rawValue
        let x1 = try CheckedInt64.add(rect.x.rawValue, rect.width.rawValue, "clip.x1")
        let y0 = rect.y.rawValue
        let y1 = try CheckedInt64.add(rect.y.rawValue, rect.height.rawValue, "clip.y1")
        let (sx, sxEnd) = try axisSpan(lo: x0, hi: x1, sizePx: surfaceWidth)
        let (sy, syEnd) = try axisSpan(lo: y0, hi: y1, sizePx: surfaceHeight)
        let w = max(0, sxEnd - sx)
        let h = max(0, syEnd - sy)
        if w == 0 || h == 0 { return .empty() }
        return ScissorBounds(x: sx, y: sy, width: w, height: h, isEmpty: false)
    }

    /// Intersect two scissor bounds (nested clips, plan §7.5). An empty result keeps `isEmpty`. The end
    /// additions are **checked** (corrective §3, sites 3h/3i): an overflow throws `geometryOverflow` rather
    /// than trapping. (In practice both rects are clamped to `[0, sizePx]` so this cannot overflow, but the
    /// checked form makes that a typed failure regardless of input.)
    static func intersect(_ a: ScissorBounds, _ b: ScissorBounds) throws -> ScissorBounds {
        if a.isEmpty || b.isEmpty { return .empty() }
        let sx = max(a.x, b.x)
        let sy = max(a.y, b.y)
        let aEndX = try CheckedInt.add(a.x, a.width, .geometryOverflow(detail: "clip aEndX"))
        let bEndX = try CheckedInt.add(b.x, b.width, .geometryOverflow(detail: "clip bEndX"))
        let aEndY = try CheckedInt.add(a.y, a.height, .geometryOverflow(detail: "clip aEndY"))
        let bEndY = try CheckedInt.add(b.y, b.height, .geometryOverflow(detail: "clip bEndY"))
        let sxEnd = min(aEndX, bEndX)
        let syEnd = min(aEndY, bEndY)
        let w = max(0, sxEnd - sx)
        let h = max(0, syEnd - sy)
        if w == 0 || h == 0 { return .empty() }
        return ScissorBounds(x: sx, y: sy, width: w, height: h, isEmpty: false)
    }

    private static func clamp64(_ v: Int64, _ lo: Int64, _ hi: Int64) -> Int64 {
        if v < lo { return lo }
        if v > hi { return hi }
        return v
    }

    // MARK: - Image-draw quad geometry (plan §7.2/§7.3)

    /// One quad vertex matching the shader's `ImageVertexIn` (ndc.x, ndc.y, uv.x, uv.y) as four floats.
    struct ImageVertex {
        let ndcX: Float
        let ndcY: Float
        let u: Float
        let v: Float
    }

    /// Compute the four NDC corners (triangle-strip order) of a source-pixel rect transformed to the
    /// target surface, in exact fixed point, converting to Float only for the final NDC positions
    /// (plan §7.2/§7.3). `surfaceWidthPx`/`surfaceHeightPx` are the target pixel dimensions.
    ///
    /// Source corners in source-pixel space are fed to the transform as `CanvasScalar` raw units
    /// (`pixel * unitsPerPoint`); the transform output is canvas-raw; dividing by `unitsPerPoint` gives
    /// canvas points; canvas→NDC maps `[0, sizePx]` points to `[-1, 1]` with a single vertical flip so
    /// canvas-top maps to framebuffer-top (plan §7.1).
    static func imageQuad(
        sourceWidthPx: Int, sourceHeightPx: Int,
        transform: FixedAffineTransform2D,
        surfaceWidthPx: Int, surfaceHeightPx: Int
    ) throws -> [ImageVertex] {
        // Source corners (pixels) and their UVs. Triangle-strip order: TL, BL, TR, BR.
        let corners: [(px: Int, py: Int, u: Float, v: Float)] = [
            (0, 0, 0, 0),
            (0, sourceHeightPx, 0, 1),
            (sourceWidthPx, 0, 1, 0),
            (sourceWidthPx, sourceHeightPx, 1, 1)
        ]
        return try imageQuadCorners(corners: corners, transform: transform, surfaceWidthPx: surfaceWidthPx, surfaceHeightPx: surfaceHeightPx)
    }

    private static func imageQuadCorners(
        corners: [(px: Int, py: Int, u: Float, v: Float)],
        transform: FixedAffineTransform2D, surfaceWidthPx: Int, surfaceHeightPx: Int
    ) throws -> [ImageVertex] {
        let u = CanvasScalar.unitsPerPoint
        var verts: [ImageVertex] = []
        verts.reserveCapacity(4)
        for c in corners {
            // source pixel → CanvasScalar raw (checked).
            let sxRaw = try CheckedInt64.multiply(Int64(c.px), u, "quad.sx")
            let syRaw = try CheckedInt64.multiply(Int64(c.py), u, "quad.sy")
            // Apply the final source→canvas transform in exact fixed point.
            let mapped: (x: Int64, y: Int64)
            do {
                mapped = try transform.apply(x: sxRaw, y: syRaw)
            } catch {
                throw MetalRenderError.geometryOverflow(detail: "image transform: \(error)")
            }
            // canvas-raw → canvas points (Float, only at this boundary).
            let canvasXPoints = Float(mapped.x) / Float(u)
            let canvasYPoints = Float(mapped.y) / Float(u)
            // canvas points → NDC. x: 2*xn - 1 (xn in [0,1]); y: 1 - 2*yn (single vertical flip).
            let xn = canvasXPoints / Float(surfaceWidthPx)
            let yn = canvasYPoints / Float(surfaceHeightPx)
            let ndcX = 2.0 * xn - 1.0
            let ndcY = 1.0 - 2.0 * yn
            verts.append(ImageVertex(ndcX: ndcX, ndcY: ndcY, u: c.u, v: c.v))
        }
        return verts
    }

    // MARK: - Step-11 coverage geometry (Rev-4 §7.3/§7.5)

    /// Transform a producer mesh (`positions` flat x,y `CanvasScalar` raw; `indices` triangle list) by the
    /// command's exact fixed affine transform and emit a flat NDC triangle-list `[x0,y0, x1,y1, ...]`
    /// (two floats per emitted vertex), expanding the index buffer. `Float` only at the NDC boundary.
    static func coverageNDC(
        positions: [Int64], indices: [Int],
        transform: FixedAffineTransform2D,
        surfaceWidthPx: Int, surfaceHeightPx: Int
    ) throws -> [Float] {
        let u = CanvasScalar.unitsPerPoint
        let vertexCount = positions.count / 2
        // Pre-transform each unique vertex to NDC once.
        var ndc: [(x: Float, y: Float)] = []
        ndc.reserveCapacity(vertexCount)
        var i = 0
        while i + 1 < positions.count {
            let mapped: (x: Int64, y: Int64)
            do {
                mapped = try transform.apply(x: positions[i], y: positions[i + 1])
            } catch {
                throw MetalRenderError.geometryOverflow(detail: "coverage transform: \(error)")
            }
            let canvasX = Float(mapped.x) / Float(u)
            let canvasY = Float(mapped.y) / Float(u)
            let xn = canvasX / Float(surfaceWidthPx)
            let yn = canvasY / Float(surfaceHeightPx)
            ndc.append((x: 2.0 * xn - 1.0, y: 1.0 - 2.0 * yn))
            i += 2
        }
        var out: [Float] = []
        out.reserveCapacity(indices.count * 2)
        for idx in indices {
            guard idx >= 0, idx < vertexCount else {
                throw MetalRenderError.geometryOverflow(detail: "coverage index \(idx) out of range \(vertexCount)")
            }
            out.append(ndc[idx].x)
            out.append(ndc[idx].y)
        }
        return out
    }
}
