import AVFoundation
import CoreVideo
import Metal
import TVECore

// MARK: - Audio Track Config (PR-E4)

/// Configuration for a single audio track (music or voiceover).
public struct AudioTrackConfig: Sendable {
    /// Audio file URL
    public let url: URL

    /// Start time on project timeline in seconds
    public let startTimeSeconds: Double

    /// Volume (0...1)
    public let volume: Float

    /// Optional trim start in source audio (seconds)
    public let trimStartSeconds: Double?

    /// Optional trim end in source audio (seconds)
    public let trimEndSeconds: Double?

    /// Whether to loop audio to fill project duration (v1: false)
    public let loopToFit: Bool

    public init(
        url: URL,
        startTimeSeconds: Double = 0,
        volume: Float = 1.0,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil,
        loopToFit: Bool = false
    ) {
        self.url = url
        self.startTimeSeconds = startTimeSeconds
        self.volume = volume
        self.trimStartSeconds = trimStartSeconds
        self.trimEndSeconds = trimEndSeconds
        self.loopToFit = loopToFit
    }
}

// MARK: - Audio Export Config (PR-E4)

/// Configuration for audio export.
public struct AudioExportConfig: Sendable {
    /// Background music track (optional)
    public let music: AudioTrackConfig?

    /// Voiceover track (optional)
    public let voiceover: AudioTrackConfig?

    /// Whether to include original audio from video slots
    public let includeOriginalFromVideoSlots: Bool

    /// Default volume for original audio if not specified in VideoSelection
    public let originalDefaultVolume: Float

    public init(
        music: AudioTrackConfig? = nil,
        voiceover: AudioTrackConfig? = nil,
        includeOriginalFromVideoSlots: Bool = true,
        originalDefaultVolume: Float = 1.0
    ) {
        self.music = music
        self.voiceover = voiceover
        self.includeOriginalFromVideoSlots = includeOriginalFromVideoSlots
        self.originalDefaultVolume = originalDefaultVolume
    }
}

// MARK: - Video Quality Preset (B2)

/// Preset quality levels for video export.
///
/// Maps to target bitrate based on canvas resolution.
/// Use `.custom(bitrate:)` for explicit bitrate control.
public enum VideoQualityPreset: Sendable {
    /// Low quality: ~4 Mbps for 1080p (scaled by resolution)
    case low

    /// Medium quality: ~10 Mbps for 1080p (scaled by resolution)
    case medium

    /// High quality: ~15 Mbps for 1080p (scaled by resolution)
    case high

    /// Maximum quality: ~25 Mbps for 1080p (scaled by resolution)
    case max

    /// Custom bitrate (explicit override)
    case custom(bitrate: Int)

    /// Calculates bitrate for the given canvas size.
    ///
    /// Bitrate is scaled proportionally to pixel count relative to 1080p (1920x1080).
    ///
    /// - Parameter canvasSize: Canvas size in pixels
    /// - Returns: Target bitrate in bits per second
    public func bitrate(for canvasSize: (width: Int, height: Int)) -> Int {
        let pixels = canvasSize.width * canvasSize.height
        let referencePixels = 1920 * 1080  // 1080p baseline

        let baseBitrate: Int
        switch self {
        case .low:
            baseBitrate = 4_000_000      // 4 Mbps for 1080p
        case .medium:
            baseBitrate = 10_000_000     // 10 Mbps for 1080p
        case .high:
            baseBitrate = 15_000_000     // 15 Mbps for 1080p
        case .max:
            baseBitrate = 25_000_000     // 25 Mbps for 1080p
        case .custom(let bitrate):
            return bitrate
        }

        // Scale by pixel count, clamp to reasonable range
        let scaledBitrate = baseBitrate * pixels / referencePixels
        return Swift.max(2_000_000, Swift.min(50_000_000, scaledBitrate))
    }
}

// MARK: - Video Export Settings

/// Configuration for video export (PR-E2).
///
/// H.264 MP4 export, SDR + Rec.709 (sRGB), no alpha.
public struct VideoExportSettings: Sendable {
    /// Output file URL
    public let outputURL: URL

    /// Output size in pixels
    public let sizePx: (width: Int, height: Int)

    /// Frame rate (must match scene runtime fps)
    public let fps: Int

    /// Target average bitrate in bps
    public let bitrate: Int

