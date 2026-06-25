import XCTest
import Foundation
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Canonical persistence tests (Task-002 plan, §18 "Persistence").
final class CanonicalProjectEncodingTests: XCTestCase {

    private func sampleDocument() throws -> CanonicalProjectDocument {
        let scene = try CanonicalProjectFixtures.scene(
            withVideoLayers: 2, sceneID: "sceneA", payloadID: "payloadA", durationTicks: 720_000
        )
        return try CanonicalProjectFixtures.singleSceneDocument(
            payload: scene, nominalDurationTicks: 720_000
        )
    }

    func testByteStableRoundTrip() throws {
        let document = try sampleDocument()
        let bytes1 = try CanonicalProjectEncoding.encode(document)
        let decoded = try CanonicalProjectEncoding.decodeValidated(bytes1)
        let bytes2 = try CanonicalProjectEncoding.encode(decoded)
        XCTAssertEqual(bytes1, bytes2, "encode → decodeValidated → encode must be byte-stable")
        XCTAssertEqual(document, decoded)
    }

    func testSortedKeysInOutput() throws {
        let document = try sampleDocument()
        let bytes = try CanonicalProjectEncoding.encode(document)
        let text = String(decoding: bytes, as: UTF8.self)
        // The top-level object keys must be sorted: manifest < overlayPayloads < scenePayloads.
        let manifestIdx = text.range(of: "\"manifest\"")!.lowerBound
        let overlayIdx = text.range(of: "\"overlayPayloads\"")!.lowerBound
        let sceneIdx = text.range(of: "\"scenePayloads\"")!.lowerBound
        XCTAssertTrue(manifestIdx < overlayIdx)
        XCTAssertTrue(overlayIdx < sceneIdx)
    }

