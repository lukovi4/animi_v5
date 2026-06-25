import XCTest
import Foundation
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Slice 001 — Stage A schema-v3 migration tests (plan §9, §10 Stage A).
///
/// Proves the empty `audio` round-trips, the encoder always writes v3 with an explicit `"audio"`
/// object, v1/v2 documents uplift to `audio == .empty`, a v1/v2 document carrying `"audio"` is
/// rejected, and a v3 document missing `"audio"` (or one of its three tables) is rejected.
final class AudioSchemaMigrationTests: XCTestCase {

    private func sampleDocument() throws -> CanonicalProjectDocument {
        let scene = try CanonicalProjectFixtures.scene(
            withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: 240_000
        )
        return try CanonicalProjectFixtures.singleSceneDocument(
            payload: scene, nominalDurationTicks: 240_000
        )
    }

    /// v3 with empty audio: encode → decode → encode is byte-identical and the canonical empty audio
    /// object is present (`{"clips":[],"sources":[],"tracks":[]}`, keys sorted by the writer).
    func testV3EmptyRoundTrip() throws {
        let document = try sampleDocument()
        let bytes1 = try CanonicalProjectEncoding.encode(document)
        let decoded = try CanonicalProjectEncoding.decodeValidated(bytes1)
        let bytes2 = try CanonicalProjectEncoding.encode(decoded)
        XCTAssertEqual(bytes1, bytes2, "v3 empty-audio round trip must be byte-stable")
        XCTAssertEqual(decoded.manifest.audio, .empty)
        let text = String(decoding: bytes1, as: UTF8.self)
        XCTAssertTrue(text.contains("\"audio\":{\"clips\":[],\"sources\":[],\"tracks\":[]}"),
                      "encoder emits the explicit empty audio object with sorted keys")
    }

    /// The encoder always writes the current schema header (v3), regardless of the in-memory version.
    func testEncoderAlwaysWritesV3() throws {
        let document = try sampleDocument()
        let text = String(decoding: try CanonicalProjectEncoding.encode(document), as: UTF8.self)
        XCTAssertTrue(text.contains("\"schemaVersion\":3"))
    }

    /// A v1 document (no `timelineSpan`, no `audio`) uplifts to `audio == .empty` and re-encodes as v3.
    func testV1UpliftToEmptyV3() throws {
        let v1text = try syntheticV1Text()
        let decoded = try CanonicalProjectEncoding.decodeValidated(Data(v1text.utf8))
        XCTAssertEqual(decoded.manifest.audio, .empty, "v1 uplift → empty audio")
        XCTAssertEqual(decoded.manifest.schemaVersion, 3, "v1 normalizes to v3 in memory")
        let reencoded = String(decoding: try CanonicalProjectEncoding.encode(decoded), as: UTF8.self)
        XCTAssertTrue(reencoded.contains("\"schemaVersion\":3"))
        XCTAssertTrue(reencoded.contains("\"audio\":{\"clips\":[],\"sources\":[],\"tracks\":[]}"))
    }

    /// A v2 document (with `timelineSpan`, no `audio`) uplifts to `audio == .empty` and re-encodes v3.
    func testV2UpliftToEmptyV3() throws {
        let v2text = try syntheticV2Text()
        let decoded = try CanonicalProjectEncoding.decodeValidated(Data(v2text.utf8))
        XCTAssertEqual(decoded.manifest.audio, .empty, "v2 uplift → empty audio")
        XCTAssertEqual(decoded.manifest.schemaVersion, 3, "v2 normalizes to v3 in memory")
        let reencoded = String(decoding: try CanonicalProjectEncoding.encode(decoded), as: UTF8.self)
        XCTAssertTrue(reencoded.contains("\"schemaVersion\":3"))
        XCTAssertTrue(reencoded.contains("\"audio\":{\"clips\":[],\"sources\":[],\"tracks\":[]}"))
    }

