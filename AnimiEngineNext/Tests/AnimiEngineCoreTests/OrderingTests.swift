import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Deterministic ordering tests with equal zIndex (Task-002 plan, §6.5, §18).
final class OrderingTests: XCTestCase {

    func testLayersWithEqualZIndexOrderByStableOrdinal() throws {
        // Two layers with the same zIndex but different stable ordinals; the lower ordinal first.
        let l0 = SceneLayer(id: try LayerID("hi"), zIndex: 5, stableOrdinal: 9,
                            activeRange: try ScenePlaybackRange(start: .zero, end: try ScenePlaybackTime(ticks: 720_000)),
                            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10),
                            mediaPlacement: try CanonicalProjectFixtures.mediaPlacement(),
                            content: .image(try ImageReference("a")), animation: nil)
        let l1 = SceneLayer(id: try LayerID("lo"), zIndex: 5, stableOrdinal: 1,
                            activeRange: try ScenePlaybackRange(start: .zero, end: try ScenePlaybackTime(ticks: 720_000)),
                            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10),
                            mediaPlacement: try CanonicalProjectFixtures.mediaPlacement(),
                            content: .image(try ImageReference("b")), animation: nil)
        // Supply them out of order; the evaluator must sort deterministically.
        let payload = ResolvedScenePayload(payloadID: try ScenePayloadID("p"), sceneID: try SceneInstanceID("s"), templateRef: try TemplateReference(catalogID: "c", sceneID: "s"), layers: [l0, l1])
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: payload, nominalDurationTicks: 720_000)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 0)
        guard case .single(let subplan) = plan.body else { return XCTFail("expected single") }
        XCTAssertEqual(subplan.layers.map(\.layerID.raw), ["lo", "hi"])
        XCTAssertEqual(subplan.layers.map(\.localCompositionOrder), [0, 1])
    }

    func testZIndexTakesPrecedenceOverOrdinal() throws {
        let lowZHighOrd = SceneLayer(id: try LayerID("z0"), zIndex: 0, stableOrdinal: 100,
                            activeRange: try ScenePlaybackRange(start: .zero, end: try ScenePlaybackTime(ticks: 720_000)),
                            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10),
                            mediaPlacement: try CanonicalProjectFixtures.mediaPlacement(),
                            content: .image(try ImageReference("a")), animation: nil)
        let highZLowOrd = SceneLayer(id: try LayerID("z9"), zIndex: 9, stableOrdinal: 0,
                            activeRange: try ScenePlaybackRange(start: .zero, end: try ScenePlaybackTime(ticks: 720_000)),
                            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10),
                            mediaPlacement: try CanonicalProjectFixtures.mediaPlacement(),
                            content: .image(try ImageReference("b")), animation: nil)
        let payload = ResolvedScenePayload(payloadID: try ScenePayloadID("p"), sceneID: try SceneInstanceID("s"), templateRef: try TemplateReference(catalogID: "c", sceneID: "s"), layers: [highZLowOrd, lowZHighOrd])
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: payload, nominalDurationTicks: 720_000)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 0)
        guard case .single(let subplan) = plan.body else { return XCTFail("expected single") }
        XCTAssertEqual(subplan.layers.map(\.layerID.raw), ["z0", "z9"])
    }
}
