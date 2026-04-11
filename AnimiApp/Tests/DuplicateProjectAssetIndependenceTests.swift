import XCTest
@testable import AnimiApp

/// PR5 Phase G §9.7: Storage-level proof that
/// `ProjectStorageActor.duplicateAssets(inDraft:)` produces a draft that is
/// independent by asset ownership from its source.
///
/// Guarantees verified:
/// 1. The returned draft has a new `id`.
/// 2. Zero `assetId` overlap between source and duplicate.
/// 3. Zero `storagePath` overlap between source and duplicate.
/// 4. Every referenced source file still exists after duplication
///    (copy semantics, not move).
/// 5. Deleting the source draft's media files does NOT delete the
///    duplicate's media files.
///
/// No UI is involved — this is the storage foundation for PR7's
/// "Duplicate project" action.
@MainActor
final class DuplicateProjectAssetIndependenceTests: XCTestCase {

    // MARK: - Setup

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5G_duplicate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a trivial JPEG-ish file so `FileManager.copyItem` can operate on it.
    private func writeStubFile(at url: URL, marker: String = "src") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(marker.utf8).write(to: url)
    }

    /// Seeds a file under `Media/UserMedia/<filename>` and registers its
    /// descriptor in the given registry; returns the asset ID + mediaRef.
    private func seedUserMedia(
        rootDir: URL,
        filename: String,
        into registry: inout ProjectAssetRegistry
    ) throws -> (ProjectAssetID, MediaRef) {
        let relPath = "Media/UserMedia/\(filename)"
        try writeStubFile(at: rootDir.appendingPathComponent(relPath), marker: "src:\(filename)")
        let assetId = ProjectAssetID()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: relPath
        ))
        return (assetId, MediaRef(storagePath: relPath, mediaKind: .photo, assetId: assetId))
    }

    /// Seeds a background image file and registers the descriptor.
    private func seedBackgroundImage(
        rootDir: URL,
        filename: String,
        into registry: inout ProjectAssetRegistry
    ) throws -> (ProjectAssetID, MediaRef) {
        let relPath = "Media/Background/\(filename)"
        try writeStubFile(at: rootDir.appendingPathComponent(relPath), marker: "bg:\(filename)")
        let assetId = ProjectAssetID()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: relPath
        ))
        return (assetId, MediaRef(storagePath: relPath, mediaKind: .photo, assetId: assetId))
    }

    // MARK: - Test

    func test_duplicateAssets_producesIndependentDraft() async throws {
        let rootDir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: rootDir) }

        // 1. Build a source draft with two scene slots and one background region.
        var sourceRegistry = ProjectAssetRegistry()
        let (slot1AssetId, slot1Ref) = try seedUserMedia(
            rootDir: rootDir,
            filename: "slot1.jpg",
            into: &sourceRegistry
        )
        let (slot2AssetId, slot2Ref) = try seedUserMedia(
            rootDir: rootDir,
            filename: "slot2.jpg",
            into: &sourceRegistry
        )
        let (bgAssetId, bgRef) = try seedBackgroundImage(
            rootDir: rootDir,
            filename: "bg1.jpg",
            into: &sourceRegistry
        )

        var sourceSceneState = SceneState.empty
        sourceSceneState.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: slot1Ref, placement: .defaultCover),
            "block2": .photo(mediaRef: slot2Ref, placement: .defaultCover),
        ]
        let instanceId = UUID()

        var sourceBackground = ProjectBackgroundOverride.empty
        sourceBackground.regions["region1"] = RegionOverride(
            source: .image(ImageOverride(mediaRef: bgRef, transform: .identity))
        )

        var sourceDraft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        sourceDraft.background = sourceBackground
        sourceDraft.sceneInstanceStates[instanceId] = sourceSceneState
        sourceDraft.assetRegistry = sourceRegistry

        // 2. Create a storage actor pointed at the temp root and duplicate.
        let persistence = FileProjectPersistenceStore(rootDirectoryURL: rootDir)
        let media = FileProjectMediaStore(rootDirectoryURL: rootDir)
        let actor = ProjectStorageActor(persistence: persistence, media: media)

        let newDraft = try await actor.duplicateAssets(inDraft: sourceDraft)

        // 3. Draft id is fresh.
        XCTAssertNotEqual(newDraft.id, sourceDraft.id, "Duplicate draft must have a new id")

        // 4. Zero assetId overlap.
        let sourceAssetIds: Set<ProjectAssetID> = [slot1AssetId, slot2AssetId, bgAssetId]
        let newAssetIds = newDraft.assetRegistry.assetIds(referencedBy: newDraft)
        XCTAssertTrue(
            sourceAssetIds.isDisjoint(with: newAssetIds),
            "Source and duplicate must share zero assetIds, got source=\(sourceAssetIds), new=\(newAssetIds)"
        )
        XCTAssertEqual(newAssetIds.count, sourceAssetIds.count, "Duplicate must have same number of referenced assets")

        // 5. Zero storagePath overlap.
        let sourcePaths: Set<String> = [
            slot1Ref.storagePath,
            slot2Ref.storagePath,
            bgRef.storagePath,
        ]
        let newPaths = newDraft.assetRegistry.storagePaths(referencedBy: newDraft)
        XCTAssertTrue(
            sourcePaths.isDisjoint(with: newPaths),
            "Source and duplicate must share zero storage paths, got source=\(sourcePaths), new=\(newPaths)"
        )

        // 6. Every source file still exists on disk (copy, not move).
        for sourcePath in sourcePaths {
            let url = rootDir.appendingPathComponent(sourcePath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Source file should still exist after duplication: \(sourcePath)"
            )
        }

        // 7. Every new file actually exists on disk.
        for newPath in newPaths {
            let url = rootDir.appendingPathComponent(newPath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Duplicated file should exist after duplication: \(newPath)"
            )
        }

        // 8. Deleting the source files does NOT remove the duplicate's files.
        for sourcePath in sourcePaths {
            let url = rootDir.appendingPathComponent(sourcePath)
            try? FileManager.default.removeItem(at: url)
        }
        for newPath in newPaths {
            let url = rootDir.appendingPathComponent(newPath)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Duplicate's file must survive source deletion: \(newPath)"
            )
        }

        // 9. Verify content of duplicated files is copied from source — the
        //    stub markers we wrote should be preserved byte-for-byte in the
        //    duplicates.
        //    (Source files are gone now, but we wrote distinct markers.)
        for newPath in newPaths {
            let url = rootDir.appendingPathComponent(newPath)
            let data = try Data(contentsOf: url)
            let content = String(data: data, encoding: .utf8)
            XCTAssertNotNil(content, "Duplicate file must contain readable data")
            XCTAssertTrue(
                content?.hasPrefix("src:") == true || content?.hasPrefix("bg:") == true,
                "Duplicate content must be a copy of source marker, got: \(content ?? "nil")"
            )
        }
    }
}
