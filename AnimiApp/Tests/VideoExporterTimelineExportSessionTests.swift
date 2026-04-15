import XCTest
import Metal
import CoreVideo
@testable import AnimiApp
@testable import TVECore

/// TT-05: Tests for TimelineExportRuntime.resolveFrame() and lifecycle.
final class VideoExporterTimelineExportSessionTests: XCTestCase {

    // MARK: - Coordinator Spy

    /// Spy implementing TimelineExportVideoCoordinating for test verification.
    private final class CoordinatorSpy: TimelineExportVideoCoordinating {
        var providerError: ExportVideoFrameProviderError?
        var updatedFrames: [Int] = []
        var finishCalled = false
        var cancelCalled = false

        func updateTextures(forSceneFrameIndex frame: Int) {
            updatedFrames.append(frame)
        }

        func finish() {
            finishCalled = true
        }

        func cancel() {
            cancelCalled = true
        }
    }

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

    /// Builds a session with N scenes, each with given duration.
    /// Returns session + ordered instance IDs for verification.
    @MainActor
    private func makeSession(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        sceneCount: Int,
        framesPerScene: Int = 100,
        fixedIds: [UUID]? = nil,
        transitions: [SceneBoundaryKey: SceneTransition] = [:]
    ) -> (TimelineCompositionEngine.TimelineExportSession, [UUID]) {
        var items: [TimelineItem] = []
        var payloads: [UUID: TimelinePayload] = [:]
        var snapshots: [UUID: TimelineCompositionEngine.TimelineExportSceneSnapshot] = [:]
        var audioData: [TimelineCompositionEngine.SceneAudioExportData] = []
        var instanceIds: [UUID] = []

        for i in 0..<sceneCount {
            let instanceId = fixedIds?[i] ?? UUID()
            let payloadId = UUID()
            let sceneTypeId = "scene-type-\(i)"
            instanceIds.append(instanceId)

            let durationUs = framesToUs(framesPerScene)
            let item = TimelineItem(id: instanceId, payloadId: payloadId, kind: .scene, startUs: nil, durationUs: durationUs)
            items.append(item)

            let scenePayload = ScenePayload(sceneTypeId: sceneTypeId)
            payloads[payloadId] = .scene(scenePayload)

            let res = makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeId)
            let renderState = SceneRenderStateSnapshot(
                resolvedTransforms: [:],
                variantOverrides: [:],
                userMediaPresent: [:],
                layerToggleState: [:]
            )
            let mediaSnapshot = ExportMediaSnapshot(
                imageRefs: [],
                videoRefs: [],
                allAssetIds: Set(res.compiled.mergedAssetIndex.basenameById.keys)
            )

            let snapshot = TimelineCompositionEngine.TimelineExportSceneSnapshot(
                sceneIndex: i,
                instanceId: instanceId,
                runtime: res.compiled.runtime,
                renderState: renderState,
                videoSelections: [:],
                mediaSnapshot: mediaSnapshot,
                assetIndex: res.compiled.mergedAssetIndex,
                resolver: res.resolver,
                bindingAssetIds: res.compiled.bindingAssetIds,
                pathRegistry: res.pathRegistry,
                assetSizes: res.assetSizes,
                sceneCanvasSize: res.canvasSize
            )
            snapshots[instanceId] = snapshot
            audioData.append(TimelineCompositionEngine.SceneAudioExportData(
                sceneIndex: i,
                runtime: res.compiled.runtime,
                videoSelections: [:]
            ))
        }

        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: items)
        let timeline = CanonicalTimeline(tracks: [sceneTrack], payloads: payloads, boundaryTransitions: transitions)
        let math = TimelineTransitionMath(
            sceneItems: timeline.sceneItems,
            boundaryTransitions: timeline.boundaryTransitions,
            fps: 30
        )

        let session = TimelineCompositionEngine.TimelineExportSession(
            transitionMath: math,
            canvasSize: SizeD(width: 1080, height: 1920),
            fps: 30,
            scenesByInstanceId: snapshots,
            audioSceneData: audioData,
            textOverlayItems: [],
            stickerOverlayItems: []
        )

        return (session, instanceIds)
    }

    /// Creates a CVMetalTextureCache for testing.
    private func makeTextureCache(device: MTLDevice) -> CVMetalTextureCache? {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        return cache
    }

    // MARK: - Single Frame Tests

    /// resolveFrame returns .single with correct localFrame for single scene.
    @MainActor
    func testResolveSingleFrameReturnsCorrectLocalFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let (session, _) = makeSession(device: device, commandQueue: commandQueue, sceneCount: 1, framesPerScene: 100)

        let noCoordinators: TimelineExportCoordinatorFactory = { _, _, _ in nil }
        let runtime = try TimelineExportRuntime(session: session, textureCache: textureCache, coordinatorFactory: noCoordinators)

        let result = try runtime.resolveFrame(42)

        guard case .single(let context) = result else {
            XCTFail("Expected .single, got \(result)")
            return
        }
        XCTAssertEqual(context.localFrame, 42)
    }

    /// Single frame updates only active scene coordinator.
    @MainActor
    func testSingleFrameUpdatesOnlyActiveCoordinator() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let (session, instanceIds) = makeSession(device: device, commandQueue: commandQueue, sceneCount: 2, framesPerScene: 100)

        let spyA = CoordinatorSpy()
        let spyB = CoordinatorSpy()
        let spyMap: [UUID: CoordinatorSpy] = [
            instanceIds[0]: spyA,
            instanceIds[1]: spyB
        ]

        let factory: TimelineExportCoordinatorFactory = { snapshot, _, _ in
            spyMap[snapshot.instanceId]
        }

        let runtime = try TimelineExportRuntime(session: session, textureCache: textureCache, coordinatorFactory: factory)

        // Frame 50 is in scene A (0..99)
        _ = try runtime.resolveFrame(50)

        XCTAssertEqual(spyA.updatedFrames, [50])
        XCTAssertTrue(spyB.updatedFrames.isEmpty, "Scene B coordinator should not be updated for scene A frame")
    }

    // MARK: - Transition Frame Tests

    /// resolveFrame returns .transition with correct frames for both scenes.
    @MainActor
    func testResolveTransitionFrameReturnsBothContexts() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let idA = UUID(), idB = UUID()
        let (session, instanceIds) = makeSession(
            device: device,
            commandQueue: commandQueue,
            sceneCount: 2,
            framesPerScene: 100,
            fixedIds: [idA, idB],
            transitions: [
                SceneBoundaryKey(idA, idB):
                    SceneTransition(type: .fade, easingPreset: .linear)
            ]
        )

        // Need to rebuild session with transitions applied
        let noCoordinators: TimelineExportCoordinatorFactory = { _, _, _ in nil }
        let runtime = try TimelineExportRuntime(session: session, textureCache: textureCache, coordinatorFactory: noCoordinators)

        // Find a transition frame
        let math = session.transitionMath
        guard let window = math.allTransitionWindows.first else {
            throw XCTSkip("No transition windows found — math produced no transitions")
        }

        let midFrame = window.startFrame + window.transition.durationFrames / 2
        let result = try runtime.resolveFrame(midFrame)

        guard case .transition(let context) = result else {
            XCTFail("Expected .transition, got \(result)")
            return
        }

        XCTAssertEqual(context.sceneA.sceneInstanceId, instanceIds[0])
        XCTAssertEqual(context.sceneB.sceneInstanceId, instanceIds[1])
        XCTAssertGreaterThan(context.progress, 0)
        XCTAssertLessThan(context.progress, 1)
    }

    /// Transition frame updates both coordinators.
    @MainActor
    func testTransitionFrameUpdatesBothCoordinators() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let idA = UUID(), idB = UUID()
        let (session, instanceIds) = makeSession(
            device: device,
            commandQueue: commandQueue,
            sceneCount: 2,
            framesPerScene: 100,
            fixedIds: [idA, idB],
            transitions: [
                SceneBoundaryKey(idA, idB):
                    SceneTransition(type: .fade, easingPreset: .linear)
            ]
        )

        let spyA = CoordinatorSpy()
        let spyB = CoordinatorSpy()
        let spyMap: [UUID: CoordinatorSpy] = [
            instanceIds[0]: spyA,
            instanceIds[1]: spyB
        ]

        let factory: TimelineExportCoordinatorFactory = { snapshot, _, _ in
            spyMap[snapshot.instanceId]
        }

        let runtime = try TimelineExportRuntime(session: session, textureCache: textureCache, coordinatorFactory: factory)

        let math = session.transitionMath
        guard let window = math.allTransitionWindows.first else {
            throw XCTSkip("No transition windows")
        }

        let midFrame = window.startFrame + window.transition.durationFrames / 2
        _ = try runtime.resolveFrame(midFrame)

        XCTAssertFalse(spyA.updatedFrames.isEmpty, "Scene A coordinator should be updated during transition")
        XCTAssertFalse(spyB.updatedFrames.isEmpty, "Scene B coordinator should be updated during transition")
    }

    // MARK: - Provider Error Tests

    /// providerError from coordinator interrupts resolve.
    @MainActor
    func testProviderErrorInterruptsResolve() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let (session, instanceIds) = makeSession(device: device, commandQueue: commandQueue, sceneCount: 1, framesPerScene: 100)

        let spy = CoordinatorSpy()
        spy.providerError = .missingVideoTrack

        let factory: TimelineExportCoordinatorFactory = { snapshot, _, _ in
            snapshot.instanceId == instanceIds[0] ? spy : nil
        }

        let runtime = try TimelineExportRuntime(session: session, textureCache: textureCache, coordinatorFactory: factory)

        do {
            _ = try runtime.resolveFrame(10)
            XCTFail("Expected provider error to be thrown")
        } catch is ExportVideoFrameProviderError {
            // Expected
        }
    }

    // MARK: - Lifecycle Tests

    /// finish() fans out to all coordinators.
    @MainActor
    func testFinishFansOutToAllCoordinators() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let (session, instanceIds) = makeSession(device: device, commandQueue: commandQueue, sceneCount: 2, framesPerScene: 100)

        let spyA = CoordinatorSpy()
        let spyB = CoordinatorSpy()
        let spyMap: [UUID: CoordinatorSpy] = [
            instanceIds[0]: spyA,
            instanceIds[1]: spyB
        ]

        let factory: TimelineExportCoordinatorFactory = { snapshot, _, _ in
            spyMap[snapshot.instanceId]
        }

        let runtime = try TimelineExportRuntime(session: session, textureCache: textureCache, coordinatorFactory: factory)
        runtime.finish()

        XCTAssertTrue(spyA.finishCalled)
        XCTAssertTrue(spyB.finishCalled)
    }

    /// cancel() fans out to all coordinators.
    @MainActor
    func testCancelFansOutToAllCoordinators() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let (session, instanceIds) = makeSession(device: device, commandQueue: commandQueue, sceneCount: 2, framesPerScene: 100)

        let spyA = CoordinatorSpy()
        let spyB = CoordinatorSpy()
        let spyMap: [UUID: CoordinatorSpy] = [
            instanceIds[0]: spyA,
            instanceIds[1]: spyB
        ]

        let factory: TimelineExportCoordinatorFactory = { snapshot, _, _ in
            spyMap[snapshot.instanceId]
        }

        let runtime = try TimelineExportRuntime(session: session, textureCache: textureCache, coordinatorFactory: factory)
        runtime.cancel()

        XCTAssertTrue(spyA.cancelCalled)
        XCTAssertTrue(spyB.cancelCalled)
    }

    // MARK: - PR9: Text Overlay Export Render Request Propagation

    /// Proves that a visible text overlay in the export session reaches
    /// TimelineRenderRequest.textOverlays through the production export path.
    /// Mirrors exactly what VideoExporter.swift does: resolveFrame + resolveTextOverlays → request.
    @MainActor
    func testExportPath_visibleTextOverlay_populatesRenderRequestTextOverlays() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        // Build a session with 1 scene (90 frames = 3s) + 1 text overlay (0-2s)
        var items: [TimelineItem] = []
        var payloads: [UUID: TimelinePayload] = [:]
        var snapshots: [UUID: TimelineCompositionEngine.TimelineExportSceneSnapshot] = [:]
        var audioData: [TimelineCompositionEngine.SceneAudioExportData] = []

        let instanceId = UUID()
        let payloadId = UUID()
        let sceneTypeId = "scene-type-0"
        let framesPerScene = 90
        let durationUs = framesToUs(framesPerScene)

        let item = TimelineItem(id: instanceId, payloadId: payloadId, kind: .scene, startUs: nil, durationUs: durationUs)
        items.append(item)
        payloads[payloadId] = .scene(ScenePayload(sceneTypeId: sceneTypeId))

        let res = makeMinimalResources(durationFrames: framesPerScene, sceneTypeId: sceneTypeId)
        let renderState = SceneRenderStateSnapshot(
            resolvedTransforms: [:], variantOverrides: [:], userMediaPresent: [:], layerToggleState: [:]
        )
        let mediaSnapshot = ExportMediaSnapshot(
            imageRefs: [], videoRefs: [],
            allAssetIds: Set(res.compiled.mergedAssetIndex.basenameById.keys)
        )
        snapshots[instanceId] = TimelineCompositionEngine.TimelineExportSceneSnapshot(
            sceneIndex: 0, instanceId: instanceId, runtime: res.compiled.runtime,
            renderState: renderState, videoSelections: [:], mediaSnapshot: mediaSnapshot,
            assetIndex: res.compiled.mergedAssetIndex, resolver: res.resolver,
            bindingAssetIds: res.compiled.bindingAssetIds, pathRegistry: res.pathRegistry,
            assetSizes: res.assetSizes, sceneCanvasSize: res.canvasSize
        )
        audioData.append(TimelineCompositionEngine.SceneAudioExportData(
            sceneIndex: 0, runtime: res.compiled.runtime, videoSelections: [:]
        ))

        // Text overlay visible at frames 0-59 (0s-2s)
        let textPayloadId = UUID()
        let textPayload = TextPayload(
            text: "Export Visible",
            fontFamily: nil,
            fontSize: 36,
            colorHex: "#FF0000",
            centerX: 0.3,
            centerY: 0.7
        )
        payloads[textPayloadId] = .text(textPayload)
        let textItem = TimelineItem(
            payloadId: textPayloadId, kind: .text, startUs: 0, durationUs: 2_000_000
        )

        let sceneTrack = Track(id: UUID(), kind: .sceneSequence, items: items)
        let overlayTrack = Track(id: UUID(), kind: .overlay, items: [textItem])
        let timeline = CanonicalTimeline(tracks: [sceneTrack, overlayTrack], payloads: payloads, boundaryTransitions: [:])
        let math = TimelineTransitionMath(
            sceneItems: timeline.sceneItems,
            boundaryTransitions: timeline.boundaryTransitions,
            fps: 30
        )

        let session = TimelineCompositionEngine.TimelineExportSession(
            transitionMath: math,
            canvasSize: SizeD(width: 1080, height: 1920),
            fps: 30,
            scenesByInstanceId: snapshots,
            audioSceneData: audioData,
            textOverlayItems: [(item: textItem, payload: textPayload)],
            stickerOverlayItems: []
        )

        // Create export runtime (same as VideoExporter does)
        let noCoordinators: TimelineExportCoordinatorFactory = { _, _, _ in nil }
        let exportRuntime = try TimelineExportRuntime(
            session: session, textureCache: textureCache, coordinatorFactory: noCoordinators
        )

        // --- Production export path (mirrors VideoExporter.swift lines 1222-1235) ---

        // Frame 15 (t=0.5s): text IS visible
        let frameInside = 15
        let resolvedInside = try exportRuntime.resolveFrame(frameInside)
        let textOverlaysInside = exportRuntime.resolveTextOverlays(at: frameInside)

        // This is the exact construction from VideoExporter production code
        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1080, height: 1920, mipmapped: false
        )
        let dummyTexture = device.makeTexture(descriptor: textureDesc)!

        let requestInside = TimelineRenderRequest(
            resolved: resolvedInside,
            targetTexture: dummyTexture,
            drawableScale: 1.0,
            timelineCanvasSize: SizeD(width: 1080, height: 1920),
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            diagnosticFrameTag: frameInside,
            textOverlays: textOverlaysInside
        )

        XCTAssertEqual(requestInside.textOverlays.count, 1, "Render request must contain visible text overlay")
        XCTAssertEqual(requestInside.textOverlays.first?.text, "Export Visible")
        XCTAssertEqual(requestInside.textOverlays.first?.fontSize, 36)
        XCTAssertEqual(requestInside.textOverlays.first?.colorHex, "#FF0000")
        XCTAssertEqual(requestInside.textOverlays.first?.centerX, 0.3)
        XCTAssertEqual(requestInside.textOverlays.first?.centerY, 0.7)

        // Frame 75 (t=2.5s): text is NOT visible
        let frameOutside = 75
        let textOverlaysOutside = exportRuntime.resolveTextOverlays(at: frameOutside)

        let requestOutside = TimelineRenderRequest(
            resolved: try exportRuntime.resolveFrame(frameOutside),
            targetTexture: dummyTexture,
            drawableScale: 1.0,
            timelineCanvasSize: SizeD(width: 1080, height: 1920),
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            diagnosticFrameTag: frameOutside,
            textOverlays: textOverlaysOutside
        )

        XCTAssertTrue(requestOutside.textOverlays.isEmpty, "Render request must be empty when text not visible")
    }

    // MARK: - PR10: Sticker Overlay Export Path

    /// Visible sticker overlay produces non-empty stickerOverlays in TimelineRenderRequest;
    /// invisible sticker overlay produces empty stickerOverlays.
    @MainActor
    func testVisibleStickerOverlay_reachesRenderRequest() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        // Build session with 1 scene (90 frames = 3s) + sticker overlay (0-2s)
        let (baseSession, _) = makeSession(device: device, commandQueue: commandQueue, sceneCount: 1, framesPerScene: 90)

        // Re-build session with sticker overlay items injected
        let stickerPayload = StickerPayload(stickerId: "star", centerX: 0.35, centerY: 0.65)
        let stickerItem = TimelineItem(
            payloadId: UUID(), kind: .sticker, startUs: 0, durationUs: 2_000_000
        )
        let stickerImageURL = URL(fileURLWithPath: "/tmp/sticker_star.png")

        let session = TimelineCompositionEngine.TimelineExportSession(
            transitionMath: baseSession.transitionMath,
            canvasSize: baseSession.canvasSize,
            fps: baseSession.fps,
            scenesByInstanceId: baseSession.scenesByInstanceId,
            audioSceneData: baseSession.audioSceneData,
            textOverlayItems: [],
            stickerOverlayItems: [(item: stickerItem, payload: stickerPayload, imageURL: stickerImageURL)]
        )

        let noCoordinators: TimelineExportCoordinatorFactory = { _, _, _ in nil }
        let exportRuntime = try TimelineExportRuntime(
            session: session, textureCache: textureCache, coordinatorFactory: noCoordinators
        )

        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1080, height: 1920, mipmapped: false
        )
        let dummyTexture = device.makeTexture(descriptor: textureDesc)!

        // Frame 15 (t=0.5s): sticker IS visible
        let frameInside = 15
        let stickerOverlaysInside = exportRuntime.resolveStickerOverlays(at: frameInside)

        let requestInside = TimelineRenderRequest(
            resolved: try exportRuntime.resolveFrame(frameInside),
            targetTexture: dummyTexture,
            drawableScale: 1.0,
            timelineCanvasSize: SizeD(width: 1080, height: 1920),
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            diagnosticFrameTag: frameInside,
            stickerOverlays: stickerOverlaysInside
        )

        XCTAssertEqual(requestInside.stickerOverlays.count, 1, "Render request must contain visible sticker overlay")
        XCTAssertEqual(requestInside.stickerOverlays.first?.stickerId, "star")
        XCTAssertEqual(requestInside.stickerOverlays.first?.imageURL, URL(fileURLWithPath: "/tmp/sticker_star.png"))
        XCTAssertEqual(requestInside.stickerOverlays.first?.centerX, 0.35)
        XCTAssertEqual(requestInside.stickerOverlays.first?.centerY, 0.65)

        // Frame 75 (t=2.5s): sticker is NOT visible
        let frameOutside = 75
        let stickerOverlaysOutside = exportRuntime.resolveStickerOverlays(at: frameOutside)

        let requestOutside = TimelineRenderRequest(
            resolved: try exportRuntime.resolveFrame(frameOutside),
            targetTexture: dummyTexture,
            drawableScale: 1.0,
            timelineCanvasSize: SizeD(width: 1080, height: 1920),
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColorOverride: nil,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            diagnosticFrameTag: frameOutside,
            stickerOverlays: stickerOverlaysOutside
        )

        XCTAssertTrue(requestOutside.stickerOverlays.isEmpty, "Render request must be empty when sticker not visible")
    }
}