    /// GOP length in seconds (default: 2)
    public let gopSeconds: Int

    /// Clear color for each frame (default: opaqueBlack for H.264)
    public let clearColor: ClearColor

    /// Audio export configuration (PR-E4). nil = video-only export.
    public let audio: AudioExportConfig?

    public init(
        outputURL: URL,
        sizePx: (width: Int, height: Int),
        fps: Int,
        bitrate: Int = 10_000_000,
        gopSeconds: Int = 2,
        clearColor: ClearColor = .opaqueBlack,
        audio: AudioExportConfig? = nil
    ) {
        self.outputURL = outputURL
        self.sizePx = sizePx
        self.fps = fps
        self.bitrate = bitrate
        self.gopSeconds = gopSeconds
        self.clearColor = clearColor
        self.audio = audio
    }
}

// MARK: - Video Export Error

/// Errors that can occur during video export (PR-E2).
public enum VideoExportError: Error, Sendable {
    /// FPS mismatch between settings and scene runtime
    case fpsMismatch(settingsFps: Int, runtimeFps: Int)

    /// Failed to create AVAssetWriter
    case failedToCreateWriter(Error?)

    /// Cannot add video input to writer
    case cannotAddVideoInput

    /// Writer failed to start
    case writerStartFailed(Error?)

    /// Failed to create CVMetalTextureCache
    case failedToCreateTextureCache

    /// No pixel buffer pool available
    case noPixelBufferPool

    /// Failed to create pixel buffer from pool
    case failedToCreatePixelBuffer(CVReturn)

    /// Failed to create Metal texture from pixel buffer
    case failedToCreateMetalTexture(CVReturn)

    /// Append failed
    case appendFailed(Error?)

    /// Finish writing failed
    case finishFailed(Error?)

    /// Export was cancelled
    case cancelled

    /// Render error
    case renderError(Error)

    /// Failed to create command buffer
    case failedToCreateCommandBuffer

    // MARK: - Audio Errors (PR-E4)

    /// Cannot add audio input to writer
    case cannotAddAudioInput

    /// Audio reader failed to start
    case audioReaderStartFailed(Error?)

    /// Audio append failed
    case audioAppendFailed(Error?)

    /// Missing audio track in source file
    case missingAudioTrack(URL)

    /// Failed to build audio pipeline
    case failedToBuildAudioPipeline(Error)
}

extension VideoExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fpsMismatch(let settingsFps, let runtimeFps):
            return "FPS mismatch: settings=\(settingsFps), runtime=\(runtimeFps)"
        case .failedToCreateWriter(let error):
            return "Failed to create AVAssetWriter: \(error?.localizedDescription ?? "unknown")"
        case .cannotAddVideoInput:
            return "Cannot add video input to writer"
        case .writerStartFailed(let error):
            return "Writer failed to start: \(error?.localizedDescription ?? "unknown")"
        case .failedToCreateTextureCache:
            return "Failed to create CVMetalTextureCache"
        case .noPixelBufferPool:
            return "No pixel buffer pool available"
        case .failedToCreatePixelBuffer(let status):
            return "Failed to create pixel buffer: CVReturn \(status)"
        case .failedToCreateMetalTexture(let status):
            return "Failed to create Metal texture: CVReturn \(status)"
        case .appendFailed(let error):
            return "Append failed: \(error?.localizedDescription ?? "unknown")"
        case .finishFailed(let error):
            return "Finish writing failed: \(error?.localizedDescription ?? "unknown")"
        case .cancelled:
            return "Export was cancelled"
        case .renderError(let error):
            return "Render error: \(error.localizedDescription)"
        case .failedToCreateCommandBuffer:
            return "Failed to create Metal command buffer"
        case .cannotAddAudioInput:
            return "Cannot add audio input to writer"
        case .audioReaderStartFailed(let error):
            return "Audio reader failed to start: \(error?.localizedDescription ?? "unknown")"
        case .audioAppendFailed(let error):
            return "Audio append failed: \(error?.localizedDescription ?? "unknown")"
        case .missingAudioTrack(let url):
            return "Missing audio track in: \(url.lastPathComponent)"
        case .failedToBuildAudioPipeline(let error):
            return "Failed to build audio pipeline: \(error.localizedDescription)"
        }
    }

    /// True if this error represents a user-initiated cancellation.
    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

