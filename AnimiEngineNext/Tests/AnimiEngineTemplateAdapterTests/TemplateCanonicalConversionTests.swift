import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineTemplateAdapter

/// Task-003 plan §17 step 7 — compiled-template → canonical conversion tests (Stage-6 corrected).
///
/// Positive matrix (item 7): every authored variant of all five real templates is converted with a
/// complete explicit selection, explicit per-block media bindings, and an explicit post-roll; each
/// preserves its complete AnimIR features, validates, round-trips byte-stably, and is deterministic.
///
/// Negative suite (item 8): converter rejects incomplete/unknown/extra selections with the typed
/// selection error; missing/unknown bindings; invalid policy; non-finite values; fixed-point/rational
/// overflow; missing sceneID; material identity collision; insufficient post-roll.
final class TemplateCanonicalConversionTests: XCTestCase {

    // MARK: - Positive matrix over all authored variants of all five templates

    func testConvertEveryAuthoredVariantOfAllTemplates() throws {
        var totalConversions = 0
        for catalogID in CompiledTemplateFixtureBytes.mandatoryIDs {
            let data = try CompiledTemplateFixtureBytes.bytes(catalogID)
            let decoded = try CompiledTemplateDecoder.decode(data)
            let inventory = try TemplateVariantInventory(from: decoded)

            for targetBlock in inventory.blocks {
                for variant in targetBlock.variants {
                    let selection = Self.selection(inventory: inventory,
                                                   overrideBlockID: targetBlock.blockID, variantID: variant.variantID)
                    let bindings = try Self.deterministicBindings(decoded: decoded)
                    let request = CompiledTemplateConverter.Request(
                        compiledTemplateData: data, catalogID: catalogID,
                        sceneInstanceID: "inst_\(catalogID)", scenePayloadID: "payload_\(catalogID)",
                        selection: selection, mediaBindings: bindings, requiredPostRoll: .zero)

                    let output = try CompiledTemplateConverter.convert(request)
                    totalConversions += 1

                    // Structural: authored block order preserved; selected animation matches.
                    let layers = output.document.scenePayloads[0].layers
                    XCTAssertEqual(layers.map(\.id.raw), inventory.blocks.map(\.blockID))
                    let layer = try XCTUnwrap(layers.first { $0.id.raw == targetBlock.blockID })
                    XCTAssertEqual(layer.animation?.variantID, variant.variantID)
                    XCTAssertEqual(layer.animation?.animationRef, variant.animRef)

                    // Complete AnimIR program present for every block (item 2).
                    XCTAssertEqual(output.materials.programCount, inventory.blocks.count)
                    let materialID = try RenderMaterialID(
                        compiledTemplateHash: output.compiledTemplateHash,
                        blockID: targetBlock.blockID, variantID: variant.variantID)
                    let program = try XCTUnwrap(output.materials.program(materialID))
                    try Self.assertCompleteAnimIR(program, decoded: decoded,
                                                  blockID: targetBlock.blockID, variantID: variant.variantID)
                    // FramePlan-style lookup resolves the same program from sceneID + layerID (item 4).
                    let viaScene = output.materials.program(for: SceneMaterialBindingKey(
                        sceneID: try SceneInstanceID("inst_\(catalogID)"), layerID: try LayerID(targetBlock.blockID)))
                    XCTAssertEqual(viaScene?.id, program.id)

                    // Validation, round-trip, determinism.
                    XCTAssertNoThrow(try ProjectValidator.validate(output.document))
                    let bytes1 = try CanonicalProjectEncoding.encode(output.document)
                    let redecoded = try CanonicalProjectEncoding.decodeValidated(bytes1)
                    let bytes2 = try CanonicalProjectEncoding.encode(redecoded)
                    XCTAssertEqual(bytes1, bytes2)
                    XCTAssertEqual(output.document, redecoded)

                    let again = try CompiledTemplateConverter.convert(request)
                    XCTAssertEqual(again.compiledTemplateHash, output.compiledTemplateHash)
                    XCTAssertEqual(again.projectHash, output.projectHash)
                    XCTAssertEqual(again.materialHash, output.materialHash)
                    XCTAssertEqual(again.materials, output.materials)
                    XCTAssertEqual(output.compiledTemplateHash.count, 64)
                    XCTAssertEqual(output.projectHash.count, 64)
                    XCTAssertEqual(output.materialHash.count, 64)
                }
            }
        }
        XCTAssertEqual(totalConversions, 25, "all five templates contribute 25 authored variants")
    }

    /// Asserts the program carries the complete selected AnimIR (compositions/layers in order, asset
    /// index, binding, input geometry, toggle state) matching the decoded DTO.
    private static func assertCompleteAnimIR(
        _ program: RenderMaterialProgram, decoded: DecodedCompiledTemplate, blockID: String, variantID: String
    ) throws {
        let runtimeBlock = try XCTUnwrap(decoded.payload.compiled.runtime.blocks.first { $0.blockID == blockID })
        let variant = try XCTUnwrap(runtimeBlock.variants.first { $0.variantID == variantID })
        let animIR = variant.animIR

        // boundAssetID comes from the AnimIR binding (item 3).
        XCTAssertEqual(program.boundAssetID, animIR.binding.boundAssetID)
        XCTAssertEqual(program.binding.boundAssetID, animIR.binding.boundAssetID)
        XCTAssertEqual(program.binding.boundLayerID, animIR.binding.boundLayerID)
        XCTAssertEqual(program.rootCompID, animIR.rootCompID)

        // Compositions and their layers preserved in order, with deep per-layer field comparisons.
        XCTAssertEqual(program.compositions.map(\.id), animIR.comps.map(\.id))
        for (rc, dc) in zip(program.compositions, animIR.comps) {
            XCTAssertEqual(rc.layers.map(\.id), dc.layers.map(\.id), "layer order preserved")
            XCTAssertEqual(rc.width.rawValue, try FixedPointConversion.canvasScalar(points: dc.size.width, field: "w").rawValue)
            for (rl, dl) in zip(rc.layers, dc.layers) {
                XCTAssertEqual(rl.type, dl.type.rawValue)
                XCTAssertEqual(rl.name, dl.name)
                XCTAssertEqual(rl.parentLayerID, dl.parentLayerID)
                XCTAssertEqual(rl.isMatteSource, dl.isMatteSource)
                XCTAssertEqual(rl.isHidden, dl.isHidden)
                XCTAssertEqual(rl.toggleID, dl.toggleID, "toggle state preserved")
                // Matte deep.
                XCTAssertEqual(rl.matte?.mode, dl.matte?.mode.rawValue, "matte mode preserved")
                XCTAssertEqual(rl.matte?.sourceLayerID, dl.matte?.sourceLayerID, "matte source preserved")
                // Layer timing exact-rational deep.
                XCTAssertEqual(rl.timing.inPoint, try FixedPointConversion.exactRational(dl.timing.inPoint, field: "t"))
                XCTAssertEqual(rl.timing.outPoint, try FixedPointConversion.exactRational(dl.timing.outPoint, field: "t"))
                // Transform rotation deep (static cases in the fixtures).
                try Self.assertRotationTrack(rl.transform.rotation, dl.transform.rotation)
                // Masks deep: mode/inverted/pathID and path vertex counts.
                XCTAssertEqual(rl.masks.count, dl.masks.count, "mask count preserved")
                for (rm, dm) in zip(rl.masks, dl.masks) {
                    XCTAssertEqual(rm.mode, dm.mode.rawValue)
                    XCTAssertEqual(rm.inverted, dm.inverted)
                    XCTAssertEqual(rm.pathID, dm.pathID)
                    try Self.assertPathVertexCounts(rm.path, dm.path)
                }
            }
        }
        // Asset index preserved (every asset id present).
        XCTAssertEqual(Set(program.assets.map(\.id)), Set(animIR.assets.byID.keys))
        // Input geometry preserved (present iff authored).
        XCTAssertEqual(program.inputGeometry != nil, animIR.inputGeometry != nil)

        // Path resources: exactly the selected AnimIR's referenced ids, sorted, each once (item 1).
        var referenced = Set<Int>()
        for (id, _) in animIR.referencedPathIDs() { referenced.insert(id) }
        XCTAssertEqual(program.pathResources.map(\.pathID), referenced.sorted(),
                       "program path resources must be exactly the selected refs, sorted")
    }

