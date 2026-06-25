import XCTest
@testable import AnimiEngineCore

/// Slice-002 Stage A — the single shared `SceneMediaClock`. Proves the lifted `sceneMediaTime`
/// (sole/outgoing/incoming) and `mediaActiveDomain` reproduce the math previously inlined in
/// `TimelineEvaluator`/`TransitionMath`/`ProjectValidator`, exactly (behavior-preserving refactor).
final class SceneMediaClockTests: XCTestCase {

    // MARK: - sceneMediaTime: sole / outgoing

    func testSoleSceneMediaTimeIsTMinusStart() throws {
        let start = try ProjectTime(ticks: 100)
        let t = try ProjectTime(ticks: 340)
        let media = try SceneMediaClock.sceneMediaTime(role: .sole, at: t, sceneStart: start, boundary: nil)
        XCTAssertEqual(media.ticks, 240)
    }

    func testOutgoingContinuesPastNominalAtNormalSpeed() throws {
        // Outgoing post-roll: T − start keeps growing past any nominal end; never frozen/clamped here.
        let start = try ProjectTime(ticks: 0)
        let t = try ProjectTime(ticks: 1_000_000)
        let media = try SceneMediaClock.sceneMediaTime(role: .outgoing, at: t, sceneStart: start, boundary: nil)
        XCTAssertEqual(media.ticks, 1_000_000)
    }

    func testOutgoingEqualsTransitionMathOutgoing() throws {
        let start = try ProjectTime(ticks: 480)
        for raw: Int64 in [480, 481, 600, 999, 240_000] {
            let t = try ProjectTime(ticks: raw)
            let viaClock = try SceneMediaClock.sceneMediaTime(role: .outgoing, at: t, sceneStart: start, boundary: nil)
            let viaMath = try TransitionMath.outgoingSceneTime(at: t, outgoingSceneStart: start)
            XCTAssertEqual(viaClock, viaMath, "outgoing mismatch at T=\(raw)")
        }
    }

    // MARK: - sceneMediaTime: incoming (hold-first)

    func testIncomingHeldAtZeroBeforeBoundary() throws {
        let boundary = try ProjectTime(ticks: 500)
        let t = try ProjectTime(ticks: 499)
        let media = try SceneMediaClock.sceneMediaTime(role: .incoming, at: t, sceneStart: .zero, boundary: boundary)
        XCTAssertEqual(media, ScenePlaybackTime.zero)
    }

    func testIncomingAtBoundaryIsZero() throws {
        let boundary = try ProjectTime(ticks: 500)
        let media = try SceneMediaClock.sceneMediaTime(role: .incoming, at: boundary, sceneStart: .zero, boundary: boundary)
        XCTAssertEqual(media.ticks, 0)
    }

    func testIncomingAfterBoundaryIsTMinusB() throws {
        let boundary = try ProjectTime(ticks: 500)
        let t = try ProjectTime(ticks: 740)
        let media = try SceneMediaClock.sceneMediaTime(role: .incoming, at: t, sceneStart: .zero, boundary: boundary)
        XCTAssertEqual(media.ticks, 240)
    }

    func testIncomingEqualsTransitionMathIncoming() throws {
        let boundary = try ProjectTime(ticks: 500)
        for raw: Int64 in [0, 250, 499, 500, 501, 800] {
            let t = try ProjectTime(ticks: raw)
            let viaClock = try SceneMediaClock.sceneMediaTime(role: .incoming, at: t, sceneStart: .zero, boundary: boundary)
            let viaMath = try TransitionMath.incomingSceneTime(at: t, boundary: boundary)
            XCTAssertEqual(viaClock, viaMath, "incoming mismatch at T=\(raw)")
        }
    }

    func testIncomingWithoutBoundaryThrows() throws {
        let t = try ProjectTime(ticks: 10)
        XCTAssertThrowsError(
            try SceneMediaClock.sceneMediaTime(role: .incoming, at: t, sceneStart: .zero, boundary: nil)
        )
    }

    // MARK: - mediaActiveDomain

    private func scene(_ id: String, span: Int64) throws -> SceneManifestEntry {
        SceneManifestEntry(
            id: try SceneInstanceID(id), payloadID: try ScenePayloadID("p-\(id)"),
            nominalDuration: try TickDuration(ticks: span), postRollCapability: .zero,
            timelineSpan: try TickDuration(ticks: span)
        )
    }
    private func cut() throws -> SceneTransition {
        SceneTransition(kind: .cut, duration: .zero, easing: try EasingReference("linear"))
    }
    private func animated(_ duration: Int64) throws -> SceneTransition {
        SceneTransition(
            kind: .animated(TransitionEffect(effectID: try TransitionEffectID("fade"), parameters: .empty)),
            duration: try TickDuration(ticks: duration), easing: try EasingReference("linear")
        )
    }

    func testDomainFirstSceneCutBoundary() throws {
        let scenes = [try scene("a", span: 1000), try scene("b", span: 1000)]
        let domain = try SceneMediaClock.mediaActiveDomain(sceneIndex: 0, scenes: scenes, boundaryTransitions: [try cut()])
        XCTAssertEqual(domain.start.ticks, 0)
        XCTAssertEqual(domain.end.ticks, 1000)        // cut postHalf == 0
    }

    func testDomainFirstSceneAnimatedAddsPostHalf() throws {
        // Animated duration 7 → preHalf 3, postHalf 4 (odd tick after B).
        let scenes = [try scene("a", span: 1000), try scene("b", span: 1000)]
        let domain = try SceneMediaClock.mediaActiveDomain(sceneIndex: 0, scenes: scenes, boundaryTransitions: [try animated(7)])
        XCTAssertEqual(domain.start.ticks, 0)
        XCTAssertEqual(domain.end.ticks, 1004)        // 1000 + postHalf(4)
        XCTAssertEqual(TransitionHalves(duration: try TickDuration(ticks: 7)).postHalf, 4)
    }

    func testDomainSecondSceneStartsAfterPrecedingSpans() throws {
        let scenes = [try scene("a", span: 1000), try scene("b", span: 500)]
        // Second scene is final → no following boundary → ends at start + span.
        let domain = try SceneMediaClock.mediaActiveDomain(sceneIndex: 1, scenes: scenes, boundaryTransitions: [try animated(7)])
        XCTAssertEqual(domain.start.ticks, 1000)
        XCTAssertEqual(domain.end.ticks, 1500)
    }

    // MARK: - Fail-closed: invalid sceneIndex throws (never runtime-trap)

    func testDomainNegativeSceneIndexThrows() throws {
        let scenes = [try scene("a", span: 1000)]
        XCTAssertThrowsError(
            try SceneMediaClock.mediaActiveDomain(sceneIndex: -1, scenes: scenes, boundaryTransitions: [])
        ) {
            XCTAssertEqual($0 as? ProjectValidationError, .invalidRange(field: "mediaDomain.sceneIndex"))
        }
    }

    func testDomainSceneIndexEqualToCountThrows() throws {
        let scenes = [try scene("a", span: 1000), try scene("b", span: 500)]
        XCTAssertThrowsError(
            try SceneMediaClock.mediaActiveDomain(sceneIndex: scenes.count, scenes: scenes, boundaryTransitions: [])
        ) {
            XCTAssertEqual($0 as? ProjectValidationError, .invalidRange(field: "mediaDomain.sceneIndex"))
        }
    }
}
