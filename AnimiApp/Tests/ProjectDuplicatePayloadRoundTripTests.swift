import XCTest
import TVECore
@testable import AnimiApp

/// PR8: Round-trip tests for AudioPayload through save/load and duplication paths.
final class ProjectDuplicatePayloadRoundTripTests: XCTestCase {

    private var tempDir: URL!
    private var persistence: FileProjectPersistenceStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        persistence = FileProjectPersistenceStore(rootDirectoryURL: tempDir)
        try! persistence.ensureDirectoriesExist()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        persistence = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - AudioPayload Codable Round-Trip

    func testAudioPayload_encodeDecode_preservesAllFields() throws {
        let assetId = ProjectAssetID()
        let original = AudioPayload(
            assetRef: .imported(assetId: assetId),
            sourceDurationUs: 15_000_000,
            trimStartUs: 2_000_000,
            trimEndUs: 12_000_000,
            volume: 0.65
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioPayload.self, from: data)

        XCTAssertEqual(decoded.assetRef, original.assetRef)
        XCTAssertEqual(decoded.sourceDurationUs, 15_000_000)
        XCTAssertEqual(decoded.trimStartUs, 2_000_000)
        XCTAssertEqual(decoded.trimEndUs, 12_000_000)
        XCTAssertEqual(decoded.volume, 0.65)
    }

    func testAudioPayload_bundledRef_encodeDecode() throws {
        let original = AudioPayload(
            assetRef: .bundled(id: "track_01"),
            sourceDurationUs: 5_000_000,
            trimStartUs: 0,
            trimEndUs: 5_000_000,
            volume: 1.0
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioPayload.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - TimelinePayload.audio Codable Round-Trip

    func testTimelinePayloadAudio_encodeDecode() throws {
        let payload = TimelinePayload.audio(AudioPayload(
            assetRef: .imported(assetId: ProjectAssetID()),
            sourceDurationUs: 8_000_000,
            trimStartUs: 500_000,
            trimEndUs: 7_500_000,
            volume: 0.9
        ))

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TimelinePayload.self, from: data)

        XCTAssertEqual(decoded, payload)
        if case .audio(let ap) = decoded {
            XCTAssertEqual(ap.sourceDurationUs, 8_000_000)
            XCTAssertEqual(ap.trimStartUs, 500_000)
            XCTAssertEqual(ap.trimEndUs, 7_500_000)
            XCTAssertEqual(ap.volume, 0.9)
        } else {
            XCTFail("Expected .audio payload")
        }
    }

    // MARK: - CanonicalTimeline with Music Save/Load Round-Trip

    func testCanonicalTimeline_withMusic_roundTrips() throws {
        let assetId = ProjectAssetID()
        var timeline = CanonicalTimeline.empty()

        // Add scene
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(TimelineItem(
            payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 3_000_000
        ))

        // Add music
        let audioPid = UUID()
        timeline.payloads[audioPid] = .audio(AudioPayload(
            assetRef: .imported(assetId: assetId),
            sourceDurationUs: 10_000_000,
            trimStartUs: 1_000_000,
            trimEndUs: 9_000_000,
            volume: 0.5
        ))
        var audioTrack = Track(kind: .audio)
        audioTrack.items.append(TimelineItem(
            payloadId: audioPid, kind: .audioClip, startUs: 0, durationUs: 8_000_000
        ))
        timeline.tracks.append(audioTrack)

        // Encode/decode
        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(CanonicalTimeline.self, from: data)

        XCTAssertNotNil(decoded.audioTrack)
        XCTAssertNotNil(decoded.musicItem)
        XCTAssertEqual(decoded.musicItem?.durationUs, 8_000_000)

        let payload = decoded.musicPayload()
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.sourceDurationUs, 10_000_000)
        XCTAssertEqual(payload?.trimStartUs, 1_000_000)
        XCTAssertEqual(payload?.trimEndUs, 9_000_000)
        XCTAssertEqual(payload?.volume, 0.5)
        XCTAssertEqual(payload?.assetRef, .imported(assetId: assetId))
    }

    // MARK: - PR9: TextPayload Codable Round-Trip

    func testTextPayload_encodeDecode_preservesAllFields() throws {
        let original = TextPayload(
            text: "Hello World",
            fontFamily: "Helvetica-Bold",
            fontSize: 48,
            colorHex: "#FF3B30",
            centerX: 0.3,
            centerY: 0.7
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TextPayload.self, from: data)

        XCTAssertEqual(decoded.text, "Hello World")
        XCTAssertEqual(decoded.fontFamily, "Helvetica-Bold")
        XCTAssertEqual(decoded.fontSize, 48)
        XCTAssertEqual(decoded.colorHex, "#FF3B30")
        XCTAssertEqual(decoded.centerX, 0.3)
        XCTAssertEqual(decoded.centerY, 0.7)
    }

    func testTimelinePayloadText_encodeDecode() throws {
        let payload = TimelinePayload.text(TextPayload(
            text: "Overlay",
            fontFamily: nil,
            fontSize: 32,
            colorHex: "#FFFFFF",
            centerX: 0.5,
            centerY: 0.5
        ))

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TimelinePayload.self, from: data)

