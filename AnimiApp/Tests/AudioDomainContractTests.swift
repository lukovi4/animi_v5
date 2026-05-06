import XCTest
import TVECore
@testable import AnimiApp

/// PR3: Tests for AudioRole, generic audio accessors, role-safe reducer mutations,
/// and AudioExportPlan production contract.
@MainActor
final class AudioDomainContractTests: XCTestCase {

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

    private let musicAssetRef = AudioAssetRef.imported(assetId: ProjectAssetID())
    private let musicDuration: TimeUs = 10_000_000

    /// Injects a voiceover item into state's canonical timeline.
    private func injectVoiceoverItem(into state: inout EditorState, startUs: TimeUs = 0, durationUs: TimeUs = 5_000_000) -> UUID {
        let payloadId = UUID()
        let payload = AudioPayload(
            assetRef: .bundled(id: "vo_test"),
            sourceDurationUs: durationUs,
            trimStartUs: 0,
            trimEndUs: durationUs,
            volume: 0.8,
            role: .voiceover
        )
        state.canonicalTimeline.payloads[payloadId] = .audio(payload)
        let item = TimelineItem(
            id: UUID(),
            payloadId: payloadId,
            kind: .audioClip,
            startUs: startUs,
            durationUs: durationUs
        )
        // Find or create audio track
        if let trackIdx = state.canonicalTimeline.tracks.firstIndex(where: { $0.kind == .audio }) {
            state.canonicalTimeline.tracks[trackIdx].items.append(item)
        } else {
            var track = Track(kind: .audio)
            track.items.append(item)
            state.canonicalTimeline.tracks.append(track)
        }
        return item.id
    }

    /// Injects an sfx item into state's canonical timeline.
    private func injectSfxItem(into state: inout EditorState, startUs: TimeUs = 0, durationUs: TimeUs = 2_000_000) -> UUID {
        let payloadId = UUID()
        let payload = AudioPayload(
            assetRef: .bundled(id: "sfx_test"),
            sourceDurationUs: durationUs,
            trimStartUs: 0,
            trimEndUs: durationUs,
            volume: 1.0,
            role: .sfx
        )
        state.canonicalTimeline.payloads[payloadId] = .audio(payload)
        let item = TimelineItem(
            id: UUID(),
            payloadId: payloadId,
            kind: .audioClip,
            startUs: startUs,
            durationUs: durationUs
        )
        if let trackIdx = state.canonicalTimeline.tracks.firstIndex(where: { $0.kind == .audio }) {
            state.canonicalTimeline.tracks[trackIdx].items.append(item)
        } else {
            var track = Track(kind: .audio)
            track.items.append(item)
            state.canonicalTimeline.tracks.append(track)
        }
        return item.id
    }

    // MARK: - 1. Legacy Decode

    func testLegacyDecode_missingRole_defaultsToMusic() throws {
        let json = """
        {
            "assetRef": {"type": "bundled", "id": "track_01"},
            "sourceDurationUs": 5000000,
            "trimStartUs": 0,
            "trimEndUs": 5000000,
            "volume": 0.8
        }
        """
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(AudioPayload.self, from: data)
        XCTAssertEqual(payload.role, .music)
        XCTAssertEqual(payload.volume, 0.8)
    }

    func testRoleRoundTrip() throws {
        let original = AudioPayload(
            assetRef: .bundled(id: "test"),
            sourceDurationUs: 5_000_000,
            role: .voiceover
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioPayload.self, from: data)
        XCTAssertEqual(decoded.role, .voiceover)
    }

    // MARK: - 2. Generic Accessors

