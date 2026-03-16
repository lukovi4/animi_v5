import XCTest
@testable import AnimiApp

/// Unit tests for TimelinePlayheadMapper.
/// Tests zone-table model for bidirectional frame mapping.
/// These tests do NOT require Metal device.
final class TimelinePlayheadMapperTests: XCTestCase {

    // MARK: - Test Helpers

    /// Creates scene items with specified durations in frames at 30fps.
    private func makeSceneItems(durationsFrames: [Int]) -> [TimelineItem] {
        durationsFrames.enumerated().map { index, duration in
            TimelineItem(
                id: UUID(),
                payloadId: UUID(),
                kind: .scene,
                startUs: nil,
                durationUs: TimeUs(duration) * 1_000_000 / 30
            )
        }
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

    /// Creates a mapper with given scenes and transitions.
    private func makeMapper(
        durationsFrames: [Int],
        transitions: [(Int, Int, Int)] = [] // (fromIndex, toIndex, durationFrames)
    ) -> TimelinePlayheadMapper {
        let scenes = makeSceneItems(durationsFrames: durationsFrames)
        var boundaryTransitions: [SceneBoundaryKey: SceneTransition] = [:]

        for (fromIdx, toIdx, duration) in transitions {
            let (key, transition) = makeTransition(
                from: scenes[fromIdx].id,
                to: scenes[toIdx].id,
                durationFrames: duration
            )
            boundaryTransitions[key] = transition
        }

        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: boundaryTransitions,
            fps: 30
        )

        return TimelinePlayheadMapper(math: math)
    }

    // MARK: - Empty Timeline Tests

    func testEmptyTimeline() {
        // Given: No scenes
        let mapper = makeMapper(durationsFrames: [])

        // Then: Durations are zero
        XCTAssertEqual(mapper.compressedDurationFrames, 0)
        XCTAssertEqual(mapper.nominalDurationFrames, 0)
    }

    // MARK: - Single Scene Tests

