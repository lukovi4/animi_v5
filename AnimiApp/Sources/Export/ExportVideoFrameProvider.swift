import AVFoundation
import CoreVideo
import Metal
import TVECore

// MARK: - Export Video Frame Provider Error

/// Errors that can occur during video frame extraction (PR-E3).
public enum ExportVideoFrameProviderError: Error, Sendable {
    /// Failed to create AVAssetReader
    case failedToCreateReader(Error?)

    /// No video track found in asset
    case missingVideoTrack

    /// Cannot add output to reader
    case cannotAddOutput

    /// Failed to start reader
    case readerStartFailed(AVAssetReader.Status, Error?)

    /// Failed to get pixel buffer from sample
    case missingPixelBuffer

    /// Failed to create Metal texture from pixel buffer
    case failedToCreateMetalTexture(CVReturn)
}

extension ExportVideoFrameProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .failedToCreateReader(let error):
            return "Failed to create AVAssetReader: \(error?.localizedDescription ?? "unknown")"
        case .missingVideoTrack:
            return "No video track found in asset"
        case .cannotAddOutput:
            return "Cannot add output to AVAssetReader"
        case .readerStartFailed(let status, let error):
            return "Reader failed to start: status=\(status.rawValue), error=\(error?.localizedDescription ?? "unknown")"
        case .missingPixelBuffer:
            return "Failed to get pixel buffer from video sample"
        case .failedToCreateMetalTexture(let status):
            return "Failed to create Metal texture: CVReturn \(status)"
        }
    }
}

// MARK: - Export Video Frame Provider

/// Deterministic video frame provider for export using AVAssetReader (PR-E3).
///
/// Unlike `VideoFrameProvider` (preview), this provider:
/// - Uses AVAssetReader instead of AVPlayer (deterministic frame access)
/// - Converts CVPixelBuffer → MTLTexture via shared CVMetalTextureCache (GPU-only)
/// - Monotonic access: frames are read sequentially with hold-last behavior
///
/// Usage:
/// ```swift
/// let provider = ExportVideoFrameProvider(
///     device: device,
///     textureCache: cache,
///     config: .init(selection: selection, blockTiming: timing, sceneFPS: 30)
/// )
/// try provider.prepare()
/// let texture = provider.texture(forSceneFrameIndex: 42)
/// provider.finish()
/// ```
public final class ExportVideoFrameProvider {
    // MARK: - Types

    /// Configuration for video frame provider.
    public struct Config: Sendable {
        /// Video selection with trim/offset parameters
        public let selection: VideoSelection

        /// Block timing (for startFrame calculation)
        public let blockTiming: BlockTiming

        /// Scene FPS (for time conversion)
        public let sceneFPS: Double

        /// Hold mode for frames beyond window
        public enum HoldMode: Sendable {
            case lastFrame
        }

        /// Hold mode (v1: lastFrame only)
        public let holdMode: HoldMode

        public init(
            selection: VideoSelection,
            blockTiming: BlockTiming,
            sceneFPS: Double,
            holdMode: HoldMode = .lastFrame
        ) {
            self.selection = selection
            self.blockTiming = blockTiming
            self.sceneFPS = sceneFPS
            self.holdMode = holdMode
        }
    }

    // MARK: - Constants

    /// Epsilon for hold-last clamp (1 tick in timescale 600)
    private static let epsilon: Double = 1.0 / 600.0

    /// Timescale for CMTime operations
    private static let timescale: CMTimeScale = 600

    // MARK: - Properties

    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let config: Config

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    /// Last decoded texture (for hold-last behavior)
    private var lastTexture: MTLTexture?

    /// PTS of last decoded sample
    private var lastPTS: CMTime = .invalid

    /// Pending sample for lookahead (P0 fix: correct hold-last PTS logic)
    private var pending: (pts: CMTime, texture: MTLTexture)?

    /// Whether reader has been prepared
    private var isPrepared = false

    /// Whether reader has finished (no more samples)
    private var isFinished = false

    /// Provider error (set on decode failure, propagated to coordinator)
    private(set) var providerError: ExportVideoFrameProviderError?

    // MARK: - Initialization

    /// Creates a video frame provider for export.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture operations
    ///   - textureCache: Shared CVMetalTextureCache (from VideoExporter)
    ///   - config: Provider configuration
    public init(
        device: MTLDevice,
        textureCache: CVMetalTextureCache,
        config: Config
    ) {
        self.device = device
        self.textureCache = textureCache
        self.config = config
    }

    // MARK: - Lifecycle

    /// Prepares the provider for reading.
    ///
    /// Creates AVAssetReader and configures output.
    /// Must be called before `texture(forSceneFrameIndex:)`.
    public func prepare() throws {
        guard !isPrepared else { return }

        let asset = AVURLAsset(url: config.selection.url)

        // Get video track
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw ExportVideoFrameProviderError.missingVideoTrack
        }

