import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage F — audio-buffer admission (ADR-005 §8).
///
/// Proves: a current decoded range is admitted; a stale-revision range is rejected; an old-epoch range
/// (after a seek/interruption advanced the epoch) is rejected; a discontinuity flushes not-yet-rendered
/// old-epoch ranges; export identity is not a preview epoch (no epoch on `ExportIdentity`).
final class AudioAdmissionTests: XCTestCase {

    private func snapshot(revision: Int64 = 1, epoch: Int64 = 5) throws -> SchedulerSnapshot {
        SchedulerSnapshot(
            revision: ProjectRevision(raw: revision), epoch: PlaybackEpoch(raw: epoch),
            coverage: try ProjectTimeRange(start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 600_000)),
            currentTarget: CurrentTarget(time: try ProjectTime(ticks: 0), frameRequest: FrameRequestID(raw: 1)),
            lastPublished: nil
        )
    }

    private func descriptor(revision: Int64 = 1, epoch: Int64 = 5, request: Int64 = 1) throws -> DecodedAudioRangeDescriptor {
        DecodedAudioRangeDescriptor(
            revision: ProjectRevision(raw: revision), epoch: PlaybackEpoch(raw: epoch),
            request: AudioRequestID(raw: request), source: try AudioSourceID("s1"),
            sampleRange: try AudioSampleRange.from(projectTicks: try ProjectTimeRange(
                start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 48_000)))
        )
    }

    private func rejection(_ result: Result<Void, RejectionReason>) -> RejectionReason? {
        if case let .failure(reason) = result { return reason }
        return nil
    }

    // MARK: - admission

    func testCurrentDescriptorAdmitted() throws {
        XCTAssertNil(rejection(AudioRangeAdmission.admit(try descriptor(), against: try snapshot())))
    }

    func testStaleRevisionRejected() throws {
        XCTAssertEqual(rejection(AudioRangeAdmission.admit(try descriptor(revision: 99), against: try snapshot())), .staleRevision)
    }

    func testOldEpochRejectedAfterSeekOrInterruption() throws {
        // A seek/interruption advanced the active epoch to 6; a range decoded under epoch 5 arrives late.
        let current = try snapshot(epoch: 6)
        XCTAssertEqual(rejection(AudioRangeAdmission.admit(try descriptor(epoch: 5), against: current)), .staleEpoch)
    }

    // MARK: - discontinuity flush

    func testDiscontinuityFlushesOldEpochNotYetRenderedRanges() throws {
        // Pending ranges from epoch 5 and the new epoch 6; after the discontinuity only epoch-6 survive.
        let pending = [
            try descriptor(epoch: 5, request: 1),
            try descriptor(epoch: 6, request: 2),
            try descriptor(epoch: 5, request: 3),
            try descriptor(epoch: 6, request: 4),
        ]
        let survivors = AudioRangeAdmission.flushingOldEpoch(pending, currentEpoch: PlaybackEpoch(raw: 6))
        XCTAssertEqual(survivors.count, 2)
        XCTAssertTrue(survivors.allSatisfy { $0.epoch == PlaybackEpoch(raw: 6) })
        // Order preserved among survivors.
        XCTAssertEqual(survivors.map { $0.request }, [AudioRequestID(raw: 2), AudioRequestID(raw: 4)])
    }

    func testFlushKeepsAllWhenNoneStale() throws {
        let pending = [try descriptor(epoch: 6, request: 1), try descriptor(epoch: 6, request: 2)]
        let survivors = AudioRangeAdmission.flushingOldEpoch(pending, currentEpoch: PlaybackEpoch(raw: 6))
        XCTAssertEqual(survivors.count, 2)
    }

    // MARK: - export identity is not a preview epoch (ADR-005 §2)

    func testExportIdentityHasNoPlaybackEpoch() throws {
        // ExportIdentity carries revision + job only — it cannot be confused with a preview epoch, so an
        // export operation is never invalidated by a preview-epoch discontinuity. (Compile-time: there
        // is no epoch field to set.)
        let export = ExportIdentity(revision: ProjectRevision(raw: 1), job: ExportJobID(raw: 7))
        XCTAssertEqual(export.revision, ProjectRevision(raw: 1))
        XCTAssertEqual(export.job, ExportJobID(raw: 7))
    }
}
