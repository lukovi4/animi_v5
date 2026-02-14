import Foundation
import Metal
import AVFoundation
import CoreVideo
import UIKit

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
    #endif

    // MARK: - Scrub State

    /// Last scrub seek time (for throttling)
    private var lastScrubSeekTime: CFTimeInterval = 0

    /// Scrub throttle interval (~30Hz = 33ms)
    private let scrubThrottle: CFTimeInterval = 0.033

    /// Last scrubbed frame index (to avoid redundant seeks)
    private var lastScrubbedFrameIndex: Int = -1

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

    /// Starts playback mode synchronized to scene timeline.
    ///
    /// Video plays at rate=1, frames are extracted via `frameTextureForPlayback()`.
    /// Drift correction happens automatically when threshold exceeded.
    ///
    /// - Parameter sceneFrameIndex: Current scene frame to sync to
    public func startPlayback(atSceneFrame sceneFrameIndex: Int) {
        guard isReady else { return }

        let targetTime = videoTime(forSceneFrame: sceneFrameIndex)
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
    /// PR1: No loop — holds last frame when past duration.
    /// PR1.1: Uses hostTime-based itemTime for reliable frame extraction.
    ///
    /// - Parameter sceneFrameIndex: Current scene frame (for drift detection)
    /// - Returns: Metal texture, or nil if not available
    public func frameTextureForPlayback(sceneFrameIndex: Int) -> MTLTexture? {
        guard isReady, isPlaybackActive else { return lastTexture }

        // PR1.1: Drift correction disabled for preview stability
        // Disabled for preview stability; export pipeline will handle sync deterministically
        if isDriftCorrectionEnabled {
            checkAndCorrectDrift(sceneFrameIndex: sceneFrameIndex)
        }

        // PR1.1 FIX: Use hostTime-based itemTime for reliable frame extraction
        // (instead of player.currentTime() which often causes hasNewPixelBuffer to return false)
        let hostTime = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: hostTime)

        // Clamp to hold-last
        let clampedTime = videoTime(seconds: itemTime.seconds)

        // Extract frame at clamped playback position
        return extractTexture(at: clampedTime)
    }

    /// Checks for drift between scene timeline and video playback, corrects if needed.
    private func checkAndCorrectDrift(sceneFrameIndex: Int) {
        let now = CACurrentMediaTime()

        // Throttle corrective seeks
        guard now - lastCorrectiveSeekTime >= correctiveSeekThrottle else { return }

        let expectedTime = videoTime(forSceneFrame: sceneFrameIndex)
        let actualTime = player.currentTime()

        // Calculate drift in frames
        let expectedSeconds = expectedTime.seconds
        let actualSeconds = actualTime.seconds
        let driftFrames = abs(expectedSeconds - actualSeconds) * sceneFPS

        if driftFrames > driftThresholdFrames {
            // Corrective seek needed (should be rare — logged for debugging)
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
    /// - Parameter sceneFrameIndex: Target scene frame
    /// - Returns: Metal texture, or nil if not available
    public func frameTextureForScrub(sceneFrameIndex: Int) -> MTLTexture? {
        guard isReady else { return lastTexture }

        // Skip if same frame requested
        if sceneFrameIndex == lastScrubbedFrameIndex {
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

        let targetTime = videoTime(forSceneFrame: sceneFrameIndex)

        // Seek with small tolerance (faster than zero tolerance)
        let tolerance = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance)

        lastScrubSeekTime = now
        lastScrubbedFrameIndex = sceneFrameIndex

        // Try to extract frame (may not be immediately available after seek)
        return extractTexture(at: targetTime)
    }

    // MARK: - Frozen Frame (Edit Mode)

    /// Returns texture for a frozen frame (edit mode).
    ///
    /// In edit mode, scene is frozen at `editFrameIndex`. Video shows
    /// corresponding frame without playback.
    ///
    /// - Parameter sceneFrameIndex: Edit frame index
    /// - Returns: Metal texture, or nil if not available
    public func frameTextureForFrozen(sceneFrameIndex: Int) -> MTLTexture? {
        guard isReady else { return lastTexture }

        let targetTime = videoTime(forSceneFrame: sceneFrameIndex)

        // Check if we already have this frame cached
        if let cached = lastTexture,
           lastExtractedVideoTime.seconds == targetTime.seconds {
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
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        do {
            let (cgImage, _) = try await generator.image(at: targetTime)

            // PR-async-race: Check token after image generation await
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }

            let uiImage = UIImage(cgImage: cgImage)

            guard let texture = textureFactory.makeTexture(from: uiImage) else {
                throw PosterError.generationFailed("Failed to create texture from image")
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

    /// Legacy: Converts scene frame index to video time.
    /// PR1: Now uses hold-last clamp instead of loop.
    private func videoTime(forSceneFrame sceneFrameIndex: Int) -> CMTime {
        let sceneTimeSeconds = Double(sceneFrameIndex) / sceneFPS
        return videoTime(seconds: sceneTimeSeconds)
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
    /// Logs extraction diagnostics every 2 seconds (PR1.1)
    private func logDiagnosticsIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastDiagnosticLogTime >= diagnosticLogInterval else { return }

        let total = nilExtractCount + successExtractCount
        if total > 0 {
            let nilRate = Double(nilExtractCount) / Double(total) * 100
            print("[VideoFrameProvider] extractTexture: \(successExtractCount) OK, \(nilExtractCount) nil (\(String(format: "%.1f", nilRate))% nil rate)")
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
                await MainActor.run {
                    // PR-async-race: Ignore result if generation changed (provider released/reused)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.duration = loadedDuration
                    self.state = .ready
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
        textureFactory.flushCache()
        state = .idle
    }

    deinit {
        release()
    }
}
