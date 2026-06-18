import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Hierarchical composition tests (Task-002 plan, §12, §18).
final class CompositionHierarchyTests: XCTestCase {

    func testTransitionCombinesTwoSceneSubplans() throws {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 3, sceneID: "A", payloadID: "pA", durationTicks: 2_000_000)
        let b = try CanonicalProjectFixtures.scene(withVideoLayers: 2, sceneID: "B", payloadID: "pB", durationTicks: 2_000_000)
        let doc = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 720_000, durationBTicks: 720_000,
            transition: try CanonicalProjectFixtures.fadeTransition(durationTicks: 240_000), postRollTicks: 120_000
        )
        let plan = try EvaluationHarness.evaluate(doc, atTick: 720_000)
        guard case .transition(let t) = plan.body else { return XCTFail("expected transition") }
        XCTAssertEqual(t.outgoing.layers.count, 3)
        XCTAssertEqual(t.incoming.layers.count, 2)
    }

    func testDenseLocalCompositionOrderAssigned() throws {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 4, sceneID: "A", payloadID: "pA", durationTicks: 720_000)
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: a, nominalDurationTicks: 720_000)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 0)
        guard case .single(let subplan) = plan.body else { return XCTFail("expected single") }
        XCTAssertEqual(subplan.layers.map(\.localCompositionOrder), [0, 1, 2, 3])
    }

    func testRendererSeesImmutableValueEqualPlan() throws {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 2, sceneID: "A", payloadID: "pA", durationTicks: 720_000)
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: a, nominalDurationTicks: 720_000)
        let p1 = try EvaluationHarness.evaluate(doc, atTick: 100_000)
        let p2 = try EvaluationHarness.evaluate(doc, atTick: 100_000)
        XCTAssertEqual(p1, p2)
    }

    func testInactiveLayerOutsideActiveRangeIsExcluded() throws {
        // A layer only active in [0, 100000) is absent at scene time 200000.
        let active = try ScenePlaybackRange(start: .zero, end: try ScenePlaybackTime(ticks: 100_000))
        let layer = SceneLayer(
            id: try LayerID("L"), zIndex: 0, stableOrdinal: 0, activeRange: active,
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10),
            mediaPlacement: try CanonicalProjectFixtures.mediaPlacement(),
            content: .image(try ImageReference("img")), animation: nil
        )
        let payload = ResolvedScenePayload(payloadID: try ScenePayloadID("p"), sceneID: try SceneInstanceID("s"), templateRef: try TemplateReference(catalogID: "c", sceneID: "s"), layers: [layer])
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: payload, nominalDurationTicks: 720_000)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 200_000)
        guard case .single(let subplan) = plan.body else { return XCTFail("expected single") }
        XCTAssertTrue(subplan.layers.isEmpty)
    }
}
