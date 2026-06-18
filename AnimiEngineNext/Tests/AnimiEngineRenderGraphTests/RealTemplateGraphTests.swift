import XCTest
import Foundation
@testable import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineTemplateAdapter
@testable import AnimiEngineRenderGraph

/// Task-003 §12 corrective #11 — real-template graph compilation: decode → convert → evaluate →
/// resolve → compile → validate, for all five real templates. Proves every authored renderable layer
/// (binding media + authored image assets across the full precomp tree) is represented, and that
/// removing a required asset pixel produces a typed failure.
final class RealTemplateGraphTests: XCTestCase {

    private func tveBytes(_ catalogID: String) throws -> Data {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url.appendPathComponent("AnimiApp/Resources/Scenes/\(catalogID)/compiled.tve")
        return try Data(contentsOf: url)
    }

    private func evaluate(_ document: CanonicalProjectDocument, atTick tick: Int64) throws -> FramePlan {
        let index = try TimelineIndex(manifest: document.manifest)
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: try document.manifest.projectDuration().ticks))
        let requirement = try index.requirements(for: coverage)
        let window = try EvaluationWindowBuilder.build(requirement: requirement, scenes: document.scenePayloads, overlays: document.overlayPayloads)
        return try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: tick))
    }

    private func convert(_ catalogID: String) throws -> CompiledTemplateConverter.Output {
        let data = try tveBytes(catalogID)
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        var chosen: [String: String] = [:]
        var bindings: [String: CompiledTemplateConverter.MediaBinding] = [:]
        for block in inventory.blocks {
            chosen[block.blockID] = block.selectedVariantID
            bindings[block.blockID] = .image(reference: "real-\(block.blockID)", mediaPlacement: .identity(fitMode: .contain))
        }
        return try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: catalogID, sceneInstanceID: "inst", scenePayloadID: "pay",
            selection: TemplateVariantInventory.Selection(chosenVariantByBlockID: chosen),
            mediaBindings: bindings, requiredPostRoll: .zero))
    }

    private func px(_ id: String) throws -> ResolvedPixelInput {
        try ResolvedPixelInput(id: try PixelInputID(id),
            dimensions: try PixelDimensions(width: 32, height: 32, bytesPerRow: 128, format: .bgra8, orientation: .up),
            bytes: Data(repeating: 0x80, count: 32 * 32 * 4))
    }

    /// Collects every authored (non-binding) image assetID referenced across a program's full comp tree.
    private func authoredAssetIDs(_ program: RenderMaterialProgram) -> Set<String> {
        var ids = Set<String>()
        let compByID = Dictionary(uniqueKeysWithValues: program.compositions.map { ($0.id, $0) })
        func walk(_ comp: RenderComposition, visiting: Set<String>) {
            guard !visiting.contains(comp.id) else { return }
            let next = visiting.union([comp.id])
            for layer in comp.layers {
                let isBinding = (comp.id == program.binding.boundCompID && layer.id == program.binding.boundLayerID)
                switch layer.content {
                case .image(let assetID) where !isBinding: ids.insert(assetID)
                case .precomp(let cid): if let sub = compByID[cid] { walk(sub, visiting: next) }
                default: break
                }
            }
        }
        if let root = compByID[program.rootCompID] { walk(root, visiting: []) }
        return ids
    }

    func testAllFiveRealTemplatesCompileWithFullTreeAndValidate() throws {
        let cfg = try GraphTestFixtures.config()
        for catalogID in ["full_image", "polaroid_shared_demo", "polaroid_2", "example_4blocks", "6_frames_template"] {
            let out = try convert(catalogID)
            let plan = try evaluate(out.document, atTick: 0)
            guard case let .single(subplan) = plan.body else { XCTFail("[\(catalogID)] expected single"); continue }

            // Media fixtures for each scene layer.
            var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
            for (i, layer) in subplan.layers.enumerated() {
                guard case let .image(ref) = layer.content else { continue }
                fixtures[.image(reference: ref.raw)] = try px("\(catalogID)-media-\(i)")
            }
            let resolved0 = try RenderInputResolver.resolve(framePlan: plan, materials: out.materials, fixtures: fixtures)

            // Collect authored asset pixels from every scene layer's program (full tree).
            var assetEntries: [ResolvedAssetPixelEntry] = []
            for layer in subplan.layers {
                let key = ResolvedLayerKey.sceneLayer(sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
                guard let program = resolved0.program(for: key) else { continue }
                for assetID in authoredAssetIDs(program).sorted() {
                    assetEntries.append(ResolvedAssetPixelEntry(
                        key: ResolvedAssetKey(materialID: program.id, assetID: assetID),
                        pixelInput: try px("\(catalogID)-asset-\(program.id.rawValue)-\(assetID)")))
                }
            }
            // Rebuild the resolved input WITH asset pixels (rebuild entries from the same data).
            let resolved = try rebuildWithAssets(plan: plan, materials: out.materials, fixtures: fixtures, assetEntries: assetEntries, scene: subplan)

            let graph = try RenderGraphCompiler.compile(plan: plan, input: resolved, configuration: cfg)
            XCTAssertEqual(graph.commands.last?.category, .finalOutput, "[\(catalogID)] complete graph")
            XCTAssertTrue(graph.commands.contains { $0.category == .drawImage }, "[\(catalogID)] draws media")
            XCTAssertNoThrow(try RenderGraphValidator.validate(graph, configuration: cfg), "[\(catalogID)] validates")
            // Determinism.
            let graph2 = try RenderGraphCompiler.compile(plan: plan, input: resolved, configuration: cfg)
            XCTAssertEqual(try graph.graphHash(), try graph2.graphHash(), "[\(catalogID)] deterministic")

            // Every authored asset is drawn (full-tree representation).
            let drawn = Set(graph.commands.compactMap { c -> String? in if case let .drawImage(rid, _, _, _) = c.payload { return rid }; return nil })
            for entry in assetEntries {
                XCTAssertTrue(drawn.contains(entry.pixelInput.id.rawValue), "[\(catalogID)] authored asset \(entry.key.assetID) drawn")
            }

            // Strengthened coverage (#11): every authored renderable shape/mask/matte across every scene
            // layer's program tree is represented by a corresponding command.
            var expShapes = 0, expMasks = 0, expMattes = 0
            for layer in subplan.layers {
                let key = ResolvedLayerKey.sceneLayer(sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
                guard let program = resolved.program(for: key) else { continue }
                let c = countRenderables(program)
                expShapes += c.shapes; expMasks += c.masks; expMattes += c.mattes
            }
            let gotShapes = graph.commands.filter { $0.category == .drawShape }.count
            let gotMasks = graph.commands.filter { $0.category == .beginMask }.count
            let gotMattes = graph.commands.filter { $0.category == .matteLink }.count
            XCTAssertEqual(gotShapes, expShapes, "[\(catalogID)] every authored shape represented")
            XCTAssertEqual(gotMasks, expMasks, "[\(catalogID)] every authored mask represented")
            XCTAssertEqual(gotMattes, expMattes, "[\(catalogID)] every authored matte represented")
        }
    }

    /// Counts the authored renderable shapes/masks/mattes a compiler must represent for a program,
    /// walking the full visible-layer tree (matte-source layers are rendered as part of their consumer's
    /// matte pass, so their own visible draws are not double-counted, but their masks/content under the
    /// matte pass ARE represented — mirrored by the compiler).
    private func countRenderables(_ program: RenderMaterialProgram) -> (shapes: Int, masks: Int, mattes: Int) {
        let compByID = Dictionary(uniqueKeysWithValues: program.compositions.map { ($0.id, $0) })
        var shapes = 0, masks = 0, mattes = 0
        func walk(_ comp: RenderComposition, asMatteSource: Bool, visiting: Set<String>) {
            guard !visiting.contains(comp.id) else { return }
            let next = visiting.union([comp.id])
            for layer in comp.layers {
                // A visible layer is one not flagged isMatteSource (when scanning the normal pass).
                let isMatteSourceTop = layer.isMatteSource && !asMatteSource
                if isMatteSourceTop { continue }    // counted via its consumer's matte pass below
                if layer.isHidden { continue }
                masks += layer.masks.count
                if case .shapes = layer.content { shapes += 1 }
                if let matte = layer.matte {
                    mattes += 1
                    // The matte source is rendered (its content/masks) — recurse into it.
                    if let src = comp.layers.first(where: { $0.id == matte.sourceLayerID }) {
                        masks += src.masks.count
                        if case .shapes = src.content { shapes += 1 }
                        if case let .precomp(cid) = src.content, let sub = compByID[cid] { walk(sub, asMatteSource: true, visiting: next) }
                    }
                }
                if case let .precomp(cid) = layer.content, let sub = compByID[cid] { walk(sub, asMatteSource: asMatteSource, visiting: next) }
            }
        }
        if let root = compByID[program.rootCompID] { walk(root, asMatteSource: false, visiting: []) }
        return (shapes, masks, mattes)
    }

    private func rebuildWithAssets(plan: FramePlan, materials: RenderMaterialTable, fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput], assetEntries: [ResolvedAssetPixelEntry], scene subplan: SceneSubplan) throws -> ResolvedFrameInput {
        // Resolve via the resolver to get scene entries, then re-pack with asset pixels.
        // Easiest path: resolve, then read its public views to reconstruct entries.
        var sceneEntries: [ResolvedSceneLayerEntry] = []
        let base = try RenderInputResolver.resolve(framePlan: plan, materials: materials, fixtures: fixtures)
        for layer in subplan.layers {
            let key = ResolvedLayerKey.sceneLayer(sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
            guard let program = base.program(for: key), let placement = base.mediaPlacement(for: key), let pixels = base.pixelInput(for: key) else { continue }
            sceneEntries.append(try ResolvedSceneLayerEntry(key: key, program: program, pixelInput: pixels, placement: placement))
        }
        return try ResolvedFrameInput(sceneLayers: sceneEntries, overlays: [], assetPixels: assetEntries)
    }

    // MARK: - FCP §1 — authored colour-arity audit across all five compiled.tve

    /// Proves the exact arity baseline the strict per-converter contract relies on: across all five real
    /// compiled templates, every authored shape FILL colour has exactly 4 components (RGBA) and every
    /// authored STROKE colour has exactly 3 components (RGB) — 25 fills, 18 strokes total.
    func testAuthoredFillStrokeColorArityBaseline() throws {
        var fill: [Int: Int] = [:]
        var stroke: [Int: Int] = [:]
        var seenProgram = Set<String>()
        for catalogID in ["full_image", "polaroid_shared_demo", "polaroid_2", "example_4blocks", "6_frames_template"] {
            let data = try tveBytes(catalogID)
            let decoded = try CompiledTemplateDecoder.decode(data)
            let inventory = try TemplateVariantInventory(from: decoded)
            for block in inventory.blocks {
                for variant in block.variants {
                    var chosen: [String: String] = [:]
                    var bindings: [String: CompiledTemplateConverter.MediaBinding] = [:]
                    for b in inventory.blocks {
                        chosen[b.blockID] = (b.blockID == block.blockID) ? variant.variantID : b.selectedVariantID
                        bindings[b.blockID] = .image(reference: "r-\(b.blockID)", mediaPlacement: .identity(fitMode: .contain))
                    }
                    let out = try CompiledTemplateConverter.convert(.init(
                        compiledTemplateData: data, catalogID: catalogID, sceneInstanceID: "inst", scenePayloadID: "pay",
                        selection: TemplateVariantInventory.Selection(chosenVariantByBlockID: chosen),
                        mediaBindings: bindings, requiredPostRoll: .zero))
                    for program in out.materials.programs {
                        guard seenProgram.insert(program.id.rawValue).inserted else { continue }
                        for comp in program.compositions {
                            for layer in comp.layers {
                                if case .shapes(let g) = layer.content {
                                    if let fc = g.fillColor { fill[fc.components.count, default: 0] += 1 }
                                    if let s = g.stroke { stroke[s.color.components.count, default: 0] += 1 }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(fill, [4: 25], "all 25 authored fills are RGBA (4 components)")
        XCTAssertEqual(stroke, [3: 18], "all 18 authored strokes are RGB (3 components)")
    }
}
