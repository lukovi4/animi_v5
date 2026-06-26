import XCTest
@testable import AnimiEngineCore

/// Slice-004 Stage F — `PlaybackStartBarrier` contract tests.
///
/// A pure synchronous value state machine: it reports `isReady` only when every required start gate is
/// satisfied (the required set depends on whether the epoch is audio-bearing), enforces matching
/// revision/epoch on every signal, advances an injected monotonic clock, and fails closed on timeout,
/// staleness, and non-monotonic time. No device, no async, no PCM.
final class PlaybackStartBarrierTests: XCTestCase {

    private func rev(_ r: Int64) -> ProjectRevision { ProjectRevision(raw: r) }
    private func ep(_ e: Int64) -> PlaybackEpoch { PlaybackEpoch(raw: e) }

    private func barrier(
        audioBearing: Bool, timeoutTicks: Int64 = 1_000, startTick: Int64 = 0,
        revision: Int64 = 1, epoch: Int64 = 1
    ) throws -> PlaybackStartBarrier {
        try PlaybackStartBarrier(
            revision: rev(revision), epoch: ep(epoch),
            audioBearing: audioBearing, timeoutTicks: timeoutTicks, startTick: startTick)
    }

    // MARK: - Required gate sets

    func testAudioEpochRequiresAllFourGates() throws {
        let b = try barrier(audioBearing: true)
        XCTAssertEqual(b.requiredGates, Set(PlaybackStartGate.allCases))
        XCTAssertFalse(b.isReady)
    }

    func testHostEpochDoesNotRequireAudioGate() throws {
        let b = try barrier(audioBearing: false)
        XCTAssertFalse(b.requiredGates.contains(.initialAudioScheduled))
        XCTAssertEqual(b.requiredGates, [.firstFrameReady, .outputConfigured, .anchorConfigured])
    }

    // MARK: - Barrier does not complete until first frame ready

    func testBarrierNotReadyUntilFirstFrameReady_audioEpoch() throws {
        var b = try barrier(audioBearing: true)
        b = try b.markingOutputConfigured(revision: rev(1), epoch: ep(1))
        b = try b.markingAnchorConfigured(revision: rev(1), epoch: ep(1))
        b = try b.markingInitialAudioScheduled(revision: rev(1), epoch: ep(1))
        // Everything EXCEPT the first frame — must still be not ready.
        XCTAssertFalse(b.isReady)
        XCTAssertEqual(b.missingGates, [.firstFrameReady])

        b = try b.markingFirstFrameReady(revision: rev(1), epoch: ep(1))
        XCTAssertTrue(b.isReady)
        XCTAssertTrue(b.missingGates.isEmpty)
    }

    func testBarrierNotReadyUntilFirstFrameReady_hostEpoch() throws {
        var b = try barrier(audioBearing: false)
        b = try b.markingOutputConfigured(revision: rev(1), epoch: ep(1))
        b = try b.markingAnchorConfigured(revision: rev(1), epoch: ep(1))
        XCTAssertFalse(b.isReady)
        XCTAssertEqual(b.missingGates, [.firstFrameReady])

        b = try b.markingFirstFrameReady(revision: rev(1), epoch: ep(1))
        XCTAssertTrue(b.isReady, "host epoch needs no audio gate")
    }

    // MARK: - Audio gate is not part of a host epoch's required set (fail-closed)

    func testHostEpochRejectsAudioGate() throws {
        let b = try barrier(audioBearing: false)
        XCTAssertThrowsError(try b.markingInitialAudioScheduled(revision: rev(1), epoch: ep(1))) { error in
            XCTAssertEqual(error as? PlaybackStartBarrierError, .audioGateNotRequiredForHostEpoch)
        }
    }

    // MARK: - Identity (stale revision / epoch rejected)

    func testStaleRevisionSignalRejected() throws {
        let b = try barrier(audioBearing: true, revision: 5, epoch: 2)
        XCTAssertThrowsError(try b.markingFirstFrameReady(revision: rev(4), epoch: ep(2))) { error in
            XCTAssertEqual(error as? PlaybackStartBarrierError, .staleRevision(signal: rev(4), active: rev(5)))
        }
    }

