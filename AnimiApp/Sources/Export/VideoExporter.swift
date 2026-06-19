import AVFoundation
import CoreVideo
import Metal
import TVECore

// MARK: - Video Exporter

/// GPU-only video exporter for scenes (PR-E2).
///
/// Thin facade that owns the export queue and active session lifecycle.
/// Frame rendering is delegated to `SingleSceneVideoExportRunner` and
/// `TimelineVideoExportRunner`.
public final class VideoExporter: @unchecked Sendable {
    // MARK: - Queues

    /// Main export queue for frame stepping
    private let exportQueue = DispatchQueue(label: "com.animi.videoexporter", qos: .userInitiated)

    // MARK: - Thread-safe Active Session

    private let sessionLock = NSLock()
    private var _activeSession: ExportSession?

    internal func setActiveSession(_ session: ExportSession?) {
        sessionLock.lock()
        _activeSession = session
        sessionLock.unlock()
    }

    private var activeSession: ExportSession? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return _activeSession
    }

    /// Cancels the current export.
    public func cancel() {
        activeSession?.requestCancel()
    }

    // MARK: - Init

    let mediaLocator: any ProjectMediaLocator

    init(mediaLocator: any ProjectMediaLocator) {
        self.mediaLocator = mediaLocator
    }

    // MARK: - Shared Helpers

    internal func makeExportRenderer(device: MTLDevice, maxFramesInFlight: Int = 3) throws -> MetalRenderer {
        let options = MetalRendererOptions(
            maxFramesInFlight: maxFramesInFlight,
            texturePoolConfiguration: .export
        )
        return try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm, options: options)
    }

    internal func makeExportTransitionCompositor(device: MTLDevice) throws -> TransitionCompositor {
        try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)
    }

    /// Pre-resolves background media URLs from an ExportBackgroundSnapshot via
    /// the registry-backed media locator. Called in async context before
    /// dispatching to the sync exportQueue.
    internal func resolveBackgroundURLs(
        from snapshot: ExportBackgroundSnapshot?,
        registry: ProjectAssetRegistry
    ) async -> [MediaRef: URL] {
        guard let snapshot else { return [:] }
        var resolved: [MediaRef: URL] = [:]
        for ref in snapshot.regionRefs {
            if let url = try? await mediaLocator.absoluteURL(for: ref.mediaRef, registry: registry) {
                resolved[ref.mediaRef] = url
            }
        }
        return resolved
    }

    // MARK: - Public API: Single-Scene Export

    @MainActor
    internal func exportVideo(
        compiledScene: CompiledScene,
        scenePlayer: ScenePlayer,
        device: MTLDevice,
        textureProvider: ExportTextureProvider,
        pathRegistry: PathRegistry,
        assetSizes: [String: AssetSize],
        settings: VideoExportSettings,
        backgroundState: EffectiveBackgroundState?,
        overlaySnapshot: OverlayExportSnapshot? = nil,
        budget: ExportResourceBudget = .default,
        mediaSnapshot: ExportMediaSnapshot? = nil,
        backgroundSnapshot: ExportBackgroundSnapshot? = nil,
        assetRegistry: ProjectAssetRegistry = ProjectAssetRegistry(),
        onFinishing: (() -> Void)? = nil,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) async {
        let session = ExportSession(completion: completion)
        #if DEBUG
        session.diagnosticDevice = device
        let handoffStartNs = DispatchTime.now().uptimeNanoseconds
        #endif
        setActiveSession(session)

        session.setOnTerminal { [weak self] in
            self?.setActiveSession(nil)
        }
        if let onFinishing { session.setOnFinishing(onFinishing) }

        if session.completeIfCancelled() { return }

        // Validate FPS match
        guard settings.fps == compiledScene.runtime.fps else {
            session.complete(with: .failure(VideoExportError.fpsMismatch(
                settingsFps: settings.fps,
                runtimeFps: compiledScene.runtime.fps
            )))
            return
        }

        // Capture state snapshot on MainActor (deep copy)
        let snapshot = scenePlayer.exportStateSnapshot()
        let runtime = compiledScene.runtime

        // Video selections are now included in ExportMediaSnapshot (from persisted slots)
        let videoSelections: [String: VideoSelection] = {
            guard let snapshot = mediaSnapshot else { return [:] }
            var result: [String: VideoSelection] = [:]
            for ref in snapshot.videoRefs {
                result[ref.blockId] = ref.selection
            }
            return result
        }()

        let exportRenderer: MetalRenderer
        do {
            exportRenderer = try makeExportRenderer(device: device, maxFramesInFlight: budget.maxFramesInFlight)
        } catch {
            session.complete(with: .failure(VideoExportError.renderError(error)))
            return
        }

        let workItem = SingleSceneVideoExportRunner.WorkItem(
            runtime: runtime,
            snapshot: snapshot,
            renderer: exportRenderer,
            textureProvider: textureProvider,
            pathRegistry: pathRegistry,
            assetSizes: assetSizes,
            videoSelections: videoSelections,
            settings: settings,
            backgroundState: backgroundState,
            overlaySnapshot: overlaySnapshot,
            mediaSnapshot: mediaSnapshot,
            backgroundSnapshot: backgroundSnapshot,
            budget: budget
        )

        // Pre-resolve background media URLs in async context before dispatching to sync queue
        let resolvedBgURLs = await resolveBackgroundURLs(from: backgroundSnapshot, registry: assetRegistry)

        if session.completeIfCancelled() { return }

        // Run export on background queue
        #if DEBUG
        let handoffSec = Double(DispatchTime.now().uptimeNanoseconds - handoffStartNs) / 1_000_000_000.0
        MemoryDiagnostics.event(
            "export.handoff.summary",
            String(format: "mode=single duration=%.2fs", handoffSec)
        )
        #endif
        #if DEBUG
        let debugHandoffEndNs = DispatchTime.now().uptimeNanoseconds
        #else
        let debugHandoffEndNs: UInt64 = 0
        #endif
        let allAssetIds = Set(compiledScene.mergedAssetIndex.basenameById.keys)
        exportQueue.async { [workItem, session, allAssetIds, resolvedBgURLs, debugHandoffEndNs] in
            #if DEBUG
            let queueDelaySec = Double(DispatchTime.now().uptimeNanoseconds - debugHandoffEndNs) / 1_000_000_000.0
            MemoryDiagnostics.event(
                "export.queueDelay.summary",
                String(format: "mode=single delay=%.2fs", queueDelaySec)
            )
            #endif
            SingleSceneVideoExportRunner.run(
                workItem: workItem,
                session: session,
                allAssetIds: allAssetIds,
                resolvedBgURLs: resolvedBgURLs,
                progress: progress
            )
        }
    }

    // MARK: - Public API: Timeline Export

    @MainActor
    internal func exportTimeline(
        engine: TimelineCompositionEngine,
        sceneBackgrounds: [UUID: SceneExportBackgroundData],
        preBuiltSession: TimelineCompositionEngine.TimelineExportSession? = nil,
        settings: TimelineExportSettings,
        budget: ExportResourceBudget = .default,
        renderDiagnosticsSink: RenderDiagnosticsSink? = nil,
        assetRegistry: ProjectAssetRegistry? = nil,
        onFinishing: (() -> Void)? = nil,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let effectiveRegistry = assetRegistry ?? engine.currentAssetRegistry
        let exportSession = ExportSession(completion: completion)
        #if DEBUG
        exportSession.diagnosticDevice = engine.device
        #endif
        setActiveSession(exportSession)

        exportSession.setOnTerminal { [weak self] in
            self?.setActiveSession(nil)
        }
        if let onFinishing { exportSession.setOnFinishing(onFinishing) }

        // Validate FPS match
        guard settings.fps == engine.fps else {
            exportSession.complete(with: .failure(VideoExportError.fpsMismatch(
                settingsFps: settings.fps,
                runtimeFps: engine.fps
            )))
            return
        }

        #if DEBUG
        let taskScheduleNs = DispatchTime.now().uptimeNanoseconds
        #else
        let taskScheduleNs: UInt64 = 0
        #endif
        Task { @MainActor [weak self] in
            guard let self else {
                exportSession.complete(with: .failure(VideoExportError.cancelled))
                return
            }
            #if DEBUG
            let taskDelaySec = Double(DispatchTime.now().uptimeNanoseconds - taskScheduleNs) / 1_000_000_000.0
            MemoryDiagnostics.event(
                "export.taskDelay.summary",
                String(format: "mode=timeline delay=%.2fs", taskDelaySec)
            )
            let handoffStartNs = DispatchTime.now().uptimeNanoseconds
            #endif

            guard !exportSession.isCancelled else {
                exportSession.complete(with: .failure(VideoExportError.cancelled))
                return
            }

            let tlSession: TimelineCompositionEngine.TimelineExportSession
            if let preBuiltSession {
                tlSession = preBuiltSession
            } else {
                do {
                    tlSession = try await engine.buildExportSession()
                } catch {
                    exportSession.complete(with: .failure(VideoExportError.renderError(error)))
                    return
                }
            }

            guard !exportSession.isCancelled else {
                exportSession.complete(with: .failure(VideoExportError.cancelled))
                return
            }

            let totalFrames = tlSession.transitionMath.compressedDurationFrames
            let canvasSize = tlSession.canvasSize

            let exportRenderer: MetalRenderer
            let exportCompositor: TransitionCompositor
            do {
                exportRenderer = try self.makeExportRenderer(device: engine.device, maxFramesInFlight: budget.maxFramesInFlight)
                exportCompositor = try self.makeExportTransitionCompositor(device: engine.device)
            } catch {
                exportSession.complete(with: .failure(VideoExportError.renderError(error)))
                return
            }

            let workItem = TimelineVideoExportRunner.WorkItem(
                session: tlSession,
                renderer: exportRenderer,
                transitionCompositor: exportCompositor,
                totalFrames: totalFrames,
                canvasSize: canvasSize,
                sceneBackgrounds: sceneBackgrounds,
                settings: settings,
                budget: budget,
                renderDiagnosticsSink: renderDiagnosticsSink
            )

            // Pre-resolve background media URLs from all scene snapshots
            var resolvedBgURLs: [MediaRef: URL] = [:]
            for (_, sceneBg) in sceneBackgrounds {
                guard !exportSession.isCancelled else {
                    exportSession.complete(with: .failure(VideoExportError.cancelled))
                    return
                }
                let sceneURLs = await self.resolveBackgroundURLs(from: sceneBg.snapshot, registry: effectiveRegistry)
                resolvedBgURLs.merge(sceneURLs) { _, new in new }
            }
            if exportSession.completeIfCancelled() { return }

            #if DEBUG
            let handoffSec = Double(DispatchTime.now().uptimeNanoseconds - handoffStartNs) / 1_000_000_000.0
            MemoryDiagnostics.event(
                "export.handoff.summary",
                String(format: "mode=timeline duration=%.2fs", handoffSec)
            )
            #endif
            #if DEBUG
            let debugHandoffEndNs = DispatchTime.now().uptimeNanoseconds
            #else
            let debugHandoffEndNs: UInt64 = 0
            #endif
            self.exportQueue.async { [workItem, exportSession, resolvedBgURLs, debugHandoffEndNs] in
                #if DEBUG
                let queueDelaySec = Double(DispatchTime.now().uptimeNanoseconds - debugHandoffEndNs) / 1_000_000_000.0
                MemoryDiagnostics.event(
                    "export.queueDelay.summary",
                    String(format: "mode=timeline delay=%.2fs", queueDelaySec)
                )
                #endif
                TimelineVideoExportRunner.run(
                    workItem: workItem,
                    exportSession: exportSession,
                    resolvedBgURLs: resolvedBgURLs,
                    progress: progress
                )
            }
        }
    }
}

