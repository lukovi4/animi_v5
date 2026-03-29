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

    /// Last extracted texture (for caching/reuse) — playback path only
    private var lastPlaybackTexture: MTLTexture?
    private var lastPlaybackExtractedVideoTime: CMTime = .invalid

    /// Still cache (AVAssetImageGenerator path) — separate from playback
    private var lastStillTexture: MTLTexture?
    private var lastStillVideoTime: CMTime = .invalid

    /// Interactive still cache (tolerant generator, reused across drag ticks)
    private var interactiveStillGenerator: AVAssetImageGenerator?
    private var lastInteractiveStillTexture: MTLTexture?
    private var lastInteractiveStillVideoTime: CMTime = .invalid
    private static let interactivePreviewToleranceSeconds: Double = 1.0 / 30.0

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

    // (Scrub state removed — PR2: exact still pipeline)

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
            lastPlaybackTexture = nil
            lastPlaybackExtractedVideoTime = .invalid
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
        guard isReady, isPlaybackActive else { return lastPlaybackTexture }

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

    // MARK: - Still Frame Extraction (PR2: Exact Still Pipeline)

    /// Extracts exact frame via AVAssetImageGenerator. Token-protected, latest-wins safe.
    /// Writes to still cache (separate from playback cache).
    public func requestStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
        let token = generation
        try Task.checkCancellation()
        guard isReady else { throw PosterError.notReady }

        let targetTime = videoTime(seconds: videoTimeSeconds)

        // Still cache hit — synchronous fast path (no await)
        if lastStillVideoTime.isValid,
           abs(lastStillVideoTime.seconds - targetTime.seconds) < Self.epsilon,
           let cached = lastStillTexture {
            return cached
        }

        let generator = AVAssetImageGenerator(asset: playerItem.asset)
        generator.appliesPreferredTrackTransform = false
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let (cgImage, _) = try await generator.image(at: targetTime)
        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()

        guard let texture = textureFactory.makeTexture(from: cgImage) else {
            throw PosterError.generationFailed("Texture conversion failed")
        }

        lastStillTexture = texture
        lastStillVideoTime = targetTime
        return texture
    }

    // MARK: - Interactive Still Frame (Tolerant, Reusable Generator)

    /// Lazily creates or returns the cached interactive still generator with frame-level tolerance.
    private func ensureInteractiveStillGenerator() -> AVAssetImageGenerator {
        if let existing = interactiveStillGenerator { return existing }
        let gen = AVAssetImageGenerator(asset: playerItem.asset)
        gen.appliesPreferredTrackTransform = false
        let tolerance = CMTime(seconds: Self.interactivePreviewToleranceSeconds, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        interactiveStillGenerator = gen
        return gen
    }

    /// Extracts a frame using the tolerant, reusable interactive generator.
    /// Suitable for rapid drag gestures where exact-frame precision is not required.
    public func requestInteractiveStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
        let token = generation
        try Task.checkCancellation()
        guard isReady else { throw PosterError.notReady }

        let targetTime = videoTime(seconds: videoTimeSeconds)

        // Cache hit check (epsilon comparison)
        if lastInteractiveStillVideoTime.isValid,
           abs(lastInteractiveStillVideoTime.seconds - targetTime.seconds) < Self.epsilon,
           let cached = lastInteractiveStillTexture {
            return cached
        }

        let generator = ensureInteractiveStillGenerator()
        let (cgImage, _) = try await generator.image(at: targetTime)
        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()

        guard let texture = textureFactory.makeTexture(from: cgImage) else {
            throw PosterError.generationFailed("Texture conversion failed")
        }

        lastInteractiveStillTexture = texture
        lastInteractiveStillVideoTime = targetTime
        return texture
    }

    /// Releases interactive still generator and cache.
    public func releaseInteractiveStillResources() {
        interactiveStillGenerator?.cancelAllCGImageGeneration()
        interactiveStillGenerator = nil
        lastInteractiveStillTexture = nil
        lastInteractiveStillVideoTime = .invalid
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
    /// PR2: Thin wrapper over requestStillTexture with loading-poll loop.
    /// Called once after setVideo to get the first frame before enabling binding layer.
    /// PR-async-race: Token-protected to throw CancellationError if provider released mid-operation.
    ///
    /// - Parameter seconds: Time in video to extract poster from (typically trimStart)
    /// - Returns: Metal texture of the poster frame
    /// - Throws: PosterError if generation fails, CancellationError if provider released
    public func requestPoster(at seconds: Double) async throws -> MTLTexture {
        let token = generation
        try Task.checkCancellation()

        // Poll for ready state (poster requested during initial setup)
        if state == .loading {
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                if state == .ready { break }
                if case .failed(let msg) = state { throw PosterError.generationFailed(msg) }
            }
        }

        guard state == .ready else { throw PosterError.notReady }
        guard token == generation else { throw CancellationError() }

        return try await requestStillTexture(atVideoTime: seconds)
    }

    // MARK: - Constants

    /// Epsilon for hold-last clamp (1 tick in timescale 600)
    private static let epsilon: Double = 1.0 / 600.0

    // MARK: - Private Helpers

    /// Converts video time in seconds to CMTime with hold-last clamp.
    ///
    /// PR1: No loop — clamps to [0, duration - epsilon] for hold-last behavior.
    ///
    /// - Parameter seconds: Video time in seconds (already computed with trim window by caller)
    /// - Returns: Clamped CMTime
    private func videoTime(seconds: Double) -> CMTime {
        let maxSeconds = max(0, duration.seconds - Self.epsilon)
        let clampedSeconds = min(max(seconds, 0), maxSeconds)
        return CMTime(seconds: clampedSeconds, preferredTimescale: 600)
    }

    /// Extracts texture from video output at given time (playback path only).
    private func extractTexture(at time: CMTime) -> MTLTexture? {
        // Try to get pixel buffer
        let itemTime = time

        // Check if new buffer available
        if videoOutput.hasNewPixelBuffer(forItemTime: itemTime) {
            if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                let texture = textureFactory.makeTexture(from: pixelBuffer)
                lastPlaybackTexture = texture
                lastPlaybackExtractedVideoTime = time
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
                lastPlaybackTexture = texture
                lastPlaybackExtractedVideoTime = time
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
        return lastPlaybackTexture
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
            let lastT = lastPlaybackExtractedVideoTime.isValid ? String(format: "%.3f", lastPlaybackExtractedVideoTime.seconds) : "nil"
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
        releaseInteractiveStillResources()
        playerItem.remove(videoOutput)
        player.replaceCurrentItem(with: nil)
        lastPlaybackTexture = nil
        lastPlaybackExtractedVideoTime = .invalid
        lastStillTexture = nil
        lastStillVideoTime = .invalid
        presentationInfo = nil
        textureFactory.flushCache()
        state = .idle
    }

    deinit {
        release()
    }
}
