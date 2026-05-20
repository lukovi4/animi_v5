import AVFoundation
import CoreVideo
import Metal
import TVECore

/// Per-scene background data for timeline export.
public struct SceneExportBackgroundData: @unchecked Sendable {
    public let state: EffectiveBackgroundState?
    public let snapshot: ExportBackgroundSnapshot?

    public init(state: EffectiveBackgroundState?, snapshot: ExportBackgroundSnapshot?) {
        self.state = state
        self.snapshot = snapshot
    }
}

// MARK: - Timeline Video Export Runner

/// Stateless runner for timeline (multi-scene) video export.
/// Called on `exportQueue` with a fully-built work item.
internal final class TimelineVideoExportRunner {

    // MARK: - Work Item

    internal final class WorkItem: @unchecked Sendable {
        let session: TimelineCompositionEngine.TimelineExportSession
        let renderer: MetalRenderer
        let transitionCompositor: TransitionCompositor
        let totalFrames: Int
        let canvasSize: SizeD
        /// Per-scene background data keyed by instance ID.
        let sceneBackgrounds: [UUID: SceneExportBackgroundData]
        let settings: TimelineExportSettings
        let budget: ExportResourceBudget
        let renderDiagnosticsSink: RenderDiagnosticsSink?

        init(
            session: TimelineCompositionEngine.TimelineExportSession,
            renderer: MetalRenderer,
            transitionCompositor: TransitionCompositor,
            totalFrames: Int,
            canvasSize: SizeD,
            sceneBackgrounds: [UUID: SceneExportBackgroundData],
            settings: TimelineExportSettings,
            budget: ExportResourceBudget,
            renderDiagnosticsSink: RenderDiagnosticsSink?
        ) {
            self.session = session
            self.renderer = renderer
            self.transitionCompositor = transitionCompositor
            self.totalFrames = totalFrames
            self.canvasSize = canvasSize
            self.sceneBackgrounds = sceneBackgrounds
            self.settings = settings
            self.budget = budget
            self.renderDiagnosticsSink = renderDiagnosticsSink
        }
    }

    // MARK: - Run

    static func run(
        workItem: WorkItem,
        exportSession: ExportSession,
        resolvedBgURLs: [MediaRef: URL],
        progress: @escaping (Double) -> Void
    ) {
        #if DEBUG
        let setupStartNs = DispatchTime.now().uptimeNanoseconds
        #else
        let setupStartNs: UInt64 = 0
        #endif
        // Load background textures on export queue (off MainActor).
        // Loads per-scene background snapshots into a single texture provider.
        // Slot keys are unique per preset+region, so different scene overrides coexist.
        let exportBackgroundProvider = ThreadSafeInMemoryTextureProvider()
        let commandQueue = workItem.renderer.commandQueue
        let allSnapshots: [ExportBackgroundSnapshot] = workItem.sceneBackgrounds.values
            .compactMap(\.snapshot)
        for bgSnapshot in allSnapshots {
            for ref in bgSnapshot.regionRefs {
                if let url = resolvedBgURLs[ref.mediaRef],
                   let texture = try? DownsampledImageLoader.loadTexture(
                       from: url,
                       device: commandQueue.device,
                       commandQueue: commandQueue,
                       maxDimensionPx: workItem.budget.targetImageMaxDimensionPx
                   ) {
                    exportBackgroundProvider.setTexture(texture, for: ref.slotKey)
                }
            }
        }

        #if DEBUG
        let bgEndNs = DispatchTime.now().uptimeNanoseconds
        #else
        let bgEndNs: UInt64 = 0
        #endif

        var audioPipeline: BuiltAudioPipeline?
        if let plan = workItem.settings.audioPlan ?? workItem.settings.audio?.toPlan() {
            do {
                let builder = AudioCompositionBuilder()
                audioPipeline = try builder.buildTimeline(
                    sceneData: workItem.session.audioSceneData,
                    transitionMath: workItem.session.transitionMath,
                    fps: workItem.settings.fps,
                    plan: plan
                )
            } catch {
                exportSession.complete(with: .failure(VideoExportError.failedToBuildAudioPipeline(error)))
                return
            }
        }

        #if DEBUG
        let audioEndNs = DispatchTime.now().uptimeNanoseconds
        #else
        let audioEndNs: UInt64 = 0
        #endif

        runTimelineExportLoop(
            workItem: workItem,
            backgroundTextureProvider: exportBackgroundProvider,
            audioPipeline: audioPipeline,
            exportSession: exportSession,
            progress: progress,
            debugSetupStartNs: setupStartNs,
            debugBgEndNs: bgEndNs,
            debugAudioEndNs: audioEndNs
        )
    }