    private static func assertRotationTrack(_ render: RenderRotationTrack, _ dto: CompiledScalarTrackDTO) throws {
        switch (render, dto) {
        case (.static(let r), .static(let d)):
            XCTAssertEqual(r.rawValue, try FixedPointConversion.rotationScalar(degrees: d, field: "r").rawValue)
        case (.keyframed(let rks), .keyframed(let dks)):
            XCTAssertEqual(rks.count, dks.count)
        default:
            XCTFail("rotation track shape mismatch")
        }
    }

    private static func assertPathVertexCounts(_ render: RenderAnimatedPath, _ dto: CompiledAnimatedPathDTO) throws {
        switch (render, dto) {
        case (.static(let rb), .static(let db)):
            XCTAssertEqual(rb.vertices.count, db.vertices.count)
            XCTAssertEqual(rb.inTangents.count, db.inTangents.count)
            XCTAssertEqual(rb.outTangents.count, db.outTangents.count)
            XCTAssertEqual(rb.closed, db.closed)
        case (.keyframed(let rks), .keyframed(let dks)):
            XCTAssertEqual(rks.count, dks.count)
        default:
            XCTFail("path track shape mismatch")
        }
    }

    // MARK: - Path registry preservation (item 1)

    func testSelectedProgramPathResourcesMatchSourceRegistry() throws {
        // Source scene-level registry sizes are 4, 6, 8, 21, 12 (fixtures). Every selected program's
        // referenced resources must resolve in that registry, each exactly once, sorted.
        let expectedRegistrySize: [String: Int] = [
            "full_image": 4, "polaroid_shared_demo": 6, "polaroid_2": 8, "example_4blocks": 21, "6_frames_template": 12
        ]
        for catalogID in CompiledTemplateFixtureBytes.mandatoryIDs {
            let data = try CompiledTemplateFixtureBytes.bytes(catalogID)
            let decoded = try CompiledTemplateDecoder.decode(data)
            let registryIDs = Set(decoded.payload.compiled.pathRegistry.paths.map(\.pathID))
            XCTAssertEqual(registryIDs.count, expectedRegistrySize[catalogID], "registry size for \(catalogID)")

            let inventory = try TemplateVariantInventory(from: decoded)
            for block in inventory.blocks {
                for variant in block.variants {
                    let out = try CompiledTemplateConverter.convert(.init(
                        compiledTemplateData: data, catalogID: catalogID, sceneInstanceID: "i", scenePayloadID: "p",
                        selection: Self.selection(inventory: inventory, overrideBlockID: block.blockID, variantID: variant.variantID),
                        mediaBindings: try Self.deterministicBindings(decoded: decoded), requiredPostRoll: .zero))
                    let program = try XCTUnwrap(out.materials.programs.first { $0.blockID == block.blockID })
                    let ids = program.pathResources.map(\.pathID)
                    // Sorted, unique, and every id resolves in the source registry.
                    XCTAssertEqual(ids, ids.sorted())
                    XCTAssertEqual(Set(ids).count, ids.count)
                    for id in ids { XCTAssertTrue(registryIDs.contains(id), "\(catalogID) pathID \(id) not in registry") }
                }
            }
        }
    }