    func testGenericAccessors_filterByRole() {
        var state = loadState()

        // Add music
        let musicResult = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: musicAssetRef, sourceDurationUs: musicDuration)
        )
        state = musicResult.state

        // Add voiceover
        let voId = injectVoiceoverItem(into: &state)

        let timeline = state.canonicalTimeline

        XCTAssertEqual(timeline.allAudioItems.count, 2)
        XCTAssertEqual(timeline.audioItems(role: .music).count, 1)
        XCTAssertEqual(timeline.audioItems(role: .voiceover).count, 1)
        XCTAssertEqual(timeline.audioItems(role: .sfx).count, 0)

        // musicItem compatibility wrapper returns only music
        XCTAssertNotNil(timeline.musicItem)
        XCTAssertEqual(timeline.musicPayload()?.role, .music)

        // audioPayload(for:) works for voiceover
        XCTAssertEqual(timeline.audioPayload(for: voId)?.role, .voiceover)
    }

    // MARK: - 3. setProjectMusic Preserves Non-Music

    func testSetProjectMusic_preservesVoiceover() {
        var state = loadState()

        // Inject voiceover first
        let voId = injectVoiceoverItem(into: &state)

        // Set music
        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: musicAssetRef, sourceDurationUs: musicDuration)
        )

        let timeline = result.state.canonicalTimeline
        XCTAssertNotNil(timeline.musicItem, "Music should be added")
        XCTAssertNotNil(timeline.audioPayload(for: voId), "Voiceover should be preserved")
        XCTAssertEqual(timeline.audioPayload(for: voId)?.role, .voiceover)
        XCTAssertEqual(timeline.allAudioItems.count, 2)
    }

    func testSetProjectMusic_preservesNonMusicAcrossMultipleTracks() {
        var state = loadState()

        // Add voiceover on one audio track
        let voId = injectVoiceoverItem(into: &state)

        // Add sfx on a second audio track
        var sfxTrack = Track(kind: .audio)
        let sfxPid = UUID()
        state.canonicalTimeline.payloads[sfxPid] = .audio(AudioPayload(
            assetRef: .bundled(id: "sfx"),
            sourceDurationUs: 1_000_000,
            role: .sfx
        ))
        let sfxItem = TimelineItem(payloadId: sfxPid, kind: .audioClip, startUs: 0, durationUs: 1_000_000)
        sfxTrack.items.append(sfxItem)
        state.canonicalTimeline.tracks.append(sfxTrack)
        let sfxId = sfxItem.id

        // Also add music manually to verify replacement
        let oldMusicResult = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: .imported(assetId: ProjectAssetID()), sourceDurationUs: 5_000_000)
        )
        state = oldMusicResult.state

        // Now set new music — should replace old music, keep vo + sfx
        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: musicAssetRef, sourceDurationUs: musicDuration)
        )

        let tl = result.state.canonicalTimeline
        XCTAssertEqual(tl.audioItems(role: .music).count, 1)
        XCTAssertNotNil(tl.audioPayload(for: voId))
        XCTAssertNotNil(tl.audioPayload(for: sfxId))
    }

    // MARK: - 4. removeProjectMusic Removes Only Music

    func testRemoveProjectMusic_keepsVoiceover() {
        var state = loadState()
        let voId = injectVoiceoverItem(into: &state)

        // Add music
        let withMusic = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: musicAssetRef, sourceDurationUs: musicDuration)
        )
        state = withMusic.state
        XCTAssertEqual(state.canonicalTimeline.allAudioItems.count, 2)

        // Remove music
        let result = EditorReducer.reduce(state: state, action: .removeProjectMusic)

        let tl = result.state.canonicalTimeline
        XCTAssertNil(tl.musicItem, "Music should be removed")
        XCTAssertNotNil(tl.audioPayload(for: voId), "Voiceover should be preserved")
        // Track with voiceover should not be pruned
        XCTAssertTrue(tl.audioTracks.count >= 1)
    }

    // MARK: - 5. Trim/Volume No-Op for Non-Music

    func testSetProjectMusicTrim_noop_forVoiceover() {
        var state = loadState()
        let voId = injectVoiceoverItem(into: &state, durationUs: 5_000_000)
        let originalPayload = state.canonicalTimeline.audioPayload(for: voId)!

        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusicTrim(itemId: voId, trimStartUs: 1_000_000, trimEndUs: 3_000_000)
        )

        // State should be unchanged
        let afterPayload = result.state.canonicalTimeline.audioPayload(for: voId)!
        XCTAssertEqual(afterPayload.trimStartUs, originalPayload.trimStartUs)
        XCTAssertEqual(afterPayload.trimEndUs, originalPayload.trimEndUs)
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    func testSetProjectMusicVolume_noop_forVoiceover() {
        var state = loadState()
        let voId = injectVoiceoverItem(into: &state)
        let originalVolume = state.canonicalTimeline.audioPayload(for: voId)!.volume

        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusicVolume(itemId: voId, volume: 0.1)
        )

        let afterPayload = result.state.canonicalTimeline.audioPayload(for: voId)!
        XCTAssertEqual(afterPayload.volume, originalVolume)
        XCTAssertFalse(result.shouldPushSnapshot)
    }

    // MARK: - 11. setProjectMusic Resets Stale Selection

    func testSetProjectMusic_resetsStaleSelection() {
        var state = loadState()

        // Add music and select it
        let withMusic = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: .imported(assetId: ProjectAssetID()), sourceDurationUs: 5_000_000)
        )
        state = withMusic.state
        let oldMusicId = state.canonicalTimeline.musicItem!.id
        state.selection = .audio(itemId: oldMusicId)

        // Replace music — old selection should be cleared
        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: musicAssetRef, sourceDurationUs: musicDuration)
        )

        // Selection should be reset since old item is gone
        if case .audio(let selectedId) = result.state.selection {
            XCTAssertNotEqual(selectedId, oldMusicId, "Selection should not point to deleted item")
        }
        // New music item should exist
        XCTAssertNotNil(result.state.canonicalTimeline.musicItem)
    }

    // MARK: - musicPayload() returns role == .music

    func testMusicPayload_hasRoleMusic() {
        let state = loadState()
        let result = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: musicAssetRef, sourceDurationUs: musicDuration)
        )
        XCTAssertEqual(result.state.canonicalTimeline.musicPayload()?.role, .music)
    }

    // MARK: - AudioExportPlan multi-item

    func testAudioExportPlan_multipleItems() {
        let plan = AudioExportPlan(
            items: [
                AudioExportItemPlan(
                    itemId: UUID(), role: .music,
                    url: URL(fileURLWithPath: "/tmp/m.mp3"),
                    startTimeSeconds: 0, volume: 1.0
                ),
                AudioExportItemPlan(
                    itemId: UUID(), role: .sfx,
                    url: URL(fileURLWithPath: "/tmp/s.wav"),
                    startTimeSeconds: 1.0, volume: 0.5
                ),
            ]
        )
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.items[0].role, .music)
        XCTAssertEqual(plan.items[1].role, .sfx)
    }

    func testAudioExportPlan_twoSameRole_doNotCollapse() {
        let plan = AudioExportPlan(
            items: [
                AudioExportItemPlan(
                    itemId: UUID(), role: .music,
                    url: URL(fileURLWithPath: "/tmp/m1.mp3"),
                    startTimeSeconds: 0, volume: 1.0
                ),
                AudioExportItemPlan(
                    itemId: UUID(), role: .music,
                    url: URL(fileURLWithPath: "/tmp/m2.mp3"),
                    startTimeSeconds: 5.0, volume: 0.8
                ),
            ]
        )
        XCTAssertEqual(plan.items.count, 2, "Two items of same role should not collapse")
    }

    // MARK: - removeProjectMusic preserves non-music selection

    func testRemoveProjectMusic_preservesVoiceoverSelection() {
        var state = loadState()

        // Add voiceover and select it
        let voId = injectVoiceoverItem(into: &state)
        state.selection = .audio(itemId: voId)

        // Add music
        let withMusic = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: musicAssetRef, sourceDurationUs: musicDuration)
        )
        var stateWithBoth = withMusic.state
        // Re-select voiceover (setProjectMusic may have reset selection if it was music)
        stateWithBoth.selection = .audio(itemId: voId)

        // Remove music — voiceover selection must survive
        let result = EditorReducer.reduce(state: stateWithBoth, action: .removeProjectMusic)

        XCTAssertNotNil(result.state.canonicalTimeline.audioPayload(for: voId),
                        "Voiceover item should survive removeProjectMusic")
        if case .audio(let selectedId) = result.state.selection {
            XCTAssertEqual(selectedId, voId, "Selection should still point to voiceover")
        } else {
            XCTFail("Selection should remain .audio(voiceover), got \(result.state.selection)")
        }
    }

    func testRemoveProjectMusic_clearsSelectionForRemovedMusicItem() {
        var state = loadState()

        // Add music and select it
        let withMusic = EditorReducer.reduce(
            state: state,
            action: .setProjectMusic(assetRef: musicAssetRef, sourceDurationUs: musicDuration)
        )
        state = withMusic.state
        let musicId = state.canonicalTimeline.musicItem!.id
        state.selection = .audio(itemId: musicId)

        // Remove music — selection should be cleared since selected item is gone
        let result = EditorReducer.reduce(state: state, action: .removeProjectMusic)
        XCTAssertEqual(result.state.selection, .none, "Selection of removed music item should be cleared")
    }

    // MARK: - removeProjectMusic with no music is no-op

    func testRemoveProjectMusic_noMusic_noop() {
        let state = loadState()
        let result = EditorReducer.reduce(state: state, action: .removeProjectMusic)
        XCTAssertFalse(result.shouldPushSnapshot, "No music to remove = no snapshot")
    }

    // MARK: - PR3 Bridge: AudioExportPlan.toLegacyConfig()

    func testAudioExportPlan_toLegacyConfig_mapsFirstMusicAndVoiceover() {
        let musicURL = URL(fileURLWithPath: "/tmp/music.mp3")
        let voiceoverURL = URL(fileURLWithPath: "/tmp/vo.mp3")
        let sfxURL = URL(fileURLWithPath: "/tmp/sfx.wav")

        let plan = AudioExportPlan(items: [
            AudioExportItemPlan(itemId: UUID(), role: .music, url: musicURL, startTimeSeconds: 0, volume: 0.8, trimStartSeconds: 1.0, trimEndSeconds: 5.0),
            AudioExportItemPlan(itemId: UUID(), role: .voiceover, url: voiceoverURL, startTimeSeconds: 2.0, volume: 0.6),
            AudioExportItemPlan(itemId: UUID(), role: .sfx, url: sfxURL, startTimeSeconds: 3.0, volume: 1.0),
            AudioExportItemPlan(itemId: UUID(), role: .music, url: URL(fileURLWithPath: "/tmp/music2.mp3"), startTimeSeconds: 10, volume: 0.5),
        ], includeOriginalFromVideoSlots: false, originalDefaultVolume: 0.7)

        let config = plan.toLegacyConfig()
        XCTAssertEqual(config.music?.url, musicURL)
        XCTAssertEqual(config.music?.volume, 0.8)
        XCTAssertEqual(config.music?.trimStartSeconds, 1.0)
        XCTAssertEqual(config.music?.trimEndSeconds, 5.0)
        XCTAssertEqual(config.voiceover?.url, voiceoverURL)
        XCTAssertEqual(config.voiceover?.volume, 0.6)
        XCTAssertFalse(config.includeOriginalFromVideoSlots)
        XCTAssertEqual(config.originalDefaultVolume, 0.7)
    }

    func testAudioExportPlan_toLegacyConfig_emptyPlan() {
        let plan = AudioExportPlan()
        let config = plan.toLegacyConfig()
        XCTAssertNil(config.music)
        XCTAssertNil(config.voiceover)
        XCTAssertTrue(config.includeOriginalFromVideoSlots)
    }

    func testAudioExportPlan_toLegacyConfig_sfxOnly_noMusicNoVoiceover() {
        let plan = AudioExportPlan(items: [
            AudioExportItemPlan(itemId: UUID(), role: .sfx, url: URL(fileURLWithPath: "/tmp/sfx.wav"), startTimeSeconds: 0, volume: 1.0),
        ])
        let config = plan.toLegacyConfig()
        XCTAssertNil(config.music)
        XCTAssertNil(config.voiceover)
    }

    func testAudioExportConfig_toPlan_roundTrip() {
        let musicURL = URL(fileURLWithPath: "/tmp/music.mp3")
        let voiceoverURL = URL(fileURLWithPath: "/tmp/vo.mp3")
        let config = AudioExportConfig(
            music: AudioTrackConfig(url: musicURL, startTimeSeconds: 1.0, volume: 0.9, trimStartSeconds: 2.0, trimEndSeconds: 8.0),
            voiceover: AudioTrackConfig(url: voiceoverURL, startTimeSeconds: 0, volume: 0.7),
            includeOriginalFromVideoSlots: false,
            originalDefaultVolume: 0.5
        )

        let plan = config.toPlan()
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.items[0].role, .music)
        XCTAssertEqual(plan.items[0].url, musicURL)
        XCTAssertEqual(plan.items[0].volume, 0.9)
        XCTAssertEqual(plan.items[0].trimStartSeconds, 2.0)
        XCTAssertEqual(plan.items[1].role, .voiceover)
        XCTAssertEqual(plan.items[1].url, voiceoverURL)
        XCTAssertFalse(plan.includeOriginalFromVideoSlots)
        XCTAssertEqual(plan.originalDefaultVolume, 0.5)

        // Round-trip back to config
        let roundTripped = plan.toLegacyConfig()
        XCTAssertEqual(roundTripped.music?.url, musicURL)
        XCTAssertEqual(roundTripped.voiceover?.url, voiceoverURL)
        XCTAssertEqual(roundTripped.includeOriginalFromVideoSlots, config.includeOriginalFromVideoSlots)
    }
}
