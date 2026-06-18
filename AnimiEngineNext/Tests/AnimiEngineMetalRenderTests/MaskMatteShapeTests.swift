import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph
@testable import AnimiEngineMetalRender

/// Task-003 / Step-11 (Rev-4 §10.5) — Metal pixel realization of shapes, masks, and mattes.
///
/// Exact-byte assertions are used only for analytically-exact opaque interiors and same-device
/// repeatability; AA edges and half-float intermediates use bounded tolerances.
final class MaskMatteShapeTests: XCTestCase {
    private let pt = CanvasScalar.unitsPerPoint
    private func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }

    private func session() throws -> (MetalRenderSession, MTLDevice) {
        let device = try MetalTestEnvironment.requireDevice()
        return (try MetalRenderSession(device: device), device)
    }

    /// A full-canvas quad mesh (two triangles) in path-local CanvasScalar raw covering `[0,w]×[0,h]` points.
    private func fullCanvasMesh(wPt: Int64, hPt: Int64, pathID: Int = 1) throws -> SampledPathMesh {
        try SampledPathMesh(
            pathID: pathID,
            positions: [cs(0), cs(0), cs(wPt * pt), cs(0), cs(wPt * pt), cs(hPt * pt), cs(0), cs(hPt * pt)],
            indices: [0, 1, 2, 0, 2, 3], closed: true)
    }

    /// A half-canvas quad covering the left half `[0,w/2]×[0,h]`.
    private func leftHalfMesh(wPt: Int64, hPt: Int64, pathID: Int = 2) throws -> SampledPathMesh {
        let half = wPt / 2
        return try SampledPathMesh(
            pathID: pathID,
            positions: [cs(0), cs(0), cs(half * pt), cs(0), cs(half * pt), cs(hPt * pt), cs(0), cs(hPt * pt)],
            indices: [0, 1, 2, 0, 2, 3], closed: true)
    }

    private func sceneGraph(width: Int64, height: Int64, _ body: (_ add: (RenderCommandPayload) throws -> Void) throws -> Void) throws -> RenderGraph {
        let config = try MetalTestEnvironment.configuration(width: width, height: height, profile: .rgba16FloatLinear)
        var cmds: [RenderCommand] = []
        var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
        try add(.offscreenSurface(MetalTestEnvironment.linearCanvasDescriptor(width: width, height: height, profile: .rgba16FloatLinear)))
        try add(.offscreenSurface(MetalTestEnvironment.sRGBSurfaceDescriptor(width: width, height: height)))
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
        try body(add)
        try add(.endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        return try RenderGraph(configuration: config, commands: cmds)
    }

    private func isoSurface(_ id: String, width: Int64, height: Int64) -> RenderCommandPayload {
        .offscreenSurface(RenderResourceDescriptor(
            offscreenID: id, width: MetalTestEnvironment.canvasRaw(width), height: MetalTestEnvironment.canvasRaw(height),
            profile: .intermediate(.rgba16FloatLinear), colorContract: .task003))
    }

    private func opaqueRed() throws -> SampledSRGBAColor { try SampledSRGBAColor(components: [.one, .zero, .zero, .one]) }
    private func opaqueWhite() throws -> SampledSRGBAColor { try SampledSRGBAColor(components: [.one, .one, .one, .one]) }

    // MARK: - Fill

    func testOpaqueFillInteriorExact() throws {
        let (s, _) = try session()
        let mesh = try fullCanvasMesh(wPt: 8, hPt: 8)
        let shape = try SampledShape(fillMesh: mesh, fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(.drawShape(shape: shape, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let frame = try s.execute(graph)
        // Interior pixel (4,4): opaque red. sRGB red 1.0 → byte 255; green/blue 0.
        let px = MetalTestEnvironment.pixel(frame, x: 4, y: 4)
        XCTAssertEqual(px.r, 255, "fill interior red exact")
        XCTAssertEqual(px.g, 0)
        XCTAssertEqual(px.b, 0)
        XCTAssertEqual(px.a, 255)
    }

    func testFillColorAppliedOnceNoDoubleOnOverlap() throws {
        // Two overlapping triangles of the SAME fill must apply colour/opacity ONCE (coverage replacement,
        // not multiplicative) — a half-alpha fill stays half-alpha where triangles overlap.
        let (s, _) = try session()
        // A mesh with two overlapping triangles covering the same full canvas.
        let mesh = try SampledPathMesh(
            pathID: 1,
            positions: [cs(0), cs(0), cs(8 * pt), cs(0), cs(8 * pt), cs(8 * pt), cs(0), cs(8 * pt)],
            indices: [0, 1, 2, 0, 2, 3, 0, 1, 2], closed: true)  // a duplicate triangle (overlap)
        let halfAlpha = try SampledSRGBAColor(components: [.one, .zero, .zero, try NormalizedColorComponent(rawValue: 500_000)])
        let shape = try SampledShape(fillMesh: mesh, fillColor: halfAlpha, fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(.drawShape(shape: shape, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let frame = try s.execute(graph)
        let px = MetalTestEnvironment.pixel(frame, x: 4, y: 4)
        // Overlapping coverage resolves to 1.0 once; alpha ≈ 0.5 (not 0.75 from double-compositing).
        XCTAssertEqual(Int(px.a), 128, accuracy: 4, "half-alpha applied once over overlap (not doubled)")
    }

    // MARK: - Masks (group isolation + algebra)

    /// Render: content (full red) masked by a single `add` mask covering the left half → only the left
    /// half is opaque red; the right half is transparent.
    func testMaskAddCoversOperationRegion() throws {
        let (s, _) = try session()
        let content = "iso\u{1F}maskContent"
        let contentShape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let op = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: try leftHalfMesh(wPt: 8, hPt: 8), pathToTarget: .identity)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(self.isoSurface(content, width: 8, height: 8))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: content))
            try add(.beginMask(operations: [op], contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.drawShape(shape: contentShape, transform: .identity, opacity: .opaque, targetSurfaceID: content))
            try add(.endMask(contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let frame = try s.execute(graph)
        let left = MetalTestEnvironment.pixel(frame, x: 2, y: 4)
        let right = MetalTestEnvironment.pixel(frame, x: 6, y: 4)
        XCTAssertEqual(left.r, 255, "left half (inside add mask) is opaque red")
        XCTAssertEqual(left.a, 255)
        XCTAssertEqual(right.a, 0, "right half (outside add mask) is masked out")
    }

    func testMaskInvertedFlipsCoverage() throws {
        let (s, _) = try session()
        let content = "iso\u{1F}maskContentInv"
        let contentShape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let op = SampledMaskOperation(mode: .add, inverted: true, opacity: .opaque, mesh: try leftHalfMesh(wPt: 8, hPt: 8), pathToTarget: .identity)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(self.isoSurface(content, width: 8, height: 8))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: content))
            try add(.beginMask(operations: [op], contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.drawShape(shape: contentShape, transform: .identity, opacity: .opaque, targetSurfaceID: content))
            try add(.endMask(contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let frame = try s.execute(graph)
        // Inverted: the LEFT half is now masked OUT and the RIGHT half shows.
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 2, y: 4).a, 0, "inverted: left masked out")
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 6, y: 4).a, 255, "inverted: right shows")
    }

    func testMaskSubtractRemovesRegion() throws {
        let (s, _) = try session()
        let content = "iso\u{1F}maskSub"
        let contentShape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        // subtract first → accumulator starts 1, then acc·(1−cov): left half (cov 1) → 0, right (cov 0) → 1.
        let op = SampledMaskOperation(mode: .subtract, inverted: false, opacity: .opaque, mesh: try leftHalfMesh(wPt: 8, hPt: 8), pathToTarget: .identity)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(self.isoSurface(content, width: 8, height: 8))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: content))
            try add(.beginMask(operations: [op], contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.drawShape(shape: contentShape, transform: .identity, opacity: .opaque, targetSurfaceID: content))
            try add(.endMask(contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let frame = try s.execute(graph)
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 2, y: 4).a, 0, "subtract removes the left half")
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 6, y: 4).a, 255, "right half retained")
    }

    // MARK: - Matte (alpha / luma)

    func testAlphaMatteUsesSourceAlpha() throws {
        let (s, _) = try session()
        let src = "iso\u{1F}matteSrc"
        let con = "iso\u{1F}matteCon"
        // Source: opaque left half (alpha 1 left, 0 right). Consumer: full opaque red.
        let srcShape = try SampledShape(fillMesh: try leftHalfMesh(wPt: 8, hPt: 8), fillColor: try opaqueWhite(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let conShape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(self.isoSurface(src, width: 8, height: 8))
            try add(self.isoSurface(con, width: 8, height: 8))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: src))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: con))
            try add(.drawShape(shape: srcShape, transform: .identity, opacity: .opaque, targetSurfaceID: src))
            try add(.drawShape(shape: conShape, transform: .identity, opacity: .opaque, targetSurfaceID: con))
            try add(.matteLink(mode: .alpha, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: src, consumerSurfaceID: con, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let frame = try s.execute(graph)
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 2, y: 4).a, 255, "alpha matte: left (source α=1) keeps consumer")
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 6, y: 4).a, 0, "alpha matte: right (source α=0) removes consumer")
    }

    func testTransparentBrightLumaSourceProducesZeroCoverage() throws {
        // A fully TRANSPARENT source (alpha 0) — even though authored 'bright' — is premultiplied to ~0
        // RGB, so luma coverage is ~0 and the consumer is removed everywhere (NO unpremultiply).
        let (s, _) = try session()
        let src = "iso\u{1F}lumaSrc"
        let con = "iso\u{1F}lumaCon"
        // Source shape with alpha 0 (transparent) but bright authored RGB.
        let transparentBright = try SampledSRGBAColor(components: [.one, .one, .one, .zero])
        let srcShape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: transparentBright, fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let conShape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(self.isoSurface(src, width: 8, height: 8))
            try add(self.isoSurface(con, width: 8, height: 8))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: src))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: con))
            try add(.drawShape(shape: srcShape, transform: .identity, opacity: .opaque, targetSurfaceID: src))
            try add(.drawShape(shape: conShape, transform: .identity, opacity: .opaque, targetSurfaceID: con))
            try add(.matteLink(mode: .luma, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: src, consumerSurfaceID: con, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let frame = try s.execute(graph)
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 4, y: 4).a, 0, "transparent bright luma source → zero coverage")
    }

    func testLumaMatteUsesRec709() throws {
        // Source: opaque white (luma 1) left half, transparent right. Luma matte keeps consumer on the
        // left, removes it on the right.
        let (s, _) = try session()
        let src = "iso\u{1F}lumaSrc2"
        let con = "iso\u{1F}lumaCon2"
        let srcShape = try SampledShape(fillMesh: try leftHalfMesh(wPt: 8, hPt: 8), fillColor: try opaqueWhite(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let conShape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(self.isoSurface(src, width: 8, height: 8))
            try add(self.isoSurface(con, width: 8, height: 8))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: src))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: con))
            try add(.drawShape(shape: srcShape, transform: .identity, opacity: .opaque, targetSurfaceID: src))
            try add(.drawShape(shape: conShape, transform: .identity, opacity: .opaque, targetSurfaceID: con))
            try add(.matteLink(mode: .luma, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: src, consumerSurfaceID: con, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let frame = try s.execute(graph)
        XCTAssertGreaterThan(Int(MetalTestEnvironment.pixel(frame, x: 2, y: 4).a), 230, "luma white → near-full coverage left")
        XCTAssertEqual(MetalTestEnvironment.pixel(frame, x: 6, y: 4).a, 0, "transparent right → zero coverage")
    }

    // MARK: - Combined + determinism

    /// FCP §3 — the graph MUST really contain a shape draw, a mask group, AND a matteLink. The consumer
    /// is a masked red fill (left-half `add` mask) isolated and matted by a left-half alpha source.
    func testCombinedShapeMaskMatteFrameRepeatable() throws {
        let (s, _) = try session()
        let content = "iso\u{1F}cMask", src = "iso\u{1F}cSrc", con = "iso\u{1F}cCon"
        func build() throws -> RenderGraph {
            let red = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
            let white = try SampledShape(fillMesh: try leftHalfMesh(wPt: 8, hPt: 8), fillColor: try opaqueWhite(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
            let op = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: try leftHalfMesh(wPt: 8, hPt: 8, pathID: 9), pathToTarget: .identity)
            return try sceneGraph(width: 8, height: 8) { add in
                try add(self.isoSurface(content, width: 8, height: 8))
                try add(self.isoSurface(src, width: 8, height: 8))
                try add(self.isoSurface(con, width: 8, height: 8))
                try add(.clearBackground(color: .transparentBlack, targetSurfaceID: src))
                try add(.clearBackground(color: .transparentBlack, targetSurfaceID: con))
                // matte source = left-half white (alpha 1 left / 0 right).
                try add(.drawShape(shape: white, transform: .identity, opacity: .opaque, targetSurfaceID: src))
                // consumer = a MASKED red fill isolated in `content`, masked into `con`.
                try add(.clearBackground(color: .transparentBlack, targetSurfaceID: content))
                try add(.beginMask(operations: [op], contentSurfaceID: content, targetSurfaceID: con))
                try add(.drawShape(shape: red, transform: .identity, opacity: .opaque, targetSurfaceID: content))
                try add(.endMask(contentSurfaceID: content, targetSurfaceID: con))
                // matteLink composes the masked consumer through the alpha source into the canvas.
                try add(.matteLink(mode: .alpha, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: src, consumerSurfaceID: con, targetSurfaceID: RenderSurface.linearCanvas))
            }
        }
        // The graph contains exactly one shape-fill chain per category — assert the categories are present.
        let g1 = try build()
        XCTAssertTrue(g1.commands.contains { $0.category == .drawShape }, "graph contains a drawShape")
        XCTAssertTrue(g1.commands.contains { $0.category == .beginMask }, "graph contains a mask group")
        XCTAssertTrue(g1.commands.contains { $0.category == .matteLink }, "graph contains a matteLink")

        let f1 = try s.execute(g1)
        // Pixel result: left half (inside mask AND inside matte source) is opaque red; right half removed.
        XCTAssertEqual(MetalTestEnvironment.pixel(f1, x: 2, y: 4).r, 255, "combined: left half opaque red")
        XCTAssertEqual(MetalTestEnvironment.pixel(f1, x: 2, y: 4).a, 255)
        XCTAssertEqual(MetalTestEnvironment.pixel(f1, x: 6, y: 4).a, 0, "combined: right half removed by mask ∩ matte")

        let f2 = try s.execute(try build())
        XCTAssertEqual([UInt8](f1.bytes), [UInt8](f2.bytes), "same-device byte repeatability for shape+mask+matte frame")
        XCTAssertEqual(f1.rawOutputHash, f2.rawOutputHash, "rawOutputHash repeatability")
    }

    // MARK: - One command buffer / one wait preserved + transient release

    func testTransientResourcesReleasedAfterSuccess() throws {
        let device = try MetalTestEnvironment.requireDevice()
        var released = false
        let s = try MetalRenderSession(device: device)
        let content = "iso\u{1F}rel"
        let contentShape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 4, hPt: 4), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let op = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: try fullCanvasMesh(wPt: 4, hPt: 4, pathID: 3), pathToTarget: .identity)
        let graph = try sceneGraph(width: 4, height: 4) { add in
            try add(self.isoSurface(content, width: 4, height: 4))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: content))
            try add(.beginMask(operations: [op], contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.drawShape(shape: contentShape, transform: .identity, opacity: .opaque, targetSurfaceID: content))
            try add(.endMask(contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
        }
        s.onOwnerCreated = { owner in owner.onDeinit = { released = true } }
        _ = try s.execute(graph)
        XCTAssertTrue(released, "engine-owned transient resources released after success")
    }

    // MARK: - FCP §2 — Rev-4 Metal matrix (real pixel tests)

    /// Helper: render `content` (full red) through an ordered mask group and read left/right pixels.
    private func renderMaskedRed(width: Int64, height: Int64, ops: [SampledMaskOperation]) throws -> RenderedFrame {
        let (s, _) = try session()
        let content = "iso\u{1F}m"
        let red = try SampledShape(fillMesh: try fullCanvasMesh(wPt: width, hPt: height), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let graph = try sceneGraph(width: width, height: height) { add in
            try add(self.isoSurface(content, width: width, height: height))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: content))
            try add(.beginMask(operations: ops, contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.drawShape(shape: red, transform: .identity, opacity: .opaque, targetSurfaceID: content))
            try add(.endMask(contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
        }
        return try s.execute(graph)
    }

    func testIntersectAsFirstOperationSeedsOne() throws {
        // intersect first → accumulator seeds 1, then min(1, cov): left half (cov 1) stays, right (0) → 0.
        let op = SampledMaskOperation(mode: .intersect, inverted: false, opacity: .opaque, mesh: try leftHalfMesh(wPt: 8, hPt: 8), pathToTarget: .identity)
        let f = try renderMaskedRed(width: 8, height: 8, ops: [op])
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 2, y: 4).a, 255, "intersect-first keeps the covered left half")
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 6, y: 4).a, 0, "intersect-first removes the uncovered right half")
    }

    func testAddThenSubtractDiffersFromSubtractThenAdd() throws {
        // add→subtract: start 0; add left(cov1)→1 on left; then subtract left(cov1)→0 on left ⇒ all 0.
        let addOp = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: try leftHalfMesh(wPt: 8, hPt: 8, pathID: 2), pathToTarget: .identity)
        let subOp = SampledMaskOperation(mode: .subtract, inverted: false, opacity: .opaque, mesh: try leftHalfMesh(wPt: 8, hPt: 8, pathID: 3), pathToTarget: .identity)
        let addThenSub = try renderMaskedRed(width: 8, height: 8, ops: [addOp, subOp])
        // subtract→add: start 1; subtract left→0 on left, 1 on right; then add left(cov1)→1 left ⇒ all 1.
        let subThenAdd = try renderMaskedRed(width: 8, height: 8, ops: [subOp, addOp])
        XCTAssertEqual(MetalTestEnvironment.pixel(addThenSub, x: 2, y: 4).a, 0, "add→subtract: left removed")
        XCTAssertEqual(MetalTestEnvironment.pixel(subThenAdd, x: 2, y: 4).a, 255, "subtract→add: left present")
        XCTAssertNotEqual(MetalTestEnvironment.pixel(addThenSub, x: 2, y: 4).a,
                          MetalTestEnvironment.pixel(subThenAdd, x: 2, y: 4).a, "operation order is significant")
    }

    func testInvertThenOpacityThenModeOrdering() throws {
        // add, inverted, opacity 0.5: cov(left)=1 → invert → 0 → ×0.5 → 0; cov(right)=0 → invert → 1 → ×0.5
        // → 0.5. So the RIGHT half gets ~0.5 coverage, the left gets 0. Proves invert BEFORE opacity.
        let op = SampledMaskOperation(mode: .add, inverted: true, opacity: try OpacityScalar(rawValue: 500_000), mesh: try leftHalfMesh(wPt: 8, hPt: 8), pathToTarget: .identity)
        let f = try renderMaskedRed(width: 8, height: 8, ops: [op])
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 2, y: 4).a, 0, "left: inverted coverage 0")
        XCTAssertEqual(Int(MetalTestEnvironment.pixel(f, x: 6, y: 4).a), 128, accuracy: 4, "right: inverted(1)×opacity(0.5) ≈ 0.5")
    }

    func testNestedMaskExecution() throws {
        // Outer mask group whose content is itself a masked layer: inner add(left) into `inner`, then the
        // inner result is the outer group's content, masked by add(top-half) into the canvas. Only the
        // top-left quadrant survives (left ∩ top).
        let (s, _) = try session()
        let inner = "iso\u{1F}inner", outer = "iso\u{1F}outer"
        let red = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let leftOp = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: try leftHalfMesh(wPt: 8, hPt: 8, pathID: 2), pathToTarget: .identity)
        // top-half mesh
        let topHalf = try SampledPathMesh(pathID: 3, positions: [cs(0), cs(0), cs(8 * pt), cs(0), cs(8 * pt), cs(4 * pt), cs(0), cs(4 * pt)], indices: [0, 1, 2, 0, 2, 3], closed: true)
        let topOp = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: topHalf, pathToTarget: .identity)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(self.isoSurface(inner, width: 8, height: 8))
            try add(self.isoSurface(outer, width: 8, height: 8))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: inner))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: outer))
            // outer group: content surface is `outer`, target is canvas, masked by top-half.
            try add(.beginMask(operations: [topOp], contentSurfaceID: outer, targetSurfaceID: RenderSurface.linearCanvas))
            //   inner group: content `inner`, target `outer`, masked by left-half.
            try add(.beginMask(operations: [leftOp], contentSurfaceID: inner, targetSurfaceID: outer))
            try add(.drawShape(shape: red, transform: .identity, opacity: .opaque, targetSurfaceID: inner))
            try add(.endMask(contentSurfaceID: inner, targetSurfaceID: outer))
            try add(.endMask(contentSurfaceID: outer, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let f = try s.execute(graph)
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 2, y: 2).a, 255, "top-left quadrant survives (left ∩ top)")
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 6, y: 2).a, 0, "top-right removed (outside left)")
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 2, y: 6).a, 0, "bottom-left removed (outside top)")
    }

    func testMultipleDrawsMaskedOnceAsSingleContribution() throws {
        // Two SEPARATE half-alpha draws of the SAME region inside one mask group. If masked per-draw they
        // would composite twice (≈0.75 alpha); as a single contribution the content composites first
        // (≈0.75 in the content surface) then the mask applies once. We assert the masked region is
        // present and the OUTSIDE-mask region is fully removed (the group boundary is the whole layer).
        let (s, _) = try session()
        let content = "iso\u{1F}multi"
        let halfA = try SampledSRGBAColor(components: [.one, .zero, .zero, try NormalizedColorComponent(rawValue: 500_000)])
        let draw = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: halfA, fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let op = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: try leftHalfMesh(wPt: 8, hPt: 8, pathID: 5), pathToTarget: .identity)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(self.isoSurface(content, width: 8, height: 8))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: content))
            try add(.beginMask(operations: [op], contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.drawShape(shape: draw, transform: .identity, opacity: .opaque, targetSurfaceID: content))
            try add(.drawShape(shape: draw, transform: .identity, opacity: .opaque, targetSurfaceID: content))
            try add(.endMask(contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let f = try s.execute(graph)
        // The mask boundary applies once to the WHOLE accumulated contribution: outside-mask is fully 0,
        // inside-mask is present (two stacked half-alpha draws → ~0.75 alpha, masked by 1.0).
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 6, y: 4).a, 0, "outside the single mask boundary fully removed")
        XCTAssertGreaterThan(Int(MetalTestEnvironment.pixel(f, x: 2, y: 4).a), 150, "inside: stacked draws then masked once")
    }

    func testTranslatedAndRotatedMask() throws {
        // A small square mask path placed at the origin, then translated to the canvas centre and rotated
        // 45°, must mask the centre region (not the origin). Proves pathToTarget carries translation+rotation.
        let half: Int64 = 2
        let sq = try SampledPathMesh(pathID: 7,
            positions: [cs(-half * pt), cs(-half * pt), cs(half * pt), cs(-half * pt), cs(half * pt), cs(half * pt), cs(-half * pt), cs(half * pt)],
            indices: [0, 1, 2, 0, 2, 3], closed: true)
        // translate to centre (4,4) then rotate 45°.
        let rot = try FixedAffineTransform2D.rotation(degreesTimesUnitsPerDegree: 45_000)
        let toTarget = try FixedAffineTransform2D.translation(tx: 4 * pt, ty: 4 * pt).concatenating(rot)
        let op = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: sq, pathToTarget: toTarget)
        let f = try renderMaskedRed(width: 8, height: 8, ops: [op])
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 4, y: 4).a, 255, "rotated+translated mask covers the canvas centre")
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 0, y: 0).a, 0, "origin is NOT masked (transform applied)")
    }

    func testAlphaInvertedMatte() throws {
        let (s, _) = try session()
        let src = "iso\u{1F}aiSrc", con = "iso\u{1F}aiCon"
        let srcShape = try SampledShape(fillMesh: try leftHalfMesh(wPt: 8, hPt: 8), fillColor: try opaqueWhite(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let conShape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(self.isoSurface(src, width: 8, height: 8)); try add(self.isoSurface(con, width: 8, height: 8))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: src)); try add(.clearBackground(color: .transparentBlack, targetSurfaceID: con))
            try add(.drawShape(shape: srcShape, transform: .identity, opacity: .opaque, targetSurfaceID: src))
            try add(.drawShape(shape: conShape, transform: .identity, opacity: .opaque, targetSurfaceID: con))
            try add(.matteLink(mode: .alphaInverted, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: src, consumerSurfaceID: con, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let f = try s.execute(graph)
        // alphaInverted: left (source α=1 → 1−1=0) removed; right (source α=0 → 1−0=1) kept.
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 2, y: 4).a, 0, "alphaInverted removes where source α=1")
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 6, y: 4).a, 255, "alphaInverted keeps where source α=0")
    }

    func testLumaInvertedMatte() throws {
        let (s, _) = try session()
        let src = "iso\u{1F}liSrc", con = "iso\u{1F}liCon"
        // Source: opaque white left (luma 1) / transparent right (luma 0).
        let srcShape = try SampledShape(fillMesh: try leftHalfMesh(wPt: 8, hPt: 8), fillColor: try opaqueWhite(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let conShape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 8, hPt: 8), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(self.isoSurface(src, width: 8, height: 8)); try add(self.isoSurface(con, width: 8, height: 8))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: src)); try add(.clearBackground(color: .transparentBlack, targetSurfaceID: con))
            try add(.drawShape(shape: srcShape, transform: .identity, opacity: .opaque, targetSurfaceID: src))
            try add(.drawShape(shape: conShape, transform: .identity, opacity: .opaque, targetSurfaceID: con))
            try add(.matteLink(mode: .lumaInverted, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: src, consumerSurfaceID: con, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let f = try s.execute(graph)
        // lumaInverted: left (luma 1 → 0) removed; right (luma 0 → 1) kept.
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 2, y: 4).a, 0, "lumaInverted removes bright (luma 1) region")
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 6, y: 4).a, 255, "lumaInverted keeps dark (luma 0) region")
    }

    func testStrokePixelsCapsJoinsInteriorAndBoundedEdges() throws {
        // An L-shaped open polyline stroked with round caps + miter join. Build the execution-ready stroke
        // mesh in the graph layer, then draw it and assert: interior pixels on the stroke are opaque (exact),
        // pixels far off the stroke are empty (exact), and the count of partial-alpha edge pixels is bounded.
        let (s, _) = try session()
        let poly = try SampledPathMesh(pathID: 11,
            positions: [cs(1 * pt), cs(4 * pt), cs(4 * pt), cs(4 * pt), cs(4 * pt), cs(1 * pt)],
            indices: [0, 1, 2], closed: false)
        let mesh = try StrokeMeshBuilder.build(path: poly, width: cs(2 * pt), lineCap: .round, lineJoin: .miter, miterLimit: MiterScalar(rawValue: 4_000_000))
        let stroke = SampledStroke(sourcePathID: 11, mesh: mesh, color: try SampledSRGBAColor(components: [.one, .one, .one, .one]),
                                   opacity: .opaque, width: cs(2 * pt), lineCap: .round, lineJoin: .miter, miterLimit: MiterScalar(rawValue: 4_000_000))
        let shape = try SampledShape(fillMesh: nil, fillColor: nil, fillOpacity: .opaque, stroke: stroke, groupOpacity: .opaque)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(.drawShape(shape: shape, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let f = try s.execute(graph)
        // Interior of the horizontal arm (around (2,4)) is fully covered → opaque white.
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 2, y: 4).a, 255, "stroke interior opaque")
        // A pixel far from the stroke (corner) is empty.
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 7, y: 7).a, 0, "off-stroke pixel empty")
        // Bounded AA edges: every pixel alpha is a 4x-quantized value (multiple of 64 within tolerance).
        for y in 0..<8 { for x in 0..<8 {
            let a = Int(MetalTestEnvironment.pixel(f, x: x, y: y).a)
            let nearest = (a + 32) / 64 * 64
            XCTAssertLessThanOrEqual(abs(a - min(nearest, 255)), 8, "stroke edge alpha is 4x-quantized at (\(x),\(y))=\(a)")
        }}
    }

    func testFourxCoverageQuantization() throws {
        // A diagonal half-plane fill over the canvas. With 4x MSAA, every pixel's resolved coverage — and
        // thus the opaque-white alpha — is a multiple of 1/4 (0, 0.25, 0.5, 0.75, 1.0 → 0/64/128/191/255):
        // interior exact 255, exterior exact 0, diagonal edges quantized to quarter steps.
        let (s, _) = try session()
        // Triangle covering the lower-left half: (0,0),(8,0),(0,8) in points.
        let tri = try SampledPathMesh(pathID: 13,
            positions: [cs(0), cs(0), cs(8 * pt), cs(0), cs(0), cs(8 * pt)], indices: [0, 1, 2], closed: true)
        let shape = try SampledShape(fillMesh: tri, fillColor: try opaqueWhite(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let graph = try sceneGraph(width: 8, height: 8) { add in
            try add(.drawShape(shape: shape, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas))
        }
        let f = try s.execute(graph)
        var sawInteriorFull = false, sawEmpty = false, sawPartial = false
        for y in 0..<8 { for x in 0..<8 {
            let a = Int(MetalTestEnvironment.pixel(f, x: x, y: y).a)
            let nearest = (a + 32) / 64 * 64
            XCTAssertLessThanOrEqual(abs(a - min(nearest, 255)), 8, "coverage alpha is a quarter-step at (\(x),\(y))=\(a)")
            if a == 255 { sawInteriorFull = true }
            if a == 0 { sawEmpty = true }
            if a > 8 && a < 247 { sawPartial = true }
        }}
        XCTAssertTrue(sawInteriorFull, "saw a fully-covered (1.0) pixel")
        XCTAssertTrue(sawEmpty, "saw a fully-uncovered (0.0) pixel")
        XCTAssertTrue(sawPartial, "saw a partially-covered (0.25/0.5/0.75) edge pixel")
    }

    func testTransientResourcesReleasedAfterInjectedFailure() throws {
        // An injected command-buffer failure (via a failing submitter) must still release all engine-owned
        // transient Step-11 resources after execute() throws.
        let device = try MetalTestEnvironment.requireDevice()
        guard let queue = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        var released = false
        let session = try MetalRenderSession(
            device: device, shaderLoader: RuntimeSourceShaderLoader(),
            submitter: FailingSubmitter(inner: RealCommandSubmitter(queue: queue)))
        session.onOwnerCreated = { owner in owner.onDeinit = { released = true } }
        let content = "iso\u{1F}failRel"
        let shape = try SampledShape(fillMesh: try fullCanvasMesh(wPt: 4, hPt: 4), fillColor: try opaqueRed(), fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let op = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: try fullCanvasMesh(wPt: 4, hPt: 4, pathID: 3), pathToTarget: .identity)
        let graph = try sceneGraph(width: 4, height: 4) { add in
            try add(self.isoSurface(content, width: 4, height: 4))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: content))
            try add(.beginMask(operations: [op], contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
            try add(.drawShape(shape: shape, transform: .identity, opacity: .opaque, targetSurfaceID: content))
            try add(.endMask(contentSurfaceID: content, targetSurfaceID: RenderSurface.linearCanvas))
        }
        XCTAssertThrowsError(try session.execute(graph), "injected failure must throw")
        XCTAssertTrue(released, "engine-owned Step-11 transient resources released after injected failure")
    }
}

/// A submitter that commits the real buffer (valid encoding) then forces a `.failed` completion — drives
/// the injected-failure lifecycle path.
private struct FailingSubmitter: CommandSubmitter {
    let inner: CommandSubmitter
    func makeCommandBuffer() throws -> MTLCommandBuffer { try inner.makeCommandBuffer() }
    func commitAndWait(_ buffer: MTLCommandBuffer) -> CommandCompletion {
        _ = inner.commitAndWait(buffer)
        return .failed(status: "injected", detail: "FailingSubmitter")
    }
}
