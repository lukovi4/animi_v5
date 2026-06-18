import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Animated-transition worked-example tests (Task-002 plan, §14, §18 "Approved playback behavior").
final class AnimatedTransitionTests: XCTestCase {

    /// The §14 worked example: two 720,000-tick scenes, animated duration 240,000, boundary 720,000.
    private func workedExampleDocument() throws -> CanonicalProjectDocument {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "A", payloadID: "pA", durationTicks: 1_000_000)
        let b = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "B", payloadID: "pB", durationTicks: 1_000_000)
        // Scene nominal durations are 720000 each; layers active over the full post-roll window.
        return try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 720_000, durationBTicks: 720_000,
            transition: try CanonicalProjectFixtures.fadeTransition(durationTicks: 240_000),
            postRollTicks: 120_000
        )
    }

    func testFrame74IsSoleA() throws {
        let plan = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 592_000)
        guard case .single(let subplan) = plan.body else { return XCTFail("expected single A") }
        XCTAssertEqual(subplan.sceneID.raw, "A")
        XCTAssertEqual(subplan.scenePlaybackTime.ticks, 592_000)
    }

    func testFrame75TransitionBegins() throws {
        // tick 600000: progress 0/240000, A scene time 600000, B scene time 0.
        let plan = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 600_000)
        guard case .transition(let t) = plan.body else { return XCTFail("expected transition") }
        XCTAssertEqual(t.progressNumerator, 0)
        XCTAssertEqual(t.progressDenominator, 240_000)
        XCTAssertEqual(t.outgoing.scenePlaybackTime.ticks, 600_000)
        XCTAssertEqual(t.incoming.scenePlaybackTime.ticks, 0)
        XCTAssertEqual(t.outgoing.role, .outgoing)
        XCTAssertEqual(t.incoming.role, .incoming)
    }

    func testFrame90AtBoundary() throws {
        // tick 720000: progress 120000/240000, A scene time 720000, B scene time 0 (hold-first).
        let plan = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 720_000)
        guard case .transition(let t) = plan.body else { return XCTFail("expected transition") }
        XCTAssertEqual(t.progressNumerator, 120_000)
        XCTAssertEqual(t.outgoing.scenePlaybackTime.ticks, 720_000)  // continues past nominal end
        XCTAssertEqual(t.incoming.scenePlaybackTime.ticks, 0)        // hold-first: still zero at B
    }

    func testFrame91AfterBoundaryIncomingAdvances() throws {
        // tick 728000: progress 128000/240000, A scene time 728000, B scene time 8000.
        let plan = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 728_000)
        guard case .transition(let t) = plan.body else { return XCTFail("expected transition") }
        XCTAssertEqual(t.progressNumerator, 128_000)
        XCTAssertEqual(t.outgoing.scenePlaybackTime.ticks, 728_000)
        XCTAssertEqual(t.incoming.scenePlaybackTime.ticks, 8_000)
    }

    func testFrame104NearWindowEnd() throws {
        // tick 832000: progress 232000/240000, A scene time 832000, B scene time 112000.
        let plan = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 832_000)
        guard case .transition(let t) = plan.body else { return XCTFail("expected transition") }
        XCTAssertEqual(t.progressNumerator, 232_000)
        XCTAssertEqual(t.outgoing.scenePlaybackTime.ticks, 832_000)
        XCTAssertEqual(t.incoming.scenePlaybackTime.ticks, 112_000)
    }

    func testFrame105IsSoleBNoProgressOne() throws {
        // tick 840000: window end is exclusive → B sole, scene time 120000. progress 1 never emitted.
        let plan = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 840_000)
        guard case .single(let subplan) = plan.body else { return XCTFail("expected single B") }
        XCTAssertEqual(subplan.sceneID.raw, "B")
        XCTAssertEqual(subplan.scenePlaybackTime.ticks, 120_000)
    }

    func testIncomingVideoTargetsMatchWorkedExample() throws {
        // §14: frame 91 target 1/30, frame 104 target 7/15, frame 105 target 1/2 (B scene time).
        let docFrame91 = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 728_000)
        guard case .transition(let t91) = docFrame91.body,
              case .video(let req91) = t91.incoming.layers.first?.content else {
            return XCTFail("expected incoming video at frame 91")
        }
        XCTAssertEqual(req91.target, try RationalSourceTime(numerator: 1, denominator: 30))

        let docFrame105 = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 840_000)
        guard case .single(let subplan) = docFrame105.body,
              case .video(let req105) = subplan.layers.first?.content else {
            return XCTFail("expected B video at frame 105")
        }
        XCTAssertEqual(req105.target, try RationalSourceTime(numerator: 1, denominator: 2))
    }

    func testOutgoingVideoNeverFrozenContinuesPastNominalEnd() throws {
        // The outgoing A scene time strictly increases across the boundary (no freeze/clamp).
        let t1 = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 712_000)
        let t2 = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 728_000)
        guard case .transition(let a) = t1.body, case .transition(let b) = t2.body else {
            return XCTFail("expected transitions")
        }
        XCTAssertLessThan(a.outgoing.scenePlaybackTime.ticks, b.outgoing.scenePlaybackTime.ticks)
        XCTAssertEqual(b.outgoing.scenePlaybackTime.ticks, 728_000)  // > nominal end 720000
    }

    func testEasingPreservedIntoTransitionPlan() throws {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "A", payloadID: "pA", durationTicks: 1_000_000)
        let b = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "B", payloadID: "pB", durationTicks: 1_000_000)
        let doc = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 720_000, durationBTicks: 720_000,
            transition: try CanonicalProjectFixtures.fadeTransition(durationTicks: 240_000, easing: "easeInOut"),
            postRollTicks: 120_000
        )
        let plan = try EvaluationHarness.evaluate(doc, atTick: 720_000)
        guard case .transition(let t) = plan.body else { return XCTFail("expected transition") }
        XCTAssertEqual(t.easing.raw, "easeInOut")
    }

    func testTotalProjectDurationUnchangedByTransition() throws {
        XCTAssertEqual(try workedExampleDocument().manifest.projectDuration().ticks, 1_440_000)
    }

    func testIncomingContinuesWithoutJumpWhenTransitionEnds() throws {
        // Just inside window end vs just at window end: B scene time is continuous.
        let inside = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 839_000)
        let atEnd = try EvaluationHarness.evaluate(try workedExampleDocument(), atTick: 840_000)
        guard case .transition(let t) = inside.body, case .single(let s) = atEnd.body else {
            return XCTFail("expected transition then single")
        }
        // 839000 → B time 119000; 840000 → B time 120000. Difference is exactly 1000, no jump.
        XCTAssertEqual(t.incoming.scenePlaybackTime.ticks, 119_000)
        XCTAssertEqual(s.scenePlaybackTime.ticks, 120_000)
    }
}
