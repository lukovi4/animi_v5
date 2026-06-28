import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage 6 — continuous canonical playback: after the initial preroll + first-frame start, the
/// controller schedules successive bounded chunks through the SAME render pipeline + `graph.scheduleMix`,
/// anchored to the same `PreviewAudioScheduleAnchor`. Covered with fakes only (no AVFoundation, no device):
/// chunk advancement, exact ranges, anchor-relative output time, bounded lookahead, late-completion drop,
/// stop/teardown cancellation, end-of-plan, later-chunk failure → unavailable, scrub schedules nothing.
@MainActor
final class CanonicalContinuousPlaybackTests: XCTestCase {

    // MARK: - Config for deterministic small chunks

    /// Small chunk so a short plan yields several chunks deterministically.
    private static let chunk: Int64 = 4
    /// Plan spanning exactly 3 chunks (0..<12 @ chunk=4): preroll covers [0,4); continuous covers [4,8),[8,12).
    private static let planSamples: Int64 = 12

    private static func range(start: Int64, end: Int64) throws -> AudioSampleRange {
        let tps = AudioSampleGrid.ticksPerSample
        return try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: try ProjectTime(ticks: start * tps), end: try ProjectTime(ticks: end * tps)))
    }

    private static func plan(samples: Int64 = planSamples) throws -> AudioPlan {
        let r = try range(start: 0, end: samples)
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("c0"), sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .music, destinationSamples: r, sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        return AudioPlan(sampleInterval: r, segments: [seg])
    }

    // MARK: - Recording sink (captures scheduled range + output sample time)

    private final class RecordingSink: PreviewAudioOutputSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _scheduled: [(range: AudioSampleRange, at: Int64)] = []
        var scheduled: [(range: AudioSampleRange, at: Int64)] { lock.lock(); defer { lock.unlock() }; return _scheduled }
        func configure(outputFormat: AudioOutputFormat, route: AudioOutputRoute) throws {}
        func scheduleMixed(range: AudioSampleRange, samples: [Float32], at outputSampleTime: Int64) throws {
            lock.lock(); _scheduled.append((range, outputSampleTime)); lock.unlock()
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

    private func query() throws -> AudioOutputQuery {
        AudioOutputQuery(format: try AudioOutputFormat(sampleRate: 48_000, channelLayout: .stereo),
                         route: try AudioOutputRoute(identifier: "speaker"))
    }

    /// A render-pipeline fake (as the controller's `buildInitialPrerollAsync` closure) that records every
    /// requested range and returns one exact-range source for that revision/epoch. Optionally GATES (blocks
    /// on a continuation) and/or FAILS for a specific range, to drive late-drop / failure tests.
    private final class RenderSpy: @unchecked Sendable {
        let lock = NSLock()
        private(set) var requestedRanges: [AudioSampleRange] = []
        var failRangeStart: Int64?                       // throw for the chunk starting here
        private var gateContinuations: [AudioSampleRange: CheckedContinuation<Void, Never>] = [:]
        var gatedStarts: Set<Int64> = []                // ranges to block until released

        func record(_ r: AudioSampleRange) { lock.lock(); requestedRanges.append(r); lock.unlock() }
        func release(start: Int64) {
            lock.lock()
            let conts = gateContinuations.filter { $0.key.start == start }
            for (k, _) in conts { gateContinuations[k] = nil }
            lock.unlock()
            for (_, c) in conts { c.resume() }
        }

        func build(plan: AudioPlan, revision: ProjectRevision, epoch: PlaybackEpoch,
                   anchor: PreviewAudioScheduleAnchor, range: AudioSampleRange) async throws -> [PreviewMixSource] {
            record(range)
            if let fs = failRangeStart, range.start == fs {
                throw AppRealtimeAudioIntegrationError.pcmRenderFailed(reason: "induced chunk fail @\(fs)")
            }
            if gatedStarts.contains(range.start) {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    lock.lock(); gateContinuations[range] = cont; lock.unlock()
                }
            }
            var reqAlloc = MonotonicRequestIDAllocator()
            let buffer = try PreparedAudioBuffer(
                revision: revision, epoch: epoch, request: reqAlloc.nextAudioRequest(),
                sourceID: try AudioSourceID("s0"), chunkRange: range,
                streamIdentity: try AudioStreamIdentity("stream-0"),
                sourceSampleRate: 48_000, channelLayout: .mono, isMuted: false, gain: .unity,
                payload: try PreparedAudioPayloadHandle(identifier: "spy:\(range.start)-\(range.end)"))
            return [PreviewMixSource(buffer: buffer, samples: Array(repeating: 0.1, count: Int(range.sampleCount)))]
        }
    }

    /// Build a controller with explicit small `maxChunkSamples`, a recording sink + render spy.
    private func makeController(
        plan: AudioPlan?, spy: RenderSpy, sink: RecordingSink,
        projectHasAudio: @escaping () -> Bool = { true }
    ) throws -> CanonicalPreviewAudioController {
        let deps = CanonicalPreviewAudioController.Dependencies(
            evaluatePlan: { plan },
            buildInitialPrerollAsync: { p, rev, ep, anchor, range, _ in
                try await spy.build(plan: p, revision: rev, epoch: ep, anchor: anchor, range: range)
            },
            sessionAdapter: try FakeSession(query: query()),
            sink: sink,
            makeAudioClock: { anchorProjectTime in
                AudioSampleMasterClock(anchorProjectTime: anchorProjectTime, currentSampleTime: { 0 })
            },
            maxChunkSamples: Self.chunk,
            startTimeoutTicks: 240_000 * 5,
            projectHasAudio: projectHasAudio)
        return CanonicalPreviewAudioController(dependencies: deps)
    }

    /// Stage-8 fix A: a controller with a DISTINCT initial preroll size (smaller than the continuous chunk).
    private func makeControllerFixA(
        plan: AudioPlan?, spy: RenderSpy, sink: RecordingSink,
        initialPrerollSamples: Int64, maxChunkSamples: Int64
    ) throws -> CanonicalPreviewAudioController {
        let deps = CanonicalPreviewAudioController.Dependencies(
            evaluatePlan: { plan },
            buildInitialPrerollAsync: { p, rev, ep, anchor, range, _ in
                try await spy.build(plan: p, revision: rev, epoch: ep, anchor: anchor, range: range)
            },
            sessionAdapter: try FakeSession(query: query()),
            sink: sink,
            makeAudioClock: { AudioSampleMasterClock(anchorProjectTime: $0, currentSampleTime: { 0 }) },
            maxChunkSamples: maxChunkSamples,
            initialPrerollSamples: initialPrerollSamples,
            startTimeoutTicks: 240_000 * 5,
            projectHasAudio: { true })
        return CanonicalPreviewAudioController(dependencies: deps)
    }

    private func drainPreroll(_ c: CanonicalPreviewAudioController) async {
        for _ in 0..<400 { if !c.hasInFlightPrerollTask { break }; await Task.yield() }
    }
    private func settle() async { for _ in 0..<200 { await Task.yield() } }

    // MARK: - Stage-8 fix A: small initial preroll, continuous chunks unchanged

    /// Plan long enough for a small preroll + several full continuous chunks. Interval [0, 100).
    private static func planFixA(samples: Int64 = 100) throws -> AudioPlan {
        let r = try range(start: 0, end: samples)
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("c0"), sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .music, destinationSamples: r, sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        return AudioPlan(sampleInterval: r, segments: [seg])
    }

    /// (1) initial preroll uses the SMALL initialPrerollSamples (8), not maxChunkSamples (20).
    /// (3) the first continuous chunk starts EXACTLY at preroll.end.
    /// (4) continuous chunks use maxChunkSamples (20).
    func testFixA_smallPrerollThenFullContinuousChunks() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        let controller = try makeControllerFixA(
            plan: try Self.planFixA(samples: 100), spy: spy, sink: sink,
            initialPrerollSamples: 8, maxChunkSamples: 20)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()
        let ranges = sink.scheduled.map { [$0.range.start, $0.range.end] }
        // preroll [0,8) (small), then continuous [8,28),[28,48),[48,68),[68,88),[88,100).
        XCTAssertEqual(ranges.first, [0, 8], "initial preroll uses initialPrerollSamples=8, not maxChunkSamples=20")
        XCTAssertEqual(ranges.count >= 2 ? ranges[1] : nil, [8, 28],
                       "first continuous chunk starts at preroll.end (8) and is maxChunkSamples (20) wide")
        // Every continuous chunk after the preroll is 20 wide (except the final clamp to plan end 100).
        for (i, r) in ranges.enumerated() where i >= 1 && r[1] != 100 {
            XCTAssertEqual(r[1] - r[0], 20, "continuous chunk \(i) must be maxChunkSamples (20) wide")
        }
        XCTAssertEqual(ranges.last, [88, 100], "final chunk clamps to plan end")
    }

    /// (2) when plan remaining is shorter than initialPrerollSamples, the preroll clamps to remaining.
    func testFixA_prerollClampsToRemainingWhenPlanShorter() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        // Plan only 5 long, initialPrerollSamples 8 → preroll clamps to [0,5).
        let controller = try makeControllerFixA(
            plan: try Self.planFixA(samples: 5), spy: spy, sink: sink,
            initialPrerollSamples: 8, maxChunkSamples: 20)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()
        XCTAssertEqual(sink.scheduled.map { [$0.range.start, $0.range.end] }, [[0, 5]],
                       "preroll clamps to plan remaining (5) when shorter than initialPrerollSamples (8)")
        XCTAssertNotNil(controller.activeSession, "short plan still starts cleanly (end-of-plan)")
    }

    /// Unset initialPrerollSamples (nil) → preroll falls back to maxChunkSamples (no behavior change).
    func testFixA_defaultUnsetUsesMaxChunkSamples() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        // makeController (the original) does NOT set initialPrerollSamples → preroll == maxChunkSamples (chunk=4).
        let controller = try makeController(plan: try Self.plan(), spy: spy, sink: sink)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()
        XCTAssertEqual(sink.scheduled.first.map { [$0.range.start, $0.range.end] }, [0, 4],
                       "unset initialPrerollSamples → preroll uses maxChunkSamples (4), unchanged")
    }

    // MARK: - 1+2+3. chunk0 then chunk1; chunk1 starts at chunk0.end; output sample time = anchor formula

    func testSchedulesSubsequentChunksWithExactRangesAndAnchorRelativeTime() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        let controller = try makeController(plan: try Self.plan(), spy: spy, sink: sink)

        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()

        // Initial preroll = [0,4); continuous = [4,8) then [8,12). All scheduled onto the sink.
        let ranges = sink.scheduled.map { [$0.range.start, $0.range.end] }
        XCTAssertEqual(ranges, [[0, 4], [4, 8], [8, 12]], "preroll + 2 continuous chunks, contiguous")

        // chunk1 starts exactly at chunk0.end.
        XCTAssertEqual(sink.scheduled[1].range.start, sink.scheduled[0].range.end)
        XCTAssertEqual(sink.scheduled[2].range.start, sink.scheduled[1].range.end)

        // Output sample time == anchor.outputSampleTime + (chunkStart - anchor.projectSample). Anchor here is
        // projectSample=0, outputSampleTime=0 → outputSampleTime == chunkStart.
        for s in sink.scheduled {
            XCTAssertEqual(s.at, s.range.start, "output sample time is anchor-relative (== chunkStart here)")
        }
    }

    // MARK: - 4. Continuous chunks go through the render pipeline (spy), not direct decode

    func testContinuousChunksUseRenderPipeline() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        let controller = try makeController(plan: try Self.plan(), spy: spy, sink: sink)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()
        let starts = spy.requestedRanges.map { $0.start }.sorted()
        XCTAssertEqual(starts, [0, 4, 8], "every chunk (preroll + continuous) was rendered via the pipeline")
    }

    // MARK: - 5. End-of-plan stops scheduling without error

    func testEndOfPlanStopsCleanly() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        let controller = try makeController(plan: try Self.plan(), spy: spy, sink: sink)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()
        // Exactly 3 chunks (no extra past plan end), session still active (no failure).
        XCTAssertEqual(sink.scheduled.count, 3)
        XCTAssertNotNil(controller.activeSession, "end-of-plan is clean — session not torn down")
        #if DEBUG
        XCTAssertEqual(controller.continuousChunksScheduled, 2, "2 continuous chunks after the preroll")
        #endif
    }

    // MARK: - 6. Pause before a gated chunk render completes drops the late completion

    func testPauseDropsLateChunkCompletion() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        spy.gatedStarts = [4]                            // sequential: only chunk [4,8) is in flight
        let controller = try makeController(plan: try Self.plan(), spy: spy, sink: sink)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()                                   // preroll [0,4) scheduled; chunk [4,8) render parked

        XCTAssertEqual(sink.scheduled.count, 1, "only the preroll scheduled; continuous chunk is parked")

        // Pause while the chunk render is in flight → cancels + invalidates generation.
        controller.pausePlaybackImmediately()
        XCTAssertNil(controller.activeSession, "pause stops the session")

        // Release the parked render AFTER pause: its late completion must schedule NOTHING.
        spy.release(start: 4)
        await settle()
        XCTAssertEqual(sink.scheduled.count, 1, "late chunk completion after pause must NOT be scheduled")
    }

    // MARK: - 7. Teardown cancels next-chunk renders

    func testTeardownCancelsContinuous() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        spy.gatedStarts = [4]
        let controller = try makeController(plan: try Self.plan(), spy: spy, sink: sink)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()
        controller.teardown()
        spy.release(start: 4)
        await settle()
        XCTAssertEqual(sink.scheduled.count, 1, "teardown drops in-flight continuous chunks")
        XCTAssertNil(controller.activeSession)
    }

    // MARK: - 8. Render failure in a LATER chunk triggers canonical unavailable, not silence

    func testLaterChunkFailureRoutesToUnavailable() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        spy.failRangeStart = 4                           // the (only) continuous chunk fails
        // Plan = preroll [0,4) + exactly ONE continuous chunk [4,8) → deterministic (no [8,12) race).
        let controller = try makeController(plan: try Self.plan(samples: 8), spy: spy, sink: sink)
        var unavailable: String?
        controller.onCanonicalUnavailable = { unavailable = $0 }

        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()

        XCTAssertNotNil(unavailable, "a non-empty later-chunk render failure must route to canonical-unavailable")
        XCTAssertNil(controller.activeSession, "failed continuous chunk tears the epoch down (no silent partial)")
        // The preroll [0,4) was scheduled before the failure; the failing chunk scheduled nothing.
        XCTAssertEqual(sink.scheduled.map { $0.range.start }, [0], "no silence/partial scheduled for the failed chunk")
    }

    // MARK: - 9. SEQUENTIAL scheduling: next chunk is not requested until the previous one schedules

    func testSequentialSchedulingDoesNotRequestNextUntilPreviousScheduled() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        spy.gatedStarts = [4]                            // park the first continuous chunk render
        let controller = try makeController(plan: try Self.plan(), spy: spy, sink: sink)  // chunks [4,8),[8,12)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()

        // While [4,8) is parked, [8,12) MUST NOT be requested (sequential, depth 1).
        let continuousStarts0 = spy.requestedRanges.map { $0.start }.filter { $0 >= 4 }.sorted()
        XCTAssertEqual(continuousStarts0, [4], "only chunk [4,8) requested; [8,12) must wait for it to schedule")

        // Release [4,8): it renders + schedules, and ONLY THEN is [8,12) requested.
        spy.release(start: 4)
        await settle()
        let continuousStarts1 = spy.requestedRanges.map { $0.start }.filter { $0 >= 4 }.sorted()
        XCTAssertEqual(continuousStarts1, [4, 8], "next chunk requested only after the previous scheduled")
        XCTAssertEqual(sink.scheduled.map { [$0.range.start, $0.range.end] }, [[0, 4], [4, 8], [8, 12]])
    }

    // MARK: - S7 (Stage-7 fix): a chunk past the LAST segment's destination end is a clean audio end,
    //         NOT `audioRenderPipelineUnavailable`. Plan sampleInterval extends past the last segment
    //         (e.g. a later scene with no video-original segments) so the renderer returns zero sources.

    /// Plan whose `sampleInterval` is WIDER than its single segment's destination: segment covers [0,4),
    /// but the interval runs [0,12). Chunks [4,8) and [8,12) are past the segment → zero sources.
    private static func planWithSegmentEndingBeforeInterval() throws -> AudioPlan {
        let interval = try range(start: 0, end: planSamples)        // [0,12)
        let segDest = try range(start: 0, end: chunk)               // [0,4) — only the first chunk has audio
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("c0"), sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .videoLayer, destinationSamples: segDest, sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        return AudioPlan(sampleInterval: interval, segments: [seg])
    }

    /// A render spy that mirrors `BackgroundCanonicalPCMRenderer`: it returns ZERO sources for any chunk that
    /// starts at/after the max segment destination end (no overlap), and one source otherwise.
    private final class CoverageAwareRenderSpy: @unchecked Sendable {
        let plan: AudioPlan
        let lock = NSLock()
        private(set) var requestedRanges: [AudioSampleRange] = []
        init(plan: AudioPlan) { self.plan = plan }
        func build(plan: AudioPlan, revision: ProjectRevision, epoch: PlaybackEpoch,
                   anchor: PreviewAudioScheduleAnchor, range: AudioSampleRange) async throws -> [PreviewMixSource] {
            lock.lock(); requestedRanges.append(range); lock.unlock()
            let lastEnd = plan.segments.map(\.destinationSamples.end).max() ?? 0
            if range.start >= lastEnd { return [] }     // past all segments → zero sources (renderer behaviour)
            var reqAlloc = MonotonicRequestIDAllocator()
            let buffer = try PreparedAudioBuffer(
                revision: revision, epoch: epoch, request: reqAlloc.nextAudioRequest(),
                sourceID: try AudioSourceID("s0"), chunkRange: range,
                streamIdentity: try AudioStreamIdentity("stream-0"),
                sourceSampleRate: 48_000, channelLayout: .mono, isMuted: false, gain: .unity,
                payload: try PreparedAudioPayloadHandle(identifier: "cov:\(range.start)-\(range.end)"))
            return [PreviewMixSource(buffer: buffer, samples: Array(repeating: 0.1, count: Int(range.sampleCount)))]
        }
    }

    private func makeControllerCoverage(
        plan: AudioPlan, spy: CoverageAwareRenderSpy, sink: RecordingSink
    ) throws -> CanonicalPreviewAudioController {
        let deps = CanonicalPreviewAudioController.Dependencies(
            evaluatePlan: { plan },
            buildInitialPrerollAsync: { p, rev, ep, anchor, range, _ in
                try await spy.build(plan: p, revision: rev, epoch: ep, anchor: anchor, range: range)
            },
            sessionAdapter: try FakeSession(query: query()),
            sink: sink,
            makeAudioClock: { anchorProjectTime in
                AudioSampleMasterClock(anchorProjectTime: anchorProjectTime, currentSampleTime: { 0 })
            },
            maxChunkSamples: Self.chunk,
            startTimeoutTicks: 240_000 * 5,
            projectHasAudio: { true })
        return CanonicalPreviewAudioController(dependencies: deps)
    }

    func testChunkPastLastSegmentEndsCleanlyNotUnavailable() async throws {
        let plan = try Self.planWithSegmentEndingBeforeInterval()   // segment [0,4), interval [0,12)
        let spy = CoverageAwareRenderSpy(plan: plan); let sink = RecordingSink()
        let controller = try makeControllerCoverage(plan: plan, spy: spy, sink: sink)
        var unavailable: String?
        var failure: PreviewAudioFailureReason?
        controller.onCanonicalUnavailable = { unavailable = $0 }
        controller.onFailure = { failure = $0 }

        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()

        // Preroll [0,4) had audio and scheduled; the continuous chunk [4,8) is past the segment → clean end.
        XCTAssertNil(unavailable, "a chunk past the last segment must NOT route to audioRenderPipelineUnavailable")
        XCTAssertNil(failure, "no failure surfaced for a clean audio end")
        XCTAssertNotNil(controller.activeSession, "clean end keeps the session (already-scheduled audio plays)")
        XCTAssertEqual(sink.scheduled.map { $0.range.start }, [0], "only the segment-covered preroll scheduled")
    }

    func testInteriorGapStillFailsClosed() async throws {
        // A plan whose segment covers [0,4) AND [8,12) but NOT [4,8): the middle chunk is an interior gap.
        let interval = try Self.range(start: 0, end: 12)
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("c0"), sourceID: try AudioSourceID("s0"), trackID: try AudioTrackID("t0"),
            role: .videoLayer, destinationSamples: try Self.range(start: 0, end: 12), sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false, gain: .unity, sourceSampleRate: 48_000, channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"), sceneID: nil)
        let plan = AudioPlan(sampleInterval: interval, segments: [seg])
        // Spy that returns zero for the MIDDLE chunk [4,8) only — an interior gap BEFORE the last segment end (12).
        final class MiddleGapSpy: @unchecked Sendable {
            func build(plan: AudioPlan, revision: ProjectRevision, epoch: PlaybackEpoch,
                       anchor: PreviewAudioScheduleAnchor, range: AudioSampleRange) async throws -> [PreviewMixSource] {
                if range.start == 4 { return [] }          // interior gap (last segment end is 12)
                var reqAlloc = MonotonicRequestIDAllocator()
                let buffer = try PreparedAudioBuffer(
                    revision: revision, epoch: epoch, request: reqAlloc.nextAudioRequest(),
                    sourceID: try AudioSourceID("s0"), chunkRange: range,
                    streamIdentity: try AudioStreamIdentity("stream-0"),
                    sourceSampleRate: 48_000, channelLayout: .mono, isMuted: false, gain: .unity,
                    payload: try PreparedAudioPayloadHandle(identifier: "mid:\(range.start)-\(range.end)"))
                return [PreviewMixSource(buffer: buffer, samples: Array(repeating: 0.1, count: Int(range.sampleCount)))]
            }
        }
        let spy = MiddleGapSpy(); let sink = RecordingSink()
        let deps = CanonicalPreviewAudioController.Dependencies(
            evaluatePlan: { plan },
            buildInitialPrerollAsync: { p, rev, ep, anchor, range, _ in
                try await spy.build(plan: p, revision: rev, epoch: ep, anchor: anchor, range: range)
            },
            sessionAdapter: try FakeSession(query: query()), sink: sink,
            makeAudioClock: { AudioSampleMasterClock(anchorProjectTime: $0, currentSampleTime: { 0 }) },
            maxChunkSamples: Self.chunk, startTimeoutTicks: 240_000 * 5, projectHasAudio: { true })
        let controller = CanonicalPreviewAudioController(dependencies: deps)
        var unavailable: String?
        controller.onCanonicalUnavailable = { unavailable = $0 }
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()
        // The interior gap (chunk [4,8) before last-segment-end 12) must fail closed, NOT be hidden as endOfPlan.
        XCTAssertNotNil(unavailable, "an interior empty chunk before the last segment end must fail closed")
        XCTAssertNil(controller.activeSession, "interior gap tears the epoch down (never silent partial)")
    }

    // MARK: - 10. Max in-flight is 1 (no parallel adjacent-chunk renders)

    func testMaxInFlightIsOne() async throws {
        let spy = RenderSpy(); let sink = RecordingSink()
        spy.gatedStarts = [4, 8, 12, 16, 20]            // park every continuous chunk
        let controller = try makeController(plan: try Self.plan(samples: 40), spy: spy, sink: sink)
        controller.startPlayback(fromSeconds: 0, hostTime: 0)
        await drainPreroll(controller)
        controller.signalFirstFrameReady()
        await settle()
        // Sequential: at most ONE continuous render in flight at a time.
        let continuousRequested = spy.requestedRanges.filter { $0.start >= 4 }.count
        XCTAssertEqual(continuousRequested, 1, "exactly one continuous render in flight (depth 1, sequential)")
        XCTAssertEqual(CanonicalPreviewAudioController.continuousLookaheadDepth, 1)
    }
}
