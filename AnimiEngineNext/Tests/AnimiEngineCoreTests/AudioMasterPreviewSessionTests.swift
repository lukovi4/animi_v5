import XCTest
@testable import AnimiEngineCore

/// Slice-004 Stage F — `AudioMasterPreviewSession` contract tests.
///
/// The session orchestrates one preview epoch's start: it ties the (already-decided) `MasterClockKind`,
/// the chosen master clock, the `PreviewAudioGraph` AV boundary, first-frame readiness, the bounded
/// initial audio preroll, and the `PlaybackStartBarrier`. It must: never schedule audio before the
/// first frame; schedule the initial preroll through `PreviewAudioGraph.scheduleMix` at the exact
/// anchor-derived output sample time for an audio epoch; select the monotonic-host path and schedule no
/// audio for a no-audio epoch; reject stale identity; fail closed on timeout; and never start audio on
/// the scrub/settle path. A fake session adapter and fake sink keep everything device-free.
final class AudioMasterPreviewSessionTests: XCTestCase {

    // MARK: - Fakes (no AVFoundation), shared shape with Stage-E tests

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

    private final class FakeSink: PreviewAudioOutputSink, @unchecked Sendable {
        var scheduled: [(range: AudioSampleRange, samples: [Float32], at: Int64)] = []
        func configure(outputFormat: AudioOutputFormat, route: AudioOutputRoute) throws {}
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

    private func graph(
        session: FakeSession, sink: FakeSink, epoch: Int64 = 1, revision: Int64 = 1, maxChunkSamples: Int64 = 1_024
    ) throws -> PreviewAudioGraph {
        try PreviewAudioGraph(
            session: session, sink: sink, epoch: ep(epoch), revision: rev(revision),
            maxChunkSamples: maxChunkSamples)
    }

    private func anchor(
        revision: Int64 = 1, epoch: Int64 = 1, projectSample: Int64 = 0, outputSampleTime: Int64 = 0
    ) -> PreviewAudioScheduleAnchor {
        PreviewAudioScheduleAnchor(
            revision: rev(revision), epoch: ep(epoch),
            projectSample: projectSample, outputSampleTime: outputSampleTime)
    }

    private func snapshot(revision: Int64 = 1, epoch: Int64 = 1) throws -> SchedulerSnapshot {
        SchedulerSnapshot(
            revision: rev(revision), epoch: ep(epoch),
            coverage: try ProjectTimeRange(start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 10_000_000)),
            currentTarget: CurrentTarget(time: try ProjectTime(ticks: 0), frameRequest: FrameRequestID(raw: 1)),
            lastPublished: nil)
    }

    private func mixSource(
        sourceID: String, samples: [Float32], muted: Bool = false, gain: AudioGain = .unity,
        revision: Int64 = 1, epoch: Int64 = 1, chunkStart: Int64, chunkEnd: Int64
    ) throws -> PreviewMixSource {
        PreviewMixSource(
            buffer: try PreparedAudioBuffer(
                revision: rev(revision), epoch: ep(epoch), request: AudioRequestID(raw: 1),
                sourceID: try AudioSourceID(sourceID),
                chunkRange: range(chunkStart, chunkEnd),
                streamIdentity: try AudioStreamIdentity("stream-\(sourceID)"),
                sourceSampleRate: 48_000, channelLayout: .stereo, isMuted: muted, gain: gain,
                payload: try PreparedAudioPayloadHandle(identifier: "pcm:\(sourceID)")),
            samples: samples)
    }

    private func audioClock() -> SelectedMasterClock {
        SelectedMasterClock(
            kind: .audioSample,
            clock: AudioSampleMasterClock(anchorProjectTime: .zero, currentSampleTime: { 0 }))
    }

    private func hostClock() -> SelectedMasterClock {
        SelectedMasterClock(
            kind: .monotonicHost,
            clock: MonotonicHostMasterClock(anchorProjectTime: .zero, advancedTicks: { 0 }))
    }

