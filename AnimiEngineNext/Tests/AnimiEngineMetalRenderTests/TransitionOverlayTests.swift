import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph
@testable import AnimiEngineMetalRender

/// Task-003 / Step-12 — Metal pixel realization of cut, fade, slide, overlay.
///
/// Exact-byte assertions are used only for analytically-exact opaque content and same-device
/// repeatability; partial-alpha / midpoint rows use bounded tolerance vs a linear CPU oracle.
final class TransitionOverlayTests: XCTestCase {
    private let pt = CanvasScalar.unitsPerPoint
    private func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }

    private func session() throws -> (MetalRenderSession, MTLDevice) {
        let device = try MetalTestEnvironment.requireDevice()
        return (try MetalRenderSession(device: device), device)
    }

    private func fullMesh(_ wPt: Int64, _ hPt: Int64, pathID: Int = 1) throws -> SampledPathMesh {
        try SampledPathMesh(
            pathID: pathID,
            positions: [cs(0), cs(0), cs(wPt * pt), cs(0), cs(wPt * pt), cs(hPt * pt), cs(0), cs(hPt * pt)],
            indices: [0, 1, 2, 0, 2, 3], closed: true)
    }
    private func leftHalfMesh(_ wPt: Int64, _ hPt: Int64, pathID: Int = 2) throws -> SampledPathMesh {
        try SampledPathMesh(
            pathID: pathID,
            positions: [cs(0), cs(0), cs(wPt / 2 * pt), cs(0), cs(wPt / 2 * pt), cs(hPt * pt), cs(0), cs(hPt * pt)],
            indices: [0, 1, 2, 0, 2, 3], closed: true)
    }
    private func color(_ r: NormalizedColorComponent, _ g: NormalizedColorComponent, _ b: NormalizedColorComponent, _ a: NormalizedColorComponent) throws -> SampledSRGBAColor {
        try SampledSRGBAColor(components: [r, g, b, a])
    }
    private func red() throws -> SampledSRGBAColor { try color(.one, .zero, .zero, .one) }
    private func green() throws -> SampledSRGBAColor { try color(.zero, .one, .zero, .one) }
    private func fill(_ mesh: SampledPathMesh, _ c: SampledSRGBAColor) throws -> SampledShape {
        try SampledShape(fillMesh: mesh, fillColor: c, fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
    }

    private func config(_ w: Int64, _ h: Int64) throws -> RenderConfiguration {
        try MetalTestEnvironment.configuration(width: w, height: h, profile: .rgba16FloatLinear)
    }
    private func isoSurface(_ id: String, _ w: Int64, _ h: Int64) -> RenderCommandPayload {
        .offscreenSurface(RenderResourceDescriptor(
            offscreenID: id, width: MetalTestEnvironment.canvasRaw(w), height: MetalTestEnvironment.canvasRaw(h),
            profile: .intermediate(.rgba16FloatLinear), colorContract: .task003))
    }
    private func sceneBoiler(_ w: Int64, _ h: Int64) -> [RenderCommandPayload] {
        [.offscreenSurface(MetalTestEnvironment.linearCanvasDescriptor(width: w, height: h, profile: .rgba16FloatLinear)),
         .offscreenSurface(MetalTestEnvironment.sRGBSurfaceDescriptor(width: w, height: h)),
         .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas)]
    }
    private func finalChain() -> [RenderCommandPayload] {
        [.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
         .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)]
    }
    private func graph(_ w: Int64, _ h: Int64, _ payloads: [RenderCommandPayload]) throws -> RenderGraph {
        var all = sceneBoiler(w, h)
        all.append(contentsOf: payloads)
        all.append(contentsOf: finalChain())
        var cmds: [RenderCommand] = []
        for (i, p) in all.enumerated() { cmds.append(try RenderCommand(ordinal: i, payload: p)) }
        return try RenderGraph(configuration: try config(w, h), commands: cmds)
    }

    /// Build outgoing (full `outColor`) + incoming (full `inColor`) scene surfaces, returning the prefix
    /// command list (surfaces + the two scene renders). The transition/overlay command is appended by the
    /// caller, then the final chain.
    private func twoScenes(_ w: Int64, _ h: Int64, out outColor: SampledSRGBAColor, inc inColor: SampledSRGBAColor,
                           outgoing: String, incoming: String) throws -> [RenderCommandPayload] {
        [isoSurface(outgoing, w, h), isoSurface(incoming, w, h),
         .clearBackground(color: .transparentBlack, targetSurfaceID: outgoing),
         .beginScene(sceneID: "o", role: .outgoing, targetSurfaceID: outgoing),
         .drawShape(shape: try fill(try fullMesh(w, h, pathID: 1), outColor), transform: .identity, opacity: .opaque, targetSurfaceID: outgoing),
         .endScene(sceneID: "o", role: .outgoing, targetSurfaceID: outgoing),
         .clearBackground(color: .transparentBlack, targetSurfaceID: incoming),
         .beginScene(sceneID: "i", role: .incoming, targetSurfaceID: incoming),
         .drawShape(shape: try fill(try fullMesh(w, h, pathID: 3), inColor), transform: .identity, opacity: .opaque, targetSurfaceID: incoming),
         .endScene(sceneID: "i", role: .incoming, targetSurfaceID: incoming)]
    }

    // MARK: - Cut (regression): single scene → canvas → final

    func testCutSingleSceneRendersAndFinalConversionLast() throws {
        let (s, _) = try session()
        let g = try graph(8, 8, [
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .drawShape(shape: try fill(try fullMesh(8, 8), try red()), transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
        ])
        let f = try s.execute(g)
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 4, y: 4).r, 255, "cut: red interior")
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 4, y: 4).a, 255)
    }

    // MARK: - Fade

    func testFadeProgressZeroIsOutgoing() throws {
        let (s, _) = try session()
        var p = try twoScenes(8, 8, out: try red(), inc: try green(), outgoing: "o", incoming: "i")
        p.append(.fadeTransition(easedProgress: .zero, outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: RenderSurface.linearCanvas))
        let f = try s.execute(try graph(8, 8, p))
        let px = MetalTestEnvironment.pixel(f, x: 4, y: 4)
        XCTAssertEqual(px.r, 255, "fade p=0 → outgoing (red)")
        XCTAssertEqual(px.g, 0)
    }

    /// fade p=1 may exist only as a direct executor/shader boundary test using `UnitInterval.one`
    /// (clarification): the graph compiler/evaluator never produce p=1 (half-open progress).
    func testFadeProgressOneIsIncoming_ExecutorBoundary() throws {
        let (s, _) = try session()
        var p = try twoScenes(8, 8, out: try red(), inc: try green(), outgoing: "o", incoming: "i")
        p.append(.fadeTransition(easedProgress: .one, outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: RenderSurface.linearCanvas))
        let f = try s.execute(try graph(8, 8, p))
        let px = MetalTestEnvironment.pixel(f, x: 4, y: 4)
        XCTAssertEqual(px.g, 255, "fade p=1 (UnitInterval.one boundary) → incoming (green)")
        XCTAssertEqual(px.r, 0)
    }

    func testFadeMidpointCrossDissolve() throws {
        let (s, _) = try session()
        var p = try twoScenes(8, 8, out: try red(), inc: try green(), outgoing: "o", incoming: "i")
        p.append(.fadeTransition(easedProgress: try UnitInterval(rawValue: 500_000), outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: RenderSurface.linearCanvas))
        let f = try s.execute(try graph(8, 8, p))
        let px = MetalTestEnvironment.pixel(f, x: 4, y: 4)
        // Linear-light 50/50 of opaque red and opaque green: each channel's linear value halved, then
        // re-encoded to sRGB. sRGB(0.5·linear(1.0)) = sRGB(0.5) ≈ 188. Bounded.
        let mid = Int(MetalTestEnvironment.linearToSRGB(0.5) * 255.0 + 0.5)
        XCTAssertEqual(Int(px.r), mid, accuracy: 3, "fade midpoint red channel ≈ sRGB(0.5)")
        XCTAssertEqual(Int(px.g), mid, accuracy: 3, "fade midpoint green channel ≈ sRGB(0.5)")
        XCTAssertEqual(px.a, 255, "both opaque → opaque result")
    }

    func testFadePartialAlphaPremultiplied() throws {
        // incoming is half-alpha green over a fully-transparent outgoing; at p=1 the result is the
        // premultiplied half-alpha green (NOT doubled). Two-sided: catches a non-premultiplied blend.
        let (s, _) = try session()
        let halfGreen = try color(.zero, .one, .zero, try NormalizedColorComponent(rawValue: 500_000))
        var p: [RenderCommandPayload] = [
            isoSurface("o", 8, 8), isoSurface("i", 8, 8),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "o"),    // outgoing fully transparent
            .beginScene(sceneID: "o", role: .outgoing, targetSurfaceID: "o"),
            .drawShape(shape: try SampledShape(fillMesh: try fullMesh(8, 8, pathID: 5), fillColor: try color(.zero, .zero, .zero, .zero), fillOpacity: .transparent, stroke: nil, groupOpacity: .opaque), transform: .identity, opacity: .transparent, targetSurfaceID: "o"),
            .endScene(sceneID: "o", role: .outgoing, targetSurfaceID: "o"),
            .clearBackground(color: .transparentBlack, targetSurfaceID: "i"),
            .beginScene(sceneID: "i", role: .incoming, targetSurfaceID: "i"),
            .drawShape(shape: try fill(try fullMesh(8, 8, pathID: 6), halfGreen), transform: .identity, opacity: .opaque, targetSurfaceID: "i"),
            .endScene(sceneID: "i", role: .incoming, targetSurfaceID: "i"),
        ]
        p.append(.fadeTransition(easedProgress: .one, outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: RenderSurface.linearCanvas))
        let f = try s.execute(try graph(8, 8, p))
        let px = MetalTestEnvironment.pixel(f, x: 4, y: 4)
        XCTAssertEqual(Int(px.a), 128, accuracy: 4, "half-alpha incoming stays half-alpha (premultiplied)")
    }

    // MARK: - Slide

    private func slideFrame(direction: RenderSlideDirection, offsetX: Int64, offsetY: Int64) throws -> RenderedFrame {
        let (s, _) = try session()
        // outgoing = full red, incoming = full green; the incoming slides over the stationary outgoing.
        var p = try twoScenes(8, 8, out: try red(), inc: try green(), outgoing: "o", incoming: "i")
        p.append(.slideTransition(direction: direction, easedProgress: try UnitInterval(rawValue: 500_000),
                                  offsetX: offsetX, offsetY: offsetY, outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: RenderSurface.linearCanvas))
        return try s.execute(try graph(8, 8, p))
    }

    func testSlideLeftHalfwayShowsIncomingOverOutgoing() throws {
        // direction .left at p=0.5: offset = (1−0.5)·width = 4pt to the left → incoming shifted by (−4pt).
        // The incoming green covers the LEFT half-ish; the right portion reveals the stationary red.
        let f = try slideFrame(direction: .left, offsetX: -4 * pt, offsetY: 0)
        // Left region: incoming green present.
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 1, y: 4).g, 255, "slide-left: incoming green on the left")
        // Right region: stationary outgoing red revealed (incoming shifted off it).
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 7, y: 4).r, 255, "slide-left: stationary outgoing red on the right")
    }

    func testSlideProgressOneFullyInPlace_ExecutorBoundary() throws {
        // offset 0 (p=1 boundary): incoming exactly in place over the outgoing → fully green.
        let f = try slideFrame(direction: .left, offsetX: 0, offsetY: 0)
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 4, y: 4).g, 255, "slide offset 0 → incoming fully in place")
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 4, y: 4).r, 0)
    }

    func testSlideOffEdgeIsTransparentRevealingOutgoing() throws {
        // A large rightward offset pushes the incoming mostly off-canvas to the right; the left edge has no
        // incoming sample (clampToZero → transparent), revealing the stationary outgoing red.
        let f = try slideFrame(direction: .right, offsetX: 7 * pt, offsetY: 0)
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 0, y: 4).r, 255, "slide off-edge: outgoing red revealed where incoming is absent")
    }

    func testSlideAllFourDirectionsExecute() throws {
        XCTAssertNoThrow(try slideFrame(direction: .left, offsetX: -2 * pt, offsetY: 0))
        XCTAssertNoThrow(try slideFrame(direction: .right, offsetX: 2 * pt, offsetY: 0))
        XCTAssertNoThrow(try slideFrame(direction: .up, offsetX: 0, offsetY: -2 * pt))
        XCTAssertNoThrow(try slideFrame(direction: .down, offsetX: 0, offsetY: 2 * pt))
    }

    // MARK: - Overlay

    private func overlayPixel(id: String, w: Int, h: Int, b: UInt8, g: UInt8, r: UInt8, a: UInt8) throws -> ResolvedPixelInput {
        try MetalTestEnvironment.makePixelInput(id: id, width: w, height: h, straightBGRA: Array(repeating: (b: b, g: g, r: r, a: a), count: w * h))
    }

    func testOverlayCompositesAboveBody() throws {
        let (s, _) = try session()
        let ov = try overlayPixel(id: "ov", w: 8, h: 8, b: 0, g: 255, r: 0, a: 255)   // opaque green overlay
        // Body: a single scene of red into linearCanvas; then a full-canvas green overlay above it.
        let sizing = try OverlayPlacementHelper.fullCanvasTransform(w: 8, h: 8, pixelW: 8, pixelH: 8)
        let g = try graph(8, 8, [
            .declareResource(RenderResourceDescriptor(pixelInputID: "ov", pixels: ov, colorContract: .task003)),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .drawShape(shape: try fill(try fullMesh(8, 8), try red()), transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .overlay(resourceID: "ov", transform: sizing, opacity: .opaque, compositionOrder: 0, targetSurfaceID: RenderSurface.linearCanvas),
        ])
        let f = try s.execute(g)
        // The opaque green overlay covers the red body.
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 4, y: 4).g, 255, "overlay green composited above the red body")
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 4, y: 4).r, 0)
    }

    func testTwoOverlaysCompositionOrderRespected() throws {
        let (s, _) = try session()
        // Overlay A (order 0): opaque blue left half. Overlay B (order 1): opaque green right half. Both
        // composite above the red body in order; the later one wins where they would overlap (they don't).
        let a = try overlayPixel(id: "ovA", w: 4, h: 8, b: 255, g: 0, r: 0, a: 255)
        let b = try overlayPixel(id: "ovB", w: 4, h: 8, b: 0, g: 255, r: 0, a: 255)
        let leftT = try OverlayPlacementHelper.frameTransform(x: 0, y: 0, w: 4, h: 8, pixelW: 4, pixelH: 8)
        let rightT = try OverlayPlacementHelper.frameTransform(x: 4, y: 0, w: 4, h: 8, pixelW: 4, pixelH: 8)
        let g = try graph(8, 8, [
            .declareResource(RenderResourceDescriptor(pixelInputID: "ovA", pixels: a, colorContract: .task003)),
            .declareResource(RenderResourceDescriptor(pixelInputID: "ovB", pixels: b, colorContract: .task003)),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .drawShape(shape: try fill(try fullMesh(8, 8), try red()), transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .overlay(resourceID: "ovA", transform: leftT, opacity: .opaque, compositionOrder: 0, targetSurfaceID: RenderSurface.linearCanvas),
            .overlay(resourceID: "ovB", transform: rightT, opacity: .opaque, compositionOrder: 1, targetSurfaceID: RenderSurface.linearCanvas),
        ])
        let f = try s.execute(g)
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 1, y: 4).b, 255, "left overlay blue")
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 6, y: 4).g, 255, "right overlay green")
    }

    func testOverlayAboveTransitionResult() throws {
        let (s, _) = try session()
        let ov = try overlayPixel(id: "ovt", w: 8, h: 8, b: 255, g: 0, r: 0, a: 255)   // opaque blue overlay
        var p = try twoScenes(8, 8, out: try red(), inc: try green(), outgoing: "o", incoming: "i")
        p.insert(.declareResource(RenderResourceDescriptor(pixelInputID: "ovt", pixels: ov, colorContract: .task003)), at: 0)
        p.append(.fadeTransition(easedProgress: try UnitInterval(rawValue: 500_000), outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: RenderSurface.linearCanvas))
        p.append(.overlay(resourceID: "ovt", transform: try OverlayPlacementHelper.fullCanvasTransform(w: 8, h: 8, pixelW: 8, pixelH: 8), opacity: .opaque, compositionOrder: 0, targetSurfaceID: RenderSurface.linearCanvas))
        let f = try s.execute(try graph(8, 8, p))
        // The opaque blue overlay sits above the fade result.
        XCTAssertEqual(MetalTestEnvironment.pixel(f, x: 4, y: 4).b, 255, "overlay above the transition result")
    }

    // MARK: - Determinism + lifecycle

    func testTransitionFrameRepeatable() throws {
        let (s, _) = try session()
        func build() throws -> RenderGraph {
            var p = try twoScenes(8, 8, out: try red(), inc: try green(), outgoing: "o", incoming: "i")
            p.append(.slideTransition(direction: .left, easedProgress: try UnitInterval(rawValue: 400_000), offsetX: -3 * pt, offsetY: 0, outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: RenderSurface.linearCanvas))
            return try graph(8, 8, p)
        }
        let f1 = try s.execute(try build())
        let f2 = try s.execute(try build())
        XCTAssertEqual([UInt8](f1.bytes), [UInt8](f2.bytes), "same-device byte repeatability (slide)")
        XCTAssertEqual(f1.rawOutputHash, f2.rawOutputHash, "rawOutputHash repeatability")
    }

    func testTransitionTransientReleasedAfterInjectedFailure() throws {
        let device = try MetalTestEnvironment.requireDevice()
        guard let queue = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        var released = false
        let s = try MetalRenderSession(device: device, shaderLoader: RuntimeSourceShaderLoader(),
                                       submitter: FadeFailingSubmitter(inner: RealCommandSubmitter(queue: queue)))
        s.onOwnerCreated = { owner in owner.onDeinit = { released = true } }
        var p = try twoScenes(8, 8, out: try red(), inc: try green(), outgoing: "o", incoming: "i")
        p.append(.fadeTransition(easedProgress: try UnitInterval(rawValue: 500_000), outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: RenderSurface.linearCanvas))
        XCTAssertThrowsError(try s.execute(try graph(8, 8, p)), "injected failure throws")
        XCTAssertTrue(released, "engine-owned resources released after injected failure during a transition")
    }
}

