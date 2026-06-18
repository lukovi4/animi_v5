import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Shared helper to build an evaluation window covering the whole project and evaluate a frame.
enum EvaluationHarness {

    /// Builds a window over `[0, projectDuration)` for the given document.
    static func wholeProjectWindow(_ document: CanonicalProjectDocument) throws -> EvaluationWindow {
        let index = try TimelineIndex(manifest: document.manifest)
        let projectDuration = try document.manifest.projectDuration()
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: projectDuration.ticks))
        let requirement = try index.requirements(for: coverage)
        return try EvaluationWindowBuilder.build(
            requirement: requirement,
            scenes: document.scenePayloads,
            overlays: document.overlayPayloads
        )
    }

    static func evaluate(_ document: CanonicalProjectDocument, atTick tick: Int64) throws -> FramePlan {
        let window = try wholeProjectWindow(document)
        return try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: tick))
    }
}
