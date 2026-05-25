import AVFoundation
import CoreVideo
import ImageIO
import Metal
import TVECore

// MARK: - Single-Scene Video Export Runner

/// Stateless runner for single-scene video export.
/// Called on `exportQueue` with a fully-built work item.
internal final class SingleSceneVideoExportRunner {

    // MARK: - Work Item

    internal final class WorkItem: @unchecked Sendable {
        let runtime: SceneRuntime
        let snapshot: SceneRenderStateSnapshot
        let renderer: MetalRenderer
        let textureProvider: ExportTextureProvider
        let pathRegistry: PathRegistry
        let assetSizes: [String: AssetSize]
        let videoSelections: [String: VideoSelection]
        let settings: VideoExportSettings
        let backgroundState: EffectiveBackgroundState?
        let overlaySnapshot: OverlayExportSnapshot?
        let mediaSnapshot: ExportMediaSnapshot?
        let backgroundSnapshot: ExportBackgroundSnapshot?
        let budget: ExportResourceBudget

        init(
            runtime: SceneRuntime,
            snapshot: SceneRenderStateSnapshot,
            renderer: MetalRenderer,
            textureProvider: ExportTextureProvider,
            pathRegistry: PathRegistry,
            assetSizes: [String: AssetSize],
            videoSelections: [String: VideoSelection],
            settings: VideoExportSettings,
            backgroundState: EffectiveBackgroundState?,
            overlaySnapshot: OverlayExportSnapshot? = nil,
            mediaSnapshot: ExportMediaSnapshot? = nil,
            backgroundSnapshot: ExportBackgroundSnapshot? = nil,
            budget: ExportResourceBudget = .default
        ) {
            self.runtime = runtime
            self.snapshot = snapshot
            self.renderer = renderer
            self.textureProvider = textureProvider
            self.pathRegistry = pathRegistry
            self.assetSizes = assetSizes
            self.videoSelections = videoSelections
            self.settings = settings
            self.backgroundState = backgroundState
            self.overlaySnapshot = overlaySnapshot
            self.mediaSnapshot = mediaSnapshot
            self.backgroundSnapshot = backgroundSnapshot
            self.budget = budget
        }
    }

    // MARK: - Run

    static func run(
        workItem: WorkItem,
        session: ExportSession,
        allAssetIds: Set<String>,
        resolvedBgURLs: [MediaRef: URL],
        progress: @escaping (Double) -> Void
    ) {
        #if DEBUG
        let setupStartNs = DispatchTime.now().uptimeNanoseconds
        #else
        let setupStartNs: UInt64 = 0
        #endif
        if session.completeIfCancelled() { return }

        // Warm all scene assets (unified API — same behavior as old preloadAll)
        workItem.textureProvider.warm(assetIds: allAssetIds, commandQueue: workItem.renderer.commandQueue)
        #if DEBUG
        let warmEndNs = DispatchTime.now().uptimeNanoseconds
        #else
        let warmEndNs: UInt64 = 0
        #endif

        if session.completeIfCancelled() { return }

        // Load user photos on export queue (not MainActor)
        if let mediaSnapshot = workItem.mediaSnapshot {
            let commandQueue = workItem.renderer.commandQueue
            for imageRef in mediaSnapshot.imageRefs {
                if let texture = try? DownsampledImageLoader.loadTexture(
                    from: imageRef.url,
                    device: commandQueue.device,
                    commandQueue: commandQueue,
                    maxDimensionPx: workItem.budget.targetImageMaxDimensionPx
                ) {
                    // PR-F: Probe original file size for display size metadata.
                    // Export placement is resolved from file probe dimensions, so renderer
                    // quad geometry must match. Using texture.width/height would mismatch
                    // when the image is downsampled below source resolution.
                    let probeSize = probeImageSize(url: imageRef.url)
                        ?? CGSize(width: texture.width, height: texture.height)

                    for assetId in imageRef.bindingAssetIds {
                        workItem.textureProvider.setTexture(texture, for: assetId)
                        (workItem.textureProvider as? MutableAssetDisplaySizeProvider)?
                            .setDisplaySize(probeSize, for: assetId)
                    }
                }
            }
        }

        #if DEBUG
        let photoEndNs = DispatchTime.now().uptimeNanoseconds
        #else
        let photoEndNs: UInt64 = 0
        #endif

        if session.completeIfCancelled() { return }

        // Load background textures on export queue (URLs pre-resolved above)
        if let bgSnapshot = workItem.backgroundSnapshot {
            let commandQueue = workItem.renderer.commandQueue
            for ref in bgSnapshot.regionRefs {
                if let url = resolvedBgURLs[ref.mediaRef] {
                    if let texture = try? DownsampledImageLoader.loadTexture(
                        from: url,
                        device: commandQueue.device,
                        commandQueue: commandQueue,
                        maxDimensionPx: workItem.budget.targetImageMaxDimensionPx
                    ) {
                        workItem.textureProvider.setTexture(texture, for: ref.slotKey)
                    }
                }
            }
        }

        #if DEBUG
        let bgEndNs = DispatchTime.now().uptimeNanoseconds
        #else
        let bgEndNs: UInt64 = 0
        #endif

        guard !session.isCancelled else {
            session.complete(with: .failure(VideoExportError.cancelled))
            return
        }

        runExportLoop(
            workItem: workItem,
            session: session,
            progress: progress,
            debugSetupStartNs: setupStartNs,
            debugWarmEndNs: warmEndNs,
            debugPhotoEndNs: photoEndNs,
            debugBgEndNs: bgEndNs
        )
    }

