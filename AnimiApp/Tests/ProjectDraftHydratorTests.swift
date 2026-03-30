import XCTest
@testable import AnimiApp
import TVECore

/// Tests for ProjectDraftHydrator: project-load-time hydration of all scene states.
final class ProjectDraftHydratorTests: XCTestCase {

    // MARK: - Test Helpers

    /// Mock URL provider that returns pre-configured URLs per sceneTypeId.
    private struct MockSceneURLProvider: ProjectDraftHydrator.SceneURLProvider {
        var urls: [String: URL] = [:]

        func sceneURL(for sceneTypeId: String) -> URL? {
            urls[sceneTypeId]
        }
    }

    /// Builds a draft with given scene instances.
    /// Returns (draft, [(instanceId, sceneTypeId)]) for verification.
    private static func makeDraft(
        scenes: [(sceneTypeId: String, durationUs: TimeUs, state: SceneState)]
    ) -> (ProjectDraft, [(UUID, String)]) {
        var items: [TimelineItem] = []
        var payloads: [UUID: TimelinePayload] = [:]
        var states: [UUID: SceneState] = [:]
        var mapping: [(UUID, String)] = []

        for scene in scenes {
            let payloadId = UUID()
            let item = TimelineItem(
                id: UUID(),
                payloadId: payloadId,
                kind: .scene,
                durationUs: scene.durationUs
            )
            items.append(item)
            payloads[payloadId] = .scene(ScenePayload(sceneTypeId: scene.sceneTypeId))
            states[item.id] = scene.state
            mapping.append((item.id, scene.sceneTypeId))
        }

        let track = Track(kind: .sceneSequence, items: items)
        let timeline = CanonicalTimeline(tracks: [track], payloads: payloads)
        let draft = ProjectDraft(
            templateId: "test-template",
            canonicalTimeline: timeline,
            sceneInstanceStates: states
        )
        return (draft, mapping)
    }

