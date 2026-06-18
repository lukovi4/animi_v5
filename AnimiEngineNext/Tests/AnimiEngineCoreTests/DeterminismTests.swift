import XCTest
import Foundation
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Determinism tests: repeated evaluation and encoding produce identical results (Task-002 plan, §18).
final class DeterminismTests: XCTestCase {

    private func document() throws -> CanonicalProjectDocument {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 5, sceneID: "A", payloadID: "pA", durationTicks: 2_000_000)
        let b = try CanonicalProjectFixtures.scene(withVideoLayers: 5, sceneID: "B", payloadID: "pB", durationTicks: 2_000_000)
        let overlays = try CanonicalProjectFixtures.textOverlays(count: 4, projectDurationTicks: 1_440_000)
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [
                SceneManifestEntry(id: a.sceneID, payloadID: a.payloadID, nominalDuration: try TickDuration(ticks: 720_000), postRollCapability: try TickDuration(ticks: 120_000)),
                SceneManifestEntry(id: b.sceneID, payloadID: b.payloadID, nominalDuration: try TickDuration(ticks: 720_000), postRollCapability: .zero)
            ],
            boundaryTransitions: [try CanonicalProjectFixtures.fadeTransition(durationTicks: 240_000)],
            overlays: overlays.map(\.0)
        )
        return CanonicalProjectDocument(manifest: manifest, scenePayloads: [a, b], overlayPayloads: overlays.map(\.1))
    }

    func testRepeatedEvaluationIsValueEqual() throws {
        let doc = try document()
        let window = try EvaluationHarness.wholeProjectWindow(doc)
        for tick in [0, 360_000, 720_000, 728_000, 1_000_000] {
            let p1 = try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: Int64(tick)))
            let p2 = try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: Int64(tick)))
            XCTAssertEqual(p1, p2, "tick \(tick)")
        }
    }

    func testEncodingIsDeterministicAcrossRuns() throws {
        let doc = try document()
        let b1 = try CanonicalProjectEncoding.encode(doc)
        let b2 = try CanonicalProjectEncoding.encode(doc)
        XCTAssertEqual(b1, b2)
    }

    func testEvaluateAtFrameMatchesEvaluateAtTime() throws {
        let doc = try document()
        let window = try EvaluationHarness.wholeProjectWindow(doc)
        // 30 fps → frame 90 = tick 720000.
        let byFrame = try TimelineEvaluator.evaluate(window, atFrame: try FrameIndex(value: 90))
        let byTime = try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: 720_000))
        XCTAssertEqual(byFrame, byTime)
    }

    func testEvaluateOutsideCoverageRejected() throws {
        let doc = try document()
        // Build a window covering only [0, 100000) and evaluate outside it.
        let index = try TimelineIndex(manifest: doc.manifest)
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 100_000))
        let req = try index.requirements(for: coverage)
        let window = try EvaluationWindowBuilder.build(
            requirement: req,
            scenes: doc.scenePayloads.filter { req.sceneSpans.map(\.payloadID).contains($0.payloadID) },
            overlays: doc.overlayPayloads.filter { req.overlayEntries.map(\.payloadID).contains($0.payloadID) }
        )
        XCTAssertThrowsError(try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: 500_000))) {
            XCTAssertEqual($0 as? ProjectValidationError, .invalidEvaluationWindowCoverage)
        }
    }
}