    // MARK: - Timeline Export Loop

    private static func runTimelineExportLoop(
        workItem: WorkItem,
        backgroundTextureProvider: TextureProvider,
        audioPipeline: BuiltAudioPipeline?,
        exportSession: ExportSession,
        progress: @escaping (Double) -> Void,
        debugSetupStartNs: UInt64 = 0,
        debugBgEndNs: UInt64 = 0,
        debugAudioEndNs: UInt64 = 0
    ) {
        #if DEBUG
        let loopSetupStartNs = DispatchTime.now().uptimeNanoseconds
        #endif
        let renderer = workItem.renderer
        let transitionCompositor = workItem.transitionCompositor
        let totalFrames = workItem.totalFrames
        let canvasSize = workItem.canvasSize
        let settings = workItem.settings
        let budget = workItem.budget
        let renderDiagnosticsSink = workItem.renderDiagnosticsSink

        // Delete existing file
        try? FileManager.default.removeItem(at: settings.outputURL)

        // 1. Create pipeline (replaces writer/input/adaptor/audio setup)
        let pipeline: ExportWriterPipeline
        do {
            pipeline = try ExportWriterPipeline(
                outputURL: settings.outputURL,
                video: .init(sizePx: settings.sizePx, fps: settings.fps,
                             bitrate: settings.bitrate, gopSeconds: settings.gopSeconds),
                audio: audioPipeline.map { .init(composition: $0.composition, audioMix: $0.audioMix) }
            )
            exportSession.attachPipeline(pipeline)
            try pipeline.startWriting()
        } catch {
            exportSession.complete(with: .failure(error))
            return
        }
        #if DEBUG
        let writerEndNs = DispatchTime.now().uptimeNanoseconds
        #endif

        // 2. Create CVMetalTextureCache
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
            exportSession.complete(with: .failure(VideoExportError.failedToCreateTextureCache))
            return
        }
        #if DEBUG
        MemoryDiagnostics.event("CVTextureCache.create", "owner=TimelineExport")
        let cacheEndNs = DispatchTime.now().uptimeNanoseconds
        #endif

        // 3. Create residency controller + runtime on export queue
        let residencyController = TimelineExportResidencyController(
            session: workItem.session,
            budget: budget,
            device: renderer.commandQueue.device,
            commandQueue: renderer.commandQueue,
            textureCache: textureCache
        )

        let exportRuntime = TimelineExportRuntime(
            session: workItem.session,
            residencyController: residencyController
        )
        #if DEBUG
        let residencyEndNs = DispatchTime.now().uptimeNanoseconds
        #endif

        // Export-owned overlay cache — lives for the duration of the export session.
        let exportOverlayCache = OverlayRenderResourceCache()

        exportSession.setCleanup(
            onSuccess: {
                exportRuntime.finish()
                CVMetalTextureCacheFlush(textureCache, 0)
                renderer.trimTransientResources(policy: .exportFinished)
            },
            onFailure: {
                exportRuntime.cancel()
                CVMetalTextureCacheFlush(textureCache, 0)
                renderer.trimTransientResources(policy: .exportFinished)
            },
            onCancel: {
                exportRuntime.cancel()
                CVMetalTextureCacheFlush(textureCache, 0)
                renderer.trimTransientResources(policy: .exportFinished)
            }
        )
        exportSession.transitionToRendering()

        // 4. Video export loop (semaphore capped by budget)
        let semaphore = DispatchSemaphore(value: budget.maxFramesInFlight)
        let videoGroup = DispatchGroup()

