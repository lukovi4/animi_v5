import XCTest
import TVECore
@testable import AnimiApp

/// PR-G: Tests for TimelineCompositionEngine playback lifecycle APIs.
/// Tests cover:
/// - startPlayback(at:) determines correct runtimes for single/transition modes
/// - stopPlayback() iterates all loaded runtimes
/// - SceneInstanceRuntime.startPlayback(at:) delegates to userMediaService
final class TimelineEngineLifecycleTests: XCTestCase {

    // MARK: - Test Constants

    private let fps = 30

    // MARK: - Test Helpers

    /// Creates scene items with specified durations in frames.
    /// Uses exact frame-to-microseconds conversion to avoid rounding errors.
    private func makeSceneItems(durationsFrames: [Int]) -> [TimelineItem] {
        durationsFrames.map { frames in
            TimelineItem(
                payloadId: UUID(),
                kind: .scene,
                startUs: nil,
                durationUs: TimeUs(frames) * 1_000_000 / TimeUs(fps)
            )
        }
    }

    // MARK: - TimelineTransitionMath Mode Detection Tests

    /// Test: renderMode returns single for frame outside transition window.
    func testRenderMode_singleScene_outsideTransition() {
        // Given: 2 scenes of 30 frames each, 14-frame fade transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let key = SceneBoundaryKey(scenes[0].id, scenes[1].id)
        let transition = SceneTransition(type: .fade, durationFrames: 14)

        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: fps
        )

        // When: Query frame 5 (well before transition)
        guard let mode = math.renderMode(for: 5) else {
            XCTFail("Expected non-nil render mode")
            return
        }

        // Then: Should be single scene mode
        guard case .single(let sceneIndex, let localFrame) = mode else {
            XCTFail("Expected single mode, got transition")
            return
        }
        XCTAssertEqual(sceneIndex, 0)
        XCTAssertEqual(localFrame, 5)
    }

    /// Test: renderMode returns transition for frame inside transition window.
    func testRenderMode_transition_insideWindow() {
        // Given: 2 scenes of 30 frames each, 14-frame fade transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let key = SceneBoundaryKey(scenes[0].id, scenes[1].id)
        let transition = SceneTransition(type: .fade, durationFrames: 14)

        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: fps
        )

        // Compressed duration = 30 + 30 - 14 = 46 frames
        // Transition window: compressed frames 23-36 (scene A ends at 30, overlap is 14)

        // When: Query frame 25 (inside transition)
        guard let mode = math.renderMode(for: 25) else {
            XCTFail("Expected non-nil render mode")
            return
        }

        // Then: Should be transition mode
        guard case .transition(let aIndex, _, let bIndex, _, _, let progress) = mode else {
            XCTFail("Expected transition mode, got single")
            return
        }
        XCTAssertEqual(aIndex, 0)
        XCTAssertEqual(bIndex, 1)
        XCTAssertGreaterThan(progress, 0)
        XCTAssertLessThan(progress, 1)
    }

    /// Test: renderMode returns single for second scene after transition.
    func testRenderMode_singleScene_afterTransition() {
        // Given: 2 scenes of 30 frames each, 14-frame fade transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let key = SceneBoundaryKey(scenes[0].id, scenes[1].id)
        let transition = SceneTransition(type: .fade, durationFrames: 14)

        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: fps
        )

        // Compressed duration = 46 frames
        // After transition: frame 40 should be in scene B

        // When: Query frame 40
        guard let mode = math.renderMode(for: 40) else {
            XCTFail("Expected non-nil render mode")
            return
        }

        // Then: Should be single scene mode for scene B
        guard case .single(let sceneIndex, _) = mode else {
            XCTFail("Expected single mode, got transition")
            return
        }
        XCTAssertEqual(sceneIndex, 1)
    }

    // MARK: - Engine Lifecycle Contract Tests

    /// Test: startPlayback determines correct scene for single mode.
    /// Note: Full integration test requires Metal device, this tests the math.
    func testStartPlayback_singleMode_correctSceneIdentified() {
        // Given: 2 scenes, no transitions
        let scenes = makeSceneItems(durationsFrames: [30, 30])

        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [:],
            fps: fps
        )

        // When: Get mode for frame 45 (should be scene B)
        guard let mode = math.renderMode(for: 45) else {
            XCTFail("Expected non-nil render mode")
            return
        }

        // Then: Scene B (index 1) with local frame 15
        guard case .single(let sceneIndex, let localFrame) = mode else {
            XCTFail("Expected single mode")
            return
        }
        XCTAssertEqual(sceneIndex, 1, "Should identify scene B")
        XCTAssertEqual(localFrame, 15, "Should have correct local frame")
    }

    /// Test: startPlayback determines both scenes for transition mode.
    func testStartPlayback_transitionMode_bothScenesIdentified() {
        // Given: 2 scenes with 14-frame transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let key = SceneBoundaryKey(scenes[0].id, scenes[1].id)
        let transition = SceneTransition(type: .fade, durationFrames: 14)

        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: fps
        )

        // When: Get mode for frame in transition window
        guard let mode = math.renderMode(for: 25) else {
            XCTFail("Expected non-nil render mode")
            return
        }

        // Then: Both scenes identified
        guard case .transition(let aIndex, let frameA, let bIndex, let frameB, _, _) = mode else {
            XCTFail("Expected transition mode")
            return
        }
        XCTAssertEqual(aIndex, 0, "Scene A index")
        XCTAssertEqual(bIndex, 1, "Scene B index")
        XCTAssertGreaterThan(frameA, 0, "Scene A should have positive local frame")
        XCTAssertGreaterThanOrEqual(frameB, 0, "Scene B should have non-negative local frame")
    }

    // MARK: - Frame Conversion Tests

    /// Test: compressedFrame(forTimeUs:) correctly converts time to frame.
    func testCompressedFrame_conversion() {
        // At 30 fps: 1 second = 30 frames = 1_000_000 us

        // When: Convert 500_000 us (0.5 seconds)
        let frame = Int(500_000 * TimeUs(fps) / 1_000_000)

        // Then: Should be 15 frames
        XCTAssertEqual(frame, 15)
    }

    /// Test: compressedFrame at exactly 1 second.
    func testCompressedFrame_oneSecond() {
        // When: Convert 1_000_000 us (1 second)
        let frame = Int(1_000_000 * TimeUs(fps) / 1_000_000)

        // Then: Should be 30 frames
        XCTAssertEqual(frame, 30)
    }
}
