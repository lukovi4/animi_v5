import XCTest
import Foundation
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Slice 001 — audio value-model semantics + populated round-trip (plan §3.2/§3.4, §9).
///
/// Proves the value types are real (Equatable/Sendable, distinct construction) and that a populated
/// manifest encodes and round-trips byte-stable through the Stage-C codec.
final class AudioValueModelTests: XCTestCase {

    // MARK: - Value semantics

    func testAssetReferenceEquatable() throws {
        let a = AudioAssetReference.videoLayerMedia(try MediaReference("m"))
        let b = AudioAssetReference.videoLayerMedia(try MediaReference("m"))
        let c = AudioAssetReference.globalAudio(try GlobalAudioAssetID("g"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testRolesAndPolicy() {
        XCTAssertEqual(AudioSourceRole.allCases.count, 4)
        XCTAssertEqual(AudioSourceRole.videoLayer.rawValue, "videoLayer")
        XCTAssertEqual(AudioPlaybackPolicy.once.rawValue, "once")
    }

    func testEntryValueSemantics() throws {
        let src1 = AudioSourceEntry(id: try AudioSourceID("s"),
                                    asset: .globalAudio(try GlobalAudioAssetID("g")))
        let src2 = AudioSourceEntry(id: try AudioSourceID("s"),
                                    asset: .globalAudio(try GlobalAudioAssetID("g")))
        XCTAssertEqual(src1, src2)

        let track = AudioTrackEntry(id: try AudioTrackID("t"), role: .music)
        XCTAssertEqual(track.role, .music)

        let clip = try sampleClip()
        XCTAssertEqual(clip, try sampleClip())
        XCTAssertEqual(clip.playbackPolicy, .once)
        XCTAssertNil(clip.videoLayer)
    }

    /// Compile-time `Sendable` conformance check across the value model.
    func testValueModelIsSendable() throws {
        func requireSendable<T: Sendable>(_ value: T) {}
        requireSendable(try AudioSourceID("s"))
        requireSendable(AudioAssetReference.globalAudio(try GlobalAudioAssetID("g")))
        requireSendable(AudioSourceRole.music)
        requireSendable(AudioPlaybackPolicy.once)
        requireSendable(try sampleClip())
        requireSendable(AudioManifest.empty)
    }

    // MARK: - Populated round-trip

    /// A populated `AudioManifest` encodes and round-trips byte-stable.
    func testPopulatedManifestEncodesAndRoundTrips() throws {
        let document = try documentWithPopulatedAudio()
        let bytes1 = try CanonicalProjectEncoding.encode(document)
        let decoded = try CanonicalProjectEncoding.decodeValidated(bytes1)
        let bytes2 = try CanonicalProjectEncoding.encode(decoded)
        XCTAssertEqual(bytes1, bytes2, "populated audio round trip must be byte-stable")
        XCTAssertEqual(decoded.manifest.audio, document.manifest.audio)
    }

    /// An empty manifest still encodes fine (no regression to the empty path).
    func testEmptyAudioCounterpartEncodesFine() throws {
        let empty = try emptyAudioDocument()
        XCTAssertEqual(empty.manifest.audio, .empty)
        XCTAssertNoThrow(try CanonicalProjectEncoding.encode(empty))
    }

    // MARK: - Helpers

    private func sampleClip() throws -> AudioClipEntry {
        AudioClipEntry(
            id: try AudioClipID("c"),
            trackID: try AudioTrackID("t"),
            sourceID: try AudioSourceID("s"),
            videoLayer: nil,
            destination: try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 240_000)),
            sourceTrim: try RationalSourceRange(
                start: try RationalSourceTime(numerator: 0, denominator: 1),
                end: try RationalSourceTime(numerator: 1, denominator: 1)
            ),
            gain: .unity,
            isMuted: false,
            playbackPolicy: .once
        )
    }

    private func emptyAudioDocument() throws -> CanonicalProjectDocument {
        try CanonicalProjectFixtures.singleSceneDocument(
            payload: try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: 240_000),
            nominalDurationTicks: 240_000
        )
    }

    /// Builds a valid document, then swaps in a populated audio manifest (reachable via @testable).
    private func documentWithPopulatedAudio() throws -> CanonicalProjectDocument {
        let base = try emptyAudioDocument()
        let m = base.manifest
        let populatedAudio = AudioManifest(
            sources: [AudioSourceEntry(id: try AudioSourceID("s"), asset: .globalAudio(try GlobalAudioAssetID("g")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t"), role: .music)],
            clips: [try sampleClip()]
        )
        let populatedManifest = CanonicalProjectManifest(
            schemaVersion: m.schemaVersion, output: m.output, scenes: m.scenes,
            boundaryTransitions: m.boundaryTransitions, overlays: m.overlays, audio: populatedAudio
        )
        return CanonicalProjectDocument(
            manifest: populatedManifest, scenePayloads: base.scenePayloads, overlayPayloads: base.overlayPayloads
        )
    }
}
