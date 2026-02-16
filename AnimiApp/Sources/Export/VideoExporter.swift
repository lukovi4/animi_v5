import AVFoundation
import CoreVideo
import Metal
import TVECore

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

    public init(
        outputURL: URL,
        sizePx: (width: Int, height: Int),
        fps: Int,
        bitrate: Int = 10_000_000,
        gopSeconds: Int = 2,
        clearColor: ClearColor = .opaqueBlack,
        backpressureTimeoutSeconds: Double = 3.0
    ) {
        self.outputURL = outputURL
        self.sizePx = sizePx
        self.fps = fps
        self.bitrate = bitrate
        self.gopSeconds = gopSeconds
        self.clearColor = clearColor
        self.backpressureTimeoutSeconds = backpressureTimeoutSeconds
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

        // 4. Start writing
        guard writer.startWriting() else {
            DispatchQueue.main.async {
                completion(.failure(VideoExportError.writerStartFailed(writer.error)))
            }
            return
        }
        writer.startSession(atSourceTime: .zero)

        // 5. Create CVMetalTextureCache using commandQueue.device
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

        // 6. PR-E3: Setup video slots coordinator
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
        let group = DispatchGroup()

        // 9. Export loop
        let totalFrames = runtime.durationFrames
        let canvasSize = runtime.canvasSize
        let backpressureTimeout = settings.backpressureTimeoutSeconds

        for frameIndex in 0..<totalFrames {
            // Check cancellation
            if isCancelled() { break }

            // Check for errors from other frames
            if exportError() != nil { break }

            // Wait for in-flight slot (GPU backpressure)
            semaphore.wait()
            group.enter()

            autoreleasepool {
                // Get pixel buffer from pool
                guard let pool = adaptor.pixelBufferPool else {
                    setExportErrorOnce(VideoExportError.noPixelBufferPool)
                    group.leave()
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
                    group.leave()
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
                    group.leave()
                    semaphore.signal()
                    return
                }

                // PR-E3: Update video textures before render
                videoSlotsCoordinator?.updateTextures(forSceneFrameIndex: frameIndex)

                // P0 #2: Check for video slot provider errors
                if let error = videoSlotsCoordinator?.providerError {
                    setExportErrorOnce(error)
                    group.leave()
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
                    group.leave()
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
                        pathRegistry: pathRegistry
                    )
                } catch {
                    setExportErrorOnce(VideoExportError.renderError(error))
                    group.leave()
                    semaphore.signal()
                    return
                }

                // Add completion handler - append on writerQueue after GPU completion
                commandBuffer.addCompletedHandler { [weak self] _ in
                    guard let self else {
                        group.leave()
                        semaphore.signal()
                        return
                    }

                    self.writerQueue.async {
                        defer {
                            group.leave()
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

        // 10. Wait for all frames to complete (appends done)
        group.wait()

        // 11. Finalization on writerQueue
        writerQueue.async { [weak self] in
            guard let self else {
                videoSlotsCoordinator?.cancel()
                DispatchQueue.main.async {
                    completion(.failure(VideoExportError.cancelled))
                }
                return
            }

            // Check cancellation
            if self.isCancelled() {
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

            // Finalize writer
            videoInput.markAsFinished()
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
}
