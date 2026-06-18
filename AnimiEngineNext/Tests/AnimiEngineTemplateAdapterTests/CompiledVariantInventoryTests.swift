import XCTest
import Foundation
@testable import AnimiEngineTemplateAdapter

/// Task-003 plan §17 step 6 — compiled-template **variant inventory** tests.
///
/// Each mandatory template's inventory is proven against **three independent representations**:
///   1. the `compiled.tve` inventory (decode the real package, then build the inventory);
///   2. the `SceneSources/<id>/scene.json` *source* inventory (an independent `JSONSerialization`
///      reader of the authored scene, written from scratch — it does not reuse adapter DTOs);
///   3. a checked-in **explicit golden** inventory table embedded in this test file.
///
/// The golden table is hand-written and is **never** regenerated or updated by the tests. The
/// `SceneSources/` and `AnimiApp/Resources/` trees are read-only fixtures and are never modified.
///
/// Beyond the three-way agreement, the suite proves: exact block/variant ids, exact `animRef`
/// values, exact ordering, single occurrence of every block and variant, value-identical repeated
/// construction, and the explicit-selection contract (full selections pass; missing / extra /
/// unknown selections fail with the typed errors).
final class CompiledVariantInventoryTests: XCTestCase {

    // MARK: - Checked-in explicit golden inventory table (hand-authored; never auto-generated)

    /// A plain, literal description of one block in the golden table.
    private struct GoldenBlock {
        let blockID: String
        let orderIndex: Int
        let selectedVariantID: String
        let editVariantID: String
        /// Authored variants as `(variantID, animRef)` in authored order.
        let variants: [(String, String)]
    }

