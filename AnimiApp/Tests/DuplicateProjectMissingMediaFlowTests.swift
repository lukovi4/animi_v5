import XCTest
import TVECore
@testable import AnimiApp

/// End-to-end integration test: exercises the real duplication chain on a source
/// project with missing media, then opens the materialized duplicate through
/// the normal `.savedProject(...)` bootstrap and verifies the missing-media
/// notice contract.
///
/// Chain exercised:
///   1. Create source saved project with media on disk
///   2. Delete the source media file (simulate missing media)
///   3. Duplicate via real `ProjectDuplicationUseCase.execute(...)`
///   4. Load the materialized duplicate via real `ProjectStorageActor`
///   5. Bootstrap `EditorSession` with `.savedProject(duplicatedId)`
///   6. Verify session opens (.ready), and media locator resolves to a
///      non-existent file, enabling the existing missing-media notice path
@MainActor
final class DuplicateProjectMissingMediaFlowTests: XCTestCase {

    private var storageActor: ProjectStorageActor!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup_missing_\(UUID().uuidString)")
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

    // MARK: - End-to-End: Duplicate With Missing Media → Open → Notice

    func testEndToEnd_duplicateWithMissingMedia_opensAndActivatesMissingMediaNotice() async throws {
        // 1. Create a source saved project with a real media file on disk.
        let (sourceId, instanceId, blockId) = try await createSourceProjectWithMedia()

        // 2. Delete the underlying media file to simulate missing media.
        try deleteAllUserMediaFiles()

        // 3. Duplicate via the real use case (exercises FileProjectMediaStore fix).
        let useCase = ProjectDuplicationUseCase(
            persistence: storageActor,
            mediaWriter: storageActor
        )
        let duplicatedId = try await useCase.execute(sourceProjectId: sourceId)
        XCTAssertNotEqual(duplicatedId, sourceId)

        // 4. Load the materialized duplicate via real storage.
        let duplicatedRecord = await storageActor.loadSavedProject(projectId: duplicatedId)
        let record = try XCTUnwrap(duplicatedRecord, "Duplicated project must be loadable")

        // Verify the duplicate has the correct origin
        XCTAssertEqual(record.draft.origin, .duplicate(sourceProjectId: sourceId))

        // Verify the duplicate has asset descriptors (minted broken refs)
        let referencedAssets = record.draft.assetRegistry.assetIds(referencedBy: record.draft)
        XCTAssertFalse(referencedAssets.isEmpty, "Duplicate should still have asset references")

        // Verify the duplicate's media file does NOT exist on disk (broken ref)
        let storagePaths = record.draft.assetRegistry.storagePaths(referencedBy: record.draft)
        for path in storagePaths {
            let url = tempDir.appendingPathComponent(path)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "Duplicated broken media file should not exist: \(path)"
            )
        }

        // 5. Bootstrap EditorSession with .savedProject(duplicatedId) using real
        //    storage actor for media resolution.
        let deps = makeSessionDeps(loadSavedProject: { [storageActor] id in
            await storageActor!.loadSavedProject(projectId: id)
        })
        let session = EditorSession(
            intent: .savedProject(projectId: duplicatedId),
            dependencies: deps
        )

        var bootstrapOutput: EditorSessionOutput?
        session.onOutput = { bootstrapOutput = $0 }

        await session.bootstrap()

        // Session must reach .ready — not .failed
        guard case .ready(let editor) = session.phase else {
            XCTFail("Expected .ready phase, got \(session.phase)")
            return
        }
        XCTAssertNil(editor.templateId, "Duplicate origin should have nil templateId")
        XCTAssertEqual(editor.activeDraftSlot.linkedSavedProjectId, duplicatedId)

        if case .bootstrapSucceeded = bootstrapOutput { /* OK */ }
        else { XCTFail("Expected .bootstrapSucceeded, got \(String(describing: bootstrapOutput))") }

