import XCTest
import TVECore
@testable import AnimiApp

/// Tests for music timeline UI interaction (PR8 Phase C).
/// Covers selection, trim, volume, and remove action paths.
@MainActor
final class MusicTimelineInteractionTests: XCTestCase {

    // MARK: - Helpers

    private func makeDraft(sceneDurations: [TimeUs]) -> ProjectDraft {
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]
        for (index, duration) in sceneDurations.enumerated() {
            let payloadId = UUID()
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "scene_\(index)"))
            let item = TimelineItem(payloadId: payloadId, kind: .scene, startUs: nil, durationUs: duration)
            timeline.tracks[0].items.append(item)
        }
        timeline.payloads = payloads
        draft.canonicalTimeline = timeline
        return draft
    }

    private func stateWithMusic() -> EditorState {
        var state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: makeDraft(sceneDurations: [5_000_000]), templateFPS: 30, defaultSceneSequence: [])
        ).state
        state = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: .imported(assetId: ProjectAssetID()), sourceDurationUs: 10_000_000)
        ).state
        return state
    }

    // MARK: - Selection

    func testAudioClipSelection_emitsAudioItemId() {
        let state = stateWithMusic()
        let itemId = state.canonicalTimeline.musicItem!.id

        let result = EditorReducer.reduce(
            state: state,
            action: .select(selection: .audio(itemId: itemId))
        )

        XCTAssertEqual(result.state.selection, .audio(itemId: itemId))
        XCTAssertTrue(result.state.selection.isAudioSelected)
        XCTAssertFalse(result.state.selection.isSceneSelected)
    }

    func testAudioSelection_deactivatesFollowPlayhead() {
        var state = stateWithMusic()

        // Activate follow playhead via focusScene
        let sceneId = state.sceneItems.first!.id
        state = EditorReducer.reduce(
            state: state,
            action: .focusScene(sceneId: sceneId)
        ).state
        XCTAssertEqual(state.timelineSceneSelectionMode, .followPlayhead)

        // Select audio
        let itemId = state.canonicalTimeline.musicItem!.id
        state = EditorReducer.reduce(
            state: state,
            action: .select(selection: .audio(itemId: itemId))
        ).state
        XCTAssertEqual(state.timelineSceneSelectionMode, .inactive)
    }

    // MARK: - Trim

    func testAudioTrim_updatesReducerState() {
        let state = stateWithMusic()
        let itemId = state.canonicalTimeline.musicItem!.id

        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusicTrim(itemId: itemId, trimStartUs: 2_000_000, trimEndUs: 6_000_000)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        XCTAssertEqual(result.state.canonicalTimeline.musicPayload()?.trimStartUs, 2_000_000)
        XCTAssertEqual(result.state.canonicalTimeline.musicPayload()?.trimEndUs, 6_000_000)
        XCTAssertEqual(result.state.canonicalTimeline.musicItem?.durationUs, 4_000_000)
    }

    // MARK: - Volume

    func testVolumeAction_updatesPayload() {
        let state = stateWithMusic()
        let itemId = state.canonicalTimeline.musicItem!.id

        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusicVolume(itemId: itemId, volume: 0.25)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        XCTAssertEqual(result.state.canonicalTimeline.musicPayload()?.volume, 0.25)
    }

    // MARK: - Remove

    func testRemoveAction_returnsToEmptyAudioLane() {
        let state = stateWithMusic()

        let result = EditorReducer.reduce(state: state, action: .removeProjectMusic)

        XCTAssertTrue(result.shouldPushSnapshot)
        XCTAssertNil(result.state.canonicalTimeline.audioTrack)
        XCTAssertNil(result.state.canonicalTimeline.musicItem)
    }

    // MARK: - Remove No-Op

    func testRemoveNoMusic_noOp() {
        let state = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: makeDraft(sceneDurations: [3_000_000]), templateFPS: 30, defaultSceneSequence: [])
        ).state

        let result = EditorReducer.reduce(state: state, action: .removeProjectMusic)
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    // MARK: - Trim Dispatch Through Store (production path)

    func testTrimDispatch_updatesClipDurationThroughStore() {
        let store = EditorStore()
        store.dispatch(.loadProject(
            draft: makeDraft(sceneDurations: [5_000_000]),
            templateFPS: 30,
            defaultSceneSequence: []
        ))
        store.dispatch(.setProjectMusic(
            assetRef: .imported(assetId: ProjectAssetID()),
            sourceDurationUs: 10_000_000
        ))

        let itemId = store.state.canonicalTimeline.musicItem!.id

        // Dispatch trim (same path as production UI)
        store.dispatch(.setProjectMusicTrim(
            itemId: itemId,
            trimStartUs: 2_000_000,
            trimEndUs: 6_000_000
        ))

        // Timeline reflects updated clip duration
        XCTAssertEqual(store.state.canonicalTimeline.musicItem?.durationUs, 4_000_000)
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.trimStartUs, 2_000_000)
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.trimEndUs, 6_000_000)
    }
}
