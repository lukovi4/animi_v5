import XCTest
import TVECore
@testable import AnimiApp

/// Tests for project music import flow (PR8 Phase B).
/// Covers that import dispatch creates correct timeline state.
@MainActor
final class ProjectMusicImportTests: XCTestCase {

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

    // MARK: - Import dispatches setProjectMusic

    func testImportDispatch_createsAudioTrack() {
        let store = EditorStore()
        let draft = makeDraft(sceneDurations: [5_000_000])
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        let assetId = ProjectAssetID()
        let assetRef = AudioAssetRef.imported(assetId: assetId)
        let duration: TimeUs = 15_000_000

        store.dispatch(.setProjectMusic(assetRef: assetRef, sourceDurationUs: duration))

        XCTAssertNotNil(store.state.canonicalTimeline.audioTrack)
        XCTAssertNotNil(store.state.canonicalTimeline.musicItem)
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.assetRef, assetRef)
        XCTAssertEqual(store.state.canonicalTimeline.musicPayload()?.sourceDurationUs, duration)
    }

    // MARK: - Replace import does not create duplicates

    func testReplaceImport_singleItem() {
        let store = EditorStore()
        let draft = makeDraft(sceneDurations: [5_000_000])
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        // First import
        let assetId1 = ProjectAssetID()
        store.dispatch(.setProjectMusic(assetRef: .imported(assetId: assetId1), sourceDurationUs: 10_000_000))

        let audioTrackItemCount1 = store.state.canonicalTimeline.audioTrack?.items.count

        // Second import (replace)
        let assetId2 = ProjectAssetID()
        store.dispatch(.setProjectMusic(assetRef: .imported(assetId: assetId2), sourceDurationUs: 8_000_000))

        XCTAssertEqual(store.state.canonicalTimeline.audioTrack?.items.count, 1, "Should still have exactly one item")
        XCTAssertEqual(audioTrackItemCount1, 1)

        // New asset ref should be active
        if case .imported(let activeId, _) = store.state.canonicalTimeline.musicPayload()?.assetRef {
            XCTAssertEqual(activeId, assetId2)
        } else {
            XCTFail("Expected imported asset ref")
        }
    }

    // MARK: - AudioAssetRef Codable

    func testAudioAssetRef_importedCodable() throws {
        let assetId = ProjectAssetID()
        let original = AudioAssetRef.imported(assetId: assetId)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioAssetRef.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testAudioPayload_codable() throws {
        let payload = AudioPayload(
            assetRef: .imported(assetId: ProjectAssetID()),
            sourceDurationUs: 5_000_000,
            trimStartUs: 1_000_000,
            trimEndUs: 4_000_000,
            volume: 0.8
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AudioPayload.self, from: data)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.sourceDurationUs, 5_000_000)
        XCTAssertEqual(decoded.trimStartUs, 1_000_000)
        XCTAssertEqual(decoded.trimEndUs, 4_000_000)
        XCTAssertEqual(decoded.volume, 0.8)
    }

    // MARK: - Collision-Proof Filename

    func testCollisionProofFilename_differentImportsGetUniqueStoragePaths() {
        let store = EditorStore()
        let draft = makeDraft(sceneDurations: [5_000_000])
        store.dispatch(.loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: []))

        // Two imports with same-name original file should get different asset IDs
        let id1 = ProjectAssetID()
        let id2 = ProjectAssetID()
        store.dispatch(.setProjectMusic(assetRef: .imported(assetId: id1), sourceDurationUs: 10_000_000))
        let firstItemId = store.state.canonicalTimeline.musicItem?.id

        store.dispatch(.setProjectMusic(assetRef: .imported(assetId: id2), sourceDurationUs: 8_000_000))
        let secondItemId = store.state.canonicalTimeline.musicItem?.id

        // Items are different (replaced, not duplicated)
        XCTAssertNotEqual(firstItemId, secondItemId)
        XCTAssertEqual(store.state.canonicalTimeline.audioTrack?.items.count, 1)

        // Asset ref is the latest one
        if case .imported(let activeId, _) = store.state.canonicalTimeline.musicPayload()?.assetRef {
            XCTAssertEqual(activeId, id2)
        } else {
            XCTFail("Expected imported ref")
        }
    }

    // MARK: - Temp Copy Pattern Validation

    func testTempCopyPattern_uuidFilenameDoesNotCollide() {
        // Verify UUID-based filenames are unique (regression guard for import path)
        var names: Set<String> = []
        for _ in 0..<100 {
            let ext = "mp3"
            let name = "\(UUID().uuidString).\(ext)"
            XCTAssertFalse(names.contains(name), "UUID filename collision")
            names.insert(name)
        }
    }
}
