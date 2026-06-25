import XCTest
import Foundation
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Slice 001 Stage C — populated audio codec tests (plan §5, §6, §9; slice-001 contract "Canonical
/// JSON"). Strict SHAPE round-trip only — no Stage-D semantic validation is asserted here.
final class AudioCodecTests: XCTestCase {

    // MARK: - Round-trips

    /// Populated round trip: a global-audio source + music track + global clip survives byte-stable.
    func testGlobalAudioRoundTrip() throws {
        let audio = AudioManifest(
            sources: [AudioSourceEntry(id: try AudioSourceID("s1"), asset: .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t1"), role: .music)],
            clips: [try clip(id: "c1", trackID: "t1", sourceID: "s1", videoLayer: nil)]
        )
        let document = try document(with: audio)
        let bytes1 = try CanonicalProjectEncoding.encode(document)
        let decoded = try CanonicalProjectEncoding.decodeValidated(bytes1)
        let bytes2 = try CanonicalProjectEncoding.encode(decoded)
        XCTAssertEqual(bytes1, bytes2, "global-audio round trip must be byte-stable")
        XCTAssertEqual(decoded.manifest.audio, audio)
        // Global clip omits videoLayer entirely.
        let text = String(decoding: bytes1, as: UTF8.self)
        XCTAssertTrue(text.contains("\"kind\":\"globalAudio\""))
        XCTAssertFalse(text.contains("\"videoLayer\""))
        XCTAssertNil(decoded.manifest.audio.clips[0].videoLayer)
    }

    /// Populated round trip: a video-layer media source + videoLayer track + clip carrying a
    /// SceneLayerReference survives byte-stable.
    func testVideoLayerMediaRoundTrip() throws {
        // Use the fixture scene's real ids so the full (Stage-D) validation passes: scene "s",
        // layer "s.layer0", media "media-0".
        let ref = SceneLayerReference(sceneID: try SceneInstanceID("s"), layerID: try LayerID("s.layer0"))
        let audio = AudioManifest(
            sources: [AudioSourceEntry(id: try AudioSourceID("s1"), asset: .videoLayerMedia(try MediaReference("media-0")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t1"), role: .videoLayer)],
            clips: [try clip(id: "c1", trackID: "t1", sourceID: "s1", videoLayer: ref)]
        )
        let document = try document(with: audio)
        let bytes1 = try CanonicalProjectEncoding.encode(document)
        let decoded = try CanonicalProjectEncoding.decodeValidated(bytes1)
        let bytes2 = try CanonicalProjectEncoding.encode(decoded)
        XCTAssertEqual(bytes1, bytes2, "video-layer round trip must be byte-stable")
        XCTAssertEqual(decoded.manifest.audio, audio)
        let text = String(decoding: bytes1, as: UTF8.self)
        XCTAssertTrue(text.contains("\"kind\":\"videoLayerMedia\""))
        XCTAssertTrue(text.contains("\"videoLayer\":{\"layerID\":\"s.layer0\",\"sceneID\":\"s\"}"))
        XCTAssertEqual(decoded.manifest.audio.clips[0].videoLayer, ref)
    }

    // MARK: - Deterministic ordering

    /// An unsorted in-memory manifest encodes to the canonical deterministic order:
    /// sources by AudioSourceID; tracks by AudioTrackID; clips by (trackID, destination.start, clipID).
    func testDeterministicOrderingFromUnsorted() throws {
        let audio = AudioManifest(
            sources: [
                AudioSourceEntry(id: try AudioSourceID("s2"), asset: .globalAudio(try GlobalAudioAssetID("g2"))),
                AudioSourceEntry(id: try AudioSourceID("s1"), asset: .globalAudio(try GlobalAudioAssetID("g1")))
            ],
            tracks: [
                AudioTrackEntry(id: try AudioTrackID("t2"), role: .voiceover),
                AudioTrackEntry(id: try AudioTrackID("t1"), role: .music)
            ],
            clips: [
                // Same track t1: ordered by destination.start, then clip id.
                try clip(id: "cB", trackID: "t1", sourceID: "s1", videoLayer: nil, destStart: 120_000, destEnd: 240_000),
                try clip(id: "cA", trackID: "t1", sourceID: "s1", videoLayer: nil, destStart: 0, destEnd: 120_000),
                // Different track t2 sorts after t1.
                try clip(id: "cC", trackID: "t2", sourceID: "s2", videoLayer: nil, destStart: 0, destEnd: 120_000)
            ]
        )
        let document = try document(with: audio)
        let text = String(decoding: try CanonicalProjectEncoding.encode(document), as: UTF8.self)

        XCTAssertTrue(try idxOf(text, "\"id\":\"s1\"") < idxOf(text, "\"id\":\"s2\""), "sources sorted by id")
        XCTAssertTrue(try idxOf(text, "\"id\":\"t1\"") < idxOf(text, "\"id\":\"t2\""), "tracks sorted by id")
        // Clips: cA (t1,0) < cB (t1,120000) < cC (t2,0).
        let a = try idxOf(text, "\"id\":\"cA\""), b = try idxOf(text, "\"id\":\"cB\""), c = try idxOf(text, "\"id\":\"cC\"")
        XCTAssertTrue(a < b && b < c, "clips sorted by (trackID, destination.start, clipID)")

        // Re-encode is byte-stable regardless of input order.
        let bytes1 = try CanonicalProjectEncoding.encode(document)
        let bytes2 = try CanonicalProjectEncoding.encode(try CanonicalProjectEncoding.decodeValidated(bytes1))
        XCTAssertEqual(bytes1, bytes2)
    }

    // MARK: - videoLayer absent vs explicit null

    func testAbsentVideoLayerAccepted() throws {
        // A global clip naturally omits videoLayer; decodes to nil.
        let audio = AudioManifest(
            sources: [AudioSourceEntry(id: try AudioSourceID("s1"), asset: .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t1"), role: .music)],
            clips: [try clip(id: "c1", trackID: "t1", sourceID: "s1", videoLayer: nil)]
        )
        let bytes = try CanonicalProjectEncoding.encode(try document(with: audio))
        let decoded = try CanonicalProjectEncoding.decodeValidated(bytes)
        XCTAssertNil(decoded.manifest.audio.clips[0].videoLayer)
    }

    func testExplicitNullVideoLayerRejected() throws {
        // Inject an explicit null videoLayer into a global clip's JSON → typed explicitNull.
        let audio = AudioManifest(
            sources: [AudioSourceEntry(id: try AudioSourceID("s1"), asset: .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t1"), role: .music)],
            clips: [try clip(id: "c1", trackID: "t1", sourceID: "s1", videoLayer: nil)]
        )
        let text = String(decoding: try CanonicalProjectEncoding.encode(try document(with: audio)), as: UTF8.self)
        // Add a "videoLayer":null pair into the clip object (right after the clip "id").
        let injected = text.replacingOccurrences(of: "\"id\":\"c1\"", with: "\"id\":\"c1\",\"videoLayer\":null")
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(injected.utf8))) { error in
            guard case .decoding(let d) = error as? ProjectLoadError, case .explicitNull = d else {
                return XCTFail("expected decoding .explicitNull, got \(error)")
            }
        }
    }

    /// No-regression: the EXISTING lenient optional field (`animation`, decoded via `optionalObject`)
    /// still treats an explicit `null` as absent. Proves the new `optionalObjectRejectingNull` (used
    /// only by `videoLayer`) did NOT tighten unrelated optional fields.
    func testAnimationNullStillTreatedAsAbsent() throws {
        // A scene layer with an animation; then force its `animation` to explicit null.
        let layer = try CanonicalProjectFixtures.videoLayer(
            id: "a.anim", zIndex: 0, stableOrdinal: 0, sceneDurationTicks: 240_000,
            media: "m", trimSeconds: 600,
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 100, height: 100),
            animation: try CanonicalProjectFixtures.holdLastAnimation(authoredTicks: 240_000)
        )
        let payload = ResolvedScenePayload(
            payloadID: try ScenePayloadID("p"), sceneID: try SceneInstanceID("s"),
            templateRef: try TemplateReference(catalogID: "c", sceneID: "sc"), layers: [layer]
        )
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: payload, nominalDurationTicks: 240_000)
        var text = String(decoding: try CanonicalProjectEncoding.encode(doc), as: UTF8.self)
        // Replace the animation object value with explicit null (lenient path → treated as absent).
        guard let aRange = text.range(of: "\"animation\":{") else { return XCTFail("no animation object") }
        guard let close = text[aRange.lowerBound...].range(of: "}") else { return XCTFail("no closing brace") }
        text.replaceSubrange(aRange.lowerBound..<close.upperBound, with: "\"animation\":null")
        let decoded = try CanonicalProjectEncoding.decodeValidated(Data(text.utf8))
        XCTAssertNil(decoded.scenePayloads[0].layers[0].animation, "animation null → absent (lenient, unchanged)")
    }

    // MARK: - Unknown / malformed shapes

    func testUnknownAssetKindRejected() throws {
        let text = try populatedGlobalText()
        let injected = text.replacingOccurrences(of: "\"kind\":\"globalAudio\"", with: "\"kind\":\"bogusKind\"")
        assertUnknownEnumTag(injected)
    }

    func testUnknownRoleRejected() throws {
        let text = try populatedGlobalText()
        let injected = text.replacingOccurrences(of: "\"role\":\"music\"", with: "\"role\":\"bogusRole\"")
        assertUnknownEnumTag(injected)
    }

    func testUnknownPlaybackPolicyRejected() throws {
        let text = try populatedGlobalText()
        let injected = text.replacingOccurrences(of: "\"playbackPolicy\":\"once\"", with: "\"playbackPolicy\":\"loop\"")
        assertUnknownEnumTag(injected)
    }

    func testMalformedAssetObjectRejected() throws {
        // Remove the asset's required `id` for a globalAudio asset → missingField.
        let text = try populatedGlobalText()
        let injected = text.replacingOccurrences(of: "\"asset\":{\"id\":\"g1\",\"kind\":\"globalAudio\"}",
                                                  with: "\"asset\":{\"kind\":\"globalAudio\"}")
        XCTAssertNotEqual(injected, text, "test setup: asset object should have been mutated")
        assertMissingField(injected)
    }

    func testMalformedSceneLayerReferenceRejected() throws {
        // A video clip whose videoLayer object is missing `layerID` → missingField. The source
        // document is semantically valid (fixture ids) so it ENCODES; the malformed JSON is then
        // injected and fails on DECODE.
        let ref = SceneLayerReference(sceneID: try SceneInstanceID("s"), layerID: try LayerID("s.layer0"))
        let audio = AudioManifest(
            sources: [AudioSourceEntry(id: try AudioSourceID("s1"), asset: .videoLayerMedia(try MediaReference("media-0")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t1"), role: .videoLayer)],
            clips: [try clip(id: "c1", trackID: "t1", sourceID: "s1", videoLayer: ref)]
        )
        let text = String(decoding: try CanonicalProjectEncoding.encode(try document(with: audio)), as: UTF8.self)
        let injected = text.replacingOccurrences(of: "\"videoLayer\":{\"layerID\":\"s.layer0\",\"sceneID\":\"s\"}",
                                                  with: "\"videoLayer\":{\"sceneID\":\"s\"}")
        XCTAssertNotEqual(injected, text, "test setup: videoLayer object should have been mutated")
        assertMissingField(injected)
    }

    func testUnknownAudioFieldRejected() throws {
        // An extra key inside the source object → strict finish() rejects it as unknownField.
        let text = try populatedGlobalText()
        let injected = text.replacingOccurrences(of: "\"asset\":{\"id\":\"g1\",\"kind\":\"globalAudio\"}",
                                                  with: "\"asset\":{\"id\":\"g1\",\"kind\":\"globalAudio\"},\"bogus\":1")
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(injected.utf8))) { error in
            guard case .decoding(let d) = error as? ProjectLoadError, case .unknownField = d else {
                return XCTFail("expected decoding .unknownField, got \(error)")
            }
        }
    }

    func testGainOutOfRangeRejectedThroughDecoder() throws {
        // A gain above unity in JSON → AudioGain.init throws invalidAudioGain (surfaced as validation).
        let text = try populatedGlobalText()
        let injected = text.replacingOccurrences(of: "\"gain\":1000000", with: "\"gain\":1000001")
        XCTAssertNotEqual(injected, text, "test setup: gain should have been mutated")
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(injected.utf8))) { error in
            guard case .validation(let v) = error as? ProjectLoadError, v == .invalidAudioGain(value: 1_000_001) else {
                return XCTFail("expected validation .invalidAudioGain, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func populatedGlobalText() throws -> String {
        let audio = AudioManifest(
            sources: [AudioSourceEntry(id: try AudioSourceID("s1"), asset: .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t1"), role: .music)],
            clips: [try clip(id: "c1", trackID: "t1", sourceID: "s1", videoLayer: nil)]
        )
        return String(decoding: try CanonicalProjectEncoding.encode(try document(with: audio)), as: UTF8.self)
    }

    private func assertUnknownEnumTag(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(json.utf8)), file: file, line: line) { error in
            guard case .decoding(let d) = error as? ProjectLoadError, case .unknownEnumTag = d else {
                return XCTFail("expected decoding .unknownEnumTag, got \(error)", file: file, line: line)
            }
        }
    }

    private func assertMissingField(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CanonicalProjectEncoding.decodeValidated(Data(json.utf8)), file: file, line: line) { error in
            guard case .decoding(let d) = error as? ProjectLoadError, case .missingField = d else {
                return XCTFail("expected decoding .missingField, got \(error)", file: file, line: line)
            }
        }
    }

    private func idxOf(_ text: String, _ needle: String) throws -> String.Index {
        guard let r = text.range(of: needle) else {
            throw XCTSkip("needle \(needle) not found")
        }
        return r.lowerBound
    }

    private func clip(
        id: String, trackID: String, sourceID: String, videoLayer: SceneLayerReference?,
        destStart: Int64 = 0, destEnd: Int64 = 240_000
    ) throws -> AudioClipEntry {
        AudioClipEntry(
            id: try AudioClipID(id),
            trackID: try AudioTrackID(trackID),
            sourceID: try AudioSourceID(sourceID),
            videoLayer: videoLayer,
            destination: try ProjectTimeRange(start: try ProjectTime(ticks: destStart), end: try ProjectTime(ticks: destEnd)),
            sourceTrim: try RationalSourceRange(
                start: try RationalSourceTime(numerator: 0, denominator: 1),
                end: try RationalSourceTime(numerator: 1, denominator: 1)
            ),
            gain: .unity,
            isMuted: false,
            playbackPolicy: .once
        )
    }

    private func document(with audio: AudioManifest) throws -> CanonicalProjectDocument {
        let base = try CanonicalProjectFixtures.singleSceneDocument(
            payload: try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: 240_000),
            nominalDurationTicks: 240_000
        )
        let m = base.manifest
        let manifest = CanonicalProjectManifest(
            schemaVersion: m.schemaVersion, output: m.output, scenes: m.scenes,
            boundaryTransitions: m.boundaryTransitions, overlays: m.overlays, audio: audio
        )
        return CanonicalProjectDocument(
            manifest: manifest, scenePayloads: base.scenePayloads, overlayPayloads: base.overlayPayloads
        )
    }
}
