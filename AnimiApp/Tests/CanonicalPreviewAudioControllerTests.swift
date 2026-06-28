import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage C — `CanonicalPreviewAudioController`: the canonical realtime preview-audio lifecycle
/// is reachable end-to-end with injected fakes. Play schedules preroll (after first frame); scrub is
/// silent; pause stops; route newDeviceAvailable is pause-only.
@MainActor
final class CanonicalPreviewAudioControllerTests: XCTestCase {

    // MARK: - Fakes (no AVFoundation, no device)

    private final class FakeSession: AudioSessionAdapter, @unchecked Sendable {
        private(set) var isActive = false
        private(set) var activateCount = 0
        private(set) var deactivateCount = 0
        private let q: AudioOutputQuery
        init(query: AudioOutputQuery) { self.q = query }
        func activate() throws { isActive = true; activateCount += 1 }
        func deactivate() throws { isActive = false; deactivateCount += 1 }
        func queryActualOutput() throws -> AudioOutputQuery {
            guard isActive else { throw RealtimeAudioBoundaryError.queryBeforeActivation }
            return q
        }
    }

    /// Records every scheduled mixed buffer — the proof of what reached the graph/sink.
    private final class RecordingSink: PreviewAudioOutputSink, @unchecked Sendable {
        var scheduled: [(range: AudioSampleRange, samples: [Float32], at: Int64)] = []
        func configure(outputFormat: AudioOutputFormat, route: AudioOutputRoute) throws {}
        func scheduleMixed(range: AudioSampleRange, samples: [Float32], at outputSampleTime: Int64) throws {
            scheduled.append((range, samples, outputSampleTime))
        }
    }

    /// A simple suspend-until-released gate to model a slow in-flight async render deterministically.
    private actor AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { c in self.continuation = c }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - Builders

    private func query() throws -> AudioOutputQuery {
        AudioOutputQuery(
            format: try AudioOutputFormat(sampleRate: 48_000, channelLayout: .stereo),
            route: try AudioOutputRoute(identifier: "speaker"))
    }

