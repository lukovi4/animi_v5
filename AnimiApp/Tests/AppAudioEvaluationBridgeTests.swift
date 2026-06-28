import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage B — `AppAudioEvaluationBridge`: app editor state → canonical `AudioEvaluationWindow`
/// + `AudioPlan` through the canonical `AudioEvaluator` (never legacy `AVMutableComposition`).
final class AppAudioEvaluationBridgeTests: XCTestCase {

    // MARK: - Fake probe

    private final class FakeProbe: AppAudioSourceDescriptorResolver.Probe {
        var bySource: [String: [AppAudioSourceDescriptorResolver.ProbeResult]] = [:]
        /// When set, every referenced source resolves to this single result (convenience).
        var defaultResult: AppAudioSourceDescriptorResolver.ProbeResult?
        func probe(sourceID: AudioSourceID) throws -> [AppAudioSourceDescriptorResolver.ProbeResult] {
            if let explicit = bySource[sourceID.raw] { return explicit }
            if let d = defaultResult { return [d] }
            return []
        }
    }

    private func result() -> AppAudioSourceDescriptorResolver.ProbeResult {
        .init(sampleRate: 48_000, channelCount: 2, durationNumerator: 10, durationDenominator: 1,
              streamIdentityRaw: "stream")
    }

    // MARK: - Minimal canonical VIDEO document (manifest.audio == .empty), self-contained.

