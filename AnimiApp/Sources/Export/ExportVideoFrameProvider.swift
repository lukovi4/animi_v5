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

    /// Failed to allocate an export-owned texture for a decoded video frame
    case failedToCreateOwnedTexture

    /// Failed to copy a CoreVideo-backed decoded frame into export-owned Metal storage
    case failedToCopyTexture(Error?)
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
        case .failedToCreateOwnedTexture:
            return "Failed to allocate owned Metal texture for decoded video frame"
        case .failedToCopyTexture(let error):
            return "Failed to copy decoded video frame into owned Metal texture: \(error?.localizedDescription ?? "unknown")"
        }
    }
}

// MARK: - Video Resampling Policy

/// Controls how export handles temporal resampling when target time falls between decoded samples.
public enum VideoResamplingPolicy: Sendable, Equatable {
    /// Hold-last cadence — returns nearest decoded frame with PTS ≤ target.
    case nearest
    /// Temporal linear blend between bracketing samples (default for upsampling).
    case blend
}

// MARK: - Resampling Decision

/// Pure decision result from resampling logic — separates "what to do" from GPU execution.
enum ResamplingDecision: Equatable {
    /// Return the previous (last) texture as-is
    case usePrev
    /// Return the next (pending) texture as-is
    case useNext
    /// Blend prev and next with the given alpha factor
    case blend(alpha: Float)

    /// Computes the resampling decision given timing parameters.
    ///
    /// - Parameters:
    ///   - policy: The resampling policy (.nearest or .blend)
    ///   - targetSeconds: Target time in seconds
    ///   - lastPTSSeconds: PTS of the last (previous) decoded sample, or nil if invalid
    ///   - nextPTSSeconds: PTS of the next (pending) decoded sample, or nil if unavailable
    /// - Returns: The decision on which texture to use
    static func decide(
        policy: VideoResamplingPolicy,
        targetSeconds: Double,
        lastPTSSeconds: Double?,
        nextPTSSeconds: Double?
    ) -> ResamplingDecision {
        guard policy == .blend else { return .usePrev }
        guard let lastPTS = lastPTSSeconds else { return .usePrev }
        guard let nextPTS = nextPTSSeconds else { return .usePrev }

        let epsilon = 1.0 / 600.0

        if abs(targetSeconds - lastPTS) <= epsilon { return .usePrev }
        if abs(targetSeconds - nextPTS) <= epsilon { return .useNext }

        let span = nextPTS - lastPTS
        guard span > 0 else { return .usePrev }

        let alpha = Float(min(max((targetSeconds - lastPTS) / span, 0), 1))
        return .blend(alpha: alpha)
    }
}

// MARK: - Export Video Frame Provider

/// Deterministic video frame provider for export using AVAssetReader (PR-E3).
///
/// Unlike `VideoFrameProvider` (preview), this provider:
/// - Uses AVAssetReader instead of AVPlayer (deterministic frame access)
/// - Converts CVPixelBuffer → MTLTexture via shared CVMetalTextureCache (GPU-only)
/// - Monotonic access: frames are read sequentially with hold-last behavior
/// - Temporal blend for upsampling scenarios (PR 6)
///
/// Usage:
/// ```swift
/// let provider = ExportVideoFrameProvider(
///     device: device,
///     textureCache: cache,
///     commandQueue: queue,
///     config: .init(selection: selection)
/// )
/// try provider.prepare()
/// let texture = provider.texture(forTargetVideoTime: 1.5)
/// provider.finish()
/// ```
public final class ExportVideoFrameProvider {
    // MARK: - Types

    private struct DecodedFrame {
        let pts: CMTime
        let texture: MTLTexture
    }

    /// Configuration for video frame provider.
    public struct Config: Sendable {
        /// Video selection with trim/audio parameters
        public let selection: VideoSelection
        /// Resampling policy for inter-sample times
        public let resamplingPolicy: VideoResamplingPolicy

        public init(selection: VideoSelection, resamplingPolicy: VideoResamplingPolicy = .blend) {
            self.selection = selection
            self.resamplingPolicy = resamplingPolicy
        }
    }

    // MARK: - Constants

