import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 §17 step 9 final corrective — targeted tests for the last narrow fixes: shape group
/// transform/opacity (#1), full-width Int64-boundary interpolation/subtraction (#2), parent transform
/// time vs visibility (#3), matte-source full pipeline + clear-only rejection (#4), exact storage
/// format (#5), missing authored asset rejection (#6).
final class Step9FinalCorrectiveTests: XCTestCase {

    typealias F = GraphTestFixtures
    private let pt = CanvasScalar.unitsPerPoint
    private func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }
    private func frame(_ n: Int64) throws -> RationalSourceTime { try RationalSourceTime(numerator: n, denominator: 1) }

    // MARK: - #2 Full-width Int64-boundary lerp / subtraction

    func testLerpInt64BoundaryNoOverflow() throws {
        // lerp(Int64.min, Int64.max, 0.5) — midpoint must be computed without an Int64 hi-lo overflow.
        let half = try UnitInterval(rawValue: 500_000)
        let mid = try AnimationSampler.lerp(Int64.min, Int64.max, half, "t")
        // Exact midpoint of [Int64.min, Int64.max] rounds to 0 (ties away from zero → magnitude .5 → 0 or ±1).
        XCTAssertTrue(mid == 0 || mid == -1 || mid == 1, "midpoint near 0, got \(mid)")
    }

    func testLerpEndpointsExactAtBoundaries() throws {
        XCTAssertEqual(try AnimationSampler.lerp(Int64.min, Int64.max, .zero, "t"), Int64.min)
        XCTAssertEqual(try AnimationSampler.lerp(Int64.min, Int64.max, .one, "t"), Int64.max)
        XCTAssertEqual(try AnimationSampler.lerp(-100, 100, try UnitInterval(rawValue: 750_000), "t"), 50)
    }

    func testRationalSubtractionNoInt64MinNegation() throws {
        // t0 with Int64.min numerator: `0 − Int64.min = +2^63` does not fit Int64 → it is a TYPED error
        // (`rationalDoesNotFit`), NOT a trap and NOT a silent wrap from negating Int64.min (issue #2).
        let t0 = try RationalSourceTime(numerator: Int64.min, denominator: 1)
        XCTAssertThrowsError(try (try frame(0)).subtracting(t0)) { error in
            guard case TimeError.rationalDoesNotFit? = error as? TimeError else { return XCTFail("expected typed rationalDoesNotFit, got \(error)") }
        }
        // A representable case with the Int64.min operand: Int64.min − (−1) = Int64.min+1 (no trap).
        XCTAssertEqual(try t0.subtracting(try RationalSourceTime(numerator: -1, denominator: 1)),
                       try RationalSourceTime(numerator: Int64.min + 1, denominator: 1))
        // 5/1 − 2/1 = 3/1.
        XCTAssertEqual(try (try frame(5)).subtracting(try frame(2)), try frame(3))
        // 2/3 − 1/6 = 1/2.
        let a = try RationalSourceTime(numerator: 2, denominator: 3)
        let b = try RationalSourceTime(numerator: 1, denominator: 6)
        XCTAssertEqual(try a.subtracting(b), try RationalSourceTime(numerator: 1, denominator: 2))
    }

    func testWeightedSumDivideBoundary() throws {
        // (Int64.max·1 + Int64.min·1) / 1 = -1, formed in full width with no Int64 sum.
        XCTAssertEqual(try FixedPointMath.weightedSumDivide(Int64.max, 1, Int64.min, 1, 1, "t"), -1)
        // (10·3 + 20·3)/2 = 45.
        XCTAssertEqual(try FixedPointMath.weightedSumDivide(10, 3, 20, 3, 2, "t"), 45)
        XCTAssertThrowsError(try FixedPointMath.weightedSumDivide(1, 1, 1, 1, 0, "t"))   // divisor 0
    }

    // MARK: - #3 Parent transform time uses `compFrame − parent.startTime` exactly

    /// A keyframed X-position track: linear from `(t0, x0)` to `(t1, x1)` (no hold, no easing → linear).
    private func keyframedPositionX(_ t0: Int64, _ x0: Int64, _ t1: Int64, _ x1: Int64) throws -> RenderVectorTrack {
        .keyframed([
            RenderKeyframe(time: try frame(t0), value: RenderVec2(x: cs(x0), y: cs(0)), hold: false, inTangent: nil, outTangent: nil),
            RenderKeyframe(time: try frame(t1), value: RenderVec2(x: cs(x1), y: cs(0)), hold: false, inTangent: nil, outTangent: nil)
        ])
    }

    func testParentTransformUsesCompFrameMinusStartTimeExactly() throws {
        // Real proof of the parent-timing contract (final micro-correction #2):
        //   • compFrame = 13 (sampled via 13·8000 = 104_000 ticks at 30fps).
        //   • parent (id 2) has a NON-ZERO startTime = 3 and a KEYFRAMED X track:
        //       linear t=0→x=0  …  t=20→x=200pt   (both sample positions land on EXACT halves of the
        //       segment, so neither value carries rounding error).
        //   • parent is OUTSIDE its own visible interval at compFrame 13 (visible only [0,5)).
        //   • child (id 3) is visible at compFrame 13 ([0,150)), static y=+40pt, parented to id 2.
        // The parent's transform must be sampled at  localFrame = compFrame − startTime = 13 − 3 = 10,
        // giving s = 10/20 = 0.5 → x = 200pt·0.5 = 100pt EXACTLY. The buggy "use compFrame directly" path
        // would sample at frame 13 → s = 13/20 = 0.65 → x = 130pt — a DIFFERENT exact value, so this
        // cleanly distinguishes `compFrame − parent.startTime` from `compFrame`.
        let parentTiming = RenderLayerTiming(inPoint: try frame(0), outPoint: try frame(5), startTime: try frame(3))
        let parentTransform = RenderTransform(
            position: try keyframedPositionX(0, 0, 20, 200 * pt),
            scale: .static(RenderScaleVec2(x: .one, y: .one)),
            rotation: .static(RotationScalar(rawValue: 0)),
            opacity: .static(.opaque),
            anchor: .static(RenderVec2(x: cs(0), y: cs(0))))
        let parent = RenderLayer(id: 2, name: "p", type: 3, timing: parentTiming, parentLayerID: nil,
            transform: parentTransform, masks: [], matte: nil, content: .none,
            isMatteSource: false, isHidden: false, toggleID: nil)
        let childTiming = RenderLayerTiming(inPoint: try frame(0), outPoint: try frame(150), startTime: .zero)
        let child = RenderLayer(id: 3, name: "c", type: 2, timing: childTiming, parentLayerID: 2,
            transform: F.staticTransform(posX: 0, posY: 40 * pt), masks: [], matte: nil, content: .image(assetID: "authored"),
            isMatteSource: false, isHidden: false, toggleID: nil)
        let p = try F.program(block: "a", extraRootLayers: [parent, child],
            assets: [RenderAsset(id: "authored", resolvedID: "r", basename: "a.png", width: cs(8 * pt), height: cs(8 * pt))])
        let layer = try ActiveLayer(layerID: try LayerID("a"), zIndex: 0, stableOrdinal: 0, localCompositionOrder: 0,
            placement: try Placement(frame: try FixedRect(x: cs(0), y: cs(0), width: cs(100 * pt), height: cs(100 * pt)), scale: .one, rotation: .zero),
            mediaPlacement: .identity(fitMode: .contain), content: .image(try ImageReference("img")),
            animationReference: try AnimationReference(variantID: "v", animationRef: "anim.json", authoredDuration: try TickDuration(ticks: 8_000_000), ifShorter: .holdLast, ifLonger: .cutAtEvaluationEnd),
            animationRequest: .sample(try AnimationPlaybackTime(ticks: 104_000)))   // 13 frames at 30fps = 104000 ticks
        let plan = try F.singlePlan(scene: "s", layers: [layer])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "authored"), pixelInput: try F.pixels("aPix", 8, 8))])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let draw = try XCTUnwrap(graph.commands.compactMap { c -> FixedAffineTransform2D? in
            if case let .drawImage(rid, t, _, _) = c.payload, rid == "aPix" { return t }; return nil }.first)
        let origin = try draw.apply(x: 0, y: 0)
        // x = 130pt · (13−3)/13 = 130pt · 10/13 = 100pt EXACTLY — proves compFrame − startTime, not compFrame.
        XCTAssertEqual(origin.x, 100 * pt, "parent transform sampled at compFrame − startTime (=10), not compFrame (=13)")
        XCTAssertNotEqual(origin.x, 130 * pt, "the compFrame-directly value (130pt) is rejected")
        XCTAssertEqual(origin.y, 40 * pt, "child's own static offset is preserved")
    }

    // MARK: - #1 Shape group transform + opacity

    private func shapeProgram(groupPosX: Int64, groupOpacity: Int64) throws -> RenderMaterialProgram {
        let gt = RenderGroupTransform(
            position: .static(RenderVec2(x: cs(groupPosX), y: cs(0))),
            anchor: .static(RenderVec2(x: cs(0), y: cs(0))),
            scale: .static(RenderScaleVec2(x: .one, y: .one)),
            rotation: .static(RotationScalar(rawValue: 0)),
            opacity: .static(try OpacityScalar(rawValue: groupOpacity)))
        let fill = RenderColor(components: [.one, .zero, .zero, .one])
        let group = RenderShapeGroup(animPath: F.closedBezier(), fillColor: fill, fillOpacity: .opaque, stroke: nil,
                                     groupTransforms: [gt], pathID: 7)
        let shapeLayer = RenderLayer(id: 2, name: "shape", type: 4, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .shapes(group),
            isMatteSource: false, isHidden: false, toggleID: nil)
        return try F.program(block: "a", extraRootLayers: [shapeLayer], pathResources: [try F.pathResource(id: 7)])
    }

    func testShapeGroupTransformAndOpacityComposed() throws {
        // Rev-4 §5.5 — the composed group transform folds into drawShape.transform (world·group); the
        // group opacity is carried on SampledShape.groupOpacity.
        let p = try shapeProgram(groupPosX: 25 * pt, groupOpacity: 500_000)
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let shapeCmd = try XCTUnwrap(graph.commands.first { $0.category == .drawShape })
        guard case let .drawShape(shape, transform, _, _) = shapeCmd.payload else { return XCTFail() }
        // The shape's world transform is identity (placement maps the 1080x1920 block onto the canvas at
        // origin with scale 1), so drawShape.transform == the composed group transform: +25pt in x.
        let origin = try transform.apply(x: 0, y: 0)
        XCTAssertEqual(origin.x, 25 * pt, "group transform position folded into drawShape.transform")
        XCTAssertEqual(shape.groupOpacity.rawValue, 500_000, "group opacity composed")
        XCTAssertNotNil(shape.fillMesh, "fill mesh present")
    }

    func testShapeGroupTransformMutationChangesHash() throws {
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        func hash(groupPosX: Int64, groupOpacity: Int64) throws -> String {
            let p = try shapeProgram(groupPosX: groupPosX, groupOpacity: groupOpacity)
            let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
            return try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config()).graphHash()
        }
        XCTAssertNotEqual(try hash(groupPosX: 25 * pt, groupOpacity: 500_000), try hash(groupPosX: 50 * pt, groupOpacity: 500_000),
                          "group transform mutation changes hash")
        XCTAssertNotEqual(try hash(groupPosX: 25 * pt, groupOpacity: 500_000), try hash(groupPosX: 25 * pt, groupOpacity: 300_000),
                          "group opacity mutation changes hash")
    }

    // MARK: - #4 Matte source full pipeline (own masks / nested matte) + clear-only (empty source) allowance

    func testMatteSourceWithOwnMaskRendered() throws {
        // Matte source (id 2, image, isMatteSource) carries its OWN mask — the full pipeline must emit it.
        let sourceMask = RenderMask(mode: "a", inverted: false, opacity: .opaque, path: F.closedBezier(), pathID: 7)
        let source = RenderLayer(id: 2, name: "ms", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [sourceMask], matte: nil, content: .image(assetID: "ma"),
            isMatteSource: true, isHidden: false, toggleID: nil)
        let bound = RenderLayer(id: 1, name: "media", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: RenderMatte(mode: 1, sourceLayerID: 2),
            content: .image(assetID: "boundAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: cs(1080 * pt), height: cs(1920 * pt), layers: [bound, source])
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset", boundCompID: "comp_0", boundLayerID: 1)
        let p = try RenderMaterialProgram(id: try RenderMaterialID(compiledTemplateHash: "t", blockID: "a", variantID: "v"),
            blockID: "a", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0", compositions: [root],
            assets: [RenderAsset(id: "ma", resolvedID: "r", basename: "m.png", width: cs(8 * pt), height: cs(8 * pt))],
            binding: binding, inputGeometry: nil, meta: try F.meta(),
            pathResources: [try F.pathResource(id: 7)], toggleIDs: [])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "ma"), pixelInput: try F.pixels("mPix", 8, 8))])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        // The matte source is rendered through its full pipeline: its own mask group isolates the mPix
        // draw into a mask-content surface whose endMask composites into the matte source surface.
        let sourceSurface = try XCTUnwrap(graph.commands.compactMap { c -> String? in
            if case let .matteLink(_, _, _, s, _, _) = c.payload { return s }; return nil }.first)
        // The source's own mask group exists and targets the matte source surface.
        let maskTargetsSource = graph.commands.contains {
            if case let .beginMask(_, _, t) = $0.payload { return t == sourceSurface }; return false }
        XCTAssertTrue(maskTargetsSource, "matte source's own mask group targets the matte source surface (full pipeline)")
        let drewSource = graph.commands.contains { if case let .drawImage(rid, _, _, _) = $0.payload { return rid == "mPix" }; return false }
        XCTAssertTrue(drewSource, "matte source content (mPix) rendered")
        XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()))
    }

    /// Builds a program whose root comp = [bound media (id 1)] + the supplied authored layers, with a
    /// single authored asset "ma" (8×8) supplied as pixels "mPix". Used by the nested-matte tests.
    private func matteProgram(extra: [RenderLayer]) throws -> (RenderMaterialProgram, [ResolvedAssetPixelEntry]) {
        let bound = RenderLayer(id: 1, name: "media", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: RenderMatte(mode: 1, sourceLayerID: 2),
            content: .image(assetID: "boundAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: cs(1080 * pt), height: cs(1920 * pt), layers: [bound] + extra)
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset", boundCompID: "comp_0", boundLayerID: 1)
        let p = try RenderMaterialProgram(id: try RenderMaterialID(compiledTemplateHash: "t", blockID: "a", variantID: "v"),
            blockID: "a", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0", compositions: [root],
            assets: [RenderAsset(id: "ma", resolvedID: "r", basename: "m.png", width: cs(8 * pt), height: cs(8 * pt))],
            binding: binding, inputGeometry: nil, meta: try F.meta(), pathResources: [], toggleIDs: [])
        let pix = [ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "ma"), pixelInput: try F.pixels("mPix", 8, 8))]
        return (p, pix)
    }

    func testNestedMatteConsumerThroughSourceThatConsumesAnotherMatte() throws {
        // Real nested matte (final micro-correction #3):
        //   consumer (id 1, bound media)  →matte→  source (id 2, isMatteSource) which ITSELF
        //   →matte→  source (id 3, isMatteSource).
        // Each consumer→source step must allocate its OWN distinct matte surface, render the source into
        // it through the full pipeline, and emit its own matteLink. So we expect TWO distinct surfaces,
        // TWO source draws (one per surface), and TWO matte links (1→2 and 2→3).
        let innerSource = RenderLayer(id: 3, name: "ms_inner", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .image(assetID: "ma"),
            isMatteSource: true, isHidden: false, toggleID: nil)
        let midSource = RenderLayer(id: 2, name: "ms_mid", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: RenderMatte(mode: 1, sourceLayerID: 3),
            content: .image(assetID: "ma"), isMatteSource: true, isHidden: false, toggleID: nil)
        let (p, pix) = try matteProgram(extra: [midSource, innerSource])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: pix)
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())

        // Collect the matte links: expect (consumer 1 ← source 2) and (consumer 2 ← source 3).
        let links = graph.commands.compactMap { c -> (mode: RenderMatteMode, src: Int, dst: Int, surf: String)? in
            if case let .matteLink(mode, src, dst, surf, _, _) = c.payload { return (mode, src, dst, surf) }; return nil }
        XCTAssertEqual(links.count, 2, "two matte links: 1←2 and 2←3")
        let link12 = try XCTUnwrap(links.first { $0.dst == 1 && $0.src == 2 }, "consumer 1 links source 2")
        let link23 = try XCTUnwrap(links.first { $0.dst == 2 && $0.src == 3 }, "consumer 2 links source 3")
        // Two DISTINCT matte surfaces.
        XCTAssertNotEqual(link12.surf, link23.surf, "each matte link uses a distinct context-unique surface")

        // Each surface is declared as an offscreen intermediate surface.
        let declaredSurfaces = Set(graph.commands.compactMap { c -> String? in
            if case let .offscreenSurface(d) = c.payload { return d.resourceID }; return nil })
        XCTAssertTrue(declaredSurfaces.contains(link12.surf), "matte surface for 1←2 declared")
        XCTAssertTrue(declaredSurfaces.contains(link23.surf), "matte surface for 2←3 declared")

        // Inner source 3 (no matte) is rendered directly into the 2←3 matte source surface.
        func drewMPix(into surface: String) -> Bool {
            graph.commands.contains { if case let .drawImage(rid, _, _, t) = $0.payload { return rid == "mPix" && t == surface }; return false }
        }
        XCTAssertTrue(drewMPix(into: link23.surf), "inner source 3 rendered into the 2←3 matte surface")
        // Source 2 is itself a matte consumer: its matted contribution composites into the 1←2 matte
        // source surface via the 2←3 matteLink's target (Rev-4 §5.4 isolation), not a direct draw.
        let innerLinkTargetsOuter = graph.commands.contains {
            if case let .matteLink(_, s, d, _, _, t) = $0.payload { return s == 3 && d == 2 && t == link12.surf }; return false }
        XCTAssertTrue(innerLinkTargetsOuter, "the 2←3 matte composites source 2's contribution into the 1←2 matte surface")

        // The inner link (2←3) is emitted BEFORE the outer link (1←2): the inner matte is resolved while
        // rendering source 2 into the outer matte surface, so its ordinal precedes the outer link's.
        let innerOrd = try XCTUnwrap(graph.commands.first { if case let .matteLink(_, s, d, _, _, _) = $0.payload { return s == 3 && d == 2 }; return false }).ordinal
        let outerOrd = try XCTUnwrap(graph.commands.first { if case let .matteLink(_, s, d, _, _, _) = $0.payload { return s == 2 && d == 1 }; return false }).ordinal
        XCTAssertLessThan(innerOrd, outerOrd, "the nested (inner) matte is resolved before its enclosing consumer's link")

        XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()))
    }

    func testMatteChainTwoCycleRejectedWithoutDepthBackstop() throws {
        // A length-2 matte cycle: source 2 consumes a matte whose source is layer 3, and source 3
        // consumes a matte whose source is layer 2 (2→3→2). This is NOT a direct self-reference (so
        // resolveMatte's self-check does not catch it) and it must be rejected as a typed `matteCycle`
        // by the explicit per-chain visited set — long before the depth-64 backstop would fire.
        let s3 = RenderLayer(id: 3, name: "s3", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: RenderMatte(mode: 1, sourceLayerID: 2),
            content: .image(assetID: "ma"), isMatteSource: true, isHidden: false, toggleID: nil)
        let s2 = RenderLayer(id: 2, name: "s2", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: RenderMatte(mode: 1, sourceLayerID: 3),
            content: .image(assetID: "ma"), isMatteSource: true, isHidden: false, toggleID: nil)
        let (p, pix) = try matteProgram(extra: [s2, s3])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: pix)
        XCTAssertThrowsError(try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())) { error in
            guard case let RenderGraphError.matteCycle(_, layerID)? = error as? RenderGraphError else {
                return XCTFail("expected typed matteCycle, got \(error)")
            }
            XCTAssertTrue(layerID == 2 || layerID == 3, "cycle reported on a chain member, got \(layerID)")
        }
    }

    func testClearOnlyMatteSourceSurfaceAllowed() throws {
        // CP7.5: a matte SOURCE surface cleared but never drawn into is an EMPTY (non-drawing) matte
        // source — e.g. content fully clipped / zero-coverage at this frame. The validator must ACCEPT
        // it (the matteLink composites an empty source). This is NOT the timing-inactive/hidden case:
        // the compiler renders a timing-inactive or hidden matte source HELD (TVECore oracle parity),
        // so that source IS drawn. This test only covers the genuinely-empty-but-declared source.
        func surface(_ id: String, _ profile: RenderSurfaceProfile) -> RenderCommandPayload {
            .offscreenSurface(RenderResourceDescriptor(offscreenID: id, width: 1, height: 1, profile: profile, colorContract: .task003))
        }
        let matteS = "surface\u{1F}matte\u{1F}x"
        let consumerS = "surface\u{1F}matteConsumer\u{1F}x"
        let p: [RenderCommandPayload] = [
            surface(RenderSurface.linearCanvas, .intermediate(.rgba16FloatLinear)),
            surface(RenderSurface.sRGBSurface, .finalSRGB),
            surface(matteS, .intermediate(.rgba16FloatLinear)),
            surface(consumerS, .intermediate(.rgba16FloatLinear)),
            .declareResource(RenderResourceDescriptor(pixelInputID: "r", pixels: try F.pixels("r", 1, 1), colorContract: .task003)),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .clearBackground(color: .transparentBlack, targetSurfaceID: matteS),   // empty source: cleared only (no draw)
            .clearBackground(color: .transparentBlack, targetSurfaceID: consumerS),
            .drawImage(resourceID: "r", transform: .identity, opacity: .opaque, targetSurfaceID: consumerS),
            .matteLink(mode: .alpha, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: matteS, consumerSurfaceID: consumerS, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)
        ]
        let graph = try RenderGraph(configuration: try F.config(), commands: try p.enumerated().map { try RenderCommand(ordinal: $0.offset, payload: $0.element) })
        XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()),
                         "clear-only (empty/non-drawing) matte source is valid")
    }

    func testMatteSourceSurfaceNeverClearedStillRejected() throws {
        // GUARD: a matte source surface that is neither drawn into NOR cleared as a matte isolation
        // surface is still a genuine dependency bug → rejected.
        func surface(_ id: String, _ profile: RenderSurfaceProfile) -> RenderCommandPayload {
            .offscreenSurface(RenderResourceDescriptor(offscreenID: id, width: 1, height: 1, profile: profile, colorContract: .task003))
        }
        let matteS = "surface\u{1F}matte\u{1F}y"
        let consumerS = "surface\u{1F}matteConsumer\u{1F}y"
        let p: [RenderCommandPayload] = [
            surface(RenderSurface.linearCanvas, .intermediate(.rgba16FloatLinear)),
            surface(RenderSurface.sRGBSurface, .finalSRGB),
            surface(matteS, .intermediate(.rgba16FloatLinear)),
            surface(consumerS, .intermediate(.rgba16FloatLinear)),
            .declareResource(RenderResourceDescriptor(pixelInputID: "r", pixels: try F.pixels("r", 1, 1), colorContract: .task003)),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            // matteS is NEVER cleared inside the scene (not a matte isolation surface) — genuine bug.
            .clearBackground(color: .transparentBlack, targetSurfaceID: consumerS),
            .drawImage(resourceID: "r", transform: .identity, opacity: .opaque, targetSurfaceID: consumerS),
            .matteLink(mode: .alpha, sourceLayerID: 2, consumerLayerID: 1, sourceSurfaceID: matteS, consumerSurfaceID: consumerS, targetSurfaceID: RenderSurface.linearCanvas),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)
        ]
        let graph = try RenderGraph(configuration: try F.config(), commands: try p.enumerated().map { try RenderCommand(ordinal: $0.offset, payload: $0.element) })
        XCTAssertThrowsError(try RenderGraphValidator.validate(graph, configuration: try F.config())) { error in
            guard case RenderGraphError.validatorInvalidSurfaceDependency? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - #5 Exact storage format

    func testRGBA16FloatLinearSurfaceHasCorrectStorage() throws {
        let p = try F.program(block: "a")
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let surfaces = graph.commands.compactMap { c -> RenderResourceDescriptor? in if case let .offscreenSurface(d) = c.payload { return d }; return nil }
        let lin = try XCTUnwrap(surfaces.first { $0.resourceID == RenderSurface.linearCanvas })
        XCTAssertEqual(lin.surfaceStorage, .rgba16FloatLinear, "rgba16FloatLinear surface is NOT mislabelled as BGRA8")
        let srgb = try XCTUnwrap(surfaces.first { $0.resourceID == RenderSurface.sRGBSurface })
        XCTAssertEqual(srgb.surfaceStorage, .bgra8SRGB)
    }

    func testValidatorRejectsStorageMismatch() throws {
        // A linearCanvas declared with finalSRGB profile (→ bgra8SRGB storage) but the config is
        // rgba16FloatLinear → profile mismatch.
        func surface(_ id: String, _ profile: RenderSurfaceProfile) -> RenderCommandPayload {
            .offscreenSurface(RenderResourceDescriptor(offscreenID: id, width: 1, height: 1, profile: profile, colorContract: .task003))
        }
        let p: [RenderCommandPayload] = [
            surface(RenderSurface.linearCanvas, .finalSRGB),    // wrong profile for the linear canvas
            surface(RenderSurface.sRGBSurface, .finalSRGB),
            .clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas),
            .finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface),
            .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)
        ]
        let graph = try RenderGraph(configuration: try F.config(), commands: try p.enumerated().map { try RenderCommand(ordinal: $0.offset, payload: $0.element) })
        XCTAssertThrowsError(try RenderGraphValidator.validate(graph, configuration: try F.config())) { error in
            guard case RenderGraphError.validatorColorProfileMismatch? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - #6 Missing authored asset rejection

    func testMissingAuthoredAssetRejected() throws {
        // An authored image layer references assetID "authored" but the program declares NO RenderAsset.
        let authored = RenderLayer(id: 2, name: "x", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .image(assetID: "authored"),
            isMatteSource: false, isHidden: false, toggleID: nil)
        let p = try F.program(block: "a", extraRootLayers: [authored], assets: [])   // no RenderAsset
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "authored"), pixelInput: try F.pixels("aPix", 8, 8))])
        XCTAssertThrowsError(try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())) { error in
            guard case RenderGraphError.missingAuthoredAsset? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    func testInvalidAuthoredAssetDimensionsRejected() throws {
        let authored = RenderLayer(id: 2, name: "x", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .image(assetID: "authored"),
            isMatteSource: false, isHidden: false, toggleID: nil)
        // RenderAsset with zero width → invalid.
        let p = try F.program(block: "a", extraRootLayers: [authored],
            assets: [RenderAsset(id: "authored", resolvedID: "r", basename: "a.png", width: cs(0), height: cs(8 * pt))])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "authored"), pixelInput: try F.pixels("aPix", 8, 8))])
        XCTAssertThrowsError(try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())) { error in
            guard case RenderGraphError.missingAuthoredAsset? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }
}
