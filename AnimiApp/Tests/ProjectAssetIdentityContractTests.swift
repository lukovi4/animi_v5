import XCTest
@testable import AnimiApp

/// Contract tests for `ProjectAssetID`-based identity model.
/// Verifies that asset identity is decoupled from storage path.
final class ProjectAssetIdentityContractTests: XCTestCase {

    // MARK: - ProjectAssetID

    func test_projectAssetID_isUniqueOnDefaultInit() {
        let a = ProjectAssetID()
        let b = ProjectAssetID()
        XCTAssertNotEqual(a, b)
    }

    func test_projectAssetID_isStableWhenConstructedFromSameUUID() {
        let uuid = UUID()
        let a = ProjectAssetID(rawValue: uuid)
        let b = ProjectAssetID(rawValue: uuid)
        XCTAssertEqual(a, b)
    }

    // MARK: - MediaRef identity by assetId

    func test_mediaRef_identity_byAssetId_notStoragePath() {
        let shared = ProjectAssetID()
        let ref1 = MediaRef(storagePath: "path/a.jpg", mediaKind: .photo, assetId: shared)
        let ref2 = MediaRef(storagePath: "path/b.jpg", mediaKind: .photo, assetId: shared)
        XCTAssertEqual(ref1, ref2, "Two refs with same assetId must be equal despite different storagePaths")
    }

    func test_mediaRef_inequality_differentAssetIds_sameStoragePath() {
        let ref1 = MediaRef(storagePath: "path/a.jpg", mediaKind: .photo)
        let ref2 = MediaRef(storagePath: "path/a.jpg", mediaKind: .photo)
        XCTAssertNotEqual(ref1, ref2, "Refs with different auto-generated assetIds must not be equal")
    }

    // MARK: - ProjectAssetRegistry CRUD

    func test_registry_registerAndLookup() {
        var registry = ProjectAssetRegistry()
        let id = ProjectAssetID()
        let descriptor = ProjectAssetDescriptor(assetId: id, mediaKind: .photo, storagePath: "Media/a.jpg")
        registry.register(descriptor)

        XCTAssertEqual(registry.descriptor(for: id), descriptor)
        XCTAssertEqual(registry.storagePath(for: id), "Media/a.jpg")
    }

    func test_registry_allStoragePaths() {
        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(assetId: ProjectAssetID(), mediaKind: .photo, storagePath: "Media/a.jpg"))
        registry.register(ProjectAssetDescriptor(assetId: ProjectAssetID(), mediaKind: .video, storagePath: "Media/b.mp4"))

