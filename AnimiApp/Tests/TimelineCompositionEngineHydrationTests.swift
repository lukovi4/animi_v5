import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// PR-D: Regression tests for TimelineCompositionEngine.updateSceneState cold hydration path.
final class TimelineCompositionEngineHydrationTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a minimal CanonicalTimeline with one scene and returns (timeline, instanceId, sceneTypeId).
    @MainActor
    private func makeTimeline(sceneTypeId: String) -> (CanonicalTimeline, UUID) {
        let instanceId = UUID()
        let payloadId = UUID()
        let durationUs: TimeUs = 3_000_000

        let item = TimelineItem(
            id: instanceId,
            payloadId: payloadId,
            kind: .scene,
            startUs: nil,
            durationUs: durationUs
        )

        let payload: TimelinePayload = .scene(ScenePayload(sceneTypeId: sceneTypeId))
        let track = Track(id: UUID(), kind: .sceneSequence, items: [item])
        let timeline = CanonicalTimeline(
            tracks: [track],
            payloads: [payloadId: payload],
            boundaryTransitions: [:]
        )
        return (timeline, instanceId)
    }

    /// Creates a temp scene package on disk with a compiled.tve containing the given mediaBlocks.
    private func makeScenePackage(sceneTypeId: String, mediaBlocks: [MediaBlock]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EngineHydrationTests")
            .appendingPathComponent(sceneTypeId)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create images/ directory (required by LocalAssetsIndex scanner)
        let imagesDir = tempDir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

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

        var data = Data()
        data.append(contentsOf: CompiledPackageConstants.magicBytes)
        data.appendLE(CompiledPackageConstants.supportedFormatVersion)
        data.appendLE(CompiledPackageConstants.headerSizeV1WithSchema)
        data.appendLE(UInt32(jsonData.count))
        data.appendLE(UInt32(0)) // engine hash (0 = skip check)
        data.appendLE(CompiledPackageConstants.supportedIRSchemaRange.lowerBound)
        data.append(jsonData)

        try data.write(to: tempDir.appendingPathComponent("compiled.tve"))

        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        return tempDir
    }

    private func makeMediaBlock(id: String, defaultFit: FitMode) -> MediaBlock {
        let input = MediaInput(bindingKey: "media",
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

    // MARK: - Cold Cache → Preloads Metadata and Hydrates

    @MainActor
    func test_updateSceneState_coldCache_preloadsMetadata_andHydrates() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let sceneTypeId = "cold-scene"
        let blockId = "block1"

        // Create real temp scene package with a media block
        let packageURL = try makeScenePackage(sceneTypeId: sceneTypeId, mediaBlocks: [
            makeMediaBlock(id: blockId, defaultFit: .contain)
        ])

        // Empty cache — cold path
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        cache.sceneURLProvider = { typeId in
            typeId == sceneTypeId ? packageURL : nil
        }

        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: 3,
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )

        // Track hydration callback
        var hydratedCallbackIds: [UUID] = []
        engine.onSceneStateHydrated = { instanceId, _ in
            hydratedCallbackIds.append(instanceId)
        }

        let (timeline, instanceId) = makeTimeline(sceneTypeId: sceneTypeId)
        engine.setTimeline(timeline, sceneStates: [:])

        // Create unhydrated state: photo slot with nil placement
        var legacyState = SceneState.empty
        legacyState.mediaSlotsByBlockId = [
            blockId: .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]

        // Act
        await engine.updateSceneState(legacyState, for: instanceId)

        // Assert: state hydrated
        let finalState = engine.sceneStates[instanceId]
        XCTAssertNotNil(finalState, "State must be stored")
        let placement = finalState?.mediaSlotsByBlockId?[blockId]?.asset.placement
        XCTAssertNotNil(placement, "Placement must be hydrated")
        XCTAssertEqual(placement?.fitMode, .contain, "fitMode from template mediaBlock")

        // Assert: callback fired
        XCTAssertEqual(hydratedCallbackIds, [instanceId], "onSceneStateHydrated must fire exactly once")

        // Assert: state no longer needs hydration
        XCTAssertFalse(SceneStateMigrationHelper.needsHydration(finalState!))
    }

    // MARK: - Metadata Preload Failure → State Unchanged

    @MainActor
    func test_updateSceneState_metadataPreloadFailure_leavesStateUnchanged() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let sceneTypeId = "missing-scene"
        let blockId = "block1"

        // Create invalid package directory (empty dir, no compiled.tve)
        let invalidDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EngineHydrationTests")
            .appendingPathComponent("invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: invalidDir) }

        // Cache with provider pointing to invalid package
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        cache.sceneURLProvider = { _ in invalidDir }

        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: 3,
            resourcesCache: cache,
            runtimeFactory: { instanceId, resources, dev, queue in
                SceneInstanceRuntime(
                    sceneInstanceId: instanceId,
                    resources: resources,
                    device: dev,
                    commandQueue: queue,
                    mediaSyncing: spy
                )
            }
        )

        // Track hydration callback — should NOT fire
        var hydratedCallbackFired = false
        engine.onSceneStateHydrated = { _, _ in
            hydratedCallbackFired = true
        }

        let (timeline, instanceId) = makeTimeline(sceneTypeId: sceneTypeId)
        engine.setTimeline(timeline, sceneStates: [:])

        // Create unhydrated state
        var legacyState = SceneState.empty
        legacyState.mediaSlotsByBlockId = [
            blockId: .photo(mediaRef: .file("Media/photo.jpg", mediaKind: .photo))
        ]

        // Act
        await engine.updateSceneState(legacyState, for: instanceId)

        // Assert: state stored but still unhydrated
        let finalState = engine.sceneStates[instanceId]
        XCTAssertNotNil(finalState, "State must be stored even on failure")
        XCTAssertNil(finalState?.mediaSlotsByBlockId?[blockId]?.asset.placement, "Placement must remain nil")
        XCTAssertFalse(hydratedCallbackFired, "onSceneStateHydrated must NOT fire on failure")
    }
}

// MARK: - Data LE Helper

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(UnsafeBufferPointer(start: &le, count: 1))
    }
}
