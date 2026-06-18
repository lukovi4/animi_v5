import XCTest
import Foundation
@testable import AnimiEngineTemplateAdapter

/// Task-003 plan §5.2, §13 row "Strict schema" — strict schema-2 payload decoding (Stage-4
/// correction).
///
/// The minimal valid payload mirrors the producer schema exactly (Double timings/meta, layer
/// type↔content pairing, scene product policy, scene↔runtime block bijection, a path registry that
/// resolves the layer's `pathId`). Each rejection branch mutates one node. All five real fixtures
/// are decoded end-to-end and a determinism check is kept.
final class CompiledTemplateSchemaTests: XCTestCase {

    // MARK: - Minimal valid payload (producer-shaped)

    private func validPayloadObject() -> [String: Any] {
        let imageAsset = "anim.json|image_0"
        let sizeI: [String: Any] = ["width": 1080, "height": 1920]              // Composition SizeD (Double-typed)
        let rect: [String: Any] = ["x": 0, "y": 0, "width": 1080, "height": 1920]
        let staticVec: ([String: Any]) -> [String: Any] = { ["static": ["_0": $0]] }
        let staticScalar: (Any) -> [String: Any] = { ["static": ["_0": $0]] }
        let transform: [String: Any] = [
            "position": staticVec(["x": 540, "y": 960]),
            "scale": staticVec(["x": 100, "y": 100]),
            "rotation": staticScalar(0),
            "opacity": staticScalar(100),
            "anchor": staticVec(["x": 0, "y": 0])
        ]
        // Image layer (type 2 → image content). Timings are Double per producer LayerTiming.
        let imageLayer: [String: Any] = [
            "id": 1,
            "name": "media",
            "type": 2,
            "timing": ["inPoint": 0.0, "outPoint": 150.0, "startTime": 0.0],
            "transform": transform,
            "masks": [],
            "content": ["image": ["assetId": imageAsset]],
            "isMatteSource": false,
            "isHidden": false
        ]
        let comp: [String: Any] = ["id": "comp_0", "size": sizeI, "layers": [imageLayer]]
        let assets: [String: Any] = [
            "byId": [imageAsset: "img0"],
            "sizeById": [imageAsset: ["width": 1080.0, "height": 1920.0]],
            "basenameById": [imageAsset: "img0"]
        ]
        let animIR: [String: Any] = [
            "meta": [
                "width": 1080.0, "height": 1920.0, "fps": 30.0,
                "inPoint": 0.0, "outPoint": 150.0, "sourceAnimRef": "anim.json"
            ],
            "rootComp": "comp_0",
            "comps": ["comp_0": comp],
            "assets": assets,
            "binding": [
                "bindingKey": "media", "boundLayerId": 1,
                "boundAssetId": imageAsset, "boundCompId": "comp_0"
            ],
            "pathRegistry": ["paths": []]
        ]
        let runtimeVariant: [String: Any] = [
            "variantId": "no-anim", "animRef": "anim.json", "bindingKey": "media", "animIR": animIR
        ]
        let block: [String: Any] = [
            "blockId": "block_01",
            "zIndex": 0,
            "orderIndex": 0,
            "rectCanvas": rect,
            "bindingBaseline": [
                "boundAssetId": imageAsset,
                "contentSizeLocal": ["width": 1080.0, "height": 1920.0],
                "contentRectLocal": rect
            ],
            "mediaInputGeometry": ["placementRectLocal": rect],
            "timing": ["startFrame": 0, "endFrame": 150],
            "containerClip": "none",
            "hitTestMode": "mask",
            "selectedVariantId": "no-anim",
            "editVariantId": "no-anim",
            "variants": [runtimeVariant]
        ]
        let canvas: [String: Any] = ["width": 1080, "height": 1920, "fps": 30, "durationFrames": 150]
        let sceneMediaBlock: [String: Any] = [
            "blockId": "block_01",
            "zIndex": 0,
            "rect": rect,
            "containerClip": "none",
            "input": [
                "bindingKey": "media",
                "hitTest": "mask",
                "allowedMedia": ["photo", "video", "color"],
                "emptyPolicy": "hideWholeBlock",
                "fitModesAllowed": ["cover", "contain", "fill"],
                "defaultFit": "cover",
                "userTransformsAllowed": ["pan": true, "zoom": true, "rotate": true],
                "audio": ["enabled": false, "gain": 1.0]
            ],
            "variants": [[
                "variantId": "no-anim", "animRef": "anim.json",
                "defaultDurationFrames": 150, "ifAnimationShorter": "holdLastFrame",
                "ifAnimationLonger": "cut", "loop": false
            ]],
            "layerToggles": []
        ]
        let scene: [String: Any] = [
            "schemaVersion": "0.1",
            "sceneId": "scene_test",
            "canvas": canvas,
            "mediaBlocks": [sceneMediaBlock]
        ]
        let compiled: [String: Any] = [
            "runtime": [
                "scene": scene, "canvas": canvas, "blocks": [block],
                "durationFrames": 150, "fps": 30
            ],
            "mergedAssetIndex": assets,
            "pathRegistry": ["paths": []],
            "bindingAssetIds": [imageAsset]
        ]
        return [
            "engineVersion": "0.1.0",
            "templateId": "test_template",
            "templateRevision": 1,
            "compiled": compiled
        ]
    }

    /// A shapeMatte layer (type 4 → shapes content) plus a registry that resolves its pathId.
    /// Returned as (layer, registryEntry) so individual tests can install both.
    private func shapeLayerAndRegistry(pathID: Int = 0) -> (layer: [String: Any], registry: [String: Any]) {
        let bezier: [String: Any] = [
            "vertices": [["x": 0, "y": 0], ["x": 10, "y": 0], ["x": 10, "y": 10]],
            "inTangents": [["x": 0, "y": 0], ["x": 0, "y": 0], ["x": 0, "y": 0]],
            "outTangents": [["x": 0, "y": 0], ["x": 0, "y": 0], ["x": 0, "y": 0]],
            "closed": true
        ]
        let staticVec: ([String: Any]) -> [String: Any] = { ["static": ["_0": $0]] }
        let staticScalar: (Any) -> [String: Any] = { ["static": ["_0": $0]] }
        let gt: [String: Any] = [
            "position": staticVec(["x": 0, "y": 0]),
            "anchor": staticVec(["x": 0, "y": 0]),
            "scale": staticVec(["x": 100, "y": 100]),
            "rotation": staticScalar(0),
            "opacity": staticScalar(1)
        ]
        let shape: [String: Any] = [
            "pathId": ["value": pathID],
            "fillColor": [1.0, 1.0, 1.0, 1.0],
            "fillOpacity": 100,
            "stroke": [
                "color": [1.0, 1.0, 1.0], "opacity": 1.0, "width": staticScalar(2),
                "lineCap": 1, "lineJoin": 1, "miterLimit": 4.0
            ],
            "animPath": ["staticBezier": ["_0": bezier]],
            "groupTransforms": [gt]
        ]
        let layer: [String: Any] = [
            "id": 9,
            "name": "shape",
            "type": 4,
            "timing": ["inPoint": 0.0, "outPoint": 150.0, "startTime": 0.0],
            "transform": gt,
            "masks": [],
            "content": ["shapes": ["_0": shape]],
            "isMatteSource": true,
            "isHidden": false
        ]
        let registry: [String: Any] = ["paths": [[
            "pathId": ["value": pathID],
            "keyframePositions": [[0.0, 0.0, 10.0, 0.0]],
            "keyframeTimes": [0.0],
            "indices": [0, 1, 2],
            "vertexCount": 3,
            "keyframeEasing": []
        ]]]
        return (layer, registry)
    }

