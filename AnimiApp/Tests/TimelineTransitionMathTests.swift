import XCTest
@testable import AnimiApp

/// Pure math tests for TimelineTransitionMath.
/// These tests do NOT require Metal device.
/// They validate all timing logic for multi-scene timeline with transitions.
final class TimelineTransitionMathTests: XCTestCase {

    // MARK: - Test Helpers

    /// Creates scene items with specified durations in microseconds.
    private func makeSceneItems(durationsUs: [TimeUs]) -> [TimelineItem] {
        durationsUs.enumerated().map { index, durationUs in
            TimelineItem(
                id: UUID(),
                payloadId: UUID(),
                kind: .scene,
                startUs: nil,
                durationUs: durationUs
            )
        }
    }

    /// Creates scene items with specified durations in frames at 30fps.
    private func makeSceneItems(durationsFrames: [Int]) -> [TimelineItem] {
        makeSceneItems(durationsUs: durationsFrames.map { TimeUs($0) * 1_000_000 / 30 })
    }

    /// Creates a boundary transition between two scenes.
    private func makeTransition(
        from fromId: UUID,
        to toId: UUID,
        type: TransitionType = .fade,
        durationFrames: Int = 14
    ) -> (SceneBoundaryKey, SceneTransition) {
        let key = SceneBoundaryKey(fromId, toId)
        let transition = SceneTransition(type: type, durationFrames: durationFrames)
        return (key, transition)
    }

    // MARK: - Compressed Duration Tests

    func testCompressedDuration_noTransitions() {
        // Given: 3 scenes of 30 frames each, no transitions
        let scenes = makeSceneItems(durationsFrames: [30, 30, 30])

        // When
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [:],
            fps: 30
        )