    func testSingleScene_identityMapping() {
        // Given: Single scene of 30 frames
        let mapper = makeMapper(durationsFrames: [30])

        // Then: 1:1 mapping everywhere
        XCTAssertEqual(mapper.compressedDurationFrames, 30)
        XCTAssertEqual(mapper.nominalDurationFrames, 30)

        // Test frame mapping
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 0, quantize: .ended), 0)
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 15, quantize: .ended), 15)
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 29, quantize: .ended), 29)

        // Test inverse mapping
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 0), 0)
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 15), 15)
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 29), 29)
    }

    // MARK: - Two Scenes with Transition Tests

    func testTwoScenes_14fTransition_durations() {
        // Given: A=30f, B=30f, transition=14f
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // Then: compressed = 60 - 7 = 53
        XCTAssertEqual(mapper.compressedDurationFrames, 53)
        XCTAssertEqual(mapper.nominalDurationFrames, 60)
    }

    func testTwoScenes_boundaryNominalEqualsCompressed() {
        // Given: A=30f, B=30f, transition=14f
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // Key invariant: boundary nominal = boundary compressed
        // nominal 30 (start of B) = compressed 30
        // Transition window is compressed frames 23-36

        // Scene A body (before outgoing transition): 1:1 mapping
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 0, quantize: .ended), 0)
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 22, quantize: .ended), 22)

        // Scene A outgoing transition (frames 23-29): 1:1 mapping
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 23, quantize: .ended), 23)
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 29, quantize: .ended), 29)

        // Boundary: nominal 30 = compressed 30
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 30, quantize: .ended), 30)

        // Scene B incoming transition (frames 30-36): 1:1 mapping
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 36, quantize: .ended), 36)

        // Scene B body: scaled mapping (nominal 37-59 → compressed 37-52)
        // 23 nominal frames → 16 compressed frames
        // End: nominal 59 → compressed 52
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 59, quantize: .ended), 52)
    }

    func testTwoScenes_inverseMapping() {
        // Given: A=30f, B=30f, transition=14f
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // Boundary inverse: compressed 30 → nominal 30
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 30), 30)

        // End inverse: compressed 52 → nominal 59
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 52), 59)

        // Identity zones inverse
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 0), 0)
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 22), 22)
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 23), 23)
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 29), 29)
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 36), 36)
    }

    // MARK: - Three Scenes with Two Transitions Tests

    func testThreeScenes_twoTransitions_durations() {
        // Given: A=30f, B=30f, C=30f, transitions=14f each
        let mapper = makeMapper(
            durationsFrames: [30, 30, 30],
            transitions: [(0, 1, 14), (1, 2, 14)]
        )

        // Then: compressed = 90 - 7 - 7 = 76
        XCTAssertEqual(mapper.compressedDurationFrames, 76)
        XCTAssertEqual(mapper.nominalDurationFrames, 90)
    }

    func testThreeScenes_boundaryPreservation() {
        // Given: A=30f, B=30f, C=30f, transitions=14f each
        let mapper = makeMapper(
            durationsFrames: [30, 30, 30],
            transitions: [(0, 1, 14), (1, 2, 14)]
        )

        // Boundary A→B: nominal 30 = compressed 30
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 30, quantize: .ended), 30)

        // Boundary B→C: nominal 60 = compressed 53
        // B has 30 nominal frames but is compressed by 7 (from incoming)
        // B compressed start = 30, B compressed end = 30 + 30 - 7 = 53
        // So nominal 60 (start of C) = compressed 53
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 60, quantize: .ended), 53)

        // End frame: nominal 89 → compressed 75
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 89, quantize: .ended), 75)
    }

    // MARK: - Monotonicity Tests

    func testInverseMapping_monotonicity() {
        // Given: A=30f, B=30f, transition=14f
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // Verify monotonicity: compressed frame + 1 should never decrease nominal frame
        var lastNominal = mapper.nominalFrame(forCompressedFrame: 0)
        for compressed in 1..<mapper.compressedDurationFrames {
            let nominal = mapper.nominalFrame(forCompressedFrame: compressed)
            XCTAssertGreaterThanOrEqual(
                nominal, lastNominal,
                "Non-monotonic at compressed \(compressed): \(nominal) < \(lastNominal)"
            )
            lastNominal = nominal
        }
    }

    func testForwardMapping_monotonicity() {
        // Given: A=30f, B=30f, transition=14f
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // Verify monotonicity: nominal frame + 1 should never decrease compressed frame
        var lastCompressed = mapper.compressedFrame(forNominalFrame: 0, quantize: .ended)
        for nominal in 1..<mapper.nominalDurationFrames {
            let compressed = mapper.compressedFrame(forNominalFrame: nominal, quantize: .ended)
            XCTAssertGreaterThanOrEqual(
                compressed, lastCompressed,
                "Non-monotonic at nominal \(nominal): \(compressed) < \(lastCompressed)"
            )
            lastCompressed = compressed
        }
    }

    // MARK: - QuantizeMode Tests

    func testQuantizeMode_draggingVsEnded() {
        // Given: A=30f, B=30f, transition=14f, fps=30
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let (key, transition) = makeTransition(from: scenes[0].id, to: scenes[1].id, durationFrames: 14)
        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )
        let mapper = TimelinePlayheadMapper(math: math)

        // Frame 10 at 30fps = 333_333 us (exactly)
        let timeUs: TimeUs = 333_333

        // dragging: floor behavior
        let draggingFrame = mapper.compressedFrame(forTimeUs: timeUs, quantize: .dragging)

        // ended: round behavior
        let endedFrame = mapper.compressedFrame(forTimeUs: timeUs, quantize: .ended)

        // Both should give valid compressed frame within range
        XCTAssertGreaterThanOrEqual(draggingFrame, 0)
        XCTAssertLessThan(draggingFrame, mapper.compressedDurationFrames)
        XCTAssertGreaterThanOrEqual(endedFrame, 0)
        XCTAssertLessThan(endedFrame, mapper.compressedDurationFrames)
    }

    func testQuantizeMode_playback() {
        // Given: Single scene 30f at 30fps
        let mapper = makeMapper(durationsFrames: [30])

        // Half-frame time: 0.5 / 30 * 1_000_000 = 16667 us
        let halfFrameUs: TimeUs = 16_667

        // playback uses floor (like dragging)
        let playbackFrame = mapper.compressedFrame(forTimeUs: halfFrameUs, quantize: .playback)

        // Should be frame 0 (floor of 0.5)
        XCTAssertEqual(playbackFrame, 0)

        // ended would round to frame 1
        let endedFrame = mapper.compressedFrame(forTimeUs: halfFrameUs, quantize: .ended)
        XCTAssertEqual(endedFrame, 1)
    }

    // MARK: - TimeUs Mapping Tests

    func testTimeUsMapping_nominalTime() {
        // Given: A=30f at 30fps (1 second)
        let mapper = makeMapper(durationsFrames: [30])

        // Frame 15 = 0.5 seconds = 500_000 us
        let expectedTimeUs: TimeUs = 500_000

        // Compressed frame 15 → nominal time 500_000
        let timeUs = mapper.nominalTimeUs(forCompressedFrame: 15)
        XCTAssertEqual(timeUs, expectedTimeUs)
    }

    func testTimeUsMapping_withCompression() {
        // Given: A=30f, B=30f, transition=14f
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // Compressed frame 52 (last frame) → nominal frame 59
        // Nominal frame 59 at 30fps = 59 * 1_000_000 / 30 = 1_966_666 us
        let timeUs = mapper.nominalTimeUs(forCompressedFrame: 52)
        let expectedTimeUs: TimeUs = 59 * 1_000_000 / 30
        XCTAssertEqual(timeUs, expectedTimeUs)
    }

    // MARK: - UI Offset Mapping Tests

    func testOffsetXMapping_toCompressedFrame() {
        // Given: 30f scene at 30fps, 100 px/sec zoom
        let mapper = makeMapper(durationsFrames: [30])
        let pxPerSecond: CGFloat = 100.0

        // 0.5 seconds = 50px offset
        let offsetX: CGFloat = 50.0

        // Should map to frame 15 (0.5 * 30fps)
        let frame = mapper.compressedFrame(forOffsetX: offsetX, pxPerSecond: pxPerSecond, quantize: .ended)
        XCTAssertEqual(frame, 15)
    }

    func testOffsetXMapping_fromCompressedFrame() {
        // Given: 30f scene at 30fps, 100 px/sec zoom
        let mapper = makeMapper(durationsFrames: [30])
        let pxPerSecond: CGFloat = 100.0

        // Frame 15 = 0.5 seconds = 50px offset
        let offsetX = mapper.offsetX(forCompressedFrame: 15, pxPerSecond: pxPerSecond)
        XCTAssertEqual(offsetX, 50.0, accuracy: 0.01)
    }

    func testOffsetXMapping_withCompression() {
        // Given: A=30f, B=30f, transition=14f, 100 px/sec
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )
        let pxPerSecond: CGFloat = 100.0

        // Compressed frame 52 → nominal frame 59
        // Nominal frame 59 at 30fps = 59/30 = 1.9667 seconds
        // At 100 px/sec = 196.67px
        let offsetX = mapper.offsetX(forCompressedFrame: 52, pxPerSecond: pxPerSecond)
        let expectedOffset = CGFloat(59) / 30.0 * 100.0
        XCTAssertEqual(offsetX, expectedOffset, accuracy: 0.1)
    }

    // MARK: - Edge Case Tests

    func testClamping_nominalFrameOutOfRange() {
        // Given: 30f scene
        let mapper = makeMapper(durationsFrames: [30])

        // Negative frame clamps to 0
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: -10, quantize: .ended), 0)

        // Frame beyond end clamps to last
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 100, quantize: .ended), 29)
    }

    func testClamping_compressedFrameOutOfRange() {
        // Given: 30f scene
        let mapper = makeMapper(durationsFrames: [30])

        // Negative frame clamps to 0
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: -10), 0)

        // Frame beyond end clamps to last
        XCTAssertEqual(mapper.nominalFrame(forCompressedFrame: 100), 29)
    }

    func testTransitionTypeNone_noCompression() {
        // Given: A=30f, B=30f with .none transition
        let scenes = makeSceneItems(durationsFrames: [30, 30])
        let key = SceneBoundaryKey(scenes[0].id, scenes[1].id)
        let transition = SceneTransition(type: .none, durationFrames: 14)

        let math = TimelineTransitionMath(
            sceneItems: scenes,
            boundaryTransitions: [key: transition],
            fps: 30
        )
        let mapper = TimelinePlayheadMapper(math: math)

        // Then: 1:1 mapping (no compression for .none)
        XCTAssertEqual(mapper.compressedDurationFrames, 60)
        XCTAssertEqual(mapper.nominalDurationFrames, 60)
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 30, quantize: .ended), 30)
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 59, quantize: .ended), 59)
    }

    // MARK: - Exact Values from Plan

    /// Test exact values from the plan:
    /// - boundary `30 nominal → 30 compressed`
    /// - end `59 nominal → 52 compressed`
    func testExactValuesFromPlan() {
        // Given: A=30f, B=30f, transition=14f (from plan)
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // Exact: boundary 30 nominal → 30 compressed
        XCTAssertEqual(
            mapper.compressedFrame(forNominalFrame: 30, quantize: .ended),
            30,
            "Boundary nominal 30 should map to compressed 30"
        )

        // Exact: end 59 nominal → 52 compressed
        XCTAssertEqual(
            mapper.compressedFrame(forNominalFrame: 59, quantize: .ended),
            52,
            "End nominal 59 should map to compressed 52"
        )

        // Verify inverse
        XCTAssertEqual(
            mapper.nominalFrame(forCompressedFrame: 30),
            30,
            "Boundary compressed 30 should map to nominal 30"
        )

        XCTAssertEqual(
            mapper.nominalFrame(forCompressedFrame: 52),
            59,
            "End compressed 52 should map to nominal 59"
        )
    }

    // MARK: - sceneBoundaryCompressedFrame Tests

    func testSceneBoundaryCompressedFrame_singleScene() {
        // Given: Single scene of 30 frames
        let mapper = makeMapper(durationsFrames: [30])

        // Then: Scene 0 boundary is frame 0
        XCTAssertEqual(mapper.sceneBoundaryCompressedFrame(forSceneAt: 0), 0)
    }

    func testSceneBoundaryCompressedFrame_twoScenes_withTransition() {
        // Given: A=30f, B=30f, transition=14f
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // Then: Scene 0 boundary is frame 0
        XCTAssertEqual(mapper.sceneBoundaryCompressedFrame(forSceneAt: 0), 0)

        // Scene 1 boundary is compressed frame 30 (boundary-preserved)
        XCTAssertEqual(mapper.sceneBoundaryCompressedFrame(forSceneAt: 1), 30)
    }

    func testSceneBoundaryCompressedFrame_threeScenes_twoTransitions() {
        // Given: A=30f, B=30f, C=30f, transitions=14f each
        let mapper = makeMapper(
            durationsFrames: [30, 30, 30],
            transitions: [(0, 1, 14), (1, 2, 14)]
        )

        // Scene 0 boundary is frame 0
        XCTAssertEqual(mapper.sceneBoundaryCompressedFrame(forSceneAt: 0), 0)

        // Scene 1 boundary is compressed frame 30
        XCTAssertEqual(mapper.sceneBoundaryCompressedFrame(forSceneAt: 1), 30)

        // Scene 2 boundary is compressed frame 53 (30 + 30 - 7 compression)
        XCTAssertEqual(mapper.sceneBoundaryCompressedFrame(forSceneAt: 2), 53)
    }

    // MARK: - Scaled Zone QuantizeMode Tests

    func testScaledZone_quantizeDraggingUsesFloor() {
        // Given: A=30f, B=30f, transition=14f
        // B body zone: nominal 37-59 → compressed 37-52 (23 nominal → 16 compressed, ratio ≈ 0.696)
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // nominal 48 in B body: offset from zone start (37) = 11
        // raw = 11 * 16/23 ≈ 7.65
        // .dragging should floor to 7 → compressed 37 + 7 = 44
        let draggingFrame = mapper.compressedFrame(forNominalFrame: 48, quantize: .dragging)
        XCTAssertEqual(draggingFrame, 44, "dragging should use floor in scaled zone")
    }

    func testScaledZone_quantizeEndedUsesRound() {
        // Given: A=30f, B=30f, transition=14f
        // B body zone: nominal 37-59 → compressed 37-52 (23 nominal → 16 compressed, ratio ≈ 0.696)
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // nominal 48 in B body: offset from zone start (37) = 11
        // raw = 11 * 16/23 ≈ 7.65
        // .ended should round to 8 → compressed 37 + 8 = 45
        let endedFrame = mapper.compressedFrame(forNominalFrame: 48, quantize: .ended)
        XCTAssertEqual(endedFrame, 45, "ended should use round in scaled zone")
    }

    func testScaledZone_quantizePlaybackUsesFloor() {
        // Given: A=30f, B=30f, transition=14f
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // nominal 48: same as dragging, should floor
        let playbackFrame = mapper.compressedFrame(forNominalFrame: 48, quantize: .playback)
        XCTAssertEqual(playbackFrame, 44, "playback should use floor in scaled zone")
    }

    // MARK: - Zone Mapping Correctness

    /// Verify zone boundaries from the plan:
    /// - nominal 0...22  → compressed 0...22   (A body, 1:1)
    /// - nominal 23...29 → compressed 23...29  (A outgoing, 1:1)
    /// - nominal 30...36 → compressed 30...36  (B incoming, 1:1)
    /// - nominal 37...59 → compressed 37...52  (B body, -7 compression)
    func testZoneMappingFromPlan() {
        // Given: A=30f, B=30f, transition=14f
        let mapper = makeMapper(
            durationsFrames: [30, 30],
            transitions: [(0, 1, 14)]
        )

        // Zone 1: A body (nominal 0-22 → compressed 0-22, 1:1)
        for nominal in 0...22 {
            XCTAssertEqual(
                mapper.compressedFrame(forNominalFrame: nominal, quantize: .ended),
                nominal,
                "A body: nominal \(nominal) should be 1:1"
            )
        }

        // Zone 2: A outgoing (nominal 23-29 → compressed 23-29, 1:1)
        for nominal in 23...29 {
            XCTAssertEqual(
                mapper.compressedFrame(forNominalFrame: nominal, quantize: .ended),
                nominal,
                "A outgoing: nominal \(nominal) should be 1:1"
            )
        }

        // Zone 3: B incoming (nominal 30-36 → compressed 30-36, 1:1)
        for nominal in 30...36 {
            XCTAssertEqual(
                mapper.compressedFrame(forNominalFrame: nominal, quantize: .ended),
                nominal,
                "B incoming: nominal \(nominal) should be 1:1"
            )
        }

        // Zone 4: B body (nominal 37-59 → compressed 37-52, scaled)
        // 23 nominal frames → 16 compressed frames (ratio = 16/23 ≈ 0.696)
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 37, quantize: .ended), 37)
        XCTAssertEqual(mapper.compressedFrame(forNominalFrame: 59, quantize: .ended), 52)

        // Intermediate values should be scaled
        let midNominal = 48 // roughly middle of 37-59
        let compressed = mapper.compressedFrame(forNominalFrame: midNominal, quantize: .ended)
        XCTAssertGreaterThan(compressed, 37)
        XCTAssertLessThan(compressed, 52)
    }
}