    func testUnknownFieldsRejectedAtEveryDepth() throws {
        let bytes = try CanonicalProjectEncoding.encode(try sampleDocument())
        var text = String(decoding: bytes, as: UTF8.self)
        // Inject an unknown field deep inside the first scene layer object.
        text = text.replacingOccurrences(of: "\"zIndex\":0", with: "\"zIndex\":0,\"bogus\":1", options: [], range: text.range(of: "\"zIndex\":0"))
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(text.utf8))) { error in
            guard case .decoding(let decodingError) = error as? ProjectLoadError,
                  case .unknownField = decodingError else {
                return XCTFail("expected unknownField, got \(error)")
            }
        }
    }

    func testDuplicateJSONKeysRejected() throws {
        let json = "{\"manifest\":{},\"manifest\":{}}"
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(json.utf8))) { error in
            guard case .decoding(let decodingError) = error as? ProjectLoadError,
                  case .duplicateKey = decodingError else {
                return XCTFail("expected duplicateKey, got \(error)")
            }
        }
    }

    func testEnumTagsPinnedGolden() throws {
        // A cut transition encodes its kind tag exactly as "cut"; animated as "animated".
        let sceneA = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "a", payloadID: "pa", durationTicks: 240_000)
        let sceneB = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "b", payloadID: "pb", durationTicks: 240_000)
        let doc = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: sceneA, sceneB: sceneB, durationATicks: 240_000, durationBTicks: 240_000,
            transition: try CanonicalProjectFixtures.fadeTransition(durationTicks: 120_000), postRollTicks: 120_000
        )
        let text = String(decoding: try CanonicalProjectEncoding.encode(doc), as: UTF8.self)
        XCTAssertTrue(text.contains("\"kind\":\"animated\""))
        XCTAssertTrue(text.contains("\"effectID\":\"fade\""))

        // Animation policy tags are pinned too; build a payload that carries an animation.
        let layer = try CanonicalProjectFixtures.videoLayer(
            id: "a.anim", zIndex: 0, stableOrdinal: 0, sceneDurationTicks: 240_000,
            media: "m", trimSeconds: 600,
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 100, height: 100),
            animation: try CanonicalProjectFixtures.holdLastAnimation(authoredTicks: 240_000)
        )
        let animScene = ResolvedScenePayload(
            payloadID: try ScenePayloadID("animPayload"), sceneID: try SceneInstanceID("animScene"),
            templateRef: try TemplateReference(catalogID: "c", sceneID: "s"), layers: [layer]
        )
        let animDoc = try CanonicalProjectFixtures.singleSceneDocument(payload: animScene, nominalDurationTicks: 240_000)
        let animText = String(decoding: try CanonicalProjectEncoding.encode(animDoc), as: UTF8.self)
        XCTAssertTrue(animText.contains("\"ifShorter\":\"holdLast\""))
        XCTAssertTrue(animText.contains("\"ifLonger\":\"cutAtEvaluationEnd\""))
    }

    func testTransitionParameterKeysSorted() throws {
        // Build a slide with a single direction parameter; ensure encoding is deterministic & sorted.
        let sceneA = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "a", payloadID: "pa", durationTicks: 240_000)
        let sceneB = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "b", payloadID: "pb", durationTicks: 240_000)
        let doc = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: sceneA, sceneB: sceneB, durationATicks: 240_000, durationBTicks: 240_000,
            transition: try CanonicalProjectFixtures.slideTransition(direction: "left", durationTicks: 120_000),
            postRollTicks: 120_000
        )
        let bytes1 = try CanonicalProjectEncoding.encode(doc)
        let bytes2 = try CanonicalProjectEncoding.encode(try CanonicalProjectEncoding.decodeValidated(bytes1))
        XCTAssertEqual(bytes1, bytes2)
        let text = String(decoding: bytes1, as: UTF8.self)
        XCTAssertTrue(text.contains("\"direction\""))
    }

    func testDecodingAndValidationErrorsRemainDistinct() throws {
        // Malformed JSON → decoding error.
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data("{not json".utf8))) { error in
            guard case .decoding = error as? ProjectLoadError else { return XCTFail("expected decoding") }
        }
        // Well-formed but semantically invalid (empty project) → validation error.
        let emptyManifestJSON = """
        {"manifest":{"schemaVersion":1,"output":{"canvas":{"width":1080,"height":1920},"frameRate":{"numerator":30,"denominator":1}},"scenes":[],"boundaryTransitions":[],"overlays":[]},"scenePayloads":[],"overlayPayloads":[]}
        """
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(emptyManifestJSON.utf8))) { error in
            guard case .validation(let v) = error as? ProjectLoadError, v == .emptyProject else {
                return XCTFail("expected validation .emptyProject, got \(error)")
            }
        }
    }

    func testMalformedIntegerRejected() throws {
        let bytes = try CanonicalProjectEncoding.encode(try sampleDocument())
        var text = String(decoding: bytes, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":3.5")
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(text.utf8))) { error in
            guard case .decoding(let d) = error as? ProjectLoadError, case .malformedInteger = d else {
                return XCTFail("expected malformedInteger, got \(error)")
            }
        }
    }

    func testIntegerFormattingHasNoTrailingDecimalOrExponent() throws {
        let text = String(decoding: try CanonicalProjectEncoding.encode(try sampleDocument()), as: UTF8.self)
        XCTAssertFalse(text.contains(".0"))
        XCTAssertFalse(text.lowercased().contains("e+"))
    }

    // MARK: - C-5: encode validates first

    func testEncodeRejectsSemanticallyInvalidDocument() throws {
        // Empty-scene document is well-formed structurally but semantically invalid.
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [], boundaryTransitions: [], overlays: []
        )
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [], overlayPayloads: [])
        XCTAssertThrowsError(try CanonicalProjectEncoding.encode(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .emptyProject)
        }
    }

    func testEncodeDecodeSymmetryStillByteStableForValidDocuments() throws {
        let document = try sampleDocument()
        let b1 = try CanonicalProjectEncoding.encode(document)
        let b2 = try CanonicalProjectEncoding.encode(try CanonicalProjectEncoding.decodeValidated(b1))
        XCTAssertEqual(b1, b2)
    }

    func testUnsupportedSchemaVersionRejectedOnEncodeAndDecode() throws {
        // Slice 001: v3 is now the supported/written version; v1/v2 are accepted (uplifted). An
        // UNSUPPORTED version (4) must still be rejected on both encode (validate) and decode.
        let scene = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: 240_000)
        let manifest = CanonicalProjectManifest(
            schemaVersion: 4, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: scene.sceneID, payloadID: scene.payloadID, nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)],
            boundaryTransitions: [], overlays: []
        )
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [scene], overlayPayloads: [])
        XCTAssertThrowsError(try CanonicalProjectEncoding.encode(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .unsupportedSchemaVersion(found: 4, supported: 3))
        }
        // For decode: take a valid v3 document's bytes and bump the schema number to 4.
        let validDoc = try CanonicalProjectFixtures.singleSceneDocument(payload: scene, nominalDurationTicks: 240_000)
        let bytes = try CanonicalProjectEncoding.encode(validDoc)
        let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":4")
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(text.utf8))) { error in
            guard case .validation(let v) = error as? ProjectLoadError, v == .unsupportedSchemaVersion(found: 4, supported: 3) else {
                return XCTFail("expected validation unsupportedSchemaVersion, got \(error)")
            }
        }
    }

    // CP7.5 / Slice 001: a v1 document (no `timelineSpan`, no `audio` key) decodes with
    // timelineSpan == nominalDuration and audio == .empty, normalized in memory to v3.
    func testV1DocumentDecodesWithTimelineSpanEqualNominal() throws {
        let scene = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: 240_000)
        let validDoc = try CanonicalProjectFixtures.singleSceneDocument(payload: scene, nominalDurationTicks: 240_000)
        // Synthesize a v1 on-disk document: drop the timelineSpan + audio keys + set schemaVersion:1.
        let v3text = String(decoding: try CanonicalProjectEncoding.encode(validDoc), as: UTF8.self)
        let v1text = v3text
            .replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":1")
            .replacingOccurrences(of: ",\"timelineSpan\":240000", with: "")
            .replacingOccurrences(of: "\"audio\":{\"clips\":[],\"sources\":[],\"tracks\":[]},", with: "")
        let decoded = try CanonicalProjectEncoding.decodeValidated(Data(v1text.utf8))
        XCTAssertEqual(decoded.manifest.scenes[0].timelineSpan, try TickDuration(ticks: 240_000),
                       "v1 uplift: timelineSpan defaults to nominalDuration")
        XCTAssertEqual(decoded.manifest.audio, .empty, "v1 uplift: audio defaults to .empty")
        XCTAssertEqual(decoded.manifest.schemaVersion, 3, "decode normalizes to v3 in memory")
    }
}