        XCTAssertEqual(registry.allStoragePaths, ["Media/a.jpg", "Media/b.mp4"])
    }

    func test_registry_codableRoundTrip() throws {
        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(assetId: ProjectAssetID(), mediaKind: .photo, storagePath: "Media/a.jpg"))

        let data = try JSONEncoder().encode(registry)
        let decoded = try JSONDecoder().decode(ProjectAssetRegistry.self, from: data)
        XCTAssertEqual(decoded.allStoragePaths, registry.allStoragePaths)
    }

    // MARK: - MediaRef codable round-trip preserves assetId

    func test_mediaRef_codable_preservesAssetId() throws {
        let original = MediaRef(storagePath: "Media/a.jpg", mediaKind: .photo)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaRef.self, from: data)

        XCTAssertEqual(decoded.assetId, original.assetId)
        XCTAssertEqual(decoded.storagePath, original.storagePath)
        XCTAssertEqual(decoded.mediaKind, original.mediaKind)
    }

    // MARK: - Registry Lifecycle (PR5 Phase B)

    func test_registry_unregister_removesDescriptor() {
        var registry = ProjectAssetRegistry()
        let id = ProjectAssetID()
        registry.register(ProjectAssetDescriptor(assetId: id, mediaKind: .photo, storagePath: "Media/a.jpg"))
        XCTAssertNotNil(registry.descriptor(for: id))

        registry.unregister(id)
        XCTAssertNil(registry.descriptor(for: id))
    }

    func test_registry_replace_swapsDescriptor() {
        var registry = ProjectAssetRegistry()
        let oldId = ProjectAssetID()
        let newId = ProjectAssetID()
        registry.register(ProjectAssetDescriptor(assetId: oldId, mediaKind: .photo, storagePath: "Media/old.jpg"))

        let newDescriptor = ProjectAssetDescriptor(assetId: newId, mediaKind: .photo, storagePath: "Media/new.jpg")
        registry.replace(oldAssetId: oldId, with: newDescriptor)

        XCTAssertNil(registry.descriptor(for: oldId))
        XCTAssertEqual(registry.descriptor(for: newId)?.storagePath, "Media/new.jpg")
    }

    // MARK: - Draft walkers

    func test_registry_assetIdsReferencedBy_walksSlotsAndBackground() {
        let slotAssetId = ProjectAssetID()
        let bgAssetId = ProjectAssetID()

        // Build a draft with one scene slot + one background region
        let slotRef = MediaRef(storagePath: "Media/slot.jpg", mediaKind: .photo, assetId: slotAssetId)
        let bgRef = MediaRef(storagePath: "Media/bg.jpg", mediaKind: .photo, assetId: bgAssetId)

        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            "block1": .photo(mediaRef: slotRef, placement: .defaultCover)
        ]

        var bg = ProjectBackgroundOverride.empty
        bg.regions["region1"] = RegionOverride(
            source: .image(ImageOverride(mediaRef: bgRef, transform: .identity))
        )

        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        draft.background = bg
        draft.sceneInstanceStates[UUID()] = sceneState

        let registry = ProjectAssetRegistry()
        let referenced = registry.assetIds(referencedBy: draft)

        XCTAssertEqual(referenced, [slotAssetId, bgAssetId])
    }

    func test_registry_storagePathsReferencedBy_usesRegistryPrimary_fallsBackToRawPath() {
        let registeredId = ProjectAssetID()
        let orphanId = ProjectAssetID()

        // Register only one of the two. The second should fall back to
        // the raw mediaRef.storagePath (defense-in-depth).
        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(
            assetId: registeredId,
            mediaKind: .photo,
            storagePath: "Media/registered-path.jpg"
        ))

        let registeredRef = MediaRef(storagePath: "Media/raw-registered.jpg", mediaKind: .photo, assetId: registeredId)
        let orphanRef = MediaRef(storagePath: "Media/raw-orphan.jpg", mediaKind: .photo, assetId: orphanId)

        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            "b1": .photo(mediaRef: registeredRef, placement: .defaultCover),
            "b2": .photo(mediaRef: orphanRef, placement: .defaultCover),
        ]
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        draft.sceneInstanceStates[UUID()] = sceneState

        let paths = registry.storagePaths(referencedBy: draft)

        // Registered asset → uses the descriptor's path (not the raw mediaRef path).
        XCTAssertTrue(paths.contains("Media/registered-path.jpg"))
        // Orphan asset → falls back to raw mediaRef.storagePath.
        XCTAssertTrue(paths.contains("Media/raw-orphan.jpg"))
        // Raw path for the registered asset must NOT be in the set — registry wins.
        XCTAssertFalse(paths.contains("Media/raw-registered.jpg"))
    }

    // MARK: - Registry-backed locator resolution (PR5 Phase B + E)

    /// Happy path: with a populated registry, `FileProjectMediaStore` resolves
    /// via the registry descriptor's path and does NOT touch the legacy fallback.
    /// This is the behavioral contract that Phase E must satisfy in production.
    func test_fileProjectMediaStore_registryPopulated_zeroLegacyFallbackHits() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5_phaseE_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = FileProjectMediaStore(rootDirectoryURL: tempDir)
        let assetId = ProjectAssetID()
        let mediaRef = MediaRef(storagePath: "Media/raw.jpg", mediaKind: .photo, assetId: assetId)

        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: "Media/descriptor.jpg"
        ))

        XCTAssertEqual(store.legacyFallbackHits, 0, "Precondition: counter starts at zero")

        let url = try store.absoluteURL(for: mediaRef, registry: registry)

        // Registry-backed path used → counter is still zero.
        XCTAssertEqual(store.legacyFallbackHits, 0, "Registry hit must not bump the fallback counter")
        XCTAssertEqual(
            url,
            tempDir.appendingPathComponent("Media/descriptor.jpg"),
            "Resolved URL must use the descriptor's storagePath, not the raw mediaRef.storagePath"
        )
    }

    /// Empty/miss path: with an empty registry, the fallback is taken and
    /// `legacyFallbackHits` increments — this is the observable seam that
    /// tests use to detect accidental production regressions.
    func test_fileProjectMediaStore_registryMiss_bumpsLegacyFallbackHits() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5_phaseE_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = FileProjectMediaStore(rootDirectoryURL: tempDir)
        let mediaRef = MediaRef(storagePath: "Media/fallback.jpg", mediaKind: .photo)

        XCTAssertEqual(store.legacyFallbackHits, 0)

        _ = try store.absoluteURL(for: mediaRef, registry: ProjectAssetRegistry())

        XCTAssertEqual(
            store.legacyFallbackHits,
            1,
            "Empty registry should force the legacy mediaRef.storagePath fallback exactly once"
        )
    }

    // MARK: - Self-Healing (PR5 Phase G: undo-registry symmetry)

    /// `selfHealed(for:)` on an empty registry against a draft with no
    /// content returns an empty registry (no synthesis).
    func test_selfHealed_emptyDraft_returnsEmpty() {
        let registry = ProjectAssetRegistry()
        let draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))

        let healed = registry.selfHealed(for: draft)
        XCTAssertEqual(healed.allDescriptors.count, 0)
    }

    /// `selfHealed(for:)` is a no-op when every referenced assetId already
    /// has a descriptor in the registry. Same descriptor count.
    func test_selfHealed_allReferencesPresent_returnsSelf() {
        let assetId = ProjectAssetID()
        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: "Media/a.jpg"
        ))

        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            "b1": .photo(
                mediaRef: MediaRef(storagePath: "Media/a.jpg", mediaKind: .photo, assetId: assetId),
                placement: .defaultCover
            )
        ]
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        draft.sceneInstanceStates[UUID()] = sceneState

        let healed = registry.selfHealed(for: draft)
        XCTAssertEqual(healed.allDescriptors.count, 1)
        XCTAssertNotNil(healed.descriptor(for: assetId))
    }

    /// Canonical undo-asymmetry scenario: the draft references an `assetId`
    /// via a slot `MediaRef`, but the registry no longer contains the
    /// descriptor (because a previous unregister ran, then undo restored
    /// the slot without restoring the descriptor). `selfHealed(for:)` must
    /// synthesize the missing descriptor from the `MediaRef` itself.
    func test_selfHealed_slotReferencesMissingDescriptor_synthesizesIt() {
        let assetId = ProjectAssetID()
        // Registry is empty — this is the post-undo state.
        let registry = ProjectAssetRegistry()

        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            "b1": .photo(
                mediaRef: MediaRef(storagePath: "Media/orphan.jpg", mediaKind: .photo, assetId: assetId),
                placement: .defaultCover
            )
        ]
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        draft.sceneInstanceStates[UUID()] = sceneState

        let healed = registry.selfHealed(for: draft)

        let descriptor = healed.descriptor(for: assetId)
        XCTAssertNotNil(
            descriptor,
            "Self-healing must synthesize a descriptor for an assetId referenced by a slot but missing from the registry"
        )
        XCTAssertEqual(descriptor?.mediaKind, .photo)
        XCTAssertEqual(descriptor?.storagePath, "Media/orphan.jpg")
    }

    /// Same scenario for background region image references.
    func test_selfHealed_backgroundRegionReferencesMissingDescriptor_synthesizesIt() {
        let assetId = ProjectAssetID()
        let registry = ProjectAssetRegistry()

        var bg = ProjectBackgroundOverride.empty
        bg.regions["region1"] = RegionOverride(
            source: .image(ImageOverride(
                mediaRef: MediaRef(storagePath: "Media/Background/orphan.jpg", mediaKind: .photo, assetId: assetId),
                transform: .identity
            ))
        )
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        draft.background = bg

        let healed = registry.selfHealed(for: draft)

        let descriptor = healed.descriptor(for: assetId)
        XCTAssertNotNil(
            descriptor,
            "Self-healing must synthesize a descriptor for a background region assetId missing from the registry"
        )
        XCTAssertEqual(descriptor?.storagePath, "Media/Background/orphan.jpg")
    }

    /// Self-healing must NOT mutate the receiver — the input registry
    /// remains unchanged, the healed copy is a new value.
    func test_selfHealed_doesNotMutateReceiver() {
        let assetId = ProjectAssetID()
        let registry = ProjectAssetRegistry()

        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            "b1": .photo(
                mediaRef: MediaRef(storagePath: "Media/pure.jpg", mediaKind: .photo, assetId: assetId),
                placement: .defaultCover
            )
        ]
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        draft.sceneInstanceStates[UUID()] = sceneState

        _ = registry.selfHealed(for: draft)

        XCTAssertNil(
            registry.descriptor(for: assetId),
            "selfHealed(for:) must be pure — the receiver must not acquire any descriptor"
        )
    }

    /// After self-healing, resolving the same assetId through
    /// `FileProjectMediaStore.absoluteURL(for:registry:)` must NOT bump
    /// `legacyFallbackHits` — it uses the synthesized descriptor.
    func test_selfHealed_fileStoreResolution_doesNotBumpFallbackCounter() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5G_selfheal_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let assetId = ProjectAssetID()
        let mediaRef = MediaRef(storagePath: "Media/undo.jpg", mediaKind: .photo, assetId: assetId)

        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            "b1": .photo(mediaRef: mediaRef, placement: .defaultCover)
        ]
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        draft.sceneInstanceStates[UUID()] = sceneState

        let registry = ProjectAssetRegistry() // empty — post-undo state
        let healed = registry.selfHealed(for: draft)

        let store = FileProjectMediaStore(rootDirectoryURL: tempDir)
        XCTAssertEqual(store.legacyFallbackHits, 0)

        _ = try store.absoluteURL(for: mediaRef, registry: healed)

        XCTAssertEqual(
            store.legacyFallbackHits,
            0,
            "Self-healed registry must resolve without hitting the legacy fallback counter — this is the undo-symmetry contract"
        )
    }
}