        #if DEBUG
        do {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let knownNs = (debugBgEndNs - debugSetupStartNs)
                + (debugAudioEndNs - debugBgEndNs)
                + (writerEndNs - loopSetupStartNs)
                + (cacheEndNs - writerEndNs)
                + (residencyEndNs - cacheEndNs)
            let totalNs = nowNs - debugSetupStartNs
            let otherNs = totalNs > knownNs ? totalNs - knownNs : 0

            MemoryDiagnostics.event(
                "export.runnerSetup.summary",
                String(format: "mode=timeline background=%.2fs audio=%.2fs writer=%.2fs cache=%.2fs residency=%.2fs other=%.2fs total=%.2fs",
                       Double(debugBgEndNs - debugSetupStartNs) / 1e9,
                       Double(debugAudioEndNs - debugBgEndNs) / 1e9,
                       Double(writerEndNs - loopSetupStartNs) / 1e9,
                       Double(cacheEndNs - writerEndNs) / 1e9,
                       Double(residencyEndNs - cacheEndNs) / 1e9,
                       Double(otherNs) / 1e9,
                       Double(totalNs) / 1e9)
            )
        }
        var renderedFrames = 0
        let renderStartNs = DispatchTime.now().uptimeNanoseconds
        #endif

        for frameIndex in 0..<totalFrames {
            #if DEBUG
            if frameIndex % 300 == 0 { MemoryDiagnostics.checkpoint("export.frame.\(frameIndex)", metal: metalDevice) }
            #endif
            if exportSession.shouldStop { break }

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

                // Resolve and render via extracted helper
                do {
                    _ = try renderTimelineFrame(
                        frameIndex: frameIndex,
                        targetTexture: targetTexture,
                        exportRuntime: exportRuntime,
                        renderer: renderer,
                        transitionCompositor: transitionCompositor,
                        canvasSize: canvasSize,
                        backgroundTextureProvider: backgroundTextureProvider,
                        clearColor: settings.clearColor,
                        renderDiagnosticsSink: renderDiagnosticsSink,
                        overlayCache: exportOverlayCache,
                        sceneBackgrounds: workItem.sceneBackgrounds
                    )
                } catch {
                    pipeline.setError(VideoExportError.renderError(error))
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                #if DEBUG
                renderedFrames += 1
                #endif

                // Enqueue via pipeline — no busy-wait, readiness-driven
                let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(settings.fps))
                pipeline.enqueueVideoFrame(pixelBuffer, presentationTime: pts) {
                    videoGroup.leave()
                    semaphore.signal()
                }
            }