    /// A single-scene document with no layers — sufficient for a *global* audio plan (global audio binds
    /// 1/1 and references no scene layer). Its `manifest.audio` is `.empty`, exactly like the app's
    /// `NextTimelineBridge` output, so the bridge must inject audio itself.
    private func videoDocument(sceneDurationTicks: Int64 = 720_000) throws -> CanonicalProjectDocument {
        let sceneID = try SceneInstanceID("s0")
        let payloadID = try ScenePayloadID("p0")
        let entry = SceneManifestEntry(
            id: sceneID, payloadID: payloadID,
            nominalDuration: try TickDuration(ticks: sceneDurationTicks),
            postRollCapability: .zero)
        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: .fps30),
            scenes: [entry], boundaryTransitions: [], overlays: [])
        XCTAssertTrue(manifest.audio.isEmpty, "video document must start with empty audio")
        let payload = ResolvedScenePayload(
            payloadID: payloadID, sceneID: sceneID,
            templateRef: try TemplateReference(catalogID: "cat", sceneID: "tpl"), layers: [])
        return CanonicalProjectDocument(manifest: manifest, scenePayloads: [payload], overlayPayloads: [])
    }

    // MARK: - App audio items

    private func musicItem(
        index: Int = 0, startUs: Int64 = 0, durationUs: Int64 = 1_000_000, assetID: String = "m"
    ) -> AppAudioManifestBridge.Input {
        AppAudioManifestBridge.Input(
            index: index, startUs: startUs, durationUs: durationUs,
            payload: AudioPayload(assetRef: .bundled(id: assetID), sourceDurationUs: durationUs,
                                  trimStartUs: 0, trimEndUs: durationUs, volume: 1.0, role: .music))
    }

    private func evaluate(
        _ items: [AppAudioManifestBridge.Input], probe: FakeProbe
    ) throws -> AppAudioEvaluationBridge.Result {
        try AppAudioEvaluationBridge.evaluateWholeProject(
            videoDocument: try videoDocument(), audioItems: items,
            includeOriginalFromVideoSlots: false, probe: probe)
    }

    // MARK: - empty audio → valid silent plan (NOT error)

    func testEmptyAudioProducesValidSilentPlan() throws {
        let probe = FakeProbe()
        let r = try evaluate([], probe: probe)
        XCTAssertTrue(r.window.clips.isEmpty, "no clips for empty app audio")
        XCTAssertTrue(r.plan.segments.isEmpty, "silent plan: zero segments")
        // A silent plan is still a valid plan over the project sample interval (no throw above).
        XCTAssertFalse(r.plan.sampleInterval.isEmpty, "non-empty project → non-empty sample interval")
    }

    // MARK: - one global music item → non-empty AudioPlan

    func testOneGlobalMusicItemProducesNonEmptyPlan() throws {
        let probe = FakeProbe(); probe.defaultResult = result()
        let r = try evaluate([musicItem()], probe: probe)
        XCTAssertEqual(r.window.clips.count, 1)
        XCTAssertFalse(r.plan.segments.isEmpty, "global music must yield at least one segment")
        XCTAssertEqual(r.plan.segments.first?.role, .music)
    }

    // MARK: - non-grid TimeUs from Stage A flows through to the plan

    func testNonGridTimeUsFlowsThroughToPlan() throws {
        let probe = FakeProbe(); probe.defaultResult = result()
        // 500_111µs start, non-25µs-aligned — Stage A projects outward; the segment must exist.
        let r = try evaluate(
            [musicItem(startUs: 100_111, durationUs: 300_333)], probe: probe)
        XCTAssertEqual(r.window.clips.count, 1)
        XCTAssertFalse(r.plan.segments.isEmpty, "non-grid TimeUs must still produce a segment")
        // The destination start is the outward-projected floor tick (100_111*6/25 = 24_026).
        XCTAssertEqual(r.window.clips.first?.destination.start.ticks, 24_026)
    }

    // MARK: - missing / ambiguous descriptor → typed failure

    func testMissingDescriptorFailsTyped() throws {
        let probe = FakeProbe() // no result for the referenced source
        XCTAssertThrowsError(try evaluate([musicItem()], probe: probe)) { error in
            guard case .missingSourceDescriptor? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected missingSourceDescriptor, got \(error)")
            }
        }
    }

    func testAmbiguousDescriptorFailsTyped() throws {
        let probe = FakeProbe()
        let doc = try videoDocument()
        // Resolve the canonical source id the bridge will derive, give it two descriptors.
        let manifest = try AppAudioManifestBridge.buildManifest(
            items: [musicItem()], includeOriginalFromVideoSlots: false)
        probe.bySource[manifest.sources.first!.id.raw] = [result(), result()]
        XCTAssertThrowsError(
            try AppAudioEvaluationBridge.evaluateWholeProject(
                videoDocument: doc, audioItems: [musicItem()],
                includeOriginalFromVideoSlots: false, probe: probe)
        ) { error in
            guard case .duplicateSourceDescriptor? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected duplicateSourceDescriptor, got \(error)")
            }
        }
    }

    // MARK: - canonical rules: .once only, no loop, video-layer refused, no export type touched

    func testPlaybackPolicyOnceAndNoLoop() throws {
        let probe = FakeProbe(); probe.defaultResult = result()
        let r = try evaluate([musicItem()], probe: probe)
        XCTAssertEqual(r.window.clips.first?.playbackPolicy, .once)
        XCTAssertEqual(r.plan.segments.first?.role, .music)
    }

    func testVideoLayerOriginalAudioRefused() throws {
        let probe = FakeProbe(); probe.defaultResult = result()
        XCTAssertThrowsError(
            try AppAudioEvaluationBridge.evaluateWholeProject(
                videoDocument: try videoDocument(), audioItems: [musicItem()],
                includeOriginalFromVideoSlots: true, probe: probe)
        ) { error in
            XCTAssertEqual(
                error as? AppRealtimeAudioIntegrationError, .videoLayerOriginalAudioUnsupportedInStageA)
        }
    }

    /// Structural: the Stage-B bridge source references the canonical `AudioEvaluator` and none of the
    /// legacy AVFoundation composition/mix symbols (proof it is NOT the legacy audio path).
    func testBridgeUsesCanonicalEvaluatorNotLegacyComposition() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EditorRuntime/Realtime/AppAudioEvaluationBridge.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        // The canonical-evaluator reference is real code.
        XCTAssertTrue(raw.contains("AudioEvaluator.evaluate"), "must use the canonical AudioEvaluator")
        // Strip line comments — the doc comment legitimately *documents the absence* of legacy types
        // (e.g. "never legacy AVMutableComposition/AVAudioMix"); only executable code is checked.
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
        for banned in ["AVMutableComposition", "AVAudioMix", "AVAssetReader", "buildTimeline", "setVolumeRamp"] {
            XCTAssertFalse(code.contains(banned), "Stage-B bridge code must not reference legacy \(banned)")
        }
    }

    // MARK: - deterministic output ordering

    func testDeterministicPlanOrdering() throws {
        let probe = FakeProbe(); probe.defaultResult = result()
        let items = [
            musicItem(index: 0, startUs: 600_000, durationUs: 100_000, assetID: "c"),
            musicItem(index: 1, startUs: 0, durationUs: 100_000, assetID: "a"),
            musicItem(index: 2, startUs: 300_000, durationUs: 100_000, assetID: "b"),
        ]
        let a = try evaluate(items, probe: probe)
        let b = try evaluate(items, probe: probe)
        XCTAssertEqual(a.plan, b.plan, "evaluation must be deterministic")
        let starts = a.plan.segments.map(\.destinationSamples.start)
        XCTAssertEqual(starts, starts.sorted(), "segments ordered by destination start")
    }
}
