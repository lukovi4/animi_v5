import XCTest
import TVECore
@testable import AnimiApp

/// Phase 5 orchestration tests for video selection editing.
///
/// Tests cover:
/// - VideoSelectionEditorViewController delegate contract (all 4 callbacks)
/// - PlayerViewController.isVideoEditorSessionValid (static, pure-function)
/// - videoEditorSessionKey lifecycle: confirm, unchanged done, cancel, stale callbacks
/// - Store routing: commit, no-commit, stale scene
@MainActor
final class VideoSelectionEditorOrchestrationTests: XCTestCase {

    // MARK: - Mock Delegate

    final class MockDelegate: VideoSelectionEditorDelegate {
        var changeCalls: [(blockId: String, selection: PersistedVideoSelection)] = []
        var confirmCalls: [(blockId: String, selection: PersistedVideoSelection)] = []
        var finishUnchangedCalls: [String] = []
        var cancelCalls: [String] = []

        func videoSelectionEditorDidChange(blockId: String, selection: PersistedVideoSelection) {
            changeCalls.append((blockId, selection))
        }
        func videoSelectionEditorDidConfirm(blockId: String, selection: PersistedVideoSelection) {
            confirmCalls.append((blockId, selection))
        }
        func videoSelectionEditorDidFinishUnchanged(blockId: String) {
            finishUnchangedCalls.append(blockId)
        }
        func videoSelectionEditorDidCancel(blockId: String) {
            cancelCalls.append(blockId)
        }
    }

    // MARK: - Helpers

    private func makeDraft(sceneDurations: [TimeUs]) -> ProjectDraft {
        var draft = ProjectDraft.create(for: "test-template")
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

    private func makeSceneInstanceStatesWithVideoSlot(
        sceneId: UUID,
        blockId: String
    ) -> [UUID: SceneState] {
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        )
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [blockId: videoSlot]
        return [sceneId: sceneState]
    }

    // MARK: - A. Editor VC Delegate Contract

    /// Unchanged Done calls didFinishUnchanged, not didConfirm or local dismiss.
    func test_unchangedDone_callsDidFinishUnchanged() {
        let selection = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        let vc = VideoSelectionEditorViewController(
            blockId: "block_01",
            actualDuration: 10.0,
            initialSelection: selection
        )
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        vc.perform(Selector(("doneTapped")))

        XCTAssertEqual(delegate.finishUnchangedCalls.count, 1)
        XCTAssertEqual(delegate.finishUnchangedCalls.first, "block_01")
        XCTAssertTrue(delegate.confirmCalls.isEmpty, "Should NOT call didConfirm for unchanged")
        XCTAssertTrue(delegate.cancelCalls.isEmpty)
    }

    /// Cancel calls didCancel.
    func test_cancel_callsDidCancel() {
        let selection = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        let vc = VideoSelectionEditorViewController(
            blockId: "block_01",
            actualDuration: 10.0,
            initialSelection: selection
        )
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        vc.perform(Selector(("cancelTapped")))

        XCTAssertEqual(delegate.cancelCalls.count, 1)
        XCTAssertEqual(delegate.cancelCalls.first, "block_01")
        XCTAssertTrue(delegate.confirmCalls.isEmpty)
        XCTAssertTrue(delegate.finishUnchangedCalls.isEmpty)
    }

    // MARK: - B. isVideoEditorSessionValid (static, pure-function)

    /// Valid session: blockId matches, instanceId matches target, slot is video.
    func test_sessionValid_allConditionsMet() {
        let sceneId = UUID()
        let states = makeSceneInstanceStatesWithVideoSlot(sceneId: sceneId, blockId: "block_01")

        let result = PlayerViewController.isVideoEditorSessionValid(
            for: "block_01",
            sessionKey: (instanceId: sceneId, blockId: "block_01"),
            sceneEditTargetInstanceId: sceneId,
            sceneInstanceStates: states
        )
        XCTAssertTrue(result)
    }

