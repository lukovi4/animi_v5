import AVFoundation
import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// TT-05: Tests for TimelineCompositionEngine.buildExportSession().
final class TimelineCompositionEngineExportSessionTests: XCTestCase {

    // MARK: - Test Infrastructure

    @MainActor
    private func makeMinimalResources(durationFrames: Int, fps: Int = 30, sceneTypeId: String = "test-scene-type") -> SceneTypeResourcesCache.Resources {
        let canvas = Canvas(width: 1080, height: 1920, fps: fps, durationFrames: durationFrames)
        let scene = Scene(
            schemaVersion: "1.0",
            sceneId: "test-scene",
            canvas: canvas,
            background: nil,
            mediaBlocks: []
        )
        let runtime = SceneRuntime(
            scene: scene,
            canvas: canvas,
            blocks: [],
            durationFrames: durationFrames,
            fps: fps
        )
        let compiled = CompiledScene(
            runtime: runtime,
            mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry(),
            bindingAssetIds: []
        )
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let baseProvider = InMemoryTextureProvider()

        return SceneTypeResourcesCache.Resources(
            sceneTypeId: sceneTypeId,
            compiled: compiled,
            resolver: resolver,
            baseTextureProvider: baseProvider,
            assetSizes: [:],
            pathRegistry: PathRegistry(),
            canvasSize: SizeD(width: Double(canvas.width), height: Double(canvas.height)),
            fps: fps,
            durationFrames: durationFrames
        )
    }

    private func framesToUs(_ frames: Int, fps: Int = 30) -> TimeUs {
        Int64(frames) * 1_000_000 / Int64(fps)
    }

