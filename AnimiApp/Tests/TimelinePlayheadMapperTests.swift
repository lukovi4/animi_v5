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

    // MARK: - TT-01 Regression Tests

    /// TT-01: offsetX roundtrip for single scene without drift.
    /// Verifies that frame → offsetX → frame is identity.
    func test_TT01_offsetXRoundtrip_singleScene_noDrift() {
        // Given: 90-frame scene at 30fps (3 seconds)
        let mapper = makeMapper(durationsFrames: [90])
        let pxPerSecond: CGFloat = 100.0

        // When/Then: Every frame should roundtrip exactly
        for frame in 0...60 {
            let offsetX = mapper.offsetX(forCompressedFrame: frame, pxPerSecond: pxPerSecond)

            let recoveredDragging = mapper.compressedFrame(
                forOffsetX: offsetX,
                pxPerSecond: pxPerSecond,
                quantize: .dragging
            )
            let recoveredEnded = mapper.compressedFrame(
                forOffsetX: offsetX,
                pxPerSecond: pxPerSecond,
                quantize: .ended
            )

            XCTAssertEqual(recoveredDragging, frame, "Dragging roundtrip failed for frame \(frame)")
            XCTAssertEqual(recoveredEnded, frame, "Ended roundtrip failed for frame \(frame)")
        }
    }

    /// TT-01: offsetX roundtrip with transition without drift.
    /// Note: Only identity zones can have exact roundtrip. Scaled zones (B body)
    /// have ratio < 1, so multiple nominal frames map to same compressed frame.
    func test_TT01_offsetXRoundtrip_withTransition_noDrift() {
        // Given: A=30f, B=30f, transition=14f
        // Zone layout:
        //   - A body: compressed 0-22 (identity)
        //   - A outgoing: compressed 23-29 (identity)
        //   - B incoming: compressed 30-36 (identity)
        //   - B body: compressed 37-52 (SCALED - roundtrip not guaranteed)
        let mapper = makeMapper(durationsFrames: [30, 30], transitions: [(0, 1, 14)])
        let pxPerSecond: CGFloat = 100.0

        // Identity zones: frames 0-36 should roundtrip exactly
        let identityZoneFrames = Array(0...36)

        for frame in identityZoneFrames {
            let offsetX = mapper.offsetX(forCompressedFrame: frame, pxPerSecond: pxPerSecond)

            let recoveredDragging = mapper.compressedFrame(
                forOffsetX: offsetX,
                pxPerSecond: pxPerSecond,
                quantize: .dragging
            )
            let recoveredEnded = mapper.compressedFrame(
                forOffsetX: offsetX,
                pxPerSecond: pxPerSecond,
                quantize: .ended
            )

            XCTAssertEqual(recoveredDragging, frame, "Dragging roundtrip failed for frame \(frame)")
            XCTAssertEqual(recoveredEnded, frame, "Ended roundtrip failed for frame \(frame)")
        }

        // Scaled zone boundary frames should also roundtrip
        let scaledZoneBoundaries = [37, 52]  // first and last of B body
        for frame in scaledZoneBoundaries {
            let offsetX = mapper.offsetX(forCompressedFrame: frame, pxPerSecond: pxPerSecond)
            let recovered = mapper.compressedFrame(
                forOffsetX: offsetX,
                pxPerSecond: pxPerSecond,
                quantize: .ended
            )
            XCTAssertEqual(recovered, frame, "Boundary frame \(frame) roundtrip failed")
        }
    }

    /// TT-01: Verifies problematic frames that had backward drift with TimeUs roundtrip.
    func test_TT01_problematicFrames_noDrift() {
        // Given: These frames had backward drift with TimeUs roundtrip at 30fps
        let problematicFrames = [1, 2, 4, 5, 7, 8, 10, 11, 13, 14]
        let mapper = makeMapper(durationsFrames: [30])
        let pxPerSecond: CGFloat = 100.0

        for frame in problematicFrames {
            let offsetX = mapper.offsetX(forCompressedFrame: frame, pxPerSecond: pxPerSecond)
            let recovered = mapper.compressedFrame(
                forOffsetX: offsetX,
                pxPerSecond: pxPerSecond,
                quantize: .dragging
            )

            XCTAssertEqual(recovered, frame, "Frame \(frame) drifted to \(recovered)")
        }
    }

    /// TT-01: Verifies .playback and .dragging give same result for exact frame offsets.
    func test_TT01_nominalFrameHelper_playbackEqualsDragging_forExactOffsets() {
        // Given: For exact frame offsets, .playback and .dragging should give same result
        let mapper = makeMapper(durationsFrames: [60])
        let pxPerSecond: CGFloat = 100.0

        for frame in 0..<60 {
            // Get exact offset for this frame
            let exactOffsetX = mapper.offsetX(forCompressedFrame: frame, pxPerSecond: pxPerSecond)

            // Both modes should return same frame for exact offsets
            let draggingFrame = mapper.nominalFrame(
                forOffsetX: exactOffsetX,
                pxPerSecond: pxPerSecond,
                quantize: .dragging
            )
            let playbackFrame = mapper.nominalFrame(
                forOffsetX: exactOffsetX,
                pxPerSecond: pxPerSecond,
                quantize: .playback
            )

            XCTAssertEqual(draggingFrame, playbackFrame,
                "Frame \(frame): dragging=\(draggingFrame), playback=\(playbackFrame)")
        }
    }

    // MARK: - TT-01 UI Integration Tests

    /// TT-01: TimelineView restoreState roundtrip at zoom 1.0.
    func test_TT01_timelineView_restoreState_roundtrip_zoom1() {
        // Given
        let timelineView = TimelineView()
        timelineView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)

        let scene1Id = UUID()
        let scenes = [SceneDraft(id: scene1Id, durationUs: 2_000_000)]  // 60 frames at 30fps

        timelineView.configure(
            scenes: scenes,
            boundaries: [],
            templateFPS: 30,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )

        let mapper = makeMapper(durationsFrames: [60])
        timelineView.setMapper(mapper)
        timelineView.layoutIfNeeded()

        // Test problematic frames that had drift with TimeUs roundtrip
        let testFrames = [0, 1, 2, 4, 5, 7, 8, 10, 11, 13, 14, 30, 59]

        for frame in testFrames {
            // When
            timelineView.restoreState(compressedFrame: frame, zoom: 1.0, mapper: mapper)

            // Then
            let snapshot = timelineView.snapshotCompressedFrame()
            XCTAssertEqual(snapshot, frame, "Frame \(frame) became \(snapshot) after restore")
        }
    }

    /// TT-01: TimelineView restoreState roundtrip at varied zoom levels.
    func test_TT01_timelineView_restoreState_roundtrip_zoomVaried() {
        // Given
        let timelineView = TimelineView()
        timelineView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)

        let scenes = [SceneDraft(id: UUID(), durationUs: 2_000_000)]

        timelineView.configure(
            scenes: scenes,
            boundaries: [],
            templateFPS: 30,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )

        let mapper = makeMapper(durationsFrames: [60])
        timelineView.setMapper(mapper)
        timelineView.layoutIfNeeded()

        // Valid zoom range: 1.0...EditorConfig.zoomMax (no 0.5!)
        let zoomLevels: [CGFloat] = [1.0, 2.0, 4.0]
        let testFrames = [1, 5, 10, 30]

        for zoom in zoomLevels {
            for frame in testFrames {
                timelineView.restoreState(compressedFrame: frame, zoom: zoom, mapper: mapper)
                let snapshot = timelineView.snapshotCompressedFrame()
                XCTAssertEqual(snapshot, frame, "Frame \(frame) at zoom \(zoom) became \(snapshot)")
            }
        }
    }

    /// TT-01: TimelineView restoreState roundtrip with transition.
    func test_TT01_timelineView_restoreState_withTransition() {
        // Given: A=30f, B=30f, transition=14f
        let timelineView = TimelineView()
        timelineView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)

        let scene1Id = UUID()
        let scene2Id = UUID()
        let scenes = [
            SceneDraft(id: scene1Id, durationUs: 1_000_000),  // 30 frames
            SceneDraft(id: scene2Id, durationUs: 1_000_000)   // 30 frames
        ]
        let boundaries = [
            SceneBoundaryDraft(
                fromSceneId: scene1Id,
                toSceneId: scene2Id,
                transition: SceneTransition.v1Preset(for: .fade)
            )
        ]

        timelineView.configure(
            scenes: scenes,
            boundaries: boundaries,
            templateFPS: 30,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )

        let mapper = makeMapper(durationsFrames: [30, 30], transitions: [(0, 1, 14)])
        timelineView.setMapper(mapper)
        timelineView.layoutIfNeeded()

        // Test boundary region frames (use mapper's computed duration)
        let maxFrame = mapper.compressedDurationFrames - 1
        let boundaryFrames = [20, 23, 29, 30, 36, 40, maxFrame]

        for frame in boundaryFrames {
            timelineView.restoreState(compressedFrame: frame, zoom: 1.0, mapper: mapper)
            let snapshot = timelineView.snapshotCompressedFrame()
            XCTAssertEqual(snapshot, frame, "Boundary frame \(frame) became \(snapshot)")
        }
    }

    // MARK: - TT-01 Phase 2: Session-Authoritative Scrubbing Tests

    /// TT-01 Phase 2: .began emits authoritative frame without rollback in scaled zone.
    func test_TT01_Phase2_beganWithoutRollback_scaledZone() {
        // Given: A=30f, B=30f, transition=14f
        let timelineView = TimelineView()
        timelineView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)

        let scene1Id = UUID()
        let scene2Id = UUID()
        let scenes = [
            SceneDraft(id: scene1Id, durationUs: 1_000_000),  // 30 frames
            SceneDraft(id: scene2Id, durationUs: 1_000_000)   // 30 frames
        ]
        let boundaries = [
            SceneBoundaryDraft(
                fromSceneId: scene1Id,
                toSceneId: scene2Id,
                transition: SceneTransition.v1Preset(for: .fade)
            )
        ]

        timelineView.configure(
            scenes: scenes,
            boundaries: boundaries,
            templateFPS: 30,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )

        let mapper = makeMapper(durationsFrames: [30, 30], transitions: [(0, 1, 14)])
        timelineView.setMapper(mapper)
        timelineView.layoutIfNeeded()

        // Problematic frames in scaled zone (would rollback with floor() vs round() asymmetry)
        let rollbackFrames = [38, 40, 42, 44, 47, 49, 51]
        var capturedEvents: [(Int, InteractionPhase)] = []

        timelineView.onEvent = { event in
            if case .scrub(let frame, let phase) = event {
                capturedEvents.append((frame, phase))
            }
        }

        for frame in rollbackFrames {
            capturedEvents.removeAll()

            // Restore to exact frame
            timelineView.restoreState(compressedFrame: frame, zoom: 1.0, mapper: mapper)

            // Simulate drag start (without actual movement)
            timelineView.simulateBeginDragging()

            // Then: .began should emit same frame, not frame-1
            XCTAssertEqual(capturedEvents.count, 1, "Expected 1 event for frame \(frame)")
            XCTAssertEqual(capturedEvents[0].0, frame,
                "Frame \(frame) rolled back to \(capturedEvents[0].0) on .began")
            XCTAssertEqual(capturedEvents[0].1, .began)
        }
    }

    /// TT-01 Phase 2: Directional clamp pure function - positive movement never goes backward.
    func test_TT01_Phase2_resolveScrubFramePure_positiveMovement() {
        let epsilon: CGFloat = 0.5

        // When moving right (deltaX > epsilon), candidate should be clamped to max(candidate, current)
        // This prevents rollback in scaled zones where candidate might be < current

        // Case 1: candidate < current (rollback scenario in scaled zone)
        let result1 = TimelineView.resolveScrubFramePure(
            candidate: 39,
            currentFrame: 40,
            deltaX: 1.0,  // Moving right
            epsilon: epsilon
        )
        XCTAssertEqual(result1.frame, 40, "Moving right with candidate=39 should clamp to current=40")
        XCTAssertTrue(result1.shouldUpdateOffset, "Meaningful movement should update offset")

        // Case 2: candidate > current (normal forward movement)
        let result2 = TimelineView.resolveScrubFramePure(
            candidate: 42,
            currentFrame: 40,
            deltaX: 2.0,  // Moving right
            epsilon: epsilon
        )
        XCTAssertEqual(result2.frame, 42, "Moving right with candidate=42 should use candidate")
        XCTAssertTrue(result2.shouldUpdateOffset, "Meaningful movement should update offset")

        // Case 3: candidate == current
        let result3 = TimelineView.resolveScrubFramePure(
            candidate: 40,
            currentFrame: 40,
            deltaX: 1.0,
            epsilon: epsilon
        )
        XCTAssertEqual(result3.frame, 40, "Same frame should remain same")
    }

    /// TT-01 Phase 2: Directional clamp pure function - negative movement never goes forward.
    func test_TT01_Phase2_resolveScrubFramePure_negativeMovement() {
        let epsilon: CGFloat = 0.5

        // When moving left (deltaX < -epsilon), candidate should be clamped to min(candidate, current)

        // Case 1: candidate > current (forward jump scenario)
        let result1 = TimelineView.resolveScrubFramePure(
            candidate: 41,
            currentFrame: 40,
            deltaX: -1.0,  // Moving left
            epsilon: epsilon
        )
        XCTAssertEqual(result1.frame, 40, "Moving left with candidate=41 should clamp to current=40")
        XCTAssertTrue(result1.shouldUpdateOffset, "Meaningful movement should update offset")

        // Case 2: candidate < current (normal backward movement)
        let result2 = TimelineView.resolveScrubFramePure(
            candidate: 38,
            currentFrame: 40,
            deltaX: -2.0,  // Moving left
            epsilon: epsilon
        )
        XCTAssertEqual(result2.frame, 38, "Moving left with candidate=38 should use candidate")
        XCTAssertTrue(result2.shouldUpdateOffset, "Meaningful movement should update offset")
    }

    /// TT-01 Phase 2: Directional clamp pure function - small deltas don't update offset.
    func test_TT01_Phase2_resolveScrubFramePure_smallDeltasAccumulate() {
        let epsilon: CGFloat = 0.5

        // When |deltaX| <= epsilon, should NOT update offset (let deltas accumulate)

        // Small positive movement
        let result1 = TimelineView.resolveScrubFramePure(
            candidate: 41,
            currentFrame: 40,
            deltaX: 0.4,  // Too small
            epsilon: epsilon
        )
        XCTAssertEqual(result1.frame, 40, "Small movement should keep current frame")
        XCTAssertFalse(result1.shouldUpdateOffset, "Small movement should NOT update offset")

        // Small negative movement
        let result2 = TimelineView.resolveScrubFramePure(
            candidate: 39,
            currentFrame: 40,
            deltaX: -0.4,  // Too small
            epsilon: epsilon
        )
        XCTAssertEqual(result2.frame, 40, "Small movement should keep current frame")
        XCTAssertFalse(result2.shouldUpdateOffset, "Small movement should NOT update offset")

        // Zero movement
        let result3 = TimelineView.resolveScrubFramePure(
            candidate: 41,
            currentFrame: 40,
            deltaX: 0.0,
            epsilon: epsilon
        )
        XCTAssertEqual(result3.frame, 40, "Zero movement should keep current frame")
        XCTAssertFalse(result3.shouldUpdateOffset, "Zero movement should NOT update offset")
    }

    /// TT-01 Phase 2: .ended uses snap-to-nearest (round) quantization.
    /// Verifies that offset between frames snaps to nearest frame.
    func test_TT01_Phase2_endedUsesSnapToNearest_snapsUp() {
        // Given: At zoom=1.0 (pxPerSecond=20), fps=30
        // exactFrame = offset * fps / pxPerSecond = offset * 1.5
        // offset = 10.4 → exactFrame = 15.6 → round = 16
        let timelineView = TimelineView()
        timelineView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)

        let scene1Id = UUID()
        let scenes = [SceneDraft(id: scene1Id, durationUs: 2_000_000)]  // 60 frames

        timelineView.configure(
            scenes: scenes,
            boundaries: [],
            templateFPS: 30,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )

        let mapper = makeMapper(durationsFrames: [60])
        timelineView.setMapper(mapper)
        timelineView.layoutIfNeeded()

        var capturedEndedFrame: Int?
        timelineView.onEvent = { event in
            if case .scrub(let frame, let phase) = event, phase == .ended {
                capturedEndedFrame = frame
            }
        }

        // Position at offset 10.4 (between frame 15 and 16, closer to 16)
        timelineView.setTestScrollOffset(10.4)
        timelineView.simulateBeginDragging()
        timelineView.simulateEndDragging()

        // Then: .ended should snap UP to frame 16 (round(15.6) = 16)
        XCTAssertEqual(capturedEndedFrame, 16,
            ".ended should snap UP: offset 10.4 → exactFrame 15.6 → round = 16, got \(capturedEndedFrame ?? -1)")
    }

    /// TT-01 Phase 2: Mapper directly tests .ended snap-to-nearest (pure calculation).
    func test_TT01_Phase2_mapperDirectSnapToNearest() {
        // Given: fps=30, pxPerSecond=20
        // exactFrame = offset * fps / pxPerSecond = offset * 1.5
        let mapper = makeMapper(durationsFrames: [60])
        let pxPerSecond: CGFloat = 20.0

        // Offset 10.2 → exactFrame = 15.3 → round = 15 (snap DOWN)
        let frame1 = mapper.compressedFrame(forOffsetX: 10.2, pxPerSecond: pxPerSecond, quantize: .ended)
        XCTAssertEqual(frame1, 15, "offset 10.2 → exactFrame 15.3 → round = 15, got \(frame1)")

        // Offset 10.4 → exactFrame = 15.6 → round = 16 (snap UP)
        let frame2 = mapper.compressedFrame(forOffsetX: 10.4, pxPerSecond: pxPerSecond, quantize: .ended)
        XCTAssertEqual(frame2, 16, "offset 10.4 → exactFrame 15.6 → round = 16, got \(frame2)")

        // Offset 10.35 → exactFrame = 15.525 → round = 16 (clearly above midpoint)
        let frame3 = mapper.compressedFrame(forOffsetX: 10.35, pxPerSecond: pxPerSecond, quantize: .ended)
        XCTAssertEqual(frame3, 16, "offset 10.35 → exactFrame 15.525 → round = 16, got \(frame3)")

        // Offset 10.3 → exactFrame = 15.45 → round = 15 (clearly below midpoint)
        let frame4 = mapper.compressedFrame(forOffsetX: 10.3, pxPerSecond: pxPerSecond, quantize: .ended)
        XCTAssertEqual(frame4, 15, "offset 10.3 → exactFrame 15.45 → round = 15, got \(frame4)")
    }

    /// TT-01 Phase 2: TimelineView .ended snaps DOWN when closer to previous frame.
    func test_TT01_Phase2_endedUsesSnapToNearest_snapsDown() {
        // Given: At zoom=1.0 (pxPerSecond=20), fps=30
        // Use offset 6.8 for cleaner calculation:
        // exactFrame = 6.8 * 30 / 20 = 10.2 → round = 10
        let timelineView = TimelineView()
        timelineView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)

        let scene1Id = UUID()
        let scenes = [SceneDraft(id: scene1Id, durationUs: 2_000_000)]  // 60 frames

        timelineView.configure(
            scenes: scenes,
            boundaries: [],
            templateFPS: 30,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )

        let mapper = makeMapper(durationsFrames: [60])
        timelineView.setMapper(mapper)
        timelineView.layoutIfNeeded()

        var capturedEndedFrame: Int?
        timelineView.onEvent = { event in
            if case .scrub(let frame, let phase) = event, phase == .ended {
                capturedEndedFrame = frame
            }
        }

        // Position at offset 6.8 (exactFrame = 10.2 → round = 10)
        timelineView.setTestScrollOffset(6.8)
        timelineView.simulateBeginDragging()
        timelineView.simulateEndDragging()

        // Then: .ended should snap DOWN to frame 10 (round(10.2) = 10)
        XCTAssertEqual(capturedEndedFrame, 10,
            ".ended should snap DOWN: offset 6.8 → exactFrame 10.2 → round = 10, got \(capturedEndedFrame ?? -1)")
    }

    /// TT-01 Phase 2: .ended snaps UP when closer to next frame.
    /// Tests TimelineView integration with mapper snap-to-nearest behavior.
    func test_TT01_Phase2_endedUsesSnapToNearest_integrationSnapsUp() {
        // Given: At zoom=1.0 (pxPerSecond=20), fps=30
        // exactFrame = offset * fps / pxPerSecond = offset * 1.5
        // offset = 10.35 → exactFrame = 15.525 → round = 16 (clearly above midpoint)
        let timelineView = TimelineView()
        timelineView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)

        let scene1Id = UUID()
        let scenes = [SceneDraft(id: scene1Id, durationUs: 2_000_000)]  // 60 frames

        timelineView.configure(
            scenes: scenes,
            boundaries: [],
            templateFPS: 30,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )

        let mapper = makeMapper(durationsFrames: [60])
        timelineView.setMapper(mapper)
        timelineView.layoutIfNeeded()

        var capturedEndedFrame: Int?
        timelineView.onEvent = { event in
            if case .scrub(let frame, let phase) = event, phase == .ended {
                capturedEndedFrame = frame
            }
        }

        // Position clearly above midpoint: offset 10.35 → exactFrame 15.525
        timelineView.setTestScrollOffset(10.35)
        timelineView.simulateBeginDragging()
        timelineView.simulateEndDragging()

        // Then: .ended should snap UP to frame 16 (round(15.525) = 16)
        XCTAssertEqual(capturedEndedFrame, 16,
            ".ended above midpoint should snap UP: offset 10.35 → exactFrame 15.525 → round = 16, got \(capturedEndedFrame ?? -1)")
    }
}