    // MARK: - Helpers

    private func decode(_ object: [String: Any]) throws -> CompiledTemplatePayloadDTO {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try CompiledTemplatePayloadDTO.decode(try CompiledJSONParser.parse(data))
    }

    private func mutating(_ object: [String: Any], _ keyPath: String, to value: Any?) -> [String: Any] {
        var root = object
        setValue(&root, path: keyPath.split(separator: ".").map(String.init), value: value)
        return root
    }

    private func setValue(_ container: inout [String: Any], path: [String], value: Any?) {
        guard let head = path.first else { return }
        if path.count == 1 {
            if let value { container[head] = value } else { container.removeValue(forKey: head) }
            return
        }
        let rest = Array(path.dropFirst())
        if var child = container[head] as? [String: Any] {
            setValue(&child, path: rest, value: value)
            container[head] = child
        } else if var arr = container[head] as? [Any], let first = rest.first,
                  first.hasPrefix("["), let idx = Int(first.dropFirst().dropLast()), idx < arr.count {
            if rest.count == 1 {
                if let value { arr[idx] = value }
            } else if var elem = arr[idx] as? [String: Any] {
                setValue(&elem, path: Array(rest.dropFirst()), value: value)
                arr[idx] = elem
            }
            container[head] = arr
        }
    }

    private func assertThrows(
        _ object: [String: Any], _ expected: CompiledTemplateDecodingError, _ message: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertThrowsError(try decode(object), message, file: file, line: line) {
            XCTAssertEqual($0 as? CompiledTemplateDecodingError, expected, message, file: file, line: line)
        }
    }

    private func assertThrowsAny(
        _ object: [String: Any], _ message: String,
        file: StaticString = #file, line: UInt = #line,
        where predicate: (CompiledTemplateDecodingError) -> Bool
    ) {
        XCTAssertThrowsError(try decode(object), message, file: file, line: line) {
            guard let e = $0 as? CompiledTemplateDecodingError else {
                return XCTFail("expected CompiledTemplateDecodingError, got \($0)", file: file, line: line)
            }
            XCTAssertTrue(predicate(e), "\(message) — got \(e)", file: file, line: line)
        }
    }

    // MARK: - Baseline

    func testMinimalValidPayloadDecodes() throws {
        let dto = try decode(validPayloadObject())
        XCTAssertEqual(dto.templateID, "test_template")
        XCTAssertEqual(dto.compiled.runtime.blocks.count, 1)
        let block = dto.compiled.runtime.blocks[0]
        XCTAssertEqual(block.hitTestMode, .mask)
        XCTAssertEqual(block.containerClip, .none)
        XCTAssertEqual(block.variants[0].animIR.comps[0].layers[0].type, .image)
    }

    func testNullableTemplateIdAbsentDecodes() throws {
        // templateId is documented nullable-absent (String?); omitting it is valid.
        let dto = try decode(mutating(validPayloadObject(), "templateId", to: nil))
        XCTAssertNil(dto.templateID)
    }

    // MARK: - Missing / unknown fields

    func testMissingRequiredFieldRejected() {
        assertThrows(mutating(validPayloadObject(), "templateRevision", to: nil),
                     .missingField(path: "", field: "templateRevision"), "missing top-level field")
    }

    func testMissingNestedFieldRejected() {
        assertThrows(mutating(validPayloadObject(), "compiled.runtime.fps", to: nil),
                     .missingField(path: "compiled.runtime", field: "fps"), "missing nested field")
    }

    func testUnknownTopLevelFieldRejected() {
        assertThrows(mutating(validPayloadObject(), "surprise", to: 1),
                     .unknownField(path: "", field: "surprise"), "unknown top-level field")
    }

