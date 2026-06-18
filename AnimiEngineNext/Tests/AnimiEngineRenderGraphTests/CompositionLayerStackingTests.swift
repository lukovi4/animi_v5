import XCTest
import Foundation
@testable import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineTemplateAdapter
@testable import AnimiEngineRenderGraph

/// Task-004 / CP2 blocker corrective — composition layer stacking order.
///
/// AE/Lottie `comp.layers` is ordered top-to-bottom (array index 0 is the front-most / top
/// layer), so the renderer must emit draw commands bottom-to-top: the LAST array element first
/// and the FIRST element last. Before the fix `RenderGraphCompiler.expandComposition` iterated
/// `comp.layers` forward, drawing index 0 (the top decor) UNDER later layers — the CP2 blocker
/// where `full_image`'s authored `plastik.png` rendered beneath the user photo.
///
/// These tests assert EXACT relative draw order (not just `contains`), at the synthetic level
/// (single comp, nested precomp) and for the real `full_image` template.
final class CompositionLayerStackingTests: XCTestCase {

    private typealias F = GraphTestFixtures

    /// Ordered list of `drawImage` resource ids in graph emission order.
    private func drawnImageOrder(_ graph: RenderGraph) -> [String] {
        graph.commands.compactMap { c in
            if case let .drawImage(rid, _, _, _) = c.payload { return rid }
            return nil
        }
    }

    // MARK: - Req 4: single comp, top authored asset over bottom binding media

    func test_singleComp_topAuthoredAsset_drawsAfter_bottomBindingMedia() throws {
        // comp.layers authored order = [top authored decor, bottom binding media].
        // Draw order must be: binding media FIRST (bottom), authored decor LAST (top).
        let topDecor = RenderLayer(
            id: 2, name: "decor", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil,
            content: .image(assetID: "decorAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let bottomMedia = RenderLayer(
            id: 1, name: "media", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil,
            content: .image(assetID: "boundAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: F.cs(1080 * F.pt), height: F.cs(1920 * F.pt),
                                     layers: [topDecor, bottomMedia])   // index 0 = top
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset",
                                    boundCompID: "comp_0", boundLayerID: 1)
        let program = try RenderMaterialProgram(
            id: try RenderMaterialID(compiledTemplateHash: "t", blockID: "b", variantID: "v"),
            blockID: "b", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0", compositions: [root],
            assets: [RenderAsset(id: "decorAsset", resolvedID: "decor", basename: "decor",
                                 width: F.cs(64 * F.pt), height: F.cs(64 * F.pt))],
            binding: binding, inputGeometry: nil, meta: try F.meta(), pathResources: [], toggleIDs: [])

        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("1", ref: "userRef", order: 0)])
        let assetPix = ResolvedAssetPixelEntry(
            key: ResolvedAssetKey(materialID: program.id, assetID: "decorAsset"),
            pixelInput: try F.pixels("decorPix"))
        let input = try F.singleInput(scene: "s", [(layer: "1", program: program, pixID: "userPix")],
                                      assetPixels: [assetPix])
        let graph = try RenderGraphCompiler.compile(plan: plan, input: input, configuration: try F.config())