    /// An audio-bearing session whose graph output is configured but anchor/frame are NOT yet set.
    private func audioSession(
        epoch: Int64 = 1, revision: Int64 = 1, timeoutTicks: Int64 = 1_000, startTick: Int64 = 0
    ) throws -> (AudioMasterPreviewSession, FakeSink) {
        let session = FakeSession(query: try query())
        let sink = FakeSink()
        let g = try graph(session: session, sink: sink, epoch: epoch, revision: revision)
        try session.activate()
        let s = try AudioMasterPreviewSession(
            revision: rev(revision), epoch: ep(epoch), graph: g, selectedClock: audioClock(),
            timeoutTicks: timeoutTicks, startTick: startTick)
        return (s, sink)
    }

    // MARK: - 1. Barrier does not complete until first frame ready

    func testStartFailsClosedUntilFirstFrameReady() throws {
        let (s, _) = try audioSession()
        try s.configureOutput()
        try s.configureAnchor(anchor())
        // No first frame yet → not ready.
        XCTAssertThrowsError(try s.start()) { error in
            guard case .notReadyToStart(let missing)? = error as? AudioMasterPreviewSessionError else {
                return XCTFail("expected notReadyToStart, got \(error)")
            }
            XCTAssertTrue(missing.contains(.firstFrameReady))
        }
    }

    // MARK: - 2. Barrier does not schedule audio before first frame

