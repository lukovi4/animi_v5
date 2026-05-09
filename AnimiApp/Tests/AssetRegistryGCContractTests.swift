import XCTest
@testable import AnimiApp

/// PR5 Phase G §9.7: Proves the GC policy defined in Phase B.
///
/// GC policy (from `FileProjectMediaStore.collectMediaPaths(from:)`):
/// 1. **Primary**: `assetRegistry.storagePaths(referencedBy: draft)` — only
///    assets currently referenced by content survive.
/// 2. **Defense-in-depth scan**: raw `mediaRef.storagePath` walk over slots +
///    background regions catches pre-registry drafts with stale/empty registry.
///
/// Consequences proven here:
/// - Registered + referenced file: **survives**.
/// - Registered + unreferenced file: **deleted** (GC-eligible, registry does NOT pin).
/// - Unregistered + referenced file (pre-registry draft): **survives** via scan.
/// - Unregistered + unreferenced file: **deleted** (plain orphan).
@MainActor
final class AssetRegistryGCContractTests: XCTestCase {

    // MARK: - Setup

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5G_gc_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeStubFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stub".utf8).write(to: url)
    }

    // MARK: - Test

    /// Canonical GC scenario with all four states (registered ±, referenced ±).
    func test_gc_preservesReferenced_deletesUnreferencedOrphans() async throws {
        let rootDir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let media = FileProjectMediaStore(rootDirectoryURL: rootDir)
        let persistence = FileProjectPersistenceStore(rootDirectoryURL: rootDir)

        // Ensure the user media directory exists
        let userMediaDir = try media.userMediaDirectoryURL()
        try FileManager.default.createDirectory(at: userMediaDir, withIntermediateDirectories: true)

        // State 1: registered + referenced — MUST survive
        let referencedRegisteredRelPath = "Media/UserMedia/registered_referenced.jpg"
        let referencedRegisteredURL = rootDir.appendingPathComponent(referencedRegisteredRelPath)
        try writeStubFile(at: referencedRegisteredURL)
        let referencedRegisteredId = ProjectAssetID()

        // State 2: registered + unreferenced — MUST be deleted (registry does NOT pin)
        let registeredUnreferencedRelPath = "Media/UserMedia/registered_orphan.jpg"
        let registeredUnreferencedURL = rootDir.appendingPathComponent(registeredUnreferencedRelPath)
        try writeStubFile(at: registeredUnreferencedURL)
        let registeredUnreferencedId = ProjectAssetID()

        // State 3: unregistered + referenced (pre-registry draft) — MUST survive via scan
        let unregisteredReferencedRelPath = "Media/UserMedia/scan_referenced.jpg"
        let unregisteredReferencedURL = rootDir.appendingPathComponent(unregisteredReferencedRelPath)
        try writeStubFile(at: unregisteredReferencedURL)

        // State 4: unregistered + unreferenced — MUST be deleted (plain orphan)
        let plainOrphanRelPath = "Media/UserMedia/plain_orphan.jpg"
        let plainOrphanURL = rootDir.appendingPathComponent(plainOrphanRelPath)
        try writeStubFile(at: plainOrphanURL)

        // Build a draft that references (1) and (3), with registry containing (1) and (2).
        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(
            assetId: referencedRegisteredId,
            mediaKind: .photo,
            storagePath: referencedRegisteredRelPath
        ))
        registry.register(ProjectAssetDescriptor(
            assetId: registeredUnreferencedId,
            mediaKind: .photo,
            storagePath: registeredUnreferencedRelPath
        ))

        let slot1Ref = MediaRef(
            storagePath: referencedRegisteredRelPath,
            mediaKind: .photo,
            assetId: referencedRegisteredId
        )
        // State 3 uses a fresh assetId NOT in the registry — only referenced.
        let scanOnlyId = ProjectAssetID()
        let scanOnlyRef = MediaRef(
            storagePath: unregisteredReferencedRelPath,
            mediaKind: .photo,
            assetId: scanOnlyId
        )

        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            "blockA": .photo(mediaRef: slot1Ref, placement: .defaultCover),
            "blockB": .photo(mediaRef: scanOnlyRef, placement: .defaultCover),
        ]
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        draft.sceneInstanceStates[UUID()] = sceneState
        draft.assetRegistry = registry

        // Save as the active draft so GC's top-level scanner picks it up.
        let slot = ActiveDraftSlot(
            entryContext: .newProject(origin: .template(templateId: "tpl_1")),
            linkedSavedProjectId: nil,
            draft: draft
        )
        try persistence.saveActiveDraft(slot)

        // Precondition: all four files exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: referencedRegisteredURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: registeredUnreferencedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unregisteredReferencedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plainOrphanURL.path))

        // Run GC.
        await media.collectOrphanMediaFiles(persistence: persistence)

        // Post-conditions:
        // (1) registered + referenced survives.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: referencedRegisteredURL.path),
            "Registered + referenced file must survive GC"
        )

        // (2) registered + unreferenced is deleted (GC-eligible).
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: registeredUnreferencedURL.path),
            "Registered-but-unreferenced file must be GC-eligible — registry does NOT pin"
        )

        // (3) unregistered + referenced survives via defense-in-depth scan.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unregisteredReferencedURL.path),
            "Unregistered-but-referenced file must survive via raw-path scan"
        )

        // (4) plain orphan is deleted.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plainOrphanURL.path),
            "Plain orphan (unregistered + unreferenced) must be deleted"
        )
    }

    /// Saved projects must pin scene-level background files even after the
    /// active draft is removed. This is the storage-side contract behind
    /// "export then open from My Projects": GC must not physically delete the
    /// image referenced only by `SceneState.backgroundOverride`.
    func test_gc_preservesSavedProjectSceneBackgroundAfterActiveDraftDeleted() async throws {
        let rootDir = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let media = FileProjectMediaStore(rootDirectoryURL: rootDir)
        let persistence = FileProjectPersistenceStore(rootDirectoryURL: rootDir)

        let bgRelPath = "Media/Background/saved_scene_bg.jpg"
        let bgURL = rootDir.appendingPathComponent(bgRelPath)
        try writeStubFile(at: bgURL)

        let assetId = ProjectAssetID()
        let mediaRef = MediaRef(storagePath: bgRelPath, mediaKind: .photo, assetId: assetId)
        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: bgRelPath
        ))

        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        draft.canonicalTimeline = .makeWithSingleScene(sceneTypeId: "scene_1", durationUs: 3_000_000)
        guard let sceneId = draft.canonicalTimeline.sceneItems.first?.id else {
            XCTFail("Test timeline must contain one scene")
            return
        }
        draft.sceneInstanceStates[sceneId] = SceneState(
            backgroundOverride: ProjectBackgroundOverride(
                selectedPresetId: "test_preset",
                regions: [
                    "full": RegionOverride(
                        source: .image(ImageOverride(mediaRef: mediaRef, transform: .identity))
                    )
                ]
            )
        )
        draft.assetRegistry = registry

        let activeSlot = ActiveDraftSlot(
            entryContext: .newProject(origin: .template(templateId: "tpl_1")),
            linkedSavedProjectId: nil,
            draft: draft
        )
        try persistence.saveActiveDraft(activeSlot)
        let savedSlot = try persistence.materializeSavedProject(activeSlot)
        try persistence.saveActiveDraft(savedSlot)
        try persistence.deleteActiveDraft()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bgURL.path),
            "Precondition: scene background file must exist before GC"
        )

        await media.collectOrphanMediaFiles(persistence: persistence)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bgURL.path),
            "Saved project scene-level background file must survive GC after active draft deletion"
        )

        let savedRecord = persistence.loadSavedProject(projectId: draft.id)
        XCTAssertEqual(
            savedRecord?.draft.sceneInstanceStates[sceneId]?.backgroundOverride?.regions["full"]?.imageMediaRef,
            mediaRef,
            "Saved project must retain the scene-level background reference used to pin the file"
        )
    }
}
