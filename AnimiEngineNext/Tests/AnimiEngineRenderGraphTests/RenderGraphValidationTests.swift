import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §7.4, D3-11, §13 — golden canonical-byte and SHA-256 tests (item 10) for the pinned
/// render-model values: render configuration, animation program, material table, render graph, pixel
/// input and rendered frame.
///
/// Golden tests pin the *exact* canonical UTF-8 bytes and the resulting domain-scoped SHA-256, so any
/// accidental change to field set, ordering, formatting or hash domain is caught deterministically.
/// (The graph *compiler*/full *validator* are §17 step 9; this file validates byte/hash stability.)
final class RenderGraphValidationTests: XCTestCase {

    // MARK: - Fixtures

    private func referenceConfig() throws -> RenderConfiguration {
        let canvas = try CanvasSize(width: 1080, height: 1920)
        let output = OutputContext(canvas: canvas, frameRate: try FrameRate(numerator: 30, denominator: 1))
        return try RenderConfiguration(
            output: output, colorContract: .task003,
            intermediateProfile: .rgba16FloatLinear, framesInFlight: 1)
    }

    private func bytes(_ value: RenderCanonicalEncoding.Value) throws -> String {
        String(data: try RenderCanonicalEncoding.canonicalBytes(value), encoding: .utf8)!
    }

    // MARK: - Configuration golden

    func testConfigurationGoldenBytesAndHash() throws {
        let config = try referenceConfig()
        let canonical = try bytes(try config.canonicalValue())
        XCTAssertEqual(canonical,
            "{\"canvasHeight\":1920,\"canvasWidth\":1080,\"colorContract\":{\"alphaStorage\":\"premultiplied\",\"colorSpace\":\"sRGB\",\"dynamicRange\":\"sdr\",\"outputFormat\":\"bgra8\"},\"frameRateDenominator\":1,\"frameRateNumerator\":30,\"framesInFlight\":1,\"intermediateProfile\":\"rgba16FloatLinear\"}")
        XCTAssertEqual(try config.configurationHash(),
            "9cd0d2cf5ec1e4d3d3aef665f2af69e2011d16d137a8ca5a78ef318f16fecb11")
    }

    // MARK: - Animation program golden

    func testAnimationProgramGoldenBytesAndHash() throws {
        let program = try AnimationProgram(
            id: try AnimationProgramID("anim-1"), authoredDuration: try TickDuration(ticks: 240_000))
        XCTAssertEqual(try bytes(try program.canonicalValue()),
            "{\"authoredDurationTicks\":240000,\"id\":\"anim-1\"}")
        XCTAssertEqual(try program.programHash(),
            "84be322456bac9f67af423c93f3fb2cfb946f02bbac8992d498df03cfff5efdd")
    }

    // MARK: - Material table golden

    func testMaterialTableGoldenBytesAndHash() throws {
        let dims = try PixelDimensions(width: 1, height: 1, bytesPerRow: 4, format: .bgra8)
        let a = try ResolvedPixelInput(id: try PixelInputID("a"), dimensions: dims, bytes: Data([1, 2, 3, 4]))
        let table = try RenderMaterialTable(pixelInputs: [a])
        // §17 step 7 extends the table with (here empty) programs and sceneBindings categories; the
        // canonical form now carries all three keys, sorted.
        XCTAssertEqual(try bytes(try table.canonicalValue()),
            "{\"pixelInputs\":[{\"contentHash\":\"f0db9f170b124b1a3a10be186115ed09b0dd596fc470d986b3284a61a7a5ce0e\",\"height\":1,\"id\":\"a\",\"width\":1}],\"programs\":[],\"sceneBindings\":[]}")
        XCTAssertEqual(try table.contentHash(),
            "a1020de41b5355ede996d00206e3d63f7a719c7bad9aed67e7f425db9ef38a90")
    }

    // MARK: - RenderGraph consumes selected materials WITHOUT importing the template adapter (item 7)