        // Then: Total = 30 + 30 + 30 = 90 frames
        XCTAssertEqual(math.compressedDurationFrames, 90)
    }

    func testCompressedDuration_oneTransition() {
        // Given: 2 scenes of 30 frames each, one 14-frame transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let (key, transition) = makeTransition(from: scenes[0].id, to: scenes[1].id)

        // When
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )

        // Then: Total = 30 + 30 - 7 = 53 frames (7 = 14/2 compression)
        XCTAssertEqual(math.compressedDurationFrames, 53)
    }

    func testCompressedDuration_multipleTransitions() {
        // Given: 3 scenes of 30 frames each, two 14-frame transitions
        let scenes = makeSceneItems(durationsFrames: [30, 30, 30])
        let (key1, trans1) = makeTransition(from: scenes[0].id, to: scenes[1].id)
        let (key2, trans2) = makeTransition(from: scenes[1].id, to: scenes[2].id)

        // When
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key1: trans1, key2: trans2],
            fps: 30
        )

        // Then: Total = 90 - 7 - 7 = 76 frames
        XCTAssertEqual(math.compressedDurationFrames, 76)
    }

    // MARK: - Compressed Start Frame Tests

    func testCompressedStartFrame_firstScene() {
        // Given: Any configuration
        let scenes = makeSceneItems(durationsFrames: [30, 30])

        // When
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [:],
            fps: 30
        )

        // Then: First scene always starts at frame 0
        XCTAssertEqual(math.compressedStartFrame(forSceneAt: 0), 0)
    }

    func testCompressedStartFrame_secondScene_noTransition() {
        // Given: 2 scenes of 30 frames, no transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])

        // When
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [:],
            fps: 30
        )

        // Then: Scene B starts at frame 30
        XCTAssertEqual(math.compressedStartFrame(forSceneAt: 1), 30)
    }

    func testCompressedStartFrame_secondScene_withTransition() {
        // Given: 2 scenes of 30 frames, 14-frame transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let (key, transition) = makeTransition(from: scenes[0].id, to: scenes[1].id)

        // When
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )

        // Then: Scene B starts at frame 23 (30 - 7)
        XCTAssertEqual(math.compressedStartFrame(forSceneAt: 1), 23)
    }

    func testCompressedStartFrame_withMultipleTransitions() {
        // Given: 3 scenes of 30 frames each, two 14-frame transitions
        let scenes = makeSceneItems(durationsFrames: [30, 30, 30])
        let (key1, trans1) = makeTransition(from: scenes[0].id, to: scenes[1].id)
        let (key2, trans2) = makeTransition(from: scenes[1].id, to: scenes[2].id)

        // When
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key1: trans1, key2: trans2],
            fps: 30
        )

        // Then:
        // Scene A starts at 0
        // Scene B starts at 23 (30 - 7)
        // Scene C starts at 46 (23 + 30 - 7)
        XCTAssertEqual(math.compressedStartFrame(forSceneAt: 0), 0)
        XCTAssertEqual(math.compressedStartFrame(forSceneAt: 1), 23)
        XCTAssertEqual(math.compressedStartFrame(forSceneAt: 2), 46)
    }

    // MARK: - Transition Window Tests

    func testTransitionWindow_beforeTransition() {
        // Given: 2 scenes with transition starting at frame 23
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let (key, transition) = makeTransition(from: scenes[0].id, to: scenes[1].id)
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )

        // When: Check frame 22 (before transition)
        let window = math.transitionWindow(at: 22)

        // Then: No transition window
        XCTAssertNil(window)
    }

    func testTransitionWindow_inTransition() {
        // Given: 2 scenes with 14-frame transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let (key, transition) = makeTransition(from: scenes[0].id, to: scenes[1].id)
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )

        // When: Check frame 25 (in transition)
        // Transition window: frames 23-36 (startFrame = 30 - 7 = 23, endFrame = 23 + 14 = 37)
        let window = math.transitionWindow(at: 25)

        // Then: Transition window found
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.fromSceneIndex, 0)
        XCTAssertEqual(window?.toSceneIndex, 1)
        XCTAssertEqual(window?.startFrame, 23)
        XCTAssertEqual(window?.endFrame, 37)
    }

    func testTransitionWindow_afterTransition() {
        // Given: 2 scenes with transition ending at frame 37
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let (key, transition) = makeTransition(from: scenes[0].id, to: scenes[1].id)
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )

        // When: Check frame 40 (after transition)
        let window = math.transitionWindow(at: 40)

        // Then: No transition window
        XCTAssertNil(window)
    }

    // MARK: - Render Mode Tests

    func testRenderMode_singleScene() {
        // Given: Single scene
        let scenes = makeSceneItems(durationsFrames: [30])
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [:],
            fps: 30
        )

        // When
        guard let mode = math.renderMode(for: 15) else {
            XCTFail("Expected non-nil render mode")
            return
        }

        // Then: Single scene rendering
        if case .single(let sceneIndex, let localFrame) = mode {
            XCTAssertEqual(sceneIndex, 0)
            XCTAssertEqual(localFrame, 15)
        } else {
            XCTFail("Expected single scene mode")
        }
    }

    func testRenderMode_transitionMidpoint() {
        // Given: 2 scenes with 14-frame transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let (key, transition) = makeTransition(from: scenes[0].id, to: scenes[1].id)
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )

        // When: Check midpoint of transition (frame 30 = 23 + 7)
        guard let mode = math.renderMode(for: 30) else {
            XCTFail("Expected non-nil render mode")
            return
        }

        // Then: Transition rendering at 50% progress
        if case .transition(let aIdx, let frameA, let bIdx, let frameB, _, let progress) = mode {
            XCTAssertEqual(aIdx, 0)
            XCTAssertEqual(bIdx, 1)
            XCTAssertEqual(frameA, 29) // Scene A at last frame before hold
            XCTAssertEqual(frameB, 7)  // Scene B at frame 7 (30 - 23 = 7)
            XCTAssertEqual(progress, 0.5, accuracy: 0.01)
        } else {
            XCTFail("Expected transition mode")
        }
    }

    func testRenderMode_transitionStart() {
        // Given: 2 scenes with 14-frame transition starting at frame 23
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let (key, transition) = makeTransition(from: scenes[0].id, to: scenes[1].id)
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )

        // When: Check first frame of transition (frame 23)
        guard let mode = math.renderMode(for: 23) else {
            XCTFail("Expected non-nil render mode")
            return
        }

        // Then: Transition at 0% progress
        if case .transition(_, let frameA, _, let frameB, _, let progress) = mode {
            XCTAssertEqual(frameA, 23) // Scene A at frame 23
            XCTAssertEqual(frameB, 0)  // Scene B at frame 0
            XCTAssertEqual(progress, 0.0, accuracy: 0.01)
        } else {
            XCTFail("Expected transition mode")
        }
    }

    func testRenderMode_transitionEnd() {
        // Given: 2 scenes with 14-frame transition ending at frame 36
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let (key, transition) = makeTransition(from: scenes[0].id, to: scenes[1].id)
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )

        // When: Check last frame of transition (frame 36)
        guard let mode = math.renderMode(for: 36) else {
            XCTFail("Expected non-nil render mode")
            return
        }

        // Then: Transition near 100% progress
        if case .transition(_, let frameA, _, let frameB, _, let progress) = mode {
            XCTAssertEqual(frameA, 29) // Scene A holds last frame
            XCTAssertEqual(frameB, 13) // Scene B at frame 13
            XCTAssertGreaterThan(progress, 0.9)
        } else {
            XCTFail("Expected transition mode")
        }
    }

    // MARK: - Audio Mapping Tests

    func testAudioMapping_noTransitions() {
        // Given: 2 scenes, no transitions
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [:],
            fps: 30
        )

        // When: Map frame 15 in scene 0
        let compressed = math.compressedFrame(forUncompressedFrame: 15, inSceneAt: 0)

        // Then: Same as uncompressed (no compression)
        XCTAssertEqual(compressed, 15)

        // When: Map frame 10 in scene 1
        let compressed2 = math.compressedFrame(forUncompressedFrame: 10, inSceneAt: 1)

        // Then: Scene 1 starts at 30, so frame 10 = 30 + 10 = 40
        XCTAssertEqual(compressed2, 40)
    }

    func testAudioMapping_withTransitions() {
        // Given: 2 scenes with 14-frame transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let (key, transition) = makeTransition(from: scenes[0].id, to: scenes[1].id)
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )

        // When: Map frame 15 in scene 0
        let compressed = math.compressedFrame(forUncompressedFrame: 15, inSceneAt: 0)

        // Then: Scene 0 not affected by transition (starts at 0)
        XCTAssertEqual(compressed, 15)

        // When: Map frame 10 in scene 1
        let compressed2 = math.compressedFrame(forUncompressedFrame: 10, inSceneAt: 1)

        // Then: Scene 1 starts at 23 (compressed), so frame 10 = 23 + 10 = 33
        XCTAssertEqual(compressed2, 33)
    }

    // MARK: - Edge Case Tests

    func testEmptyTimeline() {
        // Given: No scenes
        let math = TimelineTransitionMath(
            sceneItems: [],
            boundaryTransitions: [:],
            fps: 30
        )

        // Then: Computed values are zero/empty
        XCTAssertEqual(math.compressedDurationFrames, 0)
        XCTAssertEqual(math.allTransitionWindows.count, 0)

        // Then: Optional APIs return nil for empty timeline
        XCTAssertNil(math.frameMapping(for: 0), "frameMapping should return nil for empty timeline")
        XCTAssertNil(math.renderMode(for: 0), "renderMode should return nil for empty timeline")
    }

    func testSingleScene() {
        // Given: Single scene
        let scenes = makeSceneItems(durationsFrames: [30])
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [:],
            fps: 30
        )

        // Then
        XCTAssertEqual(math.compressedDurationFrames, 30)
        XCTAssertEqual(math.compressedStartFrame(forSceneAt: 0), 0)
        XCTAssertNil(math.transitionWindow(at: 15))
    }

    func testTransitionTypeNone_noCompression() {
        // Given: 2 scenes with .none transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let key = SceneBoundaryKey(scenes[0].id, scenes[1].id)
        let transition = SceneTransition(type: .none, durationFrames: 14)

        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )

        // Then: No compression for .none transitions
        XCTAssertEqual(math.compressedDurationFrames, 60)
        XCTAssertEqual(math.compressedStartFrame(forSceneAt: 1), 30)
    }
}