    func testUnknownNestedFieldRejectedRecursively() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].animIR.comps.comp_0.layers.[0].bogus",
                         to: true)
        assertThrowsAny(o, "deep unknown field") {
            if case .unknownField(_, let f) = $0 { return f == "bogus" }; return false
        }
    }

    func testUnknownFieldInSceneInputRejected() {
        // Scene MediaInput is now decoded strictly — an unknown field must be rejected.
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.scene.mediaBlocks.[0].input.weird", to: 1)
        assertThrowsAny(o, "unknown field in scene input") {
            if case .unknownField(_, let f) = $0 { return f == "weird" }; return false
        }
    }

    func testUnknownFieldInLayerToggleRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.scene.mediaBlocks.[0].layerToggles",
                         to: [["id": "t1", "title": "T", "defaultOn": true, "extra": 1]])
        assertThrowsAny(o, "unknown field in layerToggle") {
            if case .unknownField(_, let f) = $0 { return f == "extra" }; return false
        }
    }

    // MARK: - Wrong types

    func testStringWhereIntegerExpectedRejected() {
        assertThrows(mutating(validPayloadObject(), "templateRevision", to: "one"),
                     .wrongType(path: "templateRevision", expected: "integer"), "string for integer")
    }

    func testIntegerWhereStringExpectedRejected() {
        assertThrows(mutating(validPayloadObject(), "templateId", to: 7),
                     .wrongType(path: "templateId", expected: "string"), "integer for string")
    }

    func testObjectWhereArrayExpectedRejected() {
        assertThrows(mutating(validPayloadObject(), "compiled.bindingAssetIds", to: ["a": 1]),
                     .wrongType(path: "compiled.bindingAssetIds", expected: "array"), "object for array")
    }

    func testSceneVariantWrongTypeRejected() {
        // defaultDurationFrames must be an integer when present.
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.scene.mediaBlocks.[0].variants.[0].defaultDurationFrames", to: "x")
        assertThrowsAny(o, "scene variant wrong type") {
            if case .wrongType(_, let e) = $0 { return e == "integer" }; return false
        }
    }

    // MARK: - Bool / integer / float distinction (§5.4)

    func testBoolWhereIntegerExpectedRejected() {
        assertThrows(mutating(validPayloadObject(), "templateRevision", to: true),
                     .wrongType(path: "templateRevision", expected: "integer"), "Bool not integer")
    }

    func testIntegerWhereBoolExpectedRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].animIR.comps.comp_0.layers.[0].isHidden",
                         to: 1)
        assertThrowsAny(o, "integer not Bool") {
            if case .wrongType(_, let e) = $0 { return e == "boolean" }; return false
        }
    }

    func testFractionalValueWhereIntegerExpectedRejected() {
        assertThrows(mutating(validPayloadObject(), "compiled.runtime.fps", to: 30.5),
                     .malformedInteger(path: "compiled.runtime.fps"), "fraction not integer")
    }

    func testFloatingValueAcceptedWhereNumberExpected() throws {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].mediaInputGeometry.placementRectLocal.y", to: 12.5)
        let dto = try decode(o)
        XCTAssertEqual(dto.compiled.runtime.blocks[0].mediaInputGeometry.placementRectLocal.y, 12.5)
    }

    func testIntegerAcceptedForDoubleMetaField() throws {
        // Meta.fps is Double; an integer literal is a valid finite number.
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].animIR.meta.fps", to: 24)
        let dto = try decode(o)
        XCTAssertEqual(dto.compiled.runtime.blocks[0].variants[0].animIR.meta.fps, 24)
    }

    // MARK: - Explicit-null vs absent (item 5)

    func testExplicitNullOnRequiredFieldRejected() {
        assertThrows(mutating(validPayloadObject(), "engineVersion", to: NSNull()),
                     .explicitNull(path: "engineVersion"), "null on required field")
    }

    func testExplicitNullOnNullableAbsentFieldRejected() {
        // templateId may be ABSENT, but an explicit `null` is still rejected (not documented nullable).
        assertThrows(mutating(validPayloadObject(), "templateId", to: NSNull()),
                     .explicitNull(path: "templateId"), "null on optional-absent field")
    }

    func testExplicitNullOnOptionalSceneFieldRejected() {
        // hitTest is optional-absent on MediaInput; explicit null must fail closed.
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.scene.mediaBlocks.[0].input.hitTest", to: NSNull())
        assertThrowsAny(o, "null on optional scene field") {
            if case .explicitNull = $0 { return true }; return false
        }
    }

    func testExplicitNullKeyframeEasingElementAccepted() throws {
        // keyframeEasing elements ARE documented nullable ([KeyframeEasing?]); null is a valid marker.
        let (layer, _) = shapeLayerAndRegistry(pathID: 0)
        let registry: [String: Any] = ["paths": [[
            "pathId": ["value": 0],
            "keyframePositions": [[0.0, 0.0], [1.0, 1.0]],
            "keyframeTimes": [0.0, 30.0],
            "indices": [0, 1],
            "vertexCount": 1,
            "keyframeEasing": [NSNull()]   // explicit null element → linear/hold marker
        ]]]
        var o = installShapeLayer(validPayloadObject(), layer: layer)
        o = mutating(o, "compiled.pathRegistry", to: registry)
        let dto = try decode(o)
        let entry = dto.compiled.pathRegistry.paths.first { $0.pathID == 0 }
        XCTAssertEqual(entry?.keyframeEasing.count, 1)
        XCTAssertNil(entry?.keyframeEasing.first ?? .some(CompiledPathEasingDTO(outX: 0, outY: 0, inX: 0, inY: 0, hold: false)))
    }

    // MARK: - Closed enums

    func testUnknownHitTestModeRejected() {
        let o = mutating(validPayloadObject(), "compiled.runtime.blocks.[0].hitTestMode", to: "blob")
        assertThrowsAny(o, "unknown hitTestMode") {
            if case .unknownEnumTag(_, let t) = $0 { return t == "blob" }; return false
        }
    }

    func testUnknownContainerClipRejected() {
        let o = mutating(validPayloadObject(), "compiled.runtime.blocks.[0].containerClip", to: "squish")
        assertThrowsAny(o, "unknown containerClip") {
            if case .unknownEnumTag(_, let t) = $0 { return t == "squish" }; return false
        }
    }

    func testUnknownFitModeRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.scene.mediaBlocks.[0].input.defaultFit", to: "squash")
        assertThrowsAny(o, "unknown fit mode") {
            if case .unknownEnumTag(_, let t) = $0 { return t == "squash" }; return false
        }
    }

    func testUnknownFitModeInArrayRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.scene.mediaBlocks.[0].input.fitModesAllowed", to: ["cover", "warp"])
        assertThrowsAny(o, "unknown fit mode in array") {
            if case .unknownEnumTag(_, let t) = $0 { return t == "warp" }; return false
        }
    }

    func testUnknownEmptyPolicyRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.scene.mediaBlocks.[0].input.emptyPolicy", to: "vanish")
        assertThrowsAny(o, "unknown empty policy") {
            if case .unknownEnumTag(_, let t) = $0 { return t == "vanish" }; return false
        }
    }

    func testUnknownAnimationDurationBehaviorRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.scene.mediaBlocks.[0].variants.[0].ifAnimationShorter", to: "freeze")
        assertThrowsAny(o, "unknown duration behavior") {
            if case .unknownEnumTag(_, let t) = $0 { return t == "freeze" }; return false
        }
    }

    func testUnknownLayerTypeCodeRejected() {
        let o = setLayerZero(validPayloadObject(), key: "type", to: 99)
        assertThrowsAny(o, "unknown layer type code") {
            if case .unknownEnumCode(_, let c) = $0 { return c == 99 }; return false
        }
    }

    func testUnknownMatteModeCodeRejected() {
        var layer = layerZero(in: validPayloadObject())
        layer["matte"] = ["mode": 7, "sourceLayerId": 1]
        let o = setLayerZero(validPayloadObject(), to: layer)
        assertThrowsAny(o, "unknown matte mode code") {
            if case .unknownEnumCode(_, let c) = $0 { return c == 7 }; return false
        }
    }

    func testUnknownMaskModeRejected() {
        var layer = layerZero(in: validPayloadObject())
        layer["masks"] = [[
            "mode": "z", "inverted": false, "opacity": 100,
            "path": ["staticBezier": ["_0": [
                "vertices": [], "inTangents": [], "outTangents": [], "closed": true
            ]]]
        ]]
        let o = setLayerZero(validPayloadObject(), to: layer)
        assertThrowsAny(o, "unknown mask mode") {
            if case .unknownEnumTag(_, let t) = $0 { return t == "z" }; return false
        }
    }

    func testLineCapOutOfRangeRejected() throws {
        let (layer, registry) = shapeLayerAndRegistry(pathID: 0)
        var bad = layer
        var content = bad["content"] as! [String: Any]
        var shapes = content["shapes"] as! [String: Any]
        var shape = shapes["_0"] as! [String: Any]
        var stroke = shape["stroke"] as! [String: Any]
        stroke["lineCap"] = 9
        shape["stroke"] = stroke; shapes["_0"] = shape; content["shapes"] = shapes; bad["content"] = content
        var o = installShapeLayer(validPayloadObject(), layer: bad)
        o = mutating(o, "compiled.pathRegistry", to: registry)
        assertThrowsAny(o, "lineCap out of range") {
            if case .valueOutOfRange(_, let d) = $0 { return d.contains("lineCap") }; return false
        }
    }

    // MARK: - Layer type/content compatibility

    func testLayerTypeContentMismatchRejected() {
        // type 2 (image) carrying shape content is incompatible.
        var layer = layerZero(in: validPayloadObject())
        layer["content"] = ["shapes": ["_0": [
            "fillOpacity": 100, "groupTransforms": []
        ]]]
        let o = setLayerZero(validPayloadObject(), to: layer)
        assertThrowsAny(o, "layer type/content mismatch") {
            if case .layerContentMismatch(_, let t, let c) = $0 { return t == 2 && c == "shapes" }; return false
        }
    }

    // MARK: - Numeric grammar at lexer (item 1)

    private func parseFails(_ json: String, _ message: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertThrowsError(try CompiledJSONParser.parse(Data(json.utf8)), message, file: file, line: line) {
            guard case .malformedJSON = ($0 as? CompiledTemplateDecodingError) else {
                return XCTFail("\(message) — expected malformedJSON, got \($0)", file: file, line: line)
            }
        }
    }

    func testNumberGrammarRejectsLeadingZero() { parseFails(#"{"x":01}"#, "leading zero") }
    func testNumberGrammarRejectsLeadingZeroFraction() { parseFails(#"{"x":01.2}"#, "01.2") }
    func testNumberGrammarRejectsBareTrailingPoint() { parseFails(#"{"x":1.}"#, "1.") }
    func testNumberGrammarRejectsPointBeforeExponent() { parseFails(#"{"x":1.e2}"#, "1.e2") }
    func testNumberGrammarRejectsLeadingPlus() { parseFails(#"{"x":+1}"#, "+1") }
    func testNumberGrammarRejectsLeadingPointWithSign() { parseFails(#"{"x":-.1}"#, "-.1") }
    func testNumberGrammarRejectsIncompleteExponent() { parseFails(#"{"x":1e}"#, "1e") }
    func testNumberGrammarRejectsIncompleteSignedExponent() { parseFails(#"{"x":1e+}"#, "1e+") }
    func testNumberGrammarRejectsTokenConcatenation() { parseFails(#"{"x":1.2.3}"#, "1.2.3") }
    func testNumberGrammarRejectsDoubleExponent() { parseFails(#"{"x":1e2e3}"#, "1e2e3") }

    func testNumberGrammarAcceptsCanonicalForms() throws {
        for token in ["0", "-0", "1", "-1", "150", "3.14", "-960", "1e2", "1E-3", "0.5", "12.0"] {
            let root = try CompiledJSONParser.parse(Data("{\"x\":\(token)}".utf8))
            guard case .object(let pairs) = root, case .number(let lexeme) = pairs[0].1 else {
                return XCTFail("token \(token) did not lex as number")
            }
            XCTAssertEqual(lexeme, token, "lexeme preserved verbatim")
        }
    }

    // MARK: - Duplicate identifiers

    func testDuplicateVariantIDRejected() {
        var block = blockZero(in: validPayloadObject())
        var variants = block["variants"] as! [Any]
        variants.append(variants[0])
        block["variants"] = variants
        let o = mutating(validPayloadObject(), "compiled.runtime.blocks.[0]", to: block)
        assertThrowsAny(o, "duplicate variant id") {
            if case .duplicateIdentifier(let k, let i, _) = $0 { return k == "variant" && i == "no-anim" }; return false
        }
    }

    func testDuplicateLayerIDRejected() {
        var comp = compZero(in: validPayloadObject())
        var layers = comp["layers"] as! [Any]
        layers.append(layers[0])
        comp["layers"] = layers
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].animIR.comps.comp_0", to: comp)
        assertThrowsAny(o, "duplicate layer id") {
            if case .duplicateIdentifier(let k, _, _) = $0 { return k == "layer" }; return false
        }
    }

    func testDuplicateBindingAssetIDRejected() {
        let o = mutating(validPayloadObject(), "compiled.bindingAssetIds",
                         to: ["anim.json|image_0", "anim.json|image_0"])
        assertThrowsAny(o, "duplicate binding asset id") {
            if case .duplicateIdentifier(let k, _, _) = $0 { return k == "bindingAssetId" }; return false
        }
    }

    func testDuplicateJSONKeyRejected() {
        let json = #"{"engineVersion":"x","engineVersion":"y","templateId":"t","templateRevision":1,"compiled":{}}"#
        XCTAssertThrowsError(try CompiledJSONParser.parse(Data(json.utf8))) {
            XCTAssertEqual($0 as? CompiledTemplateDecodingError, .duplicateKey(key: "engineVersion"))
        }
    }

    // MARK: - Reference validation

    func testSelectedVariantReferenceRejected() {
        let o = mutating(validPayloadObject(), "compiled.runtime.blocks.[0].selectedVariantId", to: "ghost")
        assertThrowsAny(o, "dangling selected variant") {
            if case .danglingReference(let k, let i, _) = $0 { return k == "selectedVariantId" && i == "ghost" }
            return false
        }
    }

    func testBindingAssetIDDoesNotResolveRejected() {
        let o = mutating(validPayloadObject(), "compiled.bindingAssetIds", to: ["not-in-index"])
        assertThrowsAny(o, "binding asset id resolves") {
            if case .danglingReference(let k, _, _) = $0 { return k == "bindingAssetId" }; return false
        }
    }

    func testBindingBaselineAssetReferenceRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].bindingBaseline.boundAssetId", to: "ghost-asset")
        assertThrowsAny(o, "bindingBaseline asset resolves") {
            if case .danglingReference(let k, _, _) = $0 { return k == "bindingBaseline.boundAssetId" }
            return false
        }
    }

    func testImageContentAssetReferenceRejected() {
        var layer = layerZero(in: validPayloadObject())
        layer["content"] = ["image": ["assetId": "ghost"]]
        let o = setLayerZero(validPayloadObject(), to: layer)
        assertThrowsAny(o, "image content asset resolves") {
            if case .danglingReference(let k, _, _) = $0 { return k == "content.image.assetId" }; return false
        }
    }

    func testBindingBoundAssetReferenceRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].animIR.binding.boundAssetId", to: "ghost")
        assertThrowsAny(o, "binding.boundAssetId resolves") {
            if case .danglingReference(let k, _, _) = $0 { return k == "binding.boundAssetId" }; return false
        }
    }

    func testBindingBoundCompReferenceRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].animIR.binding.boundCompId", to: "ghost")
        assertThrowsAny(o, "binding.boundCompId resolves") {
            if case .danglingReference(let k, _, _) = $0 { return k == "binding.boundCompId" }; return false
        }
    }

    func testBindingBoundLayerReferenceRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].animIR.binding.boundLayerId", to: 999)
        assertThrowsAny(o, "binding.boundLayerId resolves") {
            if case .danglingReference(let k, _, _) = $0 { return k == "binding.boundLayerId" }; return false
        }
    }

    func testMatteSourceLayerReferenceRejected() {
        var layer = layerZero(in: validPayloadObject())
        layer["matte"] = ["mode": 1, "sourceLayerId": 999]
        let o = setLayerZero(validPayloadObject(), to: layer)
        assertThrowsAny(o, "matte source layer resolves") {
            if case .danglingReference(let k, _, _) = $0 { return k == "matte.sourceLayerId" }; return false
        }
    }

    func testRootCompReferenceRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].animIR.rootComp", to: "ghost")
        assertThrowsAny(o, "rootComp resolves") {
            if case .danglingReference(let k, _, _) = $0 { return k == "rootComp" }; return false
        }
    }

    func testVariantBindingKeyRelationshipRejected() {
        // Runtime variant.bindingKey must equal scene input.bindingKey / AnimIR binding.bindingKey.
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].bindingKey", to: "other")
        assertThrowsAny(o, "variant bindingKey relationship") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("bindingKey") }; return false
        }
    }

    func testVariantAnimRefRelationshipRejected() {
        // Runtime variant.animRef must equal the scene variant's animRef.
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].animRef", to: "other.json")
        assertThrowsAny(o, "variant animRef relationship") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("animRef") }; return false
        }
    }

    func testInputGeometryLayerReferenceRejected() {
        // Add an inputGeometry that points at a non-existent layer.
        let bezier: [String: Any] = ["vertices": [], "inTangents": [], "outTangents": [], "closed": true]
        let ig: [String: Any] = [
            "layerId": 999, "pathId": ["value": 0], "compId": "comp_0",
            "animPath": ["staticBezier": ["_0": bezier]]
        ]
        var o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].variants.[0].animIR.inputGeometry", to: ig)
        o = mutating(o, "compiled.pathRegistry", to: ["paths": [[
            "pathId": ["value": 0], "keyframePositions": [[0.0, 0.0]], "keyframeTimes": [0.0],
            "indices": [0], "vertexCount": 1, "keyframeEasing": []
        ]]])
        assertThrowsAny(o, "inputGeometry layerId resolves") {
            if case .danglingReference(let k, _, _) = $0 { return k == "inputGeometry.layerId" }; return false
        }
    }

    func testMaskPathIDReferenceRejected() {
        // A mask referencing a pathId absent from the scene-level registry.
        var layer = layerZero(in: validPayloadObject())
        layer["masks"] = [[
            "mode": "a", "inverted": false, "opacity": 100, "pathId": ["value": 42],
            "path": ["staticBezier": ["_0": ["vertices": [], "inTangents": [], "outTangents": [], "closed": true]]]
        ]]
        let o = setLayerZero(validPayloadObject(), to: layer)
        assertThrowsAny(o, "mask pathId resolves") {
            if case .danglingReference(let k, let i, _) = $0 { return k == "pathId" && i == "42" }; return false
        }
    }

    func testShapePathIDReferenceRejected() {
        // shapeMatte layer with pathId 7, but registry only has pathId 0.
        let (layer, _) = shapeLayerAndRegistry(pathID: 7)
        var o = installShapeLayer(validPayloadObject(), layer: layer)
        o = mutating(o, "compiled.pathRegistry", to: ["paths": [[
            "pathId": ["value": 0], "keyframePositions": [[0.0, 0.0]], "keyframeTimes": [0.0],
            "indices": [0], "vertexCount": 1, "keyframeEasing": []
        ]]])
        assertThrowsAny(o, "shape pathId resolves") {
            if case .danglingReference(let k, let i, _) = $0 { return k == "pathId" && i == "7" }; return false
        }
    }

    func testSceneRuntimeBlockMismatchRejected() {
        // Rename the scene media block so it no longer matches the runtime block id.
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.scene.mediaBlocks.[0].blockId", to: "other_block")
        assertThrowsAny(o, "scene/runtime block bijection") {
            if case .danglingReference(let k, _, _) = $0 { return k == "sceneMediaBlockId" }; return false
        }
    }

    func testShapePathIDResolvesWhenRegistered() throws {
        // Positive: a shapeMatte layer whose pathId is in the registry decodes cleanly.
        let (layer, registry) = shapeLayerAndRegistry(pathID: 0)
        var o = installShapeLayer(validPayloadObject(), layer: layer)
        o = mutating(o, "compiled.pathRegistry", to: registry)
        let dto = try decode(o)
        let comp = dto.compiled.runtime.blocks[0].variants[0].animIR.comps[0]
        XCTAssertTrue(comp.layers.contains { $0.type == .shapeMatte })
    }

    // MARK: - Ambiguous unions / unsupported features

    func testAmbiguousContentUnionRejected() {
        var layer = layerZero(in: validPayloadObject())
        layer["content"] = ["image": ["assetId": "anim.json|image_0"], "none": [:]]
        let o = setLayerZero(validPayloadObject(), to: layer)
        assertThrowsAny(o, "two content keys") { if case .ambiguousUnion = $0 { return true }; return false }
    }

    func testEmptyContentUnionRejected() {
        var layer = layerZero(in: validPayloadObject())
        layer["content"] = [String: Any]()
        let o = setLayerZero(validPayloadObject(), to: layer)
        assertThrowsAny(o, "zero content keys") { if case .ambiguousUnion = $0 { return true }; return false }
    }

    func testAmbiguousValueTrackRejected() {
        var layer = layerZero(in: validPayloadObject())
        var transform = layer["transform"] as! [String: Any]
        transform["opacity"] = ["static": ["_0": 100], "keyframed": ["_0": []]]
        layer["transform"] = transform
        let o = setLayerZero(validPayloadObject(), to: layer)
        assertThrowsAny(o, "ambiguous value track") { if case .ambiguousUnion = $0 { return true }; return false }
    }

    func testMergedAssetIndexKeySetMismatchRejected() {
        let o = mutating(validPayloadObject(), "compiled.mergedAssetIndex.basenameById", to: ["other-key": "x"])
        assertThrowsAny(o, "merged asset index key sets differ") {
            if case .unsupportedCompiledFeature(_, let d) = $0 { return d.contains("key sets") }; return false
        }
    }

    func testBezierTangentCountMismatchRejected() {
        var layer = layerZero(in: validPayloadObject())
        layer["masks"] = [[
            "mode": "a", "inverted": false, "opacity": 100,
            "path": ["staticBezier": ["_0": [
                "vertices": [["x": 0, "y": 0], ["x": 1, "y": 1]],
                "inTangents": [["x": 0, "y": 0]],   // count mismatch
                "outTangents": [["x": 0, "y": 0], ["x": 0, "y": 0]],
                "closed": true
            ]]]
        ]]
        let o = setLayerZero(validPayloadObject(), to: layer)
        assertThrowsAny(o, "bezier tangent count mismatch") {
            if case .unsupportedCompiledFeature(_, let d) = $0 { return d.contains("tangent count") }; return false
        }
    }

    // MARK: - JSON-level malformity

    func testTrailingPayloadContentRejected() {
        XCTAssertThrowsError(try CompiledJSONParser.parse(Data(#"{"engineVersion":"x"} garbage"#.utf8))) {
            XCTAssertEqual($0 as? CompiledTemplateDecodingError, .trailingPayloadContent)
        }
    }

    func testNonUTF8PayloadRejected() {
        XCTAssertThrowsError(try CompiledJSONParser.parse(Data([0xff, 0xfe, 0xfd]))) {
            XCTAssertEqual($0 as? CompiledTemplateDecodingError, .payloadNotUTF8)
        }
    }

    func testIntegerFieldRejectsValidFloatToken() throws {
        // A grammatically-valid float token in an integer field is rejected at field-read time.
        let root = try CompiledJSONParser.parse(Data(#"{"x":1.5}"#.utf8))
        var r = try root.requireObject(path: "")
        XCTAssertThrowsError(try r.int("x")) {
            XCTAssertEqual($0 as? CompiledTemplateDecodingError, .malformedInteger(path: "x"))
        }
    }

    // MARK: - Real fixtures, end-to-end

    func testAllRealFixturesDecode() throws {
        for id in CompiledTemplateFixtureBytes.mandatoryIDs {
            let data = try CompiledTemplateFixtureBytes.bytes(id)
            let decoded = try CompiledTemplateDecoder.decode(data)
            XCTAssertEqual(decoded.envelope.schemaVersion, 2, "\(id) schema")
            XCTAssertFalse(decoded.payload.compiled.runtime.blocks.isEmpty, "\(id) has blocks")
            for block in decoded.payload.compiled.runtime.blocks {
                XCTAssertTrue(block.variants.contains { $0.variantID == block.selectedVariantID },
                              "\(id) \(block.blockID) selected variant resolves")
                for variant in block.variants {
                    XCTAssertFalse(variant.animIR.comps.isEmpty, "\(id) \(variant.variantID) has comps")
                }
            }
        }
    }

    func testRealFixtureDecodeIsDeterministic() throws {
        let data = try CompiledTemplateFixtureBytes.bytes("polaroid_2")
        XCTAssertEqual(try CompiledTemplateDecoder.decode(data), try CompiledTemplateDecoder.decode(data))
    }

    // MARK: - Nested-accessor helpers

    private func blockZero(in object: [String: Any]) -> [String: Any] {
        let compiled = object["compiled"] as! [String: Any]
        let runtime = compiled["runtime"] as! [String: Any]
        return (runtime["blocks"] as! [Any])[0] as! [String: Any]
    }

    private func compZero(in object: [String: Any]) -> [String: Any] {
        let variants = blockZero(in: object)["variants"] as! [Any]
        let animIR = (variants[0] as! [String: Any])["animIR"] as! [String: Any]
        return (animIR["comps"] as! [String: Any])["comp_0"] as! [String: Any]
    }

    private func layerZero(in object: [String: Any]) -> [String: Any] {
        (compZero(in: object)["layers"] as! [Any])[0] as! [String: Any]
    }

    private func setLayerZero(_ object: [String: Any], to layer: [String: Any]) -> [String: Any] {
        var comp = compZero(in: object)
        var layers = comp["layers"] as! [Any]
        layers[0] = layer
        comp["layers"] = layers
        return mutating(object, "compiled.runtime.blocks.[0].variants.[0].animIR.comps.comp_0", to: comp)
    }

    private func setLayerZero(_ object: [String: Any], key: String, to value: Any) -> [String: Any] {
        var layer = layerZero(in: object)
        layer[key] = value
        return setLayerZero(object, to: layer)
    }

    /// Appends `layer` (a shapeMatte source) to comp_0's layers.
    private func installShapeLayer(_ object: [String: Any], layer: [String: Any]) -> [String: Any] {
        var comp = compZero(in: object)
        var layers = comp["layers"] as! [Any]
        layers.append(layer)
        comp["layers"] = layers
        return mutating(object, "compiled.runtime.blocks.[0].variants.[0].animIR.comps.comp_0", to: comp)
    }

    /// Installs a `background` object onto the scene.
    private func installBackground(_ object: [String: Any], _ background: [String: Any]) -> [String: Any] {
        mutating(object, "compiled.runtime.scene.background", to: background)
    }

    private func validBackground() -> [String: Any] {
        [
            "type": "preset",
            "presetId": "p1",
            "defaults": [
                "region0": [
                    "sourceType": "gradient",
                    "gradientLinear": [
                        "stops": [["position": 0.0, "color": "#000000"], ["position": 1.0, "color": "#FFFFFF"]],
                        "p0": ["x": 0, "y": 0],
                        "p1": ["x": 100, "y": 100]
                    ]
                ]
            ]
        ]
    }

    /// Appends a toggle layer (with `toggleId`) to comp_0 and a matching scene `layerToggles` entry.
    private func installToggle(_ object: [String: Any], toggleLayerOverrides: [String: Any] = [:],
                               sceneToggleIDs: [String]) -> [String: Any] {
        let staticVec: ([String: Any]) -> [String: Any] = { ["static": ["_0": $0]] }
        let staticScalar: (Any) -> [String: Any] = { ["static": ["_0": $0]] }
        let transform: [String: Any] = [
            "position": staticVec(["x": 0, "y": 0]), "scale": staticVec(["x": 100, "y": 100]),
            "rotation": staticScalar(0), "opacity": staticScalar(100), "anchor": staticVec(["x": 0, "y": 0])
        ]
        var toggleLayer: [String: Any] = [
            "id": 50,
            "name": "toggle:frame",
            "type": 3,
            "timing": ["inPoint": 0.0, "outPoint": 150.0, "startTime": 0.0],
            "transform": transform,
            "masks": [],
            "content": ["none": [:]],
            "isMatteSource": false,
            "isHidden": false,
            "toggleId": "frame"
        ]
        for (k, v) in toggleLayerOverrides { toggleLayer[k] = v }
        var o = installShapeLayerNamed(object, layer: toggleLayer)
        // scene layerToggles
        let toggles = sceneToggleIDs.map { ["id": $0, "title": "T", "defaultOn": true] as [String: Any] }
        o = mutating(o, "compiled.runtime.scene.mediaBlocks.[0].layerToggles", to: toggles)
        return o
    }

    /// Appends an arbitrary layer to comp_0 (no shapeMatte assumption).
    private func installShapeLayerNamed(_ object: [String: Any], layer: [String: Any]) -> [String: Any] {
        installShapeLayer(object, layer: layer)
    }

    // MARK: - Background.defaults strict (item 1)

    func testValidBackgroundDecodes() throws {
        let dto = try decode(installBackground(validPayloadObject(), validBackground()))
        let region = dto.compiled.runtime.scene.background?.defaults?["region0"]
        XCTAssertEqual(region?.sourceType, "gradient")
        XCTAssertEqual(region?.gradientLinear?.stops.count, 2)
        XCTAssertEqual(region?.gradientLinear?.p1.x, 100)
    }

    func testUnknownFieldInBackgroundRejected() {
        var bg = validBackground(); bg["weird"] = 1
        assertThrowsAny(installBackground(validPayloadObject(), bg), "unknown field in Background") {
            if case .unknownField(_, let f) = $0 { return f == "weird" }; return false
        }
    }

    func testUnknownFieldInRegionDefaultRejected() {
        var bg = validBackground()
        var defaults = bg["defaults"] as! [String: Any]
        var region = defaults["region0"] as! [String: Any]
        region["weird"] = 1; defaults["region0"] = region; bg["defaults"] = defaults
        assertThrowsAny(installBackground(validPayloadObject(), bg), "unknown field in RegionDefault") {
            if case .unknownField(_, let f) = $0 { return f == "weird" }; return false
        }
    }

    func testUnknownFieldInGradientLinearRejected() {
        var bg = validBackground()
        var defaults = bg["defaults"] as! [String: Any]
        var region = defaults["region0"] as! [String: Any]
        var grad = region["gradientLinear"] as! [String: Any]
        grad["weird"] = 1; region["gradientLinear"] = grad; defaults["region0"] = region; bg["defaults"] = defaults
        assertThrowsAny(installBackground(validPayloadObject(), bg), "unknown field in GradientLinearDefault") {
            if case .unknownField(_, let f) = $0 { return f == "weird" }; return false
        }
    }

    func testUnknownFieldInGradientStopRejected() {
        var bg = validBackground()
        var defaults = bg["defaults"] as! [String: Any]
        var region = defaults["region0"] as! [String: Any]
        var grad = region["gradientLinear"] as! [String: Any]
        grad["stops"] = [["position": 0.0, "color": "#000000", "weird": 1]]
        region["gradientLinear"] = grad; defaults["region0"] = region; bg["defaults"] = defaults
        assertThrowsAny(installBackground(validPayloadObject(), bg), "unknown field in GradientStop") {
            if case .unknownField(_, let f) = $0 { return f == "weird" }; return false
        }
    }

    func testUnknownFieldInGradientVec2DRejected() {
        var bg = validBackground()
        var defaults = bg["defaults"] as! [String: Any]
        var region = defaults["region0"] as! [String: Any]
        var grad = region["gradientLinear"] as! [String: Any]
        grad["p0"] = ["x": 0, "y": 0, "z": 1]
        region["gradientLinear"] = grad; defaults["region0"] = region; bg["defaults"] = defaults
        assertThrowsAny(installBackground(validPayloadObject(), bg), "unknown field in gradient Vec2D") {
            if case .unknownField(_, let f) = $0 { return f == "z" }; return false
        }
    }

    func testWrongTypeInGradientStopRejected() {
        var bg = validBackground()
        var defaults = bg["defaults"] as! [String: Any]
        var region = defaults["region0"] as! [String: Any]
        var grad = region["gradientLinear"] as! [String: Any]
        grad["stops"] = [["position": "x", "color": "#000000"]]   // position must be number
        region["gradientLinear"] = grad; defaults["region0"] = region; bg["defaults"] = defaults
        assertThrowsAny(installBackground(validPayloadObject(), bg), "wrong type in GradientStop") {
            if case .wrongType(_, let e) = $0 { return e == "number" }; return false
        }
    }

    func testExplicitNullInRegionDefaultGradientRejected() {
        // gradientLinear is optional-absent; an explicit null is rejected.
        var bg = validBackground()
        var defaults = bg["defaults"] as! [String: Any]
        var region = defaults["region0"] as! [String: Any]
        region["gradientLinear"] = NSNull(); defaults["region0"] = region; bg["defaults"] = defaults
        assertThrowsAny(installBackground(validPayloadObject(), bg), "explicit null in RegionDefault") {
            if case .explicitNull = $0 { return true }; return false
        }
    }

    // MARK: - Scene ↔ runtime consistency (item 2)

    func testRuntimeCanvasMismatchRejected() {
        let o = mutating(validPayloadObject(), "compiled.runtime.canvas.width", to: 999)
        assertThrowsAny(o, "runtime.canvas != scene.canvas") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("canvas") }; return false
        }
    }

    func testRuntimeFpsMismatchRejected() {
        let o = mutating(validPayloadObject(), "compiled.runtime.fps", to: 60)
        assertThrowsAny(o, "runtime.fps != scene.canvas.fps") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("fps") }; return false
        }
    }

    func testRuntimeDurationMismatchRejected() {
        let o = mutating(validPayloadObject(), "compiled.runtime.durationFrames", to: 999)
        assertThrowsAny(o, "runtime.duration != scene.canvas.duration") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("durationFrames") }; return false
        }
    }

    func testVariantIDSetMismatchRejected() {
        // Add a runtime-only variant (anim-1) without a matching scene variant → id sets differ.
        // Keep selectedVariantId/editVariantId valid ("no-anim") so the id-set check is what fires.
        var runtimeVariants = blockZero(in: validPayloadObject())["variants"] as! [Any]
        var extra = runtimeVariants[0] as! [String: Any]
        extra["variantId"] = "anim-1"; extra["animRef"] = "anim-1.json"
        var animIR = extra["animIR"] as! [String: Any]
        var meta = animIR["meta"] as! [String: Any]; meta["sourceAnimRef"] = "anim-1.json"; animIR["meta"] = meta
        extra["animIR"] = animIR
        runtimeVariants.append(extra)
        var block = blockZero(in: validPayloadObject()); block["variants"] = runtimeVariants
        let o = mutating(validPayloadObject(), "compiled.runtime.blocks.[0]", to: block)
        assertThrowsAny(o, "variant id set mismatch") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("variant id sets") }; return false
        }
    }

    func testSelectedVariantNotFirstSceneVariantRejected() {
        // Two variants where selected is not the first authored scene variant.
        var o = installSecondVariant(validPayloadObject())
        o = mutating(o, "compiled.runtime.blocks.[0].selectedVariantId", to: "anim-1")
        assertThrowsAny(o, "selected != first scene variant") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("first scene variant") }; return false
        }
    }

    func testEditVariantNotNoAnimRejected() {
        var o = installSecondVariant(validPayloadObject())
        o = mutating(o, "compiled.runtime.blocks.[0].editVariantId", to: "anim-1")
        assertThrowsAny(o, "edit != no-anim") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("no-anim") }; return false
        }
    }

    func testOrderIndexMismatchRejected() {
        let o = mutating(validPayloadObject(), "compiled.runtime.blocks.[0].orderIndex", to: 5)
        assertThrowsAny(o, "orderIndex mismatch") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("orderIndex") }; return false
        }
    }

    func testZIndexMirrorMismatchRejected() {
        let o = mutating(validPayloadObject(), "compiled.runtime.blocks.[0].zIndex", to: 7)
        assertThrowsAny(o, "zIndex mirror mismatch") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("zIndex") }; return false
        }
    }

    func testRectMirrorMismatchRejected() {
        let o = mutating(validPayloadObject(),
                         "compiled.runtime.blocks.[0].rectCanvas.width", to: 500)
        assertThrowsAny(o, "rect mirror mismatch") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("rectCanvas") }; return false
        }
    }

    func testContainerClipMirrorMismatchRejected() {
        // Change runtime block containerClip to a different valid enum value.
        let o = mutating(validPayloadObject(), "compiled.runtime.blocks.[0].containerClip", to: "slotRect")
        assertThrowsAny(o, "containerClip mirror mismatch") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("containerClip") }; return false
        }
    }

    func testHitTestMirrorMismatchRejected() {
        // Runtime hitTestMode rect, scene input.hitTest mask.
        let o = mutating(validPayloadObject(), "compiled.runtime.blocks.[0].hitTestMode", to: "rect")
        assertThrowsAny(o, "hitTest mirror mismatch") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("hitTestMode") }; return false
        }
    }

    func testTimingMirrorMismatchRejected() {
        let o = mutating(validPayloadObject(), "compiled.runtime.blocks.[0].timing.endFrame", to: 99)
        assertThrowsAny(o, "timing mirror mismatch") {
            if case .sceneRuntimeInconsistency(_, let d) = $0 { return d.contains("timing") }; return false
        }
    }

    func testTimingDefaultFromSceneDurationAccepted() throws {
        // Scene block omits timing → runtime timing must equal (0, scene.canvas.durationFrames).
        var o = mutating(validPayloadObject(), "compiled.runtime.scene.mediaBlocks.[0].timing", to: nil)
        o = mutating(o, "compiled.runtime.blocks.[0].timing", to: ["startFrame": 0, "endFrame": 150])
        XCTAssertNoThrow(try decode(o))
    }

    // MARK: - Layer toggles (item 3)

    func testValidTogglesDecode() throws {
        let o = installToggle(validPayloadObject(), sceneToggleIDs: ["frame"])
        XCTAssertNoThrow(try decode(o))
    }

    func testToggleSetMismatchRejected() {
        // AnimIR has toggle "frame" but scene declares a different id.
        let o = installToggle(validPayloadObject(), sceneToggleIDs: ["other"])
        assertThrowsAny(o, "toggle set mismatch") {
            if case .layerToggleViolation(_, let d) = $0 { return d.contains("toggle ids") }; return false
        }
    }

    func testToggleMissingSceneIdRejected() {
        var o = installToggle(validPayloadObject(), sceneToggleIDs: ["frame"])
        o = mutating(o, "compiled.runtime.scene.sceneId", to: nil)   // no sceneId while toggles exist
        assertThrowsAny(o, "toggle requires sceneId") {
            if case .layerToggleViolation(_, let d) = $0 { return d.contains("sceneId") }; return false
        }
    }

    func testToggleEmptySceneIdRejected() {
        var o = installToggle(validPayloadObject(), sceneToggleIDs: ["frame"])
        o = mutating(o, "compiled.runtime.scene.sceneId", to: "")
        assertThrowsAny(o, "toggle requires non-empty sceneId") {
            if case .layerToggleViolation(_, let d) = $0 { return d.contains("sceneId") }; return false
        }
    }

    func testToggleLayerAsMatteSourceRejected() {
        let o = installToggle(validPayloadObject(),
                              toggleLayerOverrides: ["isMatteSource": true], sceneToggleIDs: ["frame"])
        assertThrowsAny(o, "toggle layer is matte source") {
            if case .layerToggleViolation(_, let d) = $0 { return d.contains("matte source") }; return false
        }
    }

    func testToggleLayerAsMatteConsumerRejected() {
        let o = installToggle(validPayloadObject(),
                              toggleLayerOverrides: ["matte": ["mode": 1, "sourceLayerId": 1]],
                              sceneToggleIDs: ["frame"])
        assertThrowsAny(o, "toggle layer is matte consumer") {
            if case .layerToggleViolation(_, let d) = $0 { return d.contains("matte consumer") }; return false
        }
    }

    func testToggleLayerAsParentRejected() {
        // Make the image layer (id 1) parent onto the toggle layer (id 50).
        var o = installToggle(validPayloadObject(), sceneToggleIDs: ["frame"])
        var layer = layerZero(in: o)   // image layer id 1
        layer["parent"] = 50
        o = setLayerZero(o, to: layer)
        assertThrowsAny(o, "toggle layer is parent") {
            if case .layerToggleViolation(_, let d) = $0 { return d.contains("parents onto toggle") }; return false
        }
    }

    func testDuplicateToggleIDInAnimRejected() {
        // Two layers carrying toggleId "frame" inside the same AnimIR.
        var o = installToggle(validPayloadObject(), sceneToggleIDs: ["frame"])
        let staticVec: ([String: Any]) -> [String: Any] = { ["static": ["_0": $0]] }
        let staticScalar: (Any) -> [String: Any] = { ["static": ["_0": $0]] }
        let transform: [String: Any] = [
            "position": staticVec(["x": 0, "y": 0]), "scale": staticVec(["x": 100, "y": 100]),
            "rotation": staticScalar(0), "opacity": staticScalar(100), "anchor": staticVec(["x": 0, "y": 0])
        ]
        let dupToggle: [String: Any] = [
            "id": 51, "name": "toggle:frame", "type": 3,
            "timing": ["inPoint": 0.0, "outPoint": 150.0, "startTime": 0.0],
            "transform": transform, "masks": [], "content": ["none": [:]],
            "isMatteSource": false, "isHidden": false, "toggleId": "frame"
        ]
        o = installShapeLayer(o, layer: dupToggle)
        assertThrowsAny(o, "duplicate toggle id in anim") {
            if case .layerToggleViolation(_, let d) = $0 { return d.contains("duplicate toggleId") }; return false
        }
    }

    // MARK: - bindingAssetIds exact set (item 4)

    func testBindingAssetIDsExtraRejected() {
        // Declared id that is never a binding boundAssetId, yet exists in merged index.
        var o = validPayloadObject()
        // add a second merged asset and declare it as binding (extra).
        let assets: [String: Any] = [
            "byId": ["anim.json|image_0": "img0", "extra|a": "x"],
            "sizeById": ["anim.json|image_0": ["width": 1080.0, "height": 1920.0], "extra|a": ["width": 1.0, "height": 1.0]],
            "basenameById": ["anim.json|image_0": "img0", "extra|a": "x"]
        ]
        o = mutating(o, "compiled.mergedAssetIndex", to: assets)
        o = mutating(o, "compiled.bindingAssetIds", to: ["anim.json|image_0", "extra|a"])
        assertThrowsAny(o, "extra binding asset id") {
            if case .bindingAssetSetMismatch(_, let extra, _) = $0 { return extra == ["extra|a"] }; return false
        }
    }

    func testBindingAssetIDsMissingRejected() {
        // Remove the genuine binding id from bindingAssetIds (missing).
        let o = mutating(validPayloadObject(), "compiled.bindingAssetIds", to: [String]())
        assertThrowsAny(o, "missing binding asset id") {
            if case .bindingAssetSetMismatch(let missing, _, _) = $0 { return missing == ["anim.json|image_0"] }
            return false
        }
    }

    // MARK: - Multi-variant helper

    /// Adds an `anim-1` second variant to block 0 in both the runtime and the scene, sharing the
    /// same binding asset (so the bindingAssetIds set stays exact). Keeps `no-anim` first.
    private func installSecondVariant(_ object: [String: Any]) -> [String: Any] {
        var o = object
        // runtime: clone variant 0, change ids/animRef.
        var runtimeVariants = blockZero(in: o)["variants"] as! [Any]
        var second = runtimeVariants[0] as! [String: Any]
        second["variantId"] = "anim-1"
        second["animRef"] = "anim-1.json"
        var animIR = second["animIR"] as! [String: Any]
        var meta = animIR["meta"] as! [String: Any]
        meta["sourceAnimRef"] = "anim-1.json"; animIR["meta"] = meta
        second["animIR"] = animIR
        runtimeVariants.append(second)
        var block = blockZero(in: o); block["variants"] = runtimeVariants
        o = mutating(o, "compiled.runtime.blocks.[0]", to: block)
        // scene: append matching scene variant.
        var sceneVariants = (sceneBlockZero(in: o)["variants"] as! [Any])
        sceneVariants.append(["variantId": "anim-1", "animRef": "anim-1.json",
                              "defaultDurationFrames": 150, "ifAnimationShorter": "holdLastFrame",
                              "ifAnimationLonger": "cut", "loop": false])
        o = mutating(o, "compiled.runtime.scene.mediaBlocks.[0].variants", to: sceneVariants)
        return o
    }

    private func sceneBlockZero(in object: [String: Any]) -> [String: Any] {
        let compiled = object["compiled"] as! [String: Any]
        let runtime = compiled["runtime"] as! [String: Any]
        let scene = runtime["scene"] as! [String: Any]
        return (scene["mediaBlocks"] as! [Any])[0] as! [String: Any]
    }
}