    /// Builds a `RenderMaterialProgram` (helper below) and a scene-binding, then resolves it from only
    /// `SceneInstanceID` + `LayerID` — the FramePlan lookup path — importing only Core + RenderModel.
    func testRenderGraphConsumesMaterialProgramWithoutAdapter() throws {
        let program = try Self.sampleProgram(
            templateHash: "deadbeef", blockID: "block_01", variantID: "no-anim", assetID: "asset")
        let sceneID = try SceneInstanceID("scene_a")
        let layerID = try LayerID("block_01")
        let table = try RenderMaterialTable(
            programs: [program],
            sceneBindings: [SceneMaterialBinding(
                key: SceneMaterialBindingKey(sceneID: sceneID, layerID: layerID), materialID: program.id)])

        // FramePlan-style lookup: sceneID + layerID only (no adapter, no material-id construction).
        let resolved = try XCTUnwrap(table.program(for: SceneMaterialBindingKey(sceneID: sceneID, layerID: layerID)))
        XCTAssertEqual(resolved.boundAssetID, "asset")
        XCTAssertEqual(resolved.compositions.first?.layers.first?.id, 1)
        if case .image(let assetID)? = resolved.compositions.first?.layers.first?.content {
            XCTAssertEqual(assetID, "asset")
        } else { XCTFail("expected image content") }
        XCTAssertEqual(try table.contentHash().count, 64)
    }

    /// Multi-template, multi-scene merge: distinct templates and scene instances all containing
    /// `block_01/no-anim` produce **no** identity collisions (structured ids + scene bindings).
    func testMultiTemplateMaterialTableMergeNoCollision() throws {
        let p1 = try Self.sampleProgram(templateHash: "hashA", blockID: "block_01", variantID: "no-anim", assetID: "a1")
        let p2 = try Self.sampleProgram(templateHash: "hashB", blockID: "block_01", variantID: "no-anim", assetID: "a2")
        XCTAssertNotEqual(p1.id, p2.id, "same block/variant across templates must not collide")

        let s1 = try SceneInstanceID("scene_1"); let s2 = try SceneInstanceID("scene_2")
        let l = try LayerID("block_01")
        let table = try RenderMaterialTable(
            programs: [p1, p2],
            sceneBindings: [
                SceneMaterialBinding(key: SceneMaterialBindingKey(sceneID: s1, layerID: l), materialID: p1.id),
                SceneMaterialBinding(key: SceneMaterialBindingKey(sceneID: s2, layerID: l), materialID: p2.id)
            ])
        XCTAssertEqual(table.programCount, 2)
        XCTAssertEqual(try XCTUnwrap(table.program(for: .init(sceneID: s1, layerID: l))).boundAssetID, "a1")
        XCTAssertEqual(try XCTUnwrap(table.program(for: .init(sceneID: s2, layerID: l))).boundAssetID, "a2")
    }

    /// Typed merge API (item 4): duplicate scene keys and conflicting programs fail; value-identical
    /// programs coalesce; all lookups survive.
    func testTypedMergeRejectsConflictsAndDuplicatesAndCoalescesIdenticals() throws {
        let s1 = try SceneInstanceID("s1"); let s2 = try SceneInstanceID("s2"); let l = try LayerID("block_01")
        let p1 = try Self.sampleProgram(templateHash: "hA", blockID: "block_01", variantID: "no-anim", assetID: "a1")
        let p2 = try Self.sampleProgram(templateHash: "hB", blockID: "block_01", variantID: "no-anim", assetID: "a2")
        let t1 = try RenderMaterialTable(programs: [p1],
            sceneBindings: [SceneMaterialBinding(key: .init(sceneID: s1, layerID: l), materialID: p1.id)])
        let t2 = try RenderMaterialTable(programs: [p2],
            sceneBindings: [SceneMaterialBinding(key: .init(sceneID: s2, layerID: l), materialID: p2.id)])

        // Clean merge: both programs and both bindings survive.
        let merged = try t1.merging(t2)
        XCTAssertEqual(merged.programCount, 2)
        XCTAssertEqual(merged.program(for: .init(sceneID: s1, layerID: l))?.boundAssetID, "a1")
        XCTAssertEqual(merged.program(for: .init(sceneID: s2, layerID: l))?.boundAssetID, "a2")

        // Value-identical program with same id coalesces (no error).
        let t1again = try RenderMaterialTable(programs: [p1])
        XCTAssertEqual(try t1.merging(t1again).programCount, 1)

        // Conflicting program: same id, different value → typed error.
        let p1conflict = try Self.sampleProgram(templateHash: "hA", blockID: "block_01", variantID: "no-anim", assetID: "DIFFERENT")
        XCTAssertEqual(p1.id, p1conflict.id)
        XCTAssertThrowsError(try t1.merging(try RenderMaterialTable(programs: [p1conflict]))) {
            XCTAssertEqual($0 as? RenderModelError, .conflictingProgram(id: p1.id.rawValue))
        }

        // Duplicate scene-binding key → typed error.
        let t1dupKey = try RenderMaterialTable(programs: [p2],
            sceneBindings: [SceneMaterialBinding(key: .init(sceneID: s1, layerID: l), materialID: p2.id)])
        XCTAssertThrowsError(try t1.merging(t1dupKey)) {
            XCTAssertEqual($0 as? RenderModelError, .duplicateSceneBinding(sceneID: "s1", layerID: "block_01"))
        }
    }

