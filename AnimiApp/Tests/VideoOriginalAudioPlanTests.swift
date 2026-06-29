#if DEBUG
import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage 1 — prove the canonical video-original audio assembly produces a NON-EMPTY `AudioPlan`
/// with a real `.videoLayer` segment, end-to-end through `AudioEvaluationWindowBuilder` + `AudioEvaluator`
/// (the SAME path `RuntimeCanonicalAudioPlanSource.currentAudioPlan` runs). This is the non-empty-plan
/// proof the cutover requires; it also proves a music + video-original manifest yields BOTH a music and a
/// videoLayer segment, and that a mismatched scene/layer/media fails typed (not silent).
@MainActor
final class VideoOriginalAudioPlanTests: XCTestCase {

    // Build a minimal canonical document (one scene span) carrying the audio-only `.video` layer(s).
    private func makeDocument(sceneDurationUs: Int64, layers: [SceneLayer], sceneIDRaw: String, payloadIDRaw: String) throws -> CanonicalProjectDocument {
        let sceneID = try SceneInstanceID(sceneIDRaw)
        let payloadID = try ScenePayloadID(payloadIDRaw)
        let ticks = max(1, Int64((Double(sceneDurationUs) * 6 / 25).rounded(.up)))
        let entry = SceneManifestEntry(
            id: sceneID, payloadID: payloadID,
            nominalDuration: try TickDuration(ticks: ticks), postRollCapability: .zero)
        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: .fps30),
            scenes: [entry], boundaryTransitions: [], overlays: [])
        let payload = ResolvedScenePayload(
            payloadID: payloadID, sceneID: sceneID,
            templateRef: try TemplateReference(catalogID: "preview-audio", sceneID: "s0"),
            layers: layers)
        return CanonicalProjectDocument(manifest: manifest, scenePayloads: [payload], overlayPayloads: [])
    }

    /// Combine two single-scene documents into one two-scene timeline (cut boundary, scene B after A).
    private func makeTwoSceneDocument(a: CanonicalProjectDocument, b: CanonicalProjectDocument) throws -> CanonicalProjectDocument {
        let entries = a.manifest.scenes + b.manifest.scenes
        let cut = AnimiEngineCore.SceneTransition(kind: .cut, duration: .zero, easing: try EasingReference("none"))
        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: a.manifest.output, scenes: entries, boundaryTransitions: [cut], overlays: [])
        return CanonicalProjectDocument(
            manifest: manifest, scenePayloads: a.scenePayloads + b.scenePayloads, overlayPayloads: [])
    }

    private func injectAudio(_ doc: CanonicalProjectDocument, _ audio: AudioManifest) -> CanonicalProjectManifest {
        let m = doc.manifest
        return CanonicalProjectManifest(
            schemaVersion: m.schemaVersion, output: m.output, scenes: m.scenes,
            boundaryTransitions: m.boundaryTransitions, overlays: m.overlays, audio: audio)
    }

    private func evaluate(doc: CanonicalProjectDocument, audio: AudioManifest, descriptors: [ResolvedAudioSourceDescriptor]) throws -> AudioPlan {
        let manifest = injectAudio(doc, audio)
        let index = try TimelineIndex(manifest: manifest)
        let duration = try manifest.projectDuration()
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: duration.ticks))
        let requirement = try index.requirements(for: coverage)
        let window = try AudioEvaluationWindowBuilder.build(
            manifest: manifest, requirement: requirement,
            scenes: doc.scenePayloads, sourceDescriptors: descriptors)
        return try AudioEvaluator.evaluate(window: window, range: window.coverage)
    }

    private func videoBuilt(blockID: String, sceneIDRaw: String, sceneDurationUs: Int64 = 3_000_000) throws -> AppVideoOriginalAudioBridge.Built {
        try AppVideoOriginalAudioBridge.build(.init(
            blockID: blockID, sceneInstanceIDRaw: sceneIDRaw, mediaReferenceRaw: "audio.videoLayer:0:\(blockID)",
            winStart: 0, winEnd: 3, volume: 1, isMuted: false,
            sceneStartUs: 0, sceneDurationUs: sceneDurationUs,
            realAudioTrackDurationSeconds: 1000,
            blockStartUsInScene: 0, blockEndUsInScene: sceneDurationUs))
    }

    // MARK: - Video-only project → non-empty AudioPlan with a .videoLayer segment

    func test_videoOnly_producesNonEmptyPlanWithVideoLayerSegment() throws {
        let sceneIDRaw = "scene-0-\(UUID().uuidString)"
        let built = try videoBuilt(blockID: "block_01", sceneIDRaw: sceneIDRaw)
        let doc = try makeDocument(
            sceneDurationUs: 3_000_000, layers: [built.layer],
            sceneIDRaw: sceneIDRaw, payloadIDRaw: "payload-0")
        let audio = AudioManifest(sources: [built.source], tracks: [built.track], clips: [built.clip])

        let plan = try evaluate(doc: doc, audio: audio, descriptors: [built.descriptor])
        XCTAssertFalse(plan.segments.isEmpty, "video-only project must produce a non-empty AudioPlan")
        XCTAssertTrue(plan.segments.contains { $0.role == .videoLayer }, "a .videoLayer segment is present")
    }

    // MARK: - Music + video-original → BOTH a music and a videoLayer segment

    func test_musicPlusVideo_producesBothSegments() throws {
        let sceneIDRaw = "scene-0-\(UUID().uuidString)"
        let v = try videoBuilt(blockID: "block_01", sceneIDRaw: sceneIDRaw)

        // A music clip on the same scene span (global audio).
        let musicSourceID = try AudioSourceID("app.audio.source.imported:music")
        let musicTrackID = try AudioTrackID("app.audio.track.music")
        let musicSource = AudioSourceEntry(id: musicSourceID, asset: .globalAudio(try GlobalAudioAssetID("g.music")))
        let musicTrack = AudioTrackEntry(id: musicTrackID, role: .music)
        let musicClip = AudioClipEntry(
            id: try AudioClipID("app.audio.clip.music"), trackID: musicTrackID, sourceID: musicSourceID,
            videoLayer: nil,
            destination: try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 720_000)),
            sourceTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 3, denominator: 1)),
            gain: .unity, isMuted: false, playbackPolicy: .once)
        let musicDescriptor = ResolvedAudioSourceDescriptor(
            sourceID: musicSourceID, streamIdentity: try AudioStreamIdentity("stream:music"),
            sourceDuration: try RationalSourceTime(numerator: 3, denominator: 1), sampleRate: 48_000, channelLayout: .mono)

        let doc = try makeDocument(
            sceneDurationUs: 3_000_000, layers: [v.layer],
            sceneIDRaw: sceneIDRaw, payloadIDRaw: "payload-0")
        let audio = AudioManifest(
            sources: [musicSource, v.source], tracks: [musicTrack, v.track], clips: [musicClip, v.clip])

        let plan = try evaluate(doc: doc, audio: audio, descriptors: [musicDescriptor, v.descriptor])
        XCTAssertFalse(plan.segments.isEmpty)
        XCTAssertTrue(plan.segments.contains { $0.role == .music }, "music segment present")
        XCTAssertTrue(plan.segments.contains { $0.role == .videoLayer }, "videoLayer segment present")
    }

    // MARK: - P0: same blockID in TWO scenes → distinct IDs, no collision, two videoLayer segments

    /// A two-scene document where BOTH scenes carry a video block with the SAME `blockID` but DIFFERENT
    /// scene instance ids + different video URLs. Proves: distinct AudioSourceID/AudioClipID, no duplicate
    /// manifest ids (the evaluator/window builder would throw on a duplicate), two videoLayer segments.
    func test_sameBlockIdAcrossTwoScenes_noCollision_twoSegments() throws {
        let sceneA = "scene-0-\(UUID().uuidString)"
        let sceneB = "scene-1-\(UUID().uuidString)"
        let a = try AppVideoOriginalAudioBridge.build(.init(
            blockID: "block_01", sceneInstanceIDRaw: sceneA, mediaReferenceRaw: "audio.videoLayer:0:block_01",
            winStart: 0, winEnd: 3, volume: 1, isMuted: false,
            sceneStartUs: 0, sceneDurationUs: 3_000_000, realAudioTrackDurationSeconds: 1000,
            blockStartUsInScene: 0, blockEndUsInScene: 3_000_000))
        let b = try AppVideoOriginalAudioBridge.build(.init(
            blockID: "block_01", sceneInstanceIDRaw: sceneB, mediaReferenceRaw: "audio.videoLayer:1:block_01",
            winStart: 0, winEnd: 3, volume: 1, isMuted: false,
            sceneStartUs: 3_000_000, sceneDurationUs: 3_000_000, realAudioTrackDurationSeconds: 1000,
            blockStartUsInScene: 0, blockEndUsInScene: 3_000_000))

        // Distinct ids despite identical blockID.
        XCTAssertNotEqual(a.source.id, b.source.id, "two scenes' video sources must have distinct AudioSourceID")
        XCTAssertNotEqual(a.clip.id, b.clip.id, "distinct AudioClipID")
        XCTAssertNotEqual(a.sourceRaw, b.sourceRaw, "distinct sourceRaw (→ resolvedSourcesByID keeps both URLs)")

        // Build a 2-scene document with each scene's `.video` layer on its own payload.
        let docA = try makeDocument(sceneDurationUs: 3_000_000, layers: [a.layer], sceneIDRaw: sceneA, payloadIDRaw: "payload-0")
        let docB = try makeDocument(sceneDurationUs: 3_000_000, layers: [b.layer], sceneIDRaw: sceneB, payloadIDRaw: "payload-1")
        let twoScene = try makeTwoSceneDocument(a: docA, b: docB)
        let audio = AudioManifest(
            sources: [a.source, b.source], tracks: [a.track, b.track], clips: [a.clip, b.clip])

        // resolvedSourcesByID analogue: two distinct raws → two URLs, no overwrite.
        var resolved: [String: URL] = [:]
        resolved[a.sourceRaw] = URL(fileURLWithPath: "/tmp/a.mov")
        resolved[b.sourceRaw] = URL(fileURLWithPath: "/tmp/b.mov")
        XCTAssertEqual(resolved.count, 2, "both URLs retained (no overwrite)")

        let plan = try evaluate(doc: twoScene, audio: audio, descriptors: [a.descriptor, b.descriptor])
        let videoSegs = plan.segments.filter { $0.role == .videoLayer }
        XCTAssertEqual(videoSegs.count, 2, "two videoLayer segments (one per scene)")
        XCTAssertEqual(Set(videoSegs.map { $0.sourceID }).count, 2, "two distinct segment sourceIDs")
    }

    // MARK: - P1 evaluator proof: scene-filling video clip → segment.sourceStart == winStart

    /// winStart > 0, scene at a NON-zero project start, block fills the scene → the evaluator's scene-local
    /// clock makes `sceneMediaTime = 0` at the scene start, so `sourceStart == winStart` (not advanced).
    func test_sceneFilling_evaluatorSourceStartEqualsWinStart() throws {
        let sceneIDRaw = "scene-1-\(UUID().uuidString)"
        // winStart = 2s; scene at project 3s, duration 3s; block fills it.
        let built = try AppVideoOriginalAudioBridge.build(.init(
            blockID: "b", sceneInstanceIDRaw: sceneIDRaw, mediaReferenceRaw: "audio.videoLayer:1:b",
            winStart: 2, winEnd: 5, volume: 1, isMuted: false,
            sceneStartUs: 3_000_000, sceneDurationUs: 3_000_000, realAudioTrackDurationSeconds: 1000,
            blockStartUsInScene: 0, blockEndUsInScene: 3_000_000))
        // Single-scene doc whose scene starts at project 3s (a leading empty scene shifts it).
        let lead = try makeDocument(sceneDurationUs: 3_000_000, layers: [], sceneIDRaw: "scene-0-lead", payloadIDRaw: "payload-lead")
        let main = try makeDocument(sceneDurationUs: 3_000_000, layers: [built.layer], sceneIDRaw: sceneIDRaw, payloadIDRaw: "payload-1")
        let doc = try makeTwoSceneDocument(a: lead, b: main)
        let audio = AudioManifest(sources: [built.source], tracks: [built.track], clips: [built.clip])

        let plan = try evaluate(doc: doc, audio: audio, descriptors: [built.descriptor])
        let seg = try XCTUnwrap(plan.segments.first { $0.role == .videoLayer }, "videoLayer segment present")
        // sourceStart == winStart (2s) — the source is NOT advanced by the scene's 3s project offset.
        XCTAssertEqual(seg.sourceStart, try RationalSourceTime(numerator: 2, denominator: 1),
            "scene-filling clip: sourceStart == winStart (scene-local clock = 0 at scene start)")
    }

    // MARK: - Mismatched scene/layer/media fails typed (not silent)

    func test_mismatchedLayer_failsTypedNotSilent() throws {
        let sceneIDRaw = "scene-0-\(UUID().uuidString)"
        let built = try videoBuilt(blockID: "block_01", sceneIDRaw: sceneIDRaw)
        // Build the document with NO layers (empty) → the video-layer clip cannot resolve its binding.
        let doc = try makeDocument(
            sceneDurationUs: 3_000_000, layers: [],
            sceneIDRaw: sceneIDRaw, payloadIDRaw: "payload-0")
        let audio = AudioManifest(sources: [built.source], tracks: [built.track], clips: [built.clip])
        XCTAssertThrowsError(try evaluate(doc: doc, audio: audio, descriptors: [built.descriptor]),
            "a video-layer clip with no matching .video payload layer must fail typed, not silently drop")
    }
}
#endif
