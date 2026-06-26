import XCTest
@testable import AnimiEngineCore

/// Slice-004 Stage G — interruption / route-change **pause-only** contract tests.
///
/// Every audio-session interruption, route change, new-device-available, or output-format/route change
/// is a pause-only discontinuity: the session invalidates, refuses further scheduling, captures the last
/// confirmed project time from the injected master clock (fail-closed), and stays paused. There is NO
/// auto-resume and NO legacy reprepare+restart — `interruptionEnded` does not resume, and
/// `newDeviceAvailable` pauses like the rest. A fake session adapter, fake sink, and injectable clock
/// keep everything device-free.
final class InterruptionRouteChangePauseOnlyTests: XCTestCase {

    // MARK: - Fakes (no AVFoundation)

    private final class FakeSession: AudioSessionAdapter, @unchecked Sendable {
        private(set) var isActive = false
        private let q: AudioOutputQuery
        var queryCount = 0
        init(query: AudioOutputQuery) { self.q = query }
        func activate() throws { isActive = true }
        func deactivate() throws { isActive = false }
        func queryActualOutput() throws -> AudioOutputQuery {
            queryCount += 1
            guard isActive else { throw RealtimeAudioBoundaryError.queryBeforeActivation }
            return q
        }
    }

    private final class FakeSink: PreviewAudioOutputSink, @unchecked Sendable {
        var scheduled: [(range: AudioSampleRange, samples: [Float32], at: Int64)] = []
        func configure(outputFormat: AudioOutputFormat, route: AudioOutputRoute) throws {}
        func scheduleMixed(range: AudioSampleRange, samples: [Float32], at outputSampleTime: Int64) throws {
            scheduled.append((range, samples, outputSampleTime))
        }
    }

    private enum FakeClockError: Error, Equatable { case readFailed }

    /// An injectable master clock that is NOT one of the canonical Stage-B clocks (so the session imposes
    /// no kind constraint), returning a fixed time — or throwing — on demand.
    private final class FakeClock: MasterClock, @unchecked Sendable {
        let anchorProjectTime: ProjectTime
        private let fixed: ProjectTime
        var shouldThrow = false
        init(fixedTicks: Int64) {
            self.anchorProjectTime = .zero
            self.fixed = (try? ProjectTime(ticks: fixedTicks)) ?? .zero
        }
        func currentProjectTime() throws -> ProjectTime {
            if shouldThrow { throw FakeClockError.readFailed }
            return fixed
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

    private func anchor(projectSample: Int64 = 0, outputSampleTime: Int64 = 0) -> PreviewAudioScheduleAnchor {
        PreviewAudioScheduleAnchor(
            revision: rev(1), epoch: ep(1), projectSample: projectSample, outputSampleTime: outputSampleTime)
    }

    private func snapshot() throws -> SchedulerSnapshot {
        SchedulerSnapshot(
            revision: rev(1), epoch: ep(1),
            coverage: try ProjectTimeRange(start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 10_000_000)),
            currentTarget: CurrentTarget(time: try ProjectTime(ticks: 0), frameRequest: FrameRequestID(raw: 1)),
            lastPublished: nil)
    }

    private func mixSource(samples: [Float32], chunkStart: Int64, chunkEnd: Int64) throws -> PreviewMixSource {
        PreviewMixSource(
            buffer: try PreparedAudioBuffer(
                revision: rev(1), epoch: ep(1), request: AudioRequestID(raw: 1),
                sourceID: try AudioSourceID("A"), chunkRange: range(chunkStart, chunkEnd),
                streamIdentity: try AudioStreamIdentity("stream-A"),
                sourceSampleRate: 48_000, channelLayout: .stereo, isMuted: false, gain: .unity,
                payload: try PreparedAudioPayloadHandle(identifier: "pcm:A")),
            samples: samples)
    }