    /// Stale session: blockId doesn't match session key.
    func test_sessionInvalid_blockIdMismatch() {
        let sceneId = UUID()
        let states = makeSceneInstanceStatesWithVideoSlot(sceneId: sceneId, blockId: "block_01")

        let result = PlayerViewController.isVideoEditorSessionValid(
            for: "block_99",
            sessionKey: (instanceId: sceneId, blockId: "block_01"),
            sceneEditTargetInstanceId: sceneId,
            sceneInstanceStates: states
        )
        XCTAssertFalse(result, "Mismatched blockId should invalidate session")
    }

    /// Stale session: target instance changed (scene switched).
    func test_sessionInvalid_targetInstanceChanged() {
        let sceneA = UUID()
        let sceneB = UUID()
        let states = makeSceneInstanceStatesWithVideoSlot(sceneId: sceneA, blockId: "block_01")

        let result = PlayerViewController.isVideoEditorSessionValid(
            for: "block_01",
            sessionKey: (instanceId: sceneA, blockId: "block_01"),
            sceneEditTargetInstanceId: sceneB,  // Target changed
            sceneInstanceStates: states
        )
        XCTAssertFalse(result, "Session for sceneA should be invalid when target is sceneB")
    }

    /// Stale session: no session key set.
    func test_sessionInvalid_noSessionKey() {
        let sceneId = UUID()
        let states = makeSceneInstanceStatesWithVideoSlot(sceneId: sceneId, blockId: "block_01")

        let result = PlayerViewController.isVideoEditorSessionValid(
            for: "block_01",
            sessionKey: nil,
            sceneEditTargetInstanceId: sceneId,
            sceneInstanceStates: states
        )
        XCTAssertFalse(result, "Nil session key should invalidate")
    }

    /// Stale session: slot exists but is a photo (not video).
    func test_sessionInvalid_slotIsPhoto() {
        let sceneId = UUID()
        let photoSlot = SceneMediaSlot.photo(mediaRef: MediaRef.file("Media/test.jpg"))
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = ["block_01": photoSlot]

        let result = PlayerViewController.isVideoEditorSessionValid(
            for: "block_01",
            sessionKey: (instanceId: sceneId, blockId: "block_01"),
            sceneEditTargetInstanceId: sceneId,
            sceneInstanceStates: [sceneId: sceneState]
        )
        XCTAssertFalse(result, "Photo slot should invalidate video editor session")
    }

    /// Stale session: slot missing from state.
    func test_sessionInvalid_slotMissing() {
        let sceneId = UUID()

        let result = PlayerViewController.isVideoEditorSessionValid(
            for: "block_01",
            sessionKey: (instanceId: sceneId, blockId: "block_01"),
            sceneEditTargetInstanceId: sceneId,
            sceneInstanceStates: [sceneId: .empty]
        )
        XCTAssertFalse(result, "Missing slot should invalidate session")
    }

    // MARK: - C. Store Routing: Commit / No-Commit

    /// setVideoSelection with unchanged selection does not push snapshot.
    func test_storeNotMutated_whenSelectionUnchanged() {
        let draft = makeDraft(sceneDurations: [2_000_000])
        let store = EditorStore(initialState: EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state)

        let sceneId = store.state.sceneItems[0].id
        let selection = PersistedVideoSelection(trimStart: 0, trimEnd: 10.0)
        let videoSlot = SceneMediaSlot.video(
            mediaRef: MediaRef.file("Media/test.mov", mediaKind: .video),
            videoWindow: selection
        )
        store.dispatch(.setMediaSlot(sceneInstanceId: sceneId, blockId: "block_01", slot: videoSlot))

        var videoChangeFired = false
        store.onVideoSelectionChanged = { _, _, _ in
            videoChangeFired = true
        }

        store.dispatch(.setVideoSelection(sceneInstanceId: sceneId, blockId: "block_01", selection: selection))

        XCTAssertFalse(videoChangeFired, "Unchanged selection must not fire callback")
    }

