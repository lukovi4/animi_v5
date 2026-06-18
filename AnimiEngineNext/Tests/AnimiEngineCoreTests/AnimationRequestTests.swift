import XCTest
@testable import AnimiEngineCore

/// Animation-request resolution tests (Task-002 plan, §6.3, §8.5, §18).
final class AnimationRequestTests: XCTestCase {

    private func reference(_ policy: AnimationShorterPolicy, authored: Int64 = 240_000) throws -> AnimationReference {
        try AnimationReference(
            variantID: "v", animationRef: "v.json", authoredDuration: try TickDuration(ticks: authored),
            ifShorter: policy, ifLonger: .cutAtEvaluationEnd
        )
    }

    func testSampleBeforeAuthoredEnd() throws {
        let r = try reference(.holdLast)
        let req = AnimationRequestResolver.resolve(reference: r, at: try AnimationPlaybackTime(ticks: 100_000))
        XCTAssertEqual(req, .sample(try AnimationPlaybackTime(ticks: 100_000)))
    }

    func testHoldLastAfterAuthoredEnd() throws {
        let r = try reference(.holdLast)
        let req = AnimationRequestResolver.resolve(reference: r, at: try AnimationPlaybackTime(ticks: 240_000))
        XCTAssertEqual(req, .holdLast)
        let req2 = AnimationRequestResolver.resolve(reference: r, at: try AnimationPlaybackTime(ticks: 500_000))
        XCTAssertEqual(req2, .holdLast)
    }

    func testLoopAfterAuthoredEndWraps() throws {
        let r = try reference(.loop)
        // 240000 → wrapped 0; 250000 → wrapped 10000.
        XCTAssertEqual(AnimationRequestResolver.resolve(reference: r, at: try AnimationPlaybackTime(ticks: 240_000)),
                       .looped(try AnimationPlaybackTime(ticks: 0)))
        XCTAssertEqual(AnimationRequestResolver.resolve(reference: r, at: try AnimationPlaybackTime(ticks: 250_000)),
                       .looped(try AnimationPlaybackTime(ticks: 10_000)))
    }

    func testBecomeInactiveAfterAuthoredEnd() throws {
        let r = try reference(.becomeInactive)
        XCTAssertEqual(AnimationRequestResolver.resolve(reference: r, at: try AnimationPlaybackTime(ticks: 240_000)),
                       .inactive)
    }

    func testExactlyAtAuthoredEndIsPastEnd() throws {
        // The authored endpoint is half-open: at authoredDuration itself, the policy applies.
        let r = try reference(.holdLast, authored: 100)
        XCTAssertEqual(AnimationRequestResolver.resolve(reference: r, at: try AnimationPlaybackTime(ticks: 99)),
                       .sample(try AnimationPlaybackTime(ticks: 99)))
        XCTAssertEqual(AnimationRequestResolver.resolve(reference: r, at: try AnimationPlaybackTime(ticks: 100)),
                       .holdLast)
    }

    func testZeroAuthoredDurationRejected() {
        XCTAssertThrowsError(try AnimationReference(
            variantID: "v", animationRef: "v.json", authoredDuration: .zero,
            ifShorter: .holdLast, ifLonger: .cutAtEvaluationEnd
        )) {
            XCTAssertEqual($0 as? ProjectValidationError, .invalidAuthoredAnimationDuration)
        }
    }
}