    // Epsilon lives in VideoTimelineTimeMapper (canonical owner: VideoWindowValidator)

    /// Timescale for CMTime operations
    private static let timescale: CMTimeScale = 600

    // MARK: - Properties

    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let commandQueue: MTLCommandQueue
    let config: Config

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    /// Last decoded texture (for hold-last behavior)
    private var lastTexture: MTLTexture?

    /// PTS of last decoded sample
    private var lastPTS: CMTime = .invalid

    /// Pending sample for lookahead (P0 fix: correct hold-last PTS logic)
    private var pending: DecodedFrame?

    /// Whether reader has been prepared
    private var isPrepared = false

    /// Whether reader has finished (no more samples)
    private var isFinished = false

    /// Provider error (set on decode failure, propagated to coordinator)
    private(set) var providerError: ExportVideoFrameProviderError?

    /// Video presentation metadata (orientation, size, UV transform).
    /// Computed once during prepare from track metadata.
    private(set) var presentationInfo: VideoPresentationInfo?

    /// Lazy GPU blender for temporal interpolation (PR 6)
    private var blender: VideoFrameBlender?

    // MARK: - PerfDiag Counters (DEBUG)

    #if DEBUG
    /// Number of times a new sample was advanced (promoted pending → last)
    private var advancedSampleCount: Int = 0
    /// Number of times cached lastTexture was returned without advancing
    private var reusedLastTextureCount: Int = 0
    /// Current streak of consecutive reused frames
    private var currentReusedStreak: Int = 0
    /// Maximum streak of consecutive reused frames
    private var maxReusedStreak: Int = 0
    /// Total texture() calls
    private var totalTextureCallCount: Int = 0
    /// Number of GPU-blended frames
    private var blendCount: Int = 0
    /// Number of exact sample hits (no blend needed)
    private var exactSampleCount: Int = 0
    /// Whether metadata has been logged
    private var didLogMetadata: Bool = false
    #endif

    // MARK: - Initialization

    /// Creates a video frame provider for export.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture operations
    ///   - textureCache: Shared CVMetalTextureCache (from VideoExporter)
    ///   - commandQueue: Metal command queue (for PR 6 blend pass)
    ///   - config: Provider configuration
    public init(
        device: MTLDevice,
        textureCache: CVMetalTextureCache,
        commandQueue: MTLCommandQueue,
        config: Config
    ) {
        self.device = device
        self.textureCache = textureCache
        self.commandQueue = commandQueue
        self.config = config
    }

    // MARK: - Lifecycle

    /// Prepares the provider for reading (idempotent).
    ///
    /// Creates AVAssetReader and configures output.
    /// Must be called before `texture(forTargetVideoTime:)`.
    /// Safe to call multiple times — no-op if already prepared.
    public func prepareIfNeeded() throws {
        guard !isPrepared else { return }
        try prepareInternal()
    }

    /// Prepares the provider for reading.
    ///
    /// Creates AVAssetReader and configures output.
    /// Must be called before `texture(forTargetVideoTime:)`.
    public func prepare() throws {
        guard !isPrepared else { return }
        try prepareInternal()
    }

    /// Suspends the provider — cancels reader, clears pending/lastTexture, keeps config.
    /// Can be resumed later via `resume()`.
    public func suspend() {
        reader?.cancelReading()
        reader = nil
        output = nil
        lastTexture = nil
        lastPTS = .invalid
        pending = nil
        blender?.releaseScratch()
        isPrepared = false
        isFinished = false
        // Keep config, blender PSO, and providerError intact
    }

    /// Resumes a suspended provider — re-creates reader from saved config.
    public func resume() throws {
        guard !isPrepared else { return }
        providerError = nil
        try prepareInternal()
    }

    /// Releases all decoded state (textures, pending samples) without fully finishing.
    /// Keeps config for potential re-prepare.
    public func releaseDecodedState() {
        lastTexture = nil
        pending = nil
        blender?.releaseScratch()
    }

    // MARK: - Internal Prepare

