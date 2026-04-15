import XCTest
import TVECore
@testable import AnimiApp

/// Tests for project-level music track (PR8 Phase A).
/// Covers add/replace/remove/trim/volume reducer logic and undo/redo.
@MainActor
final class ProjectMusicTrackTests: XCTestCase {

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

    private func loadState(sceneDurations: [TimeUs] = [3_000_000]) -> EditorState {
        let draft = makeDraft(sceneDurations: sceneDurations)
        return EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        ).state
    }

    private let testAssetRef = AudioAssetRef.imported(assetId: ProjectAssetID())
    private let testDuration: TimeUs = 10_000_000 // 10 seconds

    // MARK: - Add Music

    func testAddMusic_createsTrackItemPayload() {
        let state = loadState()

        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration)
        )

        XCTAssertTrue(result.shouldPushSnapshot)

        let timeline = result.state.canonicalTimeline
        XCTAssertNotNil(timeline.audioTrack, "Audio track should be created")
        XCTAssertNotNil(timeline.musicItem, "Music item should exist")
        XCTAssertEqual(timeline.musicItem?.durationUs, testDuration)
        XCTAssertEqual(timeline.musicItem?.startUs, 0)
        XCTAssertEqual(timeline.musicItem?.kind, .audioClip)

        let payload = timeline.musicPayload()
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.assetRef, testAssetRef)
        XCTAssertEqual(payload?.sourceDurationUs, testDuration)
        XCTAssertEqual(payload?.trimStartUs, 0)
        XCTAssertEqual(payload?.trimEndUs, testDuration)
        XCTAssertEqual(payload?.volume, 1.0)
    }

    // MARK: - Replace Music

    func testReplaceMusic_singleItemInvariant() {
        var state = loadState()

        // Add first music
        state = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration)
        ).state

        let oldPayloadCount = state.canonicalTimeline.payloads.count

        // Replace with second music
        let newAssetRef = AudioAssetRef.imported(assetId: ProjectAssetID())
        let newDuration: TimeUs = 5_000_000
        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: newAssetRef, sourceDurationUs: newDuration)
        )

        let timeline = result.state.canonicalTimeline
        // Single item invariant
        XCTAssertEqual(timeline.audioTrack?.items.count, 1)
        XCTAssertEqual(timeline.musicItem?.durationUs, newDuration)
        XCTAssertEqual(timeline.musicPayload()?.assetRef, newAssetRef)
        // Old payload removed
        XCTAssertEqual(timeline.payloads.count, oldPayloadCount, "Old payload should be replaced, not accumulated")
    }

    // MARK: - Remove Music

    func testRemoveMusic_noAudioTrack() {
        var state = loadState()

        // Add music
        state = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration)
        ).state

        // Remove
        let result = EditorReducer.reduce(state: state, action: .removeProjectMusic)

        XCTAssertTrue(result.shouldPushSnapshot)
        XCTAssertNil(result.state.canonicalTimeline.audioTrack)
        XCTAssertNil(result.state.canonicalTimeline.musicItem)
        XCTAssertNil(result.state.canonicalTimeline.musicPayload())
    }

    func testRemoveMusic_noOrphanPayload() {
        var state = loadState()

        state = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration)
        ).state

        let scenePayloadCount = state.canonicalTimeline.payloads.values.filter {
            if case .scene = $0 { return true }
            return false
        }.count

        let result = EditorReducer.reduce(state: state, action: .removeProjectMusic)

        // Only scene payloads remain
        XCTAssertEqual(result.state.canonicalTimeline.payloads.count, scenePayloadCount)
    }

    func testRemoveSelectedMusic_resetsSelection() {
        var state = loadState()

        state = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration)
        ).state

        let itemId = state.canonicalTimeline.musicItem!.id

        // Select audio
        state = EditorReducer.reduce(
            state: state,
            action: .select(selection: .audio(itemId: itemId))
        ).state
        XCTAssertTrue(state.selection.isAudioSelected)

        // Remove
        let result = EditorReducer.reduce(state: state, action: .removeProjectMusic)
        XCTAssertEqual(result.state.selection, .none)
    }

    // MARK: - Trim Music

    func testTrimMusic_updatesPayloadAndDuration() {
        var state = loadState()

        state = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration)
        ).state

        let itemId = state.canonicalTimeline.musicItem!.id

        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusicTrim(itemId: itemId, trimStartUs: 2_000_000, trimEndUs: 8_000_000)
        )

        XCTAssertTrue(result.shouldPushSnapshot)

        let payload = result.state.canonicalTimeline.musicPayload()
        XCTAssertEqual(payload?.trimStartUs, 2_000_000)
        XCTAssertEqual(payload?.trimEndUs, 8_000_000)

        let item = result.state.canonicalTimeline.musicItem
        XCTAssertEqual(item?.durationUs, 6_000_000, "durationUs = trimEnd - trimStart")
    }

    func testTrimMusic_clampsToSourceDuration() {
        var state = loadState()

        state = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration)
        ).state

        let itemId = state.canonicalTimeline.musicItem!.id

        // Try to trim beyond source duration
        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusicTrim(itemId: itemId, trimStartUs: -1_000_000, trimEndUs: 15_000_000)
        )

        let payload = result.state.canonicalTimeline.musicPayload()
        XCTAssertEqual(payload?.trimStartUs, 0, "trimStart clamped to 0")
        XCTAssertEqual(payload?.trimEndUs, testDuration, "trimEnd clamped to sourceDuration")
    }

    // MARK: - Volume

    func testSetVolume_updatesPayload() {
        var state = loadState()

        state = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration)
        ).state

        let itemId = state.canonicalTimeline.musicItem!.id

        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusicVolume(itemId: itemId, volume: 0.5)
        )

        XCTAssertTrue(result.shouldPushSnapshot)
        XCTAssertEqual(result.state.canonicalTimeline.musicPayload()?.volume, 0.5)
    }

    func testSetVolume_clampsToRange() {
        var state = loadState()

        state = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration)
        ).state

        let itemId = state.canonicalTimeline.musicItem!.id

        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusicVolume(itemId: itemId, volume: 1.5)
        )
        XCTAssertEqual(result.state.canonicalTimeline.musicPayload()?.volume, 1.0)
    }

    // MARK: - Undo/Redo Round-Trip

    func testUndoRedo_addRemoveMusic() {
        let store = EditorStore()
        let draft = makeDraft(sceneDurations: [3_000_000])
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        // Add music
        store.dispatch(.setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration))
        XCTAssertNotNil(store.state.canonicalTimeline.musicItem)

        // Undo → no music
        store.dispatch(.undo)
        XCTAssertNil(store.state.canonicalTimeline.musicItem)

        // Redo → music restored
        store.dispatch(.redo)
        XCTAssertNotNil(store.state.canonicalTimeline.musicItem)
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.assetRef, testAssetRef)
    }

    func testUndoRedo_trimMusic() {
        let store = EditorStore()
        let draft = makeDraft(sceneDurations: [3_000_000])
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))
        store.dispatch(.setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration))

        let itemId = store.state.canonicalTimeline.musicItem!.id

        // Trim
        store.dispatch(.setProjectMusicTrim(itemId: itemId, trimStartUs: 1_000_000, trimEndUs: 7_000_000))
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.trimStartUs, 1_000_000)

        // Undo → full duration
        store.dispatch(.undo)
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.trimStartUs, 0)
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.trimEndUs, testDuration)

        // Redo → trimmed
        store.dispatch(.redo)
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.trimStartUs, 1_000_000)
    }

    func testUndoRedo_volumeChange() {
        let store = EditorStore()
        let draft = makeDraft(sceneDurations: [3_000_000])
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))
        store.dispatch(.setProjectMusic(assetRef: testAssetRef, sourceDurationUs: testDuration))

        let itemId = store.state.canonicalTimeline.musicItem!.id

        store.dispatch(.setProjectMusicVolume(itemId: itemId, volume: 0.3))
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.volume, 0.3)

        store.dispatch(.undo)
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.volume, 1.0)
    }

    // MARK: - Convenience Accessors

    func testConvenienceAccessors_noMusic() {
        let state = loadState()
        XCTAssertNil(state.canonicalTimeline.audioTrack)
        XCTAssertNil(state.canonicalTimeline.musicItem)
        XCTAssertNil(state.canonicalTimeline.musicPayload())
    }

    // MARK: - Selection

    func testAudioSelection_isAudioSelected() {
        let itemId = UUID()
        let selection = TimelineSelection.audio(itemId: itemId)
        XCTAssertTrue(selection.isAudioSelected)
        XCTAssertFalse(selection.isSceneSelected)
    }
}
