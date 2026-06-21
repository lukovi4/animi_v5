import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 plan §6, §13 row "Input completeness" + step-8 corrective issues #3/#4/#5/#8 —
/// `RenderInputResolver` resolves every reference against pre-resolved fixtures, retains the selected
/// programs whole, validates AnimationReference, rejects conflicting pixel ids, and assembles a
/// structurally-complete `ResolvedFrameInput`. Fit mode comes from the layer's authored
/// `mediaPlacement`; there is no external fit map.
final class RenderInputResolverTests: XCTestCase {

    private let pt = CanvasScalar.unitsPerPoint
    private func cs(_ raw: Int64) -> CanvasScalar { CanvasScalar(rawValue: raw) }

    // MARK: - Builders

    private func program(
        templateHash: String = "t", blockID: String, variantID: String = "v",
        animationRef: String = "anim.json", baselinePoints: (Int64, Int64) = (100, 100),
        containerClip: String = "none"
    ) throws -> RenderMaterialProgram {
        let rect = try FixedRect(x: cs(0), y: cs(0),
                                 width: cs(baselinePoints.0 * pt), height: cs(baselinePoints.1 * pt))
        let transform = RenderTransform(
            position: .static(RenderVec2(x: cs(0), y: cs(0))),
            scale: .static(RenderScaleVec2(x: .one, y: .one)),
            rotation: .static(RotationScalar(rawValue: 0)),
            opacity: .static(OpacityScalar.opaque),
            anchor: .static(RenderVec2(x: cs(0), y: cs(0))))
        let timing = RenderLayerTiming(
            inPoint: try RationalSourceTime(numerator: 0, denominator: 1),
            outPoint: try RationalSourceTime(numerator: 150, denominator: 1),
            startTime: try RationalSourceTime(numerator: 0, denominator: 1))
        let layer = RenderLayer(
            id: 1, name: "media", type: 2, timing: timing, parentLayerID: nil, transform: transform,
            masks: [], matte: nil, content: .image(assetID: "asset"), isMatteSource: false,
            isHidden: false, toggleID: nil)
        let comp = RenderComposition(id: "comp_0", width: cs(1080 * pt), height: cs(1920 * pt), layers: [layer])
        let meta = RenderProgramMeta(
            width: cs(1080 * pt), height: cs(1920 * pt),
            fps: try RationalSourceTime(numerator: 30, denominator: 1),
            inPoint: try RationalSourceTime(numerator: 0, denominator: 1),
            outPoint: try RationalSourceTime(numerator: 150, denominator: 1), sourceAnimRef: "anim.json")
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "asset", boundCompID: "comp_0", boundLayerID: 1)
        let geometry = RenderMediaGeometry(
            contentSizeWidth: cs(baselinePoints.0 * pt), contentSizeHeight: cs(baselinePoints.1 * pt),
            contentRect: rect, placementRect: rect, blockRectCanvas: rect, containerClip: containerClip)
        return try RenderMaterialProgram(
            id: try RenderMaterialID(compiledTemplateHash: templateHash, blockID: blockID, variantID: variantID),
            blockID: blockID, variantID: variantID, animationRef: animationRef, boundAssetID: "asset",
            mediaGeometry: geometry, rootCompID: "comp_0", compositions: [comp], assets: [],
            binding: binding, inputGeometry: nil, meta: meta, pathResources: [], toggleIDs: [])
    }

    private func pixels(_ id: String, _ w: Int, _ h: Int, fill: UInt8 = 0xFF,
                        orientation: PixelOrientation = .up) throws -> ResolvedPixelInput {
        let dims = try PixelDimensions(width: w, height: h, bytesPerRow: w * 4, format: .bgra8, orientation: orientation)
        return try ResolvedPixelInput(
            id: try PixelInputID(id), dimensions: dims, bytes: Data(repeating: fill, count: w * h * 4))
    }

    private func sceneID(_ raw: String) throws -> SceneInstanceID { try SceneInstanceID(raw) }
    private func layerID(_ raw: String) throws -> LayerID { try LayerID(raw) }
    private func media(_ fit: MediaFitMode) -> MediaPlacement { .identity(fitMode: fit) }

    /// The shared 100×100-pt block rect that `program(...)` uses for `blockRectCanvas` — the layer's
    /// outer `placement.frame` must equal it (issue #7), so the builders below use the same rect.
    private func blockRect() throws -> FixedRect {
        try FixedRect(x: cs(0), y: cs(0), width: cs(100 * pt), height: cs(100 * pt))
    }

    private func imageLayer(_ layer: String, ref: String, fit: MediaFitMode = .contain,
                            animation: AnimationReference? = nil) throws -> ActiveLayer {
        ActiveLayer(
            layerID: try layerID(layer), zIndex: 0, stableOrdinal: 0, localCompositionOrder: 0,
            placement: try Placement(frame: try blockRect(), scale: .one, rotation: .zero),
            mediaPlacement: media(fit),
            content: .image(try ImageReference(ref)),
            animationReference: animation, animationRequest: nil)
    }

    private func videoLayer(_ layer: String, mediaRef: String, num: Int64, den: Int64,
                            fit: MediaFitMode = .cover) throws -> ActiveLayer {
        let request = SourceRequest(
            media: try MediaReference(mediaRef),
            target: try RationalSourceTime(numerator: num, denominator: den),
            selection: .presentationIntervalContainsTarget)
        return ActiveLayer(
            layerID: try layerID(layer), zIndex: 0, stableOrdinal: 0, localCompositionOrder: 0,
            placement: try Placement(frame: try blockRect(), scale: .one, rotation: .zero),
            mediaPlacement: media(fit),
            content: .video(request), animationReference: nil, animationRequest: nil)
    }

    private func singleFramePlan(sceneID s: String, layers: [ActiveLayer], overlays: [ActiveOverlay] = []) throws -> FramePlan {
        let output = OutputContext(canvas: try CanvasSize(width: 1080, height: 1920),
                                   frameRate: try FrameRate(numerator: 30, denominator: 1))
        let subplan = SceneSubplan(sceneID: try sceneID(s), role: .sole,
                                   visualPlaybackTime: try ScenePlaybackTime(ticks: 0), mediaPlaybackTime: try ScenePlaybackTime(ticks: 0),
                                   transitionRelativeTime: nil, layers: layers)
        return FramePlan(output: output, projectTime: try ProjectTime(ticks: 0), body: .single(subplan), overlays: overlays)
    }

    private func tableFor(_ s: String, _ pairs: [(layer: String, program: RenderMaterialProgram)]) throws -> RenderMaterialTable {
        try RenderMaterialTable(
            programs: pairs.map(\.program),
            sceneBindings: try pairs.map {
                SceneMaterialBinding(key: SceneMaterialBindingKey(sceneID: try sceneID(s), layerID: try layerID($0.layer)),
                                     materialID: $0.program.id)
            })
    }

    // MARK: - Happy path + program retention (#3)

    func testSingleImageLayerResolvesAndRetainsProgram() throws {
        let s = "scene1", l = "blockA"
        let prog = try program(blockID: l)
        let plan = try singleFramePlan(sceneID: s, layers: [try imageLayer(l, ref: "img.png")])
        let resolved = try RenderInputResolver.resolve(
            framePlan: plan, materials: try tableFor(s, [(l, prog)]),
            fixtures: [.image(reference: "img.png"): try pixels("image\u{1F}img.png", 100, 100)])
        let key = ResolvedLayerKey.sceneLayer(sceneID: try sceneID(s), role: .sole, layerID: try layerID(l))
        XCTAssertEqual(resolved.pixelInputCount, 1)
        XCTAssertEqual(resolved.mediaPlacement(for: key)?.fitMode, .contain)
        // Program retained whole (issue #3): same program, with mask/matte/path containers intact.
        XCTAssertEqual(resolved.program(for: key)?.id, prog.id)
        XCTAssertEqual(resolved.programCount, 1)
        XCTAssertFalse(try resolved.contentHash().isEmpty)
    }

    // MARK: - AnimationReference validation (#3)

    func testAnimationRefMismatchRejected() throws {
        let s = "scene1", l = "blockA"
        let prog = try program(blockID: l, animationRef: "anim.json")
        let mismatched = try AnimationReference(
            variantID: "v", animationRef: "OTHER.json",
            authoredDuration: try TickDuration(ticks: 1000), ifShorter: .holdLast, ifLonger: .cutAtEvaluationEnd)
        let plan = try singleFramePlan(sceneID: s, layers: [try imageLayer(l, ref: "img.png", animation: mismatched)])
        XCTAssertThrowsError(try RenderInputResolver.resolve(
            framePlan: plan, materials: try tableFor(s, [(l, prog)]),
            fixtures: [.image(reference: "img.png"): try pixels("p", 100, 100)])) { error in
            guard case RenderGraphError.animationRefMismatch? = error as? RenderGraphError else {
                return XCTFail("expected animationRefMismatch, got \(error)")
            }
        }
    }

    func testAnimationVariantMismatchRejected() throws {
        let s = "scene1", l = "blockA"
        let prog = try program(blockID: l, variantID: "v", animationRef: "anim.json")
        let mismatched = try AnimationReference(
            variantID: "WRONG", animationRef: "anim.json",
            authoredDuration: try TickDuration(ticks: 1000), ifShorter: .holdLast, ifLonger: .cutAtEvaluationEnd)
        let plan = try singleFramePlan(sceneID: s, layers: [try imageLayer(l, ref: "img.png", animation: mismatched)])
        XCTAssertThrowsError(try RenderInputResolver.resolve(
            framePlan: plan, materials: try tableFor(s, [(l, prog)]),
            fixtures: [.image(reference: "img.png"): try pixels("p", 100, 100)])) { error in
            guard case RenderGraphError.animationVariantMismatch? = error as? RenderGraphError else {
                return XCTFail("expected animationVariantMismatch, got \(error)")
            }
        }
    }

    // MARK: - Video target identity (§6)

    func testTwoVideoTargetsOfSameMediaAreDistinctInputs() throws {
        let s = "scene1"
        let p0 = try program(blockID: "v0"), p1 = try program(blockID: "v1")
        let plan = try singleFramePlan(sceneID: s, layers: [
            try videoLayer("v0", mediaRef: "clip.mov", num: 0, den: 1),
            try videoLayer("v1", mediaRef: "clip.mov", num: 1, den: 2)])
        let resolved = try RenderInputResolver.resolve(
            framePlan: plan, materials: try tableFor(s, [("v0", p0), ("v1", p1)]),
            fixtures: [
                .video(reference: "clip.mov", targetNumerator: 0, targetDenominator: 1): try pixels("a", 50, 50, fill: 0x11),
                .video(reference: "clip.mov", targetNumerator: 1, targetDenominator: 2): try pixels("b", 50, 50, fill: 0x22)])
        XCTAssertEqual(resolved.pixelInputCount, 2)
        XCTAssertEqual(resolved.bindingCount, 2)
    }

    // MARK: - Conflicting / coalesced pixel inputs (#4)

    func testConflictingPixelIDRejected() throws {
        let s = "scene1"
        let pa = try program(blockID: "a"), pb = try program(blockID: "b")
        let plan = try singleFramePlan(sceneID: s, layers: [
            try imageLayer("a", ref: "x.png"), try imageLayer("b", ref: "y.png")])
        // Same id "dup" but DIFFERENT content (fill) → conflict.
        XCTAssertThrowsError(try RenderInputResolver.resolve(
            framePlan: plan, materials: try tableFor(s, [("a", pa), ("b", pb)]),
            fixtures: [
                .image(reference: "x.png"): try pixels("dup", 100, 100, fill: 0x01),
                .image(reference: "y.png"): try pixels("dup", 100, 100, fill: 0x02)])) { error in
            guard case RenderModelError.conflictingPixelInput? = error as? RenderModelError else {
                return XCTFail("expected conflictingPixelInput, got \(error)")
            }
        }
    }

    func testValueIdenticalPixelsCoalesce() throws {
        let s = "scene1"
        let pa = try program(blockID: "a"), pb = try program(blockID: "b")
        let plan = try singleFramePlan(sceneID: s, layers: [
            try imageLayer("a", ref: "shared.png"), try imageLayer("b", ref: "shared.png")])
        let shared = try pixels("image\u{1F}shared.png", 100, 100)
        let resolved = try RenderInputResolver.resolve(
            framePlan: plan, materials: try tableFor(s, [("a", pa), ("b", pb)]),
            fixtures: [.image(reference: "shared.png"): shared])
        XCTAssertEqual(resolved.pixelInputCount, 1)
        XCTAssertEqual(resolved.bindingCount, 2)
    }

    // MARK: - Orientation participates in identity (#5)

    func testOrientationDistinguishesContentHash() throws {
        let up = try pixels("o", 10, 10, fill: 0x55, orientation: .up)
        let right = try pixels("o", 10, 10, fill: 0x55, orientation: .right)
        XCTAssertNotEqual(up.contentHash, right.contentHash, "orientation must participate in the hash")
    }

    // MARK: - Transition role disambiguation + overlays

    func testTransitionSameLayerIDDoesNotCollide() throws {
        let sOut = "sceneOut", sIn = "sceneIn", l = "block"
        let output = OutputContext(canvas: try CanvasSize(width: 1080, height: 1920),
                                   frameRate: try FrameRate(numerator: 30, denominator: 1))
        let outgoing = SceneSubplan(sceneID: try sceneID(sOut), role: .outgoing,
                                    visualPlaybackTime: try ScenePlaybackTime(ticks: 0), mediaPlaybackTime: try ScenePlaybackTime(ticks: 0),
                                    transitionRelativeTime: nil, layers: [try imageLayer(l, ref: "out.png", fit: .fill)])
        let incoming = SceneSubplan(sceneID: try sceneID(sIn), role: .incoming,
                                    visualPlaybackTime: try ScenePlaybackTime(ticks: 0), mediaPlaybackTime: try ScenePlaybackTime(ticks: 0),
                                    transitionRelativeTime: nil, layers: [try imageLayer(l, ref: "in.png", fit: .fill)])
        let transition = TransitionPlan(
            effectID: try TransitionEffectID("fade"), parameters: .empty,
            easing: try EasingReference("easeInOut"), progressNumerator: 1, progressDenominator: 2,
            outgoing: outgoing, incoming: incoming)
        let plan = FramePlan(output: output, projectTime: try ProjectTime(ticks: 0), body: .transition(transition), overlays: [])
        let pOut = try program(blockID: l, variantID: "vOut")
        let pIn = try program(blockID: l, variantID: "vIn")
        let table = try RenderMaterialTable(
            programs: [pOut, pIn],
            sceneBindings: [
                SceneMaterialBinding(key: .init(sceneID: try sceneID(sOut), layerID: try layerID(l)), materialID: pOut.id),
                SceneMaterialBinding(key: .init(sceneID: try sceneID(sIn), layerID: try layerID(l)), materialID: pIn.id)])
        let resolved = try RenderInputResolver.resolve(
            framePlan: plan, materials: table,
            fixtures: [
                .image(reference: "out.png"): try pixels("o", 100, 100, fill: 0x01),
                .image(reference: "in.png"): try pixels("i", 100, 100, fill: 0x02)])
        XCTAssertEqual(resolved.bindingCount, 2)
        XCTAssertEqual(resolved.mediaPlacementCount, 2)
        XCTAssertEqual(resolved.programCount, 2)
    }

    func testOverlayBindsPixelsWithoutPlacement() throws {
        let s = "scene1"
        let overlay = ActiveOverlay(
            overlayID: try OverlayID("ov1"), zIndex: 0, stableOrdinal: 0, compositionOrder: 0,
            placement: try Placement(frame: try FixedRect(x: cs(0), y: cs(0), width: cs(1), height: cs(1)), scale: .one, rotation: .zero),
            content: .sticker(try ImageReference("sticker.png")),
            animationReference: nil, animationRequest: nil, playbackTime: try OverlayPlaybackTime(ticks: 0))
        let plan = try singleFramePlan(sceneID: s, layers: [], overlays: [overlay])
        let resolved = try RenderInputResolver.resolve(
            framePlan: plan, materials: try RenderMaterialTable(),
            fixtures: [.overlay(reference: "sticker.png"): try pixels("ov", 20, 20)])
        let key = ResolvedLayerKey.overlay(overlayID: try OverlayID("ov1"))
        XCTAssertNotNil(resolved.pixelInput(for: key))
        XCTAssertNil(resolved.mediaPlacement(for: key))
        XCTAssertEqual(resolved.mediaPlacementCount, 0)
    }

    // MARK: - Fail-closed

    func testMissingFixtureRejected() throws {
        let s = "scene1", l = "blockA"
        let prog = try program(blockID: l)
        let plan = try singleFramePlan(sceneID: s, layers: [try imageLayer(l, ref: "img.png")])
        XCTAssertThrowsError(try RenderInputResolver.resolve(
            framePlan: plan, materials: try tableFor(s, [(l, prog)]), fixtures: [:])) { error in
            guard case RenderGraphError.missingFixturePixels? = error as? RenderGraphError else {
                return XCTFail("expected missingFixturePixels, got \(error)")
            }
        }
    }

    func testMissingMaterialBindingRejected() throws {
        let s = "scene1", l = "blockA"
        let plan = try singleFramePlan(sceneID: s, layers: [try imageLayer(l, ref: "img.png")])
        XCTAssertThrowsError(try RenderInputResolver.resolve(
            framePlan: plan, materials: try RenderMaterialTable(),
            fixtures: [.image(reference: "img.png"): try pixels("p", 100, 100)])) { error in
            guard case RenderGraphError.missingMaterialBinding? = error as? RenderGraphError else {
                return XCTFail("expected missingMaterialBinding, got \(error)")
            }
        }
    }

    func testUnusedFixtureRejected() throws {
        let s = "scene1", l = "blockA"
        let prog = try program(blockID: l)
        let plan = try singleFramePlan(sceneID: s, layers: [try imageLayer(l, ref: "img.png")])
        XCTAssertThrowsError(try RenderInputResolver.resolve(
            framePlan: plan, materials: try tableFor(s, [(l, prog)]),
            fixtures: [
                .image(reference: "img.png"): try pixels("p", 100, 100),
                .image(reference: "unused.png"): try pixels("q", 10, 10)])) { error in
            guard case RenderGraphError.unusedFixture? = error as? RenderGraphError else {
                return XCTFail("expected unusedFixture, got \(error)")
            }
        }
    }

    func testResolverIsDeterministic() throws {
        let s = "scene1", l = "blockA"
        let prog = try program(blockID: l)
        let plan = try singleFramePlan(sceneID: s, layers: [try imageLayer(l, ref: "img.png")])
        func run() throws -> ResolvedFrameInput {
            try RenderInputResolver.resolve(
                framePlan: plan, materials: try tableFor(s, [(l, prog)]),
                fixtures: [.image(reference: "img.png"): try pixels("image\u{1F}img.png", 100, 100)])
        }
        XCTAssertEqual(try run().contentHash(), try run().contentHash())
    }

    // MARK: - Corrective: non-.up orientation rejected (#4)

    func testNonUpFixtureOrientationRejected() throws {
        let s = "scene1", l = "blockA"
        let prog = try program(blockID: l)
        let plan = try singleFramePlan(sceneID: s, layers: [try imageLayer(l, ref: "img.png")])
        XCTAssertThrowsError(try RenderInputResolver.resolve(
            framePlan: plan, materials: try tableFor(s, [(l, prog)]),
            fixtures: [.image(reference: "img.png"): try pixels("p", 100, 100, orientation: .right)])) { error in
            guard case let RenderGraphError.unsupportedFixtureOrientation(_, orientation)? =
                    error as? RenderGraphError else {
                return XCTFail("expected unsupportedFixtureOrientation, got \(error)")
            }
            XCTAssertEqual(orientation, "right")
        }
    }

    // MARK: - Corrective: placement.frame must equal blockRectCanvas (#7)

    func testPlacementFrameMismatchRejected() throws {
        let s = "scene1", l = "blockA"
        let prog = try program(blockID: l)   // blockRectCanvas = 100×100 at origin
        // Build a layer whose outer placement frame is a different rect.
        let layer = ActiveLayer(
            layerID: try layerID(l), zIndex: 0, stableOrdinal: 0, localCompositionOrder: 0,
            placement: try Placement(frame: try FixedRect(x: cs(0), y: cs(0), width: cs(50 * pt), height: cs(50 * pt)),
                                     scale: .one, rotation: .zero),
            mediaPlacement: media(.contain), content: .image(try ImageReference("img.png")),
            animationReference: nil, animationRequest: nil)
        let plan = try singleFramePlan(sceneID: s, layers: [layer])
        XCTAssertThrowsError(try RenderInputResolver.resolve(
            framePlan: plan, materials: try tableFor(s, [(l, prog)]),
            fixtures: [.image(reference: "img.png"): try pixels("p", 100, 100)])) { error in
            guard case RenderGraphError.placementFrameMismatch? = error as? RenderGraphError else {
                return XCTFail("expected placementFrameMismatch, got \(error)")
            }
        }
    }

    // MARK: - Corrective: program dedup conflict (#5)

    func testConflictingProgramSameIDRejected() throws {
        // Two scene layers in different scenes bind the SAME material id but DIFFERENT program content.
        let p1 = try program(templateHash: "t", blockID: "b", variantID: "v", animationRef: "a.json")
        let p2 = try program(templateHash: "t", blockID: "b", variantID: "v", animationRef: "DIFFERENT.json")
        XCTAssertEqual(p1.id, p2.id)            // same RenderMaterialID
        XCTAssertNotEqual(p1, p2)               // different content
        let e1 = try ResolvedSceneLayerEntry(
            key: .sceneLayer(sceneID: try sceneID("s1"), role: .sole, layerID: try layerID("L")),
            program: p1, pixelInput: try pixels("x", 10, 10),
            placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        let e2 = try ResolvedSceneLayerEntry(
            key: .sceneLayer(sceneID: try sceneID("s2"), role: .sole, layerID: try layerID("L")),
            program: p2, pixelInput: try pixels("y", 10, 10),
            placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        XCTAssertThrowsError(try ResolvedFrameInput(sceneLayers: [e1, e2], overlays: [])) { error in
            guard case RenderModelError.conflictingProgram? = error as? RenderModelError else {
                return XCTFail("expected conflictingProgram, got \(error)")
            }
        }
    }

    func testValueIdenticalProgramsCoalesce() throws {
        // Same id + identical content across two scenes → one program retained, both bound.
        let p = try program(templateHash: "t", blockID: "b", variantID: "v")
        let e1 = try ResolvedSceneLayerEntry(
            key: .sceneLayer(sceneID: try sceneID("s1"), role: .sole, layerID: try layerID("L")),
            program: p, pixelInput: try pixels("x", 10, 10),
            placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        let e2 = try ResolvedSceneLayerEntry(
            key: .sceneLayer(sceneID: try sceneID("s2"), role: .sole, layerID: try layerID("L")),
            program: p, pixelInput: try pixels("x", 10, 10),
            placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        let resolved = try ResolvedFrameInput(sceneLayers: [e1, e2], overlays: [])
        XCTAssertEqual(resolved.programCount, 1, "value-identical programs coalesce")
        XCTAssertEqual(resolved.bindingCount, 2)
    }

    // MARK: - Corrective: entry key ownership (#6)

    func testSceneLayerEntryRejectsOverlayKey() throws {
        let p = try program(blockID: "b")
        XCTAssertThrowsError(try ResolvedSceneLayerEntry(
            key: .overlay(overlayID: try OverlayID("ov")), program: p, pixelInput: try pixels("x", 10, 10),
            placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))) { error in
            guard case RenderModelError.unsupportedValue? = error as? RenderModelError else {
                return XCTFail("expected unsupportedValue, got \(error)")
            }
        }
    }

    func testOverlayEntryRejectsSceneLayerKey() throws {
        XCTAssertThrowsError(try ResolvedOverlayEntry(
            key: .sceneLayer(sceneID: try sceneID("s"), role: .sole, layerID: try layerID("L")),
            pixelInput: try pixels("x", 10, 10))) { error in
            guard case RenderModelError.unsupportedValue? = error as? RenderModelError else {
                return XCTFail("expected unsupportedValue, got \(error)")
            }
        }
    }
}
