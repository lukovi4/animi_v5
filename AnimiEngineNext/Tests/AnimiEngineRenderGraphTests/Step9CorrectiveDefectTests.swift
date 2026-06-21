import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 §17 step 9 corrective — focused defect tests: placement origin (#4), shape commands + hash
/// mutation (#1), compiler-level parent chain (#2), precomp/shape matte source + matte-ID collision
/// (#3), empty scene surface init (#5), rgba16FloatLinear surface descriptor (#6), arithmetic (#8).
final class Step9CorrectiveDefectTests: XCTestCase {

    typealias F = GraphTestFixtures
    private let pt = CanvasScalar.unitsPerPoint
    private func cs(_ v: Int64) -> CanvasScalar { CanvasScalar(rawValue: v) }

    // MARK: - #4 Placement origin (exact matrix)

    func testPlacementOriginTranslationWithScale1Rot0() throws {
        // frame origin (10,20)pt, scale=1, rotation=0 → pure translation (10,20)pt.
        let placement = try Placement(
            frame: try FixedRect(x: cs(10 * pt), y: cs(20 * pt), width: cs(100 * pt), height: cs(100 * pt)),
            scale: .one, rotation: .zero)
        let m = try RenderGraphCompiler.placementMatrix(placement)
        let origin = try m.apply(x: 0, y: 0)
        XCTAssertEqual(origin.x, 10 * pt, "non-zero origin produces translation even with scale=1/rot=0")
        XCTAssertEqual(origin.y, 20 * pt)
        XCTAssertEqual(m.a, 1_000_000); XCTAssertEqual(m.d, 1_000_000)
    }

    func testPlacementScaleAboutFrameCentre() throws {
        // 100×100 frame at origin (0,0), scale ×2 about local centre (50,50): corner (0,0) → (-50,-50)pt.
        let placement = try Placement(
            frame: try FixedRect(x: cs(0), y: cs(0), width: cs(100 * pt), height: cs(100 * pt)),
            scale: try ScaleScalar(positiveRawValue: 2_000_000), rotation: .zero)
        let m = try RenderGraphCompiler.placementMatrix(placement)
        let corner = try m.apply(x: 0, y: 0)
        XCTAssertEqual(corner.x, -50 * pt); XCTAssertEqual(corner.y, -50 * pt)
    }

    func testPlacementRotationAboutFrameCentre() throws {
        // 90° about centre (50,50): centre stays fixed.
        let placement = try Placement(
            frame: try FixedRect(x: cs(0), y: cs(0), width: cs(100 * pt), height: cs(100 * pt)),
            scale: .one, rotation: RotationScalar(rawValue: 90 * 1000))
        let m = try RenderGraphCompiler.placementMatrix(placement)
        let centre = try m.apply(x: 50 * pt, y: 50 * pt)
        XCTAssertEqual(centre.x, 50 * pt, accuracy: 4); XCTAssertEqual(centre.y, 50 * pt, accuracy: 4)
    }

    // MARK: - #1 Shape command + hash mutation

    private func shapeProgram(fillR: Int64) throws -> RenderMaterialProgram {
        let group = RenderShapeGroup(
            animPath: F.closedBezier(),
            fillColor: RenderColor(components: [try NormalizedColorComponent(rawValue: fillR), .zero, .zero, .one]),
            fillOpacity: .opaque, stroke: nil, groupTransforms: [], pathID: 7)
        let shapeLayer = RenderLayer(id: 2, name: "shape", type: 4, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .shapes(group),
            isMatteSource: false, isHidden: false, toggleID: nil)
        return try F.program(block: "a", extraRootLayers: [shapeLayer], pathResources: [try F.pathResource(id: 7)])
    }

    func testShapeEmitsTypedCommandWithGeometry() throws {
        let p = try shapeProgram(fillR: 500_000)
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let shapeCmd = try XCTUnwrap(graph.commands.first { $0.category == .drawShape })
        guard case let .drawShape(shape, _, _, _) = shapeCmd.payload else { return XCTFail() }
        XCTAssertNotNil(shape.fillMesh, "shape carries sampled producer-flattened fill mesh")
        XCTAssertEqual(shape.fillMesh?.positions.count, 6)
        XCTAssertEqual(shape.fillColor?.red.rawValue, 500_000)
    }

    func testShapeMutationChangesGraphHash() throws {
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        func hash(fillR: Int64) throws -> String {
            let p = try shapeProgram(fillR: fillR)
            let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
            return try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config()).graphHash()
        }
        XCTAssertNotEqual(try hash(fillR: 500_000), try hash(fillR: 600_000), "mutating shape fill changes the graph hash")
    }

    // MARK: - #2 Compiler-level parent chain

    func testParentChainAppliedInCompiler() throws {
        // root comp: parent layer (id 2, translate +30,0) and child image (id 3, parent 2, translate +0,+40).
        // The authored image's world origin must include the parent's translation: (30,40).
        let parent = RenderLayer(id: 2, name: "p", type: 3, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(posX: 30 * pt, posY: 0), masks: [], matte: nil, content: .none,
            isMatteSource: false, isHidden: false, toggleID: nil)
        let child = RenderLayer(id: 3, name: "c", type: 2, timing: try F.timing(), parentLayerID: 2,
            transform: F.staticTransform(posX: 0, posY: 40 * pt), masks: [], matte: nil, content: .image(assetID: "authored"),
            isMatteSource: false, isHidden: false, toggleID: nil)
        let p = try F.program(block: "a", extraRootLayers: [parent, child],
            assets: [RenderAsset(id: "authored", resolvedID: "r", basename: "a.png", width: cs(8 * pt), height: cs(8 * pt))])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "authored"), pixelInput: try F.pixels("aPix", 8, 8))])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        let draw = try XCTUnwrap(graph.commands.compactMap { c -> FixedAffineTransform2D? in
            if case let .drawImage(rid, t, _, _) = c.payload, rid == "aPix" { return t }; return nil }.first)
        let origin = try draw.apply(x: 0, y: 0)
        XCTAssertEqual(origin.x, 30 * pt, "parent chain translation applied in the compiler path")
        XCTAssertEqual(origin.y, 40 * pt)
    }

    func testCompilerParentCycleRejected() throws {
        let a = RenderLayer(id: 2, name: "a", type: 3, timing: try F.timing(), parentLayerID: 3,
            transform: F.staticTransform(), masks: [], matte: nil, content: .none, isMatteSource: false, isHidden: false, toggleID: nil)
        let b = RenderLayer(id: 3, name: "b", type: 2, timing: try F.timing(), parentLayerID: 2,
            transform: F.staticTransform(), masks: [], matte: nil, content: .image(assetID: "x"), isMatteSource: false, isHidden: false, toggleID: nil)
        let p = try F.program(block: "a", extraRootLayers: [a, b], assets: [RenderAsset(id: "x", resolvedID: "r", basename: "x.png", width: cs(1), height: cs(1))])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "x"), pixelInput: try F.pixels("xPix", 1, 1))])
        XCTAssertThrowsError(try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())) { error in
            guard case RenderGraphError.parentCycle? = error as? RenderGraphError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - #3 Precomp matte source renders into matte surface (not frame.target)

    func testPrecompMatteSourceRendersIntoMatteSurface() throws {
        // Matte source (id 2) is a precomp → comp_1 (one image). Consumer (binding id 1) uses it.
        let nested = RenderLayer(id: 1, name: "nested", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .image(assetID: "nestedAsset"),
            isMatteSource: false, isHidden: false, toggleID: nil)
        let comp1 = RenderComposition(id: "comp_1", width: cs(100 * pt), height: cs(100 * pt), layers: [nested])
        let matteSource = RenderLayer(id: 2, name: "ms", type: 0, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil, content: .precomp(compID: "comp_1"),
            isMatteSource: true, isHidden: false, toggleID: nil)
        let boundWithMatte = RenderLayer(id: 1, name: "media", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: RenderMatte(mode: 1, sourceLayerID: 2),
            content: .image(assetID: "boundAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: cs(1080 * pt), height: cs(1920 * pt), layers: [boundWithMatte, matteSource])
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset", boundCompID: "comp_0", boundLayerID: 1)
        let p = try RenderMaterialProgram(id: try RenderMaterialID(compiledTemplateHash: "t", blockID: "a", variantID: "v"),
            blockID: "a", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0", compositions: [root, comp1],
            assets: [RenderAsset(id: "nestedAsset", resolvedID: "rn", basename: "n.png", width: cs(1), height: cs(1))],
            binding: binding, inputGeometry: nil, meta: try F.meta(), pathResources: [], toggleIDs: [])
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: p.id, assetID: "nestedAsset"), pixelInput: try F.pixels("nPix", 8, 8))])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        // The nested precomp image (nPix) must be drawn into the matte surface, not linearCanvas.
        let nestedDraw = try XCTUnwrap(graph.commands.compactMap { c -> String? in
            if case let .drawImage(rid, _, _, target) = c.payload, rid == "nPix" { return target }; return nil }.first)
        XCTAssertTrue(nestedDraw.contains("matte"), "precomp matte source renders into the matte surface, not frame.target")
        XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()))
    }

    func testMatteSurfaceIDsDoNotCollideAcrossLayers() throws {
        // Two scene layers, each with a matte source layer id 2 in their own program → distinct surfaces.
        func matteProgram(block: String) throws -> RenderMaterialProgram {
            let source = RenderLayer(id: 2, name: "ms", type: 2, timing: try F.timing(), parentLayerID: nil,
                transform: F.staticTransform(), masks: [], matte: nil, content: .image(assetID: "ma"),
                isMatteSource: true, isHidden: false, toggleID: nil)
            let bound = RenderLayer(id: 1, name: "media", type: 2, timing: try F.timing(), parentLayerID: nil,
                transform: F.staticTransform(), masks: [], matte: RenderMatte(mode: 1, sourceLayerID: 2),
                content: .image(assetID: "boundAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
            let root = RenderComposition(id: "comp_0", width: cs(1080 * pt), height: cs(1920 * pt), layers: [bound, source])
            let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset", boundCompID: "comp_0", boundLayerID: 1)
            return try RenderMaterialProgram(id: try RenderMaterialID(compiledTemplateHash: "t", blockID: block, variantID: "v"),
                blockID: block, variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
                mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0", compositions: [root],
                assets: [RenderAsset(id: "ma", resolvedID: "r", basename: "m.png", width: cs(1), height: cs(1))],
                binding: binding, inputGeometry: nil, meta: try F.meta(), pathResources: [], toggleIDs: [])
        }
        let pa = try matteProgram(block: "a"), pb = try matteProgram(block: "b")
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "imgA", order: 0), try F.imageActiveLayer("b", ref: "imgB", order: 1)])
        let inp = try F.singleInput(scene: "s", [("a", pa, "pa"), ("b", pb, "pb")], assetPixels: [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: pa.id, assetID: "ma"), pixelInput: try F.pixels("maA", 1, 1)),
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: pb.id, assetID: "ma"), pixelInput: try F.pixels("maB", 1, 1))])
        // If matte surface IDs collided, the validator's duplicate-resource check would throw.
        XCTAssertNoThrow(try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config()),
                         "matte surface IDs include scene/layer context and do not collide")
    }

    // MARK: - #5 Empty scene surface initialisation

    func testEmptyTransitionSceneSurfaceCleared() throws {
        // A transition outgoing scene with no draws still clears its surface so it is written before read.
        let empty = SceneSubplan(sceneID: try SceneInstanceID("sOut"), role: .outgoing, visualPlaybackTime: .zero, mediaPlaybackTime: .zero, transitionRelativeTime: nil, layers: [])
        let incoming = SceneSubplan(sceneID: try SceneInstanceID("sIn"), role: .incoming, visualPlaybackTime: .zero, mediaPlaybackTime: .zero, transitionRelativeTime: nil,
            layers: [try F.imageActiveLayer("li", ref: "refI", order: 0)])
        let tp = TransitionPlan(effectID: try TransitionEffectID("fade"), parameters: .empty, easing: try EasingReference("linear"),
            progressNumerator: 1, progressDenominator: 2, outgoing: empty, incoming: incoming)
        let plan = FramePlan(output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)),
            projectTime: try ProjectTime(ticks: 0), body: .transition(tp), overlays: [])
        let e2 = try ResolvedSceneLayerEntry(key: .sceneLayer(sceneID: try SceneInstanceID("sIn"), role: .incoming, layerID: try LayerID("li")),
            program: try F.program(block: "i"), pixelInput: try F.pixels("pI"), placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        let inp = try ResolvedFrameInput(sceneLayers: [e2], overlays: [])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        // The empty outgoing surface is cleared (initialised) even though no layer draws into it.
        let outSurface = "surface\u{1F}outgoing\u{1F}sOut"
        let cleared = graph.commands.contains { if case let .clearBackground(_, t) = $0.payload { return t == outSurface }; return false }
        XCTAssertTrue(cleared, "empty scene surface is cleared/initialised")
        XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: try F.config()))
    }

    // MARK: - #6 rgba16FloatLinear surface descriptor

    func testIntermediateSurfacesUseConfiguredProfile() throws {
        let p = try F.program(block: "a")
        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("a", ref: "img", order: 0)])
        let inp = try F.singleInput(scene: "s", [("a", p, "px0")])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: inp, configuration: try F.config())
        // linearCanvas uses the intermediate profile; sRGB surface uses finalSRGB.
        let surfaces = graph.commands.compactMap { c -> RenderResourceDescriptor? in if case let .offscreenSurface(d) = c.payload { return d }; return nil }
        let lin = try XCTUnwrap(surfaces.first { $0.resourceID == RenderSurface.linearCanvas })
        XCTAssertEqual(lin.surfaceProfile, .intermediate(.rgba16FloatLinear))
        let srgb = try XCTUnwrap(surfaces.first { $0.resourceID == RenderSurface.sRGBSurface })
        XCTAssertEqual(srgb.surfaceProfile, .finalSRGB)
    }

    // MARK: - #8 Arithmetic boundaries

    func testTransitionProgressMustBeStrictlyLessThanOne() {
        XCTAssertThrowsError(try TransitionEasing.progress(numerator: 2, denominator: 2)) // == 1 rejected
        XCTAssertNoThrow(try TransitionEasing.progress(numerator: 1, denominator: 2))
        XCTAssertThrowsError(try TransitionEasing.progress(numerator: 3, denominator: 2))
    }

    func testLoopedModuloInt64BoundaryNoOverflow() throws {
        let m = RenderProgramMeta(width: cs(1), height: cs(1), fps: (try RationalSourceTime(numerator: 30, denominator: 1)),
            inPoint: .zero, outPoint: (try RationalSourceTime(numerator: 30, denominator: 1)), sourceAnimRef: "a")
        // A large playback time wraps without overflow.
        let t = try AnimationPlaybackTime(ticks: Int64.max / 2)
        XCTAssertNoThrow(try AnimationSampler.frameTime(for: .looped(t), meta: m, authoredDurationTicks: 240_000))
    }
}
