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

    /// Active trim window for playback clamping.
    private struct PlaybackWindow {
        let start: Double
        let end: Double
    }

    private var playbackWindow: PlaybackWindow?

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

    /// Whether playback mode is active (player.rate = 1 or hold-last)
    /// PR1.2: Made public for playback gating in UserMediaService
    public private(set) var isPlaybackActive: Bool = false

    /// Internal state machine for trim-end hold behavior.
    /// When expectedVideoTime reaches trimEnd, we pause the player and load an exact
    /// still frame via AVAssetImageGenerator (deterministic, no AVPlayerItemVideoOutput).
    /// `isPlaybackActive` stays `true` so UserMediaService keeps calling each tick.
    private enum PlaybackHoldState: Equatable {
        /// Normal playback (AVPlayer running at rate=1)
        case none
        /// Exact still frame requested via AVAssetImageGenerator, not yet delivered.
        /// Returns fallback texture while loading.
        case loadingExactFrame(CMTime)
        /// Exact hold frame locked — return holdPlaybackTexture, skip all AVPlayer I/O
        case holding(CMTime)
    }

    private var playbackHoldState: PlaybackHoldState = .none
    private var playbackHoldTask: Task<Void, Never>?
    private var holdPlaybackTexture: MTLTexture?

    #if DEBUG
    internal struct DebugPlaybackSnapshot {
        let playbackWindowStart: Double?
        let playbackWindowEnd: Double?
        let expectedVideoTimeSeconds: Double?
        let clampedExpectedTimeSeconds: Double?
        let itemTimeSeconds: Double?
        let clampedOutputTimeSeconds: Double?
        let hasNewPixelBuffer: Bool?
        let copySucceeded: Bool?
        let textureIdentifier: String?
        let holdState: String
        let playerRate: Float
        let hasHoldTexture: Bool
    }

    /// Debug seam: whether provider is in hold-loading state
    internal var debugIsPlaybackHoldLoading: Bool {
        if case .loadingExactFrame = playbackHoldState { return true }
        return false
    }
    /// Debug seam: whether provider has locked hold frame
    internal var debugIsPlaybackHolding: Bool {
        if case .holding = playbackHoldState { return true }
        return false
    }
    /// Debug seam: current AVPlayer rate
    internal var debugPlayerRate: Float { player.rate }
    /// Debug seam: count of AVPlayerItemVideoOutput.copyPixelBuffer calls
    internal private(set) var debugPlaybackOutputCopyCount: Int = 0
    /// Debug seam: count of exact still requests initiated for hold
    internal private(set) var debugHoldStillRequestCount: Int = 0
    /// Debug seam: whether hold texture has been loaded
    internal var debugHasHoldPlaybackTexture: Bool { holdPlaybackTexture != nil }
    internal private(set) var debugLastExpectedVideoTimeSeconds: Double?
    internal private(set) var debugLastClampedExpectedTimeSeconds: Double?
    internal private(set) var debugLastItemTimeSeconds: Double?
    internal private(set) var debugLastClampedOutputTimeSeconds: Double?
    internal private(set) var debugLastHasNewPixelBuffer: Bool?
    internal private(set) var debugLastCopySucceeded: Bool?
    internal private(set) var debugLastTextureIdentifier: String?

    internal var debugPlaybackSnapshot: DebugPlaybackSnapshot {
        DebugPlaybackSnapshot(
            playbackWindowStart: playbackWindow?.start,
            playbackWindowEnd: playbackWindow?.end,
            expectedVideoTimeSeconds: debugLastExpectedVideoTimeSeconds,
            clampedExpectedTimeSeconds: debugLastClampedExpectedTimeSeconds,
            itemTimeSeconds: debugLastItemTimeSeconds,
            clampedOutputTimeSeconds: debugLastClampedOutputTimeSeconds,
            hasNewPixelBuffer: debugLastHasNewPixelBuffer,
            copySucceeded: debugLastCopySucceeded,
            textureIdentifier: debugLastTextureIdentifier,
            holdState: debugPlaybackHoldStateDescription,
            playerRate: player.rate,
            hasHoldTexture: holdPlaybackTexture != nil
        )
    }

    private var debugPlaybackHoldStateDescription: String {
        switch playbackHoldState {
        case .none:
            return "none"
        case .loadingExactFrame(let time):
            return String(format: "loadingExactFrame(%.6f)", time.seconds)
        case .holding(let time):
            return String(format: "holding(%.6f)", time.seconds)
        }
    }

    private static var debugVideoPlaybackTraceEnabled: Bool {
        UserDefaults.standard.bool(forKey: "DebugVideoPlaybackTrace")
    }

    private static func debugTextureIdentifier(_ texture: MTLTexture?) -> String? {
        guard let texture else { return nil }
        return String(ObjectIdentifier(texture as AnyObject).hashValue)
    }

    private static func debugTrace(_ message: @autoclosure () -> String) {
        guard debugVideoPlaybackTraceEnabled else { return }
        print("[VideoPlaybackTrace] \(message())")
    }
    #endif

    // (Drift correction removed — always disabled; export pipeline uses deterministic path)

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

        #if DEBUG
        MemoryDiagnostics.increment("VideoFrameProvider")
        MemoryDiagnostics.event("VideoFrameProvider.init", "obj=\(ObjectIdentifier(self).hashValue)")
        #endif

        // Configure player (initially paused, muted)
        player.rate = 0
        player.isMuted = true
        // Required precondition for setRate(_:time:atHostTime:) — must not wait for buffering.
        player.automaticallyWaitsToMinimizeStalling = false

        // Start loading
        state = .loading
        loadDuration(from: asset)
    }

    // MARK: - Configuration

    /// Updates scene FPS for time mapping.
    public func setSceneFPS(_ fps: Double) {
        self.sceneFPS = fps
    }

    /// Sets the active trim window for playback clamping.
    public func setPlaybackWindow(start: Double, end: Double) {
        self.playbackWindow = PlaybackWindow(start: start, end: end)
        playbackHoldTask?.cancel()
        playbackHoldTask = nil
        holdPlaybackTexture = nil
        playbackHoldState = .none
        #if DEBUG
        Self.debugTrace("provider.setPlaybackWindow start=\(String(format: "%.6f", start)) end=\(String(format: "%.6f", end))")
        #endif
    }

    // MARK: - Playback Control

    /// Starts playback mode at the given video time.
    ///
    /// Seeks to the target time, then plays at rate=1.
    /// Frames are extracted via `frameTextureForPlayback()`.
    ///
    /// - Parameter videoTimeSeconds: Target video time in seconds (pre-computed by caller via shared mapper)
    public func startPlayback(atVideoTime videoTimeSeconds: Double, hostTime: CFTimeInterval? = nil) {
        guard isReady else { return }

        let targetTime = playbackTime(seconds: videoTimeSeconds)
        isPlaybackActive = true
        playbackHoldTask?.cancel()
        playbackHoldTask = nil
        holdPlaybackTexture = nil
        playbackHoldState = .none

        // If target is already at trim-end hold boundary, enter hold immediately
        if Self.shouldHoldPlayback(
            expectedSeconds: videoTimeSeconds,
            fileDuration: duration.seconds,
            windowEnd: playbackWindow?.end
        ) {
            #if DEBUG
            Self.debugTrace("provider.startPlayback immediateHold expected=\(String(format: "%.6f", videoTimeSeconds)) target=\(String(format: "%.6f", targetTime.seconds)) window=[\(String(format: "%.6f", playbackWindow?.start ?? -1)),\(String(format: "%.6f", playbackWindow?.end ?? -1))]")
            #endif
            _ = enterOrContinuePlaybackHold(at: targetTime)
            return
        }

        #if DEBUG
        Self.debugTrace("provider.startPlayback expected=\(String(format: "%.6f", videoTimeSeconds)) target=\(String(format: "%.6f", targetTime.seconds)) hostTime=\(hostTime.map { String(format: "%.6f", $0) } ?? "nil") window=[\(String(format: "%.6f", playbackWindow?.start ?? -1)),\(String(format: "%.6f", playbackWindow?.end ?? -1))]")
        #endif

        if let hostTime {
            // AVPlayer expects host-clock CMTime here, not raw media-time seconds.
            // Also never schedule at/behind "now" on device — AVPlayer can throw.
            let hostClockTime = Self.scheduledHostClockTime(forTransportHostTime: hostTime)
            player.setRate(1.0, time: targetTime, atHostTime: hostClockTime)
        } else {
            let hostClockTime = Self.scheduledHostClockTime(forTransportHostTime: CACurrentMediaTime())
            player.setRate(1.0, time: targetTime, atHostTime: hostClockTime)
        }
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
        playbackHoldTask?.cancel()
        playbackHoldTask = nil
        holdPlaybackTexture = nil
        playbackHoldState = .none
        #if DEBUG
        Self.debugTrace("provider.stopPlayback flush=\(flush)")
        #endif

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

    /// Returns texture for current playback position.
    ///
    /// Normal playback: AVPlayer runs at rate=1, frames extracted via AVPlayerItemVideoOutput
    /// using hostTime-based itemTime (no seek per frame).
    ///
    /// At trim-end boundary: `expectedVideoTime` is the authority. AVPlayer is paused,
    /// an exact still frame is loaded via AVAssetImageGenerator, and cached texture is
    /// returned on subsequent ticks (no AVPlayerItemVideoOutput reads).
    ///
    /// - Parameter videoTimeSeconds: Expected video time (authority at trim boundary)
    /// - Returns: Metal texture, or nil if not available
    public func frameTextureForPlayback(expectedVideoTime videoTimeSeconds: Double, hostTime: CFTimeInterval? = nil) -> MTLTexture? {
        guard isReady, isPlaybackActive else { return lastPlaybackTexture }

        let expectedTime = playbackTime(seconds: videoTimeSeconds)
        #if DEBUG
        debugLastExpectedVideoTimeSeconds = videoTimeSeconds
        debugLastClampedExpectedTimeSeconds = expectedTime.seconds
        debugLastItemTimeSeconds = nil
        debugLastClampedOutputTimeSeconds = nil
        debugLastHasNewPixelBuffer = nil
        debugLastCopySucceeded = nil
        debugLastTextureIdentifier = Self.debugTextureIdentifier(lastPlaybackTexture)
        #endif

        // Check if expected time is at or past trim-end hold boundary
        if Self.shouldHoldPlayback(
            expectedSeconds: videoTimeSeconds,
            fileDuration: duration.seconds,
            windowEnd: playbackWindow?.end
        ) {
            let texture = enterOrContinuePlaybackHold(at: expectedTime)
            #if DEBUG
            debugLastTextureIdentifier = Self.debugTextureIdentifier(texture)
            #endif
            return texture
        }

        // If we were in hold but expected time is back inside trim window, resume
        if playbackHoldState != .none {
            exitPlaybackHold(resumeAt: expectedTime, hostTime: hostTime)
        }

        // Host-time-based frame extraction — use shared transport host time when available
        let effectiveHostTime = hostTime ?? CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: effectiveHostTime)

        // Clamp to trim window
        let clampedTime = playbackTime(seconds: itemTime.seconds)
        #if DEBUG
        debugLastItemTimeSeconds = itemTime.seconds
        debugLastClampedOutputTimeSeconds = clampedTime.seconds
        #endif

        // Extract frame at clamped playback position
        return extractTexture(at: clampedTime)
    }

    /// Maps transport media-time seconds into a safe host-clock CMTime for AVPlayer scheduling.
    ///
    /// Transport currently carries Core Animation media time. Preserve the relative delta from
    /// "now", convert into host-clock CMTime, and enforce a small lead time so device playback
    /// never schedules exactly at or behind the current host clock.
    internal static func scheduledHostClockTime(
        forTransportHostTime transportHostTime: CFTimeInterval,
        nowMediaTime: CFTimeInterval = CACurrentMediaTime(),
        nowHostClockTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock()),
        minimumLeadTime: CFTimeInterval = 1.0 / 120.0
    ) -> CMTime {
        let effectiveMediaTime = max(transportHostTime, nowMediaTime + minimumLeadTime)
        let deltaSeconds = effectiveMediaTime - nowMediaTime
        let delta = CMTime(seconds: deltaSeconds, preferredTimescale: 1_000_000_000)
        return CMTimeAdd(nowHostClockTime, delta)
    }

    // MARK: - Still Frame Extraction (PR2: Exact Still Pipeline)

    /// Extracts exact frame via AVAssetImageGenerator. Token-protected, latest-wins safe.
    /// Writes to still cache (separate from playback cache).
    public func requestStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture {
        let token = generation
        try Task.checkCancellation()
        guard isReady else { throw PosterError.notReady }

        let targetTime = fileTime(seconds: videoTimeSeconds)

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

        let (cgImage, _) = try await Self.cancellableImage(generator: generator, at: targetTime)
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

        let targetTime = fileTime(seconds: videoTimeSeconds)

        // Cache hit check (epsilon comparison)
        if lastInteractiveStillVideoTime.isValid,
           abs(lastInteractiveStillVideoTime.seconds - targetTime.seconds) < Self.epsilon,
           let cached = lastInteractiveStillTexture {
            return cached
        }

        let generator = ensureInteractiveStillGenerator()
        let (cgImage, _) = try await Self.cancellableImage(generator: generator, at: targetTime)
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

    // MARK: - Cancellation-Safe Image Generation

    /// Wraps AVAssetImageGenerator.image(at:) with task cancellation support.
    /// On cancellation, calls cancelAllCGImageGeneration() so the generator
    /// doesn't hold a leaked continuation.
    private static func cancellableImage(
        generator: AVAssetImageGenerator,
        at time: CMTime
    ) async throws -> (CGImage, CMTime) {
        // Check cancellation before entering the generator call —
        // AVAssetImageGenerator.image(at:) can leak its internal continuation
        // if cancelAllCGImageGeneration() fires before generation starts.
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await generator.image(at: time)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
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

    /// Clamps to [0, duration - epsilon]. Used by still/poster/interactive paths.
    private func fileTime(seconds: Double) -> CMTime {
        CMTime(seconds: Self.clampedFileTime(seconds, fileDuration: duration.seconds),
               preferredTimescale: 600)
    }

    /// Clamps to active trim window, falling back to file bounds.
    /// Used exclusively by playback path (startPlayback, frameTextureForPlayback, drift correction).
    private func playbackTime(seconds: Double) -> CMTime {
        CMTime(seconds: Self.clampedPlaybackTime(
                   seconds,
                   fileDuration: duration.seconds,
                   windowStart: playbackWindow?.start,
                   windowEnd: playbackWindow?.end),
               preferredTimescale: 600)
    }

    /// Pure clamp to [0, fileDuration - epsilon].
    internal static func clampedFileTime(_ seconds: Double, fileDuration: Double) -> Double {
        let hi = max(0, fileDuration - epsilon)
        return min(max(seconds, 0), hi)
    }

    /// Pure clamp to [windowStart, min(windowEnd - epsilon, fileDuration - epsilon)].
    /// Falls back to file bounds when window is nil.
    internal static func clampedPlaybackTime(
        _ seconds: Double,
        fileDuration: Double,
        windowStart: Double?,
        windowEnd: Double?
    ) -> Double {
        let fileCeiling = max(0, fileDuration - epsilon)
        let lo: Double
        let hi: Double
        if let ws = windowStart, let we = windowEnd {
            lo = max(ws, 0)
            let rawHi = min(we - epsilon, fileCeiling)
            hi = max(lo, rawHi)  // guard: hi >= lo even for very short trim
        } else {
            lo = 0
            hi = fileCeiling
        }
        return min(max(seconds, lo), hi)
    }

    /// Returns the hold-end time for the playback window, or nil if no window.
    internal static func playbackHoldEndTime(
        fileDuration: Double,
        windowEnd: Double?
    ) -> Double? {
        guard let we = windowEnd else { return nil }
        let fileCeiling = max(0, fileDuration - epsilon)
        return min(we - epsilon, fileCeiling)
    }

    /// Returns true when expectedSeconds is at or past the trim-end hold boundary.
    internal static func shouldHoldPlayback(
        expectedSeconds: Double,
        fileDuration: Double,
        windowEnd: Double?
    ) -> Bool {
        guard let holdTime = playbackHoldEndTime(fileDuration: fileDuration, windowEnd: windowEnd) else {
            return false
        }
        return expectedSeconds >= holdTime
    }

    /// Attempts to copy a pixel buffer from video output and convert to texture.
    /// Returns nil if no buffer available (caller decides fallback).
    private func copyPlaybackTexture(at time: CMTime) -> MTLTexture? {
        #if DEBUG
        debugPlaybackOutputCopyCount += 1
        debugLastHasNewPixelBuffer = videoOutput.hasNewPixelBuffer(forItemTime: time)
        debugLastCopySucceeded = false
        #endif
        if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            let texture = textureFactory.makeTexture(from: pixelBuffer)
            lastPlaybackTexture = texture
            lastPlaybackExtractedVideoTime = time
            #if DEBUG
            debugLastCopySucceeded = true
            debugLastTextureIdentifier = Self.debugTextureIdentifier(texture)
            successExtractCount += 1
            logDiagnosticsIfNeeded()
            #endif
            return texture
        }
        return nil
    }

    /// Extracts texture from video output at given time, falls back to cached texture.
    private func extractTexture(at time: CMTime) -> MTLTexture? {
        if let texture = copyPlaybackTexture(at: time) {
            return texture
        }
        // Return cached texture as fallback
        #if DEBUG
        nilExtractCount += 1
        logDiagnosticsIfNeeded()
        #endif
        return lastPlaybackTexture
    }

    // MARK: - Playback Hold

    /// Enters or continues trim-end hold. No AVPlayerItemVideoOutput reads.
    /// Exact hold frame is loaded asynchronously via AVAssetImageGenerator.
    private func enterOrContinuePlaybackHold(at holdTime: CMTime) -> MTLTexture? {
        switch playbackHoldState {
        case .holding:
            return holdPlaybackTexture ?? lastPlaybackTexture

        case .loadingExactFrame(let time) where time == holdTime:
            return holdPlaybackTexture ?? lastPlaybackTexture

        case .none, .loadingExactFrame:
            beginExactHoldFrameLoad(at: holdTime)
            return holdPlaybackTexture ?? lastPlaybackTexture
        }
    }

    /// Starts async exact-frame load for hold. Pauses AVPlayer, fires one still request.
    private func beginExactHoldFrameLoad(at holdTime: CMTime) {
        player.rate = 0
        playbackHoldTask?.cancel()
        holdPlaybackTexture = lastPlaybackTexture  // fallback until exact frame arrives
        playbackHoldState = .loadingExactFrame(holdTime)

        #if DEBUG
        debugHoldStillRequestCount += 1
        #endif

        let token = generation
        playbackHoldTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let texture = try await self.requestStillTexture(atVideoTime: holdTime.seconds)
                guard self.generation == token, !Task.isCancelled else { return }
                self.holdPlaybackTexture = texture
                self.lastPlaybackTexture = texture
                self.lastPlaybackExtractedVideoTime = holdTime
                self.playbackHoldState = .holding(holdTime)
                #if DEBUG
                self.debugLastTextureIdentifier = Self.debugTextureIdentifier(texture)
                Self.debugTrace("provider.holdStill.loaded time=\(String(format: "%.6f", holdTime.seconds)) texture=\(self.debugLastTextureIdentifier ?? "nil")")
                #endif
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                // Settle into holding with fallback texture — don't retry every tick
                self.playbackHoldState = .holding(holdTime)
                #if DEBUG
                Self.debugTrace("provider.holdStill.failed time=\(String(format: "%.6f", holdTime.seconds)) error=\(error)")
                #endif
            }
        }
    }

    /// Exits hold state and restarts AVPlayer from the given time.
    private func exitPlaybackHold(resumeAt time: CMTime, hostTime: CFTimeInterval?) {
        playbackHoldTask?.cancel()
        playbackHoldTask = nil
        holdPlaybackTexture = nil
        playbackHoldState = .none
        if let hostTime {
            let hostClockTime = Self.scheduledHostClockTime(forTransportHostTime: hostTime)
            player.setRate(1.0, time: time, atHostTime: hostClockTime)
        } else {
            let hostClockTime = Self.scheduledHostClockTime(forTransportHostTime: CACurrentMediaTime())
            player.setRate(1.0, time: time, atHostTime: hostClockTime)
        }
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
        #if DEBUG
        MemoryDiagnostics.event("VideoFrameProvider.release", "obj=\(ObjectIdentifier(self).hashValue)")
        #endif
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
        playbackWindow = nil
        textureFactory.flushCache()
        state = .idle
    }

    deinit {
        release()
        #if DEBUG
        MemoryDiagnostics.decrement("VideoFrameProvider")
        MemoryDiagnostics.event("VideoFrameProvider.deinit", "obj=\(ObjectIdentifier(self).hashValue)")
        #endif
    }
}