        // Create reader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportVideoFrameProviderError.failedToCreateReader(error)
        }

        // Configure output for Metal compatibility
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        // Set time range to window (reduces decode work)
        let startTime = CMTime(seconds: config.selection.winStart, preferredTimescale: Self.timescale)
        let duration = CMTime(seconds: config.selection.winEnd - config.selection.winStart, preferredTimescale: Self.timescale)
        reader.timeRange = CMTimeRange(start: startTime, duration: duration)

        // P1 fix: Guard canAdd before adding
        guard reader.canAdd(output) else {
            throw ExportVideoFrameProviderError.cannotAddOutput
        }
        reader.add(output)

        // Start reading
        guard reader.startReading() else {
            throw ExportVideoFrameProviderError.readerStartFailed(reader.status, reader.error)
        }

        self.reader = reader
        self.output = output
        self.isPrepared = true

        // Decode first sample into pending buffer
        do {
            if let sample = try decodeNextSampleThrowing() {
                pending = sample
            }
        } catch {
            providerError = error as? ExportVideoFrameProviderError
            throw error
        }
    }

    /// Returns texture for the given scene frame index.
    ///
    /// P0 fix: Correct hold-last PTS logic using pending sample buffer.
    /// Returns the last frame with PTS <= targetTime (not >= targetTime).
    ///
    /// - Parameter sceneFrameIndex: Scene frame index
    /// - Returns: MTLTexture or nil if no texture available (check providerError for failures)
    public func texture(forSceneFrameIndex sceneFrameIndex: Int) -> MTLTexture? {
        // If we already have an error, return last texture (or nil)
        guard providerError == nil else { return lastTexture }
        guard isPrepared else { return nil }

        // Compute target video time using same formula as UserMediaService.computeSyntheticSceneFrame
        let targetTime = computeTargetVideoTime(sceneFrameIndex: sceneFrameIndex)

        // If we already have a texture and target is at or before lastPTS, return cached
        if lastTexture != nil, lastPTS.isValid, targetTime <= lastPTS {
            return lastTexture
        }

        // P0 fix: Lookahead with pending sample
        // Promote pending to last while pending.pts <= targetTime
        while let p = pending, p.pts <= targetTime {
            lastTexture = p.texture
            lastPTS = p.pts

            // Read next sample into pending
            do {
                pending = try decodeNextSampleThrowing()
            } catch {
                providerError = error as? ExportVideoFrameProviderError
                pending = nil
                isFinished = true
                // Return what we have (last valid texture)
                return lastTexture
            }

            // If no more samples, we're done
            if pending == nil {
                isFinished = true
                break
            }
        }

        // If pending.pts > targetTime, return lastTexture (correct hold-last)
        // If no lastTexture yet but pending exists and pending.pts > targetTime,
        // we need at least one frame, so promote pending
        if lastTexture == nil, let p = pending {
            lastTexture = p.texture
            lastPTS = p.pts
            do {
                pending = try decodeNextSampleThrowing()
            } catch {
                providerError = error as? ExportVideoFrameProviderError
                pending = nil
                isFinished = true
            }
        }

        return lastTexture
    }

    /// Finishes reading and releases resources.
    public func finish() {
        reader?.cancelReading()
        reader = nil
        output = nil
        lastTexture = nil
        lastPTS = .invalid
        pending = nil
        isPrepared = false
        isFinished = false
        providerError = nil
    }

    /// Cancels reading immediately.
    public func cancel() {
        finish()
    }

    // MARK: - Private

    /// Computes target video time from scene frame index.
    ///
    /// Formula (matches UserMediaService.computeSyntheticSceneFrame):
    /// 1. tBlock = max(0, (sceneFrameIndex - blockStartFrame) / sceneFPS)
    /// 2. tVideo = winStart + tBlock
    /// 3. tVideoClamped = clamp(tVideo, winStart, winEnd - epsilon)
    private func computeTargetVideoTime(sceneFrameIndex: Int) -> CMTime {
        let blockStartFrame = config.blockTiming.startFrame
        let framesIntoBlock = sceneFrameIndex - blockStartFrame
        let tBlock = max(0.0, Double(framesIntoBlock) / config.sceneFPS)

        let tVideo = config.selection.winStart + tBlock

        // Clamp to window (hold-last)
        let tVideoClamped = min(max(tVideo, config.selection.winStart), config.selection.winEnd - Self.epsilon)

        return CMTime(seconds: tVideoClamped, preferredTimescale: Self.timescale)
    }

    /// Decodes the next sample and returns (PTS, MTLTexture).
    ///
    /// P0 #2 fix: Throws on decode errors instead of returning nil silently.
    /// Returns nil only when reader has no more samples (expected end of stream).
    private func decodeNextSampleThrowing() throws -> (pts: CMTime, texture: MTLTexture)? {
        guard let output = output else { return nil }

        // No more samples = expected end of stream (not an error)
        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            return nil
        }

        // Get PTS
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Get pixel buffer - P0 #2: throw on failure
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ExportVideoFrameProviderError.missingPixelBuffer
        }

        // Convert to MTLTexture via CVMetalTextureCache
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvMetalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvMetalTexture
        )

        // P0 #2: throw on Metal texture creation failure
        guard status == kCVReturnSuccess,
              let cvMetalTexture,
              let texture = CVMetalTextureGetTexture(cvMetalTexture) else {
            throw ExportVideoFrameProviderError.failedToCreateMetalTexture(status)
        }

        return (pts, texture)
    }
}