        let order = drawnImageOrder(graph)
        guard let iMedia = order.firstIndex(of: "userPix"),
              let iDecor = order.firstIndex(of: "decorPix") else {
            return XCTFail("expected both media (userPix) and decor (decorPix) drawn; got \(order)")
        }
        XCTAssertLessThan(iMedia, iDecor,
            "binding media must draw BEFORE (under) the top authored decor; order=\(order)")
    }

    // MARK: - Req 5: nested precomp — reversed order applies recursively

    func test_nestedPrecomp_reversedOrderAppliesRecursively() throws {
        // Inner comp.layers = [innerTop, innerBottom]; expect innerBottom drawn before innerTop.
        let innerTop = RenderLayer(
            id: 11, name: "innerTop", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil,
            content: .image(assetID: "innerTopAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let innerBottom = RenderLayer(
            id: 12, name: "innerBottom", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil,
            content: .image(assetID: "innerBottomAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let inner = RenderComposition(id: "comp_inner", width: F.cs(1080 * F.pt), height: F.cs(1920 * F.pt),
                                      layers: [innerTop, innerBottom])   // index 0 = top

        // Root comp.layers = [precompLayer(top), bottomMedia]. precomp expands to inner's two layers.
        let precompLayer = RenderLayer(
            id: 2, name: "precomp", type: 0, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil,
            content: .precomp(compID: "comp_inner"), isMatteSource: false, isHidden: false, toggleID: nil)
        let bottomMedia = RenderLayer(
            id: 1, name: "media", type: 2, timing: try F.timing(), parentLayerID: nil,
            transform: F.staticTransform(), masks: [], matte: nil,
            content: .image(assetID: "boundAsset"), isMatteSource: false, isHidden: false, toggleID: nil)
        let root = RenderComposition(id: "comp_0", width: F.cs(1080 * F.pt), height: F.cs(1920 * F.pt),
                                     layers: [precompLayer, bottomMedia])   // index 0 = top
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "boundAsset",
                                    boundCompID: "comp_0", boundLayerID: 1)
        let program = try RenderMaterialProgram(
            id: try RenderMaterialID(compiledTemplateHash: "t", blockID: "b", variantID: "v"),
            blockID: "b", variantID: "v", animationRef: "anim.json", boundAssetID: "boundAsset",
            mediaGeometry: try F.mediaGeometry(), rootCompID: "comp_0", compositions: [root, inner],
            assets: [
                RenderAsset(id: "innerTopAsset", resolvedID: "it", basename: "it", width: F.cs(64 * F.pt), height: F.cs(64 * F.pt)),
                RenderAsset(id: "innerBottomAsset", resolvedID: "ib", basename: "ib", width: F.cs(64 * F.pt), height: F.cs(64 * F.pt))
            ],
            binding: binding, inputGeometry: nil, meta: try F.meta(), pathResources: [], toggleIDs: [])

        let plan = try F.singlePlan(scene: "s", layers: [try F.imageActiveLayer("1", ref: "userRef", order: 0)])
        let assetPix = [
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: program.id, assetID: "innerTopAsset"),
                                    pixelInput: try F.pixels("innerTopPix")),
            ResolvedAssetPixelEntry(key: ResolvedAssetKey(materialID: program.id, assetID: "innerBottomAsset"),
                                    pixelInput: try F.pixels("innerBottomPix"))
        ]
        let input = try F.singleInput(scene: "s", [(layer: "1", program: program, pixID: "userPix")],
                                      assetPixels: assetPix)
        let graph = try RenderGraphCompiler.compile(plan: plan, input: input, configuration: try F.config())

        let order = drawnImageOrder(graph)
        guard let iBottom = order.firstIndex(of: "innerBottomPix"),
              let iTop = order.firstIndex(of: "innerTopPix") else {
            return XCTFail("expected both inner layers drawn; got \(order)")
        }
        XCTAssertLessThan(iBottom, iTop,
            "inside a precomp, the bottom layer (array index 1) must draw before the top (index 0); order=\(order)")
    }

    // MARK: - Req 6: real-template full_image — media before plastik (plastik topmost)

    func test_realTemplate_fullImage_drawsMediaBeforePlastik() throws {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url.appendPathComponent("AnimiApp/Resources/Scenes/full_image/compiled.tve")
        let data = try Data(contentsOf: url)

        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        var chosen: [String: String] = [:]
        var bindings: [String: CompiledTemplateConverter.MediaBinding] = [:]
        for block in inventory.blocks {
            chosen[block.blockID] = block.selectedVariantID
            bindings[block.blockID] = .image(reference: "media-\(block.blockID)",
                                             mediaPlacement: .identity(fitMode: .contain))
        }
        let out = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "full_image", sceneInstanceID: "inst", scenePayloadID: "pay",
            selection: TemplateVariantInventory.Selection(chosenVariantByBlockID: chosen),
            mediaBindings: bindings, requiredPostRoll: .zero))

        // Evaluate -> single-scene FramePlan at tick 0.
        let index = try TimelineIndex(manifest: out.document.manifest)
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: try out.document.manifest.projectDuration().ticks))
        let requirement = try index.requirements(for: coverage)
        let window = try EvaluationWindowBuilder.build(requirement: requirement, scenes: out.document.scenePayloads, overlays: out.document.overlayPayloads)
        let plan = try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: 0))
        guard case let .single(subplan) = plan.body else { return XCTFail("expected single scene") }

        // Base resolve binds media fixtures.
        var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
        for layer in subplan.layers {
            if case let .image(ref) = layer.content {
                fixtures[.image(reference: ref.raw)] = try px("media-pix")
            }
        }
        let base = try RenderInputResolver.resolve(framePlan: plan, materials: out.materials, fixtures: fixtures)

        // Collect authored-asset pixels (plastik) and record the plastik pixel id.
        var sceneEntries: [ResolvedSceneLayerEntry] = []
        var assetEntries: [ResolvedAssetPixelEntry] = []
        var plastikPixelID: String?
        for layer in subplan.layers {
            let key = ResolvedLayerKey.sceneLayer(sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
            guard let program = base.program(for: key), let placement = base.mediaPlacement(for: key),
                  let pixels = base.pixelInput(for: key) else { continue }
            sceneEntries.append(try ResolvedSceneLayerEntry(key: key, program: program, pixelInput: pixels, placement: placement))
            let assetByID = Dictionary(uniqueKeysWithValues: program.assets.map { ($0.id, $0) })
            for assetID in authoredAssetIDs(program).sorted() {
                let pid = "plastik-\(assetID)"
                if assetByID[assetID]?.basename == "plastik" { plastikPixelID = pid }
                assetEntries.append(ResolvedAssetPixelEntry(
                    key: ResolvedAssetKey(materialID: program.id, assetID: assetID),
                    pixelInput: try px(pid)))
            }
        }
        let input = try ResolvedFrameInput(sceneLayers: sceneEntries, overlays: [], assetPixels: assetEntries)
        let graph = try RenderGraphCompiler.compile(plan: plan, input: input, configuration: try GraphTestFixtures.config())

        let order = drawnImageOrder(graph)
        XCTAssertTrue(order.contains("media-pix"), "full_image must draw user media; order=\(order)")
        let plastik = try XCTUnwrap(plastikPixelID, "full_image must contain a plastik authored asset")
        guard let iMedia = order.firstIndex(of: "media-pix"),
              let iPlastik = order.firstIndex(of: plastik) else {
            return XCTFail("expected both media and plastik drawn; order=\(order)")
        }
        XCTAssertLessThan(iMedia, iPlastik,
            "full_image: user media must draw BEFORE (under) plastik so plastik is topmost; order=\(order)")
    }

    // MARK: - Audit (req 7): which real templates have order-affected comps

    /// Prints, for each real template, the max number of VISIBLE image layers in any single comp.
    /// A comp with >= 2 visible image layers is order-affected by the stacking fix — its promoted
    /// Task-003 references (rendered with the OLD forward order) are now stale.
    func test_audit_orderAffectedTemplates() throws {
        for cat in ["full_image", "polaroid_2", "polaroid_shared_demo", "example_4blocks", "6_frames_template"] {
            var url = URL(fileURLWithPath: #file)
            for _ in 0..<4 { url.deleteLastPathComponent() }
            url.appendPathComponent("AnimiApp/Resources/Scenes/\(cat)/compiled.tve")
            let data = try Data(contentsOf: url)
            let decoded = try CompiledTemplateDecoder.decode(data)
            let inventory = try TemplateVariantInventory(from: decoded)
            var chosen: [String: String] = [:]
            var bindings: [String: CompiledTemplateConverter.MediaBinding] = [:]
            for block in inventory.blocks {
                chosen[block.blockID] = block.selectedVariantID
                bindings[block.blockID] = .image(reference: "r-\(block.blockID)", mediaPlacement: .identity(fitMode: .contain))
            }
            let out = try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: data, catalogID: cat, sceneInstanceID: "inst", scenePayloadID: "pay",
                selection: TemplateVariantInventory.Selection(chosenVariantByBlockID: chosen),
                mediaBindings: bindings, requiredPostRoll: .zero))
            var maxVisibleImages = 0
            for program in out.materials.programs {
                for comp in program.compositions {
                    let visibleImages = comp.layers.filter {
                        if case .image = $0.content, !$0.isHidden, !$0.isMatteSource { return true }
                        return false
                    }.count
                    maxVisibleImages = max(maxVisibleImages, visibleImages)
                }
            }
            print("[AUDIT] \(cat): maxVisibleImageLayersPerComp=\(maxVisibleImages) orderAffected=\(maxVisibleImages >= 2)")
        }
    }

    // MARK: - Helpers

    private func px(_ id: String) throws -> ResolvedPixelInput {
        try ResolvedPixelInput(id: try PixelInputID(id),
            dimensions: try PixelDimensions(width: 32, height: 32, bytesPerRow: 128, format: .bgra8, orientation: .up),
            bytes: Data(repeating: 0x80, count: 32 * 32 * 4))
    }

    /// Authored (non-binding) image asset ids referenced across a program's full comp tree.
    private func authoredAssetIDs(_ program: RenderMaterialProgram) -> Set<String> {
        var ids = Set<String>()
        let compByID = Dictionary(uniqueKeysWithValues: program.compositions.map { ($0.id, $0) })
        func walk(_ comp: RenderComposition, visiting: Set<String>) {
            guard !visiting.contains(comp.id) else { return }
            let next = visiting.union([comp.id])
            for layer in comp.layers {
                let isBinding = (comp.id == program.binding.boundCompID && layer.id == program.binding.boundLayerID)
                switch layer.content {
                case let .image(assetID) where !isBinding: ids.insert(assetID)
                case let .precomp(compID): if let sub = compByID[compID] { walk(sub, visiting: next) }
                default: break
                }
            }
        }
        if let root = compByID[program.rootCompID] { walk(root, visiting: []) }
        return ids
    }
}
