import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage 4 — wiring the REAL cached canonical PCM render pipeline into the preview controller.
///
/// Proves (without AVFoundation / device): the production builder assembles the real
/// `CachedCanonicalAudioRenderPipeline` (no `UnavailableCanonicalAudioRenderPipeline` default), and a
/// controller built with the REAL cache + pipeline + `BackgroundCanonicalPCMRenderer` driven by a TEST-ONLY
/// fixture decoder runs the full async-preroll + first-frame-barrier + schedule-to-sink lifecycle.
@MainActor
final class CanonicalProductionRenderPipelineWiringTests: XCTestCase {

    // MARK: - Fixtures

    private static func range(samples: Int64) throws -> AudioSampleRange {
        try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: samples * AudioSampleGrid.ticksPerSample)))
    }

    private static func musicPlan(samples: Int64 = 8) throws -> AudioPlan {
        let r = try range(samples: samples)
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("c0"), sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .music, destinationSamples: r, sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        return AudioPlan(sampleInterval: r, segments: [seg])
    }

    // MARK: - Test-only fixture decoder (no AVFoundation, deterministic)

    private actor FixtureDecoder: CanonicalPCMAssetDecoder {
        enum Mode: Sendable { case ramp, throwUnsupported }
        private let mode: Mode
        init(mode: Mode = .ramp) { self.mode = mode }
        func decodeMono48kFloat32(_ request: CanonicalPCMAssetDecodeRequest) async throws -> [Float32] {
            switch mode {
            case .ramp: return (0..<request.frameCount).map { Float32($0 + 1) }
            case .throwUnsupported:
                throw AppRealtimeAudioIntegrationError.mediaUnsupported(sourceRaw: request.sourceIDRaw, detail: "fixture")
            }
        }
    }

    /// Build the REAL cached pipeline (Stage 1/2/3) over a fixture decoder — the production stack minus AV.
    private func realPipeline(decoderMode: FixtureDecoder.Mode = .ramp, capacity: Int = 4) throws -> CanonicalAudioRenderPipeline {
        let renderer = BackgroundCanonicalPCMRenderer(decoder: FixtureDecoder(mode: decoderMode))
        let cache = try CanonicalPCMRenderCache.make(capacity: capacity, renderer: renderer)
        return CachedCanonicalAudioRenderPipeline(cache: cache)
    }

    // MARK: - Controller boundary fakes (no AVFoundation)

    private final class RecordingSink: PreviewAudioOutputSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _scheduled: [(range: AudioSampleRange, samples: [Float32], at: Int64)] = []
        var scheduled: [(range: AudioSampleRange, samples: [Float32], at: Int64)] { lock.lock(); defer { lock.unlock() }; return _scheduled }
        func configure(outputFormat: AudioOutputFormat, route: AudioOutputRoute) throws {}
        func scheduleMixed(range: AudioSampleRange, samples: [Float32], at outputSampleTime: Int64) throws {
            lock.lock(); _scheduled.append((range, samples, outputSampleTime)); lock.unlock()
        }
    }

    private final class FakeSession: AudioSessionAdapter, @unchecked Sendable {
        private(set) var isActive = false
        private let q: AudioOutputQuery
        init(query: AudioOutputQuery) { self.q = query }
        func activate() throws { isActive = true }
        func deactivate() throws { isActive = false }
        func queryActualOutput() throws -> AudioOutputQuery {
            guard isActive else { throw RealtimeAudioBoundaryError.queryBeforeActivation }
            return q
        }
    }

    private final class FakePlanSource: ProductionPreviewAudioPlanSource {
        let plan: AudioPlan?
        init(plan: AudioPlan?) { self.plan = plan }
        func currentAudioPlan() throws -> AudioPlan? { plan }
    }

    private func query() throws -> AudioOutputQuery {
        AudioOutputQuery(format: try AudioOutputFormat(sampleRate: 48_000, channelLayout: .stereo),
                         route: try AudioOutputRoute(identifier: "speaker"))
    }

    /// Build a controller wired to the REAL pipeline + a fixture decoder, with a resolved source for "s0".
    private func makeController(
        plan: AudioPlan?, decoderMode: FixtureDecoder.Mode = .ramp,
        projectHasAudio: @escaping () -> Bool = { true }
    ) throws -> (CanonicalPreviewAudioController, RecordingSink) {
        let sink = RecordingSink()
        let controller = CanonicalPreviewAudioControllerFactory.makeController(
            planSource: FakePlanSource(plan: plan),
            sink: sink,
            adapter: try FakeSession(query: query()),
            renderPipeline: try realPipeline(decoderMode: decoderMode),
            resolvedSources: { ["s0": CanonicalResolvedAudioSource(url: URL(fileURLWithPath: "/tmp/s0"))] },
            projectHasAudio: projectHasAudio)
        return (controller, sink)
    }

    private func drainPreroll(_ controller: CanonicalPreviewAudioController) async {
        #if DEBUG
        for _ in 0..<400 { if !controller.hasInFlightPrerollTask { break }; await Task.yield() }
        #endif
    }

    // MARK: - 1. Production builder returns the REAL cached pipeline (not the placeholder)

    func testProductionRenderPipelineIsCachedCanonicalRenderPipeline() throws {
        let pipeline = try CanonicalPreviewAudioControllerFactory.makeProductionRenderPipeline()
        XCTAssertTrue(pipeline is CachedCanonicalAudioRenderPipeline,
            "production builder must return the real CachedCanonicalAudioRenderPipeline")
        XCTAssertFalse(pipeline is UnavailableCanonicalAudioRenderPipeline,
            "production builder must NOT return the unavailable placeholder")
    }

    // MARK: - 2. Builder fails closed on non-positive capacity

    func testProductionRenderPipelineRejectsNonPositiveCapacity() {
        XCTAssertThrowsError(try CanonicalPreviewAudioControllerFactory.makeProductionRenderPipeline(cacheCapacity: 0)) { error in
            guard case AppRealtimeAudioIntegrationError.invalidPCMRenderCacheCapacity(0) = error else {
                return XCTFail("expected .invalidPCMRenderCacheCapacity(0), got \(error)")
            }
        }
        XCTAssertThrowsError(try CanonicalPreviewAudioControllerFactory.makeProductionRenderPipeline(cacheCapacity: -1))
    }

    // MARK: - 3. Full lifecycle: non-empty plan → async preroll → first-frame → schedule → start (both ready)

    func testRealPipelineControllerStartsOnlyAfterPrerollAndFirstFrame() async throws {
        let (controller, sink) = try makeController(plan: try Self.musicPlan())

        controller.startPlayback(fromSeconds: 0, hostTime: 0)

        // PHASE 1: epoch pending, awaiting both the async preroll render AND the first frame. Nothing
        // scheduled, no active session yet.
        #if DEBUG
        XCTAssertTrue(controller.hasPendingSessionAwaitingFirstFrame, "epoch pending after startPlayback")
        #endif
        XCTAssertNil(controller.activeSession, "must NOT start before first frame + preroll")
        XCTAssertTrue(sink.scheduled.isEmpty, "nothing scheduled before the barrier crosses")

        // Drain the REAL async preroll render (cache → BackgroundCanonicalPCMRenderer → fixture decoder).
        await drainPreroll(controller)
        // Preroll ready but first frame NOT signalled yet → still no start, still nothing scheduled.
        XCTAssertNil(controller.activeSession, "preroll alone must not start playback")
        XCTAssertTrue(sink.scheduled.isEmpty, "preroll alone schedules nothing")

        // Second barrier side: the first frame. NOW it crosses → schedule + start.
        controller.signalFirstFrameReady()
        XCTAssertNotNil(controller.activeSession, "first frame + preroll → canonical session starts")
        XCTAssertFalse(sink.scheduled.isEmpty, "decoded preroll samples scheduled into the sink")
        // The scheduled samples are the fixture ramp (real decode-free render through the real pipeline).
        let total = sink.scheduled.reduce(0) { $0 + $1.samples.count }
        XCTAssertGreaterThan(total, 0, "non-empty decoded samples reached the graph/sink")
    }

    // MARK: - 4. Non-empty plan render FAILURE → canonical unavailable / fallback, never silence

    func testNonEmptyRenderFailureRoutesToUnavailableNotSilence() async throws {
        let (controller, sink) = try makeController(plan: try Self.musicPlan(), decoderMode: .throwUnsupported)
        var unavailableReason: String?
        controller.onCanonicalUnavailable = { reason in unavailableReason = reason }

        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        // Give the failed preroll task a moment to route through prerollPrepareFailed → onCanonicalUnavailable.
        for _ in 0..<400 { if unavailableReason != nil { break }; await Task.yield() }

        XCTAssertNotNil(unavailableReason, "non-empty render failure must route to canonical-unavailable (legacy fallback)")
        XCTAssertNil(controller.activeSession, "a failed non-empty render must NOT start an audible session")
        XCTAssertTrue(sink.scheduled.isEmpty, "render failure must NOT schedule silence/partial audio")
    }

    // MARK: - 5. Empty plan → legitimate silent epoch (no schedule, no unavailable)

    func testEmptyPlanIsLegitimateSilence() async throws {
        // Empty plan + project genuinely has NO audio → silent epoch is legitimate (no fallback).
        let r = try Self.range(samples: 8)
        let empty = AudioPlan(sampleInterval: r, segments: [])
        let (controller, sink) = try makeController(plan: empty, projectHasAudio: { false })
        var unavailableReason: String?
        controller.onCanonicalUnavailable = { reason in unavailableReason = reason }

        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()

        XCTAssertNil(controller.activeSession, "empty plan = silent epoch, no audio-bearing session")
        XCTAssertTrue(sink.scheduled.isEmpty, "silent epoch schedules nothing")
        XCTAssertNil(unavailableReason, "legitimate silence must NOT trigger the legacy fallback")
    }

    // MARK: - 6. nil plan over a project WITH audio → fail-closed fallback (canonical miss)

    func testNilPlanWithAudioRoutesToUnavailable() async throws {
        let (controller, sink) = try makeController(plan: nil, projectHasAudio: { true })
        var unavailableReason: String?
        controller.onCanonicalUnavailable = { reason in unavailableReason = reason }

        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        XCTAssertNotNil(unavailableReason, "nil plan but project has audio → canonical miss → legacy fallback")
        XCTAssertNil(controller.activeSession)
        XCTAssertTrue(sink.scheduled.isEmpty)
    }
}
