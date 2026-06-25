import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage C — the transport state machine + pure reducer (ADR-006 §2, ADR-005 §4).
///
/// Proves: all 8 states construct/equate; play opens a fresh prepare barrier; prepare completion/timeout
/// are epoch-gated and bounded; pause reads the injected clock; every discontinuity mints a fresh epoch
/// before requesting new work; scrub is silent/held with latest-target-wins; settle holds paused;
/// interrupt/routeChange never resume; projectEdit invalidates the old epoch.
final class TransportReducerTests: XCTestCase {

    // MARK: - Deterministic fake clock (no wall clock)

    private struct FixedClock: MasterClock {
        let anchorProjectTime: ProjectTime
        let current: ProjectTime
        func currentProjectTime() throws -> ProjectTime { current }
    }

    private func clock(anchor: Int64 = 0, now: Int64) throws -> FixedClock {
        FixedClock(anchorProjectTime: try ProjectTime(ticks: anchor), current: try ProjectTime(ticks: now))
    }

    private func time(_ t: Int64) throws -> ProjectTime { try ProjectTime(ticks: t) }
    private func rev(_ r: Int64) -> ProjectRevision { ProjectRevision(raw: r) }

    private func reduce(
        _ state: TransportState, _ command: TransportCommand,
        clock: MasterClock? = nil, revision: Int64 = 0, epochs: inout MonotonicEpochAllocator
    ) throws -> (TransportState, [SchedulerEffect]) {
        try TransportReducer.reduce(state, command, clock: clock, currentRevision: rev(revision), epochs: &epochs)
    }

    // MARK: - All 8 states construct + equate

    func testAllEightStatesConstructAndEquate() throws {
        let e = PlaybackEpoch(raw: 1)
        let t = try time(100)
        XCTAssertEqual(TransportState.paused(at: t), .paused(at: t))
        XCTAssertEqual(TransportState.preparing(from: t, epoch: e), .preparing(from: t, epoch: e))
        XCTAssertEqual(TransportState.playing(epoch: e), .playing(epoch: e))
        XCTAssertEqual(TransportState.scrubbing(target: t, epoch: e), .scrubbing(target: t, epoch: e))
        XCTAssertEqual(TransportState.settling(target: t, epoch: e), .settling(target: t, epoch: e))
        XCTAssertEqual(TransportState.interrupted(at: t), .interrupted(at: t))
        XCTAssertEqual(TransportState.ended(at: t), .ended(at: t))
        let f = TransportFailure.prepareTimedOut(epoch: e, from: t)
        XCTAssertEqual(TransportState.failed(f), .failed(f))
        // Distinctness sanity.
        XCTAssertNotEqual(TransportState.paused(at: t), .ended(at: t))
        XCTAssertNotEqual(TransportState.playing(epoch: e), .playing(epoch: PlaybackEpoch(raw: 2)))
    }

    // MARK: - play opens a fresh prepare barrier (ADR-006 §5)

    func testPlayFromPausedMintsEpochAndEntersPreparing() throws {
        var epochs = MonotonicEpochAllocator()
        let (state, effects) = try reduce(.paused(at: try time(500)), .play, epochs: &epochs)
        guard case let .preparing(from, epoch) = state else { return XCTFail("expected preparing, got \(state)") }
        XCTAssertEqual(from, try time(500))
        XCTAssertEqual(epoch, PlaybackEpoch(raw: 0))
        // From a held state there is no old epoch to invalidate, but the fresh accepting epoch is still
        // activated explicitly (so an owner adopts it) before the prepare barrier opens.
        XCTAssertEqual(effects, [
            .activateEpoch(PlaybackEpoch(raw: 0)),
            .beginPrepareBarrier(epoch: PlaybackEpoch(raw: 0), from: try time(500)),
        ])
    }

    func testPlayFromInterruptedAndEndedAlsoPrepares() throws {
        var epochs = MonotonicEpochAllocator()
        let (s1, _) = try reduce(.interrupted(at: try time(10)), .play, epochs: &epochs)
        if case .preparing = s1 {} else { XCTFail("interrupted+play must prepare, got \(s1)") }
        let (s2, _) = try reduce(.ended(at: try time(20)), .play, epochs: &epochs)
        if case .preparing = s2 {} else { XCTFail("ended+play must prepare, got \(s2)") }
    }