    /// A live, audio-bearing, started session: output + anchor configured, first frame ready, initial
    /// preroll scheduled. `clock` is returned so a test can flip its throw flag.
    private func startedAudioSession(
        clockTicks: Int64 = 12_345
    ) throws -> (AudioMasterPreviewSession, FakeSession, FakeSink, FakeClock) {
        let session = FakeSession(query: try query())
        let sink = FakeSink()
        let clock = FakeClock(fixedTicks: clockTicks)
        let graph = try PreviewAudioGraph(
            session: session, sink: sink, epoch: ep(1), revision: rev(1), maxChunkSamples: 1_024)
        try session.activate()
        let s = try AudioMasterPreviewSession(
            revision: rev(1), epoch: ep(1), graph: graph,
            selectedClock: SelectedMasterClock(kind: .audioSample, clock: clock),
            timeoutTicks: 10_000, startTick: 0)
        let a = anchor()
        try s.configureOutput()
        try s.configureAnchor(a)
        try s.markFirstFrameReady()
        try s.scheduleInitialAudioPreroll(
            InitialAudioPreroll(
                anchor: a, range: range(0, 2),
                sources: [try mixSource(samples: [0.1, 0.1], chunkStart: 0, chunkEnd: 2)]),
            against: try snapshot())
        XCTAssertEqual(sink.scheduled.count, 1)
        return (s, session, sink, clock)
    }

    private func preroll() throws -> InitialAudioPreroll {
        InitialAudioPreroll(
            anchor: anchor(), range: range(0, 2),
            sources: [try mixSource(samples: [0.2, 0.2], chunkStart: 0, chunkEnd: 2)])
    }

    // MARK: - 1. Interruption began pauses/invalidates and prevents scheduling

    func testInterruptionBeganInvalidatesAndPreventsScheduling() throws {
        let (s, _, sink, _) = try startedAudioSession()
        let paused = try s.handleSessionEvent(.interruptionBegan)
        XCTAssertNotNil(paused)
        XCTAssertTrue(s.isInvalidated)
        XCTAssertTrue(s.isInterrupted)
        XCTAssertEqual(paused?.invalidatedEpoch, ep(1))
        XCTAssertEqual(paused?.event, .interruptionBegan)
        let before = sink.scheduled.count
        // Further scheduling is refused typed; nothing reaches the sink.
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(try preroll(), against: try snapshot())) { error in
            XCTAssertEqual(error as? AudioMasterPreviewSessionError, .schedulingAfterSessionInvalidated)
        }
        XCTAssertEqual(sink.scheduled.count, before, "no new audio after interruption")
    }

    // MARK: - 2. Interruption ended does NOT auto-resume

