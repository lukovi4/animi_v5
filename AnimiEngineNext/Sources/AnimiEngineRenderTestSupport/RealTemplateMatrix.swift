import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineTemplateAdapter
import AnimiEngineRenderGraph

/// Task-003 / Step-14 — deterministic enumeration of the complete real-template/frame matrix.
///
/// Enumerates every authored (catalog, block, variant) pair across the five mandatory compiled templates,
/// crossed with a deterministic frame-time set, and compiles each row to an immutable `RenderGraph`. The
/// enumeration is a pure, ordered function of the compiled templates (no wall-clock, no unordered iteration)
/// so the row list and the resulting candidate IDs are reproducible. The mandatory inventory baseline
/// (5 catalogs / 14 blocks / 25 variant pairs) is re-verified; a mismatch is a typed STOP error.
public enum RealTemplateMatrix {

    public enum MatrixError: Error, Equatable, Sendable {
        case inventoryMismatch(detail: String)          // STOP: real inventory differs from baseline
        case templateUnreadable(catalogID: String, detail: String)
        case rowCompileFailed(rowID: String, detail: String)
    }

    /// The result of compiling a row: either a renderable graph, or a deterministic SKIP because the
    /// authored layer timing makes the row's content inactive at the chosen frame time (a real authored
    /// outcome, not a failure to force). A skip is fully deterministic (same row → same skip).
    public enum CompileOutcome: Sendable {
        case renderable(CompiledRow)
        case skippedInactive(rowID: String, reason: String)
    }

    /// The five mandatory catalogs, in fixed authored order.
    public static let catalogs = ["full_image", "polaroid_shared_demo", "polaroid_2", "example_4blocks", "6_frames_template"]

    /// The expected inventory baseline (constraint 8).
    public static let expectedCatalogCount = 5
    public static let expectedBlockCount = 14
    public static let expectedVariantPairCount = 25

    /// One enumerated matrix row, before rendering.
    public struct Row: Sendable, Equatable {
        public let catalogID: String
        public let blockID: String
        public let variantID: String
        public let projectTimeTicks: Int64
        public let frameKind: String      // "tick0" | "mid" | "last" | "postRoll" (provenance only)
        /// A stable per-row identifier (catalog/block/variant/tick) used for ordering + dedup checks.
        public var rowID: String { "\(catalogID)__\(blockID)__\(variantID)__t\(projectTimeTicks)__\(frameKind)" }
    }

    /// A compiled row: its provenance plus the immutable graph and config hash to render.
    public struct CompiledRow: Sendable {
        public let row: Row
        public let graph: RenderGraph
        public let configHash: String
    }

    /// Enumerate every (catalog, block, variant, frameTime) row in deterministic order. Verifies the
    /// inventory baseline first (STOP on mismatch). `scenesRootURL` is the directory holding
    /// `<catalog>/compiled.tve` (read-only).
    public static func enumerateRows(scenesRootURL: URL) throws -> [Row] {
        var rows: [Row] = []
        var totalBlocks = 0, totalVariantPairs = 0
        for catalogID in catalogs {
            let data = try tveBytes(scenesRootURL: scenesRootURL, catalogID: catalogID)
            let inventory: TemplateVariantInventory
            do { inventory = try TemplateVariantInventory(from: try CompiledTemplateDecoder.decode(data)) }
            catch { throw MatrixError.templateUnreadable(catalogID: catalogID, detail: "\(error)") }

            // Project duration → frame-time set boundaries (deterministic).
            let document = try convert(scenesRootURL: scenesRootURL, catalogID: catalogID, selectAll: nil).document
            let durationTicks = try document.manifest.projectDuration().ticks
            let postRollTicks = document.manifest.scenes.map { $0.postRollCapability.ticks }.max() ?? 0

            for block in inventory.blocks {     // authored order
                totalBlocks += 1
                for variant in block.variants { // authored order
                    totalVariantPairs += 1
                    for (tick, kind) in frameTimes(durationTicks: durationTicks, postRollTicks: postRollTicks) {
                        rows.append(Row(catalogID: catalogID, blockID: block.blockID, variantID: variant.variantID,
                                        projectTimeTicks: tick, frameKind: kind))
                    }
                }
            }
        }
        // Inventory baseline STOP-check (constraint 8).
        guard totalBlocks == expectedBlockCount, totalVariantPairs == expectedVariantPairCount,
              catalogs.count == expectedCatalogCount else {
            throw MatrixError.inventoryMismatch(detail:
                "catalogs \(catalogs.count) blocks \(totalBlocks) variantPairs \(totalVariantPairs) != baseline 5/14/25")
        }
        return rows
    }

