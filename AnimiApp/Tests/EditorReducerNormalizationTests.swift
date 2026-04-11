import XCTest
import TVECore
@testable import AnimiApp

/// TT-09: Tests that every state-mutation path runs normalization
/// (applyInvariantsAndBuildNotices) — including undo/redo via restoreNormalizedSnapshot.
final class EditorReducerNormalizationTests: XCTestCase {

    // MARK: - Test Helpers

    /// Creates a test draft with specified scene durations.
    private func makeDraft(sceneDurations: [TimeUs]) -> ProjectDraft {
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))

        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]

        for (index, duration) in sceneDurations.enumerated() {
            let payloadId = UUID()
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "test_scene_\(index)"))
            let item = TimelineItem(
                payloadId: payloadId,
                kind: .scene,
                startUs: nil,
                durationUs: duration
            )
            timeline.tracks[0].items.append(item)
        }

        timeline.payloads = payloads
        draft.canonicalTimeline = timeline

        return draft
    }

    /// Loads a draft into EditorState via reducer (runs ensureTrackInvariants).
    private func loadDraft(_ draft: ProjectDraft) -> EditorState {
        EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state
    }

    /// Builds EditorState directly with an invalid boundary transition,
    /// bypassing loadProject (which would normalize it away).
    private func makeStateWithStaleBoundary(
        sceneDurations: [TimeUs],
        staleBoundaryFromId: UUID = UUID(),
        staleBoundaryToId: UUID = UUID()
    ) -> EditorState {
        var draft = makeDraft(sceneDurations: sceneDurations)

        // Inject a stale boundary referencing non-adjacent or non-existent scene IDs
        let staleKey = SceneBoundaryKey(staleBoundaryFromId, staleBoundaryToId)
        draft.canonicalTimeline.boundaryTransitions[staleKey] = SceneTransition.v1Preset(for: .fade)

        // Construct EditorState directly — no loadProject, no normalization
        return EditorState(
            draft: draft,
            playheadCompressedFrame: 0,
            selection: .none,
            templateFPS: 30
        )
    }

    // MARK: - 1. loadProject normalizes invalid boundaries silently

    /// loadProject runs ensureTrackInvariants which removes invalid boundaries.
    /// No notices are emitted (loadProject is initialization, not user action).
    func test_loadProject_invalidBoundaryTransitions_areNormalizedSilently() {
        var draft = makeDraft(sceneDurations: [2_000_000, 2_000_000])

        // Inject invalid boundary (references non-existent scene IDs)
        let bogusKey = SceneBoundaryKey(UUID(), UUID())
        draft.canonicalTimeline.boundaryTransitions[bogusKey] = SceneTransition.v1Preset(for: .fade)

        // loadProject should clean up without emitting notices
        let result = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        )

        // Boundary is gone
        XCTAssertTrue(result.state.canonicalTimeline.boundaryTransitions.isEmpty,
                       "Invalid boundary should be removed by loadProject normalization")

        // No notices (loadProject is silent)
        XCTAssertTrue(result.notices.isEmpty,
                       "loadProject should not emit notices")
    }

    // MARK: - 2. addScene normalizes malformed existing timeline

    /// When the timeline already has a stale boundary (injected directly, not via loadProject),
    /// addScene runs applyInvariantsAndBuildNotices which cleans it up.
    func test_addScene_runsNormalizationOnMalformedExistingTimeline() {
        // Build state directly with stale boundary (bypasses loadProject normalization)
        let state = makeStateWithStaleBoundary(sceneDurations: [2_000_000, 2_000_000])

        // Verify the stale boundary exists before action
        XCTAssertFalse(state.canonicalTimeline.boundaryTransitions.isEmpty,
                        "Pre-condition: stale boundary should exist")

        // Dispatch addScene
        let result = EditorReducer.reduce(
            state: state,
            action: .addScene(sceneTypeId: "new_scene", durationUs: 2_000_000)
        )

        // Stale boundary removed (only valid boundaries remain)
        let validBoundaryCount = result.state.canonicalTimeline.boundaryTransitions.count
        // The stale boundary referenced non-existent IDs, so it must be gone
        for (key, _) in result.state.canonicalTimeline.boundaryTransitions {
            let sceneIds = result.state.canonicalTimeline.sceneItems.map { $0.id }
            XCTAssertTrue(sceneIds.contains(key.fromSceneInstanceId),
                           "Remaining boundary should reference valid scene")
            XCTAssertTrue(sceneIds.contains(key.toSceneInstanceId),
                           "Remaining boundary should reference valid scene")
        }

        // Should emit notice about reset boundary
        let hasResetNotice = result.notices.contains { notice in
            if case .boundaryTransitionsReset = notice { return true }
            return false
        }
        XCTAssertTrue(hasResetNotice, "addScene should emit notice when stale boundary is reset")

        _ = validBoundaryCount // silence warning
    }

    // MARK: - 3. duplicateScene normalizes malformed existing timeline

    func test_duplicateScene_runsNormalizationOnMalformedExistingTimeline() {
        // Build state directly with stale boundary
        let state = makeStateWithStaleBoundary(sceneDurations: [2_000_000, 2_000_000])
        let firstSceneId = state.canonicalTimeline.sceneItems[0].id

        // Verify the stale boundary exists before action
        XCTAssertFalse(state.canonicalTimeline.boundaryTransitions.isEmpty)

        // Dispatch duplicateScene
        let result = EditorReducer.reduce(
            state: state,
            action: .duplicateScene(sceneItemId: firstSceneId)
        )

        // Stale boundary removed
        for (key, _) in result.state.canonicalTimeline.boundaryTransitions {
            let sceneIds = result.state.canonicalTimeline.sceneItems.map { $0.id }
            XCTAssertTrue(sceneIds.contains(key.fromSceneInstanceId),
                           "Remaining boundary should reference valid scene")
            XCTAssertTrue(sceneIds.contains(key.toSceneInstanceId),
                           "Remaining boundary should reference valid scene")
        }

        // Should emit notice
        let hasResetNotice = result.notices.contains { notice in
            if case .boundaryTransitionsReset = notice { return true }
            return false
        }
        XCTAssertTrue(hasResetNotice, "duplicateScene should emit notice when stale boundary is reset")
    }

    // MARK: - 4. deleteScene resets broken boundary and emits notice

    /// Delete a scene that participates in a boundary → boundary reset + notice with correct key.
    func test_deleteScene_resetsBrokenBoundaryAndEmitsNotice() {
        // Build 3 scenes via loadProject (clean state)
        let draft = makeDraft(sceneDurations: [2_000_000, 2_000_000, 2_000_000])
        var state = loadDraft(draft)
        let sceneItems = state.canonicalTimeline.sceneItems
        let sceneA = sceneItems[0].id
        let sceneB = sceneItems[1].id

        // Set valid boundary between A→B
        let setResult = EditorReducer.reduce(
            state: state,
            action: .setBoundaryTransition(
                fromSceneId: sceneA,
                toSceneId: sceneB,
                transition: SceneTransition.v1Preset(for: .fade)
            )
        )
        state = setResult.state

        // Verify boundary exists
        let key = SceneBoundaryKey(sceneA, sceneB)
        XCTAssertNotNil(state.canonicalTimeline.boundaryTransitions[key])

        // Delete scene A → boundary A→B becomes invalid
        let deleteResult = EditorReducer.reduce(
            state: state,
            action: .deleteScene(sceneId: sceneA)
        )

        // Boundary should be gone
        XCTAssertNil(deleteResult.state.canonicalTimeline.boundaryTransitions[key],
                      "Boundary referencing deleted scene should be removed")

        // Notice should contain the correct key
        let resetNotice = deleteResult.notices.first { notice in
            if case .boundaryTransitionsReset = notice { return true }
            return false
        }
        XCTAssertNotNil(resetNotice, "Delete should emit boundaryTransitionsReset notice")
        if case .boundaryTransitionsReset(let keys) = resetNotice {
            XCTAssertTrue(keys.contains(key), "Notice should contain the removed boundary key")
        }
    }

    // MARK: - 5. trimEnded resets too-long transition and emits notice

    /// Trim a scene short enough that its transition can't fit → transition reset + notice.
    func test_trimEnded_resetsTooLongTransitionAndEmitsNotice() {
        // Build 2 scenes: 2s each
        let draft = makeDraft(sceneDurations: [2_000_000, 2_000_000])
        var state = loadDraft(draft)
        let sceneItems = state.canonicalTimeline.sceneItems
        let sceneA = sceneItems[0].id
        let sceneB = sceneItems[1].id

        // Set a fade transition (14 frames at 30fps ≈ 467ms)
        let setResult = EditorReducer.reduce(
            state: state,
            action: .setBoundaryTransition(
                fromSceneId: sceneA,
                toSceneId: sceneB,
                transition: SceneTransition.v1Preset(for: .fade)
            )
        )
        state = setResult.state

        let key = SceneBoundaryKey(sceneA, sceneB)
        XCTAssertNotNil(state.canonicalTimeline.boundaryTransitions[key])

        // Trim scene B to minimum (100ms) — too short for 467ms fade
        let trimResult = EditorReducer.reduce(
            state: state,
            action: .trimScene(
                sceneId: sceneB,
                phase: .ended,
                newDurationUs: ProjectDraft.minSceneDurationUs,
                edge: .trailing
            )
        )

        // Transition should be reset (scene too short to hold it)
        let boundaryAfterTrim = trimResult.state.canonicalTimeline.boundaryTransitions[key]
        XCTAssertNil(boundaryAfterTrim,
                      "Transition should be reset when scene is trimmed too short")

        // Notice should be emitted
        let hasResetNotice = trimResult.notices.contains { notice in
            if case .boundaryTransitionsReset = notice { return true }
            return false
        }
        XCTAssertTrue(hasResetNotice, "Trim should emit notice when transition is reset")
    }

    // MARK: - 6. restoreNormalizedSnapshot normalizes and emits notice

    /// Direct test of restoreNormalizedSnapshot: invalid snapshot → normalized + notice + playhead clamped.
    @MainActor
    func test_restoreNormalizedSnapshot_normalizesAndEmitsNotice() {
        // Build a clean store with 2 scenes (2s each → 60 frames each at 30fps → ~120 compressed frames)
        let draft = makeDraft(sceneDurations: [2_000_000, 2_000_000])
        let state = loadDraft(draft)
        let store = EditorStore(initialState: state)

        let sceneItems = state.canonicalTimeline.sceneItems
        let sceneA = sceneItems[0].id
        let sceneB = sceneItems[1].id

        // Build a snapshot with:
        // 1. Invalid boundary (references non-existent scene)
        // 2. Playhead beyond valid range
        var snapshotTimeline = state.canonicalTimeline
        let bogusKey = SceneBoundaryKey(UUID(), UUID())
        snapshotTimeline.boundaryTransitions[bogusKey] = SceneTransition.v1Preset(for: .fade)

        // Also add valid boundary to verify it survives
        let validKey = SceneBoundaryKey(sceneA, sceneB)
        snapshotTimeline.boundaryTransitions[validKey] = SceneTransition.v1Preset(for: .fade)

        // Set playhead beyond valid range before restore
        let compressedDuration = state.compressedDurationFrames
        let tooHighPlayhead = compressedDuration + 55
        store.dispatch(.setPlayhead(compressedFrame: tooHighPlayhead))

        let snapshot = EditorSnapshot(
            canonicalTimeline: snapshotTimeline
        )

        // Track notices
        var receivedNotices: [EditorNotice] = []
        store.onNotice = { receivedNotices.append($0) }

        // Restore — content only; playhead is left at current position, then clamped by normalization
        let notices = store.restoreNormalizedSnapshot(snapshot)

        // Playhead should be clamped to valid range by normalization
        let maxValidFrame = max(0, store.state.compressedDurationFrames - 1)
        XCTAssertLessThanOrEqual(store.state.playheadCompressedFrame, maxValidFrame,
                                  "Playhead should be clamped to valid range after restore")

        // Invalid boundary should be removed, valid one should remain
        XCTAssertNil(store.state.canonicalTimeline.boundaryTransitions[bogusKey],
                      "Invalid boundary should be removed")
        XCTAssertNotNil(store.state.canonicalTimeline.boundaryTransitions[validKey],
                         "Valid boundary should survive normalization")

        // Notice should be emitted (for the bogus boundary)
        XCTAssertFalse(notices.isEmpty, "Should return notices for reset boundary")
        XCTAssertFalse(receivedNotices.isEmpty, "onNotice callback should fire")
    }

    // MARK: - 7. restoreNormalizedSnapshot emits notice after state update

    /// onNotice fires AFTER state is already updated — observer sees normalized state.
    @MainActor
    func test_restoreNormalizedSnapshot_emitsNoticeAfterStateUpdate() {
        let draft = makeDraft(sceneDurations: [2_000_000, 2_000_000])
        let state = loadDraft(draft)
        let store = EditorStore(initialState: state)

        // Build snapshot with invalid boundary
        var snapshotTimeline = state.canonicalTimeline
        let bogusKey = SceneBoundaryKey(UUID(), UUID())
        snapshotTimeline.boundaryTransitions[bogusKey] = SceneTransition.v1Preset(for: .fade)

        let snapshot = EditorSnapshot(
            canonicalTimeline: snapshotTimeline
        )

        // When onNotice fires, state should already be normalized
        var stateAtNoticeTime: EditorState?
        store.onNotice = { _ in
            stateAtNoticeTime = store.state
        }

        store.restoreNormalizedSnapshot(snapshot)

        // Verify state was already normalized when notice fired
        XCTAssertNotNil(stateAtNoticeTime, "onNotice should have fired")
        if let capturedState = stateAtNoticeTime {
            XCTAssertNil(capturedState.canonicalTimeline.boundaryTransitions[bogusKey],
                          "State should be normalized before onNotice fires")
        }
    }
}
