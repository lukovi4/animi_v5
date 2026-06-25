import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Slice 001 Stage D — payload-dependent audio validation (plan §7). Resolves video-layer clips
/// through `sceneID → payloadID → ResolvedScenePayload` → layer → `VideoBinding`.
final class AudioDocumentValidationTests: XCTestCase {

    // MARK: - Resolution

    func testValidVideoLayerResolves() throws {
        let doc = try doc(audio: try videoAudio(layerID: "sceneA.layer0"))
        XCTAssertNoThrow(try ProjectValidator.validate(doc))
    }

    func testUnknownLayerRejected() throws {
        let doc = try doc(audio: try videoAudio(layerID: "ghost.layer"))
        assertError(doc) { XCTAssertEqual($0, .audioLayerNotFound(clip: "c1")) }
    }

    func testImageLayerRejected() throws {
        // A scene whose only layer is an image; a video-audio clip pointing at it must be rejected.
        let imageScene = ResolvedScenePayload(
            payloadID: try ScenePayloadID("pA"), sceneID: try SceneInstanceID("sceneA"),
            templateRef: try TemplateReference(catalogID: "c", sceneID: "sc"),
            layers: [try CanonicalProjectFixtures.imageLayer(
                id: "sceneA.layer0", zIndex: 0, stableOrdinal: 0, sceneDurationTicks: 240_000,
                image: "img-0",
                placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 100, height: 100)
            )]
        )
        let base = try CanonicalProjectFixtures.singleSceneDocument(payload: imageScene, nominalDurationTicks: 240_000)
        // The asset media must reference the image's... there is no video media, so use media-0; the
        // layer-not-video check fires before the media compare.
        let audio = try AudioManifest(
            sources: [src("s1", .videoLayerMedia(try MediaReference("media-0")))],
            tracks: [trk("t1", .videoLayer)],
            clips: [vclip("c1", "t1", "s1", layerID: "sceneA.layer0")]
        )
        let document = withAudio(base, audio)
        assertError(document) { XCTAssertEqual($0, .audioLayerNotVideo(clip: "c1")) }
    }

    // MARK: - Media match / trim containment

    func testMediaMismatchRejected() throws {
        // Source media "media-9" ≠ the layer's "media-0".
        let audio = try AudioManifest(
            sources: [src("s1", .videoLayerMedia(try MediaReference("media-9")))],
            tracks: [trk("t1", .videoLayer)],
            clips: [vclip("c1", "t1", "s1", layerID: "sceneA.layer0")]
        )
        assertError(try doc(audio: audio)) { XCTAssertEqual($0, .audioMediaMismatch(clip: "c1")) }
    }

    func testTrimContainmentInsidePasses() throws {
        // Layer trim is [0/1, 600/1); clip trim [0/1, 1/1) is contained.
        let audio = try videoAudio(layerID: "sceneA.layer0", trimEnd: 1)
        XCTAssertNoThrow(try ProjectValidator.validate(try doc(audio: audio)))
    }

    func testTrimContainmentOutsideRejected() throws {
        // Clip trim [0/1, 601/1) exceeds the layer trim [0/1, 600/1).
        let audio = try videoAudio(layerID: "sceneA.layer0", trimEnd: 601)
        assertError(try doc(audio: audio)) { XCTAssertEqual($0, .audioTrimNotContained(clip: "c1")) }
    }

    // MARK: - Duplicate / same-layer-id / silence

    func testDuplicateVideoAudioClipRejected() throws {
        let audio = try AudioManifest(
            sources: [src("s1", .videoLayerMedia(try MediaReference("media-0")))],
            tracks: [trk("t1", .videoLayer)],
            clips: [vclip("c1", "t1", "s1", layerID: "sceneA.layer0", destStart: 0, destEnd: 120_000),
                    vclip("c2", "t1", "s1", layerID: "sceneA.layer0", destStart: 120_000, destEnd: 240_000)]
        )
        assertError(try doc(audio: audio)) { XCTAssertEqual($0, .duplicateVideoAudioClip(layer: "sceneA/sceneA.layer0")) }
    }

    func testSameLayerIDInTwoScenesResolvesDistinctly() throws {
        // Both scenes name their layer "shared.layer". Two clips, one per scene, resolve distinctly.
        let sceneA = try sceneWithLayer(sceneID: "sceneA", payloadID: "pA", layerID: "shared.layer", media: "media-A")
        let sceneB = try sceneWithLayer(sceneID: "sceneB", payloadID: "pB", layerID: "shared.layer", media: "media-B")
        let base = try twoScene(sceneA: sceneA, sceneB: sceneB)
        let refA = SceneLayerReference(sceneID: try SceneInstanceID("sceneA"), layerID: try LayerID("shared.layer"))
        let refB = SceneLayerReference(sceneID: try SceneInstanceID("sceneB"), layerID: try LayerID("shared.layer"))
        let audio = try AudioManifest(
            sources: [src("sA", .videoLayerMedia(try MediaReference("media-A"))),
                      src("sB", .videoLayerMedia(try MediaReference("media-B")))],
            tracks: [trk("tA", .videoLayer), trk("tB", .videoLayer)],
            clips: [
                AudioClipEntry(id: try AudioClipID("cA"), trackID: try AudioTrackID("tA"), sourceID: try AudioSourceID("sA"),
                               videoLayer: refA, destination: try range(0, 240_000), sourceTrim: try trim(1),
                               gain: .unity, isMuted: false, playbackPolicy: .once),
                AudioClipEntry(id: try AudioClipID("cB"), trackID: try AudioTrackID("tB"), sourceID: try AudioSourceID("sB"),
                               videoLayer: refB, destination: try range(240_000, 480_000), sourceTrim: try trim(1),
                               gain: .unity, isMuted: false, playbackPolicy: .once)
            ]
        )
        XCTAssertNoThrow(try ProjectValidator.validate(withAudio(base, audio)))
    }

    func testLegitimateSilentVideoAccepted() throws {
        // A video scene with NO audio clip at all is valid silence.
        XCTAssertNoThrow(try ProjectValidator.validate(try doc(audio: .empty)))
    }

    // MARK: - Helpers

    private func assertError(_ document: CanonicalProjectDocument, _ check: (ProjectValidationError) -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ProjectValidator.validate(document), file: file, line: line) {
            guard let e = $0 as? ProjectValidationError else { return XCTFail("not a ProjectValidationError: \($0)", file: file, line: line) }
            check(e)
        }
    }

    private func src(_ id: String, _ asset: AudioAssetReference) throws -> AudioSourceEntry {
        AudioSourceEntry(id: try AudioSourceID(id), asset: asset)
    }
    private func trk(_ id: String, _ role: AudioSourceRole) throws -> AudioTrackEntry {
        AudioTrackEntry(id: try AudioTrackID(id), role: role)
    }
    private func range(_ s: Int64, _ e: Int64) throws -> ProjectTimeRange {
        try ProjectTimeRange(start: try ProjectTime(ticks: s), end: try ProjectTime(ticks: e))
    }
    private func trim(_ endSeconds: Int64) throws -> RationalSourceRange {
        try RationalSourceRange(
            start: try RationalSourceTime(numerator: 0, denominator: 1),
            end: try RationalSourceTime(numerator: endSeconds, denominator: 1)
        )
    }
    private func vclip(_ id: String, _ track: String, _ source: String, layerID: String,
                       destStart: Int64 = 0, destEnd: Int64 = 240_000, trimEnd: Int64 = 1) throws -> AudioClipEntry {
        AudioClipEntry(
            id: try AudioClipID(id), trackID: try AudioTrackID(track), sourceID: try AudioSourceID(source),
            videoLayer: SceneLayerReference(sceneID: try SceneInstanceID("sceneA"), layerID: try LayerID(layerID)),
            destination: try range(destStart, destEnd), sourceTrim: try trim(trimEnd),
            gain: .unity, isMuted: false, playbackPolicy: .once
        )
    }

    private func videoAudio(layerID: String, trimEnd: Int64 = 1) throws -> AudioManifest {
        try AudioManifest(
            sources: [src("s1", .videoLayerMedia(try MediaReference("media-0")))],
            tracks: [trk("t1", .videoLayer)],
            clips: [vclip("c1", "t1", "s1", layerID: layerID, trimEnd: trimEnd)]
        )
    }

    private func sceneWithLayer(sceneID: String, payloadID: String, layerID: String, media: String) throws -> ResolvedScenePayload {
        ResolvedScenePayload(
            payloadID: try ScenePayloadID(payloadID), sceneID: try SceneInstanceID(sceneID),
            templateRef: try TemplateReference(catalogID: "c", sceneID: "sc"),
            layers: [try CanonicalProjectFixtures.videoLayer(
                id: layerID, zIndex: 0, stableOrdinal: 0, sceneDurationTicks: 240_000,
                media: media, trimSeconds: 600,
                placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 100, height: 100)
            )]
        )
    }

    private func doc(audio: AudioManifest) throws -> CanonicalProjectDocument {
        let base = try CanonicalProjectFixtures.singleSceneDocument(
            payload: try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "sceneA", payloadID: "pA", durationTicks: 240_000),
            nominalDurationTicks: 240_000
        )
        return withAudio(base, audio)
    }

    private func twoScene(sceneA: ResolvedScenePayload, sceneB: ResolvedScenePayload) throws -> CanonicalProjectDocument {
        try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: sceneA, sceneB: sceneB, durationATicks: 240_000, durationBTicks: 240_000,
            transition: SceneTransition(kind: .cut, duration: .zero, easing: try EasingReference("linear")),
            postRollTicks: 0
        )
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
