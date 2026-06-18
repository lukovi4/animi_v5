import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Global-overlay tests (Task-002 plan, §6.4, §12, §18).
final class GlobalOverlayTests: XCTestCase {

    private func documentWithOverlays(_ count: Int) throws -> CanonicalProjectDocument {
        let scene = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: 720_000)
        let overlays = try CanonicalProjectFixtures.textOverlays(count: count, projectDurationTicks: 720_000)
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: scene.sceneID, payloadID: scene.payloadID, nominalDuration: try TickDuration(ticks: 720_000), postRollCapability: .zero)],
            boundaryTransitions: [], overlays: overlays.map(\.0)
        )
        return CanonicalProjectDocument(manifest: manifest, scenePayloads: [scene], overlayPayloads: overlays.map(\.1))
    }

    func testOverlaysRemainAboveBodyAndOrdered() throws {
        let doc = try documentWithOverlays(3)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 100_000)
        XCTAssertEqual(plan.overlays.count, 3)
        XCTAssertEqual(plan.overlays.map(\.compositionOrder), [0, 1, 2])
        XCTAssertEqual(plan.overlays.map(\.overlayID.raw), ["overlay0", "overlay1", "overlay2"])
    }

    func testOverlaysAreGlobalNotSceneLayers() throws {
        let doc = try documentWithOverlays(2)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 100_000)
        guard case .single(let subplan) = plan.body else { return XCTFail("expected single") }
        // The single scene has exactly one video layer; overlays never appear among scene layers.
        XCTAssertEqual(subplan.layers.count, 1)
        XCTAssertEqual(plan.overlays.count, 2)
    }

    func testOverlayPlaybackTimeMeasuredFromOverlayStart() throws {
        let doc = try documentWithOverlays(1)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 100_000)
        // Overlay starts at 0 → playbackTime equals the project time.
        XCTAssertEqual(plan.overlays.first?.playbackTime.ticks, 100_000)
    }

    func testTenAnimatedTextOverlaysRemainOrdered() throws {
        let doc = try documentWithOverlays(10)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 50_000)
        XCTAssertEqual(plan.overlays.count, 10)
        XCTAssertEqual(plan.overlays.map(\.compositionOrder), Array(0..<10))
        // Every overlay carries its immutable animation reference and a resolved request.
        for overlay in plan.overlays {
            XCTAssertNotNil(overlay.animationReference)
            XCTAssertNotNil(overlay.animationRequest)
        }
    }
}
