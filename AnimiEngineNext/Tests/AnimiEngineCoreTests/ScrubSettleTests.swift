import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage E — latest-wins scrub coalescing + exact settle barrier (ADR-005 §7, ADR-006 §7).
///
/// Proves: scrub update A→B makes A superseded and B current; the previous complete frame is kept while
/// the latest target's frame is incomplete; settle publishes only the exact final target; a nearby
/// earlier/later target is rejected as superseded; settle never auto-resumes; decisions are global
/// (no per-layer drift / no lastGood substitution).
final class ScrubSettleTests: XCTestCase {

    private func target(_ time: Int64, _ frameRequest: Int64) throws -> ScrubTarget {
        ScrubTarget(time: try ProjectTime(ticks: time), frameRequest: FrameRequestID(raw: frameRequest))
    }

    // MARK: - latest-wins coalescing

    func testScrubUpdateAThenBMakesASuperseded() throws {
        let a = try target(100, 1)
        let b = try target(200, 2)
        let current = ScrubSettlePolicy.coalesce(current: a, update: b)
        XCTAssertEqual(current, b, "latest target wins")
        // A completion for the old target A is now superseded; B is current.
        XCTAssertEqual(ScrubSettlePolicy.classify(completion: a, latest: current), .superseded)
        XCTAssertEqual(ScrubSettlePolicy.classify(completion: b, latest: current), .currentTarget)
    }

    func testIntermediateTargetsAreSuperseded() throws {
        // A rapid scrub A→B→C: only C is current; both A and B are superseded.
        var current = try target(100, 1)
        current = ScrubSettlePolicy.coalesce(current: current, update: try target(200, 2))
        current = ScrubSettlePolicy.coalesce(current: current, update: try target(300, 3))
        XCTAssertEqual(current, try target(300, 3))
        XCTAssertEqual(ScrubSettlePolicy.classify(completion: try target(100, 1), latest: current), .superseded)
        XCTAssertEqual(ScrubSettlePolicy.classify(completion: try target(200, 2), latest: current), .superseded)
        XCTAssertEqual(ScrubSettlePolicy.classify(completion: try target(300, 3), latest: current), .currentTarget)
    }

    // MARK: - previous complete composition kept until exact target frame exists

    func testPreviousCompleteFrameKeptWhileLatestIncomplete() throws {
        let latest = try target(200, 2)
        // Latest target's exact complete frame is NOT yet available → keep previous complete composition.
        XCTAssertEqual(
            ScrubSettlePolicy.presentation(latest: latest, latestCompleteFrameAvailable: false),
            .keepPreviousComplete
        )
    }

    func testLatestPresentedOnceExactCompleteFrameAvailable() throws {
        let latest = try target(200, 2)
        XCTAssertEqual(
            ScrubSettlePolicy.presentation(latest: latest, latestCompleteFrameAvailable: true),
            .presentLatest(latest)
        )
    }

    // MARK: - exact settle barrier

    func testExactSettleTargetPublishesOnlyExactFinalTarget() throws {
        let finalTarget = try target(777, 9)
        XCTAssertEqual(
            ScrubSettlePolicy.settle(candidate: finalTarget, finalTarget: finalTarget),
            .publishExact(finalTarget)
        )
    }

    func testNearbyEarlierTargetRejectedAsSuperseded() throws {
        let finalTarget = try target(777, 9)
        // A nearby earlier target (one tick off, even same frame request) is NOT a settle substitute.
        XCTAssertEqual(
            ScrubSettlePolicy.settle(candidate: try target(776, 9), finalTarget: finalTarget),
            .rejectedSuperseded
        )
    }

    func testNearbyLaterTargetRejectedAsSuperseded() throws {
        let finalTarget = try target(777, 9)
        XCTAssertEqual(
            ScrubSettlePolicy.settle(candidate: try target(778, 9), finalTarget: finalTarget),
            .rejectedSuperseded
        )
    }

    func testSettleRejectsDifferentFrameRequestEvenAtSameTime() throws {
        let finalTarget = try target(777, 9)
        XCTAssertEqual(
            ScrubSettlePolicy.settle(candidate: try target(777, 8), finalTarget: finalTarget),
            .rejectedSuperseded
        )
    }

    // MARK: - settle does not auto-resume

    func testSettleHoldsExactTargetAndDoesNotAutoResume() throws {
        let finalTarget = try target(777, 9)
        // The settle helper yields the held paused time and emits NO play/enterPlaying decision — there
        // is no API on the policy that resumes playback. The held time equals the exact final target.
        XCTAssertEqual(ScrubSettlePolicy.settledHoldTime(finalTarget: finalTarget), try ProjectTime(ticks: 777))
        // `SettleOutcome` has only publishExact / rejectedSuperseded — no "play" case exists.
        let outcome = ScrubSettlePolicy.settle(candidate: finalTarget, finalTarget: finalTarget)
        switch outcome {
        case .publishExact, .rejectedSuperseded:
            break   // exhaustive: there is no auto-resume outcome
        }
    }

    // MARK: - global behavior (no per-layer drift / no lastGood)

    func testPresentationIsGlobalNotPerLayer() throws {
        // The presentation decision is a single global verdict for the whole composition: either present
        // the one complete latest frame, or keep the one previous complete frame. There is no per-layer
        // option in the type — `ScrubPresentation` has exactly two whole-frame cases.
        let latest = try target(200, 2)
        let whenIncomplete = ScrubSettlePolicy.presentation(latest: latest, latestCompleteFrameAvailable: false)
        let whenComplete = ScrubSettlePolicy.presentation(latest: latest, latestCompleteFrameAvailable: true)
        switch whenIncomplete {
        case .keepPreviousComplete, .presentLatest:
            break   // exhaustive: no per-layer / lastGood case exists
        }
        XCTAssertEqual(whenComplete, .presentLatest(latest))
        XCTAssertNotEqual(whenIncomplete, whenComplete)
    }
}