// MARK: - In-Flight Frame

/// Holds resources for a frame that is currently being rendered/encoded.
///
/// Prevents premature deallocation of CVPixelBuffer and CVMetalTexture
/// until GPU rendering completes and append is done.
final class InFlightFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let cvMetalTexture: CVMetalTexture
    let mtlTexture: MTLTexture
    let presentationTime: CMTime

    init(
        pixelBuffer: CVPixelBuffer,
        cvMetalTexture: CVMetalTexture,
        mtlTexture: MTLTexture,
        presentationTime: CMTime
    ) {
        self.pixelBuffer = pixelBuffer
        self.cvMetalTexture = cvMetalTexture
        self.mtlTexture = mtlTexture
        self.presentationTime = presentationTime
    }
}

// MARK: - Video Exporter

/// GPU-only video exporter for scenes (PR-E2).
///
/// Exports CompiledScene to H.264 MP4 using:
/// - CVPixelBufferPool from AVAssetWriterInputPixelBufferAdaptor
/// - CVMetalTextureCache for GPU-direct rendering
/// - In-flight pipelining with completion handlers
/// - DispatchGroup for correct append synchronization
///
/// No CPU readback (getBytes/CIContext) is used.
///
/// Usage:
/// ```swift
/// let exporter = VideoExporter()
/// exporter.exportVideo(
///     compiledScene: scene,
///     scenePlayer: player,  // for snapshot only
///     renderer: renderer,
///     textureProvider: exportTextureProvider,
///     pathRegistry: pathRegistry,
///     assetSizes: scene.mergedAssetIndex.sizeById,
///     settings: settings,
///     progress: { print("Progress: \($0)") },
///     completion: { result in ... }
/// )
/// ```
public final class VideoExporter: @unchecked Sendable {
    // MARK: - Queues

    /// Main export queue for frame stepping
    private let exportQueue = DispatchQueue(label: "com.animi.videoexporter", qos: .userInitiated)

    // MARK: - Thread-safe Active Session

    private let sessionLock = NSLock()
    private var _activeSession: ExportSession?

    private func setActiveSession(_ session: ExportSession?) {
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

    public init() {}

    // MARK: - Export-Owned Render Context

    /// Single-scene export handoff for `exportQueue`.
    /// Owns an export-only renderer plus immutable snapshots and a thread-safe texture provider.
    private final class SingleSceneExportWorkItem: @unchecked Sendable {
        let runtime: SceneRuntime
        let snapshot: SceneRenderStateSnapshot
        let renderer: MetalRenderer
        let textureProvider: ExportTextureProvider
        let pathRegistry: PathRegistry
        let assetSizes: [String: AssetSize]
        let videoSelections: [String: VideoSelection]
        let settings: VideoExportSettings
        let backgroundState: EffectiveBackgroundState?
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
            self.mediaSnapshot = mediaSnapshot
            self.backgroundSnapshot = backgroundSnapshot
            self.budget = budget
        }
    }

    /// Timeline export handoff for `exportQueue`.
    /// Keeps preview and export isolated by owning a dedicated renderer/compositor pair.
    private final class TimelineExportWorkItem: @unchecked Sendable {
        let session: TimelineCompositionEngine.TimelineExportSession
        let renderer: MetalRenderer
        let transitionCompositor: TransitionCompositor
        let totalFrames: Int
        let canvasSize: SizeD
        let backgroundState: EffectiveBackgroundState?
        let backgroundSnapshot: ExportBackgroundSnapshot?
        let settings: TimelineExportSettings
        let budget: ExportResourceBudget
        let renderDiagnosticsSink: RenderDiagnosticsSink?

        init(
            session: TimelineCompositionEngine.TimelineExportSession,
            renderer: MetalRenderer,
            transitionCompositor: TransitionCompositor,
            totalFrames: Int,
            canvasSize: SizeD,
            backgroundState: EffectiveBackgroundState?,
            backgroundSnapshot: ExportBackgroundSnapshot?,
            settings: TimelineExportSettings,
            budget: ExportResourceBudget,
            renderDiagnosticsSink: RenderDiagnosticsSink?
        ) {
            self.session = session
            self.renderer = renderer
            self.transitionCompositor = transitionCompositor
            self.totalFrames = totalFrames
            self.canvasSize = canvasSize
            self.backgroundState = backgroundState
            self.backgroundSnapshot = backgroundSnapshot
            self.settings = settings
            self.budget = budget
            self.renderDiagnosticsSink = renderDiagnosticsSink
        }
    }