    func testStaleEpochSignalRejected() throws {
        let b = try barrier(audioBearing: true, revision: 5, epoch: 2)
        XCTAssertThrowsError(try b.markingOutputConfigured(revision: rev(5), epoch: ep(1))) { error in
            XCTAssertEqual(error as? PlaybackStartBarrierError, .staleEpoch(signal: ep(1), active: ep(2)))
        }
    }

    // MARK: - Timeout returns a typed failure

    func testTimeoutBeforeReadyReturnsTypedFailure() throws {
        var b = try barrier(audioBearing: true, timeoutTicks: 100, startTick: 0)
        b = try b.markingOutputConfigured(revision: rev(1), epoch: ep(1))   // not all gates
        // Within budget: ok.
        b = try b.ticking(toMonotonicTick: 100)
        XCTAssertFalse(b.isReady)
        // Past budget while still not ready: typed timeout naming the missing gates.
        XCTAssertThrowsError(try b.ticking(toMonotonicTick: 101)) { error in
            guard case .timedOut(let elapsed, let timeout, let missing)? = error as? PlaybackStartBarrierError else {
                return XCTFail("expected timedOut, got \(error)")
            }
            XCTAssertEqual(elapsed, 101)
            XCTAssertEqual(timeout, 100)
            XCTAssertTrue(missing.contains(.firstFrameReady))
            XCTAssertTrue(missing.contains(.anchorConfigured))
            XCTAssertTrue(missing.contains(.initialAudioScheduled))
            XCTAssertFalse(missing.contains(.outputConfigured))
        }
    }

    func testReadyBarrierDoesNotTimeOut() throws {
        var b = try barrier(audioBearing: false, timeoutTicks: 10, startTick: 0)
        b = try b.markingFirstFrameReady(revision: rev(1), epoch: ep(1))
        b = try b.markingOutputConfigured(revision: rev(1), epoch: ep(1))
        b = try b.markingAnchorConfigured(revision: rev(1), epoch: ep(1))
        XCTAssertTrue(b.isReady)
        // Long past the timeout, but ready ⇒ no timeout.
        XCTAssertNoThrow(try b.ticking(toMonotonicTick: 1_000_000))
    }

    // MARK: - Non-monotonic time fails closed

    func testNonMonotonicTickFailsClosed() throws {
        var b = try barrier(audioBearing: true, timeoutTicks: 1_000, startTick: 50)
        b = try b.ticking(toMonotonicTick: 60)
        XCTAssertThrowsError(try b.ticking(toMonotonicTick: 59)) { error in
            XCTAssertEqual(error as? PlaybackStartBarrierError, .nonMonotonicTime(previous: 60, current: 59))
        }
    }

    // MARK: - Injected bounds (no hardcoded timeout)

    func testNonPositiveTimeoutRejected() {
        XCTAssertThrowsError(try barrier(audioBearing: true, timeoutTicks: 0)) { error in
            XCTAssertEqual(error as? PlaybackStartBarrierError, .invalidTimeout(0))
        }
    }

    func testNegativeStartTickRejected() {
        XCTAssertThrowsError(try barrier(audioBearing: true, startTick: -1)) { error in
            XCTAssertEqual(error as? PlaybackStartBarrierError, .nonMonotonicTime(previous: 0, current: -1))
        }
    }

    // MARK: - Immutable-by-replacement (snapshots independent)

    func testMarkingReturnsFreshSnapshotLeavingOriginalUnchanged() throws {
        let b0 = try barrier(audioBearing: true)
        let b1 = try b0.markingFirstFrameReady(revision: rev(1), epoch: ep(1))
        XCTAssertFalse(b0.satisfied.contains(.firstFrameReady), "original snapshot unchanged")
        XCTAssertTrue(b1.satisfied.contains(.firstFrameReady))
        XCTAssertNotEqual(b0, b1)
    }

    // MARK: - Value semantics

    func testBarrierIsSendableValue() {
        func requireSendable<T: Sendable>(_ type: T.Type) {}
        requireSendable(PlaybackStartBarrier.self)
        requireSendable(PlaybackStartGate.self)
    }
}
