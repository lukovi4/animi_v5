import XCTest
import TVECore
@testable import AnimiApp

/// PR5 Phase E: Contract tests for `EditorSession.registerAssetBookkeeping` /
/// `unregisterAssetBookkeeping`.
///
/// Contract under test:
/// 1. Register/unregister are NON-DIRTYING — `requestClose()` stays `.safeToClose`
///    when the only mutation is bookkeeping.
/// 2. Bookkeeping mutations RIDE the next semantic dispatch's persist path —
///    a subsequent `.setBackground(...)` triggers `saveActiveDraft`, and the
///    persisted draft contains the previously registered descriptor.
/// 3. Undo of a semantic edit does NOT remove the bookkeeping descriptor,
///    because the registry mutation is not part of the undo snapshot.
/// 4. `unregister` removes the descriptor without dirtying the session.
@MainActor
final class AssetRegistryBookkeepingTests: XCTestCase {

    // MARK: - Test Session Factory

    private func makeBootstrappedSession(
        saveActiveDraft: @escaping (ActiveDraftSlot) async throws -> Void = { _ in }
    ) async -> EditorSession {
        let deps = EditorSessionDependencies(
            saveActiveDraft: saveActiveDraft,
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { $0 },
            mediaLocator: StubMediaLocator(),
            mediaWriter: StubMediaWriter(),
            loadSceneLibrary: { Self.stubSceneLibrary() },
            sceneTypeDefaults: { _, _ in
                [SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: 3_000_000)]
            },
            loadTemplateCatalog: {
                .success(TemplateCatalogSnapshot(categories: [], templates: []))
            },
            backgroundPresetProvider: StubPresetProvider()
        )
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        await session.bootstrap()
        return session
    }

    private static func stubSceneLibrary() -> SceneLibrarySnapshot {
        SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: [
                SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
            ]
        )
    }

    private func makeDescriptor(storagePath: String = "Media/UserMedia/test.jpg") -> ProjectAssetDescriptor {
        ProjectAssetDescriptor(
            assetId: ProjectAssetID(),
            mediaKind: .photo,
            storagePath: storagePath
        )
    }

    // MARK: - Contract 1: Non-Dirtying

    func testRegisterAssetBookkeeping_doesNotDirtyTheSession() async {
        let session = await makeBootstrappedSession()
        XCTAssertEqual(session.requestClose(), .safeToClose, "Bootstrap-clean session should be safe to close")

        let descriptor = makeDescriptor()
        session.registerAssetBookkeeping(descriptor)

        XCTAssertEqual(
            session.requestClose(),
            .safeToClose,
            "register should be non-dirtying; session should still be safe to close"
        )
    }

    func testUnregisterAssetBookkeeping_doesNotDirtyTheSession() async {
        let session = await makeBootstrappedSession()
        let descriptor = makeDescriptor()
        session.registerAssetBookkeeping(descriptor)

        // Precondition: still clean after register
        XCTAssertEqual(session.requestClose(), .safeToClose)

        session.unregisterAssetBookkeeping(descriptor.assetId)

        XCTAssertEqual(
            session.requestClose(),
            .safeToClose,
            "unregister should be non-dirtying; session should still be safe to close"
        )
    }

    // MARK: - Contract 2: Register populates draft registry visibly

    func testRegister_populatesDraftAssetRegistry() async {
        let session = await makeBootstrappedSession()
        let descriptor = makeDescriptor()

        XCTAssertNil(
            session.state?.draft.assetRegistry.descriptor(for: descriptor.assetId),
            "Registry should not contain the descriptor before register"
        )

        session.registerAssetBookkeeping(descriptor)

        XCTAssertNotNil(
            session.state?.draft.assetRegistry.descriptor(for: descriptor.assetId),
            "Registry should contain the descriptor after register"
        )
        XCTAssertEqual(
            session.state?.draft.assetRegistry.descriptor(for: descriptor.assetId)?.storagePath,
            descriptor.storagePath
        )
    }

    func testUnregister_removesDescriptorFromDraftRegistry() async {
        let session = await makeBootstrappedSession()
        let descriptor = makeDescriptor()

        session.registerAssetBookkeeping(descriptor)
        XCTAssertNotNil(session.state?.draft.assetRegistry.descriptor(for: descriptor.assetId))

        session.unregisterAssetBookkeeping(descriptor.assetId)

        XCTAssertNil(
            session.state?.draft.assetRegistry.descriptor(for: descriptor.assetId),
            "Registry should not contain the descriptor after unregister"
        )
    }

    // MARK: - Contract 3: Bookkeeping rides the next semantic save

    func testRegister_persistsOnNextSemanticSave() async {
        // Capture whatever gets saved so we can inspect the registry on disk.
        var savedSlots: [ActiveDraftSlot] = []
        let session = await makeBootstrappedSession(saveActiveDraft: { slot in
            savedSlots.append(slot)
        })

        let descriptor = makeDescriptor(storagePath: "Media/UserMedia/rides.jpg")
        session.registerAssetBookkeeping(descriptor)

        // Fire a dirtying edit and checkpoint — the persisted draft should
        // include the registered descriptor.
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        _ = await session.persistCheckpointIfNeeded()

        XCTAssertFalse(savedSlots.isEmpty, "saveActiveDraft should have been called")
        let lastSaved = savedSlots.last!
        XCTAssertNotNil(
            lastSaved.draft.assetRegistry.descriptor(for: descriptor.assetId),
            "The persisted draft should contain the previously registered descriptor"
        )
    }

    // MARK: - Contract 4: Undo does not remove bookkeeping

    func testUndoSemanticEdit_doesNotRemoveBookkeepingDescriptor() async {
        let session = await makeBootstrappedSession()
        let descriptor = makeDescriptor(storagePath: "Media/UserMedia/undoTest.jpg")

        session.registerAssetBookkeeping(descriptor)
        XCTAssertNotNil(session.state?.draft.assetRegistry.descriptor(for: descriptor.assetId))

        // Fire a dirtying edit so there is something to undo.
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))

        // Undo — should roll back the scene add but NOT the registry mutation,
        // because the registry is not part of the undo snapshot.
        session.dispatch(.undo)

        XCTAssertNotNil(
            session.state?.draft.assetRegistry.descriptor(for: descriptor.assetId),
            "Undo must not remove the bookkeeping descriptor — registry lives outside the undo snapshot"
        )
    }

    // MARK: - Contract 5: Ingest abort after registration (blocker 1)

    /// Simulates the ingest-abort path: `onAssetPersisted` has already fired
    /// (descriptor registered), but the slot dispatch never happens because
    /// the target scene was deleted / videoWindow was missing / scene
    /// deletion races resolveDefaultFitAsync. PVC then calls
    /// `unregisterAssetBookkeeping` on the never-bound descriptor.
    ///
    /// Expectation: the registry is clean, the session stays `.safeToClose`,
    /// and the final persisted draft does NOT contain the stale descriptor.
    func testIngestAbort_afterRegistration_unregistersStaleDescriptor() async {
        var savedSlots: [ActiveDraftSlot] = []
        let session = await makeBootstrappedSession(saveActiveDraft: { slot in
            savedSlots.append(slot)
        })
        let descriptor = makeDescriptor(storagePath: "Media/UserMedia/abort.jpg")

        // 1. onAssetPersisted fires (simulated): descriptor registered.
        session.registerAssetBookkeeping(descriptor)
        XCTAssertNotNil(session.state?.draft.assetRegistry.descriptor(for: descriptor.assetId))

        // 2. Abort path: slot was never dispatched, so the asset is not
        //    referenced. PVC's abort branch calls unregisterAssetBookkeeping
        //    directly (no need to go through unregister-if-unreferenced).
        session.unregisterAssetBookkeeping(descriptor.assetId)

        XCTAssertNil(
            session.state?.draft.assetRegistry.descriptor(for: descriptor.assetId),
            "Stale descriptor must be gone after abort-path unregister"
        )
        XCTAssertEqual(
            session.requestClose(),
            .safeToClose,
            "Register + unregister must remain non-dirtying as a pair"
        )

        // 3. Trigger a semantic save to write the draft. The persisted draft
        //    must NOT contain the aborted descriptor.
        session.dispatch(.addScene(sceneTypeId: "scene_1", durationUs: 3_000_000))
        _ = await session.persistCheckpointIfNeeded()

        XCTAssertFalse(savedSlots.isEmpty, "saveActiveDraft should have been called")
        XCTAssertNil(
            savedSlots.last?.draft.assetRegistry.descriptor(for: descriptor.assetId),
            "Persisted draft must not carry the aborted stale descriptor"
        )
    }

    // MARK: - Contract 6: Shared-reference safety

    /// If the same `assetId` is referenced by two slots, removing one slot
    /// MUST NOT unregister the descriptor — the other slot still references
    /// it. This is the invariant that `unregisterAssetIfUnreferenced` in PVC
    /// relies on via `assetRegistry.assetIds(referencedBy: draft).contains(id)`.
    func testSharedReference_assetIdsReferencedBy_reflectsAllReferences() {
        let sharedId = ProjectAssetID()
        let ref = MediaRef(storagePath: "Media/shared.jpg", mediaKind: .photo, assetId: sharedId)

        // Build a draft with two scene slots in the same scene both pointing
        // at the same assetId.
        var sceneState = SceneState.empty
        sceneState.mediaSlotsByBlockId = [
            "blockA": .photo(mediaRef: ref, placement: .defaultCover),
            "blockB": .photo(mediaRef: ref, placement: .defaultCover),
        ]
        var draft = ProjectDraft.create(origin: .template(templateId: "tpl_1"))
        draft.sceneInstanceStates[UUID()] = sceneState

        let registry = ProjectAssetRegistry()

        // Both slots reference the same asset — referenced.
        XCTAssertTrue(
            registry.assetIds(referencedBy: draft).contains(sharedId),
            "Two references must keep the asset in the referenced set"
        )

        // Remove slot A — one reference remains.
        draft.sceneInstanceStates[draft.sceneInstanceStates.keys.first!]?.mediaSlotsByBlockId?.removeValue(forKey: "blockA")
        XCTAssertTrue(
            registry.assetIds(referencedBy: draft).contains(sharedId),
            "A single remaining reference must keep the asset referenced"
        )

        // Remove slot B — zero references remain.
        draft.sceneInstanceStates[draft.sceneInstanceStates.keys.first!]?.mediaSlotsByBlockId?.removeValue(forKey: "blockB")
        XCTAssertFalse(
            registry.assetIds(referencedBy: draft).contains(sharedId),
            "Zero references must drop the asset from the referenced set"
        )
    }

    // MARK: - Contract 7: Background editor intermediate imports (blocker 2)

    /// Simulates the background editor session:
    ///   1. Editor opens, tracker starts empty.
    ///   2. User imports image A (registered + tracked).
    ///   3. User imports image B into the same region before Done (B
    ///      registered + tracked; A is no longer in the editor's working
    ///      override but is still in the registry).
    ///   4. User taps Done with an override that references only B.
    ///   5. PVC's sweep loop walks the tracker set and unregisters each
    ///      asset ID that is not referenced by the fresh draft.
    ///
    /// Expectation: after the sweep, A is gone from the registry, B remains,
    /// and the session stays non-dirty apart from the semantic `.setBackground`.
    func testBackgroundEditorDismiss_sweepsIntermediateImports() async {
        let session = await makeBootstrappedSession()

        // 1. Tracker starts empty. (Equivalent to `backgroundEditorRegisteredAssetIds.removeAll()`.)
        var tracker: Set<ProjectAssetID> = []

        // 2. Import A.
        let descA = makeDescriptor(storagePath: "Media/Background/a.jpg")
        session.registerAssetBookkeeping(descA)
        tracker.insert(descA.assetId)

        // 3. Import B.
        let descB = makeDescriptor(storagePath: "Media/Background/b.jpg")
        session.registerAssetBookkeeping(descB)
        tracker.insert(descB.assetId)

        XCTAssertNotNil(session.state?.draft.assetRegistry.descriptor(for: descA.assetId))
        XCTAssertNotNil(session.state?.draft.assetRegistry.descriptor(for: descB.assetId))

        // 4. User taps Done with an override that references only B.
        //    Simulate the `.setBackground` dispatch by directly calling it.
        let bgRefB = MediaRef(
            storagePath: descB.storagePath,
            mediaKind: .photo,
            assetId: descB.assetId
        )
        var override = ProjectBackgroundOverride.empty
        override.regions["region1"] = RegionOverride(
            source: .image(ImageOverride(mediaRef: bgRefB, transform: .identity))
        )
        session.dispatch(.setBackground(override))

        // 5. Sweep loop (mirrors PVC's `backgroundEditorWillDismiss` logic):
        //    for each tracked asset ID, unregister if unreferenced.
        for assetId in tracker {
            guard let draft = session.state?.draft else { break }
            let stillReferenced = draft.assetRegistry.assetIds(referencedBy: draft).contains(assetId)
            if !stillReferenced {
                session.unregisterAssetBookkeeping(assetId)
            }
        }

        // A was intermediate — must be gone from the registry.
        XCTAssertNil(
            session.state?.draft.assetRegistry.descriptor(for: descA.assetId),
            "Intermediate background import A must be swept"
        )
        // B is in the final override — must remain.
        XCTAssertNotNil(
            session.state?.draft.assetRegistry.descriptor(for: descB.assetId),
            "Background image B in the final override must remain registered"
        )
    }
}

// MARK: - Test Doubles

private struct StubMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/stub")
    }
}

private struct StubMediaWriter: ProjectMediaWriteGateway {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func deleteMediaFile(_ mediaRef: MediaRef) async throws {}
    func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft { sourceDraft }
}

private struct StubPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}