    /// A plan with one global music segment covering [0, count) samples.
    private func musicPlan(count: Int64 = 4) throws -> AudioPlan {
        let interval = try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: count * AudioSampleGrid.ticksPerSample)))
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("c0"), sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .music, destinationSamples: interval,
            sourceStart: .zero, sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .stereo,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        return AudioPlan(sampleInterval: interval, segments: [seg])
    }

    /// A fake preroll builder producing deterministic non-empty samples for the requested range.
    private func fakePrerollSources(
        plan: AudioPlan, revision: ProjectRevision, epoch: PlaybackEpoch,
        anchor: PreviewAudioScheduleAnchor, range: AudioSampleRange
    ) throws -> [PreviewMixSource] {
        let count = Int(range.sampleCount)
        var reqAlloc = MonotonicRequestIDAllocator()
        let buffer = try PreparedAudioBuffer(
            revision: revision, epoch: epoch, request: reqAlloc.nextAudioRequest(),
            sourceID: try AudioSourceID("s0"), chunkRange: range,
            streamIdentity: try AudioStreamIdentity("stream-0"),
            sourceSampleRate: 48_000, channelLayout: .stereo, isMuted: false, gain: .unity,
            payload: try PreparedAudioPayloadHandle(identifier: "pcm:s0"))
        let samples = (0..<count).map { Float32(0.1 * Double($0 % 3)) }   // deterministic
        return [PreviewMixSource(buffer: buffer, samples: samples)]
    }

    private func makeController(
        plan: AudioPlan?,
        sink: RecordingSink,
        prerollBuilder: ((AudioPlan, ProjectRevision, PlaybackEpoch, PreviewAudioScheduleAnchor, AudioSampleRange) throws -> [PreviewMixSource])? = nil,
        asyncPrerollBuilder: ((AudioPlan, ProjectRevision, PlaybackEpoch, PreviewAudioScheduleAnchor, AudioSampleRange) async throws -> [PreviewMixSource])? = nil,
        session: FakeSession? = nil,
        projectHasAudio: @escaping () -> Bool = { false }
    ) throws -> CanonicalPreviewAudioController {
        let s = try session ?? FakeSession(query: query())
        let sync = prerollBuilder ?? fakePrerollSources
        let deps = CanonicalPreviewAudioController.Dependencies(
            evaluatePlan: { plan },
            // Stage C.6: the controller's render boundary is async. Tests wrap a deterministic synchronous
            // builder (or an injected async one) so the lifecycle is exercised without AVFoundation.
            buildInitialPrerollAsync: { plan, revision, epoch, anchor, range, _ in
                if let asyncPrerollBuilder { return try await asyncPrerollBuilder(plan, revision, epoch, anchor, range) }
                return try sync(plan, revision, epoch, anchor, range)
            },
            sessionAdapter: s,
            sink: sink,
            makeAudioClock: { anchor in
                AudioSampleMasterClock(anchorProjectTime: anchor, currentSampleTime: { 0 })
            },
            maxChunkSamples: 1_024,
            startTimeoutTicks: 10_000,
            projectHasAudio: projectHasAudio)
        return CanonicalPreviewAudioController(dependencies: deps)
    }

    /// Drive a full canonical start: play (PHASE 1) → await the async render → first frame → cross barrier.
    /// The order of first-frame vs render does not matter (the barrier crosses on whichever is second); for
    /// the common case we signal the frame after draining the render.
    private func started(_ controller: CanonicalPreviewAudioController, fromSeconds: Double = 0) async {
        controller.startPlayback(fromSeconds: fromSeconds, hostTime: 0)
        await drainRender(controller)
        controller.signalFirstFrameReady()
        await drainRender(controller)
    }

    /// Pump the cooperative executor until the controller's owned render `Task` has run to completion
    /// (no in-flight render) or a bounded number of yields elapse. Deterministic for the in-test builders.
    private func drainRender(_ controller: CanonicalPreviewAudioController) async {
        for _ in 0..<200 {
            #if DEBUG
            if !controller.hasInFlightPrerollTask { return }
            #endif
            await Task.yield()
        }
    }

    // MARK: - Canonical path reachable: play schedules preroll; first frame crosses barrier

    func testPlaySchedulesPrerollThenFirstFrameStartsSession() async throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(count: 4), sink: sink)
        controller.replacePipeline(BuiltAudioPipeline(composition: .init(), audioMix: nil))
        controller.prepareForImmediatePlayback()

        // PHASE 1: play prepares the epoch but schedules NOTHING and does NOT cross the barrier (canonical
        // order: audio is scheduled only AFTER the first frame). The blocking render runs ASYNC, not here.
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        XCTAssertTrue(sink.scheduled.isEmpty, "no audio scheduled before the first frame")
        XCTAssertNil(controller.activeSession, "barrier NOT crossed until the first frame")
        #if DEBUG
        XCTAssertTrue(controller.hasPendingSessionAwaitingFirstFrame, "session pending the first frame")
        #endif

        // Even AFTER the async render completes, with no first frame yet, NOTHING is scheduled/started.
        await drainRender(controller)
        XCTAssertTrue(sink.scheduled.isEmpty, "render-ready but no first frame → still nothing scheduled")
        XCTAssertNil(controller.activeSession, "barrier still NOT crossed before the first frame")

        // PHASE 2: the real first-frame signal is now the SECOND barrier side → schedules + crosses.
        controller.signalFirstFrameReady()
        XCTAssertEqual(sink.scheduled.count, 1, "first frame schedules exactly one bounded preroll buffer")
        XCTAssertNotNil(controller.activeSession, "first frame starts the live session")
        XCTAssertNotNil(controller.activeGraph)
        #if DEBUG
        XCTAssertFalse(controller.hasPendingSessionAwaitingFirstFrame)
        XCTAssertEqual(controller.startedEpochCount, 1)
        XCTAssertTrue(controller.lastStartScheduledPreroll)
        #endif
    }

    // MARK: - startPlayback does NOT synchronously render (Stage C.6 core)

    func testStartPlaybackDoesNotRenderSynchronously() async throws {
        let sink = RecordingSink()
        // A builder that records WHEN it ran. It must NOT have run by the time startPlayback returns.
        actor RenderProbe { var ran = false; func mark() { ran = true }; func didRun() -> Bool { ran } }
        let probe = RenderProbe()
        let controller = try makeController(
            plan: try musicPlan(count: 4), sink: sink,
            asyncPrerollBuilder: { p, revision, epoch, anchor, range in
                await probe.mark()
                return try self.fakePrerollSources(plan: p, revision: revision, epoch: epoch, anchor: anchor, range: range)
            })
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        // Synchronously after startPlayback: NO render has run and NOTHING is scheduled.
        let ranSynchronously = await probe.didRun()
        XCTAssertFalse(ranSynchronously, "startPlayback must NOT render synchronously (off-main async only)")
        XCTAssertTrue(sink.scheduled.isEmpty, "no sources scheduled synchronously at startPlayback")
        #if DEBUG
        XCTAssertTrue(controller.hasInFlightPrerollTask, "an async render Task was kicked off")
        #endif
        // The render then runs asynchronously and the barrier crosses on the first frame.
        await drainRender(controller)
        let ranAsync = await probe.didRun()
        XCTAssertTrue(ranAsync, "the render runs asynchronously after startPlayback returns")
        controller.signalFirstFrameReady()
        XCTAssertEqual(sink.scheduled.count, 1, "async render + first frame → exactly one scheduled buffer")
    }

    // MARK: - Barrier: render-before-frame and frame-before-render both cross on the SECOND side

    func testRenderBeforeFirstFrameCrossesOnFrame() async throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(count: 4), sink: sink)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainRender(controller)                 // render side ready FIRST
        #if DEBUG
        XCTAssertTrue(controller.hasPendingPreparedSources, "render completed and holds sources")
        #endif
        XCTAssertNil(controller.activeSession, "render alone does not cross the barrier")
        controller.signalFirstFrameReady()            // frame is the second side → cross
        XCTAssertEqual(sink.scheduled.count, 1)
        XCTAssertNotNil(controller.activeSession)
    }

    func testFirstFrameBeforeRenderCrossesOnRender() async throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(count: 4), sink: sink)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        controller.signalFirstFrameReady()            // frame side ready FIRST (before render)
        XCTAssertTrue(sink.scheduled.isEmpty, "frame alone does not cross until render completes")
        XCTAssertNil(controller.activeSession)
        await drainRender(controller)                 // render is the second side → cross
        XCTAssertEqual(sink.scheduled.count, 1)
        XCTAssertNotNil(controller.activeSession)
    }

    // MARK: - First-frame gate is REAL: nothing scheduled/started before the signal

    func testNoStartBeforeFirstFrameSignal() throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(count: 4), sink: sink)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        // NOTHING is scheduled and the barrier is NOT crossed before the first-frame signal.
        XCTAssertTrue(sink.scheduled.isEmpty, "no audio scheduled before the first-frame signal")
        XCTAssertNil(controller.activeSession, "no session before the first-frame signal")
        #if DEBUG
        XCTAssertEqual(controller.startedEpochCount, 0, "no epoch started before first frame")
        #endif
    }

    func testFirstFrameWithoutPlayIsNoOp() throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(), sink: sink)
        controller.signalFirstFrameReady()   // no pending session
        XCTAssertTrue(sink.scheduled.isEmpty)
        XCTAssertNil(controller.activeSession)
    }

    // MARK: - Non-zero playhead anchor

    func testPlayFromNonZeroTimeAnchorsAtCorrectSample() async throws {
        // 0.5 s → 500_000 µs → ticks = 500_000*6/25 = 120_000 → sample = 120_000/5 = 24_000.
        let sink = RecordingSink()
        // A plan covering [0, 30_000) samples so the 24_000 anchor lies inside it.
        let interval = try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 30_000 * AudioSampleGrid.ticksPerSample)))
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("c0"), sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .music, destinationSamples: interval, sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .stereo,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        let plan = AudioPlan(sampleInterval: interval, segments: [seg])

        var capturedAnchor: PreviewAudioScheduleAnchor?
        var capturedRange: AudioSampleRange?
        let controller = try makeController(
            plan: plan, sink: sink,
            prerollBuilder: { p, revision, epoch, anchor, range in
                capturedAnchor = anchor; capturedRange = range
                return try self.fakePrerollSources(plan: p, revision: revision, epoch: epoch, anchor: anchor, range: range)
            })
        await started(controller, fromSeconds: 0.5)

        XCTAssertEqual(capturedAnchor?.projectSample, 24_000, "anchor projectSample from the 0.5 s playhead")
        XCTAssertEqual(capturedRange?.start, 24_000, "preroll starts AT the playhead sample, not 0")
        XCTAssertNotNil(controller.activeSession)
        XCTAssertEqual(sink.scheduled.first?.range.start, 24_000)
    }

    func testNegativeAndNonFinitePlayheadFailClosed() throws {
        for bad: Double in [-1.0, .nan, .infinity] {
            let sink = RecordingSink()
            let controller = try makeController(plan: try musicPlan(), sink: sink)
            var failure: PreviewAudioFailureReason?
            controller.onFailure = { failure = $0 }
            controller.startPlayback(fromSeconds: bad, hostTime: 0)
            XCTAssertNil(controller.activeSession, "bad playhead \(bad) fails closed")
            XCTAssertEqual(controller.readiness, .failed)
            XCTAssertNotNil(failure)
            XCTAssertTrue(sink.scheduled.isEmpty, "no scheduling on a bad-playhead fail-closed start")
        }
    }

    // MARK: - Non-empty plan with NO preroll sources → typed renderNotImplemented (no silent schedule)

    func testNonEmptyPlanWithNoPrerollFailsClosedNotSilent() async throws {
        let sink = RecordingSink()
        let controller = try makeController(
            plan: try musicPlan(count: 4), sink: sink,
            prerollBuilder: { _, _, _, _, _ in [] })   // simulates render → no sources
        var failure: PreviewAudioFailureReason?
        controller.onFailure = { failure = $0 }
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        // The fail-closed decision is reached when the ASYNC render completes with zero sources.
        await drainRender(controller)
        XCTAssertTrue(sink.scheduled.isEmpty, "non-empty audio must NOT schedule silence")
        XCTAssertNil(controller.activeSession)
        XCTAssertEqual(controller.readiness, .failed, "non-empty plan + no sources → fail closed")
        XCTAssertNotNil(failure)
    }

    // MARK: - Overflow in anchor arithmetic fails closed

    func testHugePlayheadOverflowFailsClosed() throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(), sink: sink)
        var failure: PreviewAudioFailureReason?
        controller.onFailure = { failure = $0 }
        // A seconds value whose µs*6 overflows Int64 → checked arithmetic fails closed (no trap).
        controller.startPlayback(fromSeconds: 1.0e30, hostTime: 0)
        XCTAssertNil(controller.activeSession)
        XCTAssertEqual(controller.readiness, .failed)
        XCTAssertNotNil(failure)
    }

    // MARK: - Fail closed on canonical preroll rejection (no partial audible state)

    func testStartFailsClosedIfPrerollRejected_noPartialAudibleState() async throws {
        let sink = RecordingSink()
        let controller = try makeController(
            plan: try musicPlan(count: 4), sink: sink,
            prerollBuilder: { _, revision, epoch, anchor, _ in
                let bad = try AudioSampleRange.from(projectTicks:
                    ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 9999 * AudioSampleGrid.ticksPerSample)))
                var reqAlloc = MonotonicRequestIDAllocator()
                let buf = try PreparedAudioBuffer(
                    revision: revision, epoch: epoch, request: reqAlloc.nextAudioRequest(),
                    sourceID: try AudioSourceID("s0"), chunkRange: bad,
                    streamIdentity: try AudioStreamIdentity("stream-0"), sourceSampleRate: 48_000,
                    channelLayout: .stereo, isMuted: false, gain: .unity,
                    payload: try PreparedAudioPayloadHandle(identifier: "pcm"))
                return [PreviewMixSource(buffer: buf, samples: [0, 0])]
            })
        var failure: PreviewAudioFailureReason?
        controller.onFailure = { failure = $0 }
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainRender(controller)        // async render produces the (bad) sources
        controller.signalFirstFrameReady()   // the canonical rejection surfaces when scheduling at the frame
        XCTAssertNil(controller.activeSession, "no live session on fail-closed start")
        XCTAssertEqual(controller.readiness, .failed)
        XCTAssertNotNil(failure)
    }

    // MARK: - Silent epoch when no resolvable audio (nil plan)

    func testNilPlanProducesSilentEpochNoScheduling() async throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: nil, sink: sink)   // projectHasAudio defaults false
        await started(controller)
        XCTAssertTrue(sink.scheduled.isEmpty, "no resolvable audio → nothing scheduled")
        XCTAssertNil(controller.activeSession, "silent epoch has no audio-bearing session")
        XCTAssertEqual(controller.readiness, .primed)
    }

    // MARK: - Silent epoch WITH project audio → fallback (never silence over real audio)

    /// The no-sound regression: canonical evaluated to no plan while the project HAS audio. That must NOT
    /// stay a silent epoch — it routes through `onCanonicalUnavailable` so the coordinator can fall back to
    /// the legacy preview audio (safety only). Proven WITHOUT touching the legacy build gate.
    func testSilentEpochWithProjectAudioFiresFallbackNotSilence() throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: nil, sink: sink, projectHasAudio: { true })
        var fallbackReason: String?
        controller.onCanonicalUnavailable = { fallbackReason = $0 }
        var failure: PreviewAudioFailureReason?
        controller.onFailure = { failure = $0 }

        controller.startPlayback(fromSeconds: 0, hostTime: 0)

        XCTAssertTrue(sink.scheduled.isEmpty, "must NOT schedule (or fake) audio")
        XCTAssertNil(controller.activeSession, "no silent session installed over real audio")
        XCTAssertEqual(controller.readiness, .failed, "silent-epoch-with-audio is a canonical miss, not .primed")
        XCTAssertNotNil(fallbackReason, "fallback to legacy is requested (never user-facing silence)")
        XCTAssertNotNil(failure)
    }

    /// Complement: a project that GENUINELY has no audio stays a legitimate silent epoch (no fallback).
    func testNilPlanWithoutProjectAudioStaysSilentEpochNoFallback() async throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: nil, sink: sink, projectHasAudio: { false })
        var fallbackReason: String?
        controller.onCanonicalUnavailable = { fallbackReason = $0 }
        await started(controller)
        XCTAssertNil(fallbackReason, "no audio in project → legitimate silent epoch, no fallback")
        XCTAssertEqual(controller.readiness, .primed)
        XCTAssertNil(controller.activeSession)
    }

    // MARK: - Pause stops the session (incl. a pending pre-first-frame session)

    func testPauseStopsSession() async throws {
        let sink = RecordingSink()
        let session = try FakeSession(query: query())
        let controller = try makeController(plan: try musicPlan(), sink: sink, session: session)
        await started(controller)
        XCTAssertNotNil(controller.activeSession)
        controller.pausePlaybackImmediately()
        XCTAssertNil(controller.activeSession, "pause stops the session")
        // The canonical adapter is now SESSION-NEUTRAL on stop (it must NOT deactivate the shared
        // AVAudioSession — that silenced the whole app). Pause stops the engine via the sink, not the
        // session: deactivate must NOT be called.
        XCTAssertEqual(session.deactivateCount, 0, "pause must NOT deactivate the shared audio session")
    }

    func testPauseBeforeFirstFrameCancelsPendingSession() async throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(), sink: sink)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)   // pending, async render kicked off
        controller.pausePlaybackImmediately()                    // cancels the render + bumps generation
        #if DEBUG
        XCTAssertFalse(controller.hasPendingSessionAwaitingFirstFrame, "pause cancels the pending session")
        XCTAssertFalse(controller.hasInFlightPrerollTask, "pause cancels the in-flight render task")
        #endif
        // Even if the render body still runs to completion, the generation guard drops it (no scheduling).
        await drainRender(controller)
        controller.signalFirstFrameReady()   // must NOT start anything now
        XCTAssertNil(controller.activeSession, "a cancelled pending session does not start on a late frame")
        XCTAssertTrue(sink.scheduled.isEmpty, "a late render completion after pause schedules nothing")
    }

    // MARK: - Pause WHILE the render is in flight → late completion is dropped (cancellation guard)

    func testPauseDuringInFlightRenderDropsLateCompletion() async throws {
        let sink = RecordingSink()
        // A gated async builder: it suspends until released, modelling a slow off-main render.
        let gate = AsyncGate()
        let controller = try makeController(
            plan: try musicPlan(count: 4), sink: sink,
            asyncPrerollBuilder: { p, revision, epoch, anchor, range in
                await gate.wait()                                // render is "in flight" here
                return try self.fakePrerollSources(plan: p, revision: revision, epoch: epoch, anchor: anchor, range: range)
            })
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        // Let the render task reach the gate (suspended mid-render).
        for _ in 0..<50 { await Task.yield() }
        // Pause WHILE the render is suspended → cancel + bump generation.
        controller.pausePlaybackImmediately()
        // Release the gate: the render body completes, hops back — but the generation guard drops it.
        await gate.release()
        await drainRender(controller)
        controller.signalFirstFrameReady()
        XCTAssertNil(controller.activeSession, "a render completing after pause must schedule nothing")
        XCTAssertTrue(sink.scheduled.isEmpty, "late render completion drops on the generation guard")
    }

    func testTeardownStopsSessionAndGoesIdle() async throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(), sink: sink)
        await started(controller)
        controller.teardown()
        XCTAssertNil(controller.activeSession)
        XCTAssertEqual(controller.readiness, .idle)
    }

    // MARK: - Scrub schedules no audio

    func testScrubSchedulesNoAudio() throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(), sink: sink)
        controller.pausePlaybackImmediately()   // the only scrub→audio reach
        XCTAssertTrue(sink.scheduled.isEmpty, "scrub/pause must schedule no audio")
        XCTAssertNil(controller.activeSession)
    }

    func testSettleAfterScrubDoesNotAutoPlay() throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(), sink: sink)
        controller.pausePlaybackImmediately()
        XCTAssertTrue(sink.scheduled.isEmpty)
        XCTAssertNil(controller.activeSession, "settle does not auto-start a session")
    }

    // MARK: - Route newDeviceAvailable: pause-only (no restart)

    func testReprepareForRouteChangeIsPauseOnlyNoRestart() async throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(), sink: sink)
        await started(controller)
        XCTAssertNotNil(controller.activeSession)
        let scheduledBefore = sink.scheduled.count
        controller.reprepareForRouteChange()
        XCTAssertNil(controller.activeSession, "route change stops the session (pause-only)")
        XCTAssertEqual(sink.scheduled.count, scheduledBefore, "no NEW audio scheduled (no restart)")
    }

    // MARK: - Each explicit play mints a new epoch

    func testEachPlayMintsNewEpoch() async throws {
        let sink = RecordingSink()
        let controller = try makeController(plan: try musicPlan(), sink: sink)
        await started(controller)
        controller.pausePlaybackImmediately()
        await started(controller)
        #if DEBUG
        XCTAssertEqual(controller.startedEpochCount, 2, "two explicit plays → two epochs")
        #endif
        XCTAssertEqual(sink.scheduled.count, 2, "each play schedules its own preroll")
    }

    // MARK: - Async render FAILURE → typed failure + fallback, never silent scheduling

    func testAsyncRenderFailureFiresTypedFailureAndFallback() async throws {
        let sink = RecordingSink()
        struct RenderBlewUp: Error {}
        let controller = try makeController(
            plan: try musicPlan(count: 4), sink: sink,
            asyncPrerollBuilder: { _, _, _, _, _ in throw RenderBlewUp() })
        var failure: PreviewAudioFailureReason?
        var fallbackReason: String?
        controller.onFailure = { failure = $0 }
        controller.onCanonicalUnavailable = { fallbackReason = $0 }
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        // The async render throws; the failure surfaces independent of the first frame (fail-closed).
        await drainRender(controller)
        controller.signalFirstFrameReady()   // even a late frame must not start anything after a failure
        XCTAssertTrue(sink.scheduled.isEmpty, "a render error must NOT schedule anything")
        XCTAssertNil(controller.activeSession, "no live session on a render failure")
        XCTAssertEqual(controller.readiness, .failed, "render failure → fail closed")
        XCTAssertNotNil(failure, "typed failure surfaced via onFailure")
        XCTAssertNotNil(fallbackReason, "render failure routes to the legacy fallback (never silence)")
    }

    // MARK: - Two sources render and mix into ONE scheduled buffer

    func testTwoSourcesRenderAndMixIntoOneScheduledBuffer() async throws {
        let sink = RecordingSink()
        // Build a two-source plan covering the same range; the fake async builder returns TWO sources.
        let interval = try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 4 * AudioSampleGrid.ticksPerSample)))
        func seg(_ sid: String, _ stream: String) throws -> AudioSegmentPlan {
            AudioSegmentPlan(
                clipID: try AudioClipID("c-\(sid)"), sourceID: try AudioSourceID(sid), trackID: try AudioTrackID("t-\(sid)"),
                role: .music, destinationSamples: interval, sourceStart: .zero,
                sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
                effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
                isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .stereo,
                streamIdentity: try AudioStreamIdentity(stream), sceneID: nil)
        }
        let plan = AudioPlan(sampleInterval: interval, segments: [try seg("s0", "stream-0"), try seg("s1", "stream-1")])

        let controller = try makeController(
            plan: plan, sink: sink,
            asyncPrerollBuilder: { p, revision, epoch, anchor, range in
                let count = Int(range.sampleCount)
                func source(_ sid: String, _ stream: String, _ v: Float32) throws -> PreviewMixSource {
                    var reqAlloc = MonotonicRequestIDAllocator()
                    let buf = try PreparedAudioBuffer(
                        revision: revision, epoch: epoch, request: reqAlloc.nextAudioRequest(),
                        sourceID: try AudioSourceID(sid), chunkRange: range,
                        streamIdentity: try AudioStreamIdentity(stream),
                        sourceSampleRate: 48_000, channelLayout: .stereo, isMuted: false, gain: .unity,
                        payload: try PreparedAudioPayloadHandle(identifier: "pcm:\(sid)"))
                    return PreviewMixSource(buffer: buf, samples: Array(repeating: v, count: count))
                }
                return [try source("s0", "stream-0", 0.1), try source("s1", "stream-1", 0.2)]
            })
        await started(controller)
        XCTAssertEqual(sink.scheduled.count, 1, "two renderd sources mix into ONE scheduled buffer")
        XCTAssertFalse(sink.scheduled.first!.samples.isEmpty)
        XCTAssertNotNil(controller.activeSession)
    }
}