    private func prepareInternal() throws {

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

        // Compute presentation info from track metadata (once)
        self.presentationInfo = VideoPresentationInfo(
            rawTrackSize: track.naturalSize,
            preferredTransform: track.preferredTransform
        )

        #if DEBUG
        if !didLogMetadata {
            didLogMetadata = true
            let fileName = config.selection.url.lastPathComponent
            let fps = String(format: "%.2f", track.nominalFrameRate)
            let size = track.naturalSize
            let tx = track.preferredTransform
            let win = "[\(String(format: "%.3f", config.selection.winStart))–\(String(format: "%.3f", config.selection.winEnd))]"
            print("[ExportVideoFrameProvider] READY: \(fileName) | trackFPS=\(fps) | size=\(Int(size.width))x\(Int(size.height)) | transform=[\(tx.a),\(tx.b),\(tx.c),\(tx.d),\(tx.tx),\(tx.ty)] | window=\(win)")
        }
        #endif

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

    /// Returns texture for the given target video time.
    ///
    /// P0 fix: Correct hold-last PTS logic using pending sample buffer.
    /// Returns the last frame with PTS <= targetTime (not >= targetTime).
    ///
    /// - Parameter targetTimeSeconds: Target video time in seconds (from VideoTimelineTimeMapper)
    /// - Returns: MTLTexture or nil if no texture available (check providerError for failures)
    public func texture(forTargetVideoTime targetTimeSeconds: Double) -> MTLTexture? {
        // If we already have an error, return last texture (or nil)
        guard providerError == nil else { return lastTexture }
        guard isPrepared else { return nil }

        let targetTime = CMTime(seconds: targetTimeSeconds, preferredTimescale: Self.timescale)

        #if DEBUG
        totalTextureCallCount += 1
        let prevPTS = lastPTS
        #endif

        // If we already have a texture and target is at or before lastPTS, return cached
        if lastTexture != nil, lastPTS.isValid, targetTime <= lastPTS {
            #if DEBUG
            reusedLastTextureCount += 1
            currentReusedStreak += 1
            maxReusedStreak = max(maxReusedStreak, currentReusedStreak)
            logSamplingIfNeeded(targetTime: targetTime, advanced: false, prevPTS: prevPTS, blendInfo: nil)
            #endif
            return lastTexture
        }

        // P0 fix: Lookahead with pending sample
        // Promote pending to last while pending.pts <= targetTime
        #if DEBUG
        var advancedThisTick = false
        #endif
        while let p = pending, p.pts <= targetTime {
            lastTexture = p.texture
            lastPTS = p.pts
            #if DEBUG
            advancedSampleCount += 1
            advancedThisTick = true
            #endif

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
            #if DEBUG
            advancedSampleCount += 1
            advancedThisTick = true
            #endif
            do {
                pending = try decodeNextSampleThrowing()
            } catch {
                providerError = error as? ExportVideoFrameProviderError
                pending = nil
                isFinished = true
            }
        }

        #if DEBUG
        if advancedThisTick {
            currentReusedStreak = 0
        } else {
            reusedLastTextureCount += 1
            currentReusedStreak += 1
            maxReusedStreak = max(maxReusedStreak, currentReusedStreak)
        }
        #endif

        // MARK: Resampling decision (PR 6)

        let decision = ResamplingDecision.decide(
            policy: config.resamplingPolicy,
            targetSeconds: targetTime.seconds,
            lastPTSSeconds: lastPTS.isValid ? lastPTS.seconds : nil,
            nextPTSSeconds: pending?.pts.seconds
        )

        let result: MTLTexture?
        switch decision {
        case .usePrev:
            result = lastTexture
            #if DEBUG
            if lastPTS.isValid, pending != nil {
                exactSampleCount += 1
            }
            logSamplingIfNeeded(targetTime: targetTime, advanced: advancedThisTick, prevPTS: prevPTS, blendInfo: "EXACT_PREV")
            #endif

        case .useNext:
            result = pending?.texture ?? lastTexture
            #if DEBUG
            exactSampleCount += 1
            logSamplingIfNeeded(targetTime: targetTime, advanced: advancedThisTick, prevPTS: prevPTS, blendInfo: "EXACT_NEXT")
            #endif

        case .blend(let alpha):
            if let last = lastTexture, let next = pending?.texture {
                if blender == nil {
                    blender = try? VideoFrameBlender(device: device)
                }
                let blended = blender?.blend(
                    prev: last, next: next,
                    alpha: alpha, commandQueue: commandQueue
                )
                result = blended ?? last  // GPU failure fallback
                #if DEBUG
                if blended != nil { blendCount += 1 }
                logSamplingIfNeeded(targetTime: targetTime, advanced: advancedThisTick, prevPTS: prevPTS, blendInfo: "BLEND(\(String(format: "%.3f", alpha)))")
                #endif
            } else {
                result = lastTexture
                #if DEBUG
                logSamplingIfNeeded(targetTime: targetTime, advanced: advancedThisTick, prevPTS: prevPTS, blendInfo: nil)
                #endif
            }
        }

        return result
    }

    /// Finishes reading and releases resources.
    public func finish() {
        #if DEBUG
        logExportSummary()
        #endif

        reader?.cancelReading()
        reader = nil
        output = nil
        lastTexture = nil
        lastPTS = .invalid
        pending = nil
        presentationInfo = nil
        blender?.releaseScratch()
        blender = nil
        isPrepared = false
        isFinished = false
        providerError = nil
    }

    /// Cancels reading immediately.
    public func cancel() {
        finish()
    }

    // MARK: - PerfDiag (DEBUG)

    #if DEBUG
    /// Logs per-frame sampling info for first 60 frames, then every 10th frame
    private func logSamplingIfNeeded(targetTime: CMTime, advanced: Bool, prevPTS: CMTime, blendInfo: String?) {
        let n = totalTextureCallCount
        guard n <= 60 || n % 10 == 0 else { return }

        let tgt = String(format: "%.4f", targetTime.seconds)
        let last = lastPTS.isValid ? String(format: "%.4f", lastPTS.seconds) : "nil"
        let pend = pending.map { String(format: "%.4f", $0.pts.seconds) } ?? "nil"
        let prev = prevPTS.isValid ? String(format: "%.4f", prevPTS.seconds) : "nil"
        let adv = advanced ? "ADV" : "HOLD"
        let blend = blendInfo.map { " | \($0)" } ?? ""

        print("[ExportVideoFrameProvider] #\(n) target=\(tgt)s | lastPTS=\(last)s | pendingPTS=\(pend)s | prevPTS=\(prev)s | \(adv)\(blend)")
    }

    /// Logs export summary counters on finish
    private func logExportSummary() {
        let total = totalTextureCallCount
        guard total > 0 else { return }
        let advRate = Double(advancedSampleCount) / Double(total) * 100
        let reusedRate = Double(reusedLastTextureCount) / Double(total) * 100
        let fileName = config.selection.url.lastPathComponent

        print("[ExportVideoFrameProvider] SUMMARY: \(fileName) | total=\(total) | advanced=\(advancedSampleCount) (\(String(format: "%.1f", advRate))%) | reused=\(reusedLastTextureCount) (\(String(format: "%.1f", reusedRate))%) | blended=\(blendCount) | exact=\(exactSampleCount) | maxReusedStreak=\(maxReusedStreak)")
    }
    #endif

    // MARK: - Private

    /// Decodes the next sample and returns (PTS, MTLTexture).
    ///
    /// P0 #2 fix: Throws on decode errors instead of returning nil silently.
    /// Returns nil only when reader has no more samples (expected end of stream).
    private func decodeNextSampleThrowing() throws -> DecodedFrame? {
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

        // Convert to export-owned MTLTexture. Do not retain CoreVideo-backed
        // textures across frames: AVAssetReader owns and may recycle those buffers.
        let texture = try makeOwnedTexture(from: pixelBuffer)
        return DecodedFrame(pts: pts, texture: texture)
    }

    private func makeOwnedTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
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
              let sourceTexture = CVMetalTextureGetTexture(cvMetalTexture) else {
            throw ExportVideoFrameProviderError.failedToCreateMetalTexture(status)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private

        guard let ownedTexture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw ExportVideoFrameProviderError.failedToCreateOwnedTexture
        }

        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: ownedTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            throw ExportVideoFrameProviderError.failedToCopyTexture(commandBuffer.error)
        }

        return ownedTexture
    }
}