    // MARK: - Export Loop

    private static func runExportLoop(
        workItem: WorkItem,
        session: ExportSession,
        progress: @escaping (Double) -> Void,
        debugSetupStartNs: UInt64 = 0,
        debugWarmEndNs: UInt64 = 0,
        debugPhotoEndNs: UInt64 = 0,
        debugBgEndNs: UInt64 = 0
    ) {
        #if DEBUG
        let loopSetupStartNs = DispatchTime.now().uptimeNanoseconds
        #endif
        let runtime = workItem.runtime
        let snapshot = workItem.snapshot
        let renderer = workItem.renderer
        let textureProvider = workItem.textureProvider
        let pathRegistry = workItem.pathRegistry
        let assetSizes = workItem.assetSizes
        let videoSelections = workItem.videoSelections
        let settings = workItem.settings
        let backgroundState = workItem.backgroundState
        let overlaySnapshot = workItem.overlaySnapshot
        let budget = workItem.budget

        // Delete existing file if present
        try? FileManager.default.removeItem(at: settings.outputURL)

        if session.completeIfCancelled() { return }

        // 1. Build audio pipeline (prefer plan, fallback to legacy config)
        var audioPipeline: BuiltAudioPipeline?

        if let plan = settings.audioPlan ?? settings.audio?.toPlan() {
            let builder = AudioCompositionBuilder()
            do {
                audioPipeline = try builder.build(
                    runtime: runtime,
                    fps: settings.fps,
                    videoSelectionsByBlockId: videoSelections,
                    plan: plan
                )
            } catch {
                session.complete(with: .failure(VideoExportError.failedToBuildAudioPipeline(error)))
                return
            }
        }
        #if DEBUG
        let audioEndNs = DispatchTime.now().uptimeNanoseconds
        #endif

        if session.completeIfCancelled() { return }

        // 2. Create pipeline (replaces ~100 lines of writer setup)
        let pipeline: ExportWriterPipeline
        do {
            pipeline = try ExportWriterPipeline(
                outputURL: settings.outputURL,
                video: .init(sizePx: settings.sizePx, fps: settings.fps,
                             bitrate: settings.bitrate, gopSeconds: settings.gopSeconds),
                audio: audioPipeline.map { .init(composition: $0.composition, audioMix: $0.audioMix) }
            )
            session.attachPipeline(pipeline)
            if session.completeIfCancelled() { return }
            try pipeline.startWriting()
        } catch {
            session.complete(with: .failure(error))
            return
        }
        if session.completeIfCancelled() { return }
        #if DEBUG
        let writerEndNs = DispatchTime.now().uptimeNanoseconds
        #endif

        // 3. Create CVMetalTextureCache
        let metalDevice = renderer.commandQueue.device
        var textureCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            metalDevice,
            nil,
            &textureCache
        )

