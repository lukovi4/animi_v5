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

    /// Timeout for writer backpressure wait in seconds (default: 3.0)
    public let backpressureTimeoutSeconds: Double

    /// Audio export configuration (PR-E4). nil = video-only export.
    public let audio: AudioExportConfig?

    public init(
        outputURL: URL,
        sizePx: (width: Int, height: Int),
        fps: Int,
        bitrate: Int = 10_000_000,
        gopSeconds: Int = 2,
        clearColor: ClearColor = .opaqueBlack,
        backpressureTimeoutSeconds: Double = 3.0,
        audio: AudioExportConfig? = nil
    ) {
        self.outputURL = outputURL
        self.sizePx = sizePx
        self.fps = fps
        self.bitrate = bitrate
        self.gopSeconds = gopSeconds
        self.clearColor = clearColor
        self.backpressureTimeoutSeconds = backpressureTimeoutSeconds
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

    /// Writer is not in writing state
    case writerNotWriting(Error?)

    /// Writer backpressure timeout
    case writerBackpressureTimeout

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

    /// Audio backpressure timeout
    case audioBackpressureTimeout

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
        case .writerNotWriting(let error):
            return "Writer not in writing state: \(error?.localizedDescription ?? "unknown")"
        case .writerBackpressureTimeout:
            return "Writer backpressure timeout - input not ready"
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
        case .audioBackpressureTimeout:
            return "Audio backpressure timeout - input not ready"
        case .missingAudioTrack(let url):
            return "Missing audio track in: \(url.lastPathComponent)"
        case .failedToBuildAudioPipeline(let error):
            return "Failed to build audio pipeline: \(error.localizedDescription)"
        }
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
public final class VideoExporter {
    // MARK: - Queues

    /// Main export queue for frame stepping
    private let exportQueue = DispatchQueue(label: "com.animi.videoexporter", qos: .userInitiated)

    /// Serial queue for all AVAssetWriter append operations
    private let writerQueue = DispatchQueue(label: "com.animi.videoexporter.writer")

    // MARK: - Thread-safe Cancel

    private let cancelLock = NSLock()
    private var _isCancelled = false

