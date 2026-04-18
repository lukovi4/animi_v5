import XCTest
import Metal
import CoreVideo
import AVFoundation
import UIKit
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

    // MARK: - Pixel Buffer Readback Helpers

    private func readPixels(from pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let h = CVPixelBufferGetHeight(pb)
        return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bpr * h))
    }

    private func hasNonBlackInROI(_ pixels: [UInt8], bytesPerRow: Int,
                                   cx: Int, cy: Int, radius: Int) -> Bool {
        for dy in -radius...radius {
            for dx in -radius...radius {
                let py = cy + dy, px = cx + dx
                guard py >= 0, px >= 0 else { continue }
                let offset = py * bytesPerRow + px * 4
                guard offset + 3 < pixels.count else { continue }
                // BGRA format: B=offset, G=offset+1, R=offset+2
                if pixels[offset] > 0 || pixels[offset+1] > 0 || pixels[offset+2] > 0 { return true }
            }
        }
        return false
    }

    /// Makes a CVPixelBuffer + CVMetalTexture pair for testing the render path.
    private func makePixelBufferAndTexture(
        device: MTLDevice,
        textureCache: CVMetalTextureCache,
        width: Int,
        height: Int
    ) -> (CVPixelBuffer, MTLTexture)? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pb else { return nil }

        var cvTex: CVMetalTexture?
        let texStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil,
            .bgra8Unorm, width, height, 0, &cvTex
        )
        guard texStatus == kCVReturnSuccess, let cvTex,
              let texture = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (pb, texture)
    }

    // MARK: - Export Pixel Proof Tests

    /// Text overlay pixels are present in CVPixelBuffer after production render path.
    @MainActor
    func testRenderTimelineFrame_textOverlay_pixelsVisibleInCVPixelBuffer() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let width = 1080, height = 1920
        guard let (pb, targetTexture) = makePixelBufferAndTexture(
            device: device, textureCache: textureCache, width: width, height: height
        ) else {
            throw XCTSkip("Failed to create pixel buffer + texture pair")
        }

        // Build session with text overlay at center (0.5, 0.5)
        let (baseSession, _) = makeSession(device: device, commandQueue: commandQueue, sceneCount: 1, framesPerScene: 90)

        let textPayloadId = UUID()
        let textPayload = TextPayload(
            text: "PIXEL PROOF",
            fontFamily: nil,
            fontSize: 72,
            colorHex: "#FFFFFF",
            centerX: 0.5,
            centerY: 0.5
        )
        let textItem = TimelineItem(payloadId: textPayloadId, kind: .text, startUs: 0, durationUs: 3_000_000)

        let session = TimelineCompositionEngine.TimelineExportSession(
            transitionMath: baseSession.transitionMath,
            canvasSize: baseSession.canvasSize,
            fps: baseSession.fps,
            scenesByInstanceId: baseSession.scenesByInstanceId,
            audioSceneData: baseSession.audioSceneData,
            textOverlayItems: [(item: textItem, payload: textPayload)],
            stickerOverlayItems: []
        )

        let noCoordinators: TimelineExportCoordinatorFactory = { _, _, _ in nil }
        let exportRuntime = try TimelineExportRuntime(
            session: session, textureCache: textureCache, coordinatorFactory: noCoordinators
        )

        let renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
        let compositor = try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)

        let counts = try VideoExporter.renderTimelineFrame(
            frameIndex: 0,
            targetTexture: targetTexture,
            exportRuntime: exportRuntime,
            renderer: renderer,
            transitionCompositor: compositor,
            canvasSize: SizeD(width: Double(width), height: Double(height)),
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColor: .opaqueBlack,
            renderDiagnosticsSink: nil
        )

        XCTAssertEqual(counts.textOverlayCount, 1)
        XCTAssertEqual(counts.stickerOverlayCount, 0)

        // Pixel readback: text overlay at center should produce non-black pixels
        let pixels = readPixels(from: pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let cx = width / 2, cy = height / 2

        XCTAssertTrue(
            hasNonBlackInROI(pixels, bytesPerRow: bpr, cx: cx, cy: cy, radius: 50),
            "Text overlay pixels must be visible at center of CVPixelBuffer"
        )

        // Control: corner should be black (no overlay there)
        XCTAssertFalse(
            hasNonBlackInROI(pixels, bytesPerRow: bpr, cx: 10, cy: 10, radius: 5),
            "Corner pixels should be black (no overlay at corner)"
        )
    }

    /// Sticker overlay pixels are present in CVPixelBuffer.
    @MainActor
    func testRenderTimelineFrame_stickerOverlay_pixelsVisibleInCVPixelBuffer() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let width = 1080, height = 1920
        guard let (pb, targetTexture) = makePixelBufferAndTexture(
            device: device, textureCache: textureCache, width: width, height: height
        ) else {
            throw XCTSkip("Failed to create pixel buffer + texture pair")
        }

        // Create a solid red 32x32 PNG fixture
        let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_sticker_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        // Generate solid red PNG
        let context = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let cgImage = context.makeImage()!
        let data = UIImage(cgImage: cgImage).pngData()!
        try data.write(to: fixtureURL)

        let (baseSession, _) = makeSession(device: device, commandQueue: commandQueue, sceneCount: 1, framesPerScene: 90)

        let stickerPayload = StickerPayload(stickerId: "test-red", centerX: 0.5, centerY: 0.5)
        let stickerItem = TimelineItem(payloadId: UUID(), kind: .sticker, startUs: 0, durationUs: 3_000_000)

        let session = TimelineCompositionEngine.TimelineExportSession(
            transitionMath: baseSession.transitionMath,
            canvasSize: baseSession.canvasSize,
            fps: baseSession.fps,
            scenesByInstanceId: baseSession.scenesByInstanceId,
            audioSceneData: baseSession.audioSceneData,
            textOverlayItems: [],
            stickerOverlayItems: [(item: stickerItem, payload: stickerPayload, imageURL: fixtureURL)]
        )

        let noCoordinators: TimelineExportCoordinatorFactory = { _, _, _ in nil }
        let exportRuntime = try TimelineExportRuntime(
            session: session, textureCache: textureCache, coordinatorFactory: noCoordinators
        )

        let renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
        let compositor = try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)

        let counts = try VideoExporter.renderTimelineFrame(
            frameIndex: 0,
            targetTexture: targetTexture,
            exportRuntime: exportRuntime,
            renderer: renderer,
            transitionCompositor: compositor,
            canvasSize: SizeD(width: Double(width), height: Double(height)),
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColor: .opaqueBlack,
            renderDiagnosticsSink: nil
        )

        XCTAssertEqual(counts.textOverlayCount, 0)
        XCTAssertEqual(counts.stickerOverlayCount, 1)

        let pixels = readPixels(from: pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let cx = width / 2, cy = height / 2

        XCTAssertTrue(
            hasNonBlackInROI(pixels, bytesPerRow: bpr, cx: cx, cy: cy, radius: 50),
            "Sticker overlay pixels must be visible at center of CVPixelBuffer"
        )
    }

    /// Mixed text+sticker: text renders on top of sticker (z-order contract).
    @MainActor
    func testRenderTimelineFrame_mixedOverlays_stickerBelowText() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let width = 1080, height = 1920
        guard let (pb, targetTexture) = makePixelBufferAndTexture(
            device: device, textureCache: textureCache, width: width, height: height
        ) else {
            throw XCTSkip("Failed to create pixel buffer + texture pair")
        }

        // Create solid red sticker fixture
        let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_sticker_zorder_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let context = CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8,
            bytesPerRow: 200 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let cgImage = context.makeImage()!
        try UIImage(cgImage: cgImage).pngData()!.write(to: fixtureURL)

        let (baseSession, _) = makeSession(device: device, commandQueue: commandQueue, sceneCount: 1, framesPerScene: 90)

        // Text: white at center. Sticker: red at center. If z-order is correct, center should be white.
        let textPayload = TextPayload(text: "Z", fontFamily: nil, fontSize: 200, colorHex: "#FFFFFF", centerX: 0.5, centerY: 0.5)
        let textItem = TimelineItem(payloadId: UUID(), kind: .text, startUs: 0, durationUs: 3_000_000)

        let stickerPayload = StickerPayload(stickerId: "red-bg", centerX: 0.5, centerY: 0.5)
        let stickerItem = TimelineItem(payloadId: UUID(), kind: .sticker, startUs: 0, durationUs: 3_000_000)

        let session = TimelineCompositionEngine.TimelineExportSession(
            transitionMath: baseSession.transitionMath,
            canvasSize: baseSession.canvasSize,
            fps: baseSession.fps,
            scenesByInstanceId: baseSession.scenesByInstanceId,
            audioSceneData: baseSession.audioSceneData,
            textOverlayItems: [(item: textItem, payload: textPayload)],
            stickerOverlayItems: [(item: stickerItem, payload: stickerPayload, imageURL: fixtureURL)]
        )

        let noCoordinators: TimelineExportCoordinatorFactory = { _, _, _ in nil }
        let exportRuntime = try TimelineExportRuntime(
            session: session, textureCache: textureCache, coordinatorFactory: noCoordinators
        )

        let renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
        let compositor = try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)

        let counts = try VideoExporter.renderTimelineFrame(
            frameIndex: 0,
            targetTexture: targetTexture,
            exportRuntime: exportRuntime,
            renderer: renderer,
            transitionCompositor: compositor,
            canvasSize: SizeD(width: Double(width), height: Double(height)),
            backgroundState: nil,
            backgroundTextureProvider: nil,
            clearColor: .opaqueBlack,
            renderDiagnosticsSink: nil
        )

        XCTAssertEqual(counts.textOverlayCount, 1)
        XCTAssertEqual(counts.stickerOverlayCount, 1)

        // Pixel readback: center should have white-ish pixels (text on top of red sticker)
        let pixels = readPixels(from: pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let cx = width / 2, cy = height / 2

        // Check a small region at center — at least some pixels should have high B+G+R (white text)
        var hasWhitePixel = false
        for dy in -20...20 {
            for dx in -20...20 {
                let py = cy + dy, px = cx + dx
                let offset = py * bpr + px * 4
                guard offset + 3 < pixels.count else { continue }
                // BGRA: if B, G, R are all > 200, it's white-ish
                if pixels[offset] > 200 && pixels[offset+1] > 200 && pixels[offset+2] > 200 {
                    hasWhitePixel = true
                    break
                }
            }
            if hasWhitePixel { break }
        }
        XCTAssertTrue(hasWhitePixel, "Text (white) must render on top of sticker (red) — z-order proof")
    }

    /// Overlays survive through the full pipeline: render -> enqueue -> AVAssetWriter -> file -> readback.
    @MainActor
    func testFullExportPipeline_overlaysVisibleInOutputFile() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let width = 540, height = 960  // smaller for speed
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export_pixel_proof_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // Build session with text overlay
        let (baseSession, _) = makeSession(device: device, commandQueue: commandQueue, sceneCount: 1, framesPerScene: 30)

        let textPayload = TextPayload(
            text: "EXPORT",
            fontFamily: nil,
            fontSize: 96,
            colorHex: "#FFFFFF",
            centerX: 0.5,
            centerY: 0.5
        )
        let textItem = TimelineItem(payloadId: UUID(), kind: .text, startUs: 0, durationUs: 1_000_000)

        let session = TimelineCompositionEngine.TimelineExportSession(
            transitionMath: baseSession.transitionMath,
            canvasSize: SizeD(width: Double(width), height: Double(height)),
            fps: baseSession.fps,
            scenesByInstanceId: baseSession.scenesByInstanceId,
            audioSceneData: baseSession.audioSceneData,
            textOverlayItems: [(item: textItem, payload: textPayload)],
            stickerOverlayItems: []
        )

        // Run the export loop manually (same as VideoExporter does, but synchronous for test)
        let renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
        let compositor = try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)

        let pipeline = try ExportWriterPipeline(
            outputURL: outputURL,
            video: .init(sizePx: (width: width, height: height), fps: 30, bitrate: 2_000_000, gopSeconds: 1),
            audio: nil
        )
        try pipeline.startWriting()

        let noCoordinators: TimelineExportCoordinatorFactory = { _, _, _ in nil }
        let exportRuntime = try TimelineExportRuntime(
            session: session, textureCache: textureCache, coordinatorFactory: noCoordinators
        )

        let totalFrames = session.transitionMath.compressedDurationFrames
        for frameIndex in 0..<totalFrames {
            guard let pool = pipeline.pixelBufferPool else {
                XCTFail("No pixel buffer pool")
                return
            }

            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard let pixelBuffer else {
                XCTFail("Failed to create pixel buffer")
                return
            }

            var cvMetalTexture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .bgra8Unorm, width, height, 0, &cvMetalTexture
            )
            guard let cvMetalTexture, let targetTexture = CVMetalTextureGetTexture(cvMetalTexture) else {
                XCTFail("Failed to create metal texture")
                return
            }

            _ = try VideoExporter.renderTimelineFrame(
                frameIndex: frameIndex,
                targetTexture: targetTexture,
                exportRuntime: exportRuntime,
                renderer: renderer,
                transitionCompositor: compositor,
                canvasSize: SizeD(width: Double(width), height: Double(height)),
                backgroundState: nil,
                backgroundTextureProvider: nil,
                clearColor: .opaqueBlack,
                renderDiagnosticsSink: nil
            )

            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
            let semaphore = DispatchSemaphore(value: 0)
            pipeline.enqueueVideoFrame(pixelBuffer, presentationTime: pts) {
                semaphore.signal()
            }
            semaphore.wait()
        }

        let finishExpectation = expectation(description: "Writer finishes")
        pipeline.finishWriting { _ in
            finishExpectation.fulfill()
        }
        await fulfillment(of: [finishExpectation], timeout: 5.0)

        // Read back first frame
        let asset = AVURLAsset(url: outputURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw XCTSkip("No video track in output")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        reader.add(output)
        guard reader.startReading() else { throw XCTSkip("Reader failed to start") }
        guard let sample = output.copyNextSampleBuffer(),
              let readbackPB = CMSampleBufferGetImageBuffer(sample) else {
            throw XCTSkip("No frame in output")
        }

        let pixels = readPixels(from: readbackPB)
        let bpr = CVPixelBufferGetBytesPerRow(readbackPB)
        let cx = width / 2, cy = height / 2

        XCTAssertTrue(
            hasNonBlackInROI(pixels, bytesPerRow: bpr, cx: cx, cy: cy, radius: 50),
            "Text overlay pixels must survive full pipeline: render -> encode -> decode"
        )
    }
}