        guard cacheStatus == kCVReturnSuccess, let textureCache else {
            pipeline.cancel()
            session.complete(with: .failure(VideoExportError.failedToCreateTextureCache))
            return
        }
        #if DEBUG
        MemoryDiagnostics.event("CVTextureCache.create", "owner=SingleSceneExport")
        let cacheEndNs = DispatchTime.now().uptimeNanoseconds
        #endif

        // 4. Setup video slots coordinator
        var videoSlotsCoordinator: ExportVideoSlotsCoordinator?
        if !videoSelections.isEmpty {
            let coordinator = ExportVideoSlotsCoordinator(
                device: metalDevice,
                textureCache: textureCache,
                commandQueue: renderer.commandQueue,
                runtime: runtime,
                sceneFPS: Double(runtime.fps),
                exportTextureProvider: textureProvider,
                videoPrefetchFrames: budget.videoPrefetchFrames,
                maxActiveProviders: budget.maxActiveVideoProviders
            )
            coordinator.configure(videoSelectionsByBlockId: videoSelections)
            videoSlotsCoordinator = coordinator
        }
        #if DEBUG
        let slotsEndNs = DispatchTime.now().uptimeNanoseconds
        #endif

        session.setCleanup(
            onSuccess: {
                videoSlotsCoordinator?.finish()
                CVMetalTextureCacheFlush(textureCache, 0)
                renderer.trimTransientResources(policy: .exportFinished)
            },
            onFailure: {
                videoSlotsCoordinator?.cancel()
                CVMetalTextureCacheFlush(textureCache, 0)
                renderer.trimTransientResources(policy: .exportFinished)
            },
            onCancel: {
                videoSlotsCoordinator?.cancel()
                CVMetalTextureCacheFlush(textureCache, 0)
                renderer.trimTransientResources(policy: .exportFinished)
            }
        )
        if session.completeIfCancelled() { return }
        session.transitionToRendering()

        // Export-owned overlay cache — lives for the duration of the export session.
        let exportOverlayCache = OverlayRenderResourceCache()

        // 5. Sync primitives — semaphore capped by budget
        let semaphore = DispatchSemaphore(value: renderer.maxFramesInFlight)
        let videoGroup = DispatchGroup()

        #if DEBUG
        do {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let knownNs = (debugWarmEndNs - debugSetupStartNs)
                + (debugPhotoEndNs - debugWarmEndNs)
                + (debugBgEndNs - debugPhotoEndNs)
                + (audioEndNs - loopSetupStartNs)
                + (writerEndNs - audioEndNs)
                + (cacheEndNs - writerEndNs)
                + (slotsEndNs - cacheEndNs)
            let totalNs = nowNs - debugSetupStartNs
            let otherNs = totalNs > knownNs ? totalNs - knownNs : 0

            MemoryDiagnostics.event(
                "export.runnerSetup.summary",
                String(format: "mode=single warm=%.2fs photos=%.2fs background=%.2fs audio=%.2fs writer=%.2fs cache=%.2fs videoSlots=%.2fs other=%.2fs total=%.2fs",
                       Double(debugWarmEndNs - debugSetupStartNs) / 1e9,
                       Double(debugPhotoEndNs - debugWarmEndNs) / 1e9,
                       Double(debugBgEndNs - debugPhotoEndNs) / 1e9,
                       Double(audioEndNs - loopSetupStartNs) / 1e9,
                       Double(writerEndNs - audioEndNs) / 1e9,
                       Double(cacheEndNs - writerEndNs) / 1e9,
                       Double(slotsEndNs - cacheEndNs) / 1e9,
                       Double(otherNs) / 1e9,
                       Double(totalNs) / 1e9)
            )
        }
        #endif