    @MainActor
    private func makeMinimalTimeline(sceneCount: Int, framesPerScene: Int = 100) -> (CanonicalTimeline, [SceneTypeResourcesCache.Resources]) {
        var items: [TimelineItem] = []
        var payloads: [UUID: TimelinePayload] = [:]
        var resources: [SceneTypeResourcesCache.Resources] = []

        for i in 0..<sceneCount {
            let instanceId = UUID()
            let payloadId = UUID()
            let sceneTypeId = "scene-type-\(i)"

            let durationUs = framesToUs(framesPerScene)
            let item = TimelineItem(
                id: instanceId,
                payloadId: payloadId,
                kind: .scene,
                startUs: nil,
                durationUs: durationUs
            )
            items.append(item)

            let scenePayload = ScenePayload(sceneTypeId: sceneTypeId)
            payloads[payloadId] = .scene(scenePayload)

            let res = makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeId)
            resources.append(res)
        }

        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: items)
        let timeline = CanonicalTimeline(
            tracks: [sceneTrack],
            payloads: payloads,
            boundaryTransitions: [:]
        )

        return (timeline, resources)
    }

    @MainActor
    private func makeEngine(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        timeline: CanonicalTimeline,
        resources: [SceneTypeResourcesCache.Resources],
        sceneStates: [UUID: SceneState] = [:]
    ) -> TimelineCompositionEngine {
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources {
            cache.addToCache(res)
        }

        let spy = SceneInstanceRuntimeHoldFrameTests.MediaSyncingSpy()
        spy.isSceneMediaReady = true

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

        engine.setTemplateCanvas(CanvasConfig(width: 1080, height: 1920))
        engine.setTimeline(timeline, sceneStates: sceneStates)

        return engine
    }

    // MARK: - Tests

    /// buildExportSession() builds snapshots for ALL sceneItems.
    @MainActor
    func testBuildExportSessionSnapshotsAllScenes() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 3, framesPerScene: 60)
        let engine = makeEngine(device: device, commandQueue: commandQueue, timeline: timeline, resources: resources)

        let session = try await engine.buildExportSession()

        // All 3 scenes present in snapshot
        XCTAssertEqual(session.scenesByInstanceId.count, 3)
        for item in timeline.sceneItems {
            XCTAssertNotNil(session.scenesByInstanceId[item.id], "Missing snapshot for scene \(item.id)")
        }
    }

    /// session.canvasSize matches engine.canvasSize (template source of truth).
    @MainActor
    func testSessionCanvasSizeMatchesEngine() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 60)
        let engine = makeEngine(device: device, commandQueue: commandQueue, timeline: timeline, resources: resources)

        let session = try await engine.buildExportSession()

        XCTAssertEqual(session.canvasSize.width, engine.canvasSize.width)
        XCTAssertEqual(session.canvasSize.height, engine.canvasSize.height)
    }

    /// Per-scene sceneCanvasSize matches runtime resources canvasSize.
    @MainActor
    func testPerSceneCanvasSizeMatchesResources() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 2, framesPerScene: 60)
        let engine = makeEngine(device: device, commandQueue: commandQueue, timeline: timeline, resources: resources)

        let session = try await engine.buildExportSession()

        for (index, item) in timeline.sceneItems.enumerated() {
            guard let snapshot = session.scenesByInstanceId[item.id] else {
                XCTFail("Missing snapshot for \(item.id)")
                continue
            }
            // Compare against cached resources (engine may not have warm runtimes for cold scenes)
            XCTAssertEqual(snapshot.sceneCanvasSize.width, resources[index].canvasSize.width)
            XCTAssertEqual(snapshot.sceneCanvasSize.height, resources[index].canvasSize.height)
        }
    }

    /// renderState matches sceneStates[instanceId] ?? .empty
    @MainActor
    func testRenderStateMatchesSceneStates() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 2, framesPerScene: 60)
        let firstId = timeline.sceneItems[0].id
        let secondId = timeline.sceneItems[1].id

        let states: [UUID: SceneState] = [
            firstId: SceneState(
                variantOverrides: ["block1": "variantA"],
                layerToggles: ["block1": ["toggle1": false]]
            )
            // secondId intentionally missing -> .empty
        ]

        let engine = makeEngine(device: device, commandQueue: commandQueue, timeline: timeline, resources: resources, sceneStates: states)

        let session = try await engine.buildExportSession()

        // First scene: matches provided state
        let snap1 = session.scenesByInstanceId[firstId]!
        XCTAssertEqual(snap1.renderState.variantOverrides, ["block1": "variantA"])
        XCTAssertTrue(snap1.renderState.userMediaPresent.isEmpty)
        XCTAssertEqual(snap1.renderState.layerToggleState, ["block1": ["toggle1": false]])

        // Second scene: empty state
        let snap2 = session.scenesByInstanceId[secondId]!
        XCTAssertTrue(snap2.renderState.variantOverrides.isEmpty)
        XCTAssertTrue(snap2.renderState.userMediaPresent.isEmpty)
        XCTAssertTrue(snap2.renderState.layerToggleState.isEmpty)
    }

    /// Snapshot contains media snapshot and asset metadata (no live GPU textures).
    @MainActor
    func testSnapshotContainsMediaSnapshotAndAssetMetadata() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 60)
        let engine = makeEngine(device: device, commandQueue: commandQueue, timeline: timeline, resources: resources)

        let session = try await engine.buildExportSession()

        let snapshot = session.scenesByInstanceId.values.first!
        XCTAssertNotNil(snapshot.mediaSnapshot, "Snapshot should have a media snapshot")
        XCTAssertNotNil(snapshot.assetIndex, "Snapshot should have an asset index")
        XCTAssertNotNil(snapshot.resolver, "Snapshot should have a resolver")
    }

    /// audioSceneData contains data for all scenes.
    @MainActor
    func testAudioSceneDataCoversAllScenes() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 3, framesPerScene: 60)
        let engine = makeEngine(device: device, commandQueue: commandQueue, timeline: timeline, resources: resources)

        let session = try await engine.buildExportSession()

        XCTAssertEqual(session.audioSceneData.count, 3)
        for (index, data) in session.audioSceneData.enumerated() {
            XCTAssertEqual(data.sceneIndex, index)
        }
    }

    /// buildExportSession throws noTimeline when no timeline is set.
    @MainActor
    func testBuildExportSessionThrowsWithoutTimeline() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let engine = TimelineCompositionEngine(device: device, commandQueue: commandQueue)

        do {
            _ = try await engine.buildExportSession()
            XCTFail("Expected noTimeline error")
        } catch let error as TimelineCompositionEngine.TimelineExportSessionBuildError {
            XCTAssertEqual(error, .noTimeline)
        }
    }

    /// buildExportSession throws noTimeline when templateCanvas is not set.
    @MainActor
    func testBuildExportSessionThrowsWithoutCanvas() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 60)
        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        for res in resources { cache.addToCache(res) }

        let engine = TimelineCompositionEngine(
            device: device,
            commandQueue: commandQueue,
            fps: 30,
            maxActiveDecoders: 3,
            resourcesCache: cache,
            runtimeFactory: { id, res, dev, queue in
                SceneInstanceRuntime(sceneInstanceId: id, resources: res, device: dev, commandQueue: queue)
            }
        )
        // Set timeline but NOT templateCanvas
        engine.setTimeline(timeline, sceneStates: [:])

        do {
            _ = try await engine.buildExportSession()
            XCTFail("Expected noTimeline error")
        } catch let error as TimelineCompositionEngine.TimelineExportSessionBuildError {
            XCTAssertEqual(error, .noTimeline)
        }
    }

    /// session.fps matches engine fps.
    @MainActor
    func testSessionFpsMatchesEngine() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 60)
        let engine = makeEngine(device: device, commandQueue: commandQueue, timeline: timeline, resources: resources)

        let session = try await engine.buildExportSession()
        XCTAssertEqual(session.fps, 30)
    }

    /// transitionMath in session is consistent with engine.
    @MainActor
    func testSessionTransitionMathConsistent() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 2, framesPerScene: 60)
        let engine = makeEngine(device: device, commandQueue: commandQueue, timeline: timeline, resources: resources)

        let session = try await engine.buildExportSession()
        XCTAssertEqual(session.transitionMath.compressedDurationFrames, engine.compressedDurationFrames)
    }

    // MARK: - Legacy Cold Export

    /// Creates a minimal valid .mp4 file so AVURLAsset.duration returns > 0.
    private func createMinimalVideoFile(at url: URL, durationFrames: Int = 2, fps: Int32 = 30) async throws {

        // Create directory if needed
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Write a minimal video using AVAssetWriter
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let buffer = pixelBuffer else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
        }
        for i in 0..<durationFrames {
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed"])
        }
    }

    /// Cold scene with video media slot (videoWindow present) produces
    /// non-empty videoSelections via persisted videoWindow parameters.
    @MainActor
    func testBuildExportSession_coldVideoSlot_producesVideoSelection() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        // Create a real video file in ProjectStore's directory
        let projectsDir = try ProjectStore.shared.projectsDirectoryURL()
        let relativePath = "Media/TestVideo/video_\(UUID().uuidString).mp4"
        let videoURL = projectsDir.appendingPathComponent(relativePath)
        try await createMinimalVideoFile(at: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        // Build timeline with 1 scene
        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 60)
        let instanceId = timeline.sceneItems[0].id

        // Probe actual duration so trimEnd stays within bounds
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // v7 state: video slot with persisted videoWindow matching actual duration
        let state = SceneState(
            mediaSlotsByBlockId: [
                "block_v1": .video(
                    mediaRef: MediaRef(kind: .file, id: relativePath, mediaKind: .video),
                    placement: .defaultCover,
                    videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: durationSeconds)
                )
            ]
        )

        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            timeline: timeline,
            resources: resources,
            sceneStates: [instanceId: state]
        )

        let session = try await engine.buildExportSession()

        // Verify the cold scene's videoSelections were assembled from persisted slot
        let snapshot = session.scenesByInstanceId[instanceId]!
        XCTAssertFalse(snapshot.videoSelections.isEmpty, "Video slot should produce video selections")

        guard let vs = snapshot.videoSelections["block_v1"] else {
            XCTFail("Expected video selection for block_v1")
            return
        }
        XCTAssertEqual(vs.url, videoURL)
        XCTAssertEqual(vs.trimEnd, durationSeconds, accuracy: 0.001, "trimEnd should match persisted videoWindow")
        XCTAssertEqual(vs.trimStart, 0, accuracy: 0.001, "trimStart should match persisted videoWindow")
    }

    // MARK: - Strict Video Contract Tests

    /// Visible video without videoWindow causes buildExportSession to throw.
    @MainActor
    func testBuildExportSession_visibleVideoWithoutVideoWindow_throws() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let projectsDir = try ProjectStore.shared.projectsDirectoryURL()
        let relativePath = "Media/TestVideo/video_\(UUID().uuidString).mp4"
        let videoURL = projectsDir.appendingPathComponent(relativePath)
        try await createMinimalVideoFile(at: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 60)
        let instanceId = timeline.sceneItems[0].id

        // Nil videoWindow on visible video slot
        let state = SceneState(
            mediaSlotsByBlockId: [
                "block_v1": SceneMediaSlot(
                    asset: SceneMediaAsset(
                        mediaRef: MediaRef(kind: .file, id: relativePath, mediaKind: .video),
                        placement: .defaultCover,
                        videoWindow: nil
                    )
                )
            ]
        )

        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            timeline: timeline,
            resources: resources,
            sceneStates: [instanceId: state]
        )

        do {
            _ = try await engine.buildExportSession()
            XCTFail("Expected missingVideoWindow error")
        } catch let error as ExportMediaError {
            if case .missingVideoWindow = error {
                // Expected
            } else {
                XCTFail("Expected missingVideoWindow, got \(error)")
            }
        }
    }

    /// Invalid persisted window (winEnd past duration) causes buildExportSession to throw.
    @MainActor
    func testBuildExportSession_invalidPersistedWindow_throws() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let projectsDir = try ProjectStore.shared.projectsDirectoryURL()
        let relativePath = "Media/TestVideo/video_\(UUID().uuidString).mp4"
        let videoURL = projectsDir.appendingPathComponent(relativePath)
        try await createMinimalVideoFile(at: videoURL, durationFrames: 2, fps: 30)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 60)
        let instanceId = timeline.sceneItems[0].id

        // trimEnd far exceeds actual duration
        let state = SceneState(
            mediaSlotsByBlockId: [
                "block_v1": .video(
                    mediaRef: MediaRef(kind: .file, id: relativePath, mediaKind: .video),
                    placement: .defaultCover,
                    videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 999.0)
                )
            ]
        )

        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            timeline: timeline,
            resources: resources,
            sceneStates: [instanceId: state]
        )

        do {
            _ = try await engine.buildExportSession()
            XCTFail("Expected invalidVideoSelection error")
        } catch let error as ExportMediaError {
            if case .invalidVideoSelection = error {
                // Expected
            } else {
                XCTFail("Expected invalidVideoSelection, got \(error)")
            }
        }
    }

    /// Hidden video slot is absent from both videoSelections and audioSceneData.videoSelections.
    @MainActor
    func testBuildExportSession_hiddenVideo_absentFromSelectionsAndAudio() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let projectsDir = try ProjectStore.shared.projectsDirectoryURL()
        let relativePath = "Media/TestVideo/video_\(UUID().uuidString).mp4"
        let videoURL = projectsDir.appendingPathComponent(relativePath)
        try await createMinimalVideoFile(at: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 60)
        let instanceId = timeline.sceneItems[0].id

        // Hidden video slot
        let state = SceneState(
            mediaSlotsByBlockId: [
                "block_v1": .video(
                    mediaRef: MediaRef(kind: .file, id: relativePath, mediaKind: .video),
                    visibility: false,
                    placement: .defaultCover,
                    videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
                )
            ]
        )

        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            timeline: timeline,
            resources: resources,
            sceneStates: [instanceId: state]
        )

        let session = try await engine.buildExportSession()

        let snapshot = session.scenesByInstanceId[instanceId]!
        XCTAssertTrue(snapshot.videoSelections.isEmpty, "Hidden video should not appear in videoSelections")

        let audioData = session.audioSceneData.first!
        XCTAssertTrue(audioData.videoSelections.isEmpty, "Hidden video should not appear in audioSceneData.videoSelections")
    }

    /// Corrupt persisted video (exists, unreadable metadata) causes buildExportSession to throw typed error.
    @MainActor
    func testBuildExportSession_corruptPersistedVideo_throwsTypedError() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let projectsDir = try ProjectStore.shared.projectsDirectoryURL()
        let relativePath = "Media/TestVideo/corrupt_\(UUID().uuidString).mp4"
        let corruptURL = projectsDir.appendingPathComponent(relativePath)

        // Write garbage bytes — file exists but AVURLAsset.load(.duration) will fail
        try FileManager.default.createDirectory(
            at: corruptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xFF, count: 256).write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        let (timeline, resources) = makeMinimalTimeline(sceneCount: 1, framesPerScene: 60)
        let instanceId = timeline.sceneItems[0].id

        let state = SceneState(
            mediaSlotsByBlockId: [
                "block_v1": .video(
                    mediaRef: MediaRef(kind: .file, id: relativePath, mediaKind: .video),
                    placement: .defaultCover,
                    videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
                )
            ]
        )

        let engine = makeEngine(
            device: device,
            commandQueue: commandQueue,
            timeline: timeline,
            resources: resources,
            sceneStates: [instanceId: state]
        )

        do {
            _ = try await engine.buildExportSession()
            XCTFail("Expected invalidVideoSelection error for corrupt video")
        } catch let error as ExportMediaError {
            if case .invalidVideoSelection(let blockId, let reason) = error {
                XCTAssertEqual(blockId, "block_v1")
                XCTAssertTrue(reason.contains("duration"), "Reason should mention duration load failure, got: \(reason)")
            } else {
                XCTFail("Expected invalidVideoSelection, got \(error)")
            }
        }
    }
}