    /// Creates a state with a nil-placement photo slot (needs hydration).
    private static func stateNeedingHydration(blockId: String = "block1") -> SceneState {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            blockId: .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]
        return state
    }

    /// Creates a state that is already hydrated (has placement, no userTransforms).
    private static func alreadyHydratedState(blockId: String = "block1") -> SceneState {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            blockId: .photo(
                mediaRef: .file("Media/photo.jpg", mediaKind: .photo),
                placement: .default(fitMode: .cover)
            )
        ]
        return state
    }

    /// Creates a state with legacy userTransforms (needs hydration).
    private static func stateWithLegacyUserTransforms(blockId: String = "block1") -> SceneState {
        var state = SceneState.empty
        state.mediaSlotsByBlockId = [
            blockId: .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]
        state.userTransforms = [blockId: .identity]
        return state
    }

    // MARK: - Multi-Scene Draft Hydration

    func test_multiSceneDraft_hydratesAllInstancesWithCorrectDefaultFit() async throws {
        // Scene type A has block1 with .contain, scene type B has block2 with .fill
        let sceneTypeA = "sceneTypeA"
        let sceneTypeB = "sceneTypeB"

        let (draft, mapping) = Self.makeDraft(scenes: [
            (sceneTypeA, 1_000_000, Self.stateNeedingHydration(blockId: "block1")),
            (sceneTypeB, 2_000_000, Self.stateNeedingHydration(blockId: "block2")),
        ])

        // Create real compiled scene packages on disk
        let urlA = try makeScenePackage(sceneTypeId: sceneTypeA, mediaBlocks: [
            makeMediaBlock(id: "block1", defaultFit: .contain)
        ])
        let urlB = try makeScenePackage(sceneTypeId: sceneTypeB, mediaBlocks: [
            makeMediaBlock(id: "block2", defaultFit: .fill)
        ])

        let provider = MockSceneURLProvider(urls: [sceneTypeA: urlA, sceneTypeB: urlB])
        let result = await ProjectDraftHydrator.hydrate(draft: draft, sceneURLProvider: provider)

        // Both instances should be hydrated
        XCTAssertEqual(result.changedInstanceIds.count, 2)
        XCTAssertTrue(result.changedInstanceIds.contains(mapping[0].0))
        XCTAssertTrue(result.changedInstanceIds.contains(mapping[1].0))

        // Check correct defaultFit per scene type
        let stateA = result.draft.sceneInstanceStates[mapping[0].0]
        XCTAssertEqual(stateA?.mediaSlotsByBlockId?["block1"]?.placement?.fitMode, .contain)

        let stateB = result.draft.sceneInstanceStates[mapping[1].0]
        XCTAssertEqual(stateB?.mediaSlotsByBlockId?["block2"]?.placement?.fitMode, .fill)
    }

    // MARK: - SceneType Dedupe

    func test_sameSceneTypeLoadedOnceForMultipleInstances() async throws {
        let sceneType = "sharedType"

        let (draft, mapping) = Self.makeDraft(scenes: [
            (sceneType, 1_000_000, Self.stateNeedingHydration(blockId: "block1")),
            (sceneType, 1_000_000, Self.stateNeedingHydration(blockId: "block1")),
            (sceneType, 1_000_000, Self.stateNeedingHydration(blockId: "block1")),
        ])

        let url = try makeScenePackage(sceneTypeId: sceneType, mediaBlocks: [
            makeMediaBlock(id: "block1", defaultFit: .cover)
        ])

        let provider = MockSceneURLProvider(urls: [sceneType: url])
        let result = await ProjectDraftHydrator.hydrate(draft: draft, sceneURLProvider: provider)

        // All 3 instances hydrated
        XCTAssertEqual(result.changedInstanceIds.count, 3)
        for (instanceId, _) in mapping {
            let state = result.draft.sceneInstanceStates[instanceId]
            XCTAssertNotNil(state?.mediaSlotsByBlockId?["block1"]?.placement)
        }
    }

    // MARK: - Already Hydrated

    func test_alreadyHydratedDraft_returnsUnchanged() async {
        let (draft, _) = Self.makeDraft(scenes: [
            ("typeA", 1_000_000, Self.alreadyHydratedState()),
        ])

        let provider = MockSceneURLProvider(urls: [:])
        let result = await ProjectDraftHydrator.hydrate(draft: draft, sceneURLProvider: provider)

        XCTAssertTrue(result.changedInstanceIds.isEmpty)
        XCTAssertEqual(result.draft, draft)
    }

    // MARK: - Legacy userTransforms Cleanup

    func test_legacyUserTransforms_removedAfterHydration() async throws {
        let sceneType = "typeA"

        let (draft, mapping) = Self.makeDraft(scenes: [
            (sceneType, 1_000_000, Self.stateWithLegacyUserTransforms(blockId: "block1")),
        ])

        let url = try makeScenePackage(sceneTypeId: sceneType, mediaBlocks: [
            makeMediaBlock(id: "block1", defaultFit: .cover)
        ])

        let provider = MockSceneURLProvider(urls: [sceneType: url])
        let result = await ProjectDraftHydrator.hydrate(draft: draft, sceneURLProvider: provider)

        let state = result.draft.sceneInstanceStates[mapping[0].0]
        XCTAssertTrue(state?.userTransforms.isEmpty ?? false, "userTransforms must be empty after hydration")
        XCTAssertNotNil(state?.mediaSlotsByBlockId?["block1"]?.placement)
    }

    // MARK: - Missing Scene URL/Package

    func test_missingSceneURL_stateRemainsUnchanged() async {
        let (draft, mapping) = Self.makeDraft(scenes: [
            ("missingType", 1_000_000, Self.stateNeedingHydration()),
        ])

        // No URL provided for missingType
        let provider = MockSceneURLProvider(urls: [:])
        let result = await ProjectDraftHydrator.hydrate(draft: draft, sceneURLProvider: provider)

        XCTAssertTrue(result.changedInstanceIds.isEmpty)
        // State should be exactly as input (nil placement preserved)
        let state = result.draft.sceneInstanceStates[mapping[0].0]
        XCTAssertNil(state?.mediaSlotsByBlockId?["block1"]?.placement)
    }

    func test_invalidScenePackage_stateRemainsUnchanged() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write invalid data as compiled.tve
        try Data("not a valid package".utf8).write(to: tempDir.appendingPathComponent("compiled.tve"))

        let (draft, mapping) = Self.makeDraft(scenes: [
            ("badType", 1_000_000, Self.stateNeedingHydration()),
        ])

        let provider = MockSceneURLProvider(urls: ["badType": tempDir])
        let result = await ProjectDraftHydrator.hydrate(draft: draft, sceneURLProvider: provider)

        XCTAssertTrue(result.changedInstanceIds.isEmpty)
        let state = result.draft.sceneInstanceStates[mapping[0].0]
        XCTAssertNil(state?.mediaSlotsByBlockId?["block1"]?.placement)
    }

    // MARK: - Empty Draft

    func test_emptyDraft_returnsImmediately() async {
        let draft = ProjectDraft(templateId: "test")
        let provider = MockSceneURLProvider(urls: [:])
        let result = await ProjectDraftHydrator.hydrate(draft: draft, sceneURLProvider: provider)

        XCTAssertTrue(result.changedInstanceIds.isEmpty)
        XCTAssertEqual(result.draft, draft)
    }

    // MARK: - Duplicate Legacy Un-Hydrated Scene Then Hydrate

    func test_duplicateLegacyUnhydratedScene_hydratesOriginalAndDuplicate() async throws {
        let sceneType = "typeA"
        let blockId = "block1"

        // Build a draft with one legacy scene: nil placement + userTransforms
        let (draft, mapping) = Self.makeDraft(scenes: [
            (sceneType, 1_000_000, Self.stateWithLegacyUserTransforms(blockId: blockId)),
        ])
        let originalId = mapping[0].0

        // Load into EditorState and duplicate
        let loadResult = EditorReducer.reduce(
            state: .empty(),
            action: .loadProject(draft: draft, templateFPS: 30, defaultSceneSequence: [])
        )
        let dupResult = EditorReducer.reduce(
            state: loadResult.state,
            action: .duplicateScene(sceneItemId: originalId)
        )

        // Find duplicate instance id (second scene item)
        let sceneItems = dupResult.state.sceneItems
        XCTAssertEqual(sceneItems.count, 2)
        let duplicateId = sceneItems[1].id
        XCTAssertNotEqual(duplicateId, originalId)

        // Pre-hydration: both still legacy
        let origState = dupResult.state.draft.sceneInstanceStates[originalId]
        let dupState = dupResult.state.draft.sceneInstanceStates[duplicateId]
        XCTAssertNil(origState?.mediaSlotsByBlockId?[blockId]?.asset.placement, "Original still un-hydrated")
        XCTAssertNil(dupState?.mediaSlotsByBlockId?[blockId]?.asset.placement, "Duplicate still un-hydrated")
        XCTAssertFalse(dupState?.userTransforms.isEmpty ?? true, "Duplicate has legacy userTransforms")

        // Hydrate the duplicated draft
        let url = try makeScenePackage(sceneTypeId: sceneType, mediaBlocks: [
            makeMediaBlock(id: blockId, defaultFit: .contain)
        ])
        let provider = MockSceneURLProvider(urls: [sceneType: url])
        let hydrated = await ProjectDraftHydrator.hydrate(
            draft: dupResult.state.draft,
            sceneURLProvider: provider
        )

        // Both instances hydrated
        XCTAssertTrue(hydrated.changedInstanceIds.contains(originalId), "Original must be in changedInstanceIds")
        XCTAssertTrue(hydrated.changedInstanceIds.contains(duplicateId), "Duplicate must be in changedInstanceIds")

        // Both have non-nil placement with correct fitMode
        let hydratedOrig = hydrated.draft.sceneInstanceStates[originalId]
        let hydratedDup = hydrated.draft.sceneInstanceStates[duplicateId]
        XCTAssertEqual(hydratedOrig?.mediaSlotsByBlockId?[blockId]?.asset.placement?.fitMode, .contain)
        XCTAssertEqual(hydratedDup?.mediaSlotsByBlockId?[blockId]?.asset.placement?.fitMode, .contain)

        // userTransforms cleared on both
        XCTAssertTrue(hydratedOrig?.userTransforms.isEmpty ?? false, "Original userTransforms cleared")
        XCTAssertTrue(hydratedDup?.userTransforms.isEmpty ?? false, "Duplicate userTransforms cleared")
    }

    // MARK: - Test Scene Package Helpers

    /// Creates a minimal compiled.tve on disk for testing.
    private func makeScenePackage(sceneTypeId: String, mediaBlocks: [MediaBlock]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HydratorTests")
            .appendingPathComponent(sceneTypeId)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 90)
        let scene = Scene(
            schemaVersion: "1",
            canvas: canvas,
            mediaBlocks: mediaBlocks
        )
        let runtime = SceneRuntime(
            scene: scene,
            canvas: canvas,
            blocks: [],
            durationFrames: 90,
            fps: 30
        )
        let compiled = CompiledScene(
            runtime: runtime,
            mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry()
        )
        let payload = CompiledScenePayload(
            compiled: compiled,
            templateId: sceneTypeId,
            templateRevision: 1,
            engineVersion: TVECore.version
        )

        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(payload)

        // Build .tve binary: magic + format version + header length + payload length + engine hash + schema version + payload
        var data = Data()
        data.append(contentsOf: CompiledPackageConstants.magicBytes)               // 4 bytes
        data.appendLE(CompiledPackageConstants.supportedFormatVersion)              // 2 bytes (UInt16)
        data.appendLE(CompiledPackageConstants.headerSizeV1WithSchema)             // 2 bytes (UInt16)
        data.appendLE(UInt32(jsonData.count))                                       // 4 bytes
        data.appendLE(UInt32(0))                                                    // 4 bytes engine hash (0 = skip check)
        data.appendLE(CompiledPackageConstants.supportedIRSchemaRange.lowerBound)  // 2 bytes IR schema
        data.append(jsonData)

        try data.write(to: tempDir.appendingPathComponent("compiled.tve"))

        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        return tempDir
    }

    /// Creates a MediaBlock with the given id and defaultFit.
    private func makeMediaBlock(id: String, defaultFit: FitMode) -> MediaBlock {
        let input = MediaInput(
            rect: Rect(x: 0, y: 0, width: 1080, height: 1920),
            bindingKey: "media",
            allowedMedia: ["photo", "video"],
            defaultFit: defaultFit
        )
        return MediaBlock(
            id: id,
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 1080, height: 1920),
            containerClip: .slotRect,
            input: input,
            variants: []
        )
    }
}

// MARK: - Data LE Helper

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(UnsafeBufferPointer(start: &le, count: 1))
    }
}
