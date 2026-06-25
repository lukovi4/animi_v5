import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Slice-002 Stage C — `AudioEvaluationWindowBuilder`: exactly-one source resolution, binding
/// resolution, track-order materialisation, and defensive builder-boundary failures. I/O-free.
final class AudioEvaluationWindowBuilderTests: XCTestCase {

    // MARK: - Document + requirement scaffolding

    /// A single video scene "sceneA" with one video layer "sceneA.layer0" (media "media-0",
    /// trim [0/1, 600/1)), 240_000 ticks long. Audio is injected per test.
    private func videoDocument(audio: AudioManifest) throws -> CanonicalProjectDocument {
        let base = try CanonicalProjectFixtures.singleSceneDocument(
            payload: try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "sceneA", payloadID: "pA", durationTicks: 240_000),
            nominalDurationTicks: 240_000
        )
        return withAudio(base, audio)
    }

    private func requirement(_ doc: CanonicalProjectDocument) throws -> EvaluationWindowRequirement {
        let index = try TimelineIndex(manifest: doc.manifest)
        let projectDuration = try doc.manifest.projectDuration()
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: projectDuration.ticks))
        return try index.requirements(for: coverage)
    }

    private func build(
        _ doc: CanonicalProjectDocument, descriptors: [ResolvedAudioSourceDescriptor]
    ) throws -> AudioEvaluationWindow {
        try AudioEvaluationWindowBuilder.build(
            manifest: doc.manifest, requirement: try requirement(doc),
            scenes: doc.scenePayloads, sourceDescriptors: descriptors
        )
    }

    // MARK: - Global audio fixtures

    private func globalAudioDocument(sourceID: String = "s1", trackID: String = "t1", clipID: String = "c1") throws -> CanonicalProjectDocument {
        let audio = try AudioManifest(
            sources: [AudioSourceEntry(id: try AudioSourceID(sourceID), asset: .globalAudio(try GlobalAudioAssetID("asset-1")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID(trackID), role: .music)],
            clips: [AudioClipEntry(
                id: try AudioClipID(clipID), trackID: try AudioTrackID(trackID), sourceID: try AudioSourceID(sourceID),
                videoLayer: nil, destination: try range(0, 240_000), sourceTrim: try trim(1),
                gain: .unity, isMuted: false, playbackPolicy: .once
            )]
        )
        return try videoDocument(audio: audio)
    }

    private func videoLayerAudioDocument() throws -> CanonicalProjectDocument {
        let audio = try AudioManifest(
            sources: [AudioSourceEntry(id: try AudioSourceID("s1"), asset: .videoLayerMedia(try MediaReference("media-0")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t1"), role: .videoLayer)],
            clips: [AudioClipEntry(
                id: try AudioClipID("c1"), trackID: try AudioTrackID("t1"), sourceID: try AudioSourceID("s1"),
                videoLayer: SceneLayerReference(sceneID: try SceneInstanceID("sceneA"), layerID: try LayerID("sceneA.layer0")),
                destination: try range(0, 240_000), sourceTrim: try trim(1),
                gain: .unity, isMuted: false, playbackPolicy: .once
            )]
        )
        return try videoDocument(audio: audio)
    }

    private func descriptor(_ id: String, identity: String = "stream") throws -> ResolvedAudioSourceDescriptor {
        ResolvedAudioSourceDescriptor(
            sourceID: try AudioSourceID(id), streamIdentity: try AudioStreamIdentity("\(identity)-\(id)"),
            sourceDuration: try RationalSourceTime(numerator: 600, denominator: 1), sampleRate: 48_000,
            channelLayout: .stereo
        )
    }

    // MARK: - Exactly-one resolution

    func testExactlyOneDescriptorResolves() throws {
        let doc = try globalAudioDocument()
        let window = try build(doc, descriptors: [try descriptor("s1")])
        XCTAssertEqual(window.clips.count, 1)
        XCTAssertEqual(window.clips[0].binding, .global)
    }

    func testZeroDescriptorFails() throws {
        let doc = try globalAudioDocument()
        XCTAssertThrowsError(try build(doc, descriptors: [])) {
            XCTAssertEqual($0 as? AudioEvaluationError, .unresolvedAudioSource(sourceID: "s1"))
        }
    }

    func testDuplicateDescriptorFails() throws {
        let doc = try globalAudioDocument()
        XCTAssertThrowsError(try build(doc, descriptors: [try descriptor("s1", identity: "a"), try descriptor("s1", identity: "b")])) {
            XCTAssertEqual($0 as? AudioEvaluationError, .ambiguousAudioSource(sourceID: "s1"))
        }
    }

    func testStableIdentityIndependentOfDescriptorInputOrder() throws {
        // Two sources, two descriptors; the resolved window is identical regardless of input order.
        let audio = try AudioManifest(
            sources: [
                AudioSourceEntry(id: try AudioSourceID("s1"), asset: .globalAudio(try GlobalAudioAssetID("a1"))),
                AudioSourceEntry(id: try AudioSourceID("s2"), asset: .globalAudio(try GlobalAudioAssetID("a2")))
            ],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t1"), role: .music),
                     AudioTrackEntry(id: try AudioTrackID("t2"), role: .voiceover)],
            clips: [
                AudioClipEntry(id: try AudioClipID("c1"), trackID: try AudioTrackID("t1"), sourceID: try AudioSourceID("s1"),
                               videoLayer: nil, destination: try range(0, 240_000), sourceTrim: try trim(1), gain: .unity, isMuted: false, playbackPolicy: .once),
                AudioClipEntry(id: try AudioClipID("c2"), trackID: try AudioTrackID("t2"), sourceID: try AudioSourceID("s2"),
                               videoLayer: nil, destination: try range(0, 240_000), sourceTrim: try trim(1), gain: .unity, isMuted: false, playbackPolicy: .once)
            ]
        )
        let doc = try videoDocument(audio: audio)
        let d1 = try descriptor("s1"); let d2 = try descriptor("s2")
        let a = try build(doc, descriptors: [d1, d2])
        let b = try build(doc, descriptors: [d2, d1])
        XCTAssertEqual(a, b)
    }

    // MARK: - Silent video / global / video-layer bindings

    func testSilentVideoNoClipProducesNoResolvedClip() throws {
        // Video scene with NO audio clip → empty audio → no resolved clips, no descriptor needed.
        let doc = try videoDocument(audio: .empty)
        let window = try build(doc, descriptors: [])
        XCTAssertTrue(window.clips.isEmpty)
    }

    func testGlobalBinding() throws {
        let window = try build(try globalAudioDocument(), descriptors: [try descriptor("s1")])
        XCTAssertEqual(window.clips[0].binding, .global)
    }

    func testVideoLayerBindingCopiesSourceMapping() throws {
        let doc = try videoLayerAudioDocument()
        let window = try build(doc, descriptors: [try descriptor("s1")])
        guard case .videoLayer(let sceneID, let mapping) = window.clips[0].binding else {
            return XCTFail("expected videoLayer binding")
        }
        XCTAssertEqual(sceneID, try SceneInstanceID("sceneA"))
        // The copied mapping equals the layer's VideoBinding.sourceMapping.
        let payload = doc.scenePayloads.first { $0.sceneID == (try? SceneInstanceID("sceneA")) }
        guard case .video(let binding)? = payload?.layers.first?.content else { return XCTFail("no video layer") }
        XCTAssertEqual(mapping, binding.sourceMapping)
    }

    // MARK: - Defensive failures

    func testVideoLayerClipWithUnknownSceneFailsAtBuilderBoundary() throws {
        // A video-layer clip references scene "ghost", absent from the loaded payloads → the builder's
        // defensive boundary check fails typed (this is reachable even after Slice-1 validation, because
        // the loaded payload set is a Stage-C input the builder must defend against).
        let audio = try AudioManifest(
            sources: [AudioSourceEntry(id: try AudioSourceID("s1"), asset: .videoLayerMedia(try MediaReference("media-0")))],
            tracks: [AudioTrackEntry(id: try AudioTrackID("t1"), role: .videoLayer)],
            clips: [AudioClipEntry(
                id: try AudioClipID("c1"), trackID: try AudioTrackID("t1"), sourceID: try AudioSourceID("s1"),
                videoLayer: SceneLayerReference(sceneID: try SceneInstanceID("sceneA"), layerID: try LayerID("sceneA.layer0")),
                destination: try range(0, 240_000), sourceTrim: try trim(1), gain: .unity, isMuted: false, playbackPolicy: .once
            )]
        )
        let doc = try videoDocument(audio: audio)
        let requirement = try requirement(doc)
        // Supply NO scene payloads → the builder cannot resolve the video-layer's scene.
        XCTAssertThrowsError(try AudioEvaluationWindowBuilder.build(
            manifest: doc.manifest, requirement: requirement, scenes: [], sourceDescriptors: [try descriptor("s1")]
        )) {
            // Missing required scene payload surfaces as a typed payload error before binding resolution.
            XCTAssertTrue(
                ($0 as? ProjectValidationError) != nil || ($0 as? AudioEvaluationError) != nil,
                "expected a typed builder-boundary error, got \($0)"
            )
        }
    }

    // MARK: - Fail-closed role (no .music fallback) + descriptor metadata carried

    func testMissingTrackFailsTypedNoMusicFallback() throws {
        // Build a valid global-audio doc (so the requirement is derivable), then hand the builder a
        // manifest whose audio TRACK table is empty while the clip still references "t1": the clip's
        // track is missing → fail-closed typed error, never a silent `.music` fallback.
        let doc = try globalAudioDocument()
        let requirement = try requirement(doc)
        let m = doc.manifest
        let tamperedAudio = try AudioManifest(
            sources: m.audio.sources, tracks: [], clips: m.audio.clips   // track table emptied
        )
        let tampered = CanonicalProjectManifest(
            schemaVersion: m.schemaVersion, output: m.output, scenes: m.scenes,
            boundaryTransitions: m.boundaryTransitions, overlays: m.overlays, audio: tamperedAudio
        )
        XCTAssertThrowsError(try AudioEvaluationWindowBuilder.build(
            manifest: tampered, requirement: requirement, scenes: doc.scenePayloads,
            sourceDescriptors: [try descriptor("s1")]
        )) {
            XCTAssertEqual($0 as? AudioEvaluationError, .inconsistentResolvedBinding(clipID: "c1"), "actual: \($0)")
        }
    }

    func testResolvedClipCarriesExactDescriptor() throws {
        let doc = try globalAudioDocument()
        let desc = ResolvedAudioSourceDescriptor(
            sourceID: try AudioSourceID("s1"), streamIdentity: try AudioStreamIdentity("prov-1"),
            sourceDuration: try RationalSourceTime(numerator: 600, denominator: 1),
            sampleRate: 32_000, channelLayout: .mono
        )
        let window = try build(doc, descriptors: [desc])
        XCTAssertEqual(window.clips[0].sourceDescriptor, desc)
    }

    // MARK: - Helpers

    private func range(_ s: Int64, _ e: Int64) throws -> ProjectTimeRange {
        try ProjectTimeRange(start: try ProjectTime(ticks: s), end: try ProjectTime(ticks: e))
    }
    private func trim(_ endSeconds: Int64) throws -> RationalSourceRange {
        try RationalSourceRange(
            start: try RationalSourceTime(numerator: 0, denominator: 1),
            end: try RationalSourceTime(numerator: endSeconds, denominator: 1)
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