    func testInterruptionEndedDoesNotAutoResume() throws {
        let (s, _, sink, _) = try startedAudioSession()
        try s.handleSessionEvent(.interruptionBegan)
        let before = sink.scheduled.count
        // Ending the interruption clears the flag but does NOT resume / re-enable scheduling.
        let ended = try s.handleSessionEvent(.interruptionEnded)
        XCTAssertNil(ended, "interruptionEnded does not produce a resume")
        XCTAssertFalse(s.isInterrupted, "interruption flag cleared")
        XCTAssertTrue(s.isInvalidated, "still invalidated — no auto-resume")
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(try preroll(), against: try snapshot()))
        XCTAssertThrowsError(try s.start()) { error in
            XCTAssertEqual(error as? AudioMasterPreviewSessionError, .sessionInterrupted(reason: .interruptionBegan))
        }
        XCTAssertEqual(sink.scheduled.count, before, "interruptionEnded scheduled no audio")
    }

    // MARK: - 3. Route change pauses/invalidates and prevents scheduling

    func testRouteChangeInvalidatesAndPreventsScheduling() throws {
        let (s, _, sink, _) = try startedAudioSession()
        let paused = try s.handleSessionEvent(.routeChanged(.oldDeviceUnavailable))
        XCTAssertTrue(s.isInvalidated)
        XCTAssertEqual(paused?.event, .routeChanged(.oldDeviceUnavailable))
        XCTAssertTrue(paused?.requiresOutputRequeryBeforeNextPlay ?? false, "route change needs re-query")
        let before = sink.scheduled.count
        XCTAssertThrowsError(try s.configureAnchor(anchor())) { error in
            XCTAssertEqual(error as? AudioMasterPreviewSessionError, .schedulingAfterSessionInvalidated)
        }
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(try preroll(), against: try snapshot()))
        XCTAssertEqual(sink.scheduled.count, before)
    }

    // MARK: - 4. newDeviceAvailable is pause-only, NO restart

    func testNewDeviceAvailableIsPauseOnlyNoRestart() throws {
        let (s, _, sink, _) = try startedAudioSession()
        let before = sink.scheduled.count
        let paused = try s.handleSessionEvent(.newDeviceAvailable)
        XCTAssertTrue(s.isInvalidated)
        XCTAssertEqual(paused?.event, .newDeviceAvailable)
        // No reprepare+restart: nothing new scheduled, session paused, start refused.
        XCTAssertEqual(sink.scheduled.count, before, "newDeviceAvailable must NOT reschedule/restart audio")
        XCTAssertThrowsError(try s.start()) { error in
            XCTAssertEqual(
                error as? AudioMasterPreviewSessionError,
                .routeChangedRequiresExplicitPlay(reason: .newDeviceAvailable))
        }
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(try preroll(), against: try snapshot()))
        XCTAssertEqual(sink.scheduled.count, before)
    }

    // MARK: - 5. Last confirmed time captured from injected clock

    func testLastConfirmedTimeCapturedFromInjectedClock() throws {
        let (s, _, _, _) = try startedAudioSession(clockTicks: 54_321)
        let paused = try s.handleSessionEvent(.interruptionBegan)
        XCTAssertEqual(paused?.lastConfirmedProjectTime, try ProjectTime(ticks: 54_321))
        XCTAssertEqual(s.pausedState?.lastConfirmedProjectTime, try ProjectTime(ticks: 54_321))
    }

    // MARK: - 6. Clock read failure during event is typed fail-closed

    func testClockReadFailureDuringEventIsTypedFailClosed() throws {
        let (s, _, _, clock) = try startedAudioSession()
        clock.shouldThrow = true
        XCTAssertThrowsError(try s.handleSessionEvent(.routeChanged(.categoryChange))) { error in
            guard case .clockReadFailedDuringPause? = error as? AudioMasterPreviewSessionError else {
                return XCTFail("expected clockReadFailedDuringPause, got \(error)")
            }
        }
        // Failed read still leaves the session invalidated/paused (fail-closed, not half-live).
        XCTAssertTrue(s.isInvalidated)
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(try preroll(), against: try snapshot()))
    }

    // MARK: - 7. Output format/route re-query does not start audio

    func testOutputRequeryDoesNotStartAudio() throws {
        let (s, session, sink, _) = try startedAudioSession()
        try s.handleSessionEvent(.outputFormatOrRouteChanged)
        let before = sink.scheduled.count
        // Re-query is pure preparation: it returns the queried output and schedules nothing.
        let q = try s.requeryOutputForNextPlay(adapter: session)
        XCTAssertEqual(q.format.sampleRate, 48_000)
        XCTAssertEqual(sink.scheduled.count, before, "re-query must not start/schedule audio")
        XCTAssertTrue(s.isInvalidated, "re-query does not revive the invalidated session")
        XCTAssertThrowsError(try s.start())
    }

    // MARK: - 8. Explicit play requires a NEW session/epoch (not resume the old one)

    func testExplicitPlayRequiresNewEpochNotResumeOldSession() throws {
        let (oldSession, adapter, _, _) = try startedAudioSession()
        try oldSession.handleSessionEvent(.routeChanged(.wakeFromSleep))
        // The old session can never start again.
        XCTAssertThrowsError(try oldSession.start())

        // Explicit play = a brand-new epoch + a brand-new session (epoch 2), re-querying output.
        _ = try oldSession.requeryOutputForNextPlay(adapter: adapter)
        let sink2 = FakeSink()
        let clock2 = FakeClock(fixedTicks: 0)
        let graph2 = try PreviewAudioGraph(
            session: adapter, sink: sink2, epoch: ep(2), revision: rev(1), maxChunkSamples: 1_024)
        let newSession = try AudioMasterPreviewSession(
            revision: rev(1), epoch: ep(2), graph: graph2,
            selectedClock: SelectedMasterClock(kind: .audioSample, clock: clock2),
            timeoutTicks: 10_000, startTick: 0)
        let a2 = PreviewAudioScheduleAnchor(
            revision: rev(1), epoch: ep(2), projectSample: 0, outputSampleTime: 0)
        try newSession.configureOutput()
        try newSession.configureAnchor(a2)
        try newSession.markFirstFrameReady()
        let snap2 = SchedulerSnapshot(
            revision: rev(1), epoch: ep(2),
            coverage: try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 10_000_000)),
            currentTarget: CurrentTarget(time: .zero, frameRequest: FrameRequestID(raw: 1)),
            lastPublished: nil)
        let src2 = PreviewMixSource(
            buffer: try PreparedAudioBuffer(
                revision: rev(1), epoch: ep(2), request: AudioRequestID(raw: 1),
                sourceID: try AudioSourceID("A"), chunkRange: range(0, 2),
                streamIdentity: try AudioStreamIdentity("stream-A"),
                sourceSampleRate: 48_000, channelLayout: .stereo, isMuted: false, gain: .unity,
                payload: try PreparedAudioPayloadHandle(identifier: "pcm:A2")),
            samples: [0.1, 0.1])
        try newSession.scheduleInitialAudioPreroll(
            InitialAudioPreroll(anchor: a2, range: range(0, 2), sources: [src2]), against: snap2)
        let started = try newSession.start()
        XCTAssertTrue(started.barrier.isReady)
        XCTAssertEqual(started.clock.kind, .audioSample)
        XCTAssertEqual(sink2.scheduled.count, 1, "the NEW session scheduled its own preroll")
    }

    // MARK: - 9. Scrub still schedules no audio (after or independent of events)

    func testScrubStillSchedulesNoAudio() throws {
        let (s, _, sink, _) = try startedAudioSession()
        let before = sink.scheduled.count
        XCTAssertNoThrow(try s.scrubSettlePreview(startAudibleAudio: false))
        XCTAssertThrowsError(try s.scrubSettlePreview(startAudibleAudio: true)) { error in
            XCTAssertEqual(error as? AudioMasterPreviewSessionError, .scrubMustNotStartAudio)
        }
        XCTAssertEqual(sink.scheduled.count, before, "scrub never schedules audio")
    }

    // MARK: - Event value model

    func testEventInvalidationClassification() {
        XCTAssertTrue(RealtimeAudioSessionEvent.interruptionBegan.invalidatesAudiblePlayback)
        XCTAssertFalse(RealtimeAudioSessionEvent.interruptionEnded.invalidatesAudiblePlayback)
        XCTAssertTrue(RealtimeAudioSessionEvent.newDeviceAvailable.invalidatesAudiblePlayback)
        XCTAssertTrue(RealtimeAudioSessionEvent.outputFormatOrRouteChanged.invalidatesAudiblePlayback)
        XCTAssertTrue(RealtimeAudioSessionEvent.routeChanged(.override).invalidatesAudiblePlayback)
    }

    func testEventModelIsSendableValue() {
        func requireSendable<T: Sendable>(_ type: T.Type) {}
        requireSendable(RealtimeAudioSessionEvent.self)
        requireSendable(RealtimeRouteChangeReason.self)
        requireSendable(PausedPreviewState.self)
    }

    // MARK: - 10/11. No auto-resume / Stage H not started (structural)

    func testNoAutoResumeOrLegacyReprepareRestartInSource() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AnimiEngineCore/Realtime", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files {
            let text = strippingLineComments(try String(contentsOf: file, encoding: .utf8))
            for banned in ["reprepare", "autoResume", "autoResume", "restartPlayback", "resumeAfterInterruption"] {
                XCTAssertFalse(text.contains(banned),
                    "\(file.lastPathComponent): pause-only contract forbids \(banned)")
            }
        }
    }

    func testStageHTypesAbsent() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AnimiEngineCore/Realtime", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in [
                "RealtimeRenderCallback", "AudioRenderTap", "AudioEngineDriver",
                "InterruptionResumeCoordinator", "BackgroundAudioContinuation",
            ] {
                XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent): Stage H type \(banned) present")
            }
        }
    }

    private func strippingLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }
}
