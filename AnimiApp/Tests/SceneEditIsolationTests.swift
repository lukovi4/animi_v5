import XCTest
@testable import AnimiApp

/// TT-10: Tests for scene edit isolation contract.
/// Verifies that entering scene edit mode properly isolates timeline activity.
final class SceneEditIsolationTests: XCTestCase {

    // MARK: - Isolation Helper Tests

    /// Verifies cancel runs before stop — order is critical so stale timeline
    /// resolve cannot complete after playback lifecycle is stopped.
    func testIsolationHelper_cancelsPendingTimelineResolveBeforeStoppingPlayback() {
        var log: [String] = []

        EditorViewController.isolateTimelineActivityForSceneEdit(
            cancelPendingTimelineResolve: { log.append("cancel") },
            stopPlayback: { log.append("stop") }
        )

        XCTAssertEqual(log, ["cancel", "stop"])
    }

    /// Verifies stopPlayback is always called, regardless of isPlaying state.
    func testIsolationHelper_stopsPlaybackUnconditionally() {
        var stopCalled = false

        EditorViewController.isolateTimelineActivityForSceneEdit(
            cancelPendingTimelineResolve: {},
            stopPlayback: { stopCalled = true }
        )

        XCTAssertTrue(stopCalled)
    }
}