        XCTAssertEqual(decoded, payload)
        if case .text(let tp) = decoded {
            XCTAssertEqual(tp.text, "Overlay")
            XCTAssertEqual(tp.fontSize, 32)
            XCTAssertEqual(tp.centerX, 0.5)
            XCTAssertEqual(tp.centerY, 0.5)
        } else {
            XCTFail("Expected .text payload")
        }
    }

    func testCanonicalTimeline_withTextOverlay_roundTrips() throws {
        var timeline = CanonicalTimeline.empty()

        // Add scene
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(TimelineItem(
            payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 3_000_000
        ))

        // Add text overlay
        let textPid = UUID()
        timeline.payloads[textPid] = .text(TextPayload(
            text: "Title",
            fontFamily: "Avenir",
            fontSize: 40,
            colorHex: "#00FF00",
            centerX: 0.2,
            centerY: 0.8
        ))
        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(TimelineItem(
            payloadId: textPid, kind: .text, startUs: 500_000, durationUs: 2_000_000
        ))
        timeline.tracks.append(overlayTrack)

        // Encode/decode
        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(CanonicalTimeline.self, from: data)

        XCTAssertNotNil(decoded.overlayTrack)
        XCTAssertEqual(decoded.textItems.count, 1)
        XCTAssertEqual(decoded.textItems.first?.startUs, 500_000)
        XCTAssertEqual(decoded.textItems.first?.durationUs, 2_000_000)

        let textItem = decoded.textItems.first!
        let payload = decoded.textPayload(for: textItem.id)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.text, "Title")
        XCTAssertEqual(payload?.fontFamily, "Avenir")
        XCTAssertEqual(payload?.fontSize, 40)
        XCTAssertEqual(payload?.colorHex, "#00FF00")
        XCTAssertEqual(payload?.centerX, 0.2)
        XCTAssertEqual(payload?.centerY, 0.8)
    }

    // MARK: - Draft Persistence Round-Trip with Music

    func testDraftPersistence_withMusic_roundTrips() async throws {
        let assetId = ProjectAssetID()
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_music"))

        var timeline = draft.canonicalTimeline

        // Add audio track
        let audioPid = UUID()
        timeline.payloads[audioPid] = .audio(AudioPayload(
            assetRef: .imported(assetId: assetId),
            sourceDurationUs: 6_000_000,
            trimStartUs: 500_000,
            trimEndUs: 5_500_000,
            volume: 0.8
        ))
        var audioTrack = Track(kind: .audio)
        audioTrack.items.append(TimelineItem(
            payloadId: audioPid, kind: .audioClip, startUs: 0, durationUs: 5_000_000
        ))
        timeline.tracks.append(audioTrack)
        draft.canonicalTimeline = timeline

        // Register asset
        draft.assetRegistry.register(ProjectAssetDescriptor(
            assetId: assetId, mediaKind: .audio, storagePath: "Media/UserMedia/song.mp3"
        ))

        // Save
        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let materialized = try await persistence.materializeSavedProject(slot)
        let savedId = materialized.draft.id

        // Load
        let loaded = await persistence.loadSavedProject(projectId: savedId)
        XCTAssertNotNil(loaded)

        let loadedPayload = loaded!.draft.canonicalTimeline.musicPayload()
        XCTAssertNotNil(loadedPayload)
        XCTAssertEqual(loadedPayload?.sourceDurationUs, 6_000_000)
        XCTAssertEqual(loadedPayload?.trimStartUs, 500_000)
        XCTAssertEqual(loadedPayload?.trimEndUs, 5_500_000)
        XCTAssertEqual(loadedPayload?.volume, 0.8)
        XCTAssertEqual(loadedPayload?.assetRef, .imported(assetId: assetId))
    }

    // MARK: - PR9: Draft Persistence Round-Trip with Text Overlay

    func testDraftPersistence_withTextOverlay_roundTrips() async throws {
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_text"))

        var timeline = draft.canonicalTimeline

        // Add text overlay track
        let textPid = UUID()
        timeline.payloads[textPid] = .text(TextPayload(
            text: "My Title",
            fontFamily: "Helvetica",
            fontSize: 36,
            colorHex: "#FF0000",
            centerX: 0.25,
            centerY: 0.75
        ))
        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(TimelineItem(
            payloadId: textPid, kind: .text, startUs: 1_000_000, durationUs: 2_000_000
        ))
        timeline.tracks.append(overlayTrack)
        draft.canonicalTimeline = timeline

        // Save
        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let materialized = try await persistence.materializeSavedProject(slot)
        let savedId = materialized.draft.id

        // Load
        let loaded = await persistence.loadSavedProject(projectId: savedId)
        XCTAssertNotNil(loaded)

        let loadedTimeline = loaded!.draft.canonicalTimeline
        XCTAssertNotNil(loadedTimeline.overlayTrack)
        XCTAssertEqual(loadedTimeline.textItems.count, 1)

        let loadedItem = loadedTimeline.textItems.first!
        XCTAssertEqual(loadedItem.startUs, 1_000_000)
        XCTAssertEqual(loadedItem.durationUs, 2_000_000)

        let loadedPayload = loadedTimeline.textPayload(for: loadedItem.id)
        XCTAssertNotNil(loadedPayload)
        XCTAssertEqual(loadedPayload?.text, "My Title")
        XCTAssertEqual(loadedPayload?.fontFamily, "Helvetica")
        XCTAssertEqual(loadedPayload?.fontSize, 36)
        XCTAssertEqual(loadedPayload?.colorHex, "#FF0000")
        XCTAssertEqual(loadedPayload?.centerX, 0.25)
        XCTAssertEqual(loadedPayload?.centerY, 0.75)
    }
}