        // 6. Verify the media locator produces a URL to a non-existent file.
        //    This is the signal that triggers missing-media detection at runtime.
        let duplicatedDraft = record.draft
        if let slots = duplicatedDraft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId,
           let slot = slots[blockId] {
            let resolvedURL = try await storageActor.absoluteURL(
                for: slot.mediaRef,
                registry: duplicatedDraft.assetRegistry
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: resolvedURL.path),
                "Resolved URL for broken media should point to non-existent file"
            )
        } else {
            XCTFail("Expected media slot in duplicated draft")
        }

        // 7. Simulate the controller reporting missing media (as EditorViewController
        //    does after scene load fails to find the file). This proves the existing
        //    missing-media notice contract activates for real duplicated artifacts.
        var emittedSummary: MissingMediaSummary?
        session.onOutput = {
            if case .missingMediaDetected(let s) = $0 { emittedSummary = s }
        }

        // Find the actual instance ID from the duplicated draft's timeline
        let dupInstanceId = try XCTUnwrap(
            duplicatedDraft.canonicalTimeline.sceneItems.first?.id,
            "Duplicated draft should have a scene item"
        )
        session.updateMissingMedia(for: dupInstanceId, failures: [blockId])

        XCTAssertNotNil(session.missingMediaSummary)
        XCTAssertTrue(session.missingMediaSummary!.hasFailedMedia)
        XCTAssertTrue(session.hasPendingMissingMediaNotice)
        XCTAssertNotNil(emittedSummary, "Should emit .missingMediaDetected")
    }

    // MARK: - Helpers

    /// Creates a saved project with one user-media asset on disk.
    /// Returns (projectId, sceneInstanceId, blockId).
    private func createSourceProjectWithMedia() async throws -> (UUID, UUID, String) {
        let blockId = "photo_block"
        let instanceId = UUID()

        var registry = ProjectAssetRegistry()
        let relPath = "Media/UserMedia/source_photo.jpg"
        let fileURL = tempDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("source-photo-data".utf8).write(to: fileURL)

        let assetId = ProjectAssetID()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: relPath
        ))
        let mediaRef = MediaRef(storagePath: relPath, mediaKind: .photo, assetId: assetId)

        // Build timeline with one scene
        var timeline = CanonicalTimeline.empty()
        let payloadId = UUID()
        timeline.payloads[payloadId] = .scene(ScenePayload(sceneTypeId: "scene_1"))
        timeline.tracks[0].items.append(
            TimelineItem(id: instanceId, payloadId: payloadId, kind: .scene, startUs: nil, durationUs: 3_000_000)
        )

        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            blockId: .photo(mediaRef: mediaRef, placement: .defaultCover)
        ]

        let draft = ProjectDraft(
            origin: .template(templateId: "tpl_source"),
            canonicalTimeline: timeline,
            sceneInstanceStates: [instanceId: sceneState],
            assetRegistry: registry
        )

        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: draft.origin),
            linkedSavedProjectId: nil,
            draft: draft
        )
        let materialized = try await storageActor.materializeSavedProject(slot)
        return (materialized.draft.id, instanceId, blockId)
    }

    private func deleteAllUserMediaFiles() throws {
        let userMediaDir = tempDir.appendingPathComponent("Media/UserMedia")
        guard FileManager.default.fileExists(atPath: userMediaDir.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: userMediaDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func makeSessionDeps(
        loadSavedProject: @escaping (UUID) async -> SavedProjectRecord?
    ) -> EditorSessionDependencies {
        EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: loadSavedProject,
            materializeSavedProject: { $0 },
            mediaLocator: storageActor,
            mediaWriter: storageActor,
            loadSceneLibrary: {
                SceneLibrarySnapshot(
                    fps: 30,
                    canvas: CanvasConfig(width: 1080, height: 1920),
                    scenes: [
                        SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
                    ]
                )
            },
            sceneTypeDefaults: { _, _ in [] },
            loadTemplateCatalog: {
                .success(TemplateCatalogSnapshot(categories: [], templates: []))
            },
            backgroundPresetProvider: StubBgPresetProvider()
        )
    }
}

// MARK: - Stubs

private struct StubBgPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
