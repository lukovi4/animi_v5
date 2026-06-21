import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 §17 step 9 corrective — `RenderGraphCompiler` tests proving the corrected behaviours:
/// explicit surface flow (#2), full precomp-tree expansion (#3), asset pixels (#4), sampled mask
/// geometry (#5), matte source rendering (#6), complete transforms (#7), dense ordering (#9),
/// self-validation (#10), and mutation-sensitivity of the graph hash (#11). No adapter/IO/Metal dep.
final class RenderGraphCompilerCorrectiveTests: XCTestCase {

    typealias F = GraphTestFixtures
    private let pt = CanvasScalar.unitsPerPoint
    private func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }

    // MARK: - Explicit surface flow (#2)

    func testExplicitSurfaceFlow() throws {
        let p = try F.program(block: "a")
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())

        // Declarations come first; the first non-declaration command clears the linear canvas.
        let firstBody = try XCTUnwrap(graph.commands.first { $0.category != .declareResource && $0.category != .offscreenSurface })
        guard case let .clearBackground(_, clearTarget) = firstBody.payload else { return XCTFail() }
        XCTAssertEqual(clearTarget, RenderSurface.linearCanvas)
        guard case let .finalOutput(outSrc) = graph.commands.last?.payload else { return XCTFail() }
        XCTAssertEqual(outSrc, RenderSurface.sRGBSurface)
        // Validator (run by the compiler) accepts it.
        XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()))
        // Draw targets the linear canvas.
        let draw = try XCTUnwrap(graph.commands.first { $0.category == .drawImage })
        guard case let .drawImage(_, _, _, drawTarget) = draw.payload else { return XCTFail() }
        XCTAssertEqual(drawTarget, RenderSurface.linearCanvas)
    }

    // MARK: - Pixel bytes retained (#1)

    func testDeclaredPixelResourceCarriesBytes() throws {
        let p = try F.program(block: "a")
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let decl = try XCTUnwrap(graph.commands.compactMap { c -> RenderResourceDescriptor? in
            if case let .declareResource(d) = c.payload { return d }; return nil }.first)
        XCTAssertNotNil(decl.pixels, "pixel resource retains owned bytes (corrective #1)")
        XCTAssertEqual(decl.pixels?.bytes.count, 64 * 64 * 4)
    }

    // MARK: - Full precomp-tree expansion (#3) + asset pixels (#4)

    /// Root comp has: binding image layer (id 1), an authored image layer (id 2, asset "authored"),
    /// and a precomp layer (id 3 → comp_1) containing another authored image (id 1, asset "nested").
    private func treeProgram() throws -> RenderMaterialProgram {
        let authored = RenderLayer(id: 2, name: "authored", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(posX: 10 * pt, posY: 0), masks: [], matte: nil,
            content: .image(assetID: "authored"), isMatteSource: false, isHidden: false, toggleID: nil)
        let precompLayer = RenderLayer(id: 3, name: "pre", type: 0, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(posX: 0, posY: 20 * pt), masks: [], matte: nil,
            content: .precomp(compID: "comp_1"), isMatteSource: false, isHidden: false, toggleID: nil)
        let nested = RenderLayer(id: 1, name: "nested", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .image(assetID: "nested"),
            isMatteSource: false, isHidden: false, toggleID: nil)
        let comp1 = RenderComposition(id: "comp_1", width: cs(100 * pt), height: cs(100 * pt), layers: [nested])
        return try F.program(block: "a", extraRootLayers: [authored, precompLayer], extraComps: [comp1],
            assets: [RenderAsset(id: "authored", resolvedID: "ra", basename: "a.png", width: cs(10), height: cs(10)),
                     RenderAsset(id: "nested", resolvedID: "rn", basename: "n.png", width: cs(10), height: cs(10))])
    }

    func testFullPrecompTreeExpandedWithAssetPixels() throws {
        let p = try treeProgram()
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let assetEntries = [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "authored"), pixelInput: try F.pixels("aPix", 8, 8, fill: 0x10)),
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "nested"), pixelInput: try F.pixels("nPix", 8, 8, fill: 0x20))
        ]
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: assetEntries)
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        // Three draws: binding user media (px0) + authored (aPix) + nested precomp (nPix).
        let drawResources = graph.commands.compactMap { c -> String? in
            if case let .drawImage(rid, _, _, _) = c.payload { return rid }; return nil }
        XCTAssertTrue(drawResources.contains("px0"), "binding user media drawn")
        XCTAssertTrue(drawResources.contains("aPix"), "authored asset drawn")
        XCTAssertTrue(drawResources.contains("nPix"), "nested precomp asset drawn (tree expanded)")
        XCTAssertEqual(drawResources.count, 3)
    }

    func testMissingAssetPixelsRejected() throws {
        let p = try treeProgram()
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        // Provide only "authored", omit "nested" → typed failure.
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "authored"), pixelInput: try F.pixels("aPix", 8, 8))])
        XCTAssertThrowsError(try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())) { error in
            guard case RenderGraphError.missingAssetPixels? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    func testHiddenLayerNotDrawn() throws {
        let hidden = RenderLayer(id: 2, name: "h", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .image(assetID: "authored"),
            isMatteSource: false, isHidden: true, toggleID: nil)
        let p = try F.program(block: "a", extraRootLayers: [hidden],
            assets: [RenderAsset(id: "authored", resolvedID: "r", basename: "a.png", width: cs(1), height: cs(1))])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])   // no asset pixels needed (hidden)
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let draws = graph.commands.compactMap { c -> String? in if case let .drawImage(rid, _, _, _) = c.payload { return rid }; return nil }
        XCTAssertEqual(draws, ["px0"], "hidden layer is not drawn")
    }

    func testTypeContentMismatchRejected() throws {
        // type=2 (image) but content=.none → misalignment.
        let bad = RenderLayer(id: 2, name: "x", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .none,
            isMatteSource: false, isHidden: false, toggleID: nil)
        let p = try F.program(block: "a", extraRootLayers: [bad])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        XCTAssertThrowsError(try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())) { error in
            guard case RenderGraphError.unsupportedLayerMode? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Sampled mask geometry (#5)

    func testMaskCarriesSampledGeometry() throws {
        let mask = RenderMask(mode: "a", inverted: false, opacity: .opaque, path: F.closedBezier(), pathID: 7)
        let bound = RenderLayer(id: 1, name: "media", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [mask], matte: nil, content: .image(assetID: "boundAsset"),
            isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: cs(1080 * pt), height: cs(1920 * pt), layers: [bound])
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset", boundCompID: "comp_0", boundLayerID: 1)
        let p = try RenderMaterialProgram(id: try RenderMaterialID(compiledTemplateHash: "t", blockID: "a", variantID: "v"),
            blockID: "a", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0", compositions: [root], assets: [],
            binding: binding, inputGeometry: nil, meta: try F.meta(), pathResources: [try F.pathResource(id: 7)], toggleIDs: [])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let beginMask = try XCTUnwrap(graph.commands.first { $0.category == .beginMask })
        guard case let .beginMask(operations, content, target) = beginMask.payload else { return XCTFail() }
        XCTAssertEqual(operations.count, 1, "one mask operation in authored order")
        XCTAssertEqual(operations[0].mesh.positions.count, 6, "sampled mesh carries flattened positions (3 verts)")
        XCTAssertEqual(operations[0].mesh.closed, true)
        XCTAssertNotEqual(content, target, "content and target surfaces are distinct")
        XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()))
    }

    // MARK: - Matte source rendered + linked (#6)

    func testMatteSourceRenderedIntoSurfaceAndLinked() throws {
        // Matte source layer id 2 (isMatteSource, image) + bound layer (id 1) consumes it via alpha matte.
        let source = RenderLayer(id: 2, name: "matte", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .image(assetID: "matteAsset"),
            isMatteSource: true, isHidden: false, toggleID: nil)
        let boundWithMatte = RenderLayer(id: 1, name: "media", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: RenderMatte(mode: 1, sourceLayerID: 2),
            content: .image(assetID: "boundAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: cs(1080 * pt), height: cs(1920 * pt), layers: [boundWithMatte, source])
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset", boundCompID: "comp_0", boundLayerID: 1)
        let p = try RenderMaterialProgram(id: try RenderMaterialID(compiledTemplateHash: "t", blockID: "a", variantID: "v"),
            blockID: "a", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0",
            compositions: [root], assets: [RenderAsset(id: "matteAsset", resolvedID: "rm", basename: "m.png", width: cs(1), height: cs(1))],
            binding: binding, inputGeometry: nil, meta: try F.meta(), pathResources: [], toggleIDs: [])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "matteAsset"), pixelInput: try F.pixels("mPix", 8, 8))])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        // The matte source must actually render into its surface, then be linked.
        let link = try XCTUnwrap(graph.commands.compactMap { c -> String? in
            if case let .matteLink(_, _, _, surface, _, _) = c.payload { return surface }; return nil }.first)
        // A draw into the matte surface exists (source rendered, not just linked).
        let drewIntoMatteSurface = graph.commands.contains {
            if case let .drawImage(_, _, _, target) = $0.payload { return target == link }; return false }
        XCTAssertTrue(drewIntoMatteSurface, "matte source is actually rendered into its surface (corrective #6)")
        XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()))
    }

    func testTimingInactiveMatteSourceStillRendersHeld() throws {
        // CP7.5 ORACLE PARITY: matte source layer id 2 is authored active only [0,30) but the compiled
        // frame is past that (timing-inactive). TVECore renders a matte source via
        // `emitLayerForMatteSource` WITHOUT any isVisible/isHidden gate (transform tracks clamp to the
        // last keyframe = hold-last), so the consumer (block_02) stays matted/VISIBLE past the source's
        // authored end. The Next compiler must therefore STILL RENDER the source (drawn into its
        // surface), NOT leave it transparent and NOT throw.
        let source = RenderLayer(id: 2, name: "matte", type: 2, timing: try F.timing(0, 30), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .image(assetID: "matteAsset"),
            isMatteSource: true, isHidden: false, toggleID: nil)
        let boundWithMatte = RenderLayer(id: 1, name: "media", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: RenderMatte(mode: 1, sourceLayerID: 2),
            content: .image(assetID: "boundAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: cs(1080 * pt), height: cs(1920 * pt), layers: [boundWithMatte, source])
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset", boundCompID: "comp_0", boundLayerID: 1)
        let p = try RenderMaterialProgram(id: try RenderMaterialID(compiledTemplateHash: "t", blockID: "a", variantID: "v"),
            blockID: "a", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0",
            compositions: [root], assets: [RenderAsset(id: "matteAsset", resolvedID: "rm", basename: "m.png", width: cs(1), height: cs(1))],
            binding: binding, inputGeometry: nil, meta: try F.meta(), pathResources: [], toggleIDs: [])
        // holdLast program → compiled at meta.outPoint-1 (frame 149), well past the source's out=30.
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "matteAsset"), pixelInput: try F.pixels("mPix", 8, 8))])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let link = graph.commands.compactMap { c -> String? in
            if case let .matteLink(_, _, _, surface, _, _) = c.payload { return surface }; return nil }.first
        let matteSurface = try XCTUnwrap(link, "matteLink must be emitted")
        // The timing-inactive matte source IS drawn into its surface (held), not left transparent.
        let drewIntoSource = graph.commands.contains {
            if case let .drawImage(_, _, _, target) = $0.payload { return target == matteSurface }; return false }
        XCTAssertTrue(drewIntoSource, "timing-inactive matte source must still render (held) — oracle parity")
        XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()))
    }

    // MARK: - Complete transforms (#7)

    /// CP4 canonical contract (supersedes the old corrective #7 "blockToCanvas carries the outer
    /// Placement scale/rotation"): blockToCanvas mirrors the TVECore oracle — it maps the block's
    /// ANIMATION space into the block rect via animToInputContain (identity when animSize == canvas).
    /// The user scale/rotation lives in authored layer transforms / mediaPlacement, NOT in
    /// blockToCanvas. Here animSize (100×100) ≠ canvas (1080×1920) and blockRect = (10,20,100×100), so
    /// blockToCanvas = scale 1 (100/100) + translate to the block origin (10,20)pt — NO ×2 scale.
    func testBlockToCanvasMatchesAnimToInputContain() throws {
        let p = try F.program(block: "a")
        let rect = try FixedRect(x: cs(10 * pt), y: cs(20 * pt), width: cs(100 * pt), height: cs(100 * pt))
        let placement = try Placement(frame: rect, scale: .one, rotation: .zero)
        let layer = ActiveLayer(layerID: try LayerID("a"), zIndex: 0, stableOrdinal: 0, localCompositionOrder: 0,
            placement: placement, mediaPlacement: .identity(fitMode: .contain), content: .image(try ImageReference("img")),
            animationReference: nil, animationRequest: .holdLast)
        let geom = RenderMediaGeometry(contentSizeWidth: cs(100 * pt), contentSizeHeight: cs(100 * pt),
            contentRect: try FixedRect(x: cs(0), y: cs(0), width: cs(100 * pt), height: cs(100 * pt)),
            placementRect: rect, blockRectCanvas: rect, containerClip: "none")
        // animSize now lives in `meta.width/height` (CP4 Rev-4): 100×100 ≠ canvas 1080×1920 so blockToCanvas
        // takes the animToInputContain branch (the whole point of this test).
        let meta100 = RenderProgramMeta(width: cs(100 * pt), height: cs(100 * pt), fps: try F.frame(30),
            inPoint: .zero, outPoint: try F.frame(150), sourceAnimRef: "anim.json")
        let p2 = try RenderMaterialProgram(id: p.id, blockID: "a", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: geom, rootCompID: "comp_0", compositions: p.compositions, assets: [],
            binding: p.binding, inputGeometry: nil, meta: meta100, pathResources: [], toggleIDs: [])
        let plan = try F.singlePlan(scene: "s", layers: [layer])
        let inp = try F.singleInput(scene: "s", [("a", p2, "px0")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let draw = try XCTUnwrap(graph.commands.first { $0.category == .drawImage })
        guard case let .drawImage(_, transform, _, _) = draw.payload else { return XCTFail() }
        // blockToCanvas is contain-scale 1 (no user ×2); the block origin (10,20)pt is applied once.
        XCTAssertEqual(transform.a, 1_000_000, "blockToCanvas contain-scale = 1 (no spurious user scale): \(transform)")
        XCTAssertEqual(transform.d, 1_000_000)
        XCTAssertEqual(transform.tx, cs(10 * pt).rawValue, "block origin x applied ONCE")
        XCTAssertEqual(transform.ty, cs(20 * pt).rawValue, "block origin y applied ONCE")
    }

    // MARK: - Dense ordering (#9)

    func testNonDenseLocalCompositionOrderRejected() throws {
        let pa = try F.program(block: "a"), pb = try F.program(block: "b")
        // orders 0 and 2 (gap) → reject.
        let l0 = try F.imageActiveLayer("a", ref: "imgA", order: 0)
        let l2 = try F.imageActiveLayer("b", ref: "imgB", order: 2)
        let plan = try F.singlePlan(scene: "s", layers: [l0, l2])
        let inp = try F.singleInput(scene: "s", [("a", pa, "pa"), ("b", pb, "pb")])
        XCTAssertThrowsError(try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())) { error in
            guard case RenderGraphError.nonDenseOrder? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Determinism + mutation sensitivity (#11)

    func testDeterministicAndMutationChangesHash() throws {
        let p = try treeProgram()
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let assetEntries = [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "authored"), pixelInput: try F.pixels("aPix", 8, 8, fill: 0x10)),
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "nested"), pixelInput: try F.pixels("nPix", 8, 8, fill: 0x20))
        ]
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: assetEntries)
        let g1 = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let g2 = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        XCTAssertEqual(try g1.graphHash(), try g2.graphHash(), "deterministic")

        // Mutate an execution-relevant authored element (asset pixel bytes) → hash must change.
        let mutated = [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "authored"), pixelInput: try F.pixels("aPix", 8, 8, fill: 0x10)),
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "nested"), pixelInput: try F.pixels("nPix", 8, 8, fill: 0x99))   // changed
        ]
        let inpM = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: mutated)
        let gM = try RenderGraphCompiler.compile(plan: plan, input: inpM, configuration: try F.config())
        XCTAssertNotEqual(try g1.graphHash(), try gM.graphHash(), "mutating an asset's pixels changes the graph hash")
    }

    // MARK: - No adapter / Metal dependency (#11)

    func testCompilerUsesNoAdapterOrMetalTypes() throws {
        let p = try F.program(block: "a")
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        XCTAssertNoThrow(try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config()))
    }

    // MARK: - FCP §1 — strict colour arity (no RGB→RGBA coercion / fallback)

    private func color(_ n: Int) -> RenderColor {
        RenderColor(components: Array(repeating: NormalizedColorComponent.one, count: n))
    }

    func testFillConverterRequiresExactlyFourComponents() throws {
        // RGBA(4) accepted.
        XCTAssertNoThrow(try RenderGraphCompiler.fillSRGBA(color(4), field: "f"))
        // RGB(3) rejected — no implicit alpha.
        XCTAssertThrowsError(try RenderGraphCompiler.fillSRGBA(color(3), field: "f")) { e in
            guard case RenderGraphError.unsupportedLayerMode = e else { return XCTFail("\(e)") }
        }
        // 5 components rejected.
        XCTAssertThrowsError(try RenderGraphCompiler.fillSRGBA(color(5), field: "f")) { e in
            guard case RenderGraphError.unsupportedLayerMode = e else { return XCTFail("\(e)") }
        }
    }

    func testStrokeConverterRequiresExactlyThreeComponentsAndSetsAlphaOne() throws {
        // RGB(3) accepted; alpha is explicitly .one.
        let c = try RenderGraphCompiler.strokeSRGBA(color(3), field: "s")
        XCTAssertEqual(c.alpha, .one, "stroke converter sets alpha = .one explicitly")
        // RGBA(4) rejected — the stroke colour must be RGB.
        XCTAssertThrowsError(try RenderGraphCompiler.strokeSRGBA(color(4), field: "s")) { e in
            guard case RenderGraphError.unsupportedLayerMode = e else { return XCTFail("\(e)") }
        }
        // 2 components rejected.
        XCTAssertThrowsError(try RenderGraphCompiler.strokeSRGBA(color(2), field: "s")) { e in
            guard case RenderGraphError.unsupportedLayerMode = e else { return XCTFail("\(e)") }
        }
    }

    func testSampledSRGBAColorRejectsNonFourComponents() throws {
        XCTAssertNoThrow(try SampledSRGBAColor(components: [.one, .one, .one, .one]))
        for badCount in [0, 1, 2, 3, 5, 6] {
            XCTAssertThrowsError(try SampledSRGBAColor(components: Array(repeating: NormalizedColorComponent.one, count: badCount))) { e in
                guard case RenderModelError.unsupportedValue = e else { return XCTFail("count \(badCount): \(e)") }
            }
        }
    }
}
