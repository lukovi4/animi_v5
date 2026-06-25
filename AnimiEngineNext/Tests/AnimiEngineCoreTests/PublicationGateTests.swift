import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage D — the atomic publication gate (ADR-005 §5, §6).
///
/// Proves the gate publishes only when all six §5 conditions hold, and otherwise keeps the previous
/// complete composition with the correct typed reason: stale revision/epoch, superseded target, missing
/// dependency, out of coverage, incomplete composition, post-render revalidation failure, late-after-
/// newer. Also proves the renderer/worker cannot publish directly — only the gate returns `.publish`.
final class PublicationGateTests: XCTestCase {

    // MARK: - complete matching candidate publishes (all six §5 conditions)

    func testCompleteMatchingCandidatePublishes() throws {
        let f = try Fixture.singleVideo(time: 240_000)
        let decision = PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot)
        guard case let .publish(published) = decision else { return XCTFail("expected publish, got \(decision)") }
        XCTAssertEqual(published, f.rendered.published)
    }

    // MARK: - identity rejections

    func testStaleRevisionRejected() throws {
        let f = try Fixture.singleVideo(time: 240_000)
        let snapshot = f.snapshot.with(revision: ProjectRevision(raw: 99))
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: snapshot),
                       .keepPrevious(reason: .staleRevision))
    }

    func testStaleEpochRejected() throws {
        let f = try Fixture.singleVideo(time: 240_000)
        let snapshot = f.snapshot.with(epoch: PlaybackEpoch(raw: 77))
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: snapshot),
                       .keepPrevious(reason: .staleEpoch))
    }

    func testSupersededTargetRejected() throws {
        let f = try Fixture.singleVideo(time: 240_000)
        // The scheduler now wants a different frame request (newer target).
        let snapshot = f.snapshot.with(currentTarget: CurrentTarget(time: try Fixture.t(240_000), frameRequest: FrameRequestID(raw: 999)))
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: snapshot),
                       .keepPrevious(reason: .supersededTarget))
    }

    func testSupersededByDifferentTargetTimeRejected() throws {
        let f = try Fixture.singleVideo(time: 240_000)
        let snapshot = f.snapshot.with(currentTarget: CurrentTarget(time: try Fixture.t(480_000), frameRequest: f.frameRequest))
        // Candidate time no longer equals the current target time → superseded (after coverage widened).
        let wide = snapshot.with(coverage: try Fixture.range(0, 600_000))
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: wide),
                       .keepPrevious(reason: .supersededTarget))
    }

    // MARK: - completeness / dependency rejections

    func testMissingDependencyRejected() throws {
        // Drop one required input's receipt → the layer is unresolved → missingDependency.
        let f = try Fixture.singleVideo(time: 240_000, resolveAllInputs: false)
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot),
                       .keepPrevious(reason: .missingDependency))
    }

    func testIncompleteCompositionRejectedOnInternalTimeMismatch() throws {
        // Workset whose identity.time disagrees with the plan time → mixed-time → incompleteComposition.
        let f = try Fixture.singleVideo(time: 240_000, identityTimeOverride: 480_000)
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot),
                       .keepPrevious(reason: .incompleteComposition))
    }

    func testQualityMismatchRejected() throws {
        // Quality is part of the preview identity tuple (ADR-005 §2/§5): the workset requested "high"
        // but the published token carries "proxy". All other identity fields match, yet a quality
        // mismatch is a mixed-identity composition and must NOT publish.
        let f = try Fixture.singleVideo(time: 240_000, publishedQualityOverride: "proxy")
        XCTAssertEqual(f.rendered.workset.identity.quality, try QualityProfileID("high"))
        XCTAssertEqual(f.rendered.published.quality, try QualityProfileID("proxy"))
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot),
                       .keepPrevious(reason: .incompleteComposition))
    }

    func testMatchingQualityStillPublishes() throws {
        // The positive path: workset and published quality agree ("high") → publishes.
        let f = try Fixture.singleVideo(time: 240_000)
        XCTAssertEqual(f.rendered.workset.identity.quality, f.rendered.published.quality)
        if case .publish = PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot) {} else {
            XCTFail("matching quality must publish")
        }
    }

    // MARK: - coverage

    func testOutsideCoverageRejected() throws {
        let f = try Fixture.singleVideo(time: 240_000)
        let snapshot = f.snapshot.with(coverage: try Fixture.range(0, 100_000)) // 240_000 not in [0,100k)
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: snapshot),
                       .keepPrevious(reason: .outsideCoverage))
    }

    // MARK: - post-render revalidation

    func testPostRenderRevalidationFailureRejected() throws {
        let f = try Fixture.singleVideo(time: 240_000, postRenderRevalidated: false)
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot),
                       .keepPrevious(reason: .postRenderRevalidationFailed))
    }

    // MARK: - late after newer

    func testLateAfterNewerRejected() throws {
        // Candidate at 120_000, but a newer frame at 240_000 was already published in the same epoch.
        let f = try Fixture.singleVideo(time: 120_000)
        let snapshot = f.snapshot
            .with(currentTarget: CurrentTarget(time: try Fixture.t(120_000), frameRequest: f.frameRequest))
            .with(lastPublished: PublishedIdentitySummary(epoch: f.epoch, time: try Fixture.t(240_000), frameRequest: FrameRequestID(raw: 1)))
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: snapshot),
                       .keepPrevious(reason: .lateAfterNewer))
    }

    // MARK: - worker/render callback cannot publish directly

    func testRenderSourceReturnsValueAndOnlyGatePublishes() throws {
        // The render seam returns a PublishedFrame value; it has NO publish side effect. The only way to
        // a `.publish` decision is through the gate.
        let f = try Fixture.singleVideo(time: 240_000)
        let source = Fixture.FakeRenderSource(result: f.rendered.published)
        let returned = try source.render(f.rendered.workset)
        XCTAssertEqual(returned, f.rendered.published)   // a value, not a publication
        // Nothing visible changed by calling render(); publication still requires the gate:
        let decision = PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot)
        if case .publish = decision {} else { XCTFail("only the gate yields publish") }
    }

    // MARK: - rejection keeps the previous complete composition (no per-layer / temporal substitution)

    func testRejectionKeepsPreviousCompleteComposition() throws {
        let f = try Fixture.singleVideo(time: 240_000, postRenderRevalidated: false)
        let decision = PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot)
        // The verdict is keepPrevious — the gate never emits a partial/substituted frame.
        guard case .keepPrevious = decision else { return XCTFail("expected keepPrevious") }
    }
}