        // 6. Video export loop
        let totalFrames = runtime.durationFrames
        #if DEBUG
        var renderedFrames = 0
        let renderStartNs = DispatchTime.now().uptimeNanoseconds
        #endif

        for frameIndex in 0..<totalFrames {
            #if DEBUG
            if frameIndex % 300 == 0 { MemoryDiagnostics.checkpoint("export.frame.\(frameIndex)", metal: metalDevice) }
            #endif
            if session.shouldStop { break }

            semaphore.wait()
            videoGroup.enter()

            autoreleasepool {
                // Get pixel buffer from pool
                guard let pool = pipeline.pixelBufferPool else {
                    pipeline.setError(VideoExportError.noPixelBufferPool)
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                var pixelBuffer: CVPixelBuffer?
                let pbStatus = CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    pool,
                    &pixelBuffer
                )

                guard pbStatus == kCVReturnSuccess, let pixelBuffer else {
                    pipeline.setError(VideoExportError.failedToCreatePixelBuffer(pbStatus))
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                // Create Metal texture from pixel buffer
                var cvMetalTexture: CVMetalTexture?
                let texStatus = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault,
                    textureCache,
                    pixelBuffer,
                    nil,
                    .bgra8Unorm,
                    settings.sizePx.width,
                    settings.sizePx.height,
                    0,
                    &cvMetalTexture
                )

                guard texStatus == kCVReturnSuccess,
                      let cvMetalTexture,
                      let targetTexture = CVMetalTextureGetTexture(cvMetalTexture) else {
                    pipeline.setError(VideoExportError.failedToCreateMetalTexture(texStatus))
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                // Update video textures before render (clamped for hold-last-frame parity)
                let clampedFrame = ExportFrameClamping.sceneFrame(frameIndex, nativeDurationFrames: runtime.durationFrames)
                let mediaFrame = max(frameIndex, 0)
                videoSlotsCoordinator?.updateTextures(visibilityFrameIndex: clampedFrame, mediaFrameIndex: mediaFrame)

                if let error = videoSlotsCoordinator?.providerError {
                    pipeline.setError(error)
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(settings.fps))

                do {
                    _ = try renderSingleSceneFrame(
                        frameIndex: frameIndex,
                        targetTexture: targetTexture,
                        runtime: runtime,
                        snapshot: snapshot,
                        renderer: renderer,
                        textureProvider: textureProvider,
                        pathRegistry: pathRegistry,
                        assetSizes: assetSizes,
                        backgroundState: backgroundState,
                        clearColor: settings.clearColor,
                        overlaySnapshot: overlaySnapshot,
                        overlayCache: exportOverlayCache
                    )
                } catch {
                    pipeline.setError(VideoExportError.renderError(error))
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                guard !session.shouldStop else {
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                #if DEBUG
                renderedFrames += 1
                #endif

                pipeline.enqueueVideoFrame(pixelBuffer, presentationTime: pts) {
                    videoGroup.leave()
                    semaphore.signal()
                }
            }

            session.emitProgressIfActive(Double(frameIndex + 1) / Double(totalFrames), via: progress)
        }

        // 7. Wait for all enqueued frames to finish
        videoGroup.wait()

        #if DEBUG
        let renderEndNs = DispatchTime.now().uptimeNanoseconds
        let elapsedSec = Double(renderEndNs - renderStartNs) / 1_000_000_000.0
        let fps = elapsedSec > 0 ? Double(renderedFrames) / elapsedSec : 0
        let renderOutcome = session.shouldStop ? (session.isCancelled ? "cancelled" : "failure") : "success"
        MemoryDiagnostics.event(
            "export.render.summary",
            String(format: "mode=single frames=%d/%d duration=%.2fs fps=%.2f renderOutcome=%@",
                   renderedFrames, totalFrames, elapsedSec, fps, renderOutcome)
        )
        MemoryDiagnostics.checkpoint("export.render.after", metal: metalDevice)
        #endif

        // 8. Finish or cancel — cleanup closures fire inside complete()
        if session.shouldStop {
            if !session.isCancelled { pipeline.cancel() }
            session.complete(with: .failure(session.terminalError ?? VideoExportError.cancelled))
        } else {
            session.finishWriting()
        }
    }

    // MARK: - Render Single Scene Frame

    /// Renders one single-scene export frame into a pre-allocated target texture.
    /// Uses the unified timeline executor so single-scene export matches preview/export overlay behavior.
    internal static func renderSingleSceneFrame(
        frameIndex: Int,
        targetTexture: MTLTexture,
        runtime: SceneRuntime,
        snapshot: SceneRenderStateSnapshot,
        renderer: MetalRenderer,
        textureProvider: TextureProvider,
        pathRegistry: PathRegistry,
        assetSizes: [String: AssetSize],
        backgroundState: EffectiveBackgroundState?,
        clearColor: ClearColor,
        overlaySnapshot: OverlayExportSnapshot?,
        overlayCache: OverlayRenderResourceCache
    ) throws -> (textOverlayCount: Int, stickerOverlayCount: Int) {
        let clampedFrame = ExportFrameClamping.sceneFrame(frameIndex, nativeDurationFrames: runtime.durationFrames)

        let commands = SceneRenderPlan.renderCommands(
            for: runtime,
            sceneFrameIndex: clampedFrame,
            resolvedTransforms: snapshot.resolvedTransforms,
            variantOverrides: snapshot.variantOverrides,
            userMediaPresent: snapshot.userMediaPresent,
            layerToggleState: snapshot.layerToggleState
        )

        let timeUs = frameToUs(frameIndex, fps: runtime.fps)
        let overlayItems = overlaySnapshot.map { OverlayResolver.resolve(from: $0, at: timeUs) } ?? []

        let renderContext = SceneRenderContext(
            commands: commands,
            textureProvider: textureProvider,
            pathRegistry: pathRegistry,
            assetSizes: assetSizes,
            localFrame: clampedFrame,
            canvasSize: runtime.canvasSize,
            sceneInstanceId: UUID()
        )

        let request = TimelineRenderRequest(
            resolved: .single(renderContext),
            targetTexture: targetTexture,
            drawableScale: 1.0,
            timelineCanvasSize: runtime.canvasSize,
            backgroundState: backgroundState,
            backgroundTextureProvider: textureProvider,
            clearColorOverride: clearColor,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            diagnosticFrameTag: frameIndex,
            overlayItems: overlayItems
        )

        do {
            try TimelineRenderExecutor.render(
                request,
                renderer: renderer,
                commandQueue: renderer.commandQueue,
                transitionCompositor: nil,
                completionQueue: nil,
                overlayCache: overlayCache
            )
        } catch let error as TimelineRenderExecutorError {
            switch error {
            case .failedToCreateCommandBuffer:
                throw VideoExportError.failedToCreateCommandBuffer
            case .failedToAcquireOffscreenTexture,
                 .missingTransitionCompositor,
                 .missingCompletionQueueForAsyncTransition:
                throw VideoExportError.renderError(error)
            }
        }

        let textCount = overlayItems.filter { $0.kind == .text }.count
        let stickerCount = overlayItems.filter { $0.kind == .sticker }.count
        return (textOverlayCount: textCount, stickerOverlayCount: stickerCount)
    }

    // MARK: - File Size Probe

    /// Probes original image dimensions from file URL via ImageIO.
    /// Returns EXIF-orientation-corrected size to match export placement resolution.
    private static func probeImageSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if orientation >= 5 && orientation <= 8 {
            return CGSize(width: h, height: w)
        }
        return CGSize(width: w, height: h)
    }
}