    /// Direct construction rejects a duplicate `SceneMaterialBindingKey` (item 4 — no silent overwrite).
    func testDuplicateSceneBindingKeyRejectedAtConstruction() throws {
        let s = try SceneInstanceID("s"); let l = try LayerID("block_01")
        let p = try Self.sampleProgram(templateHash: "h", blockID: "block_01", variantID: "no-anim", assetID: "a")
        XCTAssertThrowsError(try RenderMaterialTable(programs: [p], sceneBindings: [
            SceneMaterialBinding(key: .init(sceneID: s, layerID: l), materialID: p.id),
            SceneMaterialBinding(key: .init(sceneID: s, layerID: l), materialID: p.id)
        ])) {
            XCTAssertEqual($0 as? RenderModelError, .duplicateSceneBinding(sceneID: "s", layerID: "block_01"))
        }
    }

    /// A complete sample program (image layer, full transform with correct numeric types).
    static func sampleProgram(templateHash: String, blockID: String, variantID: String, assetID: String) throws -> RenderMaterialProgram {
        let cs: (Int64) -> CanvasScalar = { CanvasScalar(rawValue: $0) }
        let rect = try FixedRect(x: cs(0), y: cs(0), width: cs(65_536), height: cs(65_536))
        let transform = RenderTransform(
            position: .static(RenderVec2(x: cs(100), y: cs(200))),
            scale: .static(RenderScaleVec2(x: ScaleScalar.one, y: ScaleScalar.one)),
            rotation: .static(RotationScalar(rawValue: 0)),
            opacity: .static(OpacityScalar.opaque),
            anchor: .static(RenderVec2(x: cs(0), y: cs(0))))
        let timing = RenderLayerTiming(
            inPoint: try RationalSourceTime(numerator: 0, denominator: 1),
            outPoint: try RationalSourceTime(numerator: 150, denominator: 1),
            startTime: try RationalSourceTime(numerator: 0, denominator: 1))
        let layer = RenderLayer(
            id: 1, name: "media", type: 2, timing: timing, parentLayerID: nil, transform: transform,
            masks: [], matte: nil, content: .image(assetID: assetID), isMatteSource: false,
            isHidden: false, toggleID: nil)
        let comp = RenderComposition(id: "comp_0", width: cs(1080 * 65_536), height: cs(1920 * 65_536), layers: [layer])
        let meta = RenderProgramMeta(
            width: cs(1080 * 65_536), height: cs(1920 * 65_536),
            fps: try RationalSourceTime(numerator: 30, denominator: 1),
            inPoint: try RationalSourceTime(numerator: 0, denominator: 1),
            outPoint: try RationalSourceTime(numerator: 150, denominator: 1), sourceAnimRef: "anim.json")
        let binding = RenderBinding(bindingKey: "media", boundAssetID: assetID, boundCompID: "comp_0", boundLayerID: 1)
        let geometry = RenderMediaGeometry(
            contentSizeWidth: cs(1080 * 65_536), contentSizeHeight: cs(1920 * 65_536),
            contentRect: rect, placementRect: rect, blockRectCanvas: rect, containerClip: "none")
        return try RenderMaterialProgram(
            id: try RenderMaterialID(compiledTemplateHash: templateHash, blockID: blockID, variantID: variantID),
            blockID: blockID, variantID: variantID, animationRef: "anim.json", boundAssetID: assetID,
            mediaGeometry: geometry, rootCompID: "comp_0", compositions: [comp], assets: [],
            binding: binding, inputGeometry: nil, meta: meta, pathResources: [], toggleIDs: [])
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    // MARK: - Pixel input golden identity bytes (item 2)

    /// Pins the complete domain-tagged header **and** the raw-byte layout fed into SHA-256, plus the
    /// resulting content hash — so any change to the header schema, domain tag, or byte ordering is
    /// caught, not just a hash drift.
    func testPixelInputGoldenIdentityBytesAndHash() throws {
        let dims = try PixelDimensions(width: 1, height: 1, bytesPerRow: 4, format: .bgra8)
        let raw = Data([1, 2, 3, 4])
        let input = try ResolvedPixelInput(id: try PixelInputID("a"), dimensions: dims, bytes: raw)

        // Reconstruct the exact identity buffer = domain-tagged header || raw bytes.
        // The descriptor now carries an explicit presentation orientation (step-8 corrective #5).
        let header = try RenderCanonicalEncoding.domainBytes(.object([
            ("bytesPerRow", .int(4)), ("format", .string("bgra8")),
            ("height", .int(1)), ("orientation", .string("up")), ("width", .int(1))
        ]), domain: .pixelInput)
        XCTAssertEqual(String(data: header, encoding: .utf8),
            "{\"__domain\":\"aen.pixelInput.v1\",\"value\":{\"bytesPerRow\":4,\"format\":\"bgra8\",\"height\":1,\"orientation\":\"up\",\"width\":1}}")
        var combined = header; combined.append(raw)
        XCTAssertEqual(hex(combined),
            "7b225f5f646f6d61696e223a2261656e2e706978656c496e7075742e7631222c2276616c7565223a7b226279746573506572526f77223a342c22666f726d6174223a226267726138222c22686569676874223a312c226f7269656e746174696f6e223a227570222c227769647468223a317d7d01020304")
        XCTAssertEqual(input.contentHash,
            "f0db9f170b124b1a3a10be186115ed09b0dd596fc470d986b3284a61a7a5ce0e")
    }

    // MARK: - Rendered frame golden identity bytes (item 2)

    func testRenderedFrameGoldenIdentityBytesAndHash() throws {
        let dims = try PixelDimensions(width: 1, height: 1, bytesPerRow: 4, format: .bgra8)
        let raw = Data([5, 6, 7, 8])
        let frame = try RenderedFrame(dimensions: dims, colorContract: .task003, bytes: raw)

        let header = try RenderCanonicalEncoding.domainBytes(.object([
            ("alphaStorage", .string("premultiplied")), ("bytesPerRow", .int(4)),
            ("colorSpace", .string("sRGB")), ("dynamicRange", .string("sdr")),
            ("format", .string("bgra8")), ("height", .int(1)), ("orientation", .string("up")),
            ("outputFormat", .string("bgra8")), ("width", .int(1))
        ]), domain: .renderedFrame)
        XCTAssertEqual(String(data: header, encoding: .utf8),
            "{\"__domain\":\"aen.renderedFrame.v1\",\"value\":{\"alphaStorage\":\"premultiplied\",\"bytesPerRow\":4,\"colorSpace\":\"sRGB\",\"dynamicRange\":\"sdr\",\"format\":\"bgra8\",\"height\":1,\"orientation\":\"up\",\"outputFormat\":\"bgra8\",\"width\":1}}")
        var combined = header; combined.append(raw)
        XCTAssertEqual(hex(combined),
            "7b225f5f646f6d61696e223a2261656e2e72656e64657265644672616d652e7631222c2276616c7565223a7b22616c70686153746f72616765223a227072656d756c7469706c696564222c226279746573506572526f77223a342c22636f6c6f725370616365223a2273524742222c2264796e616d696352616e6765223a22736472222c22666f726d6174223a226267726138222c22686569676874223a312c226f7269656e746174696f6e223a227570222c226f7574707574466f726d6174223a226267726138222c227769647468223a317d7d05060708")
        XCTAssertEqual(frame.rawOutputHash,
            "c457492ef382447a9407b5f82bebe165c5825a26fdce697d59b5d1206ccb44b0")
    }

    // MARK: - Graph golden

    func testGraphGoldenBytesAndHash() throws {
        let commands = try [RenderCommandCategory.clearBackground, .drawImage, .finalLinearToSRGB, .finalOutput]
            .enumerated().map { try RenderCommand(ordinal: $0.offset, payload: GraphTestPayloads.minimal($0.element)) }
        let graph = try RenderGraph(configuration: try referenceConfig(), commands: commands)
        // §17 step 9 corrective: the canonical bytes now carry each command's explicit render-target
        // surface flow (corrective #2) in addition to its field-level payload.
        XCTAssertEqual(try bytes(try graph.canonicalValue()),
            "{\"commands\":[{\"category\":\"clearBackground\",\"color\":{\"a\":0,\"b\":0,\"g\":0,\"r\":0},\"ordinal\":0,\"target\":\"surface\\u001flinearCanvas\"},{\"category\":\"drawImage\",\"opacity\":1000000,\"ordinal\":1,\"resourceID\":\"r\",\"target\":\"surface\\u001flinearCanvas\",\"transform\":{\"a\":1000000,\"b\":0,\"c\":0,\"d\":1000000,\"tx\":0,\"ty\":0}},{\"category\":\"finalLinearToSRGB\",\"ordinal\":2,\"source\":\"surface\\u001flinearCanvas\",\"target\":\"surface\\u001fsRGB\"},{\"category\":\"finalOutput\",\"ordinal\":3,\"source\":\"surface\\u001fsRGB\"}],\"configuration\":{\"canvasHeight\":1920,\"canvasWidth\":1080,\"colorContract\":{\"alphaStorage\":\"premultiplied\",\"colorSpace\":\"sRGB\",\"dynamicRange\":\"sdr\",\"outputFormat\":\"bgra8\"},\"frameRateDenominator\":1,\"frameRateNumerator\":30,\"framesInFlight\":1,\"intermediateProfile\":\"rgba16FloatLinear\"}}")
        XCTAssertEqual(try graph.graphHash(),
            "acc1988dd3d1b91d91967b0d832e81f470905c95685b37d973fc96a2eda2d263")
    }

    /// Pins the canonical bytes of resource descriptors (final micro-correction #1): an OFFSCREEN
    /// rgba16FloatLinear surface must encode `"pixelFormat":"n/a"` and carry NO `"format":"bgra8"`,
    /// while a PIXEL-INPUT resource encodes its actual input byte format `"pixelFormat":"bgra8"`. This
    /// is the schema guard that the 16-bit-float surface is never mislabelled with a BGRA8 byte format.
    func testResourceDescriptorGoldenBytesNoBGRA8OnFloatSurface() throws {
        let offscreen = try RenderCommand(ordinal: 0, payload: GraphTestPayloads.minimal(.offscreenSurface))
        let pixel = try RenderCommand(ordinal: 1, payload: GraphTestPayloads.minimal(.declareResource))
        let offscreenBytes = try bytes(try offscreen.canonicalValue())
        let pixelBytes = try bytes(try pixel.canonicalValue())
        // The offscreen surface (rgba16FloatLinear) carries pixelFormat:"n/a" and surfaceStorage:rgba16FloatLinear.
        XCTAssertFalse(offscreenBytes.contains("\"format\":\"bgra8\""),
            "offscreen rgba16FloatLinear surface must NOT encode a BGRA8 byte format")
        XCTAssertTrue(offscreenBytes.contains("\"pixelFormat\":\"n/a\""),
            "offscreen surface encodes pixelFormat:\"n/a\"")
        XCTAssertTrue(offscreenBytes.contains("\"surfaceStorage\":\"rgba16FloatLinear\""),
            "offscreen surface storage is rgba16FloatLinear")
        // The pixel-input resource keeps its actual input byte format under pixelFormat.
        XCTAssertTrue(pixelBytes.contains("\"pixelFormat\":\"bgra8\""),
            "pixel input encodes its real input byte format under pixelFormat")
        XCTAssertTrue(pixelBytes.contains("\"surfaceProfile\":\"n/a\""),
            "pixel input has no surface profile")
    }
}
