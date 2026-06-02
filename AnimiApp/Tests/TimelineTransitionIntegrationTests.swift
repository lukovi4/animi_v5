import XCTest
import TVECore
@testable import AnimiApp

/// Integration tests for timeline transitions (v6 Schema).
/// Tests cover:
/// - Persistence roundtrip for boundaryTransitions
/// - Auto-reset invalid transitions on trim
/// - Auto-reset invalid transitions on reorder
/// - Auto-reset invalid transitions on delete scene
/// - Validator normalization behavior
final class TimelineTransitionIntegrationTests: XCTestCase {

    // MARK: - Test Constants

    private let fps = 30
    private let usPerFrame: TimeUs = 33_334  // ceil(1_000_000 / 30) for proper rounding

    // MARK: - Test Helpers

    /// Creates a timeline with specified scene durations (in frames).
    private func makeTimeline(sceneDurationFrames: [Int]) -> CanonicalTimeline {
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]

        for (index, frames) in sceneDurationFrames.enumerated() {
            let payloadId = UUID()
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "test_scene_\(index)"))
            let durationUs = TimeUs(frames) * usPerFrame
            let item = TimelineItem(
                payloadId: payloadId,
                kind: .scene,
                startUs: nil,
                durationUs: durationUs
            )
            timeline.tracks[0].items.append(item)
        }

        timeline.payloads = payloads
        return timeline
    }

    /// Creates a draft with specified scene durations (in frames).
    private func makeDraft(sceneDurationFrames: [Int]) -> ProjectDraft {
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        draft.canonicalTimeline = makeTimeline(sceneDurationFrames: sceneDurationFrames)
        return draft
    }

    /// Adds a fade transition between scenes at given indices.
    private func addFadeTransition(
        to timeline: inout CanonicalTimeline,
        fromIndex: Int,
        toIndex: Int,
        durationFrames: Int = 14
    ) {
        let items = timeline.sceneItems
        guard fromIndex < items.count, toIndex < items.count else { return }

        let key = SceneBoundaryKey(items[fromIndex].id, items[toIndex].id)
        timeline.boundaryTransitions[key] = SceneTransition(
            type: .fade,
            durationFrames: durationFrames,
            easingPreset: .linear
        )
    }

    // MARK: - 1. Persistence Roundtrip Tests

    /// Test: boundaryTransitions roundtrip through JSON encoding.
    func testBoundaryTransitions_persistenceRoundtrip() throws {
        // Given: timeline with two scenes and a fade transition
        var timeline = makeTimeline(sceneDurationFrames: [30, 30])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)

        // Verify transition exists
        XCTAssertEqual(timeline.boundaryTransitions.count, 1)
        let originalKey = timeline.boundaryTransitions.keys.first!
        let originalTransition = timeline.boundaryTransitions[originalKey]!
        XCTAssertEqual(originalTransition.type, .fade)
        XCTAssertEqual(originalTransition.durationFrames, 14)

        // When: encode to JSON and decode back
        let encoder = JSONEncoder()
        let data = try encoder.encode(timeline)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CanonicalTimeline.self, from: data)

        // Then: boundaryTransitions preserved
        XCTAssertEqual(decoded.boundaryTransitions.count, 1)

        let decodedKey = decoded.boundaryTransitions.keys.first!
        XCTAssertEqual(decodedKey.fromSceneInstanceId, originalKey.fromSceneInstanceId)
        XCTAssertEqual(decodedKey.toSceneInstanceId, originalKey.toSceneInstanceId)

        let decodedTransition = decoded.boundaryTransitions[decodedKey]!
        XCTAssertEqual(decodedTransition.type, .fade)
        XCTAssertEqual(decodedTransition.durationFrames, 14)
        XCTAssertEqual(decodedTransition.easingPreset, .linear)
    }

    /// Test: multiple transitions roundtrip correctly.
    func testMultipleTransitions_persistenceRoundtrip() throws {
        // Given: timeline with 3 scenes and 2 transitions
        var timeline = makeTimeline(sceneDurationFrames: [30, 30, 30])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)

        let items = timeline.sceneItems
        let key2 = SceneBoundaryKey(items[1].id, items[2].id)
        timeline.boundaryTransitions[key2] = SceneTransition(
            type: .dipToBlack,
            durationFrames: 14,
            easingPreset: .easeInOut
        )

        // When: encode/decode
        let encoder = JSONEncoder()
        let data = try encoder.encode(timeline)
        let decoded = try decoder.decode(CanonicalTimeline.self, from: data)

        // Then: both transitions preserved
        XCTAssertEqual(decoded.boundaryTransitions.count, 2)

        // Find fade transition
        let fadeEntry = decoded.boundaryTransitions.first { $0.value.type == .fade }
        XCTAssertNotNil(fadeEntry)

        // Find dip transition
        let dipEntry = decoded.boundaryTransitions.first { $0.value.type == .dipToBlack }
        XCTAssertNotNil(dipEntry)
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    /// Test: empty boundaryTransitions roundtrip.
    func testEmptyTransitions_persistenceRoundtrip() throws {
        // Given: timeline with no transitions
        let timeline = makeTimeline(sceneDurationFrames: [30, 30])
        XCTAssertTrue(timeline.boundaryTransitions.isEmpty)

        // When: encode/decode
        let encoder = JSONEncoder()
        let data = try encoder.encode(timeline)
        let decoded = try decoder.decode(CanonicalTimeline.self, from: data)

        // Then: still empty
        XCTAssertTrue(decoded.boundaryTransitions.isEmpty)
    }

    /// Test: full CanonicalTimeline roundtrip including boundary, intro, and outro transitions.
    func testCanonicalTimeline_fullRoundtrip() throws {
        // Given: 3-scene timeline with boundary transitions, intro, and outro
        var timeline = makeTimeline(sceneDurationFrames: [60, 60, 60])
        let items = timeline.sceneItems

        // Add 2 boundary transitions with distinct types/durations/easings
        let key01 = SceneBoundaryKey(items[0].id, items[1].id)
        timeline.boundaryTransitions[key01] = SceneTransition(
            type: .fade,
            durationFrames: 10,
            easingPreset: .linear
        )
        let key12 = SceneBoundaryKey(items[1].id, items[2].id)
        timeline.boundaryTransitions[key12] = SceneTransition(
            type: .slide(direction: .left),
            durationFrames: 20,
            easingPreset: .easeInOut
        )

        // Set intro and outro
        timeline.introTransition = SceneTransition(
            type: .dipToBlack,
            durationFrames: 15,
            easingPreset: .easeInOut
        )
        timeline.outroTransition = SceneTransition(
            type: .fade,
            durationFrames: 12,
            easingPreset: .linear
        )

        // When: encode → decode
        let encoder = JSONEncoder()
        let data = try encoder.encode(timeline)
        let decoded = try decoder.decode(CanonicalTimeline.self, from: data)

        // Then: boundaryTransitions count and exact keys
        XCTAssertEqual(decoded.boundaryTransitions.count, 2)

        let decodedT01 = decoded.boundaryTransitions[key01]
        XCTAssertNotNil(decodedT01)
        XCTAssertEqual(decodedT01?.type, .fade)
        XCTAssertEqual(decodedT01?.durationFrames, 10)
        XCTAssertEqual(decodedT01?.easingPreset, .linear)

        let decodedT12 = decoded.boundaryTransitions[key12]
        XCTAssertNotNil(decodedT12)
        XCTAssertEqual(decodedT12?.type, .slide(direction: .left))
        XCTAssertEqual(decodedT12?.durationFrames, 20)
        XCTAssertEqual(decodedT12?.easingPreset, .easeInOut)

        // Then: intro/outro equality
        XCTAssertEqual(decoded.introTransition, timeline.introTransition)
        XCTAssertEqual(decoded.outroTransition, timeline.outroTransition)

        // Then: tracks and payloads preserved
        XCTAssertEqual(decoded.tracks.count, timeline.tracks.count)
        XCTAssertEqual(decoded.payloads.count, timeline.payloads.count)
        XCTAssertEqual(decoded.sceneItems.count, 3)
    }

    /// Test: nil intro/outro transitions survive roundtrip.
    func testIntroOutroTransition_nilRoundtrip() throws {
        // Given: timeline with nil intro and outro
        let timeline = makeTimeline(sceneDurationFrames: [30, 30])
        XCTAssertNil(timeline.introTransition)
        XCTAssertNil(timeline.outroTransition)

        // When: encode → decode
        let encoder = JSONEncoder()
        let data = try encoder.encode(timeline)
        let decoded = try decoder.decode(CanonicalTimeline.self, from: data)

        // Then: still nil
        XCTAssertNil(decoded.introTransition)
        XCTAssertNil(decoded.outroTransition)
    }

    // MARK: - 2. Validator Auto-Reset Tests

    /// Test: transition reset when scene becomes too short.
    func testValidator_resetsTransitionWhenSceneTooShort() {
        // Given: two scenes with 30 frames each and a 14-frame transition
        var timeline = makeTimeline(sceneDurationFrames: [30, 30])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)

        // When: make scene A too short (less than half transition = 7 frames)
        timeline.tracks[0].items[0].durationUs = TimeUs(6) * usPerFrame  // 6 frames

        // Then: validate should report issue
        let issues = TimelineTransitionValidator.validate(timeline: timeline, fps: fps)
        XCTAssertFalse(issues.isEmpty)
        // Check for sceneTooShort issue using pattern matching
        let hasSceneTooShort = issues.contains { issue in
            if case .sceneTooShort = issue { return true }
            return false
        }
        XCTAssertTrue(hasSceneTooShort)
    }

    /// Test: normalization removes invalid transition.
    func testValidator_normalizationRemovesInvalidTransition() {
        // Given: two scenes, one too short for transition
        var timeline = makeTimeline(sceneDurationFrames: [6, 30])  // 6 frames is too short
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)

        // Verify transition exists
        XCTAssertEqual(timeline.boundaryTransitions.count, 1)

        // When: normalize
        let result = TimelineTransitionValidator.normalize(timeline: timeline, fps: fps)

        // Then: transition removed
        XCTAssertTrue(result.boundaryTransitions.isEmpty)
        XCTAssertFalse(result.resetBoundaries.isEmpty)
    }

    /// Test: valid transitions are preserved.
    func testValidator_preservesValidTransitions() {
        // Given: two scenes long enough for transition (30 frames each)
        var timeline = makeTimeline(sceneDurationFrames: [30, 30])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)

        // When: normalize
        let result = TimelineTransitionValidator.normalize(timeline: timeline, fps: fps)

        // Then: transition preserved
        XCTAssertEqual(result.boundaryTransitions.count, 1)
        XCTAssertTrue(result.resetBoundaries.isEmpty)
    }

    /// Test: orphaned transition keys are cleaned up.
    func testValidator_cleansOrphanedTransitionKeys() {
        // Given: timeline with transition but scene IDs don't match
        var timeline = makeTimeline(sceneDurationFrames: [30, 30])

        // Add transition with bogus UUIDs
        let bogusKey = SceneBoundaryKey(UUID(), UUID())
        timeline.boundaryTransitions[bogusKey] = SceneTransition(
            type: .fade,
            durationFrames: 14,
            easingPreset: .linear
        )

        // When: normalize
        let result = TimelineTransitionValidator.normalize(timeline: timeline, fps: fps)

        // Then: orphaned transition removed
        XCTAssertTrue(result.boundaryTransitions.isEmpty)
    }

    // MARK: - 3. Transition Duration Tests

    /// Test: transition full duration requirement (per ТЗ: min scene duration = sum of adjacent transitions).
    func testValidator_transitionHalfDurationConstraint() {
        // Given: scene with 14 frames, transition with 14 frames
        // Per ТЗ: min scene duration = full transition duration for boundary scene
        var timeline = makeTimeline(sceneDurationFrames: [14, 30])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)

        // When: validate
        let issues = TimelineTransitionValidator.validate(timeline: timeline, fps: fps)

        // Then: no issues (14 >= 14)
        XCTAssertTrue(issues.isEmpty)
    }

    /// Test: boundary scene must have enough frames for transition.
    func testValidator_boundarySceneMinimumDuration() {
        // Given: scene with 6 frames, transition needs 7
        var timeline = makeTimeline(sceneDurationFrames: [6, 30])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)

        // When: validate
        let issues = TimelineTransitionValidator.validate(timeline: timeline, fps: fps)

        // Then: scene too short
        XCTAssertFalse(issues.isEmpty)
    }

    // MARK: - 4. TransitionMath Integration

    /// Test: TransitionMath compressed duration matches expectation.
    func testTransitionMath_compressedDurationIntegration() {
        // Given: 3 scenes of 30 frames each, 2 transitions
        var timeline = makeTimeline(sceneDurationFrames: [30, 30, 30])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)
        addFadeTransition(to: &timeline, fromIndex: 1, toIndex: 2)

        // When: create math
        let math = TimelineTransitionMath(
            sceneItems: timeline.sceneItems,
            boundaryTransitions: timeline.boundaryTransitions,
            fps: fps
        )

        // Then: compressed duration = 90 - 7*2 = 76
        XCTAssertEqual(math.compressedDurationFrames, 76)
    }

    /// Test: TransitionMath with no transitions has unchanged duration.
    func testTransitionMath_noTransitionsPreservesDuration() {
        // Given: 3 scenes, no transitions
        let timeline = makeTimeline(sceneDurationFrames: [30, 30, 30])

        // When: create math
        let math = TimelineTransitionMath(
            sceneItems: timeline.sceneItems,
            boundaryTransitions: timeline.boundaryTransitions,
            fps: fps
        )

        // Then: compressed = uncompressed = 90
        XCTAssertEqual(math.compressedDurationFrames, 90)
    }

    // MARK: - 5. SceneTransition Type Tests

    /// Test: all transition types can be encoded/decoded.
    func testSceneTransition_allTypesRoundtrip() throws {
        let types: [AnimiApp.TransitionType] = [
            .none,
            .fade,
            .slide(direction: .left),
            .slide(direction: .right),
            .slide(direction: .up),
            .slide(direction: .down),
            .push(direction: .left),
            .push(direction: .right),
            .push(direction: .up),
            .push(direction: .down),
            .dipToBlack,
            .dipToWhite
        ]

        for type in types {
            let transition = SceneTransition(
                type: type,
                durationFrames: 14,
                easingPreset: .easeInOut
            )

            let encoder = JSONEncoder()
            let data = try encoder.encode(transition)

            let decoded = try decoder.decode(SceneTransition.self, from: data)
            XCTAssertEqual(decoded.type, type, "Failed roundtrip for type: \(type)")
        }
    }

    /// Test: SceneTransition.none has zero duration.
    func testSceneTransition_noneHasZeroDuration() {
        let none = SceneTransition.none
        XCTAssertEqual(none.durationFrames, 0)
        XCTAssertEqual(none.type, .none)
    }

    // MARK: - 6. GlobalVideoResidencyCoordinator Tests

    /// Test: residency coordinator pins current scene.
    @MainActor
    func testResidencyCoordinator_pinsCurrentScene() {
        // Given: timeline with 3 scenes
        let timeline = makeTimeline(sceneDurationFrames: [30, 30, 30])
        let math = TimelineTransitionMath(
            sceneItems: timeline.sceneItems,
            boundaryTransitions: [:],
            fps: fps
        )
        let coordinator = GlobalVideoResidencyCoordinator()

        // When: update at frame 0 (scene 0)
        coordinator.update(transitionMath: math, compressedFrame: 0)

        // Then: scene 0 is pinned
        let pinnedIds = coordinator.pinnedInstanceIds
        XCTAssertTrue(pinnedIds.contains(timeline.sceneItems[0].id))
    }

    /// Test: residency coordinator warms adjacent scenes.
    @MainActor
    func testResidencyCoordinator_warmsAdjacentScenes() {
        // Given: timeline with 3 scenes
        let timeline = makeTimeline(sceneDurationFrames: [30, 30, 30])
        let math = TimelineTransitionMath(
            sceneItems: timeline.sceneItems,
            boundaryTransitions: [:],
            fps: fps
        )
        let coordinator = GlobalVideoResidencyCoordinator()

        // When: update at frame 35 (scene 1)
        coordinator.update(transitionMath: math, compressedFrame: 35)

        // Then: scene 1 is pinned, scenes 0 and 2 are warm
        let pinnedIds = coordinator.pinnedInstanceIds
        let warmIds = coordinator.warmInstanceIds

        XCTAssertTrue(pinnedIds.contains(timeline.sceneItems[1].id))
        XCTAssertTrue(warmIds.contains(timeline.sceneItems[0].id) ||
                      warmIds.contains(timeline.sceneItems[2].id))
    }

    /// Test: residency coordinator pins both scenes during transition.
    @MainActor
    func testResidencyCoordinator_pinsBothDuringTransition() {
        // Given: timeline with 2 scenes and transition
        var timeline = makeTimeline(sceneDurationFrames: [30, 30])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)

        let math = TimelineTransitionMath(
            sceneItems: timeline.sceneItems,
            boundaryTransitions: timeline.boundaryTransitions,
            fps: fps
        )
        let coordinator = GlobalVideoResidencyCoordinator()

        // When: update at frame 25 (in transition window: 23-36)
        coordinator.update(transitionMath: math, compressedFrame: 25)

        // Then: both scenes are pinned
        let pinnedIds = coordinator.pinnedInstanceIds
        XCTAssertTrue(pinnedIds.contains(timeline.sceneItems[0].id))
        XCTAssertTrue(pinnedIds.contains(timeline.sceneItems[1].id))
    }

    // MARK: - 7. Payload Extraction Tests (PR-F Fix)

    /// Test: TimelinePayload.scene pattern match works correctly.
    func testTimelinePayload_scenePatternMatch() {
        // Given: timeline with scene payload
        let timeline = makeTimeline(sceneDurationFrames: [30])
        let item = timeline.sceneItems.first!

        // When: extract payload using pattern match
        guard let payload = timeline.payloads[item.payloadId],
              case .scene(let scenePayload) = payload else {
            XCTFail("Failed to extract scene payload via pattern match")
            return
        }

        // Then: payload correctly extracted
        XCTAssertEqual(scenePayload.sceneTypeId, "test_scene_0")
    }

    /// Test: casting to ScenePayload fails (validates pattern match is needed).
    func testTimelinePayload_castToScenePayloadFails() {
        // Given: timeline with scene payload
        let timeline = makeTimeline(sceneDurationFrames: [30])
        let item = timeline.sceneItems.first!
        let payload = timeline.payloads[item.payloadId]

        // When: try to cast directly (this is what the old code did incorrectly)
        let casted = payload as? ScenePayload

        // Then: cast fails (TimelinePayload is enum, not ScenePayload)
        XCTAssertNil(casted, "Direct cast should fail - pattern match is required")
    }

    // MARK: - 8. Validator Key Removal Tests (PR-F Fix)

    /// Test: normalize actually removes keys from dictionary, not just sets to .none.
    func testValidator_normalizeRemovesKeys_notSetsToNone() {
        // Given: scene too short for transition
        var timeline = makeTimeline(sceneDurationFrames: [6, 30])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)

        // Verify transition exists
        XCTAssertEqual(timeline.boundaryTransitions.count, 1)
        let key = timeline.boundaryTransitions.keys.first!

        // When: normalize
        let result = TimelineTransitionValidator.normalize(timeline: timeline, fps: fps)

        // Then: key is removed from dictionary (not set to .none)
        XCTAssertNil(result.boundaryTransitions[key], "Key should be removed, not set to .none")
        XCTAssertTrue(result.boundaryTransitions.isEmpty, "Dictionary should be empty")
    }

    /// Test: isTransitionsEmpty check works correctly after normalize.
    func testValidator_normalizedTimeline_isTransitionsEmptyCheck() {
        // Given: all transitions invalid
        var timeline = makeTimeline(sceneDurationFrames: [6, 6, 6])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)
        addFadeTransition(to: &timeline, fromIndex: 1, toIndex: 2)

        XCTAssertEqual(timeline.boundaryTransitions.count, 2)

        // When: normalize
        let result = TimelineTransitionValidator.normalize(timeline: timeline, fps: fps)

        // Then: isEmpty check works (was broken when setting to .none instead of removing)
        XCTAssertTrue(result.boundaryTransitions.isEmpty)
        // This check would fail if we were setting to .none instead of removing
        XCTAssertEqual(result.boundaryTransitions.count, 0)
    }

    // MARK: - 9. TT-03 Deterministic Ordering Tests

    /// Test: prioritizedInstances returns deterministic order with sceneIndex and UUID tiebreaker.
    @MainActor
    func testResidencyCoordinator_prioritizedInstances_deterministicTieBreak() {
        // Given: 5 scenes with fixed UUIDs
        let id0 = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let id3 = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let id4 = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let durationUs: TimeUs = 30 * usPerFrame  // 30 frames per scene
        let sceneItems: [TimelineItem] = [
            TimelineItem(id: id0, payloadId: UUID(), kind: .scene, durationUs: durationUs),
            TimelineItem(id: id1, payloadId: UUID(), kind: .scene, durationUs: durationUs),
            TimelineItem(id: id2, payloadId: UUID(), kind: .scene, durationUs: durationUs),
            TimelineItem(id: id3, payloadId: UUID(), kind: .scene, durationUs: durationUs),
            TimelineItem(id: id4, payloadId: UUID(), kind: .scene, durationUs: durationUs)
        ]

        let math = TimelineTransitionMath(
            sceneItems: sceneItems,
            boundaryTransitions: [:],
            fps: fps
        )
        let coordinator = GlobalVideoResidencyCoordinator()

        // When: update at scene 2 (middle) - frame 60 is start of scene 2
        coordinator.update(transitionMath: math, compressedFrame: 60)

        // Expect: pinned=id2, warm=id1+id3, evictable=id0+id4
        XCTAssertEqual(coordinator.pinnedInstanceIds, [id2])
        XCTAssertEqual(coordinator.warmInstanceIds, [id1, id3])

        // When: get prioritized instances
        let prioritized = coordinator.prioritizedInstances(
            from: Set([id0, id1, id2, id3, id4]),
            sceneItems: sceneItems
        )

        // Then: exact deterministic order
        // tier 0: id2 (pinned)
        // tier 1: id1, id3 (warm, same distance=1, id1 < id3 by sceneIndex)
        // tier 2: id0, id4 (evictable, same distance=2, id0 < id4 by sceneIndex)
        XCTAssertEqual(prioritized, [id2, id1, id3, id0, id4])
    }

    /// Test: instancesToEvictOrdered returns farthest-first with deterministic tiebreaker.
    @MainActor
    func testResidencyCoordinator_instancesToEvictOrdered_farthestFirstDeterministic() {
        // Given: 7 scenes with fixed UUIDs
        let ids = (0..<7).map { i in
            UUID(uuidString: "\(String(repeating: String(i), count: 8))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 4))-\(String(repeating: String(i), count: 12))")!
        }

        let durationUs: TimeUs = 30 * usPerFrame  // 30 frames per scene
        let sceneItems: [TimelineItem] = ids.map { id in
            TimelineItem(id: id, payloadId: UUID(), kind: .scene, durationUs: durationUs)
        }

        let math = TimelineTransitionMath(
            sceneItems: sceneItems,
            boundaryTransitions: [:],
            fps: fps
        )
        let coordinator = GlobalVideoResidencyCoordinator()

        // When: update at scene 3 (center) - frame 90 is start of scene 3
        coordinator.update(transitionMath: math, compressedFrame: 90)

        // Expect: pinned=ids[3], warm=ids[2]+ids[4]
        XCTAssertEqual(coordinator.pinnedInstanceIds, [ids[3]])
        XCTAssertEqual(coordinator.warmInstanceIds, [ids[2], ids[4]])

        // When: get eviction order
        let toEvict = coordinator.instancesToEvictOrdered(
            from: Set(ids),
            sceneItems: sceneItems
        )

        // Then: evictable only (ids[0,1,5,6]), farthest first, sceneIndex tiebreak
        // distances: id0=3, id1=2, id5=2, id6=3
        // order: id0(dist=3), id6(dist=3 but sceneIndex 6 > 0), id1(dist=2), id5(dist=2 but sceneIndex 5 > 1)
        // But since distance desc, farthest first: dist=3 before dist=2
        // dist=3: id0(sceneIndex=0), id6(sceneIndex=6) → id0 before id6
        // dist=2: id1(sceneIndex=1), id5(sceneIndex=5) → id1 before id5
        XCTAssertEqual(toEvict, [ids[0], ids[6], ids[1], ids[5]])
    }

    /// Test: transition mode keeps currentSceneIndex as aIndex.
    @MainActor
    func testResidencyCoordinator_transitionMode_currentSceneIndexIsA() {
        // Given: 3 scenes with transition between 0 and 1
        var timeline = makeTimeline(sceneDurationFrames: [30, 30, 30])
        addFadeTransition(to: &timeline, fromIndex: 0, toIndex: 1)

        let math = TimelineTransitionMath(
            sceneItems: timeline.sceneItems,
            boundaryTransitions: timeline.boundaryTransitions,
            fps: fps
        )
        let coordinator = GlobalVideoResidencyCoordinator()

        // When: update at transition frame (e.g., frame 25)
        coordinator.update(transitionMath: math, compressedFrame: 25)

        // Then: currentSceneIndex should be aIndex (0), not bIndex (1) or midpoint
        XCTAssertEqual(coordinator.currentSceneIndex, 0)
    }
}
