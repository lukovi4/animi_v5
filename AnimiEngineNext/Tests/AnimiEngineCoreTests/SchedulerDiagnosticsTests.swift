import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage G — bounded typed scheduler diagnostics (ADR-005 §9).
///
/// Proves: events carry typed identities + reasons; the sink is bounded (oldest dropped, drop count
/// observable); the scheduler emits epoch-transition / publish / kept-previous / audio-range / flush
/// events; diagnostics are purely observational (a scheduler with no sink behaves identically).
final class SchedulerDiagnosticsTests: XCTestCase {

    // MARK: - bounded sink

    func testBoundedSinkRejectsInvalidCapacity() {
        XCTAssertThrowsError(try BoundedDiagnosticsSink(capacity: 0)) {
            XCTAssertEqual($0 as? SchedulerDiagnosticsError, .invalidCapacity(0))
        }
    }

    func testBoundedSinkKeepsOnlyRecentEventsAndCountsDrops() throws {
        var sink = try BoundedDiagnosticsSink(capacity: 2)
        sink.record(.epochTransition(from: nil, to: PlaybackEpoch(raw: 1)))
        sink.record(.epochTransition(from: PlaybackEpoch(raw: 1), to: PlaybackEpoch(raw: 2)))
        sink.record(.epochTransition(from: PlaybackEpoch(raw: 2), to: PlaybackEpoch(raw: 3)))
        XCTAssertEqual(sink.events.count, 2)                       // bounded
        XCTAssertEqual(sink.recordedCount, 3)                      // drop observable
        XCTAssertEqual(sink.events.first, .epochTransition(from: PlaybackEpoch(raw: 1), to: PlaybackEpoch(raw: 2)))
    }

    // MARK: - scheduler emits typed events