    /// The deterministic frame-time set (D2): tick0, mid, last-representable-instant, post-roll-if-capable.
    /// `ProjectTime` is half-open `[0, duration)`, so the last representable instant is `duration − 1`. The
    /// post-roll tick is `duration + postRoll/2` only when `postRoll > 0`.
    public static func frameTimes(durationTicks: Int64, postRollTicks: Int64) -> [(tick: Int64, kind: String)] {
        var times: [(Int64, String)] = [(0, "tick0")]
        if durationTicks > 2 { times.append((durationTicks / 2, "mid")) }
        if durationTicks >= 1 { times.append((durationTicks - 1, "last")) }
        if postRollTicks > 0 { times.append((durationTicks - 1 + max(1, postRollTicks / 2), "postRoll")) }
        // Deduplicate identical ticks while preserving first-seen kind (small durations may coincide).
        var seen = Set<Int64>(); var out: [(Int64, String)] = []
        for t in times where seen.insert(t.0).inserted { out.append(t) }
        return out
    }

    /// Compile a single row to an immutable `RenderGraph`, selecting `row.variantID` for `row.blockID` and
    /// each block's `selectedVariantID` for the others; binding deterministic media fixtures and authored
    /// asset pixels; evaluating at `row.projectTimeTicks`. Mirrors the verified real-template compile path.
    /// Convenience: compile a row, requiring it to be renderable (used where a renderable row is expected).
    public static func compile(row: Row, scenesRootURL: URL, configuration: RenderConfiguration) throws -> CompiledRow {
        switch try compileOutcome(row: row, scenesRootURL: scenesRootURL, configuration: configuration) {
        case .renderable(let cr): return cr
        case .skippedInactive(let rowID, let reason):
            throw MatrixError.rowCompileFailed(rowID: rowID, detail: "expected renderable but skipped: \(reason)")
        }
    }

