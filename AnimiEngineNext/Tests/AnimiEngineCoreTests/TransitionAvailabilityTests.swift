import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Material/scene-level availability tests (Task-002 plan, §8, §18 "Material validation").
final class TransitionAvailabilityTests: XCTestCase {

    private func document(
        durationA: Int64, durationB: Int64, transitionDuration: Int64, postRoll: Int64,
        trimSecondsA: Int64 = 600
    ) throws -> CanonicalProjectDocument {
        // Scene A's single video layer is active over its whole scene span (large active range).
        let a = try makeScene(id: "A", payload: "pA", trimSeconds: trimSecondsA, sceneDuration: 2_000_000)
        let b = try makeScene(id: "B", payload: "pB", trimSeconds: 600, sceneDuration: 2_000_000)
        return try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: durationA, durationBTicks: durationB,
            transition: try CanonicalProjectFixtures.fadeTransition(durationTicks: transitionDuration),
            postRollTicks: postRoll
        )
    }

    private func makeScene(id: String, payload: String, trimSeconds: Int64, sceneDuration: Int64) throws -> ResolvedScenePayload {
        let layer = try CanonicalProjectFixtures.videoLayer(
            id: "\(id).v", zIndex: 0, stableOrdinal: 0, sceneDurationTicks: sceneDuration,
            media: "m-\(id)", trimSeconds: trimSeconds,
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 100, height: 100)
        )
        return ResolvedScenePayload(
            payloadID: try ScenePayloadID(payload), sceneID: try SceneInstanceID(id),
            templateRef: try TemplateReference(catalogID: "c", sceneID: id), layers: [layer]
        )
    }

    func testSufficientMaterialPasses() throws {
        // postRoll 120000 >= postHalf 120000, durations >= halves, ample trim.
        let doc = try document(durationA: 720_000, durationB: 720_000, transitionDuration: 240_000, postRoll: 120_000)
        XCTAssertNoThrow(try EvaluationHarness.evaluate(doc, atTick: 720_000))
    }

    func testInsufficientOutgoingPostRollRejectedByValidator() throws {
        // postRoll 0 < postHalf 120000.
        let doc = try document(durationA: 720_000, durationB: 720_000, transitionDuration: 240_000, postRoll: 0)
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .insufficientOutgoingPostRoll(boundaryIndex: 0))
        }
    }

    func testInsufficientOutgoingVideoMaterialRejected() throws {
        // Trim only 1 second of source, but the outgoing transition interval reaches scene time
        // 720000 + 120000 = 840000 ticks = 3.5s → target 3.5s > trim end 1s.
        // Material is now validated up front (corrective plan C-1): the builder rejects it while
        // constructing the window, before any frame is evaluated.
        let doc = try document(durationA: 720_000, durationB: 720_000, transitionDuration: 240_000, postRoll: 120_000, trimSecondsA: 1)
        XCTAssertThrowsError(try EvaluationHarness.wholeProjectWindow(doc)) { error in
            guard case .insufficientVideoMaterial = error as? ProjectValidationError else {
                return XCTFail("expected insufficientVideoMaterial, got \(error)")
            }
        }
    }

    func testImagesNeedNoTemporalMaterial() throws {
        // An image layer never triggers a material error even with a short transition window.
        let imageLayer = try CanonicalProjectFixtures.imageLayer(
            id: "A.img", zIndex: 0, stableOrdinal: 0, sceneDurationTicks: 2_000_000, image: "img",
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 100, height: 100)
        )
        let a = ResolvedScenePayload(payloadID: try ScenePayloadID("pA"), sceneID: try SceneInstanceID("A"), templateRef: try TemplateReference(catalogID: "c", sceneID: "A"), layers: [imageLayer])
        let b = try makeScene(id: "B", payload: "pB", trimSeconds: 600, sceneDuration: 2_000_000)
        let doc = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 720_000, durationBTicks: 720_000,
            transition: try CanonicalProjectFixtures.fadeTransition(durationTicks: 240_000), postRollTicks: 120_000
        )
        XCTAssertNoThrow(try EvaluationHarness.evaluate(doc, atTick: 720_000))
    }

    func testAdjacentTransitionsRequiringThreeScenesRejected() throws {
        // Middle scene duration 100000; prev postHalf + next preHalf = 60000 + 60000 = 120000 > 100000.
        let scenes = (0..<3).map { i in
            SceneManifestEntry(
                id: try! SceneInstanceID("s\(i)"), payloadID: try! ScenePayloadID("p\(i)"),
                nominalDuration: try! TickDuration(ticks: i == 1 ? 100_000 : 720_000),
                postRollCapability: try! TickDuration(ticks: 200_000)
            )
        }
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(), scenes: scenes,
            boundaryTransitions: [
                try CanonicalProjectFixtures.fadeTransition(durationTicks: 120_000),
                try CanonicalProjectFixtures.fadeTransition(durationTicks: 120_000)
            ], overlays: []
        )
        let payloads = (0..<3).map { i in try! makeScene(id: "s\(i)", payload: "p\(i)", trimSeconds: 600, sceneDuration: 2_000_000) }
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: payloads, overlayPayloads: [])
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .adjacentTransitionsRequireThreeScenes(middleSceneIndex: 1))
        }
    }

    func testBecomeInactiveRejectedWhenLayerOutlivesAnimation() throws {
        // Incoming layer must stay visible through the transition post-roll, but its animation is
        // .becomeInactive with an authored duration shorter than the evaluated interval.
        let shortAnim = try AnimationReference(
            variantID: "v", animationRef: "v.json", authoredDuration: try TickDuration(ticks: 1),
            ifShorter: .becomeInactive, ifLonger: .cutAtEvaluationEnd
        )
        let bLayer = try CanonicalProjectFixtures.videoLayer(
            id: "B.v", zIndex: 0, stableOrdinal: 0, sceneDurationTicks: 2_000_000, media: "mB", trimSeconds: 600,
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 100, height: 100), animation: shortAnim
        )
        let b = ResolvedScenePayload(payloadID: try ScenePayloadID("pB"), sceneID: try SceneInstanceID("B"), templateRef: try TemplateReference(catalogID: "c", sceneID: "B"), layers: [bLayer])
        let a = try makeScene(id: "A", payload: "pA", trimSeconds: 600, sceneDuration: 2_000_000)
        let doc = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 720_000, durationBTicks: 720_000,
            transition: try CanonicalProjectFixtures.fadeTransition(durationTicks: 240_000), postRollTicks: 120_000
        )
        // Rejected up front by the builder's lazy-payload material validation (corrective plan C-1).
        XCTAssertThrowsError(try EvaluationHarness.wholeProjectWindow(doc)) { error in
            guard case .unavailableAnimationContinuation = error as? ProjectValidationError else {
                return XCTFail("expected unavailableAnimationContinuation, got \(error)")
            }
        }
    }

    func testLastRequestedTickIsExclusiveEndMinusOne() throws {
        // Verified indirectly: a trim that exactly covers up to (but not including) the exclusive
        // end passes, proving the engine never requests the exclusive endpoint.
        // Outgoing interval reaches last tick 720000+120000-1 = 839999 → target 839999/240000 s.
        // Trim end must exceed 839999/240000 ≈ 3.4999958s. A 4-second trim passes.
        let doc = try document(durationA: 720_000, durationB: 720_000, transitionDuration: 240_000, postRoll: 120_000, trimSecondsA: 4)
        XCTAssertNoThrow(try EvaluationHarness.evaluate(doc, atTick: 720_000))
    }
}
