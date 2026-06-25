import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage F — the minimal serialized scheduler owner (ADR-006 §1).
///
/// Proves: the snapshot coheres with owned state; a discontinuity command mints a fresh epoch before any
/// completion can be admitted; completion admission rejects stale/superseded work; the gate publishes
/// only a matching attempt and records it as last-published; settle does not auto-resume; bounded queues
/// evict obsolete (wrong-epoch) work first.
final class EngineSchedulerTests: XCTestCase {

    private func scheduler(
        revision: Int64 = 1, epoch: Int64 = 5, target: Int64 = 240_000, frameRequest: Int64 = 1
    ) throws -> EngineScheduler {
        try EngineScheduler(
            transport: .playing(epoch: PlaybackEpoch(raw: epoch)),
            revision: ProjectRevision(raw: revision), epoch: PlaybackEpoch(raw: epoch),
            coverage: try ProjectTimeRange(start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 600_000)),
            currentTarget: CurrentTarget(time: try ProjectTime(ticks: target), frameRequest: FrameRequestID(raw: frameRequest)),
            masterClockKind: .monotonicHost,
            epochs: MonotonicEpochAllocator(start: 100),
            clock: nil,
            worksetQueueCapacity: 2,
            audioRangeQueueCapacity: 2
        )
    }

    // MARK: - snapshot coherence

    func testSnapshotReflectsOwnedState() throws {
        let s = try scheduler()
        let snap = s.snapshot
        XCTAssertEqual(snap.revision, ProjectRevision(raw: 1))
        XCTAssertEqual(snap.epoch, PlaybackEpoch(raw: 5))
        XCTAssertEqual(snap.currentTarget.time, try ProjectTime(ticks: 240_000))
        XCTAssertNil(snap.lastPublished)
    }

    // MARK: - command mints fresh epoch before admission

    func testSeekChangesActiveEpochToFreshEpoch() throws {
        var s = try scheduler()   // active epoch 5; allocator starts at 100
        XCTAssertEqual(s.activeEpoch, PlaybackEpoch(raw: 5))
        // Seek lands in a held (paused) state that carries NO epoch — the owner must still adopt the
        // freshly minted accepting epoch from the canonical `.activateEpoch` effect.
        let effects = try s.accept(.seek(at: try ProjectTime(ticks: 120_000)))
        XCTAssertEqual(s.activeEpoch, PlaybackEpoch(raw: 100), "owner must adopt the fresh epoch even in a held state")
        XCTAssertTrue(effects.contains(.activateEpoch(PlaybackEpoch(raw: 100))))
        // And the old epoch is sealed off before any new request.
        let stopIdx = effects.firstIndex(of: .stopAcceptingEpoch(PlaybackEpoch(raw: 5)))
        let activateIdx = effects.firstIndex(of: .activateEpoch(PlaybackEpoch(raw: 100)))
        XCTAssertNotNil(stopIdx); XCTAssertNotNil(activateIdx)
        XCTAssertLessThan(stopIdx!, activateIdx!)
    }

    func testOldEpochRenderAttemptRejectedAfterSeek() throws {
        var s = try scheduler()   // active epoch 5
        let f = try Fixture.singleVideo(time: 120_000)   // RenderAttempt under epoch 5
        _ = try s.accept(.seek(at: try ProjectTime(ticks: 120_000)))   // active epoch → 100, target 120_000
        s.setCurrentTarget(CurrentTarget(time: try ProjectTime(ticks: 120_000), frameRequest: f.frameRequest))
        // The render attempt is still tagged with the OLD epoch 5 → rejected against the new snapshot.
        XCTAssertEqual(rejection(s.admit(f.rendered)), .staleEpoch)
    }

    func testOldEpochAudioRangeRejectedAndFlushedAfterSeek() throws {
        var s = try scheduler()   // active epoch 5, audio queue capacity 2
        // Enqueue a current (epoch-5) audio range before the seek.
        let beforeSeek = try audioRange(epoch: 5, request: 1)
        guard case .success = s.enqueueAudioRange(beforeSeek) else { return XCTFail("epoch-5 range admits pre-seek") }
        XCTAssertEqual(s.audioRangeQueue.count, 1)
        // Seek advances the active epoch and flushes not-yet-rendered old-epoch ranges.
        _ = try s.accept(.seek(at: try ProjectTime(ticks: 120_000)))
        XCTAssertEqual(s.activeEpoch, PlaybackEpoch(raw: 100))
        XCTAssertEqual(s.audioRangeQueue.count, 0, "old-epoch not-yet-rendered ranges must be flushed")
        // A late old-epoch range arriving after the seek is rejected by identity.
        XCTAssertEqual(s.enqueueAudioRange(try audioRange(epoch: 5, request: 2)), .failure(.rejected(.staleEpoch)))
    }

    // MARK: - held-state discontinuities leave NO old epoch admissible

    func testPauseLeavesNoOldEpochAdmissible() throws {
        var s = try schedulerWithClock(now: 90_000)   // playing epoch 5
        _ = try s.accept(.pause)
        XCTAssertNotEqual(s.activeEpoch, PlaybackEpoch(raw: 5), "pause must mint a fresh quiescent epoch")
        XCTAssertEqual(s.activeEpoch, PlaybackEpoch(raw: 100))
        let staleAttempt = try Fixture.singleVideo(time: 90_000)   // epoch 5
        XCTAssertEqual(rejection(s.admit(staleAttempt.rendered)), .staleEpoch)
    }

    func testInterruptLeavesNoOldEpochAdmissible() throws {
        var s = try scheduler()   // playing epoch 5
        _ = try s.accept(.interrupt(at: try ProjectTime(ticks: 100_000)))
        XCTAssertEqual(s.activeEpoch, PlaybackEpoch(raw: 100))
        let stale = try Fixture.singleVideo(time: 100_000)   // epoch 5
        XCTAssertEqual(rejection(s.admit(stale.rendered)), .staleEpoch)
    }

    func testProjectEditLeavesNoOldEpochAdmissible() throws {
        var s = try schedulerWithClock(now: 100_000)   // playing epoch 5, revision 1
        _ = try s.accept(.projectEdit(ProjectRevision(raw: 2)))
        XCTAssertEqual(s.revision, ProjectRevision(raw: 2))
        XCTAssertEqual(s.activeEpoch, PlaybackEpoch(raw: 100))
        // Old-epoch AND old-revision attempt is inadmissible.
        let stale = try Fixture.singleVideo(time: 100_000)   // revision 1, epoch 5
        let reason = rejection(s.admit(stale.rendered))
        XCTAssertTrue(reason == .staleRevision || reason == .staleEpoch, "old work must be inadmissible, got \(String(describing: reason))")
    }

    func testPrepareTimeoutLeavesNoOldEpochAdmissible() throws {
        // Scheduler is preparing under epoch 5; a bounded timeout fails the transport AND mints a fresh
        // quiescent accepting epoch so the timed-out epoch's in-flight work is inadmissible.
        var s = try preparingScheduler(epoch: 5, from: 100_000)
        XCTAssertEqual(s.activeEpoch, PlaybackEpoch(raw: 5))

        _ = try s.accept(.prepareTimedOut(epoch: PlaybackEpoch(raw: 5)))

        // Typed failed state preserved.
        XCTAssertEqual(s.transport, .failed(.prepareTimedOut(epoch: PlaybackEpoch(raw: 5), from: try ProjectTime(ticks: 100_000))))
        // Fresh accepting epoch adopted.
        XCTAssertEqual(s.activeEpoch, PlaybackEpoch(raw: 100))

        // An old-epoch render attempt is now stale.
        s.setCurrentTarget(CurrentTarget(time: try ProjectTime(ticks: 100_000), frameRequest: FrameRequestID(raw: 1)))
        let staleAttempt = try Fixture.singleVideo(time: 100_000)   // epoch 5
        XCTAssertEqual(rejection(s.admit(staleAttempt.rendered)), .staleEpoch)

        // A late old-epoch audio range is rejected by identity.
        XCTAssertEqual(s.enqueueAudioRange(try audioRange(epoch: 5, request: 1)), .failure(.rejected(.staleEpoch)))
    }

    func testPrepareTimeoutFlushesOldEpochAudioRange() throws {
        // An epoch-5 audio range queued before the timeout is flushed when the timeout activates epoch 100.
        var s = try preparingScheduler(epoch: 5, from: 100_000)
        // Temporarily the active epoch is 5, so an epoch-5 range admits and is queued.
        guard case .success = s.enqueueAudioRange(try audioRange(epoch: 5, request: 7)) else {
            return XCTFail("epoch-5 range admits while preparing under epoch 5")
        }
        XCTAssertEqual(s.audioRangeQueue.count, 1)
        _ = try s.accept(.prepareTimedOut(epoch: PlaybackEpoch(raw: 5)))
        XCTAssertEqual(s.activeEpoch, PlaybackEpoch(raw: 100))
        XCTAssertEqual(s.audioRangeQueue.count, 0, "old-epoch not-yet-rendered range must be flushed on timeout")
    }

    // MARK: - helpers

    private func preparingScheduler(epoch: Int64, from: Int64) throws -> EngineScheduler {
        try EngineScheduler(
            transport: .preparing(from: try ProjectTime(ticks: from), epoch: PlaybackEpoch(raw: epoch)),
            revision: ProjectRevision(raw: 1), epoch: PlaybackEpoch(raw: epoch),
            coverage: try ProjectTimeRange(start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 600_000)),
            currentTarget: CurrentTarget(time: try ProjectTime(ticks: from), frameRequest: FrameRequestID(raw: 1)),
            masterClockKind: .monotonicHost,
            epochs: MonotonicEpochAllocator(start: 100),
            clock: FixedNowClock(now: try ProjectTime(ticks: from)),
            worksetQueueCapacity: 2, audioRangeQueueCapacity: 2
        )
    }

    private func schedulerWithClock(now: Int64) throws -> EngineScheduler {
        try EngineScheduler(
            transport: .playing(epoch: PlaybackEpoch(raw: 5)),
            revision: ProjectRevision(raw: 1), epoch: PlaybackEpoch(raw: 5),
            coverage: try ProjectTimeRange(start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 600_000)),
            currentTarget: CurrentTarget(time: try ProjectTime(ticks: now), frameRequest: FrameRequestID(raw: 1)),
            masterClockKind: .monotonicHost,
            epochs: MonotonicEpochAllocator(start: 100),
            clock: FixedNowClock(now: try ProjectTime(ticks: now)),
            worksetQueueCapacity: 2, audioRangeQueueCapacity: 2
        )
    }

    private func audioRange(epoch: Int64, request: Int64) throws -> DecodedAudioRangeDescriptor {
        DecodedAudioRangeDescriptor(
            revision: ProjectRevision(raw: 1), epoch: PlaybackEpoch(raw: epoch),
            request: AudioRequestID(raw: request), source: try AudioSourceID("s1"),
            sampleRange: try AudioSampleRange.from(projectTicks: try ProjectTimeRange(
                start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 48_000)))
        )
    }

    private struct FixedNowClock: MasterClock {
        let now: ProjectTime
        var anchorProjectTime: ProjectTime { now }
        func currentProjectTime() throws -> ProjectTime { now }
    }

    private func rejection(_ result: Result<Void, RejectionReason>) -> RejectionReason? {
        if case let .failure(reason) = result { return reason }
        return nil
    }

    // MARK: - completion admission rejects stale/superseded

    func testCompletionAdmissionRejectsStaleEpoch() throws {
        var s = try scheduler()
        let f = try Fixture.singleVideo(time: 240_000)   // epoch 5, target 240_000 — matches scheduler
        // Re-tag the scheduler with a different active epoch via a fresh scheduler to force mismatch.
        var mismatch = try scheduler(epoch: 6)
        XCTAssertEqual(rejection(mismatch.admit(f.rendered)), .staleEpoch)
        // And a matching one is admitted.
        guard case .success = s.admit(f.rendered) else { return XCTFail("matching attempt must admit") }
    }

    func testCompletionAdmissionRejectsSupersededTarget() throws {
        var s = try scheduler(target: 480_000)   // scheduler wants 480_000
        let f = try Fixture.singleVideo(time: 240_000)   // attempt is for 240_000
        XCTAssertEqual(rejection(s.admit(f.rendered)), .supersededTarget)
    }

    // MARK: - publication records last-published; mismatch keeps previous

    func testPublishMatchingAttemptRecordsLastPublished() throws {
        var s = try scheduler()
        let f = try Fixture.singleVideo(time: 240_000)
        let decision = s.publish(f.rendered)
        guard case .publish = decision else { return XCTFail("matching attempt must publish") }
        XCTAssertEqual(s.lastPublished?.time, try ProjectTime(ticks: 240_000))
        XCTAssertEqual(s.lastPublished?.epoch, PlaybackEpoch(raw: 5))
    }

    func testPublishStaleAttemptKeepsPreviousAndDoesNotRecord() throws {
        var s = try scheduler(epoch: 6)
        let f = try Fixture.singleVideo(time: 240_000)   // epoch 5 ≠ active 6
        let decision = s.publish(f.rendered)
        XCTAssertEqual(decision, .keepPrevious(reason: .staleEpoch))
        XCTAssertNil(s.lastPublished)   // nothing recorded; previous complete composition kept
    }

    // MARK: - bounded queue eviction of obsolete (wrong-epoch) worksets

    func testEnqueueWorksetEvictsObsoleteWrongEpochFirst() throws {
        var s = try scheduler()   // active epoch 5, capacity 2
        let active = try Fixture.singleVideo(time: 240_000)            // epoch 5
        // Build a wrong-epoch (obsolete) workset by hand.
        let staleIdentity = RequestIdentity(
            revision: ProjectRevision(raw: 1), epoch: PlaybackEpoch(raw: 4),
            frameRequest: FrameRequestID(raw: 9), time: try ProjectTime(ticks: 240_000),
            quality: try QualityProfileID("high")
        )
        let staleWorkset = FrameWorkset(identity: staleIdentity, plan: active.rendered.workset.plan)
        _ = s.enqueueWorkset(staleWorkset)               // [stale(epoch4)]
        _ = s.enqueueWorkset(active.rendered.workset)    // [stale, active] — full
        // Next admit must evict the obsolete wrong-epoch one first.
        let third = active.rendered.workset
        let result = s.enqueueWorkset(third)
        guard case .success(.evictedObsolete) = result else { return XCTFail("expected obsolete eviction") }
        XCTAssertLessThanOrEqual(s.worksetQueue.count, s.worksetQueue.capacity)
    }

    // MARK: - no auto-resume

    func testSettleDoesNotAutoResume() throws {
        var s = try scheduler()
        _ = try s.accept(.scrubBegin(at: try ProjectTime(ticks: 100)))
        let effects = try s.accept(.scrubEnd)
        // Transport is now settling; no enterPlaying effect, and a later tick never auto-resumes.
        if case .settling = s.transport {} else { XCTFail("expected settling, got \(s.transport)") }
        XCTAssertFalse(effects.contains(where: { if case .enterPlaying = $0 { return true }; return false }))
    }

    // MARK: - audio range enqueue routes through identity admission

    func testEnqueueAudioRangeRejectsStaleEpoch() throws {
        var s = try scheduler(epoch: 6)
        let stale = DecodedAudioRangeDescriptor(
            revision: ProjectRevision(raw: 1), epoch: PlaybackEpoch(raw: 5),
            request: AudioRequestID(raw: 1), source: try AudioSourceID("s1"),
            sampleRange: try AudioSampleRange.from(projectTicks: try ProjectTimeRange(
                start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 48_000)))
        )
        XCTAssertEqual(s.enqueueAudioRange(stale), .failure(.rejected(.staleEpoch)))
    }
}