            exportSession.emitProgressIfActive(Double(frameIndex + 1) / Double(totalFrames), via: progress)
        }

        // 5. Wait for all video frames to finish
        videoGroup.wait()

        #if DEBUG
        let renderEndNs = DispatchTime.now().uptimeNanoseconds
        let elapsedSec = Double(renderEndNs - renderStartNs) / 1_000_000_000.0
        let fps = elapsedSec > 0 ? Double(renderedFrames) / elapsedSec : 0
        let renderOutcome = exportSession.shouldStop ? (exportSession.isCancelled ? "cancelled" : "failure") : "success"
        MemoryDiagnostics.event(
            "export.render.summary",
            String(format: "mode=timeline frames=%d/%d duration=%.2fs fps=%.2f renderOutcome=%@",
                   renderedFrames, totalFrames, elapsedSec, fps, renderOutcome)
        )
        MemoryDiagnostics.checkpoint("export.render.after", metal: metalDevice)
        #endif

        // 6. Finish or cancel — cleanup closures fire inside complete()
        if exportSession.shouldStop {
            if !exportSession.isCancelled { pipeline.cancel() }
            exportSession.complete(with: .failure(exportSession.terminalError ?? VideoExportError.cancelled))
        } else {
            exportSession.finishWriting()
        }
    }

    // MARK: - Render Timeline Frame

    /// Renders one timeline frame into a pre-allocated target texture.
    /// Returns overlay count for debug probing.
    internal static func renderTimelineFrame(
        frameIndex: Int,
        targetTexture: MTLTexture,
        exportRuntime: TimelineExportRuntime,
        renderer: MetalRenderer,
        transitionCompositor: TransitionCompositor,
        canvasSize: SizeD,
        backgroundTextureProvider: TextureProvider?,
        clearColor: ClearColor?,
        renderDiagnosticsSink: RenderDiagnosticsSink?,
        overlayCache: OverlayRenderResourceCache,
        sceneBackgrounds: [UUID: SceneExportBackgroundData]
    ) throws -> (textOverlayCount: Int, stickerOverlayCount: Int) {
        let resolved = try exportRuntime.resolveFrame(frameIndex)
        let timeUs = exportRuntime.globalTimeUs(for: frameIndex)
        let overlayItems = timeUs.map { OverlayResolver.resolve(from: exportRuntime.session.overlaySnapshot, at: $0) } ?? []

        // Resolve per-scene background from scene instance ID.
        let resolvedBgState = Self.resolveFrameBackground(resolved: resolved, sceneBackgrounds: sceneBackgrounds)

        let request = TimelineRenderRequest(
            resolved: resolved,
            targetTexture: targetTexture,
            drawableScale: 1.0,
            timelineCanvasSize: canvasSize,
            backgroundState: resolvedBgState,
            backgroundTextureProvider: backgroundTextureProvider,
            clearColorOverride: clearColor,
            presentationDrawable: nil,
            waitUntilCompleted: true,
            diagnosticFrameTag: frameIndex,
            overlayItems: overlayItems
        )
        do {
            try TimelineRenderExecutor.render(
                request, renderer: renderer,
                commandQueue: renderer.commandQueue,
                transitionCompositor: transitionCompositor,
                completionQueue: nil,
                overlayCache: overlayCache,
                renderSink: renderDiagnosticsSink
            )
        } catch let error as TimelineRenderExecutorError {
            switch error {
            case .failedToCreateCommandBuffer:
                throw VideoExportError.failedToCreateCommandBuffer
            case .failedToAcquireOffscreenTexture:
                throw TimelineExportError.failedToAcquireOffscreenTexture
            case .missingTransitionCompositor,
                 .missingCompletionQueueForAsyncTransition:
                throw VideoExportError.renderError(error)
            }
        }
        let textCount = overlayItems.filter { $0.kind == .text }.count
        let stickerCount = overlayItems.filter { $0.kind == .sticker }.count
        return (textOverlayCount: textCount, stickerOverlayCount: stickerCount)
    }

    // MARK: - Frame Background Resolution

    /// Resolves the effective background state for a given resolved frame.
    /// For single-scene frames: uses that scene's background.
    /// For transition frames: uses the outgoing scene (scene A) background.
    internal static func resolveFrameBackground(
        resolved: ResolvedTimelineFrame,
        sceneBackgrounds: [UUID: SceneExportBackgroundData]
    ) -> EffectiveBackgroundState? {
        let instanceId: UUID? = switch resolved {
        case .single(let ctx): ctx.sceneInstanceId
        case .transition(let ctx): ctx.sceneA.sceneInstanceId
        }
        guard let instanceId else { return nil }
        return sceneBackgrounds[instanceId]?.state
    }

    // MARK: - Resolution to Export Error Mapping

    /// TT-02: Maps TimelineFrameResolution to export error (if any).
    /// Extracted for unit testing without full export loop.
    internal static func mapResolutionToExportError(
        _ resolution: TimelineFrameResolution,
        frameIndex: Int
    ) -> TimelineExportError? {
        switch resolution {
        case .resolved:
            return nil

        case .hold:
            return .frameHoldNotAllowed(frameIndex)

        case .staleGeneration:
            return .frameResolutionFailed(frame: frameIndex, reason: "stale_generation")

        case .failed(let failure):
            let reason: String
            switch failure {
            case .invalidTimeline:
                reason = "invalid_timeline"
            case .missingDependency(let id):
                reason = "missing_dependency:\(id)"
            case .dependencyFailed(let id, let r):
                reason = "dependency_failed:\(id):\(r)"
            case .dependencyTimedOut(let id):
                reason = "dependency_timeout:\(id)"
            }
            return .frameResolutionFailed(frame: frameIndex, reason: reason)
        }
    }
}
