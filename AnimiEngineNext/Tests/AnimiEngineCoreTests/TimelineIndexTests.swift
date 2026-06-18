import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Timeline index lookup/requirements tests (Task-002 plan, §10, §18 "Timeline and lazy window").
final class TimelineIndexTests: XCTestCase {

    /// Three 240,000-tick scenes with cut boundaries → project duration 720,000.
    private func threeSceneManifest() throws -> CanonicalProjectManifest {
        let scenes = (0..<3).map { i in
            SceneManifestEntry(
                id: try! SceneInstanceID("s\(i)"), payloadID: try! ScenePayloadID("p\(i)"),
                nominalDuration: try! TickDuration(ticks: 240_000), postRollCapability: .zero
            )
        }
        return CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: scenes,
            boundaryTransitions: [try CanonicalProjectFixtures.cutTransition(), try CanonicalProjectFixtures.cutTransition()],
            overlays: []
        )
    }

    func testSceneLookupBinarySearch() throws {
        let index = try TimelineIndex(manifest: try threeSceneManifest())
        XCTAssertEqual(try index.lookup(at: try ProjectTime(ticks: 0)).requiredSceneIDs.map(\.raw), ["s0"])
        XCTAssertEqual(try index.lookup(at: try ProjectTime(ticks: 239_999)).requiredSceneIDs.map(\.raw), ["s0"])
        XCTAssertEqual(try index.lookup(at: try ProjectTime(ticks: 240_000)).requiredSceneIDs.map(\.raw), ["s1"])
        XCTAssertEqual(try index.lookup(at: try ProjectTime(ticks: 480_000)).requiredSceneIDs.map(\.raw), ["s2"])
        XCTAssertEqual(try index.lookup(at: try ProjectTime(ticks: 719_999)).requiredSceneIDs.map(\.raw), ["s2"])
    }

    func testLookupOutsideProjectRejected() throws {
        let index = try TimelineIndex(manifest: try threeSceneManifest())
        XCTAssertThrowsError(try index.lookup(at: try ProjectTime(ticks: 720_000)))
    }

    func testAnimatedTransitionLookupReturnsOutgoingAndIncoming() throws {
        // Two scenes with an animated boundary at 240000.
        let scenes = [
            SceneManifestEntry(id: try SceneInstanceID("a"), payloadID: try ScenePayloadID("pa"), nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: try TickDuration(ticks: 120_000)),
            SceneManifestEntry(id: try SceneInstanceID("b"), payloadID: try ScenePayloadID("pb"), nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)
        ]
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: scenes, boundaryTransitions: [try CanonicalProjectFixtures.fadeTransition(durationTicks: 120_000)], overlays: []
        )
        let index = try TimelineIndex(manifest: manifest)
        // Window is [180000, 300000). Inside → both scenes required.
        let result = try index.lookup(at: try ProjectTime(ticks: 240_000))
        XCTAssertEqual(result.requiredSceneIDs.map(\.raw), ["a", "b"])
        XCTAssertNotNil(result.transition)
        // Outside the window (e.g. tick 0) → just scene a.
        XCTAssertEqual(try index.lookup(at: try ProjectTime(ticks: 0)).requiredSceneIDs.map(\.raw), ["a"])
    }

    func testRequirementsReturnsExactPayloadIDs() throws {
        let index = try TimelineIndex(manifest: try threeSceneManifest())
        let coverage = try ProjectTimeRange(start: try ProjectTime(ticks: 0), end: try ProjectTime(ticks: 1))
        let req = try index.requirements(for: coverage)
        XCTAssertEqual(req.sceneSpans.map(\.payloadID.raw), ["p0"])
        XCTAssertEqual(req.transitions.count, 0)
    }

    func testRequirementsRejectsCoverageOutsideProject() throws {
        let index = try TimelineIndex(manifest: try threeSceneManifest())
        let coverage = try ProjectTimeRange(start: try ProjectTime(ticks: 700_000), end: try ProjectTime(ticks: 800_000))
        XCTAssertThrowsError(try index.requirements(for: coverage)) {
            XCTAssertEqual($0 as? ProjectValidationError, .invalidEvaluationWindowCoverage)
        }
    }

    func testPrefixSumOverflowChecked() throws {
        let scenes = [
            SceneManifestEntry(id: try SceneInstanceID("a"), payloadID: try ScenePayloadID("pa"), nominalDuration: try TickDuration(ticks: Int64.max), postRollCapability: .zero),
            SceneManifestEntry(id: try SceneInstanceID("b"), payloadID: try ScenePayloadID("pb"), nominalDuration: try TickDuration(ticks: 1), postRollCapability: .zero)
        ]
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: scenes, boundaryTransitions: [try CanonicalProjectFixtures.cutTransition()], overlays: []
        )
        XCTAssertThrowsError(try TimelineIndex(manifest: manifest)) {
            XCTAssertTrue($0 is TimeError)
        }
    }

    // MARK: - C-2 / C-5

    func testRequirementsDoesNotScanAllScenesForNarrowCoverage() throws {
        // 4096 cut-joined scenes; coverage spanning ~2 scenes must yield a tiny sceneSpans set and the
        // scene lookups must be O(log n) (asserted via the SceneSpanIndex diagnostic counter).
        let n = 4096
        let scenes = (0..<n).map { i in
            SceneManifestEntry(id: try! SceneInstanceID("s\(i)"), payloadID: try! ScenePayloadID("p\(i)"),
                               nominalDuration: try! TickDuration(ticks: 240_000), postRollCapability: .zero)
        }
        let transitions = (0..<(n - 1)).map { _ in try! CanonicalProjectFixtures.cutTransition() }
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: scenes, boundaryTransitions: transitions, overlays: []
        )
        let index = try TimelineIndex(manifest: manifest)
        // Coverage inside scene 10 only.
        let coverage = try ProjectTimeRange(start: try ProjectTime(ticks: 2_400_000), end: try ProjectTime(ticks: 2_640_000))
        let req = try index.requirements(for: coverage)
        XCTAssertLessThanOrEqual(req.sceneSpans.count, 4)        // a couple of scenes, not 4096
        // The underlying scene lookup is logarithmic.
        let diag = index.sceneIndex.sceneIndexWithDiagnostics(containing: 2_400_000).diagnostics
        XCTAssertLessThanOrEqual(diag.comparisons, 4 * Int(ceil(log2(Double(n)))))
    }

    func testIndexRejectsInvalidManifest() throws {
        // Duplicate scene ids ⇒ TimelineIndex.init rejects via validateManifest (C-5).
        let dup = SceneManifestEntry(id: try SceneInstanceID("a"), payloadID: try ScenePayloadID("pa"), nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)
        let dup2 = SceneManifestEntry(id: try SceneInstanceID("a"), payloadID: try ScenePayloadID("pb"), nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [dup, dup2], boundaryTransitions: [try CanonicalProjectFixtures.cutTransition()], overlays: []
        )
        XCTAssertThrowsError(try TimelineIndex(manifest: manifest)) {
            XCTAssertEqual($0 as? ProjectValidationError, .duplicateStructuralID(scope: "scene.id", id: "a"))
        }
    }
}