/// Minimal overlay placement transform helper for tests (source-pixel→frame sizing + frame origin),
/// mirroring OverlayGraphBuilder.placementTransform for opaque, axis-aligned overlays.
private enum OverlayPlacementHelper {
    private static let pt = CanvasScalar.unitsPerPoint
    static func frameTransform(x: Int64, y: Int64, w: Int64, h: Int64, pixelW: Int64, pixelH: Int64) throws -> FixedAffineTransform2D {
        let one = FixedAffineTransform2D.linearUnitsPerOne
        let srcW = try CheckedInt64.multiply(pixelW, pt, "ovh.srcW")
        let srcH = try CheckedInt64.multiply(pixelH, pt, "ovh.srcH")
        let sx = try FixedPointMath.multiplyDivideRounding(w * pt, one, srcW, "ovh.sx")
        let sy = try FixedPointMath.multiplyDivideRounding(h * pt, one, srcH, "ovh.sy")
        let sizing = FixedAffineTransform2D.scale(scaleX: sx, scaleY: sy)
        return try FixedAffineTransform2D.translation(tx: x * pt, ty: y * pt).concatenating(sizing)
    }
    static func fullCanvasTransform(w: Int64, h: Int64, pixelW: Int64, pixelH: Int64) throws -> FixedAffineTransform2D {
        try frameTransform(x: 0, y: 0, w: w, h: h, pixelW: pixelW, pixelH: pixelH)
    }
}

private struct FadeFailingSubmitter: CommandSubmitter {
    let inner: CommandSubmitter
    func makeCommandBuffer() throws -> MTLCommandBuffer { try inner.makeCommandBuffer() }
    func commitAndWait(_ buffer: MTLCommandBuffer) -> CommandCompletion {
        _ = inner.commitAndWait(buffer)
        return .failed(status: "injected", detail: "FadeFailingSubmitter")
    }
}