// MARK: - CP6: AnimiEngineNext export (DEBUG only)

#if DEBUG
extension VideoExporter {

    /// Single-scene export through AnimiEngineNext. Reuses this exporter's `ExportSession` /
    /// `exportQueue` / cancel / cleanup / completion ownership exactly like `exportVideo`; only the
    /// frame SOURCE differs (Next bridge instead of the TVECore runner). Audio stays the old path —
    /// it is built from `audioPlan` on the export queue, same builder as the old runner.
    @MainActor
    internal func exportVideoNext(
        preparedContext: NextPreparedContext,
        sessionBox: NextSessionBox,
        sceneRuntime: SceneRuntime,
        settings: NextExportVideoSettings,
        audioPlan: AudioExportPlan?,
        totalFrames: Int,
        budget: ExportResourceBudget = .default,
        onFinishing: (() -> Void)? = nil,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let session = ExportSession(completion: completion)
        setActiveSession(session)
        session.setOnTerminal { [weak self] in self?.setActiveSession(nil) }
        if let onFinishing { session.setOnFinishing(onFinishing) }
        if session.completeIfCancelled() { return }

        exportQueue.async { [session, preparedContext, sessionBox, settings, audioPlan, totalFrames, sceneRuntime, budget] in
            var audioPipeline: BuiltAudioPipeline?
            if let plan = audioPlan {
                do {
                    audioPipeline = try AudioCompositionBuilder().build(
                        runtime: sceneRuntime,
                        fps: settings.fps,
                        videoSelectionsByBlockId: [:],   // photo-only scope
                        plan: plan
                    )
                } catch {
                    session.complete(with: .failure(VideoExportError.failedToBuildAudioPipeline(error)))
                    return
                }
            }
            NextVideoExportRunner.run(
                source: .single(preparedContext),
                sessionBox: sessionBox,
                settings: settings,
                audioPipeline: audioPipeline,
                totalFrames: totalFrames,
                maxFramesInFlight: budget.maxFramesInFlight,
                session: session,
                progress: progress
            )
        }
    }

