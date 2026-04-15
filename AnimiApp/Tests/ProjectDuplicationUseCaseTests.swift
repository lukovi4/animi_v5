import XCTest
import TVECore
@testable import AnimiApp

/// Tests for ProjectDuplicationUseCase.
/// Uses real file-backed persistence via ProjectStorageActor.
final class ProjectDuplicationUseCaseTests: XCTestCase {

    private var storageActor: ProjectStorageActor!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = FileProjectPersistenceStore(rootDirectoryURL: tempDir)
        let media = FileProjectMediaStore(rootDirectoryURL: tempDir)
        try! persistence.ensureDirectoriesExist()
        storageActor = ProjectStorageActor(persistence: persistence, media: media)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        storageActor = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testDuplicate_createsNewProjectId() async throws {
        let sourceId = try await createSavedProject(origin: .template(templateId: "tpl_1"))

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        XCTAssertNotEqual(newId, sourceId)
    }

    func testDuplicate_setsCorrectOrigin() async throws {
        let sourceId = try await createSavedProject(origin: .template(templateId: "tpl_1"))

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        let record = await storageActor.loadSavedProject(projectId: newId)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.draft.origin, .duplicate(sourceProjectId: sourceId))
    }

    func testDuplicate_preservesName() async throws {
        let sourceId = try await createSavedProject(
            origin: .template(templateId: "tpl_1"),
            name: "My Video"
        )

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        let record = await storageActor.loadSavedProject(projectId: newId)
        XCTAssertEqual(record?.draft.name, "My Video")
    }

    func testDuplicate_throwsForMissingSource() async {
        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)

        do {
            _ = try await useCase.execute(sourceProjectId: UUID())
            XCTFail("Expected error for missing source project")
        } catch {
            XCTAssertTrue(error is ProjectDuplicationError)
        }
    }

    func testDuplicate_appearsInSummaries() async throws {
        let sourceId = try await createSavedProject(origin: .template(templateId: "tpl_1"))

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        let summaries = await storageActor.allSavedProjectSummaries()
        let ids = summaries.map(\.projectId)
        XCTAssertTrue(ids.contains(sourceId))
        XCTAssertTrue(ids.contains(newId))
    }

    // MARK: - Missing Media Duplication

    func testDuplicate_missingMediaSource_stillCreatesDuplicate() async throws {
        let sourceId = try await createSavedProjectWithMedia()

        // Delete the underlying media file to simulate missing media
        try deleteAllMediaFiles()

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        XCTAssertNotEqual(newId, sourceId, "Duplicate should succeed even with missing media")
    }

    func testDuplicate_missingMediaSource_preservesDuplicateOrigin() async throws {
        let sourceId = try await createSavedProjectWithMedia()
        try deleteAllMediaFiles()

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        let record = await storageActor.loadSavedProject(projectId: newId)
        XCTAssertEqual(record?.draft.origin, .duplicate(sourceProjectId: sourceId))
    }

    func testDuplicate_missingMediaSource_appearsInSummaries() async throws {
        let sourceId = try await createSavedProjectWithMedia()
        try deleteAllMediaFiles()

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        let summaries = await storageActor.allSavedProjectSummaries()
        let ids = summaries.map(\.projectId)
        XCTAssertTrue(ids.contains(newId))
        XCTAssertTrue(ids.contains(sourceId))
    }

    func testDuplicate_missingMediaSource_doesNotRegressHealthyAssets() async throws {
        // Create a project with two media files
        let sourceId = try await createSavedProjectWithTwoMedia()

        // Delete only one media file — the other should still be copied
        let userMediaDir = tempDir.appendingPathComponent("Media/UserMedia")
        let files = try FileManager.default.contentsOfDirectory(
            at: userMediaDir,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count >= 2 else {
            XCTFail("Expected at least 2 media files")
            return
        }
        // Delete only the first file
        try FileManager.default.removeItem(at: files[0])

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        let record = await storageActor.loadSavedProject(projectId: newId)
        XCTAssertNotNil(record)

        // The duplicated draft should have 2 asset descriptors (both minted with fresh IDs)
        let referencedIds = record!.draft.assetRegistry.assetIds(referencedBy: record!.draft)
        XCTAssertEqual(referencedIds.count, 2, "Both assets should be represented in duplicate")

        // But only 1 file should actually exist on disk (the healthy one was copied)
        let newPaths = record!.draft.assetRegistry.storagePaths(referencedBy: record!.draft)
        let existingFiles = newPaths.filter { path in
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(path).path)
        }
        XCTAssertEqual(existingFiles.count, 1, "Only the healthy source file should produce a copied file")
    }

    // MARK: - Music Duplication (PR8)

    func testDuplicate_withMusic_preservesPayloadFields() async throws {
        let sourceId = try await createSavedProjectWithMusic()

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        let record = await storageActor.loadSavedProject(projectId: newId)
        XCTAssertNotNil(record)

        let payload = record!.draft.canonicalTimeline.musicPayload()
        XCTAssertNotNil(payload, "Duplicated project should have music payload")
        XCTAssertEqual(payload?.sourceDurationUs, 10_000_000)
        XCTAssertEqual(payload?.trimStartUs, 1_000_000)
        XCTAssertEqual(payload?.trimEndUs, 8_000_000)
        XCTAssertEqual(payload?.volume, 0.7)
    }

    func testDuplicate_withMusic_getsIndependentAssetId() async throws {
        let sourceId = try await createSavedProjectWithMusic()
        let sourceRecord = await storageActor.loadSavedProject(projectId: sourceId)
        let sourcePayload = sourceRecord!.draft.canonicalTimeline.musicPayload()!
        guard case .imported(let sourceAssetId) = sourcePayload.assetRef else {
            XCTFail("Expected imported asset ref")
            return
        }

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        let newRecord = await storageActor.loadSavedProject(projectId: newId)
        let newPayload = newRecord!.draft.canonicalTimeline.musicPayload()!
        guard case .imported(let newAssetId) = newPayload.assetRef else {
            XCTFail("Expected imported asset ref in duplicate")
            return
        }

        XCTAssertNotEqual(newAssetId, sourceAssetId, "Duplicate should have fresh asset ID")
    }

    // MARK: - Text Overlay Duplication (PR9)

    func testDuplicate_withTextOverlay_preservesPayloadFields() async throws {
        let sourceId = try await createSavedProjectWithTextOverlay()

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        let record = await storageActor.loadSavedProject(projectId: newId)
        XCTAssertNotNil(record)

        let timeline = record!.draft.canonicalTimeline
        XCTAssertNotNil(timeline.overlayTrack, "Duplicated project should have overlay track")
        XCTAssertEqual(timeline.textItems.count, 1, "Duplicated project should have text item")

        let item = timeline.textItems.first!
        XCTAssertEqual(item.startUs, 500_000)
        XCTAssertEqual(item.durationUs, 2_000_000)

        let payload = timeline.textPayload(for: item.id)
        XCTAssertNotNil(payload, "Duplicated project should have text payload")
        XCTAssertEqual(payload?.text, "Duplicated Text")
        XCTAssertEqual(payload?.fontFamily, "Avenir-Heavy")
        XCTAssertEqual(payload?.fontSize, 42)
        XCTAssertEqual(payload?.colorHex, "#007AFF")
        XCTAssertEqual(payload?.centerX, 0.3)
        XCTAssertEqual(payload?.centerY, 0.7)
    }

    // MARK: - Sticker Overlay Duplication (PR10)

    func testDuplicate_withStickerOverlay_preservesPayloadFields() async throws {
        let sourceId = try await createSavedProjectWithStickerOverlay()

        let useCase = ProjectDuplicationUseCase(persistence: storageActor, mediaWriter: storageActor)
        let newId = try await useCase.execute(sourceProjectId: sourceId)

        let record = await storageActor.loadSavedProject(projectId: newId)
        XCTAssertNotNil(record)

        let timeline = record!.draft.canonicalTimeline
        XCTAssertNotNil(timeline.overlayTrack, "Duplicated project should have overlay track")
        XCTAssertEqual(timeline.stickerItems.count, 1, "Duplicated project should have sticker item")

        let item = timeline.stickerItems.first!
        XCTAssertEqual(item.startUs, 300_000)
        XCTAssertEqual(item.durationUs, 1_500_000)

        let payload = timeline.stickerPayload(for: item.id)
        XCTAssertNotNil(payload, "Duplicated project should have sticker payload")
        XCTAssertEqual(payload?.stickerId, "emoji_star")
        XCTAssertEqual(payload?.centerX, 0.2)
        XCTAssertEqual(payload?.centerY, 0.8)
    }

    // MARK: - Helpers

    private func createSavedProjectWithStickerOverlay() async throws -> UUID {
        var draft = ProjectDraft(origin: .template(templateId: "tpl_sticker"))

        var timeline = CanonicalTimeline.empty()
        let scenePayloadId = UUID()
        timeline.payloads[scenePayloadId] = .scene(ScenePayload(sceneTypeId: "scene_0"))
        timeline.tracks[0].items.append(TimelineItem(
            payloadId: scenePayloadId, kind: .scene, startUs: nil, durationUs: 5_000_000
        ))

        let stickerPayloadId = UUID()
        timeline.payloads[stickerPayloadId] = .sticker(StickerPayload(
            stickerId: "emoji_star",
            centerX: 0.2,
            centerY: 0.8
        ))
        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(TimelineItem(
            payloadId: stickerPayloadId, kind: .sticker, startUs: 300_000, durationUs: 1_500_000
        ))
        timeline.tracks.append(overlayTrack)

        draft.canonicalTimeline = timeline

        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let materialized = try await storageActor.materializeSavedProject(slot)
        return materialized.draft.id
    }

    private func createSavedProjectWithTextOverlay() async throws -> UUID {
        var draft = ProjectDraft(origin: .template(templateId: "tpl_text"))

        var timeline = CanonicalTimeline.empty()
        let scenePayloadId = UUID()
        timeline.payloads[scenePayloadId] = .scene(ScenePayload(sceneTypeId: "scene_0"))
        timeline.tracks[0].items.append(TimelineItem(
            payloadId: scenePayloadId, kind: .scene, startUs: nil, durationUs: 5_000_000
        ))

        let textPayloadId = UUID()
        timeline.payloads[textPayloadId] = .text(TextPayload(
            text: "Duplicated Text",
            fontFamily: "Avenir-Heavy",
            fontSize: 42,
            colorHex: "#007AFF",
            centerX: 0.3,
            centerY: 0.7
        ))
        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(TimelineItem(
            payloadId: textPayloadId, kind: .text, startUs: 500_000, durationUs: 2_000_000
        ))
        timeline.tracks.append(overlayTrack)

        draft.canonicalTimeline = timeline

        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let materialized = try await storageActor.materializeSavedProject(slot)
        return materialized.draft.id
    }

    private func createSavedProjectWithMusic() async throws -> UUID {
        var registry = ProjectAssetRegistry()
        let (assetId, audioRef) = try seedAudioMedia(filename: "test_song.mp3", into: &registry)

        var draft = ProjectDraft(origin: .template(templateId: "tpl_music"))

        // Build timeline with music
        var timeline = CanonicalTimeline.empty()
        let scenePayloadId = UUID()
        timeline.payloads[scenePayloadId] = .scene(ScenePayload(sceneTypeId: "scene_0"))
        timeline.tracks[0].items.append(TimelineItem(
            payloadId: scenePayloadId, kind: .scene, startUs: nil, durationUs: 3_000_000
        ))

        let audioPayloadId = UUID()
        timeline.payloads[audioPayloadId] = .audio(AudioPayload(
            assetRef: .imported(assetId: assetId),
            sourceDurationUs: 10_000_000,
            trimStartUs: 1_000_000,
            trimEndUs: 8_000_000,
            volume: 0.7
        ))
        var audioTrack = Track(kind: .audio)
        audioTrack.items.append(TimelineItem(
            payloadId: audioPayloadId, kind: .audioClip, startUs: 0, durationUs: 7_000_000
        ))
        timeline.tracks.append(audioTrack)

        draft.canonicalTimeline = timeline
        draft.assetRegistry = registry

        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let materialized = try await storageActor.materializeSavedProject(slot)
        return materialized.draft.id
    }

    private func seedAudioMedia(
        filename: String,
        into registry: inout ProjectAssetRegistry
    ) throws -> (ProjectAssetID, MediaRef) {
        let relPath = "Media/UserMedia/\(filename)"
        let fileURL = tempDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stub_audio:\(filename)".utf8).write(to: fileURL)

        let assetId = ProjectAssetID()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .audio,
            storagePath: relPath
        ))
        return (assetId, MediaRef(storagePath: relPath, mediaKind: .audio, assetId: assetId))
    }

    private func createSavedProject(origin: ProjectOrigin, name: String? = nil) async throws -> UUID {
        let draft = ProjectDraft(origin: origin, name: name)
        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let materialized = try await storageActor.materializeSavedProject(slot)
        return materialized.draft.id
    }

    /// Creates a saved project with one user-media asset seeded on disk.
    private func createSavedProjectWithMedia() async throws -> UUID {
        var registry = ProjectAssetRegistry()
        let (_, ref) = try seedUserMedia(filename: "test_photo.jpg", into: &registry)

        let instanceId = UUID()
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: ref, placement: .defaultCover)
        ]

        var draft = ProjectDraft(origin: .template(templateId: "tpl_1"))
        draft.sceneInstanceStates[instanceId] = sceneState
        draft.assetRegistry = registry

        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let materialized = try await storageActor.materializeSavedProject(slot)
        return materialized.draft.id
    }

    /// Creates a saved project with two user-media assets seeded on disk.
    private func createSavedProjectWithTwoMedia() async throws -> UUID {
        var registry = ProjectAssetRegistry()
        let (_, ref1) = try seedUserMedia(filename: "photo_a.jpg", into: &registry)
        let (_, ref2) = try seedUserMedia(filename: "photo_b.jpg", into: &registry)

        let instanceId = UUID()
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: ref1, placement: .defaultCover),
            "block2": .photo(mediaRef: ref2, placement: .defaultCover)
        ]

        var draft = ProjectDraft(origin: .template(templateId: "tpl_1"))
        draft.sceneInstanceStates[instanceId] = sceneState
        draft.assetRegistry = registry

        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let materialized = try await storageActor.materializeSavedProject(slot)
        return materialized.draft.id
    }

    private func seedUserMedia(
        filename: String,
        into registry: inout ProjectAssetRegistry
    ) throws -> (ProjectAssetID, MediaRef) {
        let relPath = "Media/UserMedia/\(filename)"
        let fileURL = tempDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stub:\(filename)".utf8).write(to: fileURL)

        let assetId = ProjectAssetID()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: relPath
        ))
        return (assetId, MediaRef(storagePath: relPath, mediaKind: .photo, assetId: assetId))
    }

    private func deleteAllMediaFiles() throws {
        let mediaDir = tempDir.appendingPathComponent("Media")
        if FileManager.default.fileExists(atPath: mediaDir.path) {
            let contents = try FileManager.default.contentsOfDirectory(
                at: mediaDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for subdir in contents {
                let files = try FileManager.default.contentsOfDirectory(
                    at: subdir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for file in files {
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