    func testPathRegistryMutationChangesMaterialHash() throws {
        // Two synthetic templates differing only in a path-resource vertex position → material hash differs.
        let dataA = try Self.syntheticData(pathVertexX: 10)
        let dataB = try Self.syntheticData(pathVertexX: 11)
        func materialHash(_ data: Data) throws -> String {
            let decoded = try CompiledTemplateDecoder.decode(data)
            let inventory = try TemplateVariantInventory(from: decoded)
            return try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: data, catalogID: "synthetic", sceneInstanceID: "i", scenePayloadID: "p",
                selection: Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim"),
                mediaBindings: try Self.deterministicBindings(decoded: decoded), requiredPostRoll: .zero)).materialHash
        }
        XCTAssertNotEqual(try materialHash(dataA), try materialHash(dataB))
    }

    // MARK: - Scale / opacity / time semantics on a real fixture (item 2)

    func testRealFixtureScaleAndOpacityBecomeExactlyOne() throws {
        // 6_frames_template layers use static scale 100% and opacity 100 → exactly 1.0 in both types.
        let data = try CompiledTemplateFixtureBytes.bytes("6_frames_template")
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let out = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "6_frames_template", sceneInstanceID: "i", scenePayloadID: "p",
            selection: Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim"),
            mediaBindings: try Self.deterministicBindings(decoded: decoded), requiredPostRoll: .zero))
        var sawScale = false, sawOpacity = false
        for program in out.materials.programs {
            for comp in program.compositions {
                for layer in comp.layers {
                    if case .static(let s) = layer.transform.scale {
                        XCTAssertEqual(s.x.rawValue, ScaleScalar.unitsPerUnit, "100% scale → exactly 1,000,000")
                        XCTAssertEqual(s.y.rawValue, ScaleScalar.unitsPerUnit)
                        sawScale = true
                    }
                    if case .static(let o) = layer.transform.opacity {
                        XCTAssertEqual(o.rawValue, OpacityScalar.unitsPerUnit, "100 opacity → exactly 1.0")
                        sawOpacity = true
                    }
                }
            }
        }
        XCTAssertTrue(sawScale, "expected at least one static 100% scale")
        XCTAssertTrue(sawOpacity, "expected at least one static 100 opacity")
    }

    func testRealFixtureKeyframeTangentsAreEasingUnits() throws {
        // full_image variant anim-1 has keyframed transform tracks with tangents 0.833 / 0.167.
        // In EasingScalar (1e6/unit) these become ~833000 / 167000 — NOT canvas units (0.833 * 65536).
        let data = try CompiledTemplateFixtureBytes.bytes("full_image")
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let out = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "full_image", sceneInstanceID: "i", scenePayloadID: "p",
            selection: Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "anim-1"),
            mediaBindings: try Self.deterministicBindings(decoded: decoded), requiredPostRoll: .zero))
        let program = try XCTUnwrap(out.materials.programs.first { $0.variantID == "anim-1" })

        var sawTangent = false
        for comp in program.compositions {
            for layer in comp.layers {
                if case .keyframed(let kfs) = layer.transform.scale {
                    for kf in kfs {
                        if let inT = kf.inTangent {
                            // 0.833 → 833000 in easing units; canvas units would be ~54591 (0.833*65536).
                            XCTAssertEqual(inT.x.rawValue, 833_000)
                            XCTAssertNotEqual(inT.x.rawValue, Int64((0.833 * 65_536).rounded()))
                            sawTangent = true
                        }
                        if let outT = kf.outTangent {
                            XCTAssertEqual(outT.x.rawValue, 167_000)
                        }
                    }
                }
            }
        }
        XCTAssertTrue(sawTangent, "expected at least one keyframe with an easing tangent")
    }

    func testRealFixtureMetaTimesAreExactRational() throws {
        let data = try CompiledTemplateFixtureBytes.bytes("full_image")
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let out = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "full_image", sceneInstanceID: "i", scenePayloadID: "p",
            selection: Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim"),
            mediaBindings: try Self.deterministicBindings(decoded: decoded), requiredPostRoll: .zero))
        let meta = try XCTUnwrap(out.materials.programs.first).meta
        // fps 30 → exactly 30/1; inPoint 0 → 0; whole values stay clean rationals.
        XCTAssertEqual(meta.fps, try RationalSourceTime(numerator: 30, denominator: 1))
        XCTAssertEqual(meta.inPoint, .zero)
    }

    // MARK: - Pinned canonical-byte / hash golden for a complex real variant (item 7)

    func testComplexRealVariantGoldenHash() throws {
        // example_4blocks block_01 variant v1 is the most complex real selected variant.
        let data = try CompiledTemplateFixtureBytes.bytes("example_4blocks")
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let out = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "example_4blocks", sceneInstanceID: "inst", scenePayloadID: "pay",
            selection: Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "v1"),
            mediaBindings: try Self.deterministicBindings(decoded: decoded), requiredPostRoll: .zero))
        // Pin the material hash so any accidental change to the program's field set/encoding is caught.
        XCTAssertEqual(out.materialHash, "55b754c0e4e692c298b605a40260b5a48a1fa23a8952638ae3d069f7df33115b")
    }

    // MARK: - Hash separation (item 7)

    func testChangingMediaReferenceOrTrimChangesProjectHashOnly() throws {
        let catalogID = "full_image"
        let data = try CompiledTemplateFixtureBytes.bytes(catalogID)
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let selection = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")

        func out(media: String, trimEnd: Int64) throws -> CompiledTemplateConverter.Output {
            let bindings: [String: CompiledTemplateConverter.MediaBinding] = [
                "block_01": .video(mediaReference: media, trimStartTicks: 0, trimEndTicks: trimEnd, nativeTimescale: 30_000, mediaPlacement: .identity(fitMode: .contain))
            ]
            return try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: data, catalogID: catalogID, sceneInstanceID: "i", scenePayloadID: "p",
                selection: selection, mediaBindings: bindings, requiredPostRoll: .zero))
        }
        let base = try out(media: "mediaA", trimEnd: 1_200_000)
        let changedMedia = try out(media: "mediaB", trimEnd: 1_200_000)
        let changedTrim = try out(media: "mediaA", trimEnd: 2_400_000)

        // projectHash reflects media/trim changes…
        XCTAssertNotEqual(base.projectHash, changedMedia.projectHash)
        XCTAssertNotEqual(base.projectHash, changedTrim.projectHash)
        // …compiledTemplateHash does NOT (same bytes).
        XCTAssertEqual(base.compiledTemplateHash, changedMedia.compiledTemplateHash)
        XCTAssertEqual(base.compiledTemplateHash, changedTrim.compiledTemplateHash)
        // …materialHash does NOT (media/trim are not part of the AnimIR program).
        XCTAssertEqual(base.materialHash, changedMedia.materialHash)
        XCTAssertEqual(base.materialHash, changedTrim.materialHash)
    }

    func testChangingTrackOrMaskOrPathChangesMaterialHash() throws {
        // Two synthetic templates differing only in a transform track value → different materialHash.
        let dataA = try Self.syntheticData(positionX: 540)
        let dataB = try Self.syntheticData(positionX: 541)
        func materialHash(_ data: Data) throws -> String {
            let decoded = try CompiledTemplateDecoder.decode(data)
            let inventory = try TemplateVariantInventory(from: decoded)
            let out = try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: data, catalogID: "synthetic", sceneInstanceID: "i", scenePayloadID: "p",
                selection: Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim"),
                mediaBindings: try Self.deterministicBindings(decoded: decoded), requiredPostRoll: .zero))
            return out.materialHash
        }
        XCTAssertNotEqual(try materialHash(dataA), try materialHash(dataB))
    }

    func testCompiledTemplateHashIndependentOfSelectionMediaAndInstanceIDs() throws {
        let catalogID = "polaroid_2"  // two blocks, two variants each
        let data = try CompiledTemplateFixtureBytes.bytes(catalogID)
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)

        let selA = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")
        let selB = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "anim")
        let bindings = try Self.deterministicBindings(decoded: decoded)

        let outA = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: catalogID, sceneInstanceID: "i1", scenePayloadID: "p1",
            selection: selA, mediaBindings: bindings, requiredPostRoll: .zero))
        let outB = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: catalogID, sceneInstanceID: "i2", scenePayloadID: "p2",
            selection: selB, mediaBindings: bindings, requiredPostRoll: .zero))
        // Different selection + different instance ids, but identical compiled bytes:
        XCTAssertEqual(outA.compiledTemplateHash, outB.compiledTemplateHash)
        // Sanity: selection genuinely differs (project/material hashes differ).
        XCTAssertNotEqual(outA.projectHash, outB.projectHash)
        XCTAssertNotEqual(outA.materialHash, outB.materialHash)
    }

    // MARK: - Selection validation by the converter itself (item 1, item 7)

    func testConverterRejectsMissingSelection() throws {
        let data = try CompiledTemplateFixtureBytes.bytes("polaroid_2")
        let decoded = try CompiledTemplateDecoder.decode(data)
        var map = try Self.fullSelectionMap(decoded: decoded)
        map.removeValue(forKey: "block_02")
        try Self.assertSelectionError(data: data, selection: .init(chosenVariantByBlockID: map),
                                      expected: .missingBlockSelection(blockID: "block_02"))
    }

    func testConverterRejectsUnknownBlockSelection() throws {
        let data = try CompiledTemplateFixtureBytes.bytes("full_image")
        let decoded = try CompiledTemplateDecoder.decode(data)
        var map = try Self.fullSelectionMap(decoded: decoded)
        map["block_77"] = "no-anim"
        try Self.assertSelectionError(data: data, selection: .init(chosenVariantByBlockID: map),
                                      expected: .unknownBlock(blockID: "block_77"))
    }

    func testConverterRejectsUnknownVariantSelection() throws {
        let data = try CompiledTemplateFixtureBytes.bytes("full_image")
        try Self.assertSelectionError(data: data,
                                      selection: .init(chosenVariantByBlockID: ["block_01": "ghost"]),
                                      expected: .unknownVariant(blockID: "block_01", variantID: "ghost"))
    }

    private static func assertSelectionError(
        data: Data, selection: TemplateVariantInventory.Selection, expected: TemplateVariantSelectionError
    ) throws {
        let decoded = try CompiledTemplateDecoder.decode(data)
        let bindings = try Self.deterministicBindings(decoded: decoded)
        XCTAssertThrowsError(try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "c", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: bindings, requiredPostRoll: .zero))) {
            XCTAssertEqual($0 as? TemplateVariantSelectionError, expected,
                           "converter must surface the typed selection error, not a binding/runtime error")
        }
    }

    // MARK: - Binding negatives (item 8)

    func testMissingBlockBindingFails() throws {
        let data = try CompiledTemplateFixtureBytes.bytes("full_image")
        let decoded = try CompiledTemplateDecoder.decode(data)
        let selection: TemplateVariantInventory.Selection = .init(chosenVariantByBlockID: ["block_01": "no-anim"])
        XCTAssertThrowsError(try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "c", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: [:], requiredPostRoll: .zero))) {
            XCTAssertEqual($0 as? TemplateConversionError, .missingBlockBinding(blockID: "block_01"))
        }
        _ = decoded
    }

    func testUnknownBlockBindingFails() throws {
        let data = try CompiledTemplateFixtureBytes.bytes("full_image")
        let decoded = try CompiledTemplateDecoder.decode(data)
        var bindings = try Self.deterministicBindings(decoded: decoded)
        bindings["block_99"] = .image(reference: "img", mediaPlacement: .identity(fitMode: .contain))
        let selection: TemplateVariantInventory.Selection = .init(chosenVariantByBlockID: ["block_01": "no-anim"])
        XCTAssertThrowsError(try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "c", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: bindings, requiredPostRoll: .zero))) {
            XCTAssertEqual($0 as? TemplateConversionError, .unknownBlockBinding(blockID: "block_99"))
        }
    }

    func testValidImageAndVideoBindingsBothConvert() throws {
        let data = try CompiledTemplateFixtureBytes.bytes("full_image")
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let selection = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")

        let image: [String: CompiledTemplateConverter.MediaBinding] = ["block_01": .image(reference: "pic", mediaPlacement: .identity(fitMode: .contain))]
        let imageOut = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "c", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: image, requiredPostRoll: .zero))
        if case .image = imageOut.document.scenePayloads[0].layers[0].content {} else {
            XCTFail("expected image content")
        }
        XCTAssertNoThrow(try ProjectValidator.validate(imageOut.document))

        let video: [String: CompiledTemplateConverter.MediaBinding] = [
            "block_01": .video(mediaReference: "clip", trimStartTicks: 0, trimEndTicks: 1_200_000, nativeTimescale: 30_000, mediaPlacement: .identity(fitMode: .contain))]
        let videoOut = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "c", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: video, requiredPostRoll: .zero))
        if case .video = videoOut.document.scenePayloads[0].layers[0].content {} else {
            XCTFail("expected video content")
        }
        XCTAssertNoThrow(try ProjectValidator.validate(videoOut.document))
    }

    // MARK: - Policy / numeric / sceneID negatives (item 8)

    func testInvalidLongerPolicyRejected() throws {
        let data = try Self.syntheticData(ifShorter: "holdLastFrame", ifLonger: "loop")
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let selection = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")
        XCTAssertThrowsError(try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "synthetic", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: try Self.deterministicBindings(decoded: decoded),
            requiredPostRoll: .zero))) {
            XCTAssertEqual($0 as? CompiledAnimationConverter.ConversionError,
                           .unsupportedLongerPolicy(blockID: "block_01", variantID: "no-anim", policy: "loop"))
        }
    }

    func testNonFiniteValueRejectedAtConversionBoundary() {
        XCTAssertThrowsError(try FixedPointConversion.canvasScalar(points: .nan, field: "rect.x")) {
            XCTAssertEqual($0 as? TemplateNumericConversionError, .notANumber(field: "rect.x"))
        }
    }

    func testFixedPointOverflowRejectedInRectConversion() throws {
        let data = try Self.syntheticData(rectX: 1.0e30)
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let selection = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")
        XCTAssertThrowsError(try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "synthetic", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: try Self.deterministicBindings(decoded: decoded),
            requiredPostRoll: .zero))) { error in
            guard case TemplateNumericConversionError.fixedPointOverflow? = error as? TemplateNumericConversionError else {
                return XCTFail("expected fixedPointOverflow, got \(error)")
            }
        }
    }

    func testRationalNarrowingRejectsOverflow() throws {
        XCTAssertThrowsError(try RationalSourceTime(numerator: Int64.min, denominator: 1).multiplied(
            by: try RationalSourceTime(numerator: Int64.max, denominator: 1))) {
            XCTAssertEqual($0 as? TimeError, .rationalDoesNotFit)
        }
    }

    func testInvalidVideoTrimRejected() throws {
        let data = try CompiledTemplateFixtureBytes.bytes("full_image")
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let selection = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")
        let bindings: [String: CompiledTemplateConverter.MediaBinding] = [
            "block_01": .video(mediaReference: "m", trimStartTicks: 100, trimEndTicks: 100, nativeTimescale: 30_000, mediaPlacement: .identity(fitMode: .contain))]
        XCTAssertThrowsError(try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "c", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: bindings, requiredPostRoll: .zero))) {
            XCTAssertEqual($0 as? TemplateConversionError, .invalidVideoTrim(blockID: "block_01"))
        }
    }

    func testMissingSceneIDRejected() throws {
        let data = try Self.syntheticData(sceneID: nil)
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let selection = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")
        XCTAssertThrowsError(try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "synthetic", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: try Self.deterministicBindings(decoded: decoded),
            requiredPostRoll: .zero))) {
            XCTAssertEqual($0 as? TemplateConversionError, .missingSceneID)
        }
    }

    func testMaterialIdentityCollisionRejected() throws {
        let p = try Self.minimalProgram(templateHash: "dup")
        XCTAssertThrowsError(try RenderMaterialTable(programs: [p, p])) {
            XCTAssertEqual($0 as? RenderModelError, .duplicateIdentity(field: "RenderMaterialTable.programs", value: p.id.rawValue))
        }
    }

    /// Same block/variant across two different templates do NOT collide (structured identity, item 4).
    func testSameBlockVariantAcrossTemplatesDoesNotCollide() throws {
        // full_image and polaroid_shared_demo both have block_01/no-anim with identical layouts.
        let dataA = try CompiledTemplateFixtureBytes.bytes("full_image")
        let dataB = try CompiledTemplateFixtureBytes.bytes("polaroid_shared_demo")
        func program(_ data: Data, scene: String) throws -> CompiledTemplateConverter.Output {
            let decoded = try CompiledTemplateDecoder.decode(data)
            let inventory = try TemplateVariantInventory(from: decoded)
            return try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: data, catalogID: "c", sceneInstanceID: scene, scenePayloadID: "p",
                selection: Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim"),
                mediaBindings: ["block_01": .image(reference: "pic", mediaPlacement: .identity(fitMode: .contain))], requiredPostRoll: .zero))
        }
        let a = try program(dataA, scene: "scene_a")
        let b = try program(dataB, scene: "scene_b")
        // Distinct compiled hashes → distinct structured material ids → mergeable without collision.
        XCTAssertNotEqual(a.materials.programs.first?.id, b.materials.programs.first?.id)
        let merged = try RenderMaterialTable(programs: a.materials.programs + b.materials.programs)
        XCTAssertEqual(merged.programCount, 2)
    }

    /// Merge of **real converter outputs** (item 2): two different templates, and two instances of the
    /// same template. Lookups survive, identical programs coalesce, scene bindings stay separate, and
    /// merge order is irrelevant (identical table + hash).
    func testMergeRealConverterOutputs() throws {
        func convert(_ catalogID: String, scene: String) throws -> CompiledTemplateConverter.Output {
            let data = try CompiledTemplateFixtureBytes.bytes(catalogID)
            let decoded = try CompiledTemplateDecoder.decode(data)
            let inventory = try TemplateVariantInventory(from: decoded)
            // Bind every block (some templates have several) with deterministic image bindings.
            var bindings: [String: CompiledTemplateConverter.MediaBinding] = [:]
            for block in inventory.blocks { bindings[block.blockID] = .image(reference: "pic_\(block.blockID)", mediaPlacement: .identity(fitMode: .contain)) }
            var map: [String: String] = [:]
            for block in inventory.blocks { map[block.blockID] = block.selectedVariantID }
            return try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: data, catalogID: catalogID, sceneInstanceID: scene, scenePayloadID: "p_\(scene)",
                selection: .init(chosenVariantByBlockID: map), mediaBindings: bindings, requiredPostRoll: .zero))
        }

        // (A) Two DIFFERENT real templates.
        let fullImage = try convert("full_image", scene: "inst_full")
        let polaroid2 = try convert("polaroid_2", scene: "inst_pol")
        let mergedDiff = try fullImage.materials.merging(polaroid2.materials)
        XCTAssertEqual(mergedDiff.programCount, fullImage.materials.programCount + polaroid2.materials.programCount)
        // Every scene/layer lookup from both inputs survives the merge.
        XCTAssertNotNil(mergedDiff.program(for: SceneMaterialBindingKey(
            sceneID: try SceneInstanceID("inst_full"), layerID: try LayerID("block_01"))))
        XCTAssertNotNil(mergedDiff.program(for: SceneMaterialBindingKey(
            sceneID: try SceneInstanceID("inst_pol"), layerID: try LayerID("block_02"))))
        // Merge order is irrelevant.
        let mergedDiffRev = try polaroid2.materials.merging(fullImage.materials)
        XCTAssertEqual(mergedDiff, mergedDiffRev)
        XCTAssertEqual(try mergedDiff.contentHash(), try mergedDiffRev.contentHash())

        // (B) Two INSTANCES of the SAME real template. Programs are value-identical (same compiled
        // bytes → same structured ids) and coalesce; scene bindings stay separate per instance.
        let inst1 = try convert("polaroid_2", scene: "scene_1")
        let inst2 = try convert("polaroid_2", scene: "scene_2")
        XCTAssertEqual(inst1.materials.programs, inst2.materials.programs, "same template → identical programs")
        let mergedSame = try inst1.materials.merging(inst2.materials)
        // Programs deduplicated (still just the template's block count), bindings retained separately.
        XCTAssertEqual(mergedSame.programCount, inst1.materials.programCount)
        XCTAssertNotNil(mergedSame.program(for: SceneMaterialBindingKey(
            sceneID: try SceneInstanceID("scene_1"), layerID: try LayerID("block_01"))))
        XCTAssertNotNil(mergedSame.program(for: SceneMaterialBindingKey(
            sceneID: try SceneInstanceID("scene_2"), layerID: try LayerID("block_01"))))
        XCTAssertEqual(mergedSame.sceneBindingKeys.count,
                       inst1.materials.sceneBindingKeys.count + inst2.materials.sceneBindingKeys.count)
        // Order-independent here too.
        XCTAssertEqual(try mergedSame.contentHash(), try inst2.materials.merging(inst1.materials).contentHash())
    }

    // MARK: - Post-roll (item 7)

    func testPositivePostRollSatisfiedByImageAndHoldAnimation() throws {
        // full_image block_01 uses holdLastFrame (→ holdLast) and an image binding → positive post-roll OK.
        let data = try CompiledTemplateFixtureBytes.bytes("full_image")
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let selection = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")
        let bindings: [String: CompiledTemplateConverter.MediaBinding] = ["block_01": .image(reference: "pic", mediaPlacement: .identity(fitMode: .contain))]
        let out = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "c", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: bindings, requiredPostRoll: try TickDuration(ticks: 120_000)))
        XCTAssertEqual(out.document.manifest.scenes[0].postRollCapability.ticks, 120_000)
        XCTAssertNoThrow(try ProjectValidator.validate(out.document))
    }

    func testInsufficientVideoPostRollRejected() throws {
        // A video whose trim ends exactly at nominal duration cannot cover nominal + post-roll.
        let data = try CompiledTemplateFixtureBytes.bytes("full_image")
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let selection = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")
        // full_image: 150 frames @ 30fps → nominal = 150 * 8000 = 1_200_000 ticks. Trim ends there.
        let bindings: [String: CompiledTemplateConverter.MediaBinding] = [
            "block_01": .video(mediaReference: "m", trimStartTicks: 0, trimEndTicks: 1_200_000, nativeTimescale: 30_000, mediaPlacement: .identity(fitMode: .contain))]
        XCTAssertThrowsError(try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "c", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: bindings, requiredPostRoll: try TickDuration(ticks: 240_000)))) {
            XCTAssertEqual($0 as? TemplateConversionError, .insufficientVideoContinuation(blockID: "block_01"))
        }
    }

    func testInsufficientBecomeInactiveAnimationPostRollRejected() throws {
        // becomeInactive (ifAnimationShorter = cut) with authored duration == nominal cannot extend.
        let data = try Self.syntheticData(ifShorter: "cut", ifLonger: "cut", durationFrames: 150)
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let selection = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")
        // Image binding so video continuation is not the failing axis; animation continuation must fail.
        let bindings: [String: CompiledTemplateConverter.MediaBinding] = ["block_01": .image(reference: "pic", mediaPlacement: .identity(fitMode: .contain))]
        XCTAssertThrowsError(try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: data, catalogID: "synthetic", sceneInstanceID: "i", scenePayloadID: "p",
            selection: selection, mediaBindings: bindings, requiredPostRoll: try TickDuration(ticks: 80_000)))) {
            XCTAssertEqual($0 as? TemplateConversionError, .insufficientAnimationContinuation(blockID: "block_01"))
        }
    }

    func testNegativePostRollImpossibleByType() throws {
        // TickDuration rejects negatives by construction — the request cannot carry a negative post-roll.
        XCTAssertThrowsError(try TickDuration(ticks: -1)) {
            XCTAssertEqual($0 as? TimeError, .negativeValue(domain: "TickDuration", value: -1))
        }
    }

    // MARK: - Post-roll visibility integration (item 1)

    func testPostRollVisibilityAcrossSlideTransitionWithVideo() throws {
        let durationFrames = 150
        let shortEndFrame = 90
        let nominalTicks: Int64 = Int64(durationFrames) * 8_000   // 1_200_000
        let shortEndTicks: Int64 = Int64(shortEndFrame) * 8_000   // 720_000
        let slideDuration: Int64 = 80_000
        let preHalf = slideDuration / 2                  // 40_000
        let postHalf = slideDuration - preHalf           // 40_000
        let postRoll = try TickDuration(ticks: postHalf)

        // Outgoing scene A: two-block synthetic with VIDEO bindings. block_01 spans the scene (extended
        // into post-roll); block_02 ends at frame 90 (must NOT be extended).
        let dataA = try Self.syntheticTwoBlockData(durationFrames: durationFrames, shortEndFrame: shortEndFrame)
        let decodedA = try CompiledTemplateDecoder.decode(dataA)
        let invA = try TemplateVariantInventory(from: decodedA)
        // Video trim must cover the extended range [0, nominal + postHalf) for block_01.
        let trimEnd = nominalTicks + postHalf + 8_000
        let videoBindings: [String: CompiledTemplateConverter.MediaBinding] = [
            "block_01": .video(mediaReference: "clipA1", trimStartTicks: 0, trimEndTicks: trimEnd, nativeTimescale: 30_000, mediaPlacement: .identity(fitMode: .contain)),
            "block_02": .video(mediaReference: "clipA2", trimStartTicks: 0, trimEndTicks: shortEndTicks, nativeTimescale: 30_000, mediaPlacement: .identity(fitMode: .contain))
        ]
        let outA = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: dataA, catalogID: "synthetic2", sceneInstanceID: "sceneA", scenePayloadID: "pay_A",
            selection: Self.selection(inventory: invA, overrideBlockID: "block_01", variantID: "no-anim"),
            mediaBindings: videoBindings, requiredPostRoll: postRoll))

        // Incoming scene B: image bindings; no post-roll needed.
        let outB = try CompiledTemplateConverter.convert(.init(
            compiledTemplateData: dataA, catalogID: "synthetic2", sceneInstanceID: "sceneB", scenePayloadID: "pay_B",
            selection: Self.selection(inventory: invA, overrideBlockID: "block_01", variantID: "no-anim"),
            mediaBindings: ["block_01": .image(reference: "picB1", mediaPlacement: .identity(fitMode: .contain)), "block_02": .image(reference: "picB2", mediaPlacement: .identity(fitMode: .contain))],
            requiredPostRoll: .zero))

        // block_01 active range extended to nominal + postHalf; block_02 unchanged at its short end.
        let layersA = outA.document.scenePayloads[0].layers
        let l1 = try XCTUnwrap(layersA.first { $0.id.raw == "block_01" })
        let l2 = try XCTUnwrap(layersA.first { $0.id.raw == "block_02" })
        XCTAssertEqual(l1.activeRange.end.ticks, nominalTicks + postHalf, "spanning layer extended")
        XCTAssertEqual(l2.activeRange.end.ticks, shortEndTicks, "early-ending layer NOT extended")

        // Two-scene document with an animated SLIDE transition.
        let payloadA = outA.document.scenePayloads[0]
        let payloadB = outB.document.scenePayloads[0]
        let sceneA = SceneManifestEntry(
            id: try SceneInstanceID("sceneA"), payloadID: try ScenePayloadID("pay_A"),
            nominalDuration: try TickDuration(ticks: nominalTicks), postRollCapability: postRoll)
        let sceneB = SceneManifestEntry(
            id: try SceneInstanceID("sceneB"), payloadID: try ScenePayloadID("pay_B"),
            nominalDuration: try TickDuration(ticks: nominalTicks), postRollCapability: .zero)
        let slideParams = try TransitionParameterSet([
            TransitionParameter(key: "direction", value: .identifier("left"))
        ])
        let slide = SceneTransition(
            kind: .animated(TransitionEffect(effectID: try TransitionEffectID("slide"), parameters: slideParams)),
            duration: try TickDuration(ticks: slideDuration), easing: try EasingReference("linear"))
        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: outA.document.manifest.output, scenes: [sceneA, sceneB],
            boundaryTransitions: [slide], overlays: [])
        let document = CanonicalProjectDocument(
            manifest: manifest, scenePayloads: [payloadA, payloadB], overlayPayloads: [])
        XCTAssertNoThrow(try ProjectValidator.validate(document))

        let index = try TimelineIndex(manifest: manifest)
        let projectDuration = try manifest.projectDuration()
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: projectDuration.ticks))
        let window = try EvaluationWindowBuilder.build(
            requirement: try index.requirements(for: coverage),
            scenes: document.scenePayloads, overlays: document.overlayPayloads)

        let boundaryB = nominalTicks

        // (a) At exactly B + postHalf - 1: body is a transition; outgoing still present and timed.
        let planMid = try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: boundaryB + postHalf - 1))
        guard case .transition(let t) = planMid.body else {
            return XCTFail("expected a transition body at B + postHalf - 1, got \(planMid.body)")
        }
        XCTAssertEqual(t.outgoing.sceneID.raw, "sceneA")
        XCTAssertEqual(t.incoming.sceneID.raw, "sceneB")
        XCTAssertFalse(t.outgoing.layers.isEmpty, "outgoing layers non-empty in post-roll tail")
        // outgoing scene-local time equals nominal + postHalf - 1.
        XCTAssertEqual(t.outgoing.scenePlaybackTime.ticks, nominalTicks + postHalf - 1)
        // Only block_01 (the extended layer) is active at this post-roll tick.
        XCTAssertEqual(t.outgoing.layers.map { $0.layerID.raw }, ["block_01"],
                       "early-ending block_02 must be absent in the post-roll tail")

        // Video SourceRequest target continues normally (and advances between two post-roll ticks).
        let prevMid = try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: boundaryB + postHalf - 2))
        let target1 = try Self.videoTarget(prevMid, sceneID: "sceneA", layerID: "block_01")
        let target2 = try Self.videoTarget(planMid, sceneID: "sceneA", layerID: "block_01")
        XCTAssertLessThan(target1, target2, "video target continues advancing through post-roll")
        // Exact: at scene time s, target = s / 240000 (rate 1/1, trim start 0).
        XCTAssertEqual(target2, try RationalSourceTime(numerator: nominalTicks + postHalf - 1, denominator: 240_000))

        // animationRequest time continues normally: the no-anim (holdLast) layer holds its last frame
        // past authored end — the correct continuation request.
        let activeL1 = try XCTUnwrap(t.outgoing.layers.first { $0.layerID.raw == "block_01" })
        XCTAssertEqual(activeL1.animationRequest, .holdLast,
                       "holdLast animation continues normally (holds last frame) in post-roll")

        // (b) At exactly B + postHalf: body is a single incoming scene; no outgoing scene.
        let planEdge = try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: boundaryB + postHalf))
        guard case .single(let s) = planEdge.body else {
            return XCTFail("expected a single body at B + postHalf, got \(planEdge.body)")
        }
        XCTAssertEqual(s.sceneID.raw, "sceneB", "only the incoming scene remains at the transition window end")
        XCTAssertFalse(s.layers.isEmpty)
    }

    /// Extracts a video layer's `SourceRequest.target` from a frame plan's outgoing/sole scene.
    private static func videoTarget(_ plan: FramePlan, sceneID: String, layerID: String) throws -> RationalSourceTime {
        let subplan: SceneSubplan
        switch plan.body {
        case .transition(let t): subplan = t.outgoing.sceneID.raw == sceneID ? t.outgoing : t.incoming
        case .single(let s): subplan = s
        }
        let layer = try XCTUnwrap(subplan.layers.first { $0.layerID.raw == layerID })
        guard case .video(let request) = layer.content else {
            throw XCTSkip("layer \(layerID) is not video")
        }
        return request.target
    }

    // MARK: - Helpers

    private static func selection(
        inventory: TemplateVariantInventory, overrideBlockID: String, variantID: String
    ) -> TemplateVariantInventory.Selection {
        var map: [String: String] = [:]
        for block in inventory.blocks {
            map[block.blockID] = block.blockID == overrideBlockID ? variantID : block.selectedVariantID
        }
        return .init(chosenVariantByBlockID: map)
    }

    private static func fullSelectionMap(decoded: DecodedCompiledTemplate) throws -> [String: String] {
        let inventory = try TemplateVariantInventory(from: decoded)
        var map: [String: String] = [:]
        for block in inventory.blocks { map[block.blockID] = block.selectedVariantID }
        return map
    }

    /// One explicit, deterministic video binding per authored block, covering exactly the nominal
    /// scene duration. No 30-fps fallback (item 6): an unsupported fps throws.
    private static func deterministicBindings(
        decoded: DecodedCompiledTemplate
    ) throws -> [String: CompiledTemplateConverter.MediaBinding] {
        let scene = decoded.payload.compiled.runtime.scene
        let ticksPerFrame = try Self.ticksPerFrame(fps: scene.canvas.fps)
        let durationTicks = Int64(scene.canvas.durationFrames) * ticksPerFrame
        var map: [String: CompiledTemplateConverter.MediaBinding] = [:]
        for block in scene.mediaBlocks {
            map[block.blockID] = .video(
                mediaReference: "media_\(block.blockID)", trimStartTicks: 0,
                trimEndTicks: durationTicks, nativeTimescale: 30_000,
                mediaPlacement: .identity(fitMode: .contain))
        }
        return map
    }

    /// Exact ticks-per-frame for the supported rates; an unsupported fps throws (no silent fallback).
    private static func ticksPerFrame(fps: Int) throws -> Int64 {
        switch fps {
        case 24: return 10_000
        case 25: return 9_600
        case 30: return 8_000
        case 50: return 4_800
        case 60: return 4_000
        default: throw TimeError.unsupportedFrameRate(numerator: Int64(fps), denominator: 1)
        }
    }

    private static func minimalProgram(templateHash: String) throws -> RenderMaterialProgram {
        let cs = CanvasScalar(rawValue: 0)
        let rect = try FixedRect(x: cs, y: cs, width: CanvasScalar(rawValue: 1), height: CanvasScalar(rawValue: 1))
        let meta = RenderProgramMeta(width: cs, height: cs, fps: .zero, inPoint: .zero, outPoint: .zero, sourceAnimRef: "a")
        let binding = RenderBinding(bindingKey: "media", boundAssetID: "asset", boundCompID: "comp_0", boundLayerID: 1)
        let geometry = RenderMediaGeometry(
            contentSizeWidth: CanvasScalar(rawValue: 1), contentSizeHeight: CanvasScalar(rawValue: 1),
            contentRect: rect, placementRect: rect, blockRectCanvas: rect, containerClip: "none")
        return try RenderMaterialProgram(
            id: try RenderMaterialID(compiledTemplateHash: templateHash, blockID: "b", variantID: "v"),
            blockID: "b", variantID: "v", animationRef: "a.json", boundAssetID: "asset",
            mediaGeometry: geometry, rootCompID: "comp_0", compositions: [], assets: [],
            binding: binding, inputGeometry: nil, meta: meta, pathResources: [], toggleIDs: [])
    }

    // MARK: - Synthetic compiled `.tve` bytes (single block, one no-anim variant)

    private static func syntheticData(
        ifShorter: String = "holdLastFrame", ifLonger: String = "cut", durationFrames: Int = 150,
        sceneID: String? = "synthetic_scene", rectX: Double = 0, positionX: Double = 540,
        pathVertexX: Double? = nil, fitModesAllowed: [String] = ["cover", "contain", "fill"]
    ) throws -> Data {
        let object = Self.syntheticPayload(
            ifShorter: ifShorter, ifLonger: ifLonger, durationFrames: durationFrames,
            sceneID: sceneID, rectX: rectX, positionX: positionX, pathVertexX: pathVertexX,
            fitModesAllowed: fitModesAllowed)
        let payloadJSON = try JSONSerialization.data(withJSONObject: object)
        return Self.wrapEnvelope(payloadJSON)
    }

    /// Wraps a JSON payload in an 18-byte `TVE1` envelope (format 1, schema 2) so the converter can
    /// decode it internally (item 4).
    private static func wrapEnvelope(_ payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: [0x54, 0x56, 0x45, 0x31])              // "TVE1"
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        data.append(contentsOf: le16(1))                                // formatVersion
        data.append(contentsOf: le16(18))                              // headerLength
        data.append(contentsOf: le32(UInt32(payload.count)))           // payloadLength
        data.append(contentsOf: le32(0))                               // engineHash
        data.append(contentsOf: le16(2))                               // schemaVersion
        data.append(payload)
        return data
    }

    private static func syntheticPayload(
        ifShorter: String, ifLonger: String, durationFrames: Int, sceneID: String?, rectX: Double, positionX: Double,
        pathVertexX: Double?, fitModesAllowed: [String] = ["cover", "contain", "fill"]
    ) -> [String: Any] {
        let asset = "anim.json|image_0"
        let rect: [String: Any] = ["x": rectX, "y": 0, "width": 1080, "height": 1920]
        let canvas: [String: Any] = ["width": 1080, "height": 1920, "fps": 30, "durationFrames": durationFrames]
        let staticVec: ([String: Any]) -> [String: Any] = { ["static": ["_0": $0]] }
        let staticScalar: (Any) -> [String: Any] = { ["static": ["_0": $0]] }
        let staticBezier: [String: Any] = ["staticBezier": ["_0": [
            "vertices": [["x": 0, "y": 0], ["x": 10, "y": 0], ["x": 10, "y": 10]],
            "inTangents": [["x": 0, "y": 0], ["x": 0, "y": 0], ["x": 0, "y": 0]],
            "outTangents": [["x": 0, "y": 0], ["x": 0, "y": 0], ["x": 0, "y": 0]],
            "closed": true]]]
        let transform: [String: Any] = [
            "position": staticVec(["x": positionX, "y": 960]), "scale": staticVec(["x": 100, "y": 100]),
            "rotation": staticScalar(0), "opacity": staticScalar(100), "anchor": staticVec(["x": 0, "y": 0])
        ]
        // When a path vertex is supplied, attach a mask that references scene-level pathId 0.
        let masks: [[String: Any]] = pathVertexX == nil ? [] : [[
            "mode": "a", "inverted": false, "opacity": 100.0, "path": staticBezier, "pathId": ["value": 0]
        ]]
        let imageLayer: [String: Any] = [
            "id": 1, "name": "media", "type": 2,
            "timing": ["inPoint": 0.0, "outPoint": Double(durationFrames), "startTime": 0.0],
            "transform": transform, "masks": masks,
            "content": ["image": ["assetId": asset]], "isMatteSource": false, "isHidden": false
        ]
        let animIR: [String: Any] = [
            "meta": ["width": 1080.0, "height": 1920.0, "fps": 30.0,
                     "inPoint": 0.0, "outPoint": Double(durationFrames), "sourceAnimRef": "anim.json"],
            "rootComp": "comp_0",
            "comps": ["comp_0": ["id": "comp_0", "size": ["width": 1080, "height": 1920], "layers": [imageLayer]]],
            "assets": ["byId": [asset: "img0"], "sizeById": [asset: ["width": 1080.0, "height": 1920.0]],
                       "basenameById": [asset: "img0"]],
            "binding": ["bindingKey": "media", "boundLayerId": 1, "boundAssetId": asset, "boundCompId": "comp_0"],
            "pathRegistry": ["paths": []]
        ]
        // Scene-level path registry: present only when a mask references it.
        let scenePathRegistry: [String: Any]
        if let vx = pathVertexX {
            scenePathRegistry = ["paths": [[
                "pathId": ["value": 0],
                // vertexCount 4 → row length 8; indices a multiple of 3 within 0..<4; 0 easing (1 keyframe).
                "keyframePositions": [[vx, 0.0, 10.0, 0.0, 10.0, 10.0, 0.0, 10.0]],
                "keyframeTimes": [0.0], "indices": [0, 1, 2, 0, 2, 3], "vertexCount": 4, "keyframeEasing": []
            ]]]
        } else {
            scenePathRegistry = ["paths": []]
        }
        let runtimeVariant: [String: Any] = [
            "variantId": "no-anim", "animRef": "anim.json", "bindingKey": "media", "animIR": animIR]
        let block: [String: Any] = [
            "blockId": "block_01", "zIndex": 0, "orderIndex": 0, "rectCanvas": rect,
            "bindingBaseline": ["boundAssetId": asset,
                                "contentSizeLocal": ["width": 1080.0, "height": 1920.0], "contentRectLocal": rect],
            "mediaInputGeometry": ["placementRectLocal": rect],
            "timing": ["startFrame": 0, "endFrame": durationFrames],
            "containerClip": "none", "hitTestMode": "mask",
            "selectedVariantId": "no-anim", "editVariantId": "no-anim", "variants": [runtimeVariant]]
        let sceneVariant: [String: Any] = [
            "variantId": "no-anim", "animRef": "anim.json", "defaultDurationFrames": durationFrames,
            "ifAnimationShorter": ifShorter, "ifAnimationLonger": ifLonger, "loop": false]
        let sceneMediaBlock: [String: Any] = [
            "blockId": "block_01", "zIndex": 0, "rect": rect, "containerClip": "none",
            "input": ["bindingKey": "media", "hitTest": "mask",
                      "allowedMedia": ["photo", "video", "color"], "emptyPolicy": "hideWholeBlock",
                      "fitModesAllowed": fitModesAllowed, "defaultFit": "cover",
                      "userTransformsAllowed": ["pan": true, "zoom": true, "rotate": true],
                      "audio": ["enabled": false, "gain": 1.0]],
            "variants": [sceneVariant], "layerToggles": []]
        var scene: [String: Any] = ["schemaVersion": "0.1", "canvas": canvas, "mediaBlocks": [sceneMediaBlock]]
        if let sceneID { scene["sceneId"] = sceneID }
        let compiled: [String: Any] = [
            "runtime": ["scene": scene, "canvas": canvas, "blocks": [block],
                        "durationFrames": durationFrames, "fps": 30],
            "mergedAssetIndex": ["byId": [asset: "img0"],
                                 "sizeById": [asset: ["width": 1080.0, "height": 1920.0]],
                                 "basenameById": [asset: "img0"]],
            "pathRegistry": scenePathRegistry, "bindingAssetIds": [asset]]
        return ["engineVersion": "0.1.0", "templateId": "synthetic", "templateRevision": 1, "compiled": compiled]
    }

    // MARK: - Two-block synthetic `.tve` (block_01 spans the scene; block_02 ends early)

    /// A two-block synthetic template at 30 fps. `block_01` is timed `[0, durationFrames]` (so it
    /// reaches the nominal end and is post-roll-extended); `block_02` is timed `[0, shortEndFrame]`
    /// with `shortEndFrame < durationFrames` (so it must NOT be extended into post-roll).
    private static func syntheticTwoBlockData(durationFrames: Int, shortEndFrame: Int) throws -> Data {
        func blockPayloads(blockID: String, layerID: Int, asset: String, comp: String, endFrame: Int)
            -> (runtime: [String: Any], scene: [String: Any]) {
            let rect: [String: Any] = ["x": 0, "y": 0, "width": 1080, "height": 1920]
            let staticVec: ([String: Any]) -> [String: Any] = { ["static": ["_0": $0]] }
            let staticScalar: (Any) -> [String: Any] = { ["static": ["_0": $0]] }
            let transform: [String: Any] = [
                "position": staticVec(["x": 540, "y": 960]), "scale": staticVec(["x": 100, "y": 100]),
                "rotation": staticScalar(0), "opacity": staticScalar(100), "anchor": staticVec(["x": 0, "y": 0])]
            let imageLayer: [String: Any] = [
                "id": layerID, "name": "media", "type": 2,
                "timing": ["inPoint": 0.0, "outPoint": Double(durationFrames), "startTime": 0.0],
                "transform": transform, "masks": [],
                "content": ["image": ["assetId": asset]], "isMatteSource": false, "isHidden": false]
            let animIR: [String: Any] = [
                "meta": ["width": 1080.0, "height": 1920.0, "fps": 30.0,
                         "inPoint": 0.0, "outPoint": Double(durationFrames), "sourceAnimRef": "\(asset).json"],
                "rootComp": comp,
                "comps": [comp: ["id": comp, "size": ["width": 1080, "height": 1920], "layers": [imageLayer]]],
                "assets": ["byId": [asset: "r"], "sizeById": [asset: ["width": 1080.0, "height": 1920.0]],
                           "basenameById": [asset: "r"]],
                "binding": ["bindingKey": "media", "boundLayerId": layerID, "boundAssetId": asset, "boundCompId": comp],
                "pathRegistry": ["paths": []]]
            let runtimeVariant: [String: Any] = [
                "variantId": "no-anim", "animRef": "\(asset).json", "bindingKey": "media", "animIR": animIR]
            let zIndex = layerID - 1
            let runtime: [String: Any] = [
                "blockId": blockID, "zIndex": zIndex, "orderIndex": zIndex, "rectCanvas": rect,
                "bindingBaseline": ["boundAssetId": asset,
                                    "contentSizeLocal": ["width": 1080.0, "height": 1920.0], "contentRectLocal": rect],
                "mediaInputGeometry": ["placementRectLocal": rect],
                "timing": ["startFrame": 0, "endFrame": endFrame],
                "containerClip": "none", "hitTestMode": "mask",
                "selectedVariantId": "no-anim", "editVariantId": "no-anim", "variants": [runtimeVariant]]
            let sceneVariant: [String: Any] = [
                "variantId": "no-anim", "animRef": "\(asset).json", "defaultDurationFrames": durationFrames,
                "ifAnimationShorter": "holdLastFrame", "ifAnimationLonger": "cut", "loop": false]
            let sceneBlock: [String: Any] = [
                "blockId": blockID, "zIndex": zIndex, "rect": rect, "containerClip": "none",
                "timing": ["startFrame": 0, "endFrame": endFrame],
                "input": ["bindingKey": "media", "hitTest": "mask",
                          "allowedMedia": ["photo", "video", "color"], "emptyPolicy": "hideWholeBlock",
                          "fitModesAllowed": ["cover", "contain", "fill"], "defaultFit": "cover",
                          "userTransformsAllowed": ["pan": true, "zoom": true, "rotate": true],
                          "audio": ["enabled": false, "gain": 1.0]],
                "variants": [sceneVariant], "layerToggles": []]
            return (runtime, sceneBlock)
        }
        let a1 = "a1.json|image_0"; let a2 = "a2.json|image_0"
        let b1 = blockPayloads(blockID: "block_01", layerID: 1, asset: a1, comp: "comp_1", endFrame: durationFrames)
        let b2 = blockPayloads(blockID: "block_02", layerID: 2, asset: a2, comp: "comp_2", endFrame: shortEndFrame)
        let canvas: [String: Any] = ["width": 1080, "height": 1920, "fps": 30, "durationFrames": durationFrames]
        let scene: [String: Any] = ["schemaVersion": "0.1", "sceneId": "synthetic2", "canvas": canvas,
                                    "mediaBlocks": [b1.scene, b2.scene]]
        let compiled: [String: Any] = [
            "runtime": ["scene": scene, "canvas": canvas, "blocks": [b1.runtime, b2.runtime],
                        "durationFrames": durationFrames, "fps": 30],
            "mergedAssetIndex": ["byId": [a1: "r1", a2: "r2"],
                                 "sizeById": [a1: ["width": 1080.0, "height": 1920.0], a2: ["width": 1080.0, "height": 1920.0]],
                                 "basenameById": [a1: "r1", a2: "r2"]],
            "pathRegistry": ["paths": []], "bindingAssetIds": [a1, a2]]
        let object: [String: Any] = ["engineVersion": "0.1.0", "templateId": "synthetic2", "templateRevision": 1, "compiled": compiled]
        return Self.wrapEnvelope(try JSONSerialization.data(withJSONObject: object))
    }

    // MARK: - Step-8 corrective (issue #1b): explicit fit validated against fitModesAllowed

    /// A fit outside the block's `fitModesAllowed` is rejected with the typed `fitModeNotAllowed`; an
    /// allowed fit converts. All five real templates allow all three fits, so this uses a synthetic
    /// template whose `fitModesAllowed` is narrowed to `["cover"]` to exercise the rejection path.
    func testExplicitFitValidatedAgainstFitModesAllowed() throws {
        let data = try Self.syntheticData(fitModesAllowed: ["cover"])
        let decoded = try CompiledTemplateDecoder.decode(data)
        let inventory = try TemplateVariantInventory(from: decoded)
        let selection = Self.selection(inventory: inventory, overrideBlockID: "block_01", variantID: "no-anim")

        func convert(fit: MediaFitMode) throws -> CompiledTemplateConverter.Output {
            try CompiledTemplateConverter.convert(.init(
                compiledTemplateData: data, catalogID: "synthetic", sceneInstanceID: "i", scenePayloadID: "p",
                selection: selection,
                mediaBindings: ["block_01": .image(reference: "pic", mediaPlacement: .identity(fitMode: fit))],
                requiredPostRoll: .zero))
        }

        // Negative: `.contain` is not in `["cover"]` → rejected with the typed error.
        XCTAssertThrowsError(try convert(fit: .contain)) { error in
            guard case let TemplateConversionError.fitModeNotAllowed(blockID, chosenFit, allowed)? =
                    error as? TemplateConversionError else {
                return XCTFail("expected fitModeNotAllowed, got \(error)")
            }
            XCTAssertEqual(blockID, "block_01")
            XCTAssertEqual(chosenFit, "contain")
            XCTAssertEqual(allowed, ["cover"])
        }

        // Positive: `.cover` is allowed → converts and threads onto the SceneLayer.
        let out = try convert(fit: .cover)
        let layer = try XCTUnwrap(out.document.scenePayloads.first?.layers.first)
        XCTAssertEqual(layer.mediaPlacement.fitMode, .cover)
    }
}