    /// Timeline export through AnimiEngineNext. Same lifecycle ownership as `exportTimeline`; the
    /// frame source is the Next timeline bridge driven by a compressed→nominal `TimelinePlayheadMapper`.
    /// `totalFrames` is the COMPRESSED frame count (PTS/duration); audio is the old path built from
    /// the immutable session's `audioSceneData`.
    @MainActor
    internal func exportTimelineNext(
        preparedContext: NextTimelinePreparedContext,
        sessionBox: NextSessionBox,
        tlSession: TimelineCompositionEngine.TimelineExportSession,
        settings: NextExportVideoSettings,
        audioPlan: AudioExportPlan?,
        budget: ExportResourceBudget = .default,
        onFinishing: (() -> Void)? = nil,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let session = ExportSession(completion: completion)
        setActiveSession(session)
        session.setOnTerminal { [weak self] in self?.setActiveSession(nil) }
        if let onFinishing { session.setOnFinishing(onFinishing) }
        if session.completeIfCancelled() { return }

        let mapper = TimelinePlayheadMapper(math: tlSession.transitionMath)
        let totalFrames = tlSession.transitionMath.compressedDurationFrames

        exportQueue.async { [session, preparedContext, sessionBox, settings, audioPlan, totalFrames, mapper, tlSession, budget] in
            var audioPipeline: BuiltAudioPipeline?
            if let plan = audioPlan {
                do {
                    audioPipeline = try AudioCompositionBuilder().buildTimeline(
                        sceneData: tlSession.audioSceneData,
                        transitionMath: tlSession.transitionMath,
                        fps: settings.fps,
                        plan: plan
                    )
                } catch {
                    session.complete(with: .failure(VideoExportError.failedToBuildAudioPipeline(error)))
                    return
                }
            }
            NextVideoExportRunner.run(
                source: .timeline(preparedContext, mapper: mapper),
                sessionBox: sessionBox,
                settings: settings,
                audioPipeline: audioPipeline,
                totalFrames: totalFrames,
                maxFramesInFlight: budget.maxFramesInFlight,
                session: session,
                progress: progress
            )
        }
    }
}
#endif

