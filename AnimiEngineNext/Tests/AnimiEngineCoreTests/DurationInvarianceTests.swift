import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Project-duration invariance tests (Task-002 plan, §7.4, §18).
final class DurationInvarianceTests: XCTestCase {

    func testTransitionDurationDoesNotChangeProjectDuration() throws {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "A", payloadID: "pA", durationTicks: 2_000_000)
        let b = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "B", payloadID: "pB", durationTicks: 2_000_000)

        let cut = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 720_000, durationBTicks: 720_000,
            transition: try CanonicalProjectFixtures.cutTransition(), postRollTicks: 0
        )
        let fade = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 720_000, durationBTicks: 720_000,
            transition: try CanonicalProjectFixtures.fadeTransition(durationTicks: 240_000), postRollTicks: 120_000
        )
        // Both have the same total project duration = sum of nominal scene durations.
        XCTAssertEqual(try cut.manifest.projectDuration().ticks, 1_440_000)
        XCTAssertEqual(try fade.manifest.projectDuration().ticks, 1_440_000)
    }

    func testProjectDurationIsSumOfNominalDurations() throws {
        let scenes = (0..<5).map { i in
            SceneManifestEntry(id: try! SceneInstanceID("s\(i)"), payloadID: try! ScenePayloadID("p\(i)"),
                               nominalDuration: try! TickDuration(ticks: 100_000), postRollCapability: .zero)
        }
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(), scenes: scenes,
            boundaryTransitions: Array(repeating: try CanonicalProjectFixtures.cutTransition(), count: 4), overlays: []
        )
        XCTAssertEqual(try manifest.projectDuration().ticks, 500_000)
    }
}