    /// A v3 document missing the entire `"audio"` object is rejected as a typed `missingField`.
    func testV3MissingAudioRejected() throws {
        let v3text = String(decoding: try CanonicalProjectEncoding.encode(try sampleDocument()), as: UTF8.self)
        let stripped = v3text.replacingOccurrences(of: "\"audio\":{\"clips\":[],\"sources\":[],\"tracks\":[]},", with: "")
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(stripped.utf8))) { error in
            guard case .decoding(let d) = error as? ProjectLoadError, case .missingField = d else {
                return XCTFail("expected decoding .missingField, got \(error)")
            }
        }
    }

    /// A v3 document whose `"audio"` object is missing one of the three required tables is rejected.
    func testV3MissingOneTableRejected() throws {
        let v3text = String(decoding: try CanonicalProjectEncoding.encode(try sampleDocument()), as: UTF8.self)
        // Drop the `tracks` table from the empty audio object.
        let stripped = v3text.replacingOccurrences(
            of: "\"audio\":{\"clips\":[],\"sources\":[],\"tracks\":[]}",
            with: "\"audio\":{\"clips\":[],\"sources\":[]}"
        )
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(stripped.utf8))) { error in
            guard case .decoding(let d) = error as? ProjectLoadError, case .missingField = d else {
                return XCTFail("expected decoding .missingField, got \(error)")
            }
        }
    }

    /// A v1 document carrying an `"audio"` key is rejected as an unknown field (v1/v2 must not carry audio).
    func testV1WithAudioRejected() throws {
        // Take a v1 document and inject an empty `"audio"` object into the manifest.
        let v1text = try syntheticV1Text()
            .replacingOccurrences(of: "\"boundaryTransitions\":[]",
                                   with: "\"audio\":{\"clips\":[],\"sources\":[],\"tracks\":[]},\"boundaryTransitions\":[]")
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(v1text.utf8))) { error in
            guard case .decoding(let d) = error as? ProjectLoadError, case .unknownField = d else {
                return XCTFail("expected decoding .unknownField, got \(error)")
            }
        }
    }

    /// A v2 document carrying an `"audio"` key is rejected as an unknown field.
    func testV2WithAudioRejected() throws {
        let v2text = try syntheticV2Text()
            .replacingOccurrences(of: "\"boundaryTransitions\":[]",
                                   with: "\"audio\":{\"clips\":[],\"sources\":[],\"tracks\":[]},\"boundaryTransitions\":[]")
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(v2text.utf8))) { error in
            guard case .decoding(let d) = error as? ProjectLoadError, case .unknownField = d else {
                return XCTFail("expected decoding .unknownField, got \(error)")
            }
        }
    }

    // MARK: - Stage C: a non-empty table goes through strict entry decoding

    /// A malformed (empty-object) element in a table goes through strict entry decoding and fails as a
    /// typed `missingField` (the entry requires an `id`). Proves the populated path is active.
    func testEmptyEntryInSourcesRejectedAsMissingField() throws {
        try assertEmptyEntryRejectedAsMissingField(table: "sources")
    }

    func testEmptyEntryInTracksRejectedAsMissingField() throws {
        try assertEmptyEntryRejectedAsMissingField(table: "tracks")
    }

    func testEmptyEntryInClipsRejectedAsMissingField() throws {
        try assertEmptyEntryRejectedAsMissingField(table: "clips")
    }

    /// Injects an empty object into one audio table; the entry decoder rejects it as `missingField`.
    private func assertEmptyEntryRejectedAsMissingField(table: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let v3text = String(decoding: try CanonicalProjectEncoding.encode(try sampleDocument()), as: UTF8.self)
        let injected = v3text.replacingOccurrences(of: "\"\(table)\":[]", with: "\"\(table)\":[{}]")
        XCTAssertNotEqual(injected, v3text, "test setup: \(table) array should have been mutated", file: file, line: line)
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(injected.utf8)), file: file, line: line) { error in
            guard case .decoding(let d) = error as? ProjectLoadError, case .missingField = d else {
                return XCTFail("expected decoding .missingField, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - Helpers

    /// A synthetic v1 on-disk document: drop `timelineSpan` + `audio`, set schemaVersion:1.
    private func syntheticV1Text() throws -> String {
        let v3text = String(decoding: try CanonicalProjectEncoding.encode(try sampleDocument()), as: UTF8.self)
        return v3text
            .replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":1")
            .replacingOccurrences(of: ",\"timelineSpan\":240000", with: "")
            .replacingOccurrences(of: "\"audio\":{\"clips\":[],\"sources\":[],\"tracks\":[]},", with: "")
    }

    /// A synthetic v2 on-disk document: keep `timelineSpan`, drop `audio`, set schemaVersion:2.
    private func syntheticV2Text() throws -> String {
        let v3text = String(decoding: try CanonicalProjectEncoding.encode(try sampleDocument()), as: UTF8.self)
        return v3text
            .replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":2")
            .replacingOccurrences(of: "\"audio\":{\"clips\":[],\"sources\":[],\"tracks\":[]},", with: "")
    }
}