// MARK: - Compatibility: Deprecated Typealias

extension VideoExporter {
    @available(*, deprecated, renamed: "TimelineExportSettings")
    public typealias TimelineExportSettings = AnimiApp.TimelineExportSettings
}

// MARK: - Compatibility: Static Forwarding for Tests

extension VideoExporter {
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
        try SingleSceneVideoExportRunner.renderSingleSceneFrame(
            frameIndex: frameIndex,
            targetTexture: targetTexture,
            runtime: runtime,
            snapshot: snapshot,
            renderer: renderer,
            textureProvider: textureProvider,
            pathRegistry: pathRegistry,
            assetSizes: assetSizes,
            backgroundState: backgroundState,
            clearColor: clearColor,
            overlaySnapshot: overlaySnapshot,
            overlayCache: overlayCache
        )
    }

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
        sceneBackgrounds: [UUID: SceneExportBackgroundData] = [:]
    ) throws -> (textOverlayCount: Int, stickerOverlayCount: Int) {
        try TimelineVideoExportRunner.renderTimelineFrame(
            frameIndex: frameIndex,
            targetTexture: targetTexture,
            exportRuntime: exportRuntime,
            renderer: renderer,
            transitionCompositor: transitionCompositor,
            canvasSize: canvasSize,
            backgroundTextureProvider: backgroundTextureProvider,
            clearColor: clearColor,
            renderDiagnosticsSink: renderDiagnosticsSink,
            overlayCache: overlayCache,
            sceneBackgrounds: sceneBackgrounds
        )
    }

    internal static func mapResolutionToExportError(
        _ resolution: TimelineFrameResolution,
        frameIndex: Int
    ) -> TimelineExportError? {
        TimelineVideoExportRunner.mapResolutionToExportError(resolution, frameIndex: frameIndex)
    }
}
