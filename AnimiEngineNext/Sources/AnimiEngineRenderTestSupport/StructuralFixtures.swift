import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 / Step-14 — deterministic structural fixtures for cases NOT present in the real templates
/// (transitions, overlays, masks/mattes/shapes/strokes, video exact-rational targets, post-roll
/// continuation, boundary frames). Each fixture is a hand-built immutable `RenderGraph` with honest
/// SYNTHETIC provenance (a `synthetic-*` catalog id, D4) plus the command categories it must contain.
///
/// All geometry/colour is deterministic; graphs reuse the Step-10/11/12 device-verified command shapes.
public enum StructuralFixtures {

    /// One structural fixture: synthetic provenance + the graph + the categories the graph must contain.
    public struct Fixture: Sendable {
        public let catalogID: String     // e.g. "synthetic-fade"
        public let blockID: String
        public let variantID: String
        public let projectTimeTicks: Int64
        public let graph: RenderGraph
        public let expectedCategories: [RenderCommandCategory]
    }

    private static let pt = CanvasScalar.unitsPerPoint
    private static func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }

    static func config(_ w: Int64, _ h: Int64, frameRate: FrameRate) throws -> RenderConfiguration {
        try RenderConfiguration(output: OutputContext(canvas: try CanvasSize(width: w, height: h), frameRate: frameRate),
                                intermediateProfile: .rgba16FloatLinear)
    }
    static func fr30() throws -> FrameRate { try FrameRate(numerator: 30, denominator: 1) }

    static func lin(_ w: Int64, _ h: Int64) -> RenderResourceDescriptor {
        RenderResourceDescriptor(offscreenID: RenderSurface.linearCanvas, width: w * pt, height: h * pt,
                                 profile: .intermediate(.rgba16FloatLinear), colorContract: .task003)
    }
    static func srgb(_ w: Int64, _ h: Int64) -> RenderResourceDescriptor {
        RenderResourceDescriptor(offscreenID: RenderSurface.sRGBSurface, width: w * pt, height: h * pt,
                                 profile: .finalSRGB, colorContract: .task003)
    }
    static func iso(_ id: String, _ w: Int64, _ h: Int64) -> RenderCommandPayload {
        .offscreenSurface(RenderResourceDescriptor(offscreenID: id, width: w * pt, height: h * pt,
                                                   profile: .intermediate(.rgba16FloatLinear), colorContract: .task003))
    }

    static func fullMesh(_ w: Int64, _ h: Int64, pathID: Int) throws -> SampledPathMesh {
        try SampledPathMesh(pathID: pathID,
            positions: [cs(0), cs(0), cs(w * pt), cs(0), cs(w * pt), cs(h * pt), cs(0), cs(h * pt)],
            indices: [0, 1, 2, 0, 2, 3], closed: true)
    }
    static func leftMesh(_ w: Int64, _ h: Int64, pathID: Int) throws -> SampledPathMesh {
        try SampledPathMesh(pathID: pathID,
            positions: [cs(0), cs(0), cs(w / 2 * pt), cs(0), cs(w / 2 * pt), cs(h * pt), cs(0), cs(h * pt)],
            indices: [0, 1, 2, 0, 2, 3], closed: true)
    }
    static func color(_ r: NormalizedColorComponent, _ g: NormalizedColorComponent, _ b: NormalizedColorComponent, _ a: NormalizedColorComponent) throws -> SampledSRGBAColor {
        try SampledSRGBAColor(components: [r, g, b, a])
    }
    static func fill(_ mesh: SampledPathMesh, _ c: SampledSRGBAColor) throws -> SampledShape {
        try SampledShape(fillMesh: mesh, fillColor: c, fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
    }

    /// A 4×4 premultiplied-from-opaque BGRA pixel input (deterministic) for overlay/video fixtures.
    static func pixel(_ id: String, b: UInt8, g: UInt8, r: UInt8) throws -> ResolvedPixelInput {
        var data = Data(count: 4 * 4 * 4)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<16 { p[i*4+0] = b; p[i*4+1] = g; p[i*4+2] = r; p[i*4+3] = 255 }
        }
        return try ResolvedPixelInput(id: try PixelInputID(id),
            dimensions: try PixelDimensions(width: 4, height: 4, bytesPerRow: 16, format: .bgra8, orientation: .up),
            bytes: data)
    }

    private static func graphOf(_ config: RenderConfiguration, _ payloads: [RenderCommandPayload]) throws -> RenderGraph {
        try RenderGraph(configuration: config, commands: try payloads.enumerated().map { try RenderCommand(ordinal: $0.offset, payload: $0.element) })
    }

    /// All structural fixtures in deterministic order.
    public static func all() throws -> [Fixture] {
        var out: [Fixture] = []
        out.append(try fadeFixture())
        out.append(try slideFixture())
        out.append(try overlayFixture())
        out.append(try maskFixture())
        out.append(try matteFixture())
        out.append(try shapeStrokeFixture())
        out.append(try videoExactRationalFixture())
        out.append(try postRollFixture())
        out.append(try boundaryFixture())
        return out
    }

    // MARK: - Individual fixtures

    static func fadeFixture() throws -> Fixture {
        let w: Int64 = 8, h: Int64 = 8
        let cfg = try config(w, h, frameRate: try fr30())
        let red = try fill(try fullMesh(w, h, pathID: 1), try color(.one, .zero, .zero, .one))
        let green = try fill(try fullMesh(w, h, pathID: 2), try color(.zero, .one, .zero, .one))
        let graph = try graphOf(cfg, [
            .offscreenSurface(lin(w, h)), .offscreenSurface(srgb(w, h)), iso("o", w, h), iso("i", w, h),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "o"),
            .beginScene(sceneID: "o", role: .outgoing, targetSurfaceID: "o"),
            .drawShape(shape: red, transform: .identity, opacity: .opaque, targetSurfaceID: "o"),
            .endScene(sceneID: "o", role: .outgoing, targetSurfaceID: "o"),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "i"),
            .beginScene(sceneID: "i", role: .incoming, targetSurfaceID: "i"),
            .drawShape(shape: green, transform: .identity, opacity: .opaque, targetSurfaceID: "i"),
            .endScene(sceneID: "i", role: .incoming, targetSurfaceID: "i"),
            .fadeTransition(easedProgress: try UnitInterval(rawValue: 500_000), outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)])
        return Fixture(catalogID: "synthetic-fade", blockID: "blk", variantID: "fade", projectTimeTicks: 0, graph: graph, expectedCategories: [.fadeTransition])
    }

    static func slideFixture() throws -> Fixture {
        let w: Int64 = 8, h: Int64 = 8
        let cfg = try config(w, h, frameRate: try fr30())
        let red = try fill(try fullMesh(w, h, pathID: 1), try color(.one, .zero, .zero, .one))
        let green = try fill(try fullMesh(w, h, pathID: 2), try color(.zero, .one, .zero, .one))
        let graph = try graphOf(cfg, [
            .offscreenSurface(lin(w, h)), .offscreenSurface(srgb(w, h)), iso("o", w, h), iso("i", w, h),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "o"),
            .beginScene(sceneID: "o", role: .outgoing, targetSurfaceID: "o"),
            .drawShape(shape: red, transform: .identity, opacity: .opaque, targetSurfaceID: "o"),
            .endScene(sceneID: "o", role: .outgoing, targetSurfaceID: "o"),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "i"),
            .beginScene(sceneID: "i", role: .incoming, targetSurfaceID: "i"),
            .drawShape(shape: green, transform: .identity, opacity: .opaque, targetSurfaceID: "i"),
            .endScene(sceneID: "i", role: .incoming, targetSurfaceID: "i"),
            .slideTransition(direction: .left, easedProgress: try UnitInterval(rawValue: 500_000), offsetX: -(w / 2) * pt, offsetY: 0, outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)])
        return Fixture(catalogID: "synthetic-slide", blockID: "blk", variantID: "slide-left", projectTimeTicks: 0, graph: graph, expectedCategories: [.slideTransition])
    }

    static func overlayFixture() throws -> Fixture {
        let w: Int64 = 4, h: Int64 = 4
        let cfg = try config(w, h, frameRate: try fr30())
        let red = try fill(try fullMesh(w, h, pathID: 1), try color(.one, .zero, .zero, .one))
        let ov = try pixel("ovf", b: 255, g: 0, r: 0)   // opaque blue overlay
        let one = FixedAffineTransform2D.linearUnitsPerOne
        let graph = try graphOf(cfg, [
            .declareResource(RenderResourceDescriptor(pixelInputID: "ovf", pixels: ov, colorContract: .task003)),
            .offscreenSurface(lin(w, h)), .offscreenSurface(srgb(w, h)),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .drawShape(shape: red, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .overlay(resourceID: "ovf", transform: FixedAffineTransform2D.scale(scaleX: one, scaleY: one), opacity: .opaque, compositionOrder: 0, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)])
        return Fixture(catalogID: "synthetic-overlay", blockID: "blk", variantID: "overlay", projectTimeTicks: 0, graph: graph, expectedCategories: [.overlay])
    }

    static func maskFixture() throws -> Fixture {
        let w: Int64 = 8, h: Int64 = 8
        let cfg = try config(w, h, frameRate: try fr30())
        let red = try fill(try fullMesh(w, h, pathID: 1), try color(.one, .zero, .zero, .one))
        let op = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: try leftMesh(w, h, pathID: 2), pathToTarget: .identity)
        let graph = try graphOf(cfg, [
            .offscreenSurface(lin(w, h)), .offscreenSurface(srgb(w, h)), iso("content", w, h),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "content"),
            .beginMask(operations: [op], contentSurfaceID: "content", targetSurfaceID: RenderSurface.linearCanvas),
            .drawShape(shape: red, transform: .identity, opacity: .opaque, targetSurfaceID: "content"),
            .endMask(contentSurfaceID: "content", targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)])
        return Fixture(catalogID: "synthetic-mask", blockID: "blk", variantID: "add-mask", projectTimeTicks: 0, graph: graph, expectedCategories: [.beginMask, .endMask, .drawShape])
    }

    static func matteFixture() throws -> Fixture {
        let w: Int64 = 8, h: Int64 = 8
        let cfg = try config(w, h, frameRate: try fr30())
        let white = try fill(try leftMesh(w, h, pathID: 1), try color(.one, .one, .one, .one))
        let red = try fill(try fullMesh(w, h, pathID: 2), try color(.one, .zero, .zero, .one))
        let graph = try graphOf(cfg, [
            .offscreenSurface(lin(w, h)), .offscreenSurface(srgb(w, h)), iso("src", w, h), iso("con", w, h),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "src"),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "con"),
            .drawShape(shape: white, transform: .identity, opacity: .opaque, targetSurfaceID: "src"),
            .drawShape(shape: red, transform: .identity, opacity: .opaque, targetSurfaceID: "con"),
            .matteLink(mode: .alpha, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: "src", consumerSurfaceID: "con", targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)])
        return Fixture(catalogID: "synthetic-matte", blockID: "blk", variantID: "alpha-matte", projectTimeTicks: 0, graph: graph, expectedCategories: [.matteLink])
    }

    static func shapeStrokeFixture() throws -> Fixture {
        let w: Int64 = 8, h: Int64 = 8
        let cfg = try config(w, h, frameRate: try fr30())
        // Fill shape + a stroke shape. The stroke mesh is an execution-ready `SampledTriangleMesh` built
        // directly (a small ribbon quad); the producer's `StrokeMeshBuilder` is internal to RenderGraph and
        // is exercised by its own unit tests — this fixture only needs a valid stroke triangle mesh.
        let fillShape = try fill(try fullMesh(w, h, pathID: 1), try color(.one, .zero, .zero, .one))
        let strokeMesh = try SampledTriangleMesh(
            positions: [cs(1 * pt), cs(3 * pt), cs(5 * pt), cs(3 * pt), cs(5 * pt), cs(5 * pt), cs(1 * pt), cs(5 * pt)],
            indices: [0, 1, 2, 0, 2, 3])
        let stroke = SampledStroke(sourcePathID: 11, mesh: strokeMesh, color: try color(.one, .one, .one, .one), opacity: .opaque, width: cs(2 * pt), lineCap: .round, lineJoin: .miter, miterLimit: MiterScalar(rawValue: 4_000_000))
        let strokeShape = try SampledShape(fillMesh: nil, fillColor: nil, fillOpacity: .opaque, stroke: stroke, groupOpacity: .opaque)
        let graph = try graphOf(cfg, [
            .offscreenSurface(lin(w, h)), .offscreenSurface(srgb(w, h)),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .drawShape(shape: fillShape, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .drawShape(shape: strokeShape, transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)])
        return Fixture(catalogID: "synthetic-shape-stroke", blockID: "blk", variantID: "fill-stroke", projectTimeTicks: 0, graph: graph, expectedCategories: [.drawShape])
    }

    static func videoExactRationalFixture() throws -> Fixture {
        let w: Int64 = 4, h: Int64 = 4
        // Exact-rational NTSC frame rate 30000/1001 (the synthetic-faithful video target).
        let cfg = try config(w, h, frameRate: try FrameRate(numerator: 30000, denominator: 1001))
        let vid = try pixel("vidf", b: 0, g: 0, r: 255)   // a deterministic still "video frame"
        let graph = try graphOf(cfg, [
            .declareResource(RenderResourceDescriptor(pixelInputID: "vidf", pixels: vid, colorContract: .task003)),
            .offscreenSurface(lin(w, h)), .offscreenSurface(srgb(w, h)),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .drawVideoFrame(resourceID: "vidf", transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)])
        return Fixture(catalogID: "synthetic-video-30000-1001", blockID: "blk", variantID: "video-still", projectTimeTicks: 0, graph: graph, expectedCategories: [.drawVideoFrame])
    }

    /// Post-roll continuation: an image scene rendered at a tick representing the held last frame. The
    /// graph is identical regardless of the post-roll tick (holdLast holds the same authored frame), so the
    /// fixture records the held frame; the test asserts the post-roll frame equals the last-instant frame.
    static func postRollFixture() throws -> Fixture {
        let w: Int64 = 4, h: Int64 = 4
        let cfg = try config(w, h, frameRate: try fr30())
        let img = try pixel("prf", b: 0, g: 255, r: 0)
        let graph = try graphOf(cfg, [
            .declareResource(RenderResourceDescriptor(pixelInputID: "prf", pixels: img, colorContract: .task003)),
            .offscreenSurface(lin(w, h)), .offscreenSurface(srgb(w, h)),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .drawImage(resourceID: "prf", transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)])
        return Fixture(catalogID: "synthetic-postroll", blockID: "blk", variantID: "holdLast", projectTimeTicks: 999, graph: graph, expectedCategories: [.drawImage])
    }

    /// Boundary frame: a single image scene at the boundary; the structural test pairs this with the
    /// post-roll fixture to assert holdLast equality.
    static func boundaryFixture() throws -> Fixture {
        let w: Int64 = 4, h: Int64 = 4
        let cfg = try config(w, h, frameRate: try fr30())
        let img = try pixel("bf", b: 0, g: 255, r: 0)
        let graph = try graphOf(cfg, [
            .declareResource(RenderResourceDescriptor(pixelInputID: "bf", pixels: img, colorContract: .task003)),
            .offscreenSurface(lin(w, h)), .offscreenSurface(srgb(w, h)),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .drawImage(resourceID: "bf", transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)])
        return Fixture(catalogID: "synthetic-boundary", blockID: "blk", variantID: "lastInstant", projectTimeTicks: 149, graph: graph, expectedCategories: [.drawImage])
    }
}
