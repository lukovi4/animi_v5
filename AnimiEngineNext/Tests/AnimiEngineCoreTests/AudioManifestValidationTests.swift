import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Slice 001 Stage D — manifest-level audio validation (plan §7). No payloads required.
final class AudioManifestValidationTests: XCTestCase {

    // MARK: - Empty / basics

    func testEmptyAudioManifestPasses() throws {
        let doc = try singleSceneDoc(audio: .empty)
        XCTAssertNoThrow(try ProjectValidator.validateManifest(doc.manifest))
    }

    func testValidGlobalManifestPasses() throws {
        let doc = try singleSceneDoc(audio: globalAudio())
        XCTAssertNoThrow(try ProjectValidator.validateManifest(doc.manifest))
    }

    // MARK: - Uniqueness

    func testDuplicateSourceIDRejected() throws {
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1"))),
                      source("s1", .globalAudio(try GlobalAudioAssetID("g2")))],
            tracks: [track("t1", .music)],
            clips: [globalClip("c1", track: "t1", source: "s1")]
        )
        assertManifestError(audio) { XCTAssertEqual($0, .duplicateAudioID(scope: "audio.source", id: "s1")) }
    }

    func testDuplicateTrackIDRejected() throws {
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [track("t1", .music), track("t1", .voiceover)],
            clips: [globalClip("c1", track: "t1", source: "s1")]
        )
        assertManifestError(audio) { XCTAssertEqual($0, .duplicateAudioID(scope: "audio.track", id: "t1")) }
    }

    func testDuplicateClipIDRejected() throws {
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [track("t1", .music)],
            clips: [globalClip("c1", track: "t1", source: "s1"),
                    globalClip("c1", track: "t1", source: "s1")]
        )
        assertManifestError(audio) { XCTAssertEqual($0, .duplicateAudioID(scope: "audio.clip", id: "c1")) }
    }

    // MARK: - Dangling / orphan

    func testDanglingSourceRejected() throws {
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [track("t1", .music)],
            clips: [globalClip("c1", track: "t1", source: "sX")]
        )
        assertManifestError(audio) { XCTAssertEqual($0, .danglingAudioReference(kind: "source", id: "sX")) }
    }

    func testDanglingTrackRejected() throws {
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [track("t1", .music)],
            clips: [globalClip("c1", track: "tX", source: "s1")]
        )
        assertManifestError(audio) { XCTAssertEqual($0, .danglingAudioReference(kind: "track", id: "tX")) }
    }

    func testOrphanSourceRejected() throws {
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1"))),
                      source("s2", .globalAudio(try GlobalAudioAssetID("g2")))],
            tracks: [track("t1", .music)],
            clips: [globalClip("c1", track: "t1", source: "s1")]
        )
        assertManifestError(audio) { XCTAssertEqual($0, .orphanAudioSource(id: "s2")) }
    }

    func testOrphanTrackRejected() throws {
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [track("t1", .music), track("t2", .voiceover)],
            clips: [globalClip("c1", track: "t1", source: "s1")]
        )
        assertManifestError(audio) { XCTAssertEqual($0, .orphanAudioTrack(id: "t2")) }
    }

    func testOneSourceManyClipsAccepted() throws {
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [track("t1", .music)],
            clips: [globalClip("c1", track: "t1", source: "s1", destStart: 0, destEnd: 120_000),
                    globalClip("c2", track: "t1", source: "s1", destStart: 120_000, destEnd: 240_000)]
        )
        let doc = try singleSceneDoc(audio: audio)
        XCTAssertNoThrow(try ProjectValidator.validateManifest(doc.manifest))
    }

    func testShuffledTableOrderAccepted() throws {
        // Reverse-order tables must validate identically (order is non-semantic).
        let audio = try AudioManifest(
            sources: [source("s2", .globalAudio(try GlobalAudioAssetID("g2"))),
                      source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [track("t2", .voiceover), track("t1", .music)],
            clips: [globalClip("c2", track: "t2", source: "s2", destStart: 120_000, destEnd: 240_000),
                    globalClip("c1", track: "t1", source: "s1", destStart: 0, destEnd: 120_000)]
        )
        let doc = try singleSceneDoc(audio: audio)
        XCTAssertNoThrow(try ProjectValidator.validateManifest(doc.manifest))
    }

    // MARK: - role ↔ videoLayer / asset

    func testVideoRoleRequiresVideoLayer() throws {
        // .videoLayer role but nil videoLayer.
        let audio = try AudioManifest(
            sources: [source("s1", .videoLayerMedia(try MediaReference("media-0")))],
            tracks: [track("t1", .videoLayer)],
            clips: [globalClip("c1", track: "t1", source: "s1")]   // videoLayer nil
        )
        assertManifestError(audio) { XCTAssertEqual($0, .audioRoleLayerMismatch(clip: "c1")) }
    }

    func testGlobalRoleForbidsVideoLayer() throws {
        let ref = SceneLayerReference(sceneID: try SceneInstanceID("sceneA"), layerID: try LayerID("L0"))
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [track("t1", .music)],
            clips: [videoClip("c1", track: "t1", source: "s1", ref: ref)]   // music + videoLayer
        )
        assertManifestError(audio) { XCTAssertEqual($0, .audioRoleLayerMismatch(clip: "c1")) }
    }

    func testVideoRoleRequiresVideoLayerMediaAsset() throws {
        let ref = SceneLayerReference(sceneID: try SceneInstanceID("sceneA"), layerID: try LayerID("L0"))
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],   // wrong asset kind
            tracks: [track("t1", .videoLayer)],
            clips: [videoClip("c1", track: "t1", source: "s1", ref: ref)]
        )
        assertManifestError(audio) { XCTAssertEqual($0, .audioRoleAssetMismatch(clip: "c1")) }
    }

    func testGlobalRoleRequiresGlobalAudioAsset() throws {
        let audio = try AudioManifest(
            sources: [source("s1", .videoLayerMedia(try MediaReference("media-0")))],   // wrong asset kind
            tracks: [track("t1", .music)],
            clips: [globalClip("c1", track: "t1", source: "s1")]
        )
        assertManifestError(audio) { XCTAssertEqual($0, .audioRoleAssetMismatch(clip: "c1")) }
    }

    // MARK: - scene existence / destination range

    func testUnknownSceneRejected() throws {
        let ref = SceneLayerReference(sceneID: try SceneInstanceID("ghost"), layerID: try LayerID("L0"))
        let audio = try videoAudio(ref: ref)
        assertManifestError(audio) { XCTAssertEqual($0, .unknownAudioScene(clip: "c1")) }
    }

    func testDestinationOutsideProjectRejected() throws {
        // Single scene of 240_000 ticks; destination ends past project end.
        let audio = try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [track("t1", .music)],
            clips: [globalClip("c1", track: "t1", source: "s1", destStart: 0, destEnd: 240_001)]
        )
        assertManifestError(audio) { XCTAssertEqual($0, .audioDestinationOutsideProject(clip: "c1")) }
    }

    // MARK: - media-active domain

    func testIncomingAudioBeforeBoundaryRejected() throws {
        // Two scenes, each 240_000. Scene B starts at 240_000. A clip on scene B starting before that
        // is pre-boundary audio → incomingAudioBeforeBoundary.
        let ref = SceneLayerReference(sceneID: try SceneInstanceID("sceneB"), layerID: try LayerID("L0"))
        let audio = try videoAudio(ref: ref, destStart: 120_000, destEnd: 360_000)
        let doc = try twoSceneDoc(audio: audio)
        XCTAssertThrowsError(try ProjectValidator.validateManifest(doc.manifest)) {
            XCTAssertEqual($0 as? ProjectValidationError, .incomingAudioBeforeBoundary(clip: "c1"))
        }
    }

    func testDestinationOutsideMediaActiveDomainRejected() throws {
        // Cut boundary → scene A media domain is [0, 240_000). A clip extending past 240_000 is out.
        let ref = SceneLayerReference(sceneID: try SceneInstanceID("sceneA"), layerID: try LayerID("L0"))
        let audio = try videoAudio(ref: ref, destStart: 0, destEnd: 300_000)
        let doc = try twoSceneDoc(audio: audio, animatedTransition: false)
        XCTAssertThrowsError(try ProjectValidator.validateManifest(doc.manifest)) {
            XCTAssertEqual($0 as? ProjectValidationError, .audioDestinationOutsideMediaActiveDomain(clip: "c1"))
        }
    }

    func testOutgoingPostRollAudioAccepted() throws {
        // Animated fade boundary (duration 120_000, postHalf 60_000) extends scene A media domain to
        // 240_000 + 60_000 = 300_000. A clip into [240_000, 300_000) is allowed.
        let ref = SceneLayerReference(sceneID: try SceneInstanceID("sceneA"), layerID: try LayerID("L0"))
        let audio = try videoAudio(ref: ref, destStart: 0, destEnd: 300_000)
        let doc = try twoSceneDoc(audio: audio, animatedTransition: true)
        XCTAssertNoThrow(try ProjectValidator.validateManifest(doc.manifest))
    }

    // MARK: - Helpers

    private func assertManifestError(_ audio: AudioManifest, _ check: (ProjectValidationError) -> Void,
                                     file: StaticString = #filePath, line: UInt = #line) {
        do {
            let doc = try singleSceneDoc(audio: audio)
            XCTAssertThrowsError(try ProjectValidator.validateManifest(doc.manifest), file: file, line: line) {
                guard let e = $0 as? ProjectValidationError else { return XCTFail("not a ProjectValidationError: \($0)", file: file, line: line) }
                check(e)
            }
        } catch { XCTFail("setup failed: \(error)", file: file, line: line) }
    }

    private func source(_ id: String, _ asset: AudioAssetReference) throws -> AudioSourceEntry {
        AudioSourceEntry(id: try AudioSourceID(id), asset: asset)
    }
    private func track(_ id: String, _ role: AudioSourceRole) throws -> AudioTrackEntry {
        AudioTrackEntry(id: try AudioTrackID(id), role: role)
    }
    private func globalClip(_ id: String, track: String, source: String,
                            destStart: Int64 = 0, destEnd: Int64 = 240_000) throws -> AudioClipEntry {
        try clip(id, track: track, source: source, ref: nil, destStart: destStart, destEnd: destEnd)
    }
    private func videoClip(_ id: String, track: String, source: String, ref: SceneLayerReference,
                           destStart: Int64 = 0, destEnd: Int64 = 240_000) throws -> AudioClipEntry {
        try clip(id, track: track, source: source, ref: ref, destStart: destStart, destEnd: destEnd)
    }
    private func clip(_ id: String, track: String, source: String, ref: SceneLayerReference?,
                      destStart: Int64, destEnd: Int64) throws -> AudioClipEntry {
        AudioClipEntry(
            id: try AudioClipID(id), trackID: try AudioTrackID(track), sourceID: try AudioSourceID(source),
            videoLayer: ref,
            destination: try ProjectTimeRange(start: try ProjectTime(ticks: destStart), end: try ProjectTime(ticks: destEnd)),
            sourceTrim: try RationalSourceRange(
                start: try RationalSourceTime(numerator: 0, denominator: 1),
                end: try RationalSourceTime(numerator: 1, denominator: 1)
            ),
            gain: .unity, isMuted: false, playbackPolicy: .once
        )
    }

    private func globalAudio() throws -> AudioManifest {
        try AudioManifest(
            sources: [source("s1", .globalAudio(try GlobalAudioAssetID("g1")))],
            tracks: [track("t1", .music)],
            clips: [globalClip("c1", track: "t1", source: "s1")]
        )
    }

    /// A video-audio manifest whose single source media matches the fixture scene layer media-0.
    private func videoAudio(ref: SceneLayerReference, destStart: Int64 = 0, destEnd: Int64 = 240_000) throws -> AudioManifest {
        try AudioManifest(
            sources: [source("s1", .videoLayerMedia(try MediaReference("media-0")))],
            tracks: [track("t1", .videoLayer)],
            clips: [videoClip("c1", track: "t1", source: "s1", ref: ref, destStart: destStart, destEnd: destEnd)]
        )
    }

    private func singleSceneDoc(audio: AudioManifest) throws -> CanonicalProjectDocument {
        let base = try CanonicalProjectFixtures.singleSceneDocument(
            payload: try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "sceneA", payloadID: "pA", durationTicks: 240_000),
            nominalDurationTicks: 240_000
        )
        return withAudio(base, audio)
    }

    private func twoSceneDoc(audio: AudioManifest, animatedTransition: Bool = false) throws -> CanonicalProjectDocument {
        let sceneA = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "sceneA", payloadID: "pA", durationTicks: 240_000)
        let sceneB = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "sceneB", payloadID: "pB", durationTicks: 240_000)
        let transition = animatedTransition
            ? try CanonicalProjectFixtures.fadeTransition(durationTicks: 120_000)
            : SceneTransition(kind: .cut, duration: .zero, easing: try EasingReference("linear"))
        let base = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: sceneA, sceneB: sceneB, durationATicks: 240_000, durationBTicks: 240_000,
            transition: transition, postRollTicks: animatedTransition ? 120_000 : 0
        )
        return withAudio(base, audio)
    }

    private func withAudio(_ base: CanonicalProjectDocument, _ audio: AudioManifest) -> CanonicalProjectDocument {
        let m = base.manifest
        let manifest = CanonicalProjectManifest(
            schemaVersion: m.schemaVersion, output: m.output, scenes: m.scenes,
            boundaryTransitions: m.boundaryTransitions, overlays: m.overlays, audio: audio
        )
        return CanonicalProjectDocument(manifest: manifest, scenePayloads: base.scenePayloads, overlayPayloads: base.overlayPayloads)
    }
}
