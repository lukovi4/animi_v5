import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage E — scheduler-owned admission (ADR-005 §4, §7).
///
/// Proves: a matching request identity is admitted; stale revision/epoch, superseded target (by frame
/// request OR by time), and out-of-coverage are rejected; a stale completion already submitted (after a
/// cancellation that did not stop it) is still rejected by identity; a `RenderAttempt`/`PublishedFrame`
/// is admitted only when its identity matches the active snapshot.
final class AdmissionStaleTests: XCTestCase {

    // MARK: - Builders

    private func snapshot(
        revision: Int64 = 1, epoch: Int64 = 5, coverage: (Int64, Int64) = (0, 600_000),
        targetTime: Int64 = 240_000, targetFrameRequest: Int64 = 1
    ) throws -> SchedulerSnapshot {
        SchedulerSnapshot(
            revision: ProjectRevision(raw: revision), epoch: PlaybackEpoch(raw: epoch),
            coverage: try ProjectTimeRange(start: try ProjectTime(ticks: coverage.0), end: try ProjectTime(ticks: coverage.1)),
            currentTarget: CurrentTarget(time: try ProjectTime(ticks: targetTime), frameRequest: FrameRequestID(raw: targetFrameRequest)),
            lastPublished: nil
        )
    }

    private func identity(
        revision: Int64 = 1, epoch: Int64 = 5, frameRequest: Int64 = 1, time: Int64 = 240_000, quality: String = "high"
    ) throws -> RequestIdentity {
        RequestIdentity(
            revision: ProjectRevision(raw: revision), epoch: PlaybackEpoch(raw: epoch),
            frameRequest: FrameRequestID(raw: frameRequest), time: try ProjectTime(ticks: time),
            quality: try QualityProfileID(quality)
        )
    }

    // MARK: - RequestIdentity admission

    func testMatchingIdentityAdmitted() throws {
        XCTAssertNil(rejection(AdmissionController.admit(try identity(), against: try snapshot())))
    }

    func testStaleRevisionRejected() throws {
        XCTAssertEqual(rejection(AdmissionController.admit(try identity(revision: 99), against: try snapshot())), .staleRevision)
    }

    func testStaleEpochRejected() throws {
        XCTAssertEqual(rejection(AdmissionController.admit(try identity(epoch: 77), against: try snapshot())), .staleEpoch)
    }

    func testSupersededFrameRequestRejected() throws {
        // Identity time matches the current target time, but the owning frame request differs.
        XCTAssertEqual(rejection(AdmissionController.admit(try identity(frameRequest: 2), against: try snapshot(targetFrameRequest: 1))), .supersededTarget)
    }

    func testSupersededTimeRejected() throws {
        // Frame request matches, but the target time differs (a stale earlier/later target).
        XCTAssertEqual(rejection(AdmissionController.admit(try identity(time: 120_000), against: try snapshot(targetTime: 240_000))), .supersededTarget)
    }

    func testOutsideCoverageRejected() throws {
        let result = AdmissionController.admit(
            try identity(time: 700_000), against: try snapshot(coverage: (0, 600_000), targetTime: 700_000)
        )
        XCTAssertEqual(rejection(result), .outsideCoverage)
    }

    // MARK: - stale completion after cancellation still rejected (ADR-005 §4)

    func testSubmittedOldCompletionAfterCancellationStillRejected() throws {
        // Model: the epoch advanced (a discontinuity minted epoch 6), the old work for epoch 5 was
        // "cancelled" but a completion for epoch 5 was already submitted and arrives anyway. Admission
        // rejects it purely by identity — cancellation is only an optimization.
        let current = try snapshot(epoch: 6)
        let oldCompletion = try identity(epoch: 5)
        XCTAssertEqual(rejection(AdmissionController.admit(oldCompletion, against: current)), .staleEpoch)
    }

    // MARK: - RenderAttempt / PublishedFrame admission

    func testMatchingRenderAttemptAdmitted() throws {
        let f = try Fixture.singleVideo(time: 240_000)
        XCTAssertNil(rejection(AdmissionController.admit(f.rendered, against: f.snapshot)))
    }

    func testRenderAttemptWithStaleEpochRejected() throws {
        let f = try Fixture.singleVideo(time: 240_000)
        let staleSnapshot = f.snapshot.with(epoch: PlaybackEpoch(raw: 999))
        XCTAssertEqual(rejection(AdmissionController.admit(f.rendered, against: staleSnapshot)), .staleEpoch)
    }

    func testRenderAttemptWithMissingDependencyRejected() throws {
        let f = try Fixture.singleVideo(time: 240_000, resolveAllInputs: false)
        XCTAssertEqual(rejection(AdmissionController.admit(f.rendered, against: f.snapshot)), .missingDependency)
    }

    func testPublishedFrameAdmittedOnlyWhenIdentityMatches() throws {
        let f = try Fixture.singleVideo(time: 240_000)
        XCTAssertNil(rejection(AdmissionController.admit(f.rendered.published, against: f.snapshot)))
        // Same token, stale revision snapshot → rejected.
        let stale = f.snapshot.with(revision: ProjectRevision(raw: 42))
        XCTAssertEqual(rejection(AdmissionController.admit(f.rendered.published, against: stale)), .staleRevision)
    }

    // MARK: - Helper

    /// The rejection reason of an admission `Result`, or `nil` on success. (`Result<Void, _>` is not
    /// `Equatable` because `Void` is not, so this extracts the comparable failure.)
    private func rejection(_ result: Result<Void, RejectionReason>) -> RejectionReason? {
        if case let .failure(reason) = result { return reason }
        return nil
    }
}
