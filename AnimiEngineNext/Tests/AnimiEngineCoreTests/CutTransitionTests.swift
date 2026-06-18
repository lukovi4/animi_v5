import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Cut transition tests (Task-002 plan, §1.2, §18).
final class CutTransitionTests: XCTestCase {

    private func twoSceneCutDocument() throws -> CanonicalProjectDocument {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "a", payloadID: "pa", durationTicks: 240_000)
        let b = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "b", payloadID: "pb", durationTicks: 240_000)
        return try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 240_000, durationBTicks: 240_000,
            transition: try CanonicalProjectFixtures.cutTransition(), postRollTicks: 0
        )
    }

    func testCutIsAlwaysSoleScene() throws {
        let doc = try twoSceneCutDocument()
        // Just before the boundary → scene a, sole.
        let before = try EvaluationHarness.evaluate(doc, atTick: 239_999)
        guard case .single(let subplan) = before.body else { return XCTFail("expected single") }
        XCTAssertEqual(subplan.sceneID.raw, "a")
        XCTAssertEqual(subplan.role, .sole)
        // At the boundary → scene b, sole (hard switch).
        let after = try EvaluationHarness.evaluate(doc, atTick: 240_000)
        guard case .single(let subplanB) = after.body else { return XCTFail("expected single") }
        XCTAssertEqual(subplanB.sceneID.raw, "b")
        XCTAssertEqual(subplanB.role, .sole)
    }

    func testCutDurationMustBeZero() {
        XCTAssertThrowsError(try SupportedTransitionEffect.validate(
            SceneTransition(kind: .cut, duration: try! TickDuration(ticks: 1), easing: try! EasingReference("none"))
        )) {
            XCTAssertEqual($0 as? ProjectValidationError, .cutWithNonZeroDuration)
        }
    }

    func testProjectDurationUnchangedByCut() throws {
        let doc = try twoSceneCutDocument()
        XCTAssertEqual(try doc.manifest.projectDuration().ticks, 480_000)
    }
}