    func testPlayWhilePlayingIsNoOpNoSecondBarrier() throws {
        var epochs = MonotonicEpochAllocator()
        let (state, effects) = try reduce(.playing(epoch: PlaybackEpoch(raw: 7)), .play, epochs: &epochs)
        XCTAssertEqual(state, .playing(epoch: PlaybackEpoch(raw: 7)))
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - prepare completion enters playing only from matching preparing epoch

    func testPrepareCompletedEntersPlayingOnlyForMatchingEpoch() throws {
        var epochs = MonotonicEpochAllocator()
        let preparing = TransportState.preparing(from: try time(0), epoch: PlaybackEpoch(raw: 3))
        let (state, effects) = try reduce(preparing, .prepareCompleted(epoch: PlaybackEpoch(raw: 3)), epochs: &epochs)
        XCTAssertEqual(state, .playing(epoch: PlaybackEpoch(raw: 3)))
        XCTAssertEqual(effects, [.enterPlaying(epoch: PlaybackEpoch(raw: 3))])
    }

    func testPrepareCompletedForStaleEpochDoesNotEnterPlaying() throws {
        var epochs = MonotonicEpochAllocator()
        let preparing = TransportState.preparing(from: try time(0), epoch: PlaybackEpoch(raw: 3))
        let (state, effects) = try reduce(preparing, .prepareCompleted(epoch: PlaybackEpoch(raw: 2)), epochs: &epochs)
        // Stale barrier completion: state unchanged, recorded as invalidation.
        XCTAssertEqual(state, preparing)
        XCTAssertEqual(effects.count, 1)
        if case .recordInvalidation = effects[0] {} else { XCTFail("expected recordInvalidation") }
    }

    // MARK: - prepare timeout ⇒ typed failure, bounded (no indefinite wait)

    func testPrepareTimeoutEntersTypedFailedAndActivatesFreshEpoch() throws {
        var epochs = MonotonicEpochAllocator(start: 100)   // fresh epoch ≠ the preparing epoch (5)
        let preparing = TransportState.preparing(from: try time(42), epoch: PlaybackEpoch(raw: 5))
        let (state, effects) = try reduce(preparing, .prepareTimedOut(epoch: PlaybackEpoch(raw: 5)), epochs: &epochs)
        // Typed failed state preserved.
        XCTAssertEqual(state, .failed(.prepareTimedOut(epoch: PlaybackEpoch(raw: 5), from: try time(42))))
        // The timed-out epoch is sealed off and a fresh accepting epoch is activated.
        XCTAssertTrue(effects.contains(.stopAcceptingEpoch(PlaybackEpoch(raw: 5))))
        XCTAssertTrue(effects.contains(.flushUnrenderedAudio(PlaybackEpoch(raw: 5))))
        XCTAssertTrue(effects.contains(.activateEpoch(PlaybackEpoch(raw: 100))))
        // Invalidation (stop/flush) must precede activation of the fresh epoch.
        let stopIdx = effects.firstIndex(of: .stopAcceptingEpoch(PlaybackEpoch(raw: 5)))
        let flushIdx = effects.firstIndex(of: .flushUnrenderedAudio(PlaybackEpoch(raw: 5)))
        let activateIdx = effects.firstIndex(of: .activateEpoch(PlaybackEpoch(raw: 100)))
        XCTAssertNotNil(stopIdx); XCTAssertNotNil(flushIdx); XCTAssertNotNil(activateIdx)
        XCTAssertLessThan(stopIdx!, activateIdx!)
        XCTAssertLessThan(flushIdx!, activateIdx!)
    }

    // MARK: - pause while playing reads the injected clock

    func testPauseWhilePlayingUsesInjectedClock() throws {
        var epochs = MonotonicEpochAllocator()
        let c = try clock(now: 9_999)
        let (state, effects) = try reduce(.playing(epoch: PlaybackEpoch(raw: 1)), .pause, clock: c, epochs: &epochs)
        XCTAssertEqual(state, .paused(at: try time(9_999)))
        // Old epoch invalidated; held at the clock-read time.
        XCTAssertTrue(effects.contains(.stopAcceptingEpoch(PlaybackEpoch(raw: 1))))
        XCTAssertTrue(effects.contains(.enterPausedAt(try time(9_999))))
    }

    func testPauseWhilePlayingWithoutClockThrows() throws {
        var epochs = MonotonicEpochAllocator()
        XCTAssertThrowsError(
            try reduce(.playing(epoch: PlaybackEpoch(raw: 1)), .pause, clock: nil, epochs: &epochs)
        ) {
            XCTAssertEqual($0 as? TransportReducerError, .missingClockForPause)
        }
    }

    // MARK: - pause while preparing holds EXACTLY `from` (never clock/zero)

    func testPauseFromPreparingWithoutClockHoldsFromNotZero() throws {
        var epochs = MonotonicEpochAllocator()
        let preparing = TransportState.preparing(from: try time(8_888), epoch: PlaybackEpoch(raw: 3))
        // No clock injected: the barrier never advanced time, so it must still hold exactly `from`.
        let (state, _) = try reduce(preparing, .pause, clock: nil, epochs: &epochs)
        XCTAssertEqual(state, .paused(at: try time(8_888)))
        XCTAssertNotEqual(state, .paused(at: .zero))
    }

    func testPauseFromPreparingIgnoresMisleadingClock() throws {
        var epochs = MonotonicEpochAllocator()
        let preparing = TransportState.preparing(from: try time(8_888), epoch: PlaybackEpoch(raw: 3))
        // A clock whose anchor AND current deliberately disagree with `from`; the result must still be
        // `from`, proving the held time comes from the state, not the clock.
        let misleading = try clock(anchor: 1, now: 999_999)
        let (state, _) = try reduce(preparing, .pause, clock: misleading, epochs: &epochs)
        XCTAssertEqual(state, .paused(at: try time(8_888)))
    }

    func testPauseFromPreparingInvalidatesEpochAndEmitsEnterPausedAtFrom() throws {
        var epochs = MonotonicEpochAllocator()
        let preparing = TransportState.preparing(from: try time(8_888), epoch: PlaybackEpoch(raw: 3))
        let (_, effects) = try reduce(preparing, .pause, clock: nil, epochs: &epochs)
        XCTAssertTrue(effects.contains(.stopAcceptingEpoch(PlaybackEpoch(raw: 3))))
        XCTAssertTrue(effects.contains(.flushUnrenderedAudio(PlaybackEpoch(raw: 3))))
        XCTAssertTrue(effects.contains(.enterPausedAt(try time(8_888))))
    }

    func testMissingClockForPauseAppliesOnlyToPlayingNotPreparing() throws {
        var epochs = MonotonicEpochAllocator()
        // preparing + pause + no clock must NOT throw (holds `from`).
        XCTAssertNoThrow(
            try reduce(.preparing(from: try time(5), epoch: PlaybackEpoch(raw: 1)), .pause, clock: nil, epochs: &epochs)
        )
        // playing + pause + no clock still throws (it needs the clock to read the held time).
        XCTAssertThrowsError(
            try reduce(.playing(epoch: PlaybackEpoch(raw: 1)), .pause, clock: nil, epochs: &epochs)
        ) {
            XCTAssertEqual($0 as? TransportReducerError, .missingClockForPause)
        }
    }

    // MARK: - seek mints a fresh epoch BEFORE requestWorkset

    func testSeekMintsFreshEpochBeforeRequestingWork() throws {
        var epochs = MonotonicEpochAllocator()
        let (state, effects) = try reduce(.playing(epoch: PlaybackEpoch(raw: 4)), .seek(at: try time(1_234)), epochs: &epochs)
        XCTAssertEqual(state, .paused(at: try time(1_234)))
        // Order: old epoch sealed off, then the request for the exact target.
        let stopIdx = effects.firstIndex(of: .stopAcceptingEpoch(PlaybackEpoch(raw: 4)))
        let reqIdx = effects.firstIndex(of: .requestWorkset(try time(1_234)))
        XCTAssertNotNil(stopIdx)
        XCTAssertNotNil(reqIdx)
        XCTAssertLessThan(stopIdx!, reqIdx!, "invalidation must precede new-work request")
        XCTAssertTrue(effects.contains(.flushUnrenderedAudio(PlaybackEpoch(raw: 4))))
    }

    // MARK: - scrub: silent, held, latest target wins

    func testScrubBeginEntersScrubbingWithFreshEpoch() throws {
        var epochs = MonotonicEpochAllocator()
        let (state, effects) = try reduce(.playing(epoch: PlaybackEpoch(raw: 2)), .scrubBegin(at: try time(100)), epochs: &epochs)
        guard case let .scrubbing(target, epoch) = state else { return XCTFail("expected scrubbing") }
        XCTAssertEqual(target, try time(100))
        XCTAssertEqual(epoch, PlaybackEpoch(raw: 0))
        XCTAssertTrue(effects.contains(.stopAcceptingEpoch(PlaybackEpoch(raw: 2))))
        XCTAssertTrue(effects.contains(.requestWorkset(try time(100))))
    }

    func testScrubUpdateLatestTargetWins() throws {
        var epochs = MonotonicEpochAllocator()
        let scrub = TransportState.scrubbing(target: try time(100), epoch: PlaybackEpoch(raw: 0))
        let (s1, _) = try reduce(scrub, .scrubUpdate(target: try time(200)), epochs: &epochs)
        let (s2, e2) = try reduce(s1, .scrubUpdate(target: try time(350)), epochs: &epochs)
        // Same epoch throughout (one uninterrupted gesture); only the target advances.
        XCTAssertEqual(s2, .scrubbing(target: try time(350), epoch: PlaybackEpoch(raw: 0)))
        XCTAssertTrue(e2.contains(.cancelQueued))
        XCTAssertTrue(e2.contains(.requestWorkset(try time(350))))
    }

    // MARK: - scrub end enters settling exact final target, no auto-resume

    func testScrubEndEntersSettlingExactTargetAndDoesNotAutoResume() throws {
        var epochs = MonotonicEpochAllocator()
        let scrub = TransportState.scrubbing(target: try time(777), epoch: PlaybackEpoch(raw: 0))
        let (state, effects) = try reduce(scrub, .scrubEnd, epochs: &epochs)
        XCTAssertEqual(state, .settling(target: try time(777), epoch: PlaybackEpoch(raw: 0)))
        XCTAssertTrue(effects.contains(.requestWorkset(try time(777))))
        // No enterPlaying — settle does not auto-resume.
        XCTAssertFalse(effects.contains(where: { if case .enterPlaying = $0 { return true }; return false }))
    }

    func testSettlingStaysPausedUntilExplicitPlay() throws {
        var epochs = MonotonicEpochAllocator()
        // No command auto-promotes settling to playing; only an explicit play opens a new barrier.
        let settling = TransportState.settling(target: try time(777), epoch: PlaybackEpoch(raw: 0))
        let (state, _) = try reduce(settling, .play, epochs: &epochs)
        if case .preparing = state {} else { XCTFail("play from settling must open a new barrier, got \(state)") }
    }

    // MARK: - interrupt / routeChange never auto-resume

    func testInterruptDoesNotResume() throws {
        var epochs = MonotonicEpochAllocator()
        let (state, effects) = try reduce(.playing(epoch: PlaybackEpoch(raw: 1)), .interrupt(at: try time(55)), epochs: &epochs)
        XCTAssertEqual(state, .interrupted(at: try time(55)))
        XCTAssertTrue(effects.contains(.stopAcceptingEpoch(PlaybackEpoch(raw: 1))))
        XCTAssertTrue(effects.contains(.recordInvalidation(.interrupted)))
        XCTAssertFalse(effects.contains(where: { if case .enterPlaying = $0 { return true }; return false }))
    }

    func testRouteChangeDoesNotResume() throws {
        var epochs = MonotonicEpochAllocator()
        let (state, effects) = try reduce(.playing(epoch: PlaybackEpoch(raw: 1)), .routeChange(at: try time(66)), epochs: &epochs)
        XCTAssertEqual(state, .interrupted(at: try time(66)))
        XCTAssertTrue(effects.contains(.recordInvalidation(.routeChanged)))
        XCTAssertFalse(effects.contains(where: { if case .enterPlaying = $0 { return true }; return false }))
    }

    // MARK: - projectEdit invalidates the old epoch, does not admit old work

    func testProjectEditInvalidatesOldEpochAndHolds() throws {
        var epochs = MonotonicEpochAllocator()
        let c = try clock(now: 4_000)
        let (state, effects) = try reduce(.playing(epoch: PlaybackEpoch(raw: 8)), .projectEdit(rev(2)), clock: c, epochs: &epochs)
        // Returns to a safe held (paused) state; old epoch sealed off; new revision recorded.
        guard case .paused = state else { return XCTFail("projectEdit must hold paused, got \(state)") }
        XCTAssertTrue(effects.contains(.stopAcceptingEpoch(PlaybackEpoch(raw: 8))))
        XCTAssertTrue(effects.contains(.recordInvalidation(.projectRevisionChanged(rev(2)))))
        // No new-work request from the old revision; a later play/seek mints from the new revision.
        XCTAssertFalse(effects.contains(where: { if case .requestWorkset = $0 { return true }; return false }))
    }

    // MARK: - endReached / fail

    func testEndReachedEntersEndedAndInvalidates() throws {
        var epochs = MonotonicEpochAllocator()
        let (state, effects) = try reduce(.playing(epoch: PlaybackEpoch(raw: 9)), .endReached(at: try time(120_000)), epochs: &epochs)
        XCTAssertEqual(state, .ended(at: try time(120_000)))
        XCTAssertTrue(effects.contains(.stopAcceptingEpoch(PlaybackEpoch(raw: 9))))
    }

    func testFailEntersFailed() throws {
        var epochs = MonotonicEpochAllocator()
        let reason = try TransportFailureReason("decoder-stall")
        let f = TransportFailure.external(reason: reason)
        let (state, _) = try reduce(.playing(epoch: PlaybackEpoch(raw: 1)), .fail(f), epochs: &epochs)
        XCTAssertEqual(state, .failed(f))
    }
}