    func testAudioNotScheduledBeforeFirstFrame() throws {
        let (s, sink) = try audioSession()
        try s.configureOutput()
        try s.configureAnchor(anchor())
        let preroll = InitialAudioPreroll(
            anchor: anchor(), range: range(0, 2),
            sources: [try mixSource(sourceID: "A", samples: [0.1, 0.1], chunkStart: 0, chunkEnd: 2)])
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(preroll, against: try snapshot())) { error in
            XCTAssertEqual(error as? AudioMasterPreviewSessionError, .audioScheduledBeforeFirstFrame)
        }
        XCTAssertTrue(sink.scheduled.isEmpty, "no audio may reach the sink before the first frame")
    }

    // MARK: - 3. Audio epoch: anchor + mixed buffer at exact output sample time, then ready

    func testAudioEpochSchedulesMixedBufferAtExactOutputSampleTimeAndStarts() throws {
        // anchor: projectSample 1000 @ output 5000; mix at projectSample 1240 → 5240.
        let (s, sink) = try audioSession()
        let a = anchor(projectSample: 1_000, outputSampleTime: 5_000)
        try s.configureOutput()
        try s.configureAnchor(a)
        try s.markFirstFrameReady()   // first frame BEFORE audio
        let preroll = InitialAudioPreroll(
            anchor: a, range: range(1_240, 1_242),
            sources: [
                try mixSource(sourceID: "A", samples: [0.3, 0.3], chunkStart: 1_240, chunkEnd: 1_242),
                try mixSource(sourceID: "B", samples: [0.2, 0.2], chunkStart: 1_240, chunkEnd: 1_242),
            ])
        let didSchedule = try s.scheduleInitialAudioPreroll(preroll, against: try snapshot())
        XCTAssertTrue(didSchedule)
        XCTAssertEqual(sink.scheduled.count, 1, "ONE mixed buffer via scheduleMix (not per-source)")
        XCTAssertEqual(sink.scheduled[0].at, 5_240, "exact anchor-derived output sample time")
        XCTAssertEqual(sink.scheduled[0].samples[0], 0.5, accuracy: 1e-6, "summed 0.3 + 0.2")

        let started = try s.start()
        XCTAssertTrue(started.barrier.isReady)
        XCTAssertEqual(started.clock.kind, .audioSample)
        XCTAssertTrue(started.scheduledInitialPreroll)
    }

    // MARK: - 4. No-audio epoch selects monotonic host and schedules no audio

    func testNoAudioEpochSelectsHostClockAndSchedulesNoAudio() throws {
        let session = FakeSession(query: try query())
        let sink = FakeSink()
        let g = try graph(session: session, sink: sink)
        try session.activate()
        let s = try AudioMasterPreviewSession(
            revision: rev(1), epoch: ep(1), graph: g, selectedClock: hostClock(),
            timeoutTicks: 1_000, startTick: 0)
        XCTAssertFalse(s.isAudioBearing)

        try s.configureOutput()
        try s.configureAnchor(anchor())
        try s.markFirstFrameReady()
        // Even if a caller offers a preroll, a host epoch schedules nothing.
        let preroll = InitialAudioPreroll(
            anchor: anchor(), range: range(0, 2),
            sources: [try mixSource(sourceID: "A", samples: [0.5, 0.5], chunkStart: 0, chunkEnd: 2)])
        let didSchedule = try s.scheduleInitialAudioPreroll(preroll, against: try snapshot())
        XCTAssertFalse(didSchedule, "host epoch never schedules audio")
        XCTAssertTrue(sink.scheduled.isEmpty)

        let started = try s.start()
        XCTAssertEqual(started.clock.kind, .monotonicHost)
        XCTAssertFalse(started.scheduledInitialPreroll)
        XCTAssertTrue(started.barrier.isReady)
    }

    // MARK: - 5. Stale revision / epoch rejected

    func testStaleRevisionPrerollRejectedByGraphAdmission() throws {
        let (s, sink) = try audioSession(epoch: 1, revision: 7)
        try s.configureOutput()
        try s.configureAnchor(anchor(revision: 7, epoch: 1))
        try s.markFirstFrameReady()
        // Source carries revision 6 while active is 7 → admission rejects the whole mix.
        let preroll = InitialAudioPreroll(
            anchor: anchor(revision: 7, epoch: 1), range: range(0, 2),
            sources: [try mixSource(sourceID: "A", samples: [0, 0], revision: 6, chunkStart: 0, chunkEnd: 2)])
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(preroll, against: try snapshot(revision: 7, epoch: 1))) { error in
            XCTAssertEqual(error as? AudioMasterPreviewSessionError, .initialPrerollRejected(.staleRevision))
        }
        XCTAssertTrue(sink.scheduled.isEmpty)
    }

    func testStaleEpochSignalRejectedAtBarrier() throws {
        let (s, _) = try audioSession(epoch: 3, revision: 1)
        // A frame-ready signal from a different epoch is rejected by the barrier (carried through).
        try s.configureOutput()
        XCTAssertThrowsError(try s.markFirstFrameReadyMismatch(epoch: 2)) { error in
            XCTAssertEqual(error as? PlaybackStartBarrierError, .staleEpoch(signal: ep(2), active: ep(3)))
        }
    }

    // MARK: - Canonical anchor contract: configureAnchor identity

    func testConfigureAnchorRejectsStaleRevision() throws {
        let (s, _) = try audioSession(epoch: 1, revision: 5)
        try s.configureOutput()
        // Anchor minted for revision 4 (session is 5).
        XCTAssertThrowsError(try s.configureAnchor(anchor(revision: 4, epoch: 1))) { error in
            XCTAssertEqual(
                error as? AudioMasterPreviewSessionError,
                .anchorIdentityMismatch(
                    anchorRevision: rev(4), anchorEpoch: ep(1),
                    sessionRevision: rev(5), sessionEpoch: ep(1)))
        }
        // Rejected configureAnchor must NOT mark the gate.
        XCTAssertFalse(s.barrier.satisfied.contains(.anchorConfigured))
    }

    func testConfigureAnchorRejectsStaleEpoch() throws {
        let (s, _) = try audioSession(epoch: 3, revision: 1)
        try s.configureOutput()
        XCTAssertThrowsError(try s.configureAnchor(anchor(revision: 1, epoch: 2))) { error in
            XCTAssertEqual(
                error as? AudioMasterPreviewSessionError,
                .anchorIdentityMismatch(
                    anchorRevision: rev(1), anchorEpoch: ep(2),
                    sessionRevision: rev(1), sessionEpoch: ep(3)))
        }
    }

    func testRejectedConfigureAnchorDoesNotMarkAnchorConfigured() throws {
        let (s, _) = try audioSession(epoch: 1, revision: 1)
        try s.configureOutput()
        XCTAssertThrowsError(try s.configureAnchor(anchor(revision: 9, epoch: 1)))
        XCTAssertFalse(s.barrier.satisfied.contains(.anchorConfigured),
            "a rejected anchor must leave the anchorConfigured gate unset")
        XCTAssertEqual(s.barrier.missingGates.sorted { $0.rawValue < $1.rawValue }.first, .anchorConfigured)
    }

    // MARK: - Canonical anchor contract: preroll.anchor must equal the configured graph anchor

    func testPrerollRejectsMismatchedAnchorProjectSampleOrOutputTime() throws {
        let (s, sink) = try audioSession()
        let configured = anchor(projectSample: 1_000, outputSampleTime: 5_000)
        try s.configureOutput()
        try s.configureAnchor(configured)
        try s.markFirstFrameReady()
        // preroll.anchor diverges (different outputSampleTime) from the configured graph anchor.
        let divergent = anchor(projectSample: 1_000, outputSampleTime: 9_999)
        let preroll = InitialAudioPreroll(
            anchor: divergent, range: range(1_000, 1_002),
            sources: [try mixSource(sourceID: "A", samples: [0.1, 0.1], chunkStart: 1_000, chunkEnd: 1_002)])
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(preroll, against: try snapshot())) { error in
            XCTAssertEqual(
                error as? AudioMasterPreviewSessionError,
                .prerollAnchorMismatch(preroll: divergent, configured: configured))
        }
        XCTAssertTrue(sink.scheduled.isEmpty, "mismatched preroll anchor schedules nothing")
        XCTAssertFalse(s.barrier.satisfied.contains(.initialAudioScheduled))
    }

    func testPrerollRejectsMismatchedAnchorRevisionOrEpoch() throws {
        // Configure a valid anchor, then mutate the graph anchor to a different epoch behind the session
        // by configuring with a matching one but passing a preroll whose anchor carries another epoch.
        // Here the graph anchor and preroll anchor differ in epoch ⇒ prerollAnchorMismatch fires first
        // (preroll.anchor != configured). To exercise the revision/epoch branch specifically, make the
        // preroll anchor EQUAL to a configured graph anchor that itself was installed for a foreign
        // identity is impossible (configureAnchor rejects it), so the equality branch is the guard that
        // protects identity here. We assert the mismatch is reported.
        let (s, sink) = try audioSession(epoch: 1, revision: 1)
        let configured = anchor(revision: 1, epoch: 1, projectSample: 0, outputSampleTime: 0)
        try s.configureOutput()
        try s.configureAnchor(configured)
        try s.markFirstFrameReady()
        let foreign = anchor(revision: 2, epoch: 1, projectSample: 0, outputSampleTime: 0)
        let preroll = InitialAudioPreroll(
            anchor: foreign, range: range(0, 2),
            sources: [try mixSource(sourceID: "A", samples: [0.1, 0.1], chunkStart: 0, chunkEnd: 2)])
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(preroll, against: try snapshot())) { error in
            XCTAssertEqual(
                error as? AudioMasterPreviewSessionError,
                .prerollAnchorMismatch(preroll: foreign, configured: configured))
        }
        XCTAssertTrue(sink.scheduled.isEmpty)
        XCTAssertFalse(s.barrier.satisfied.contains(.initialAudioScheduled))
    }

    func testPrerollBeforeAnchorConfiguredFailsClosed() throws {
        let (s, sink) = try audioSession()
        try s.configureOutput()
        try s.markFirstFrameReady()
        // No anchor configured on the graph at all.
        let preroll = InitialAudioPreroll(
            anchor: anchor(), range: range(0, 2),
            sources: [try mixSource(sourceID: "A", samples: [0.1, 0.1], chunkStart: 0, chunkEnd: 2)])
        XCTAssertThrowsError(try s.scheduleInitialAudioPreroll(preroll, against: try snapshot())) { error in
            XCTAssertEqual(
                error as? AudioMasterPreviewSessionError,
                .prerollAnchorMismatch(preroll: anchor(), configured: nil))
        }
        XCTAssertTrue(sink.scheduled.isEmpty)
        XCTAssertFalse(s.barrier.satisfied.contains(.initialAudioScheduled))
    }

    // MARK: - 6. Timeout returns a typed failure

    func testTimeoutReturnsTypedFailure() throws {
        let (s, _) = try audioSession(timeoutTicks: 100, startTick: 0)
        try s.configureOutput()   // not all gates satisfied
        XCTAssertThrowsError(try s.tick(toMonotonicTick: 101)) { error in
            guard case .timedOut(_, let timeout, let missing)? = error as? PlaybackStartBarrierError else {
                return XCTFail("expected timedOut, got \(error)")
            }
            XCTAssertEqual(timeout, 100)
            XCTAssertTrue(missing.contains(.firstFrameReady))
        }
    }

    // MARK: - 7. Scrub / settle never starts audio

    func testScrubSettleDoesNotStartAudio() throws {
        let (s, sink) = try audioSession()
        try s.configureOutput()
        try s.configureAnchor(anchor())
        try s.markFirstFrameReady()
        // The scrub/settle preview path performs no audio scheduling.
        XCTAssertNoThrow(try s.scrubSettlePreview(startAudibleAudio: false))
        XCTAssertTrue(sink.scheduled.isEmpty, "scrub/settle must not schedule audio")
        // Asking it to start audible audio is a typed contract violation.
        XCTAssertThrowsError(try s.scrubSettlePreview(startAudibleAudio: true)) { error in
            XCTAssertEqual(error as? AudioMasterPreviewSessionError, .scrubMustNotStartAudio)
        }
        XCTAssertTrue(sink.scheduled.isEmpty)
    }

    // MARK: - Clock-kind wiring agreement

    func testClockKindMismatchFailsClosed() throws {
        let session = FakeSession(query: try query())
        let g = try graph(session: session, sink: FakeSink())
        try session.activate()
        // Declared .audioSample but the concrete clock is the monotonic host clock → mismatch.
        let mismatched = SelectedMasterClock(
            kind: .audioSample,
            clock: MonotonicHostMasterClock(anchorProjectTime: .zero, advancedTicks: { 0 }))
        XCTAssertThrowsError(
            try AudioMasterPreviewSession(
                revision: rev(1), epoch: ep(1), graph: g, selectedClock: mismatched,
                timeoutTicks: 1_000, startTick: 0)) { error in
            XCTAssertEqual(
                error as? AudioMasterPreviewSessionError,
                .clockKindMismatch(expected: .audioSample, got: .monotonicHost))
        }
    }

    // MARK: - 8. Stage G types absent

    func testStageGTypesAbsent() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AnimiEngineCore/Realtime", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        // No Stage-G realtime-callback / engine-driver / interruption-resume types yet.
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in [
                "RealtimeRenderCallback", "AudioRenderTap", "InterruptionResumeCoordinator",
                "RouteChangeResumePolicy", "AudioEngineDriver",
            ] {
                XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent): Stage G type \(banned) present")
            }
        }
    }
}

// MARK: - Test-only helper to drive a mismatched-epoch first-frame signal through the barrier

private extension AudioMasterPreviewSession {
    /// Drives a first-frame signal whose epoch deliberately mismatches the session's, to exercise the
    /// barrier's stale-epoch rejection through the session's own identity. The session always signals
    /// its own identity in production; this test hook constructs the mismatched signal explicitly.
    func markFirstFrameReadyMismatch(epoch other: Int64) throws {
        // Re-derive through the public barrier transition with a mismatched epoch.
        _ = try barrier.markingFirstFrameReady(revision: revision, epoch: PlaybackEpoch(raw: other))
    }
}
