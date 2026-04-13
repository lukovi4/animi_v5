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

    // MARK: - Helpers

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