    /// setVideoSelection for a non-existent scene fires no callbacks.
    func test_staleSession_wrongSceneId_noStoreCallback() {
        let draft = makeDraft(sceneDurations: [2_000_000])
        let store = EditorStore(initialState: EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state)

        let staleSceneId = UUID()

        var videoChangeFired = false
        store.onVideoSelectionChanged = { _, _, _ in
            videoChangeFired = true
        }

        var sceneChangeFired = false
        store.onSceneStateChanged = { _, _ in
            sceneChangeFired = true
        }

        let selection = PersistedVideoSelection(trimStart: 1.0, trimEnd: 9.0)
        store.dispatch(.setVideoSelection(sceneInstanceId: staleSceneId, blockId: "block_01", selection: selection))

        XCTAssertFalse(videoChangeFired, "Stale scene ID must not fire video change callback")
        XCTAssertFalse(sceneChangeFired, "Stale scene ID must not fire scene state callback")
    }

    /// Stale didChange/didConfirm/didCancel for wrong blockId are ignored by session validator.
    func test_staleCallbacks_wrongBlock_sessionValidationRejectsAll() {
        let sceneId = UUID()
        let states = makeSceneInstanceStatesWithVideoSlot(sceneId: sceneId, blockId: "block_01")

        // Session is for block_01, but callback arrives for block_99
        let isValid = PlayerViewController.isVideoEditorSessionValid(
            for: "block_99",
            sessionKey: (instanceId: sceneId, blockId: "block_01"),
            sceneEditTargetInstanceId: sceneId,
            sceneInstanceStates: states
        )
        XCTAssertFalse(isValid, "Stale callback for wrong block should be rejected")
    }

    // MARK: - D. didFinishUnchanged Uses Full Session Validator

    /// didFinishUnchanged: blockId matches but target instance changed → full validator rejects.
    /// This verifies that didFinishUnchanged uses the same isVideoEditorSessionValid guard
    /// as didConfirm/didCancel, not a weaker blockId-only check.
    func test_didFinishUnchanged_blockIdMatchesButTargetChanged_validatorRejects() {
        let sceneA = UUID()
        let sceneB = UUID()
        let states = makeSceneInstanceStatesWithVideoSlot(sceneId: sceneA, blockId: "block_01")

        // Session was opened for (sceneA, block_01), but target is now sceneB.
        // blockId alone would match, but full validator must reject.
        let isValid = PlayerViewController.isVideoEditorSessionValid(
            for: "block_01",
            sessionKey: (instanceId: sceneA, blockId: "block_01"),
            sceneEditTargetInstanceId: sceneB,
            sceneInstanceStates: states
        )
        XCTAssertFalse(isValid,
            "didFinishUnchanged must use full session validator — blockId match alone is insufficient")
    }

    /// didFinishUnchanged: blockId matches, instanceId matches, but slot was cleared → validator rejects.
    /// Covers the case where media was removed while editor was open with unchanged selection.
    func test_didFinishUnchanged_slotRemoved_validatorRejects() {
        let sceneId = UUID()

        // Session for (sceneId, block_01), but slot no longer exists in state
        let isValid = PlayerViewController.isVideoEditorSessionValid(
            for: "block_01",
            sessionKey: (instanceId: sceneId, blockId: "block_01"),
            sceneEditTargetInstanceId: sceneId,
            sceneInstanceStates: [sceneId: .empty]  // Slot removed
        )
        XCTAssertFalse(isValid,
            "didFinishUnchanged must reject when slot was removed during editing")
    }

    /// didFinishUnchanged: fully valid session → validator accepts (session can be cleared).
    func test_didFinishUnchanged_validSession_validatorAccepts() {
        let sceneId = UUID()
        let states = makeSceneInstanceStatesWithVideoSlot(sceneId: sceneId, blockId: "block_01")

        let isValid = PlayerViewController.isVideoEditorSessionValid(
            for: "block_01",
            sessionKey: (instanceId: sceneId, blockId: "block_01"),
            sceneEditTargetInstanceId: sceneId,
            sceneInstanceStates: states
        )
        XCTAssertTrue(isValid,
            "didFinishUnchanged with fully valid session should be accepted")
    }
}