    /// The hand-written golden inventories for all five mandatory templates. Authored order is the
    /// array order here; it must match both the compiled and the source representations exactly.
    private static let golden: [String: [GoldenBlock]] = [
        "full_image": [
            GoldenBlock(blockID: "block_01", orderIndex: 0, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "no-anim.json"), ("anim-1", "anim-1.json")])
        ],
        "polaroid_shared_demo": [
            GoldenBlock(blockID: "block_01", orderIndex: 0, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "no-anim.json"), ("anim-1", "anim-1.json")])
        ],
        "polaroid_2": [
            GoldenBlock(blockID: "block_01", orderIndex: 0, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_01_no_anim.json"), ("anim", "block_01_anim.json")]),
            GoldenBlock(blockID: "block_02", orderIndex: 1, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_02_no_anim.json"), ("anim", "block_02_anim.json")])
        ],
        "example_4blocks": [
            GoldenBlock(blockID: "block_01", orderIndex: 0, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_01/no-anim.json"),
                                   ("v1", "block_01/anim-1.1.json"),
                                   ("v2", "block_01/anim-1.2.json"),
                                   ("v3", "block_01/anim-1.3.json"),
                                   ("v4", "block_01/anim-1.4.json")]),
            GoldenBlock(blockID: "block_02", orderIndex: 1, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_02/no-anim.json"), ("v1", "block_02/anim-2.1.json")]),
            GoldenBlock(blockID: "block_03", orderIndex: 2, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_03/no-anim.json"), ("v1", "block_03/anim-3.1.json")]),
            GoldenBlock(blockID: "block_04", orderIndex: 3, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_04/no-anim.json"), ("v1", "block_04/anim-4.1.json")])
        ],
        "6_frames_template": [
            GoldenBlock(blockID: "block_01", orderIndex: 0, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_01/no-anim.json")]),
            GoldenBlock(blockID: "block_02", orderIndex: 1, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_02/no-anim.json")]),
            GoldenBlock(blockID: "block_03", orderIndex: 2, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_03/no-anim.json")]),
            GoldenBlock(blockID: "block_04", orderIndex: 3, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_04/no-anim.json")]),
            GoldenBlock(blockID: "block_05", orderIndex: 4, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_05/no-anim.json")]),
            GoldenBlock(blockID: "block_06", orderIndex: 5, selectedVariantID: "no-anim", editVariantID: "no-anim",
                        variants: [("no-anim", "block_06/no-anim.json")])
        ]
    ]

    /// Translates a golden table entry into a `TemplateVariantInventory` value for direct comparison.
    private func inventory(fromGolden blocks: [GoldenBlock]) -> TemplateVariantInventory {
        TemplateVariantInventory(blocks: blocks.map { g in
            TemplateVariantInventory.Block(
                blockID: g.blockID,
                orderIndex: g.orderIndex,
                selectedVariantID: g.selectedVariantID,
                editVariantID: g.editVariantID,
                variants: g.variants.map { TemplateVariantInventory.Variant(variantID: $0.0, animRef: $0.1) }
            )
        })
    }

    // MARK: - Independent SceneSources/<id>/scene.json source reader (no adapter DTOs reused)

    /// Builds an inventory purely from the authored `scene.json` source, using `JSONSerialization`
    /// directly so it shares no code with the compiled-template DTO path.
    ///
    /// Source-derived selection/edit pointers mirror the producer's documented derivation: the
    /// selected variant is the first authored scene variant, and the edit variant is `no-anim`.
    private func sourceInventory(catalogID: String) throws -> TemplateVariantInventory {
        let url = repositoryRootURL()
            .appendingPathComponent("SceneSources/\(catalogID)/scene.json")
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mediaBlocks = try XCTUnwrap(object["mediaBlocks"] as? [[String: Any]])

        var blocks: [TemplateVariantInventory.Block] = []
        for (orderIndex, block) in mediaBlocks.enumerated() {
            let blockID = try XCTUnwrap(block["blockId"] as? String)
            let rawVariants = try XCTUnwrap(block["variants"] as? [[String: Any]])
            var variants: [TemplateVariantInventory.Variant] = []
            for v in rawVariants {
                let variantID = try XCTUnwrap(v["variantId"] as? String)
                let animRef = try XCTUnwrap(v["animRef"] as? String)
                variants.append(.init(variantID: variantID, animRef: animRef))
            }
            let selected = try XCTUnwrap(variants.first).variantID  // producer: first authored variant
            blocks.append(.init(
                blockID: blockID,
                orderIndex: orderIndex,
                selectedVariantID: selected,
                editVariantID: "no-anim",
                variants: variants
            ))
        }
        return TemplateVariantInventory(blocks: blocks)
    }

    /// Builds an inventory by decoding the real `compiled.tve` package.
    private func compiledInventory(catalogID: String) throws -> TemplateVariantInventory {
        let data = try CompiledTemplateFixtureBytes.bytes(catalogID)
        let decoded = try CompiledTemplateDecoder.decode(data)
        return try TemplateVariantInventory(from: decoded)
    }

    // MARK: - Golden table covers exactly the mandatory templates

    func testGoldenKeySetEqualsMandatoryIDs() {
        XCTAssertEqual(Set(Self.golden.keys), Set(CompiledTemplateFixtureBytes.mandatoryIDs),
                       "golden table keys must be exactly the mandatory template ids")
        XCTAssertEqual(Self.golden.count, CompiledTemplateFixtureBytes.mandatoryIDs.count,
                       "golden table must have one entry per mandatory template")
    }

    // MARK: - Three-way agreement across all five mandatory templates

    func testCompiledSourceAndGoldenInventoriesAgreeForAllTemplates() throws {
        for catalogID in CompiledTemplateFixtureBytes.mandatoryIDs {
            let compiled = try compiledInventory(catalogID: catalogID)
            let source = try sourceInventory(catalogID: catalogID)
            let goldenBlocks = try XCTUnwrap(Self.golden[catalogID], "missing golden entry for \(catalogID)")
            let golden = inventory(fromGolden: goldenBlocks)

            XCTAssertEqual(compiled, golden, "compiled.tve inventory != golden for \(catalogID)")
            XCTAssertEqual(source, golden, "scene.json source inventory != golden for \(catalogID)")
            XCTAssertEqual(compiled, source, "compiled.tve inventory != scene.json source for \(catalogID)")
        }
    }

    // MARK: - Exact block/variant ids, animRef and ordering

    func testExactBlockAndVariantIdentityOrderingAndAnimRefs() throws {
        for catalogID in CompiledTemplateFixtureBytes.mandatoryIDs {
            let compiled = try compiledInventory(catalogID: catalogID)
            let goldenBlocks = try XCTUnwrap(Self.golden[catalogID])

            // Exact block ids, exact authored ordering, orderIndex == position.
            XCTAssertEqual(compiled.blocks.map(\.blockID), goldenBlocks.map(\.blockID),
                           "block id ordering mismatch for \(catalogID)")
            XCTAssertEqual(compiled.blocks.map(\.orderIndex), Array(goldenBlocks.indices),
                           "orderIndex must equal authored position for \(catalogID)")

            for (block, golden) in zip(compiled.blocks, goldenBlocks) {
                XCTAssertEqual(block.orderIndex, golden.orderIndex)
                XCTAssertEqual(block.selectedVariantID, golden.selectedVariantID)
                XCTAssertEqual(block.editVariantID, golden.editVariantID)

                // Exact variant ids in authored order.
                XCTAssertEqual(block.variants.map(\.variantID), golden.variants.map(\.0),
                               "variant id ordering mismatch for \(catalogID)/\(block.blockID)")
                // Exact animRef values in authored order.
                XCTAssertEqual(block.variants.map(\.animRef), golden.variants.map(\.1),
                               "animRef mismatch for \(catalogID)/\(block.blockID)")
            }
        }
    }

    // MARK: - Every block and every variant occurs exactly once

    func testEveryBlockAndVariantOccursExactlyOnce() throws {
        for catalogID in CompiledTemplateFixtureBytes.mandatoryIDs {
            let compiled = try compiledInventory(catalogID: catalogID)

            let blockIDs = compiled.blocks.map(\.blockID)
            XCTAssertEqual(Set(blockIDs).count, blockIDs.count, "duplicate block id in \(catalogID)")

            for block in compiled.blocks {
                let variantIDs = block.variants.map(\.variantID)
                XCTAssertEqual(Set(variantIDs).count, variantIDs.count,
                               "duplicate variant id in \(catalogID)/\(block.blockID)")
            }
        }
    }

    // MARK: - Repeated construction is value-identical (determinism)

    func testRepeatedConstructionIsValueIdentical() throws {
        for catalogID in CompiledTemplateFixtureBytes.mandatoryIDs {
            let data = try CompiledTemplateFixtureBytes.bytes(catalogID)
            let first = try TemplateVariantInventory(from: CompiledTemplateDecoder.decode(data))
            let second = try TemplateVariantInventory(from: CompiledTemplateDecoder.decode(data))
            XCTAssertEqual(first, second, "inventory construction is not deterministic for \(catalogID)")

            // Building twice from a single decoded value is also identical.
            let decoded = try CompiledTemplateDecoder.decode(data)
            XCTAssertEqual(try TemplateVariantInventory(from: decoded), try TemplateVariantInventory(from: decoded))
        }
    }

    // MARK: - Explicit-selection contract

    /// A full, valid selection: the selected variant for every block.
    private func fullSelection(for inventory: TemplateVariantInventory) -> TemplateVariantInventory.Selection {
        var map: [String: String] = [:]
        for block in inventory.blocks { map[block.blockID] = block.selectedVariantID }
        return .init(chosenVariantByBlockID: map)
    }

    func testValidFullSelectionsPass() throws {
        for catalogID in CompiledTemplateFixtureBytes.mandatoryIDs {
            let inventory = try compiledInventory(catalogID: catalogID)

            // Every block selected with its selected variant → passes.
            XCTAssertNoThrow(try inventory.validate(selection: fullSelection(for: inventory)))

            // Also valid: choosing any other authored variant per block (not just the selected one).
            var alt: [String: String] = [:]
            for block in inventory.blocks {
                alt[block.blockID] = block.variants.last!.variantID
            }
            XCTAssertNoThrow(try inventory.validate(selection: .init(chosenVariantByBlockID: alt)))
        }
    }

    func testMissingBlockSelectionFailsWithTypedError() throws {
        let inventory = try compiledInventory(catalogID: "polaroid_2")
        var map = fullSelection(for: inventory).chosenVariantByBlockID
        map.removeValue(forKey: "block_02")  // drop one required block
        XCTAssertThrowsError(try inventory.validate(selection: .init(chosenVariantByBlockID: map))) { error in
            XCTAssertEqual(error as? TemplateVariantSelectionError,
                           .missingBlockSelection(blockID: "block_02"))
        }
    }

    func testExtraUnknownBlockSelectionFailsWithTypedError() throws {
        let inventory = try compiledInventory(catalogID: "full_image")
        var map = fullSelection(for: inventory).chosenVariantByBlockID
        map["block_99"] = "no-anim"  // a block that does not exist
        XCTAssertThrowsError(try inventory.validate(selection: .init(chosenVariantByBlockID: map))) { error in
            XCTAssertEqual(error as? TemplateVariantSelectionError, .unknownBlock(blockID: "block_99"))
        }
    }

    func testUnknownVariantSelectionFailsWithTypedError() throws {
        let inventory = try compiledInventory(catalogID: "full_image")
        let map = ["block_01": "does-not-exist"]  // existing block, non-authored variant
        XCTAssertThrowsError(try inventory.validate(selection: .init(chosenVariantByBlockID: map))) { error in
            XCTAssertEqual(error as? TemplateVariantSelectionError,
                           .unknownVariant(blockID: "block_01", variantID: "does-not-exist"))
        }
    }

    func testEmptySelectionFailsAsMissingFirstBlock() throws {
        let inventory = try compiledInventory(catalogID: "6_frames_template")
        XCTAssertThrowsError(try inventory.validate(selection: .init(chosenVariantByBlockID: [:]))) { error in
            XCTAssertEqual(error as? TemplateVariantSelectionError,
                           .missingBlockSelection(blockID: "block_01"))
        }
    }

    // MARK: - Synthetic regression: authored order must NOT follow runtime zIndex order

    /// `SceneCompiler` sorts `runtime.blocks` by `(zIndex, orderIndex)`, so the runtime array order
    /// can differ from authored scene order. This builds a two-block package whose authored order is
    /// `[block_A, block_B]` (orderIndex 0, 1) but whose runtime `blocks` array is `[block_B, block_A]`
    /// (block_B has the lower zIndex). The inventory must follow **authored** order and carry the
    /// correct `orderIndex`, never the runtime array order.
    func testInventoryFollowsAuthoredOrderNotRuntimeZIndexOrder() throws {
        let object = syntheticTwoBlockPayload()
        let payload = try CompiledTemplatePayloadDTO.decode(try CompiledJSONParser.parse(
            try JSONSerialization.data(withJSONObject: object)))

        // Sanity: the runtime array really is in the swapped (zIndex-sorted) order.
        XCTAssertEqual(payload.compiled.runtime.blocks.map(\.blockID), ["block_B", "block_A"])
        // Sanity: the authored scene order is the original order.
        XCTAssertEqual(payload.compiled.runtime.scene.mediaBlocks.map(\.blockID), ["block_A", "block_B"])

        let decoded = DecodedCompiledTemplate(
            envelope: CompiledTemplateEnvelope(
                formatVersion: 1, headerLength: 18, engineHash: 0, schemaVersion: 2, payload: []),
            payload: payload
        )
        let inventory = try TemplateVariantInventory(from: decoded)

        // Authored order, not runtime zIndex order.
        XCTAssertEqual(inventory.blocks.map(\.blockID), ["block_A", "block_B"])
        XCTAssertEqual(inventory.blocks.map(\.orderIndex), [0, 1])
        XCTAssertEqual(inventory.blocks[0].variants.map(\.variantID), ["no-anim"])
        XCTAssertEqual(inventory.blocks[1].variants.map(\.variantID), ["no-anim"])
        XCTAssertEqual(inventory.blocks[0].selectedVariantID, "no-anim")
        XCTAssertEqual(inventory.blocks[0].editVariantID, "no-anim")
    }

    /// Producer-shaped two-block payload. `block_A` is authored first (orderIndex 0) but has the
    /// higher zIndex, so the compiler-sorted `runtime.blocks` array lists `block_B` first.
    private func syntheticTwoBlockPayload() -> [String: Any] {
        let rect: [String: Any] = ["x": 0, "y": 0, "width": 1080, "height": 1920]
        let canvas: [String: Any] = ["width": 1080, "height": 1920, "fps": 30, "durationFrames": 150]
        let staticVec: ([String: Any]) -> [String: Any] = { ["static": ["_0": $0]] }
        let staticScalar: (Any) -> [String: Any] = { ["static": ["_0": $0]] }
        let transform: [String: Any] = [
            "position": staticVec(["x": 540, "y": 960]),
            "scale": staticVec(["x": 100, "y": 100]),
            "rotation": staticScalar(0),
            "opacity": staticScalar(100),
            "anchor": staticVec(["x": 0, "y": 0])
        ]

        // Per-block builders. Each block owns a distinct asset so the binding-asset set is exact.
        func animIR(asset: String, comp: String) -> [String: Any] {
            let imageLayer: [String: Any] = [
                "id": 1, "name": "media", "type": 2,
                "timing": ["inPoint": 0.0, "outPoint": 150.0, "startTime": 0.0],
                "transform": transform, "masks": [],
                "content": ["image": ["assetId": asset]],
                "isMatteSource": false, "isHidden": false
            ]
            return [
                "meta": ["width": 1080.0, "height": 1920.0, "fps": 30.0,
                         "inPoint": 0.0, "outPoint": 150.0, "sourceAnimRef": "\(asset).json"],
                "rootComp": comp,
                "comps": [comp: ["id": comp, "size": ["width": 1080, "height": 1920], "layers": [imageLayer]]],
                "assets": ["byId": [asset: "i"], "sizeById": [asset: ["width": 1080.0, "height": 1920.0]],
                           "basenameById": [asset: "i"]],
                "binding": ["bindingKey": "media", "boundLayerId": 1, "boundAssetId": asset, "boundCompId": comp],
                "pathRegistry": ["paths": []]
            ]
        }
        func runtimeBlock(id: String, zIndex: Int, orderIndex: Int, asset: String, comp: String) -> [String: Any] {
            [
                "blockId": id, "zIndex": zIndex, "orderIndex": orderIndex,
                "rectCanvas": rect,
                "bindingBaseline": ["boundAssetId": asset,
                                    "contentSizeLocal": ["width": 1080.0, "height": 1920.0],
                                    "contentRectLocal": rect],
                "mediaInputGeometry": ["placementRectLocal": rect],
                "timing": ["startFrame": 0, "endFrame": 150],
                "containerClip": "none", "hitTestMode": "mask",
                "selectedVariantId": "no-anim", "editVariantId": "no-anim",
                "variants": [["variantId": "no-anim", "animRef": "\(asset).json",
                              "bindingKey": "media", "animIR": animIR(asset: asset, comp: comp)]]
            ]
        }
        func sceneBlock(id: String, zIndex: Int) -> [String: Any] {
            [
                "blockId": id, "zIndex": zIndex, "rect": rect, "containerClip": "none",
                "input": ["bindingKey": "media", "hitTest": "mask",
                          "allowedMedia": ["photo", "video", "color"],
                          "emptyPolicy": "hideWholeBlock",
                          "fitModesAllowed": ["cover", "contain", "fill"], "defaultFit": "cover",
                          "userTransformsAllowed": ["pan": true, "zoom": true, "rotate": true],
                          "audio": ["enabled": false, "gain": 1.0]],
                "variants": [["variantId": "no-anim", "animRef": "\(id == "block_A" ? "assetA" : "assetB").json",
                              "defaultDurationFrames": 150, "ifAnimationShorter": "holdLastFrame",
                              "ifAnimationLonger": "cut", "loop": false]],
                "layerToggles": []
            ]
        }

        // Authored scene order: A then B. zIndex: A=5 (higher), B=0 (lower).
        let scene: [String: Any] = [
            "schemaVersion": "0.1", "sceneId": "scene_synthetic", "canvas": canvas,
            "mediaBlocks": [sceneBlock(id: "block_A", zIndex: 5), sceneBlock(id: "block_B", zIndex: 0)]
        ]
        // Compiler-sorted runtime order by (zIndex, orderIndex): B (zIndex 0) before A (zIndex 5).
        let runtime: [String: Any] = [
            "scene": scene, "canvas": canvas,
            "blocks": [runtimeBlock(id: "block_B", zIndex: 0, orderIndex: 1, asset: "assetB", comp: "comp_B"),
                       runtimeBlock(id: "block_A", zIndex: 5, orderIndex: 0, asset: "assetA", comp: "comp_A")],
            "durationFrames": 150, "fps": 30
        ]
        let compiled: [String: Any] = [
            "runtime": runtime,
            "mergedAssetIndex": ["byId": ["assetA": "a", "assetB": "b"],
                                 "sizeById": ["assetA": ["width": 1080.0, "height": 1920.0],
                                              "assetB": ["width": 1080.0, "height": 1920.0]],
                                 "basenameById": ["assetA": "a", "assetB": "b"]],
            "pathRegistry": ["paths": []],
            "bindingAssetIds": ["assetA", "assetB"]
        ]
        return ["engineVersion": "0.1.0", "templateId": "synthetic", "templateRevision": 1, "compiled": compiled]
    }

    // MARK: - Focused typed-error: a scene block with no matching runtime block

    /// Constructs a deliberately malformed decoded value — an authored scene block whose `blockID`
    /// has **no** matching runtime block — and asserts `init(from:)` throws the typed construction
    /// error instead of falling back. The malformed value is assembled internally (the real decoder
    /// would reject it via the bijection check, so it cannot arise from `decode`).
    func testMissingRuntimeBlockThrowsTypedConstructionError() throws {
        let object = syntheticTwoBlockPayload()
        let payload = try CompiledTemplatePayloadDTO.decode(try CompiledJSONParser.parse(
            try JSONSerialization.data(withJSONObject: object)))
        let runtime = payload.compiled.runtime

        // Drop block_B from the runtime blocks while keeping it in the authored scene → no match.
        let malformedRuntime = CompiledRuntimeDTO(
            scene: runtime.scene,
            canvas: runtime.canvas,
            blocks: runtime.blocks.filter { $0.blockID != "block_B" },
            durationFrames: runtime.durationFrames,
            fps: runtime.fps
        )
        let malformedPackage = CompiledRuntimePackageDTO(
            runtime: malformedRuntime,
            mergedAssetIndex: payload.compiled.mergedAssetIndex,
            pathRegistry: payload.compiled.pathRegistry,
            bindingAssetIDs: payload.compiled.bindingAssetIDs
        )
        let malformedPayload = CompiledTemplatePayloadDTO(
            engineVersion: payload.engineVersion,
            templateID: payload.templateID,
            templateRevision: payload.templateRevision,
            compiled: malformedPackage
        )
        let decoded = DecodedCompiledTemplate(
            envelope: CompiledTemplateEnvelope(
                formatVersion: 1, headerLength: 18, engineHash: 0, schemaVersion: 2, payload: []),
            payload: malformedPayload
        )

        XCTAssertThrowsError(try TemplateVariantInventory(from: decoded)) { error in
            XCTAssertEqual(error as? TemplateInventoryConstructionError,
                           .missingRuntimeBlock(blockID: "block_B"))
        }
    }

    // MARK: - Repository-root resolution (test-only #file convention)

    /// `#file` = `<repo>/AnimiEngineNext/Tests/AnimiEngineTemplateAdapterTests/CompiledVariantInventoryTests.swift`
    /// → four `deleteLastPathComponent` calls reach `<repo>`.
    private func repositoryRootURL() -> URL {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }
}
