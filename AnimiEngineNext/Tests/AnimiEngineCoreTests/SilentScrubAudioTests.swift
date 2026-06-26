import XCTest
@testable import AnimiEngineCore

/// Slice-004 Stage H — silent-scrub guarantee (ADR-006 §7, ADR-012 §6).
///
/// Scrub NEVER starts/prepares/schedules audio. `scrubSettlePreview(startAudibleAudio: false)` stays
/// silent; `…(startAudibleAudio: true)` is a typed fail-closed rejection with no scheduling. Settle
/// after a scrub leaves the session paused/not-playing and never prerolls audio. Audio preroll is
/// admitted ONLY on explicit play. A behavioural proof (a fake sink that records every scheduled buffer)
/// plus a structural proof (the scrub entrypoint references none of the scheduling symbols) keep the
/// guarantee enforced.
final class SilentScrubAudioTests: XCTestCase {

    // MARK: - Fakes (no AVFoundation)

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

    /// Records EVERY scheduled mixed buffer. If scrub schedules audio, this is non-empty — the test fails.
    private final class RecordingSink: PreviewAudioOutputSink, @unchecked Sendable {
        var scheduled: [(range: AudioSampleRange, samples: [Float32], at: Int64)] = []
        var configureCount = 0
        func configure(outputFormat: AudioOutputFormat, route: AudioOutputRoute) throws { configureCount += 1 }
        func scheduleMixed(range: AudioSampleRange, samples: [Float32], at outputSampleTime: Int64) throws {
            scheduled.append((range, samples, outputSampleTime))
        }
    }

    // MARK: - Builders

    private func rev(_ r: Int64) -> ProjectRevision { ProjectRevision(raw: r) }
    private func ep(_ e: Int64) -> PlaybackEpoch { PlaybackEpoch(raw: e) }
    private func range(_ s: Int64, _ e: Int64) -> AudioSampleRange { AudioSampleRange(uncheckedStart: s, end: e) }

    private func query() throws -> AudioOutputQuery {
        AudioOutputQuery(
            format: try AudioOutputFormat(sampleRate: 48_000, channelLayout: .stereo),
            route: try AudioOutputRoute(identifier: "built-in-speaker"))
    }

    private func anchor() -> PreviewAudioScheduleAnchor {
        PreviewAudioScheduleAnchor(revision: rev(1), epoch: ep(1), projectSample: 0, outputSampleTime: 0)
    }