    /// Compile a row, classifying an authored-timing inactivity as a deterministic SKIP (not a failure).
    public static func compileOutcome(row: Row, scenesRootURL: URL, configuration: RenderConfiguration) throws -> CompileOutcome {
        do {
            let out = try convert(scenesRootURL: scenesRootURL, catalogID: row.catalogID,
                                  selectAll: (blockID: row.blockID, variantID: row.variantID))
            let plan = try evaluate(out.document, atTick: row.projectTimeTicks)
            guard case let .single(subplan) = plan.body else {
                throw MatrixError.rowCompileFailed(rowID: row.rowID, detail: "expected single body")
            }
            // Deterministic media fixtures per scene layer.
            var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
            for (i, layer) in subplan.layers.enumerated() {
                guard case let .image(ref) = layer.content else { continue }
                fixtures[.image(reference: ref.raw)] = try fixturePixel("\(row.catalogID)-media-\(i)")
            }
            let base = try RenderInputResolver.resolve(framePlan: plan, materials: out.materials, fixtures: fixtures)
            // Authored asset pixels across the full comp tree.
            var assetEntries: [ResolvedAssetPixelEntry] = []
            var sceneEntries: [ResolvedSceneLayerEntry] = []
            for layer in subplan.layers {
                let key = ResolvedLayerKey.sceneLayer(sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
                guard let program = base.program(for: key), let placement = base.mediaPlacement(for: key),
                      let pixels = base.pixelInput(for: key) else { continue }
                sceneEntries.append(try ResolvedSceneLayerEntry(key: key, program: program, pixelInput: pixels, placement: placement))
                for assetID in authoredAssetIDs(program).sorted() {
                    assetEntries.append(ResolvedAssetPixelEntry(
                        key: ResolvedAssetKey(materialID: program.id, assetID: assetID),
                        pixelInput: try fixturePixel("\(row.catalogID)-asset-\(program.id.rawValue)-\(assetID)")))
                }
            }
            let resolved = try ResolvedFrameInput(sceneLayers: sceneEntries, overlays: [], assetPixels: assetEntries)
            let graph = try RenderGraphCompiler.compile(plan: plan, input: resolved, configuration: configuration)
            return .renderable(CompiledRow(row: row, graph: graph, configHash: try graph.graphHash()))
        } catch let e as MatrixError {
            throw e
        } catch let e as RenderGraphError {
            // Authored layer timing can make a matte source / layer inactive at a chosen frame time — a real
            // authored outcome, deterministically classified as a SKIP (not a failure to force). Any other
            // graph error is a genuine compile failure (STOP).
            if case let .unsupportedLayerMode(_, value) = e,
               value.contains("matte source is timing-inactive") || value.contains("matte source is hidden") {
                return .skippedInactive(rowID: row.rowID, reason: value)
            }
            throw MatrixError.rowCompileFailed(rowID: row.rowID, detail: "\(e)")
        } catch {
            throw MatrixError.rowCompileFailed(rowID: row.rowID, detail: "\(error)")
        }
    }

    // MARK: - Internal compile helpers (mirror the verified RealTemplate path)

    static func tveBytes(scenesRootURL: URL, catalogID: String) throws -> Data {
        let url = scenesRootURL.appendingPathComponent(catalogID).appendingPathComponent("compiled.tve")
        do { return try Data(contentsOf: url) }
        catch { throw MatrixError.templateUnreadable(catalogID: catalogID, detail: "\(error)") }
    }

    /// Convert a catalog; if `selectAll` is given, choose that variant for that block (others use their
    /// selectedVariantID), else choose every block's selectedVariantID.
    static func convert(scenesRootURL: URL, catalogID: String, selectAll: (blockID: String, variantID: String)?) throws -> CompiledTemplateConverter.Output {
        let data = try tveBytes(scenesRootURL: scenesRootURL, catalogID: catalogID)
        let inventory = try TemplateVariantInventory(from: try CompiledTemplateDecoder.decode(data))
        var chosen: [String: String] = [:]
        var bindings: [String: CompiledTemplateConverter.MediaBinding] = [:]
        for block in inventory.blocks {
            if let sel = selectAll, sel.blockID == block.blockID {
                chosen[block.blockID] = sel.variantID
            } else {
                chosen[block.blockID] = block.selectedVariantID
            }
            bindings[block.blockID] = .image(reference: "real-\(block.blockID)", mediaPlacement: .identity(fitMode: .contain))
        }
        return try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: catalogID, sceneInstanceID: "inst", scenePayloadID: "pay",
            selection: TemplateVariantInventory.Selection(chosenVariantByBlockID: chosen),
            mediaBindings: bindings, requiredPostRoll: .zero))
    }

    static func evaluate(_ document: CanonicalProjectDocument, atTick tick: Int64) throws -> FramePlan {
        let index = try TimelineIndex(manifest: document.manifest)
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: try document.manifest.projectDuration().ticks))
        let requirement = try index.requirements(for: coverage)
        let window = try EvaluationWindowBuilder.build(requirement: requirement, scenes: document.scenePayloads, overlays: document.overlayPayloads)
        // Clamp post-roll ticks back into the half-open project range for evaluation (the post-roll frame is
        // the held last instant; the evaluator is queried at the last representable in-range tick).
        let end = try document.manifest.projectDuration().ticks
        let clamped = tick >= end ? max(0, end - 1) : tick
        return try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: clamped))
    }

    static func fixturePixel(_ id: String) throws -> ResolvedPixelInput {
        try ResolvedPixelInput(id: try PixelInputID(id),
            dimensions: try PixelDimensions(width: 32, height: 32, bytesPerRow: 128, format: .bgra8, orientation: .up),
            bytes: Data(repeating: 0x80, count: 32 * 32 * 4))
    }

    static func authoredAssetIDs(_ program: RenderMaterialProgram) -> Set<String> {
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
}
