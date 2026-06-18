import XCTest
import Foundation
@testable import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineTemplateAdapter
@testable import AnimiEngineRenderGraph

/// Task-003 plan §2 D3-01, §12 + step-8 corrective issue #9 — real-template integration: decode a real
/// compiled `.tve`, convert it (with an explicit per-block fit selection), evaluate a `FramePlan`, and
/// resolve a complete `ResolvedFrameInput`. This exercises the corrected end-to-end path on real data:
/// the authored `MediaPlacement` threads through the project model and codec, the converter validates
/// the fit against `fitModesAllowed`, and the resolver retains the selected programs and computes the
/// final transforms/clips. The real `.tve` packages are **read-only** inputs.
final class RealTemplateInputResolutionTests: XCTestCase {

    /// `#file` = `<repo>/AnimiEngineNext/Tests/AnimiEngineRenderGraphTests/<this>.swift`
    /// → four `deleteLastPathComponent` calls reach `<repo>`.
    private func tveBytes(_ catalogID: String) throws -> Data {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url.appendPathComponent("AnimiApp/Resources/Scenes/\(catalogID)/compiled.tve")
        return try Data(contentsOf: url)
    }

    /// Builds a whole-project evaluation window and evaluates a frame at a tick.
    private func evaluate(_ document: CanonicalProjectDocument, atTick tick: Int64) throws -> FramePlan {
        let index = try TimelineIndex(manifest: document.manifest)
        let projectDuration = try document.manifest.projectDuration()
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: projectDuration.ticks))
        let requirement = try index.requirements(for: coverage)
        let window = try EvaluationWindowBuilder.build(
            requirement: requirement, scenes: document.scenePayloads, overlays: document.overlayPayloads)
        return try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: tick))
    }

    /// Converts a real template binding every block with an explicit `.contain` media placement, using
    /// only the public adapter API (inventory + converter).
    private func convertContain(_ catalogID: String) throws -> CompiledTemplateConverter.Output {
        let data = try tveBytes(catalogID)
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        var chosen: [String: String] = [:]
        var bindings: [String: CompiledTemplateConverter.MediaBinding] = [:]
        for block in inventory.blocks {
            chosen[block.blockID] = block.selectedVariantID
            bindings[block.blockID] = .image(
                reference: "real-\(block.blockID)", mediaPlacement: .identity(fitMode: .contain))
        }
        let selection = TemplateVariantInventory.Selection(chosenVariantByBlockID: chosen)
        return try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: catalogID, sceneInstanceID: "inst", scenePayloadID: "pay",
            selection: selection, mediaBindings: bindings, requiredPostRoll: .zero))
    }

    private func fixturePixels(_ id: String, w: Int, h: Int) throws -> ResolvedPixelInput {
        let dims = try PixelDimensions(width: w, height: h, bytesPerRow: w * 4, format: .bgra8, orientation: .up)
        return try ResolvedPixelInput(id: try PixelInputID(id), dimensions: dims,
                                      bytes: Data(repeating: 0x80, count: w * h * 4))
    }

    /// End-to-end resolution for every mandatory real template that produces image scene layers at t=0.
    func testRealTemplatesEndToEndResolution() throws {
        for catalogID in ["full_image", "polaroid_shared_demo", "polaroid_2", "example_4blocks", "6_frames_template"] {
            let out = try convertContain(catalogID)
            let plan = try evaluate(out.document, atTick: 0)
            guard case let .single(subplan) = plan.body else {
                XCTFail("[\(catalogID)] expected a single scene at t=0"); continue
            }
            XCTAssertFalse(subplan.layers.isEmpty, "[\(catalogID)] expected at least one scene layer")

            // Fixtures for exactly the image references the plan consumes (real templates bind images).
            var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
            var imageLayerCount = 0
            for (i, layer) in subplan.layers.enumerated() {
                guard case let .image(ref) = layer.content else { continue }
                imageLayerCount += 1
                fixtures[.image(reference: ref.raw)] = try fixturePixels("\(catalogID)-px\(i)", w: 64, h: 64)
            }
            // All mandatory templates bind images in this configuration.
            XCTAssertEqual(imageLayerCount, subplan.layers.count, "[\(catalogID)] all scene layers are images here")

            let resolved = try RenderInputResolver.resolve(
                framePlan: plan, materials: out.materials, fixtures: fixtures)

            XCTAssertEqual(resolved.bindingCount, imageLayerCount, "[\(catalogID)] every layer bound")
            XCTAssertEqual(resolved.mediaPlacementCount, imageLayerCount, "[\(catalogID)] every placement computed")
            XCTAssertEqual(resolved.programCount, subplan.layers.count, "[\(catalogID)] selected programs retained")

            for layer in subplan.layers {
                let key = ResolvedLayerKey.sceneLayer(sceneID: subplan.sceneID, role: .sole, layerID: layer.layerID)
                XCTAssertNotNil(resolved.program(for: key), "[\(catalogID)] program retained for \(layer.layerID.raw)")
                XCTAssertNotNil(resolved.mediaPlacement(for: key), "[\(catalogID)] placement for \(layer.layerID.raw)")
                XCTAssertNotNil(resolved.pixelInput(for: key), "[\(catalogID)] pixels for \(layer.layerID.raw)")
                // The fit transform must be non-degenerate (positive linear part on both axes).
                let t = try XCTUnwrap(resolved.mediaPlacement(for: key)).transform
                XCTAssertGreaterThan(t.a, 0, "[\(catalogID)] non-degenerate scaleX")
                XCTAssertGreaterThan(t.d, 0, "[\(catalogID)] non-degenerate scaleY")
            }
            XCTAssertFalse(try resolved.contentHash().isEmpty)
        }
    }

    /// Determinism across the whole real-template path: identical conversion + resolution → identical
    /// frame-input content hash.
    func testRealTemplateResolutionIsDeterministic() throws {
        func run() throws -> String {
            let out = try convertContain("example_4blocks")
            let plan = try evaluate(out.document, atTick: 0)
            guard case let .single(subplan) = plan.body else { return "no-single" }
            var fixtures: [RenderInputResolver.FixtureKey: ResolvedPixelInput] = [:]
            for (i, layer) in subplan.layers.enumerated() {
                guard case let .image(ref) = layer.content else { continue }
                fixtures[.image(reference: ref.raw)] = try fixturePixels("d-px\(i)", w: 48, h: 48)
            }
            return try RenderInputResolver.resolve(
                framePlan: plan, materials: out.materials, fixtures: fixtures).contentHash()
        }
        XCTAssertEqual(try run(), try run())
    }
}