    private func snapshot() throws -> SchedulerSnapshot {
        SchedulerSnapshot(
            revision: rev(1), epoch: ep(1),
            coverage: try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 10_000_000)),
            currentTarget: CurrentTarget(time: .zero, frameRequest: FrameRequestID(raw: 1)),
            lastPublished: nil)
    }

    private func source(samples: [Float32], chunkStart: Int64, chunkEnd: Int64) throws -> PreviewMixSource {
        PreviewMixSource(
            buffer: try PreparedAudioBuffer(
                revision: rev(1), epoch: ep(1), request: AudioRequestID(raw: 1),
                sourceID: try AudioSourceID("A"), chunkRange: range(chunkStart, chunkEnd),
                streamIdentity: try AudioStreamIdentity("stream-A"),
                sourceSampleRate: 48_000, channelLayout: .stereo, isMuted: false, gain: .unity,
                payload: try PreparedAudioPayloadHandle(identifier: "pcm:A")),
            samples: samples)
    }

    /// An audio-bearing session with output + anchor configured and first frame ready, but NO preroll
    /// scheduled yet — the realistic "about to scrub" state.
    private func preparedAudioSession() throws -> (AudioMasterPreviewSession, RecordingSink) {
        let session = FakeSession(query: try query())
        let sink = RecordingSink()
        let graph = try PreviewAudioGraph(
            session: session, sink: sink, epoch: ep(1), revision: rev(1), maxChunkSamples: 1_024)
        try session.activate()
        let s = try AudioMasterPreviewSession(
            revision: rev(1), epoch: ep(1), graph: graph,
            selectedClock: SelectedMasterClock(
                kind: .audioSample,
                clock: AudioSampleMasterClock(anchorProjectTime: .zero, currentSampleTime: { 0 })),
            timeoutTicks: 10_000, startTick: 0)
        try s.configureOutput()
        try s.configureAnchor(anchor())
        try s.markFirstFrameReady()
        return (s, sink)
    }

    // MARK: - 2. scrubSettlePreview(false) stays silent

    func testScrubSettleSilentSchedulesNoAudio() throws {
        let (s, sink) = try preparedAudioSession()
        // Many scrub/settle iterations — none may schedule any audio.
        for _ in 0..<25 {
            XCTAssertNoThrow(try s.scrubSettlePreview(startAudibleAudio: false))
        }
        XCTAssertTrue(sink.scheduled.isEmpty, "scrub/settle must schedule NO audio")
    }

    // MARK: - 3. scrubSettlePreview(true) fail-closed, no scheduling

    func testScrubRequestingAudioFailsClosedWithoutScheduling() throws {
        let (s, sink) = try preparedAudioSession()
        XCTAssertThrowsError(try s.scrubSettlePreview(startAudibleAudio: true)) { error in
            XCTAssertEqual(error as? AudioMasterPreviewSessionError, .scrubMustNotStartAudio)
        }
        XCTAssertTrue(sink.scheduled.isEmpty, "a rejected scrub-audio request schedules nothing")
    }

    // MARK: - 4. Settle after scrub does not auto-play / does not preroll audio

    func testSettleAfterScrubDoesNotAutoPlayOrPreroll() throws {
        let (s, sink) = try preparedAudioSession()
        try s.scrubSettlePreview(startAudibleAudio: false)
        // Settle leaves the session NOT started: the audio gate is still unmet, so start fails closed and
        // no preroll exists.
        XCTAssertFalse(s.barrier.satisfied.contains(.initialAudioScheduled),
            "settle must not mark the audio gate")
        XCTAssertThrowsError(try s.start()) { error in
            guard case .notReadyToStart(let missing)? = error as? AudioMasterPreviewSessionError else {
                return XCTFail("expected notReadyToStart, got \(error)")
            }
            XCTAssertTrue(missing.contains(.initialAudioScheduled),
                "no audio preroll happened during scrub/settle")
        }
        XCTAssertTrue(sink.scheduled.isEmpty)
    }

    // MARK: - 5. Explicit play path still works (preroll allowed only here)

    func testExplicitPlayStillSchedulesPrerollAfterScrub() throws {
        let (s, sink) = try preparedAudioSession()
        // A scrub first (silent), THEN an explicit play preroll — only the explicit play schedules audio.
        try s.scrubSettlePreview(startAudibleAudio: false)
        XCTAssertTrue(sink.scheduled.isEmpty)

        let didSchedule = try s.scheduleInitialAudioPreroll(
            InitialAudioPreroll(
                anchor: anchor(), range: range(0, 2),
                sources: [try source(samples: [0.1, 0.1], chunkStart: 0, chunkEnd: 2)]),
            against: try snapshot())
        XCTAssertTrue(didSchedule, "explicit play preroll must succeed")
        XCTAssertEqual(sink.scheduled.count, 1, "exactly the explicit-play preroll reached the sink")
        let started = try s.start()
        XCTAssertTrue(started.barrier.isReady)
        XCTAssertTrue(started.scheduledInitialPreroll)
    }

    // MARK: - 6. Stage G pause-only behaviour does not regress

    func testScrubDoesNotInteractWithPauseInvalidation() throws {
        let (s, sink) = try preparedAudioSession()
        // Scrub does not invalidate the session (it is not a session event); explicit-play remains open.
        try s.scrubSettlePreview(startAudibleAudio: false)
        XCTAssertFalse(s.isInvalidated, "scrub must not invalidate the session")
        // A real route-change event still pauses/invalidates pause-only (Stage G unchanged).
        try s.handleSessionEvent(.routeChanged(.oldDeviceUnavailable))
        XCTAssertTrue(s.isInvalidated)
        // And after invalidation, scrub stays silent and scheduling stays refused.
        XCTAssertNoThrow(try s.scrubSettlePreview(startAudibleAudio: false))
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(
            InitialAudioPreroll(anchor: anchor(), range: range(0, 2),
                sources: [try source(samples: [0.1, 0.1], chunkStart: 0, chunkEnd: 2)]),
            against: try snapshot())) { error in
            XCTAssertEqual(error as? AudioMasterPreviewSessionError, .schedulingAfterSessionInvalidated)
        }
        XCTAssertTrue(sink.scheduled.isEmpty)
    }

    // MARK: - 1. Structural: the scrub entrypoint references NO scheduling symbol

    /// Extract the body of `scrubSettlePreview(...)` and assert it calls none of the audio
    /// preparation/graph/scheduling symbols — the silent-scrub guarantee proven at the source level, not
    /// only behaviourally.
    func testScrubEntrypointReferencesNoSchedulingSymbol() throws {
        let src = strippingLineComments(try sessionSource())
        guard let body = methodBody(of: "func scrubSettlePreview", in: src) else {
            return XCTFail("could not locate scrubSettlePreview body")
        }
        for banned in [
            "AudioChunkPreparer", "PreviewAudioGraph", "scheduleMix",
            "scheduleInitialAudioPreroll", ".prepare(", "graph.",
        ] {
            XCTAssertFalse(body.contains(banned),
                "scrubSettlePreview must not reference \(banned) (silent-scrub guarantee)")
        }
    }

    // MARK: - 7. Stage H forbidden types absent

    func testStageHForbiddenTypesAbsent() throws {
        let dir = realtimeDir()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in [
                "RealtimeRenderCallback", "AudioRenderTap", "AudioEngineDriver",
                "InterruptionResumeCoordinator", "ResumeCoordinator", "BackgroundAudioContinuation",
                "BackgroundContinuation",
            ] {
                XCTAssertFalse(text.contains(banned),
                    "\(file.lastPathComponent): Stage-H forbidden type \(banned) present")
            }
        }
    }

    // MARK: - Helpers

    private func realtimeDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AnimiEngineCore/Realtime", isDirectory: true)
    }

    private func sessionSource() throws -> String {
        try String(contentsOf: realtimeDir().appendingPathComponent("AudioMasterPreviewSession.swift"),
                   encoding: .utf8)
    }

    private func strippingLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    /// Returns the brace-balanced body of the first method whose signature contains `signature`.
    private func methodBody(of signature: String, in src: String) -> String? {
        guard let sigRange = src.range(of: signature) else { return nil }
        guard let open = src.range(of: "{", range: sigRange.upperBound..<src.endIndex) else { return nil }
        var depth = 0
        var idx = open.lowerBound
        var body = ""
        while idx < src.endIndex {
            let ch = src[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            if depth >= 1 { body.append(ch) }
            idx = src.index(after: idx)
        }
        return body
    }
}