    private func scheduler(diagnostics: BoundedDiagnosticsSink?) throws -> EngineScheduler {
        try EngineScheduler(
            transport: .playing(epoch: PlaybackEpoch(raw: 5)),
            revision: ProjectRevision(raw: 1), epoch: PlaybackEpoch(raw: 5),
            coverage: try ProjectTimeRange(start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 600_000)),
            currentTarget: CurrentTarget(time: try ProjectTime(ticks: 240_000), frameRequest: FrameRequestID(raw: 1)),
            masterClockKind: .monotonicHost,
            epochs: MonotonicEpochAllocator(start: 100),
            clock: FixedNowClock(now: try ProjectTime(ticks: 90_000)),
            worksetQueueCapacity: 2, audioRangeQueueCapacity: 2,
            diagnostics: diagnostics
        )
    }

    func testEpochTransitionEmittedOnDiscontinuity() throws {
        var s = try scheduler(diagnostics: try BoundedDiagnosticsSink(capacity: 16))
        _ = try s.accept(.seek(at: try ProjectTime(ticks: 120_000)))
        XCTAssertTrue(s.diagnostics!.events.contains(.epochTransition(from: PlaybackEpoch(raw: 5), to: PlaybackEpoch(raw: 100))))
    }

    func testPublishAndKeepPreviousEmitTypedEvents() throws {
        var s = try scheduler(diagnostics: try BoundedDiagnosticsSink(capacity: 16))
        let f = try Fixture.singleVideo(time: 240_000)            // matches snapshot (epoch 5, target 240_000)
        _ = s.publish(f.rendered)
        XCTAssertTrue(s.diagnostics!.events.contains(where: { if case .published = $0 { return true }; return false }))

        // A stale attempt keeps previous and emits a typed kept-previous reason.
        var s2 = try scheduler(diagnostics: try BoundedDiagnosticsSink(capacity: 16))
        _ = try s2.accept(.seek(at: try ProjectTime(ticks: 480_000)))  // active epoch → 100
        let stale = try Fixture.singleVideo(time: 240_000)             // epoch 5 ≠ 100
        _ = s2.publish(stale.rendered)
        XCTAssertTrue(s2.diagnostics!.events.contains(.keptPrevious(reason: .staleEpoch)))
    }

    func testAudioRangeAndFlushEmitEvents() throws {
        var s = try scheduler(diagnostics: try BoundedDiagnosticsSink(capacity: 32))
        let range = DecodedAudioRangeDescriptor(
            revision: ProjectRevision(raw: 1), epoch: PlaybackEpoch(raw: 5),
            request: AudioRequestID(raw: 1), source: try AudioSourceID("s1"),
            sampleRange: try AudioSampleRange.from(projectTicks: try ProjectTimeRange(
                start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 48_000)))
        )
        _ = s.enqueueAudioRange(range)
        XCTAssertTrue(s.diagnostics!.events.contains(.audioRange(reason: nil, epoch: PlaybackEpoch(raw: 5), request: AudioRequestID(raw: 1))))
        XCTAssertTrue(s.diagnostics!.events.contains(where: { if case .queueOccupancy(.audioRange, 1, 2) = $0 { return true }; return false }))
        // Seek flushes the epoch-5 range and emits an audioFlushed event.
        _ = try s.accept(.seek(at: try ProjectTime(ticks: 120_000)))
        XCTAssertTrue(s.diagnostics!.events.contains(.audioFlushed(count: 1, supersededInto: PlaybackEpoch(raw: 100))))
    }

    // MARK: - workset enqueue lifecycle

    func testWorksetEnqueueEmitsRequestedAndWorksetOccupancy() throws {
        var s = try scheduler(diagnostics: try BoundedDiagnosticsSink(capacity: 16))
        let f = try Fixture.singleVideo(time: 240_000)            // epoch 5 — current
        _ = s.enqueueWorkset(f.rendered.workset)
        XCTAssertTrue(s.diagnostics!.events.contains(.requested(f.rendered.workset.identity)))
        XCTAssertTrue(s.diagnostics!.events.contains(where: { if case .queueOccupancy(.workset, 1, 2) = $0 { return true }; return false }))
    }

    // MARK: - admit lifecycle

    func testSuccessfulAdmitEmitsAdmitted() throws {
        var s = try scheduler(diagnostics: try BoundedDiagnosticsSink(capacity: 16))
        let f = try Fixture.singleVideo(time: 240_000)            // matches snapshot (epoch 5, target 240_000)
        guard case .success = s.admit(f.rendered) else { return XCTFail("matching attempt must admit") }
        XCTAssertTrue(s.diagnostics!.events.contains(.admitted(f.rendered.workset.identity)))
    }

    func testFailedAdmitEmitsRejectedWithExactReasonTimeEpoch() throws {
        var s = try scheduler(diagnostics: try BoundedDiagnosticsSink(capacity: 16))
        _ = try s.accept(.seek(at: try ProjectTime(ticks: 240_000)))   // active epoch → 100
        s.setCurrentTarget(CurrentTarget(time: try ProjectTime(ticks: 240_000), frameRequest: FrameRequestID(raw: 1)))
        let stale = try Fixture.singleVideo(time: 240_000)            // epoch 5 ≠ active 100
        XCTAssertEqual(rejection(s.admit(stale.rendered)), .staleEpoch)
        XCTAssertTrue(s.diagnostics!.events.contains(.rejected(
            reason: .staleEpoch,
            time: stale.rendered.workset.identity.time,
            epoch: stale.rendered.workset.identity.epoch
        )))
    }

    // MARK: - diagnostics are purely observational

    func testDiagnosticsDoNotChangeBehavior() throws {
        // Commands AND completion decisions must be identical with vs. without a sink.
        var withSink = try scheduler(diagnostics: try BoundedDiagnosticsSink(capacity: 32))
        var without = try scheduler(diagnostics: nil)

        let cmd = TransportCommand.seek(at: try ProjectTime(ticks: 120_000))
        let a = try withSink.accept(cmd)
        let b = try without.accept(cmd)
        XCTAssertEqual(a, b)                                       // identical effects
        XCTAssertEqual(withSink.activeEpoch, without.activeEpoch)  // identical state
        XCTAssertEqual(withSink.transport, without.transport)
        XCTAssertNil(without.diagnostics)

        // Identical admit decision.
        let f = try Fixture.singleVideo(time: 240_000)
        let r1 = withSink.admit(f.rendered)
        let r2 = without.admit(f.rendered)
        XCTAssertEqual(rejection(r1), rejection(r2))

        // Identical enqueue + publish decisions.
        let e1 = withSink.enqueueWorkset(f.rendered.workset)
        let e2 = without.enqueueWorkset(f.rendered.workset)
        XCTAssertEqual(isSuccess(e1), isSuccess(e2))
        XCTAssertEqual(withSink.publish(f.rendered), without.publish(f.rendered))
        XCTAssertEqual(withSink.lastPublished, without.lastPublished)
    }

    private func rejection(_ result: Result<Void, RejectionReason>) -> RejectionReason? {
        if case let .failure(reason) = result { return reason }
        return nil
    }

    private func isSuccess(_ result: Result<AdmissionOutcome<FrameWorkset>, BackpressureError>) -> Bool {
        if case .success = result { return true }
        return false
    }

    // MARK: - helper clock

    private struct FixedNowClock: MasterClock {
        let now: ProjectTime
        var anchorProjectTime: ProjectTime { now }
        func currentProjectTime() throws -> ProjectTime { now }
    }
}
