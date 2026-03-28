import Foundation
import Metal
import AVFoundation
import CoreVideo
import UIKit
import TVECore

// MARK: - Video Provider State

/// State machine for video frame provider lifecycle.
public enum VideoProviderState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

// MARK: - Video Frame Provider

/// Provides Metal textures from video frames synchronized with scene timeline.
///
/// PR-33: Release-quality video pipeline with two modes:
/// - **Playback mode**: AVPlayer runs at rate=1, frames extracted via AVPlayerItemVideoOutput
///   without seek on every frame. Drift correction happens only when threshold exceeded.
/// - **Scrub mode**: Throttled seek (max 30Hz) for timeline scrubbing.
///
/// Key design decisions:
/// - No `player.seek()` on every displayLink tick
/// - State machine prevents race conditions on loading
/// - Each provider manages its own throttle state
public final class VideoFrameProvider {

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureFactory: UserMediaTextureFactory
    private let player: AVPlayer
    private let playerItem: AVPlayerItem
    private let videoOutput: AVPlayerItemVideoOutput

    /// Video duration for loop calculation
    public private(set) var duration: CMTime = .zero

    /// Video presentation metadata (orientation, size, UV transform).
    /// Computed during prepare phase, available after `.ready`.
    public private(set) var presentationInfo: VideoPresentationInfo?

    /// Current provider state
    public private(set) var state: VideoProviderState = .idle

    /// Derived ready flag
    public var isReady: Bool { state == .ready }

    /// Scene FPS for time mapping
    private var sceneFPS: Double = 30.0

    /// Last extracted texture (for caching/reuse)
    private var lastTexture: MTLTexture?
    private var lastExtractedVideoTime: CMTime = .invalid

    // MARK: - Playback State

    /// Whether playback mode is active (player.rate = 1)
    /// PR1.2: Made public for playback gating in UserMediaService
    public private(set) var isPlaybackActive: Bool = false

    /// Last corrective seek time (for throttling)
    private var lastCorrectiveSeekTime: CFTimeInterval = 0

    /// Corrective seek throttle interval (500ms)
    private let correctiveSeekThrottle: CFTimeInterval = 0.5

    /// Drift threshold in frames before corrective seek
    private let driftThresholdFrames: Double = 2.0

    /// PR1.1: Drift correction disabled for preview stability; export pipeline will handle sync deterministically
    private let isDriftCorrectionEnabled = false

    // MARK: - PR1.1 Diagnostics

    #if DEBUG
    /// Counter for nil texture extractions (diagnostic)
    private var nilExtractCount: Int = 0
    /// Counter for successful texture extractions (diagnostic)
    private var successExtractCount: Int = 0
    /// Last diagnostic log time
    private var lastDiagnosticLogTime: CFTimeInterval = 0
    /// Diagnostic log interval (2 seconds)
    private let diagnosticLogInterval: CFTimeInterval = 2.0
    /// Whether metadata has been logged for this provider
    private var didLogMetadata: Bool = false
    #endif

    // MARK: - Scrub State

    /// Last scrub seek time (for throttling)
    private var lastScrubSeekTime: CFTimeInterval = 0

    /// Scrub throttle interval (~30Hz = 33ms)
    private let scrubThrottle: CFTimeInterval = 0.033

    /// Last scrubbed video time (to avoid redundant seeks)
    private var lastScrubbedVideoTime: CMTime = .invalid

    // MARK: - Async Race Protection (PR-async-race)

    /// Generation token for async race protection.
    /// Incremented on release() to invalidate pending async operations.
    private var generation: UInt64 = 1

    /// Task loading video duration (for cancellation on release)
    private var durationTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a video frame provider for the given video URL.
    ///
    /// Provider starts in `.loading` state and transitions to `.ready` when
    /// duration is loaded, or `.failed` on error.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - commandQueue: Command queue for texture blit operations
    ///   - url: URL of the video file
    ///   - sceneFPS: Scene frames per second for time mapping
    public init(device: MTLDevice, commandQueue: MTLCommandQueue, url: URL, sceneFPS: Double = 30.0) {
        self.device = device
        self.commandQueue = commandQueue
        self.sceneFPS = sceneFPS
        self.textureFactory = UserMediaTextureFactory(device: device, commandQueue: commandQueue)

        // Configure video output for pixel buffer access
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)