    private func makeExportRenderer(device: MTLDevice, maxFramesInFlight: Int = 3) throws -> MetalRenderer {
        let options = MetalRendererOptions(maxFramesInFlight: maxFramesInFlight)
        return try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm, options: options)
    }

    private func makeExportTransitionCompositor(device: MTLDevice) throws -> TransitionCompositor {
        try TransitionCompositor(device: device, colorPixelFormat: .bgra8Unorm)
    }

    // MARK: - Public API

    /// Exports a compiled scene to video.
    ///
    /// - Parameters:
    ///   - compiledScene: Scene to export (runtime + assets)
    ///   - scenePlayer: ScenePlayer instance (MainActor) for state snapshot
    ///   - device: Metal device used to build an export-owned renderer
    ///   - textureProvider: Thread-safe export texture provider
    ///   - pathRegistry: Path registry from compiled scene
    ///   - assetSizes: Asset sizes from mergedAssetIndex.sizeById
    ///   - settings: Export configuration
    ///   - backgroundState: Background state for rendering (PR5)
    ///   - progress: Progress callback (0.0 - 1.0), called on main queue
    ///   - completion: Completion callback, called on main queue
    @MainActor
    public func exportVideo(
        compiledScene: CompiledScene,
        scenePlayer: ScenePlayer,
        device: MTLDevice,
        textureProvider: ExportTextureProvider,
        pathRegistry: PathRegistry,
        assetSizes: [String: AssetSize],
        settings: VideoExportSettings,
        backgroundState: EffectiveBackgroundState?,
        budget: ExportResourceBudget = .default,
        mediaSnapshot: ExportMediaSnapshot? = nil,
        backgroundSnapshot: ExportBackgroundSnapshot? = nil,
        onFinishing: (() -> Void)? = nil,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let session = ExportSession(completion: completion)
        setActiveSession(session)

        session.setOnTerminal { [weak self] in
            self?.setActiveSession(nil)
        }
        if let onFinishing { session.setOnFinishing(onFinishing) }

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

        let workItem = SingleSceneExportWorkItem(
            runtime: runtime,
            snapshot: snapshot,
            renderer: exportRenderer,
            textureProvider: textureProvider,
            pathRegistry: pathRegistry,
            assetSizes: assetSizes,
            videoSelections: videoSelections,
            settings: settings,
            backgroundState: backgroundState,
            mediaSnapshot: mediaSnapshot,
            backgroundSnapshot: backgroundSnapshot,
            budget: budget
        )

        // Run export on background queue
        let allAssetIds = Set(compiledScene.mergedAssetIndex.basenameById.keys)
        exportQueue.async { [self, workItem, session, allAssetIds] in
            // Warm all scene assets (unified API — same behavior as old preloadAll)
            workItem.textureProvider.warm(assetIds: allAssetIds, commandQueue: workItem.renderer.commandQueue)

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
                        for assetId in imageRef.bindingAssetIds {
                            workItem.textureProvider.setTexture(texture, for: assetId)
                        }
                    }
                }
            }

            // Load background textures on export queue
            if let bgSnapshot = workItem.backgroundSnapshot {
                let commandQueue = workItem.renderer.commandQueue
                let projectStore = ProjectStore.shared
                for ref in bgSnapshot.regionRefs {
                    if let url = try? projectStore.absoluteURL(for: ref.mediaRef) {
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

            guard !session.isCancelled else {
                session.complete(with: .failure(VideoExportError.cancelled))
                return
            }

            self.runExportLoop(
                runtime: workItem.runtime,
                snapshot: workItem.snapshot,
                renderer: workItem.renderer,
                textureProvider: workItem.textureProvider,
                pathRegistry: workItem.pathRegistry,
                assetSizes: workItem.assetSizes,
                videoSelections: workItem.videoSelections,
                settings: workItem.settings,
                backgroundState: workItem.backgroundState,
                session: session,
                budget: workItem.budget,
                progress: progress
            )
        }
    }

    // MARK: - Export Loop

    private func runExportLoop(
        runtime: SceneRuntime,
        snapshot: SceneRenderStateSnapshot,
        renderer: MetalRenderer,
        textureProvider: MutableTextureProvider,
        pathRegistry: PathRegistry,
        assetSizes: [String: AssetSize],
        videoSelections: [String: VideoSelection],
        settings: VideoExportSettings,
        backgroundState: EffectiveBackgroundState?,
        session: ExportSession,
        budget: ExportResourceBudget = .default,
        progress: @escaping (Double) -> Void
    ) {
        // Delete existing file if present
        try? FileManager.default.removeItem(at: settings.outputURL)

        // 1. Build audio pipeline (if configured)
        var audioPipeline: BuiltAudioPipeline?

        if let audioConfig = settings.audio {
            let builder = AudioCompositionBuilder()
            do {
                audioPipeline = try builder.build(
                    runtime: runtime,
                    fps: settings.fps,
                    videoSelectionsByBlockId: videoSelections,
                    config: audioConfig
                )
            } catch {
                session.complete(with: .failure(VideoExportError.failedToBuildAudioPipeline(error)))
                return
            }
        }

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
            try pipeline.startWriting()
        } catch {
            session.complete(with: .failure(error))
            return
        }

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

        // 4. Setup video slots coordinator
        var videoSlotsCoordinator: ExportVideoSlotsCoordinator?
        if !videoSelections.isEmpty {
            let coordinator = ExportVideoSlotsCoordinator(
                device: metalDevice,
                textureCache: textureCache,
                runtime: runtime,
                sceneFPS: Double(runtime.fps),
                exportTextureProvider: textureProvider,
                videoPrefetchFrames: budget.videoPrefetchFrames,
                maxActiveProviders: budget.maxActiveVideoProviders
            )
            coordinator.configure(videoSelectionsByBlockId: videoSelections)
            videoSlotsCoordinator = coordinator
        }

        session.setCleanup(
            onSuccess: { videoSlotsCoordinator?.finish() },
            onFailure: { videoSlotsCoordinator?.cancel() },
            onCancel:  { videoSlotsCoordinator?.cancel() }
        )
        session.transitionToRendering()

        // 5. Sync primitives — semaphore capped by budget
        let semaphore = DispatchSemaphore(value: renderer.maxFramesInFlight)
        let videoGroup = DispatchGroup()

        // 6. Video export loop
        let totalFrames = runtime.durationFrames
        let canvasSize = runtime.canvasSize

        for frameIndex in 0..<totalFrames {
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

                // Update video textures before render
                videoSlotsCoordinator?.updateTextures(forSceneFrameIndex: frameIndex)

                if let error = videoSlotsCoordinator?.providerError {
                    pipeline.setError(error)
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                // Build render commands
                let commands = SceneRenderPlan.renderCommands(
                    for: runtime,
                    sceneFrameIndex: frameIndex,
                    userTransforms: snapshot.userTransforms,
                    variantOverrides: snapshot.variantOverrides,
                    userMediaPresent: snapshot.userMediaPresent,
                    layerToggleState: snapshot.layerToggleState
                )

                let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(settings.fps))
                let renderTarget = RenderTarget(
                    texture: targetTexture,
                    drawableScale: 1.0,
                    animSize: canvasSize
                )

                guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
                    pipeline.setError(VideoExportError.failedToCreateCommandBuffer)
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                // InFlightFrame keeps CVMetalTexture alive until GPU completion + enqueue
                let inFlightFrame = InFlightFrame(
                    pixelBuffer: pixelBuffer,
                    cvMetalTexture: cvMetalTexture,
                    mtlTexture: targetTexture,
                    presentationTime: pts
                )

                do {
                    try renderer.draw(
                        commands: commands,
                        target: renderTarget,
                        clearColor: settings.clearColor,
                        textureProvider: textureProvider,
                        commandBuffer: commandBuffer,
                        assetSizes: assetSizes,
                        pathRegistry: pathRegistry,
                        backgroundState: backgroundState
                    )
                } catch {
                    pipeline.setError(VideoExportError.renderError(error))
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                // GPU completion: pass ONLY pixelBuffer + pts to pump.
                // InFlightFrame (with cvMetalTexture) deallocs here after enqueue.
                commandBuffer.addCompletedHandler { _ in
                    guard !session.shouldStop else {
                        videoGroup.leave()
                        semaphore.signal()
                        return
                    }
                    pipeline.enqueueVideoFrame(
                        inFlightFrame.pixelBuffer,
                        presentationTime: inFlightFrame.presentationTime
                    ) {
                        videoGroup.leave()
                        semaphore.signal()
                    }
                }

                commandBuffer.commit()
            }

            session.emitProgressIfActive(Double(frameIndex + 1) / Double(totalFrames), via: progress)
        }

        // 7. Wait for all GPU completions to enqueue
        videoGroup.wait()

        // 8. Finish or cancel — cleanup closures fire inside complete()
        if session.shouldStop {
            if !session.isCancelled { pipeline.cancel() }
            session.complete(with: .failure(session.terminalError ?? VideoExportError.cancelled))
        } else {
            session.finishWriting()
        }
    }

    // MARK: - Timeline Export (v6 Schema)

    /// Settings for timeline export with transitions.
    public struct TimelineExportSettings: Sendable {
        /// Output file URL
        public let outputURL: URL

        /// Output size in pixels
        public let sizePx: (width: Int, height: Int)

        /// Frame rate
        public let fps: Int

        /// Target average bitrate in bps
        public let bitrate: Int

        /// GOP length in seconds
        public let gopSeconds: Int

        /// Clear color for each frame
        public let clearColor: ClearColor

        /// Audio export configuration
        public let audio: AudioExportConfig?

        public init(
            outputURL: URL,
            sizePx: (width: Int, height: Int),
            fps: Int = 30,
            bitrate: Int = 10_000_000,
            gopSeconds: Int = 2,
            clearColor: ClearColor = .opaqueBlack,
            audio: AudioExportConfig? = nil
        ) {
            self.outputURL = outputURL
            self.sizePx = sizePx
            self.fps = fps
            self.bitrate = bitrate
            self.gopSeconds = gopSeconds
            self.clearColor = clearColor
            self.audio = audio
        }
    }

    /// Exports a multi-scene timeline with transitions to video.
    ///
    /// Uses TimelineCompositionEngine to resolve frames and TransitionCompositor
    /// for transition effects. Produces frame-identical output to preview.
    ///
    /// - Parameters:
    ///   - engine: TimelineCompositionEngine with configured timeline
    ///   - backgroundState: Background state for rendering
    ///   - settings: Export configuration
    ///   - progress: Progress callback (0.0 - 1.0), called on main queue
    ///   - completion: Completion callback, called on main queue
    @MainActor
    public func exportTimeline(
        engine: TimelineCompositionEngine,
        backgroundState: EffectiveBackgroundState?,
        backgroundSnapshot: ExportBackgroundSnapshot?,
        settings: TimelineExportSettings,
        budget: ExportResourceBudget = .default,
        renderDiagnosticsSink: RenderDiagnosticsSink? = nil,
        onFinishing: (() -> Void)? = nil,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let exportSession = ExportSession(completion: completion)
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

        // TT-05: Build immutable export session on MainActor, then dispatch to background
        Task { @MainActor [weak self] in
            guard let self else {
                exportSession.complete(with: .failure(VideoExportError.cancelled))
                return
            }

            guard !exportSession.isCancelled else {
                exportSession.complete(with: .failure(VideoExportError.cancelled))
                return
            }

            let tlSession: TimelineCompositionEngine.TimelineExportSession
            do {
                tlSession = try await engine.buildExportSession()
            } catch {
                exportSession.complete(with: .failure(VideoExportError.renderError(error)))
                return
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

            let workItem = TimelineExportWorkItem(
                session: tlSession,
                renderer: exportRenderer,
                transitionCompositor: exportCompositor,
                totalFrames: totalFrames,
                canvasSize: canvasSize,
                backgroundState: backgroundState,
                backgroundSnapshot: backgroundSnapshot,
                settings: settings,
                budget: budget,
                renderDiagnosticsSink: renderDiagnosticsSink
            )

            self.exportQueue.async { [self, workItem, exportSession] in
                // Load background textures on export queue (off MainActor)
                let exportBackgroundProvider = ThreadSafeInMemoryTextureProvider()
                if let bgSnapshot = workItem.backgroundSnapshot {
                    let commandQueue = workItem.renderer.commandQueue
                    for ref in bgSnapshot.regionRefs {
                        if let url = try? ProjectStore.shared.absoluteURL(for: ref.mediaRef),
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

                var audioPipeline: BuiltAudioPipeline?
                if let audioConfig = workItem.settings.audio {
                    do {
                        let builder = AudioCompositionBuilder()
                        audioPipeline = try builder.buildTimeline(
                            sceneData: workItem.session.audioSceneData,
                            transitionMath: workItem.session.transitionMath,
                            fps: workItem.settings.fps,
                            config: audioConfig
                        )
                    } catch {
                        exportSession.complete(with: .failure(VideoExportError.failedToBuildAudioPipeline(error)))
                        return
                    }
                }

                self.runTimelineExportLoop(
                    tlSession: workItem.session,
                    renderer: workItem.renderer,
                    transitionCompositor: workItem.transitionCompositor,
                    totalFrames: workItem.totalFrames,
                    canvasSize: workItem.canvasSize,
                    backgroundState: workItem.backgroundState,
                    backgroundTextureProvider: exportBackgroundProvider,
                    audioPipeline: audioPipeline,
                    settings: workItem.settings,
                    budget: workItem.budget,
                    renderDiagnosticsSink: workItem.renderDiagnosticsSink,
                    exportSession: exportSession,
                    progress: progress
                )
            }
        }
    }

    // MARK: - Timeline Export Loop

    private func runTimelineExportLoop(
        tlSession: TimelineCompositionEngine.TimelineExportSession,
        renderer: MetalRenderer,
        transitionCompositor: TransitionCompositor,
        totalFrames: Int,
        canvasSize: SizeD,
        backgroundState: EffectiveBackgroundState?,
        backgroundTextureProvider: TextureProvider,
        audioPipeline: BuiltAudioPipeline?,
        settings: TimelineExportSettings,
        budget: ExportResourceBudget = .default,
        renderDiagnosticsSink: RenderDiagnosticsSink? = nil,
        exportSession: ExportSession,
        progress: @escaping (Double) -> Void
    ) {
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

        // 3. Create residency controller + runtime on export queue
        let residencyController = TimelineExportResidencyController(
            session: tlSession,
            budget: budget,
            device: renderer.commandQueue.device,
            commandQueue: renderer.commandQueue,
            textureCache: textureCache
        )

        let exportRuntime = TimelineExportRuntime(
            session: tlSession,
            residencyController: residencyController
        )

        exportSession.setCleanup(
            onSuccess: { exportRuntime.finish() },
            onFailure: { exportRuntime.cancel() },
            onCancel:  { exportRuntime.cancel() }
        )
        exportSession.transitionToRendering()

        // 4. Video export loop (semaphore capped by budget)
        let semaphore = DispatchSemaphore(value: budget.maxFramesInFlight)
        let videoGroup = DispatchGroup()

        for frameIndex in 0..<totalFrames {
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

                // Resolve and render via unified TimelineRenderExecutor
                do {
                    let resolved = try exportRuntime.resolveFrame(frameIndex)

                    let request = TimelineRenderRequest(
                        resolved: resolved,
                        targetTexture: targetTexture,
                        drawableScale: 1.0,
                        timelineCanvasSize: canvasSize,
                        backgroundState: backgroundState,
                        backgroundTextureProvider: backgroundTextureProvider,
                        clearColorOverride: settings.clearColor,
                        presentationDrawable: nil,
                        waitUntilCompleted: true,
                        diagnosticFrameTag: frameIndex
                    )
                    do {
                        try TimelineRenderExecutor.render(
                            request, renderer: renderer,
                            commandQueue: renderer.commandQueue,
                            transitionCompositor: transitionCompositor,
                            completionQueue: nil,
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
                } catch {
                    pipeline.setError(VideoExportError.renderError(error))
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

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

        // 6. Finish or cancel — cleanup closures fire inside complete()
        if exportSession.shouldStop {
            if !exportSession.isCancelled { pipeline.cancel() }
            exportSession.complete(with: .failure(exportSession.terminalError ?? VideoExportError.cancelled))
        } else {
            exportSession.finishWriting()
        }
    }

}

// MARK: - TT-02: Resolution to Export Error Mapping

extension VideoExporter {
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

// MARK: - Empty Texture Provider

/// Empty texture provider for background-only renders.
private final class EmptyTextureProvider: TextureProvider {
    func texture(for assetId: String) -> MTLTexture? {
        nil
    }
}