    private func isCancelled() -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return _isCancelled
    }

    /// Cancels the current export.
    public func cancel() {
        cancelLock.lock()
        _isCancelled = true
        cancelLock.unlock()
    }

    // MARK: - Thread-safe Error

    private let exportErrorLock = NSLock()
    private var _exportError: Error?

    private func exportError() -> Error? {
        exportErrorLock.lock()
        defer { exportErrorLock.unlock() }
        return _exportError
    }

    private func setExportErrorOnce(_ error: Error) {
        exportErrorLock.lock()
        defer { exportErrorLock.unlock() }
        if _exportError == nil {
            _exportError = error
        }
    }

    private func resetState() {
        cancelLock.lock()
        _isCancelled = false
        cancelLock.unlock()

        exportErrorLock.lock()
        _exportError = nil
        exportErrorLock.unlock()
    }

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Exports a compiled scene to video.
    ///
    /// - Parameters:
    ///   - compiledScene: Scene to export (runtime + assets)
    ///   - scenePlayer: ScenePlayer instance (MainActor) for state snapshot
    ///   - renderer: MetalRenderer for GPU rendering
    ///   - textureProvider: Thread-safe mutable texture provider (use ExportTextureProvider)
    ///   - pathRegistry: Path registry from compiled scene
    ///   - assetSizes: Asset sizes from mergedAssetIndex.sizeById
    ///   - userMediaService: UserMediaService for video selections snapshot (PR-E3)
    ///   - settings: Export configuration
    ///   - backgroundState: Background state for rendering (PR5)
    ///   - progress: Progress callback (0.0 - 1.0), called on main queue
    ///   - completion: Completion callback, called on main queue
    @MainActor
    public func exportVideo(
        compiledScene: CompiledScene,
        scenePlayer: ScenePlayer,
        renderer: MetalRenderer,
        textureProvider: MutableTextureProvider,
        pathRegistry: PathRegistry,
        assetSizes: [String: AssetSize],
        userMediaService: UserMediaService?,
        settings: VideoExportSettings,
        backgroundState: EffectiveBackgroundState?,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // Validate FPS match
        guard settings.fps == compiledScene.runtime.fps else {
            completion(.failure(VideoExportError.fpsMismatch(
                settingsFps: settings.fps,
                runtimeFps: compiledScene.runtime.fps
            )))
            return
        }

        // Capture state snapshot on MainActor (deep copy)
        let snapshot = scenePlayer.exportStateSnapshot()
        let runtime = compiledScene.runtime

        // PR-E3: Capture video selections snapshot on MainActor
        let videoSelections = userMediaService?.exportVideoSelectionsSnapshot() ?? [:]

        // Reset state
        resetState()

        // Run export on background queue
        exportQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(VideoExportError.cancelled))
                }
                return
            }

            self.runExportLoop(
                runtime: runtime,
                snapshot: snapshot,
                renderer: renderer,
                textureProvider: textureProvider,
                pathRegistry: pathRegistry,
                assetSizes: assetSizes,
                videoSelections: videoSelections,
                settings: settings,
                backgroundState: backgroundState,
                progress: progress,
                completion: completion
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
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // Delete existing file if present
        try? FileManager.default.removeItem(at: settings.outputURL)

        // 1. Create AVAssetWriter
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: settings.outputURL, fileType: .mp4)
        } catch {
            DispatchQueue.main.async {
                completion(.failure(VideoExportError.failedToCreateWriter(error)))
            }
            return
        }

        // 2. Configure video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.sizePx.width,
            AVVideoHeightKey: settings.sizePx.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: settings.fps * settings.gopSeconds,
                AVVideoExpectedSourceFrameRateKey: settings.fps
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        // Check canAdd before adding
        guard writer.canAdd(videoInput) else {
            DispatchQueue.main.async {
                completion(.failure(VideoExportError.cannotAddVideoInput))
            }
            return
        }
        writer.add(videoInput)

        // 3. Create pixel buffer adaptor
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: settings.sizePx.width,
            kCVPixelBufferHeightKey as String: settings.sizePx.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        // 4. PR-E4: Build audio pipeline (if configured)
        var audioPipeline: BuiltAudioPipeline?
        var audioInput: AVAssetWriterInput?
        var audioPump: AudioWriterPump?

        if let audioConfig = settings.audio {
            // Build audio composition
            let builder = AudioCompositionBuilder()
            do {
                audioPipeline = try builder.build(
                    runtime: runtime,
                    fps: settings.fps,
                    videoSelectionsByBlockId: videoSelections,
                    config: audioConfig
                )
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(VideoExportError.failedToBuildAudioPipeline(error)))
                }
                return
            }

            // Check if composition has audio tracks
            if let pipeline = audioPipeline,
               !pipeline.composition.tracks(withMediaType: .audio).isEmpty {
                // Create audio input
                let aacSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128000
                ]

                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
                input.expectsMediaDataInRealTime = false

                guard writer.canAdd(input) else {
                    DispatchQueue.main.async {
                        completion(.failure(VideoExportError.cannotAddAudioInput))
                    }
                    return
                }
                writer.add(input)
                audioInput = input
                audioPump = AudioWriterPump()
            }
        }

        // 5. Start writing
        guard writer.startWriting() else {
            DispatchQueue.main.async {
                completion(.failure(VideoExportError.writerStartFailed(writer.error)))
            }
            return
        }
        writer.startSession(atSourceTime: .zero)

        // 6. Create CVMetalTextureCache using commandQueue.device
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
            writer.cancelWriting()
            DispatchQueue.main.async {
                completion(.failure(VideoExportError.failedToCreateTextureCache))
            }
            return
        }

        // 7. PR-E3: Setup video slots coordinator
        var videoSlotsCoordinator: ExportVideoSlotsCoordinator?
        if !videoSelections.isEmpty {
            let coordinator = ExportVideoSlotsCoordinator(
                device: metalDevice,
                textureCache: textureCache,
                runtime: runtime,
                sceneFPS: Double(runtime.fps),
                exportTextureProvider: textureProvider
            )
            coordinator.configure(videoSelectionsByBlockId: videoSelections)

            do {
                try coordinator.prepareAll()
                videoSlotsCoordinator = coordinator
            } catch {
                writer.cancelWriting()
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
        }

        // 8. Setup synchronization primitives
        let maxInFlight = renderer.maxFramesInFlight
        let semaphore = DispatchSemaphore(value: maxInFlight)
        let videoGroup = DispatchGroup()
        let audioGroup = DispatchGroup()
        let backpressureTimeout = settings.backpressureTimeoutSeconds

        // 9. PR-E4: Start audio pump in parallel (if configured)
        if let pipeline = audioPipeline,
           let input = audioInput,
           let pump = audioPump {
            audioGroup.enter()
            pump.start(
                composition: pipeline.composition,
                audioMix: pipeline.audioMix,
                audioInput: input,
                writerQueue: writerQueue,
                backpressureTimeout: backpressureTimeout,
                cancelCheck: { [weak self] in self?.isCancelled() ?? true },
                errorCheck: { [weak self] in self?.exportError() },
                setExportErrorOnce: { [weak self] in self?.setExportErrorOnce($0) },
                completion: { audioGroup.leave() }
            )
        }

        // 10. Video export loop
        let totalFrames = runtime.durationFrames
        let canvasSize = runtime.canvasSize

        for frameIndex in 0..<totalFrames {
            // Check cancellation
            if isCancelled() { break }

            // Check for errors from other frames
            if exportError() != nil { break }

            // Wait for in-flight slot (GPU backpressure)
            semaphore.wait()
            videoGroup.enter()

            autoreleasepool {
                // Get pixel buffer from pool
                guard let pool = adaptor.pixelBufferPool else {
                    setExportErrorOnce(VideoExportError.noPixelBufferPool)
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
                    setExportErrorOnce(VideoExportError.failedToCreatePixelBuffer(pbStatus))
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
                    setExportErrorOnce(VideoExportError.failedToCreateMetalTexture(texStatus))
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                // PR-E3: Update video textures before render
                videoSlotsCoordinator?.updateTextures(forSceneFrameIndex: frameIndex)

                // P0 #2: Check for video slot provider errors
                if let error = videoSlotsCoordinator?.providerError {
                    setExportErrorOnce(error)
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

                // Create presentation time and render target
                let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(settings.fps))
                let renderTarget = RenderTarget(
                    texture: targetTexture,
                    drawableScale: 1.0,
                    animSize: canvasSize
                )

                // Create command buffer
                guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
                    setExportErrorOnce(VideoExportError.failedToCreateCommandBuffer)
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                // Create in-flight frame holder
                let inFlightFrame = InFlightFrame(
                    pixelBuffer: pixelBuffer,
                    cvMetalTexture: cvMetalTexture,
                    mtlTexture: targetTexture,
                    presentationTime: pts
                )

                // Render frame
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
                    setExportErrorOnce(VideoExportError.renderError(error))
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                // Add completion handler - append on writerQueue after GPU completion
                commandBuffer.addCompletedHandler { [weak self] _ in
                    guard let self else {
                        videoGroup.leave()
                        semaphore.signal()
                        return
                    }

                    self.writerQueue.async {
                        defer {
                            videoGroup.leave()
                            semaphore.signal()
                        }

                        // Check cancellation
                        if self.isCancelled() { return }

                        // Check for existing error
                        if self.exportError() != nil { return }

                        // Check writer status
                        if writer.status != .writing {
                            self.setExportErrorOnce(VideoExportError.writerNotWriting(writer.error))
                            return
                        }

                        // Bounded wait for isReadyForMoreMediaData
                        let deadline = Date().addingTimeInterval(backpressureTimeout)
                        while !videoInput.isReadyForMoreMediaData {
                            if self.isCancelled() { return }
                            if self.exportError() != nil { return }
                            if Date() > deadline {
                                self.setExportErrorOnce(VideoExportError.writerBackpressureTimeout)
                                return
                            }
                            // Small sleep to yield
                            Thread.sleep(forTimeInterval: 0.002)
                        }

                        // Append pixel buffer
                        let ok = adaptor.append(
                            inFlightFrame.pixelBuffer,
                            withPresentationTime: inFlightFrame.presentationTime
                        )
                        if !ok {
                            self.setExportErrorOnce(VideoExportError.appendFailed(writer.error))
                        }
                    }
                }

                // Commit command buffer (non-blocking)
                commandBuffer.commit()
            }

            // Report progress after commit (frame submitted)
            let progressValue = Double(frameIndex + 1) / Double(totalFrames)
            DispatchQueue.main.async {
                progress(progressValue)
            }
        }

        // 11. Wait for all video frames to complete
        videoGroup.wait()

        // 12. Wait for audio pump to complete (if running)
        audioGroup.wait()

        // 13. Finalization on writerQueue
        writerQueue.async { [weak self] in
            guard let self else {
                audioPump?.cancel()
                videoSlotsCoordinator?.cancel()
                DispatchQueue.main.async {
                    completion(.failure(VideoExportError.cancelled))
                }
                return
            }

            // Check cancellation
            if self.isCancelled() {
                audioPump?.cancel()
                videoSlotsCoordinator?.cancel()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: settings.outputURL)
                DispatchQueue.main.async {
                    completion(.failure(VideoExportError.cancelled))
                }
                return
            }

            // Check for export errors
            if let error = self.exportError() {
                audioPump?.cancel()
                videoSlotsCoordinator?.cancel()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: settings.outputURL)
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            // PR-E3: Finish video slots coordinator
            videoSlotsCoordinator?.finish()

            // Finalize writer - mark both inputs as finished
            videoInput.markAsFinished()
            // Note: audioInput.markAsFinished() is called in AudioWriterPump on completion

            writer.finishWriting {
                if writer.status == .completed {
                    DispatchQueue.main.async {
                        completion(.success(settings.outputURL))
                    }
                } else {
                    try? FileManager.default.removeItem(at: settings.outputURL)
                    DispatchQueue.main.async {
                        completion(.failure(VideoExportError.finishFailed(writer.error)))
                    }
                }
            }
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

        /// Timeout for writer backpressure wait in seconds
        public let backpressureTimeoutSeconds: Double

        /// Audio export configuration
        public let audio: AudioExportConfig?

        public init(
            outputURL: URL,
            sizePx: (width: Int, height: Int),
            fps: Int = 30,
            bitrate: Int = 10_000_000,
            gopSeconds: Int = 2,
            clearColor: ClearColor = .opaqueBlack,
            backpressureTimeoutSeconds: Double = 3.0,
            audio: AudioExportConfig? = nil
        ) {
            self.outputURL = outputURL
            self.sizePx = sizePx
            self.fps = fps
            self.bitrate = bitrate
            self.gopSeconds = gopSeconds
            self.clearColor = clearColor
            self.backpressureTimeoutSeconds = backpressureTimeoutSeconds
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
    ///   - renderer: MetalRenderer for GPU rendering
    ///   - transitionCompositor: TransitionCompositor for transition effects
    ///   - backgroundState: Background state for rendering
    ///   - settings: Export configuration
    ///   - progress: Progress callback (0.0 - 1.0), called on main queue
    ///   - completion: Completion callback, called on main queue
    @MainActor
    public func exportTimeline(
        engine: TimelineCompositionEngine,
        renderer: MetalRenderer,
        transitionCompositor: TransitionCompositor,
        backgroundState: EffectiveBackgroundState?,
        backgroundTextureProvider: TextureProvider,
        settings: TimelineExportSettings,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let transitionMath = engine.transitionMath else {
            completion(.failure(VideoExportError.renderError(TimelineExportError.noTimeline)))
            return
        }

        // Validate FPS match
        guard settings.fps == engine.fps else {
            completion(.failure(VideoExportError.fpsMismatch(
                settingsFps: settings.fps,
                runtimeFps: engine.fps
            )))
            return
        }

        // Capture necessary data for background thread
        let totalFrames = transitionMath.compressedDurationFrames
        let canvasSize = engine.canvasSize

        // Reset state
        resetState()

        // Prepare engine and build audio pipeline
        Task {
            await engine.prepareForPlayback(startingAt: 0)

            // Build audio pipeline if configured
            var audioPipeline: BuiltAudioPipeline?
            if let audioConfig = settings.audio {
                do {
                    let sceneData = await engine.prepareAudioExportData()
                    let builder = AudioCompositionBuilder()
                    audioPipeline = try builder.buildTimeline(
                        sceneData: sceneData,
                        transitionMath: transitionMath,
                        fps: settings.fps,
                        config: audioConfig
                    )
                } catch {
                    DispatchQueue.main.async {
                        completion(.failure(VideoExportError.failedToBuildAudioPipeline(error)))
                    }
                    return
                }
            }

            // Run export on background queue
            exportQueue.async { [weak self] in
                guard let self else {
                    DispatchQueue.main.async {
                        completion(.failure(VideoExportError.cancelled))
                    }
                    return
                }

                self.runTimelineExportLoop(
                    engine: engine,
                    renderer: renderer,
                    transitionCompositor: transitionCompositor,
                    totalFrames: totalFrames,
                    canvasSize: canvasSize,
                    backgroundState: backgroundState,
                    backgroundTextureProvider: backgroundTextureProvider,
                    audioPipeline: audioPipeline,
                    settings: settings,
                    progress: progress,
                    completion: completion
                )
            }
        }
    }

    // MARK: - Timeline Export Loop

    private func runTimelineExportLoop(
        engine: TimelineCompositionEngine,
        renderer: MetalRenderer,
        transitionCompositor: TransitionCompositor,
        totalFrames: Int,
        canvasSize: SizeD,
        backgroundState: EffectiveBackgroundState?,
        backgroundTextureProvider: TextureProvider,
        audioPipeline: BuiltAudioPipeline?,
        settings: TimelineExportSettings,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // Delete existing file
        try? FileManager.default.removeItem(at: settings.outputURL)

        // 1. Create AVAssetWriter
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: settings.outputURL, fileType: .mp4)
        } catch {
            DispatchQueue.main.async {
                completion(.failure(VideoExportError.failedToCreateWriter(error)))
            }
            return
        }

        // 2. Configure video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.sizePx.width,
            AVVideoHeightKey: settings.sizePx.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: settings.fps * settings.gopSeconds,
                AVVideoExpectedSourceFrameRateKey: settings.fps
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else {
            DispatchQueue.main.async {
                completion(.failure(VideoExportError.cannotAddVideoInput))
            }
            return
        }
        writer.add(videoInput)

        // 2b. Configure audio input (if audio pipeline provided)
        var audioInput: AVAssetWriterInput?
        var audioPump: AudioWriterPump?
        if audioPipeline != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false

            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
                audioPump = AudioWriterPump()
            }
        }

        // 3. Create pixel buffer adaptor
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: settings.sizePx.width,
            kCVPixelBufferHeightKey as String: settings.sizePx.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        // 4. Start writing (timeline export)
        guard writer.startWriting() else {
            DispatchQueue.main.async {
                completion(.failure(VideoExportError.writerStartFailed(writer.error)))
            }
            return
        }
        writer.startSession(atSourceTime: .zero)

        // 5. Create CVMetalTextureCache
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
            writer.cancelWriting()
            DispatchQueue.main.async {
                completion(.failure(VideoExportError.failedToCreateTextureCache))
            }
            return
        }

        // 6. Setup synchronization
        let maxInFlight = renderer.maxFramesInFlight
        let semaphore = DispatchSemaphore(value: maxInFlight)
        let videoGroup = DispatchGroup()
        let audioGroup = DispatchGroup()
        let backpressureTimeout = settings.backpressureTimeoutSeconds

        // 6b. Start audio pump in parallel (if configured)
        if let pipeline = audioPipeline,
           let input = audioInput,
           let pump = audioPump {
            audioGroup.enter()
            pump.start(
                composition: pipeline.composition,
                audioMix: pipeline.audioMix,
                audioInput: input,
                writerQueue: writerQueue,
                backpressureTimeout: backpressureTimeout,
                cancelCheck: { [weak self] in self?.isCancelled() ?? true },
                errorCheck: { [weak self] in self?.exportError() },
                setExportErrorOnce: { [weak self] in self?.setExportErrorOnce($0) },
                completion: { audioGroup.leave() }
            )
        }

        // 7. Video export loop
        for frameIndex in 0..<totalFrames {
            // Check cancellation
            if isCancelled() { break }
            if exportError() != nil { break }

            // Wait for in-flight slot
            semaphore.wait()
            videoGroup.enter()

            autoreleasepool {
                // Get pixel buffer from pool
                guard let pool = adaptor.pixelBufferPool else {
                    setExportErrorOnce(VideoExportError.noPixelBufferPool)
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
                    setExportErrorOnce(VideoExportError.failedToCreatePixelBuffer(pbStatus))
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
                    setExportErrorOnce(VideoExportError.failedToCreateMetalTexture(texStatus))
                    videoGroup.leave()
                    semaphore.signal()
                    return
                }

                // Create presentation time
                let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(settings.fps))

                // Create in-flight frame holder
                let inFlightFrame = InFlightFrame(
                    pixelBuffer: pixelBuffer,
                    cvMetalTexture: cvMetalTexture,
                    mtlTexture: targetTexture,
                    presentationTime: pts
                )

                // Resolve frame on main actor
                Task { @MainActor in
                    do {
                        guard let resolved = await engine.resolveFrame(frameIndex) else {
                            throw TimelineExportError.frameResolutionFailed(frameIndex)
                        }

                        // Render frame
                        try self.renderTimelineFrame(
                            resolved: resolved,
                            target: targetTexture,
                            renderer: renderer,
                            transitionCompositor: transitionCompositor,
                            canvasSize: canvasSize,
                            clearColor: settings.clearColor,
                            backgroundState: backgroundState,
                            backgroundTextureProvider: backgroundTextureProvider
                        )

                        // Append on writer queue after render
                        self.writerQueue.async {
                            defer {
                                videoGroup.leave()
                                semaphore.signal()
                            }

                            if self.isCancelled() { return }
                            if self.exportError() != nil { return }

                            if writer.status != .writing {
                                self.setExportErrorOnce(VideoExportError.writerNotWriting(writer.error))
                                return
                            }

                            // Bounded wait for readiness
                            let deadline = Date().addingTimeInterval(backpressureTimeout)
                            while !videoInput.isReadyForMoreMediaData {
                                if self.isCancelled() { return }
                                if self.exportError() != nil { return }
                                if Date() > deadline {
                                    self.setExportErrorOnce(VideoExportError.writerBackpressureTimeout)
                                    return
                                }
                                Thread.sleep(forTimeInterval: 0.002)
                            }

                            let ok = adaptor.append(
                                inFlightFrame.pixelBuffer,
                                withPresentationTime: inFlightFrame.presentationTime
                            )
                            if !ok {
                                self.setExportErrorOnce(VideoExportError.appendFailed(writer.error))
                            }
                        }
                    } catch {
                        self.setExportErrorOnce(VideoExportError.renderError(error))
                        videoGroup.leave()
                        semaphore.signal()
                    }
                }
            }

            // Report progress
            let progressValue = Double(frameIndex + 1) / Double(totalFrames)
            DispatchQueue.main.async {
                progress(progressValue)
            }
        }

        // 8. Wait for all video frames
        videoGroup.wait()

        // 8b. Wait for audio pump
        audioGroup.wait()

        // 9. Finalization
        writerQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(VideoExportError.cancelled))
                }
                return
            }

            if self.isCancelled() {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: settings.outputURL)
                DispatchQueue.main.async {
                    completion(.failure(VideoExportError.cancelled))
                }
                return
            }

            if let error = self.exportError() {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: settings.outputURL)
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            videoInput.markAsFinished()
            audioInput?.markAsFinished()

            writer.finishWriting {
                if writer.status == .completed {
                    DispatchQueue.main.async {
                        completion(.success(settings.outputURL))
                    }
                } else {
                    try? FileManager.default.removeItem(at: settings.outputURL)
                    DispatchQueue.main.async {
                        completion(.failure(VideoExportError.finishFailed(writer.error)))
                    }
                }
            }
        }
    }

    // MARK: - Timeline Frame Rendering

    @MainActor
    private func renderTimelineFrame(
        resolved: ResolvedTimelineFrame,
        target: MTLTexture,
        renderer: MetalRenderer,
        transitionCompositor: TransitionCompositor,
        canvasSize: SizeD,
        clearColor: ClearColor,
        backgroundState: EffectiveBackgroundState?,
        backgroundTextureProvider: TextureProvider
    ) throws {
        let commandQueue = renderer.commandQueue

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw VideoExportError.failedToCreateCommandBuffer
        }

        switch resolved {
        case .single(let context):
            // PR-G: Single scene with split-pass architecture
            // Pass 1: Background pre-pass with backgroundTextureProvider
            // Pass 2: Scene pass with scene provider (initialLoadAction: .load)
            let renderTarget = RenderTarget(
                texture: target,
                drawableScale: 1.0,
                animSize: context.canvasSize
            )

            // Pass 1: Background pre-pass (always prepare target)
            if let bg = backgroundState {
                try renderer.draw(
                    commands: [],
                    target: renderTarget,
                    clearColor: clearColor,
                    textureProvider: backgroundTextureProvider,
                    commandBuffer: commandBuffer,
                    assetSizes: [:],
                    pathRegistry: PathRegistry(),
                    backgroundState: bg,
                    initialLoadAction: .clear
                )
            } else {
                // Clear target even without background
                try renderer.draw(
                    commands: [],
                    target: renderTarget,
                    clearColor: clearColor,
                    textureProvider: backgroundTextureProvider,
                    commandBuffer: commandBuffer,
                    assetSizes: [:],
                    pathRegistry: PathRegistry(),
                    backgroundState: nil,
                    initialLoadAction: .clear
                )
            }

            // Pass 2: Scene pass (preserves background)
            try renderer.draw(
                commands: context.commands,
                target: renderTarget,
                clearColor: clearColor,
                textureProvider: context.textureProvider,
                commandBuffer: commandBuffer,
                assetSizes: context.assetSizes,
                pathRegistry: context.pathRegistry,
                backgroundState: nil,  // Already rendered in pass 1
                initialLoadAction: .load  // Preserve background
            )

        case .transition(let context):
            // Transition: render both scenes offscreen, then composite
            let texturePool = renderer.texturePool
            let sizePx = (width: target.width, height: target.height)

            // Acquire offscreen textures for scenes A and B
            guard let textureA = texturePool.acquireColorTexture(size: sizePx),
                  let textureB = texturePool.acquireColorTexture(size: sizePx) else {
                throw TimelineExportError.failedToAcquireOffscreenTexture
            }

            defer {
                texturePool.release(textureA)
                texturePool.release(textureB)
            }

            // Render scene A to offscreen (transparent background)
            let targetA = RenderTarget(
                texture: textureA,
                drawableScale: 1.0,
                animSize: context.sceneA.canvasSize
            )
            try renderer.draw(
                commands: context.sceneA.commands,
                target: targetA,
                clearColor: .transparentBlack,
                textureProvider: context.sceneA.textureProvider,
                commandBuffer: commandBuffer,
                assetSizes: context.sceneA.assetSizes,
                pathRegistry: context.sceneA.pathRegistry,
                backgroundState: nil  // No background for offscreen scenes
            )

            // Render scene B to offscreen (transparent background)
            let targetB = RenderTarget(
                texture: textureB,
                drawableScale: 1.0,
                animSize: context.sceneB.canvasSize
            )
            try renderer.draw(
                commands: context.sceneB.commands,
                target: targetB,
                clearColor: .transparentBlack,
                textureProvider: context.sceneB.textureProvider,
                commandBuffer: commandBuffer,
                assetSizes: context.sceneB.assetSizes,
                pathRegistry: context.sceneB.pathRegistry,
                backgroundState: nil
            )

            // Clear target with background
            let finalTarget = RenderTarget(
                texture: target,
                drawableScale: 1.0,
                animSize: canvasSize
            )

            // PR-G: Always prepare final target before compositor
            // Background pre-pass uses shared backgroundTextureProvider (not EmptyTextureProvider)
            if let bg = backgroundState {
                try renderer.draw(
                    commands: [],
                    target: finalTarget,
                    clearColor: clearColor,
                    textureProvider: backgroundTextureProvider,
                    commandBuffer: commandBuffer,
                    assetSizes: [:],
                    pathRegistry: PathRegistry(),
                    backgroundState: bg,
                    initialLoadAction: .clear
                )
            } else {
                // PR-G: Clear target even without background to avoid stale pixels
                try renderer.draw(
                    commands: [],
                    target: finalTarget,
                    clearColor: clearColor,
                    textureProvider: backgroundTextureProvider,
                    commandBuffer: commandBuffer,
                    assetSizes: [:],
                    pathRegistry: PathRegistry(),
                    backgroundState: nil,
                    initialLoadAction: .clear
                )
            }

            // Convert SceneTransition to TransitionParams for TVECore
            let params = convertToTransitionParams(context.transition)

            // Composite A and B with transition effect
            try transitionCompositor.composite(
                sceneA: textureA,
                sceneB: textureB,
                transition: params,
                progress: context.progress,
                canvasSize: canvasSize,
                target: target,
                commandBuffer: commandBuffer
            )
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Converts AnimiApp SceneTransition to TVECore TransitionParams.
    /// PR-F: Uses extension methods from SceneTransition for type conversion.
    private func convertToTransitionParams(_ transition: SceneTransition) -> TransitionParams {
        TransitionParams(
            type: transition.type.toTVECoreType(),
            easing: transition.easingPreset.toTVECoreType()
        )
    }
}

// MARK: - Timeline Export Errors

public enum TimelineExportError: Error, LocalizedError {
    case noTimeline
    case frameResolutionFailed(Int)
    case failedToAcquireOffscreenTexture

    public var errorDescription: String? {
        switch self {
        case .noTimeline:
            return "No timeline configured in composition engine"
        case .frameResolutionFailed(let frame):
            return "Failed to resolve frame \(frame)"
        case .failedToAcquireOffscreenTexture:
            return "Failed to acquire offscreen texture from pool"
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