        // Create player item and player
        let asset = AVURLAsset(url: url)
        self.playerItem = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: playerItem)

        // Add video output to player item
        playerItem.add(videoOutput)

        // Configure player (initially paused, muted)
        player.rate = 0
        player.isMuted = true

        // Start loading
        state = .loading
        loadDuration(from: asset)
    }

    // MARK: - Configuration

    /// Updates scene FPS for time mapping.
    public func setSceneFPS(_ fps: Double) {
        self.sceneFPS = fps
    }

    // MARK: - Playback Control

    /// Starts playback mode at the given video time.
    ///
    /// Seeks to the target time, then plays at rate=1.
    /// Frames are extracted via `frameTextureForPlayback()`.
    ///
    /// - Parameter videoTimeSeconds: Target video time in seconds (pre-computed by caller via shared mapper)
    public func startPlayback(atVideoTime videoTimeSeconds: Double) {
        guard isReady else { return }

        let targetTime = videoTime(seconds: videoTimeSeconds)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = 1.0
        isPlaybackActive = true
    }

    /// Stops playback mode.
    ///
    /// PR1.1: Includes optional cache reset to reduce memory footprint.
    /// PR1.2.1: Added `flush` parameter to differentiate gating stops vs pause stops.
    ///
    /// - Parameter flush: If `true`, clears texture cache (use for Pause). If `false`, keeps cache (use for gating).
    public func stopPlayback(flush: Bool = true) {
        player.rate = 0
        isPlaybackActive = false

        // PR1.2.1: Only flush on explicit request (Pause), not on gating
        if flush {
            lastTexture = nil
            lastExtractedVideoTime = .invalid
            lastScrubbedVideoTime = .invalid
            textureFactory.flushCache()

            #if DEBUG
            print("[VideoFrameProvider] stopPlayback: flushCache called")
            #endif
        }
    }

    /// Returns texture for current playback position (NO seek per frame).
    ///
    /// In playback mode, AVPlayer runs independently. We just extract the current
    /// frame from videoOutput. Drift correction happens only when threshold exceeded.
    ///
    /// PR4: Time-based API. `expectedVideoTime` is a hint for drift/debug, not a per-tick seek target.
    /// Uses hostTime-based itemTime for reliable frame extraction.
    ///
    /// - Parameter videoTimeSeconds: Expected video time (for drift detection, not per-tick seek)
    /// - Returns: Metal texture, or nil if not available
    public func frameTextureForPlayback(expectedVideoTime videoTimeSeconds: Double) -> MTLTexture? {
        guard isReady, isPlaybackActive else { return lastTexture }

        // Drift correction disabled for preview stability
        if isDriftCorrectionEnabled {
            checkAndCorrectDrift(expectedVideoTime: videoTimeSeconds)
        }

        // Host-time-based frame extraction (no seek per tick)
        let hostTime = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: hostTime)

        // Clamp to hold-last
        let clampedTime = videoTime(seconds: itemTime.seconds)

        // Extract frame at clamped playback position
        return extractTexture(at: clampedTime)
    }

    /// Checks for drift between expected and actual video playback, corrects if needed.
    private func checkAndCorrectDrift(expectedVideoTime videoTimeSeconds: Double) {
        let now = CACurrentMediaTime()

        // Throttle corrective seeks
        guard now - lastCorrectiveSeekTime >= correctiveSeekThrottle else { return }

        let expectedTime = videoTime(seconds: videoTimeSeconds)
        let actualTime = player.currentTime()

        // Calculate drift in frames
        let driftSeconds = abs(expectedTime.seconds - actualTime.seconds)
        let driftFrames = driftSeconds * sceneFPS

        if driftFrames > driftThresholdFrames {
            #if DEBUG
            print("[VideoFrameProvider] Drift correction: \(String(format: "%.1f", driftFrames)) frames, seeking to \(expectedTime.seconds)s")
            #endif
            player.seek(to: expectedTime, toleranceBefore: .zero, toleranceAfter: .zero)
            lastCorrectiveSeekTime = now
        }
    }

    // MARK: - Scrub Mode

    /// Returns texture for scrub position (throttled seek).
    ///
    /// Used when user drags timeline slider. Seeks are throttled to ~30Hz max
    /// to avoid overwhelming the decoder.
    ///
    /// PR4: Time-based API. Scrub cache uses epsilon comparison instead of frame index equality.
    ///
    /// - Parameter videoTimeSeconds: Target video time in seconds (pre-computed by caller via shared mapper)
    /// - Returns: Metal texture, or nil if not available
    public func frameTextureForScrub(atVideoTime videoTimeSeconds: Double) -> MTLTexture? {
        guard isReady else { return lastTexture }

        let targetTime = videoTime(seconds: videoTimeSeconds)

        // Skip if same time requested (epsilon comparison)
        if lastScrubbedVideoTime.isValid,
           abs(lastScrubbedVideoTime.seconds - targetTime.seconds) < Self.epsilon {
            return lastTexture
        }

        let now = CACurrentMediaTime()

        // Throttle scrub seeks
        guard now - lastScrubSeekTime >= scrubThrottle else {
            return lastTexture
        }

        // Stop playback if active
        if isPlaybackActive {
            stopPlayback()
        }

        // Seek with small tolerance (faster than zero tolerance)
        let tolerance = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance)

        lastScrubSeekTime = now
        lastScrubbedVideoTime = targetTime

        // Try to extract frame (may not be immediately available after seek)
        return extractTexture(at: targetTime)
    }

    // MARK: - Frozen Frame (Edit Mode)

    /// Returns texture for a frozen frame (edit mode).
    ///
    /// In edit mode, scene is frozen at a specific time. Video shows
    /// corresponding frame without playback.
    ///
    /// PR4: Time-based API. Uses epsilon comparison for cache hit.
    ///
    /// - Parameter videoTimeSeconds: Target video time in seconds (pre-computed by caller via shared mapper)
    /// - Returns: Metal texture, or nil if not available
    public func frameTextureForFrozen(atVideoTime videoTimeSeconds: Double) -> MTLTexture? {
        guard isReady else { return lastTexture }

        let targetTime = videoTime(seconds: videoTimeSeconds)

        // Check if we already have this frame cached (epsilon comparison)
        if let cached = lastTexture,
           abs(lastExtractedVideoTime.seconds - targetTime.seconds) < Self.epsilon {
            return cached
        }

        // Stop playback if active
        if isPlaybackActive {
            stopPlayback()
        }

        // Seek to target frame
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)

        return extractTexture(at: targetTime)
    }

    // MARK: - Video Time API (PR1)

    /// Returns texture for a specific video time in seconds.
    ///
    /// PR1: Used by UserMediaService with pre-computed tVideo (including trim/offset).
    /// Applies hold-last clamp internally.
    ///
    /// - Parameter videoTimeSeconds: Target time in video (already includes winStart + tBlock)
    /// - Returns: Metal texture, or nil if not available
    public func frameTexture(atVideoTime videoTimeSeconds: Double) -> MTLTexture? {
        guard isReady else { return lastTexture }

        let targetTime = videoTime(seconds: videoTimeSeconds)

        // Check if we already have this frame cached
        if let cached = lastTexture,
           abs(lastExtractedVideoTime.seconds - targetTime.seconds) < Self.epsilon {
            return cached
        }

        // Stop playback if active (we're in scrub/frozen mode)
        if isPlaybackActive {
            stopPlayback()
        }

        // Seek to target frame
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)

        return extractTexture(at: targetTime)
    }

    // MARK: - Poster Generation (PR1)

    /// Poster generation error
    public enum PosterError: Error, LocalizedError {
        case notReady
        case generationFailed(String)
        case invalidDuration

        public var errorDescription: String? {
            switch self {
            case .notReady:
                return "Video provider not ready"
            case .generationFailed(let reason):
                return "Poster generation failed: \(reason)"
            case .invalidDuration:
                return "Video duration is invalid (too short)"
            }
        }
    }

    /// Generates a poster (still frame) at the specified video time.
    ///
    /// PR1: Uses AVAssetImageGenerator for reliable frame extraction.
    /// Called once after setVideo to get the first frame before enabling binding layer.
    /// PR-async-race: Token-protected to throw CancellationError if provider released mid-operation.
    ///
    /// - Parameter seconds: Time in video to extract poster from (typically winStart)
    /// - Returns: Metal texture of the poster frame
    /// - Throws: PosterError if generation fails, CancellationError if provider released
    public func requestPoster(at seconds: Double) async throws -> MTLTexture {
        // PR-async-race: Capture token at start
        let token = generation
        try Task.checkCancellation()

        // Wait for ready state if still loading
        if state == .loading {
            // Poll for ready state (max 5 seconds)
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                // PR-async-race: Check token after each await
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                if state == .ready { break }
                if case .failed(let error) = state {
                    throw PosterError.generationFailed(error)
                }
            }
        }

        // PR-async-race: Verify still valid before proceeding
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }

        guard isReady else {
            throw PosterError.notReady
        }

        // Validate duration
        guard duration.seconds > Self.epsilon else {
            throw PosterError.invalidDuration
        }

        // Clamp requested time
        let clampedSeconds = min(max(seconds, 0), duration.seconds - Self.epsilon)
        let targetTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)

        // Use AVAssetImageGenerator for reliable poster extraction
        let asset = playerItem.asset
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false  // Raw pixels — orientation via GPU
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        do {
            let (cgImage, _) = try await generator.image(at: targetTime)

            // PR-async-race: Check token after image generation await
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }

            guard let texture = textureFactory.makeTexture(from: cgImage) else {
                throw PosterError.generationFailed("Failed to create texture from CGImage")
            }

            // Cache the poster as last texture
            lastTexture = texture
            lastExtractedVideoTime = targetTime

            return texture
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PosterError.generationFailed(error.localizedDescription)
        }
    }

    // MARK: - Constants

    /// Epsilon for hold-last clamp (1 tick in timescale 600)
    private static let epsilon: Double = 1.0 / 600.0

    // MARK: - Private Helpers

    /// Converts video time in seconds to CMTime with hold-last clamp.
    ///
    /// PR1: No loop — clamps to [0, duration - epsilon] for hold-last behavior.
    ///
    /// - Parameter seconds: Video time in seconds (already computed with trim/offset by caller)
    /// - Returns: Clamped CMTime
    private func videoTime(seconds: Double) -> CMTime {
        let maxSeconds = max(0, duration.seconds - Self.epsilon)
        let clampedSeconds = min(max(seconds, 0), maxSeconds)
        return CMTime(seconds: clampedSeconds, preferredTimescale: 600)
    }

    /// Extracts texture from video output at given time.
    private func extractTexture(at time: CMTime) -> MTLTexture? {
        // Try to get pixel buffer
        let itemTime = time

        // Check if new buffer available
        if videoOutput.hasNewPixelBuffer(forItemTime: itemTime) {
            if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                let texture = textureFactory.makeTexture(from: pixelBuffer)
                lastTexture = texture
                lastExtractedVideoTime = time
                #if DEBUG
                successExtractCount += 1
                logDiagnosticsIfNeeded()
                #endif
                return texture
            }
        } else {
            // Try copyPixelBuffer anyway (may work for nearby times)
            if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                let texture = textureFactory.makeTexture(from: pixelBuffer)
                lastTexture = texture
                lastExtractedVideoTime = time
                #if DEBUG
                successExtractCount += 1
                logDiagnosticsIfNeeded()
                #endif
                return texture
            }
        }

        // Return cached texture as fallback
        #if DEBUG
        nilExtractCount += 1
        logDiagnosticsIfNeeded()
        #endif
        return lastTexture
    }

    #if DEBUG
    /// PerfDiag: Logs source metadata once per provider lifecycle
    private func logMetadataOnce(
        url: URL,
        duration: CMTime,
        trackMeta: (fps: Float, size: CGSize, transform: CGAffineTransform)?
    ) {
        guard !didLogMetadata else { return }
        didLogMetadata = true

        let fileName = url.lastPathComponent
        let dur = String(format: "%.2f", duration.seconds)
        let fps = trackMeta.map { String(format: "%.2f", $0.fps) } ?? "?"
        let size = trackMeta.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "?"
        let tx = trackMeta.map { t in
            let a = t.transform
            return "[\(a.a),\(a.b),\(a.c),\(a.d),\(a.tx),\(a.ty)]"
        } ?? "?"

        print("[VideoFrameProvider] READY: \(fileName) | dur=\(dur)s | sceneFPS=\(sceneFPS) | trackFPS=\(fps) | size=\(size) | transform=\(tx)")
    }

    /// Logs extraction diagnostics every 2 seconds (PR1.1)
    /// PerfDiag: Extended with itemTime and playback state
    private func logDiagnosticsIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastDiagnosticLogTime >= diagnosticLogInterval else { return }

        let total = nilExtractCount + successExtractCount
        if total > 0 {
            let nilRate = Double(nilExtractCount) / Double(total) * 100
            let itemTime = videoOutput.itemTime(forHostTime: now)
            let lastT = lastExtractedVideoTime.isValid ? String(format: "%.3f", lastExtractedVideoTime.seconds) : "nil"
            print("[VideoFrameProvider] playback: \(successExtractCount) OK, \(nilExtractCount) nil (\(String(format: "%.1f", nilRate))%) | itemTime=\(String(format: "%.3f", itemTime.seconds))s | lastExtracted=\(lastT)s | active=\(isPlaybackActive)")
        }

        // Reset counters
        nilExtractCount = 0
        successExtractCount = 0
        lastDiagnosticLogTime = now
    }
    #endif

    /// Loads video duration asynchronously.
    /// PR-async-race: Token-protected to prevent stale updates after release().
    private func loadDuration(from asset: AVURLAsset) {
        let token = generation
        durationTask = Task {
            do {
                let loadedDuration = try await asset.load(.duration)

                // Load video track for presentation info (always, not just DEBUG)
                let tracks = asset.tracks(withMediaType: .video)
                let firstTrack = tracks.first

                let videoPresInfo: VideoPresentationInfo? = firstTrack.map {
                    VideoPresentationInfo(
                        rawTrackSize: $0.naturalSize,
                        preferredTransform: $0.preferredTransform
                    )
                }

                #if DEBUG
                let trackMeta: (fps: Float, size: CGSize, transform: CGAffineTransform)? = firstTrack.map {
                    ($0.nominalFrameRate, $0.naturalSize, $0.preferredTransform)
                }
                #endif

                await MainActor.run {
                    // PR-async-race: Ignore result if generation changed (provider released/reused)
                    guard self.generation == token, !Task.isCancelled else { return }

                    guard let videoPresInfo else {
                        self.state = .failed("No video track found — cannot compute VideoPresentationInfo")
                        return
                    }

                    self.duration = loadedDuration
                    self.presentationInfo = videoPresInfo
                    self.state = .ready

                    #if DEBUG
                    self.logMetadataOnce(
                        url: asset.url,
                        duration: loadedDuration,
                        trackMeta: trackMeta
                    )
                    #endif
                }
            } catch {
                await MainActor.run {
                    // PR-async-race: Ignore error if generation changed
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Cleanup

    /// Releases video resources.
    /// PR-async-race: Increments generation and cancels pending tasks to prevent stale updates.
    public func release() {
        // PR-async-race: Invalidate all pending async operations
        generation += 1
        durationTask?.cancel()
        durationTask = nil

        stopPlayback()
        playerItem.remove(videoOutput)
        player.replaceCurrentItem(with: nil)
        lastTexture = nil
        presentationInfo = nil
        textureFactory.flushCache()
        state = .idle
    }

    deinit {
        release()
    }
}
