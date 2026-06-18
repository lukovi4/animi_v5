import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Synthetic stress tests: 20-video scenes, 20→20 transitions, 10 text overlays (Task-002 plan,
/// §0, §18 "Real templates and stress").
final class StressFixtureTests: XCTestCase {

    func testOneSceneWith20VideoLayersProduces20OrderedActiveLayers() throws {
        let scene = try CanonicalProjectFixtures.scene(withVideoLayers: 20, sceneID: "s", payloadID: "p", durationTicks: 720_000)
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: scene, nominalDurationTicks: 720_000)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 100_000)
        guard case .single(let subplan) = plan.body else { return XCTFail("expected single") }
        XCTAssertEqual(subplan.layers.count, 20)
        XCTAssertEqual(subplan.layers.map(\.localCompositionOrder), Array(0..<20))
        XCTAssertEqual(subplan.layers.map(\.zIndex), Array(0..<20))
    }

    func testTwentyToTwentyTransitionProducesTwoSubplansOf20Layers() throws {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 20, sceneID: "A", payloadID: "pA", durationTicks: 2_000_000)
        let b = try CanonicalProjectFixtures.scene(withVideoLayers: 20, sceneID: "B", payloadID: "pB", durationTicks: 2_000_000)
        let doc = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 720_000, durationBTicks: 720_000,
            transition: try CanonicalProjectFixtures.fadeTransition(durationTicks: 240_000), postRollTicks: 120_000
        )
        let plan = try EvaluationHarness.evaluate(doc, atTick: 720_000)
        guard case .transition(let t) = plan.body else { return XCTFail("expected transition") }
        XCTAssertEqual(t.outgoing.layers.count, 20)
        XCTAssertEqual(t.incoming.layers.count, 20)
    }

    func testTenAnimatedTextOverlaysRemainGlobalAndOrdered() throws {
        let scene = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: 720_000)
        let overlays = try CanonicalProjectFixtures.textOverlays(count: 10, projectDurationTicks: 720_000)
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: scene.sceneID, payloadID: scene.payloadID, nominalDuration: try TickDuration(ticks: 720_000), postRollCapability: .zero)],
            boundaryTransitions: [], overlays: overlays.map(\.0)
        )
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [scene], overlayPayloads: overlays.map(\.1))
        try ProjectValidator.validate(doc)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 360_000)
        XCTAssertEqual(plan.overlays.count, 10)
        XCTAssertEqual(plan.overlays.map(\.compositionOrder), Array(0..<10))
        for overlay in plan.overlays {
            if case .text = overlay.content {} else { XCTFail("expected text overlay") }
        }
    }

    func testRepeatedEvaluationProducesValueEqualFramePlans() throws {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 20, sceneID: "A", payloadID: "pA", durationTicks: 2_000_000)
        let b = try CanonicalProjectFixtures.scene(withVideoLayers: 20, sceneID: "B", payloadID: "pB", durationTicks: 2_000_000)
        let doc = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 720_000, durationBTicks: 720_000,
            transition: try CanonicalProjectFixtures.fadeTransition(durationTicks: 240_000), postRollTicks: 120_000
        )
        let window = try EvaluationHarness.wholeProjectWindow(doc)
        let p1 = try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: 728_000))
        let p2 = try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: 728_000))
        XCTAssertEqual(p1, p2)
    }
}
