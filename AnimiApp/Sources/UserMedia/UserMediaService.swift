import Metal
import AVFoundation
import TVECore
import ImageIO

// MARK: - Video Setup Provider Protocol (P0 Testing Seam)

/// Protocol for video frame provider.
/// Internal seam for dependency injection in tests.
protocol VideoSetupProviding: AnyObject {
    // Setup phase
    func requestPoster(at time: Double) async throws -> MTLTexture
    var duration: CMTime { get }
    func release()

    // State
    var isReady: Bool { get }
    var state: VideoProviderState { get }
    var isPlaybackActive: Bool { get }

    // Presentation metadata (orientation, size, UV transform)
    var presentationInfo: VideoPresentationInfo? { get }

    // Playback (time-based — PR 4)
    func startPlayback(atVideoTime videoTimeSeconds: Double)
    func stopPlayback(flush: Bool)
    func frameTextureForPlayback(expectedVideoTime videoTimeSeconds: Double) -> MTLTexture?
    func requestStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture

    // Interactive trim preview (tolerant, reusable generator)
    func requestInteractiveStillTexture(atVideoTime videoTimeSeconds: Double) async throws -> MTLTexture
    func releaseInteractiveStillResources()
}

/// Conform VideoFrameProvider to protocol.
extension VideoFrameProvider: VideoSetupProviding {}

/// Factory type for creating video setup providers.
typealias VideoSetupProviderFactory = (MTLDevice, MTLCommandQueue, URL, Double) -> VideoSetupProviding

// MARK: - Scene Player Protocol (P0 Testing Seam)

/// Protocol for scene player interactions used by UserMediaService.
/// Internal seam for dependency injection in tests.
@MainActor
protocol ScenePlayerForMedia: AnyObject {
    func bindingAssetIdsByVariant(blockId: String) -> [String: String]
    func setUserMediaPresent(blockId: String, present: Bool)
    func blockTiming(for blockId: String) -> BlockTiming?
    func blockPriorityInfo(blockId: String, at sceneFrameIndex: Int) -> BlockPriorityInfo?
}

/// Conform ScenePlayer to protocol.
extension ScenePlayer: ScenePlayerForMedia {}

// MARK: - Async Semaphore (P1: Poster Throttling)

/// Simple async semaphore for limiting concurrent operations.
/// P1: Used to throttle poster generation to avoid memory spikes.
private actor AsyncSemaphore {
    private let limit: Int
    private var current: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if current < limit {
            current += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            current = max(0, current - 1)
        }
    }
}

// MARK: - Video Selection (PR1)

/// Represents a user's video selection with trim parameters.
///
/// trimStart and trimEnd define the playback window directly.
/// winStart/winEnd are kept as aliases for downstream compatibility.
///
/// Audio parameters are stored but not applied in PR1 (preview is always muted).
public struct VideoSelection: Equatable, Sendable {
    /// Persisted video file URL (owned by MediaAssetStore, not by UserMediaService)
    public let url: URL

    /// Trim start time in seconds (relative to video start)
    public var trimStart: Double

    /// Trim end time in seconds (relative to video start)
    public var trimEnd: Double

    /// Whether audio is muted (stored for PR3 export, not applied in PR1)
    public var isMuted: Bool

    /// Audio volume 0...1 (stored for PR3 export, not applied in PR1)
    public var volume: Float

    // MARK: - Computed Properties

    /// Effective window start in video time
    public var winStart: Double { trimStart }

    /// Effective window end in video time
    public var winEnd: Double { trimEnd }

    /// Whether the selection is valid (window has positive duration)
    public var isValid: Bool { winEnd > winStart }

    // MARK: - Initialization

    /// Creates a video selection with default parameters.
    ///
    /// - Parameters:
    ///   - url: Video file URL
    ///   - duration: Video duration in seconds (used for default trimEnd)
    public init(url: URL, duration: Double) {
        self.url = url
        self.trimStart = 0
        self.trimEnd = duration
        self.isMuted = false
        self.volume = 1.0
    }

    /// Creates a video selection with explicit parameters.
    public init(
        url: URL,
        trimStart: Double,
        trimEnd: Double,
        isMuted: Bool = false,
        volume: Float = 1.0
    ) {
        self.url = url
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.isMuted = isMuted
        self.volume = volume
    }
}

// MARK: - Video Trim Context

/// Preflight context for video trim.
/// Contains the current persisted selection, actual file duration, and video URL for UI.
public struct VideoTrimContext: Sendable {
    public let currentSelection: PersistedVideoSelection
    public let actualDuration: Double
    public let videoURL: URL
}

// MARK: - Video Selection Apply Error

/// Errors from validated video selection apply.
enum VideoSelectionApplyError: Error, LocalizedError {
    case blockNotVideo(blockId: String)
    case providerNotReady(blockId: String)
    case validationFailed(underlying: VideoWindowValidationError)

    var errorDescription: String? {
        switch self {
        case .blockNotVideo(let blockId):
            return "Block '\(blockId)' is not a video block"
        case .providerNotReady(let blockId):
            return "Video provider not ready for block '\(blockId)'"
        case .validationFailed(let underlying):
            return underlying.localizedDescription
        }
    }
}

// MARK: - User Media Kind

/// Represents the type of user media for a block.
///
/// PR-33: Lightweight marker without storing full UIImage (memory optimization).
/// PR1: Video now stores VideoSelection instead of just URL.
public enum UserMediaKind: Equatable {
    case photo
    case video(VideoSelection)
    case none
}

// MARK: - Video Budget Policy (PR-F)

/// Configuration for video playback budget control.
///
/// PR-F: Limits the number of active video providers and controls update frequency
/// to ensure stable, predictable preview performance with multiple heavy videos.
public struct VideoBudgetPolicy {
    /// Maximum number of video providers that can be actively decoding simultaneously.
    /// Videos beyond this limit will hold their last frame.
    /// Default: 3
    public var maxActiveProviders: Int

    /// Frame update divider — video textures are updated every N-th displayLink tick.
    /// - `1` = update every tick (default; matches displayLink cadence driven by sceneFPS)
    /// - `2+` = explicit budget degradation, skips intermediate ticks
    /// Default: 1
    public var updateDivider: Int

    /// Behavior when a video provider becomes inactive (exceeds budget).
    public var holdMode: HoldMode

    /// Hold mode for inactive video providers.
    public enum HoldMode {
        /// Keep the last decoded frame visible (default, no flicker)
        case lastFrame
        /// Show the poster frame (requires poster extraction on deactivate)
        case poster
    }

    /// Creates a budget policy with default values.
    public init(
        maxActiveProviders: Int = 3,
        updateDivider: Int = 1,
        holdMode: HoldMode = .lastFrame
    ) {
        self.maxActiveProviders = maxActiveProviders
        self.updateDivider = updateDivider
        self.holdMode = holdMode
    }
}

// MARK: - Playback Video Candidate (TT-03)

/// Represents a ready video candidate for budget allocation.
/// Used by engine to collect candidates across scenes for global priority ordering.
struct PlaybackVideoCandidate: Sendable {
    let blockId: String
    let priority: BlockPriorityInfo
}

// MARK: - User Media Service

/// Coordinates user media (photo/video) injection into template binding layers.
///
/// This service manages the complete pipeline:
/// 1. Receives user media (photo or video) for a block
/// 2. Creates Metal textures via `UserMediaTextureFactory` or `VideoFrameProvider`
/// 3. Injects textures into ALL variant binding asset IDs (for seamless variant switching)
/// 4. Updates `ScenePlayer.userMediaPresent` state
///
/// Model A contract: All mutable state access happens on main thread during playback/render.
///
/// Usage:
/// ```swift
/// let service = UserMediaService(device: device, commandQueue: queue, scenePlayer: player, textureProvider: provider)
/// service.setPhoto(blockId: "block_01", fileURL: photoFileURL)
/// // Later...
/// service.clear(blockId: "block_01")
/// ```
@MainActor
public final class UserMediaService {

    // MARK: - Constants

    // Epsilon lives in VideoTimelineTimeMapper (canonical owner: VideoWindowValidator)

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private weak var scenePlayer: ScenePlayer?
    private weak var scenePlayerForTest: (any ScenePlayerForMedia)?
    private let textureProvider: any MutableTextureProvider

    /// Current media state per block
    private var mediaState: [String: UserMediaKind] = [:]

    /// Video frame providers per block (for video media)
    private var videoProviders: [String: VideoSetupProviding] = [:]

    /// P0 Testing Seam: Factory for creating video providers.
    /// Default creates real VideoFrameProvider. Tests can inject fake.
    var makeVideoProvider: VideoSetupProviderFactory = { device, queue, url, fps in
        VideoFrameProvider(device: device, commandQueue: queue, url: url, sceneFPS: fps)
    }

    /// Scene FPS (needed for video frame calculation)
    private var sceneFPS: Double = 30.0

    /// PR1.1: Callback for async updates that require MetalView redraw.
    /// Called after poster injection or clear/replace.
    public var onNeedsDisplay: (() -> Void)?

    /// PR2: Lightweight render-only callback for still frame delivery.
    /// Unlike `onNeedsDisplay`, does NOT re-trigger still frame sync (avoids infinite loop).
    public var onStillFrameDelivered: (() -> Void)?

    /// PR4: Called when media finishes loading for a block (photo texture injected or video poster ready).
    /// Use to re-resolve placement transforms with actual media dimensions.
    public var onMediaReady: ((String) -> Void)?

    // MARK: - Async Race Protection (PR-async-race)

    /// Generation token per blockId for async race protection.
    /// Incremented on setPhoto/setVideo/cleanup to invalidate pending async operations.
    private var mediaSetupGenerationByBlock: [String: UInt64] = [:]

    /// Active media setup tasks per blockId (for cancellation on replace/cleanup).
    /// Used by both photo (async texture load) and video (async poster extraction) paths.
    private var mediaSetupTasksByBlock: [String: Task<Void, Never>] = [:]

    // MARK: - Still Frame State (PR2: Exact Still Pipeline)

    /// Per-block generation counter for latest-wins still frame extraction.
    private var stillGenerationByBlock: [String: UInt64] = [:]

    /// Per-block in-flight still frame tasks (cancelled on new request or cleanup).
    private var stillTasksByBlock: [String: Task<Void, Never>] = [:]

    // MARK: - Interactive Trim Preview State

    /// Per-block loop tasks for interactive trim preview.
    private var trimPreviewTasksByBlock: [String: Task<Void, Never>] = [:]

    /// Per-block pending preview times (latest wins within the loop).
    private var trimPreviewPendingTimeByBlock: [String: Double] = [:]

    /// Per-block generation counter for interactive trim preview invalidation.
    private var trimPreviewGenerationByBlock: [String: UInt64] = [:]

    // MARK: - Block Readiness State (P0 Readiness Contract)

    /// Per-block readiness state for media setup (photo and video).
    /// Source of truth for scene-level readiness check.
    private enum BlockReadinessState: Equatable {
        case pending
        case ready
        case failed(reason: String)
    }

    /// Readiness state per blockId.
    /// - `.pending`: setup task in progress
    /// - `.ready`: texture/poster injected, userMediaPresent applied
    /// - `.failed`: setup failed, resources cleaned up
    private var blockReadinessState: [String: BlockReadinessState] = [:]

    /// Tracks blocks that failed specifically during media restore (not runtime setup).
    /// Used by scene-edit UI to treat restore-failed blocks as empty.
    private var restoreFailedBlockIds: Set<String> = []

    // MARK: - Poster Throttling (P1)

    /// Semaphore to limit concurrent poster generations.
    /// P1: Limits to max 2 concurrent poster extractions to avoid memory spikes.
    private let posterSemaphore = AsyncSemaphore(limit: 2)

    // MARK: - Video Budget (PR-F)

    /// Budget policy configuration for video playback.
    private var budgetPolicy = VideoBudgetPolicy()

    /// Tick counter for frame divider logic.
    /// Incremented on each `updateVideoFramesForPlayback()` call.
    /// Video textures are only updated when `tickCounter % updateDivider == 0`.
    private var tickCounter: UInt64 = 0

    /// Set of currently active video block IDs (within budget limit).
    /// Used for logging/diagnostics.
    private var activeVideoBlockIds: Set<String> = []

    // MARK: - Initialization

    /// Creates a new UserMediaService.
    ///
    /// - Parameters:
    ///   - device: Metal device for texture creation
    ///   - commandQueue: Command queue for texture blit operations (premultiplied alpha)
    ///   - scenePlayer: Scene player for accessing binding asset IDs and media state
    ///   - textureProvider: Mutable texture provider for texture injection
    public init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        scenePlayer: ScenePlayer,
        textureProvider: any MutableTextureProvider
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.scenePlayer = scenePlayer
        self.scenePlayerForTest = nil
        self.textureProvider = textureProvider
    }

    /// Internal initializer for testing.
    /// P0 Testing Seam: Allows injecting protocol-based fakes for ScenePlayer.
    init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        scenePlayerForTest: any ScenePlayerForMedia,
        textureProvider: any MutableTextureProvider
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.scenePlayer = nil
        self.scenePlayerForTest = scenePlayerForTest
        self.textureProvider = textureProvider
    }

    // MARK: - Player Access

    /// Returns the active scene player (production or test).
    private var activePlayer: (any ScenePlayerForMedia)? {
        scenePlayer ?? scenePlayerForTest
    }

    // MARK: - Configuration

    /// Sets the scene FPS for video frame calculation.
    ///
    /// - Parameter fps: Frames per second of the scene timeline
    public func setSceneFPS(_ fps: Double) {
        self.sceneFPS = fps
    }

    // MARK: - Photo API

    /// Sets a photo as user media for a block.
    ///
    /// Loads the file into a Metal texture via `DownsampledImageLoader` on a background task,
    /// then injects it into ALL variant binding asset IDs on the MainActor.
    /// Does NOT block the MainActor during texture load (GPU blit + waitUntilCompleted).
    ///
    /// P0 Readiness Contract: Updates `blockReadinessState` on success/failure.
    /// Photo failures affect scene-level readiness like video failures.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - fileURL: URL to the persisted photo file
    ///   - presentOnReady: Value for `userMediaPresent` after texture injection (default: `true`)
    /// - Returns: `true` if accepted (async texture load started), `false` if no scene player available.
    ///   File-level errors (missing/corrupt file) are reported asynchronously via `blockReadinessState`.
    /// PR5: mediaRefId enables proxy cache keying. Pass nil for legacy/test paths.
    @discardableResult
    public func setPhoto(blockId: String, fileURL: URL, presentOnReady: Bool = true, mediaRefId: String? = nil) -> Bool {
        guard let player = activePlayer else {
            blockReadinessState[blockId] = .failed(reason: "no scene player")
            return false
        }

        // Clean up any existing video provider
        cleanupVideoResources(for: blockId)

        // Increment generation and cancel previous setup task
        let newGeneration = (mediaSetupGenerationByBlock[blockId] ?? 0) + 1
        mediaSetupGenerationByBlock[blockId] = newGeneration
        let token = newGeneration

        mediaSetupTasksByBlock[blockId]?.cancel()

        // Mark as pending
        blockReadinessState[blockId] = .pending
        restoreFailedBlockIds.remove(blockId)

        // Capture dependencies for background task
        let device = self.device
        let commandQueue = self.commandQueue

        let setupTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                // PR5: Load proxy texture (or master if no proxy available)
                let texture = try await Self.loadPhotoTexture(
                    fileURL: fileURL,
                    mediaRefId: mediaRefId,
                    device: device,
                    commandQueue: commandQueue
                )

                // Check generation after await
                guard self.mediaSetupGenerationByBlock[blockId] == token, !Task.isCancelled else {
                    if self.mediaSetupGenerationByBlock[blockId] == token {
                        self.mediaSetupTasksByBlock.removeValue(forKey: blockId)
                    }
                    return
                }

                // Inject texture into all variant binding asset IDs
                let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
                for (_, assetId) in assetIds {
                    self.textureProvider.setTexture(texture, for: assetId)
                    // PR7: Remove stale video presentation metadata (video→photo replace)
                    (self.textureProvider as? MutableAssetPresentationInfoProvider)?
                        .removePresentationInfo(for: assetId)
                }

                // Update state
                self.mediaState[blockId] = .photo
                self.blockReadinessState[blockId] = .ready
                player.setUserMediaPresent(blockId: blockId, present: presentOnReady)

                // Token-safe remove task
                if self.mediaSetupGenerationByBlock[blockId] == token {
                    self.mediaSetupTasksByBlock.removeValue(forKey: blockId)
                }

                self.onNeedsDisplay?()
                self.onMediaReady?(blockId)

                #if DEBUG
                print("[UserMediaService] setPhoto success: blockId=\(blockId), needsDisplay fired")
                #endif

            } catch is CancellationError {
                if self.mediaSetupGenerationByBlock[blockId] == token {
                    self.mediaSetupTasksByBlock.removeValue(forKey: blockId)
                }
            } catch {
                guard self.mediaSetupGenerationByBlock[blockId] == token else { return }

                // Remove stale textures from previous setup
                let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
                for (_, assetId) in assetIds {
                    self.textureProvider.removeTexture(for: assetId)
                    // PR7: Remove stale video presentation metadata on photo load failure
                    (self.textureProvider as? MutableAssetPresentationInfoProvider)?
                        .removePresentationInfo(for: assetId)
                }

                // Clear stale media state
                self.mediaState.removeValue(forKey: blockId)

                self.blockReadinessState[blockId] = .failed(reason: "photo texture load failed - \(error.localizedDescription)")
                self.mediaSetupTasksByBlock.removeValue(forKey: blockId)
                player.setUserMediaPresent(blockId: blockId, present: false)
                self.onNeedsDisplay?()

                #if DEBUG
                print("[UserMediaService] setPhoto failed: blockId=\(blockId), error=\(error)")
                #endif
            }
        }

        mediaSetupTasksByBlock[blockId] = setupTask
        return true
    }

    /// PR5: Loads a photo texture from proxy (or generates proxy from master).
    /// Export uses master directly; runtime preview uses downsampled proxy for performance.
    private static nonisolated func loadPhotoTexture(
        fileURL: URL,
        mediaRefId: String?,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) async throws -> MTLTexture {
        // Use proxy if we have a mediaRefId for cache keying
        let sourceURL: URL
        if let mediaRefId,
           let proxyURL = PhotoProxyCache.shared.proxyURL(masterURL: fileURL, mediaRefId: mediaRefId) {
            sourceURL = proxyURL
        } else {
            sourceURL = fileURL
        }

        return try DownsampledImageLoader.loadTexture(
            from: sourceURL,
            device: device,
            commandQueue: commandQueue,
            maxDimensionPx: PhotoProxyCache.maxDimension
        )
    }

    // MARK: - Video API

    /// Sets a video as user media for a block.
    ///
    /// Creates provider, generates poster before enabling binding.
    /// Uses poster gating: `userMediaPresent` is only set to `true` after poster is ready.
    /// Token-protected to prevent stale updates on rapid replace.
    ///
    /// Synchronous return indicates acceptance only (player available).
    /// All file/metadata/selection validation happens asynchronously — failures are reported
    /// via `blockReadinessState = .failed` (observable through `hasFailedMedia`).
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - url: URL of the video file (must be persisted — all videos are persisted before binding)
    ///   - presentOnReady: Value for `userMediaPresent` after poster extraction (default: `true`)
    ///   - persistedSelection: The persisted trim/audio parameters to apply.
    ///     Validated against actual duration inside the async poster task.
    /// - Returns: `true` if accepted (async setup started), `false` if no scene player available
    @discardableResult
    public func setVideo(blockId: String, url: URL, presentOnReady: Bool = true, persistedSelection: PersistedVideoSelection) -> Bool {
        guard let player = activePlayer else {
            // P0: Mark as failed - no player available (symmetric with setPhoto)
            blockReadinessState[blockId] = .failed(reason: "no scene player")
            print("[UserMediaService] setVideo failed: no scene player")
            return false
        }

        // Clean up any existing video provider
        cleanupVideoResources(for: blockId)

        // PR-async-race: Increment generation and cancel previous setup task
        let newGeneration = (mediaSetupGenerationByBlock[blockId] ?? 0) + 1
        mediaSetupGenerationByBlock[blockId] = newGeneration
        let token = newGeneration

        mediaSetupTasksByBlock[blockId]?.cancel()

        // Create video frame provider with scene FPS (uses injectable factory)
        let provider = makeVideoProvider(device, commandQueue, url, sceneFPS)
        videoProviders[blockId] = provider

        // P0: Mark block as pending (setup task in progress)
        blockReadinessState[blockId] = .pending
        restoreFailedBlockIds.remove(blockId)

        // PR1: Store state immediately but userMediaPresent = false (poster gating)
        // We'll set the proper VideoSelection after we know the duration
        // For now, create a placeholder that will be updated
        // Note: userMediaPresent stays false until poster is ready

        // Start async poster generation
        // PR-async-race: Store task for cancellation on replace/cleanup
        let setupTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            // P1: Throttle concurrent poster extractions
            await self.posterSemaphore.acquire()

            do {
                // PR1 FIX: requestPoster waits for ready internally, no need for separate polling
                // PR7: Request poster at trimStart so the initial frame matches the selection
                let posterTime = persistedSelection.trimStart
                let poster = try await provider.requestPoster(at: posterTime)

                // PR-async-race: Check token after await — abort if generation changed
                guard self.mediaSetupGenerationByBlock[blockId] == token, !Task.isCancelled else {
                    #if DEBUG
                    print("[UserMediaService] setVideo: stale task ignored for blockId=\(blockId)")
                    #endif
                    // P0: Token-safe remove task (only if we're still current generation)
                    if self.mediaSetupGenerationByBlock[blockId] == token {
                        self.mediaSetupTasksByBlock.removeValue(forKey: blockId)
                    }
                    await self.posterSemaphore.release()
                    return
                }

                // Get duration after provider is ready
                let duration = provider.duration.seconds

                // Validate video window via shared validator
                let selection: VideoSelection
                do {
                    selection = try VideoWindowValidator.validate(
                        selection: persistedSelection,
                        url: url,
                        actualDuration: duration,
                        blockId: blockId
                    )
                } catch {
                    self.markVideoSetupFailed(blockId: blockId, reason: error.localizedDescription, token: token)
                    await self.posterSemaphore.release()
                    return
                }

                // Final check before side effects
                guard self.mediaSetupGenerationByBlock[blockId] == token, !Task.isCancelled else {
                    #if DEBUG
                    print("[UserMediaService] setVideo: stale task ignored (pre-commit) for blockId=\(blockId)")
                    #endif
                    if self.mediaSetupGenerationByBlock[blockId] == token {
                        self.mediaSetupTasksByBlock.removeValue(forKey: blockId)
                    }
                    await self.posterSemaphore.release()
                    return
                }

                // Update state with selection built from persisted params
                self.mediaState[blockId] = .video(selection)

                // Inject poster texture + presentation metadata into all variant binding asset IDs
                let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
                for (_, assetId) in assetIds {
                    self.textureProvider.setTexture(poster, for: assetId)
                    // Inject video presentation metadata for orientation-aware rendering
                    if let presInfo = provider.presentationInfo {
                        (self.textureProvider as? MutableAssetPresentationInfoProvider)?
                            .setPresentationInfo(presInfo, for: assetId)
                    }
                }

                // NOW enable binding layer (poster gating complete)
                // P0-3 fix: Use presentOnReady instead of hardcoded true
                player.setUserMediaPresent(blockId: blockId, present: presentOnReady)

                // P0: Mark block as ready (poster injected, userMediaPresent applied)
                self.blockReadinessState[blockId] = .ready

                // P0: Token-safe remove task from task map
                if self.mediaSetupGenerationByBlock[blockId] == token {
                    self.mediaSetupTasksByBlock.removeValue(forKey: blockId)
                }

                // PR1.1: Trigger redraw after async poster injection
                self.onNeedsDisplay?()
                self.onMediaReady?(blockId)

                #if DEBUG
                print("[UserMediaService] setVideo success: blockId=\(blockId), duration=\(duration)s, needsDisplay fired")
                #endif

                // P1: Release semaphore on success
                await self.posterSemaphore.release()

            } catch is CancellationError {
                // PR-async-race: Expected on cancel/replace — silent ignore
                #if DEBUG
                print("[UserMediaService] setVideo: cancelled for blockId=\(blockId)")
                #endif
                // P0: Token-safe remove task (only if we're still current generation)
                if self.mediaSetupGenerationByBlock[blockId] == token {
                    self.mediaSetupTasksByBlock.removeValue(forKey: blockId)
                }
                await self.posterSemaphore.release()
            } catch {
                // PR-async-race: Only mark failed if still current generation
                guard self.mediaSetupGenerationByBlock[blockId] == token else {
                    await self.posterSemaphore.release()
                    return
                }
                // P0: Use failure helper to preserve failure state
                self.markVideoSetupFailed(blockId: blockId, reason: "poster generation error - \(error.localizedDescription)", token: token)
                await self.posterSemaphore.release()
            }
        }

        mediaSetupTasksByBlock[blockId] = setupTask

        return true
    }

    // MARK: - TT-03 Budget-Aware Playback API

    /// Returns sorted playback candidates for budget allocation.
    /// Used by engine to collect candidates across scenes for global priority ordering.
    ///
    /// - Parameter sceneFrameIndex: Current scene frame for priority calculation
    /// - Returns: Sorted candidates (visible first, then area desc, zIndex desc, blockId asc)
    func playbackCandidates(sceneFrameIndex: Int) -> [PlaybackVideoCandidate] {
        guard let player = activePlayer else { return [] }

        var candidates: [PlaybackVideoCandidate] = []
        for (blockId, kind) in mediaState {
            guard case .video = kind,
                  let provider = videoProviders[blockId],
                  provider.isReady else { continue }

            let priority = player.blockPriorityInfo(blockId: blockId, at: sceneFrameIndex)
                ?? BlockPriorityInfo(isVisible: false, area: 0, zIndex: 0)
            candidates.append(PlaybackVideoCandidate(blockId: blockId, priority: priority))
        }

        // Sort: isVisible desc → area desc → zIndex desc → blockId asc
        candidates.sort { a, b in
            if a.priority.isVisible != b.priority.isVisible { return a.priority.isVisible }
            if a.priority.area != b.priority.area { return a.priority.area > b.priority.area }
            if a.priority.zIndex != b.priority.zIndex { return a.priority.zIndex > b.priority.zIndex }
            return a.blockId < b.blockId
        }
        return candidates
    }

    /// Starts video playback for granted blocks only (engine-owned budget).
    ///
    /// TT-03: Budget-aware variant. Engine determines which blocks get decoder slots.
    /// Non-granted ready providers are soft-stopped (hold-last).
    ///
    /// - Parameters:
    ///   - sceneFrameIndex: Current scene frame to sync to
    ///   - grantedBlockIds: Set of block IDs that have been granted decoder slots by engine
    func startVideoPlayback(sceneFrameIndex: Int, grantedBlockIds: Set<String>) {
        guard let player = activePlayer else { return }

        // Reset tick counter so first updateVideoFramesForPlayback() fires immediately
        tickCounter = UInt64(budgetPolicy.updateDivider - 1)

        for (blockId, kind) in mediaState {
            guard case .video(let selection) = kind,
                  let provider = videoProviders[blockId] else { continue }

            // Non-granted ready providers: soft-stop (hold-last)
            guard grantedBlockIds.contains(blockId) else {
                if provider.isReady && provider.isPlaybackActive {
                    provider.stopPlayback(flush: false)
                }
                continue
            }

            // Granted block: check visibility gating
            let timing = player.blockTiming(for: blockId)
            let isVisible = timing?.isVisible(at: sceneFrameIndex) ?? false

            guard isVisible else {
                if provider.isPlaybackActive {
                    provider.stopPlayback(flush: false)
                }
                continue
            }

            // Compute target video time and start playback
            let videoTime = computeTargetVideoTime(
                sceneFrameIndex: sceneFrameIndex,
                blockId: blockId,
                selection: selection
            )
            provider.startPlayback(atVideoTime: videoTime)
        }

        // Update active set for diagnostics
        activeVideoBlockIds = grantedBlockIds.intersection(Set(videoProviders.keys))
    }

    /// Updates video textures for granted blocks only (engine-owned budget).
    ///
    /// TT-03: Budget-aware variant. Engine determines which blocks get decoder slots.
    /// Non-granted ready providers are soft-stopped (hold-last), textures preserved.
    ///
    /// - Parameters:
    ///   - sceneFrameIndex: Current scene frame for sync
    ///   - grantedBlockIds: Set of block IDs that have been granted decoder slots by engine
    func updateVideoFramesForPlayback(sceneFrameIndex: Int, grantedBlockIds: Set<String>) {
        guard let player = activePlayer else { return }

        // Frame divider — skip video texture updates on non-update ticks
        tickCounter += 1
        let shouldUpdateTextures = (tickCounter % UInt64(budgetPolicy.updateDivider)) == 0

        for (blockId, kind) in mediaState {
            guard case .video(let selection) = kind,
                  let provider = videoProviders[blockId],
                  provider.isReady else { continue }

            // Non-granted ready providers: soft-stop (hold-last), preserve texture
            guard grantedBlockIds.contains(blockId) else {
                if provider.isPlaybackActive {
                    provider.stopPlayback(flush: false)
                }
                continue
            }

            // Granted block: check visibility gating
            let priority = player.blockPriorityInfo(blockId: blockId, at: sceneFrameIndex)
                ?? BlockPriorityInfo(isVisible: false, area: 0, zIndex: 0)

            if !priority.isVisible {
                if provider.isPlaybackActive {
                    provider.stopPlayback(flush: false)
                }
                continue
            }

            // Compute target video time
            let videoTime = computeTargetVideoTime(
                sceneFrameIndex: sceneFrameIndex,
                blockId: blockId,
                selection: selection
            )

            // Ensure playback is running
            if !provider.isPlaybackActive {
                provider.startPlayback(atVideoTime: videoTime)
            }

            // Only update texture on divider ticks
            guard shouldUpdateTextures else { continue }

            // Get frame texture using playback mode (drift correction, no seek per tick)
            guard let texture = provider.frameTextureForPlayback(expectedVideoTime: videoTime) else { continue }

            // Update texture in all variant binding asset IDs
            let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
            for (_, assetId) in assetIds {
                textureProvider.setTexture(texture, for: assetId)
            }
        }

        // Update active set for diagnostics
        activeVideoBlockIds = grantedBlockIds.intersection(Set(videoProviders.keys))
    }

    // MARK: - Playback Control (Legacy Wrappers)

    /// Starts video playback for visible video providers.
    ///
    /// Legacy wrapper: Uses local `budgetPolicy.maxActiveProviders` limit.
    /// Used by scene edit path and non-engine callers.
    ///
    /// - Parameter sceneFrameIndex: Current scene frame to sync to
    public func startVideoPlayback(sceneFrameIndex: Int) {
        // Build local grant set from top candidates
        let candidates = playbackCandidates(sceneFrameIndex: sceneFrameIndex)
        let grantedBlockIds = Set(candidates.prefix(budgetPolicy.maxActiveProviders).map(\.blockId))
        startVideoPlayback(sceneFrameIndex: sceneFrameIndex, grantedBlockIds: grantedBlockIds)
    }

    /// Updates video textures for playback mode.
    ///
    /// Legacy wrapper: Uses local `budgetPolicy.maxActiveProviders` limit.
    /// Used by scene edit path and non-engine callers.
    ///
    /// - Parameter sceneFrameIndex: Current scene frame (for drift detection)
    public func updateVideoFramesForPlayback(sceneFrameIndex: Int) {
        // Build local grant set from top candidates
        let candidates = playbackCandidates(sceneFrameIndex: sceneFrameIndex)
        let grantedBlockIds = Set(candidates.prefix(budgetPolicy.maxActiveProviders).map(\.blockId))
        updateVideoFramesForPlayback(sceneFrameIndex: sceneFrameIndex, grantedBlockIds: grantedBlockIds)
    }

    /// Stops video playback for all video providers.
    ///
    /// PR1.2.1: Uses flush: true to release memory on Pause (vs soft stop on gating).
    /// PR-F: Resets tick counter and clears active set.
    /// Call when scene playback stops (pause).
    public func stopVideoPlayback() {
        for (_, provider) in videoProviders {
            provider.stopPlayback(flush: true)
        }
        // PR-F: Reset budget state
        tickCounter = 0
        activeVideoBlockIds.removeAll()
    }

    /// TT-03 Completion: Stops all active video playback while preserving textures.
    ///
    /// Used when runtime transitions from active to warm state.
    /// Implements hold-last semantics: decoders stop but last textures remain.
    ///
    /// Contract:
    /// - Iterates ready video providers
    /// - Calls `stopPlayback(flush: false)` on active providers
    /// - Does NOT clear textures (hold-last)
    /// - Clears `activeVideoBlockIds`
    /// - Does NOT affect still/readiness behavior
    func stopVideoPlaybackPreservingTextures() {
        for (_, provider) in videoProviders {
            guard provider.isReady, provider.isPlaybackActive else { continue }
            provider.stopPlayback(flush: false)
        }
        // Clear active set but preserve textures
        activeVideoBlockIds.removeAll()
    }

    // MARK: - Frame Update API (Still — PR2: Exact Still Pipeline)

    /// Updates video textures for still mode (scrub, frozen, edit).
    ///
    /// PR2: Replaces updateVideoFramesForScrub and updateVideoFramesForFrozen.
    /// Uses AVAssetImageGenerator for exact frame extraction with per-block latest-wins.
    ///
    /// - Parameter sceneFrameIndex: Target scene frame
    public func updateVideoStillFrames(sceneFrameIndex: Int) {
        guard let player = activePlayer else { return }

        #if DEBUG
        let signpostId = ScrubSignpost.beginUpdateVideoStillFrames()
        var processedBlockCount = 0
        #endif

        for (blockId, kind) in mediaState {
            guard case .video(let selection) = kind,
                  let provider = videoProviders[blockId],
                  provider.isReady else { continue }

            let videoTime = computeTargetVideoTime(
                sceneFrameIndex: sceneFrameIndex,
                blockId: blockId,
                selection: selection
            )
            requestStillForBlock(blockId: blockId, videoTime: videoTime,
                                 provider: provider, player: player)

            #if DEBUG
            processedBlockCount += 1
            #endif
        }

        #if DEBUG
        ScrubSignpost.endUpdateVideoStillFrames(signpostId, blockCount: processedBlockCount)
        #endif
    }

    /// Per-block latest-wins still frame extraction.
    private func requestStillForBlock(blockId: String, videoTime: Double,
                                       provider: VideoSetupProviding, player: ScenePlayerForMedia) {
        let gen = (stillGenerationByBlock[blockId] ?? 0) + 1
        stillGenerationByBlock[blockId] = gen
        stillTasksByBlock[blockId]?.cancel()

        stillTasksByBlock[blockId] = Task { @MainActor [weak self] in
            do {
                let texture = try await provider.requestStillTexture(atVideoTime: videoTime)
                guard let self, self.stillGenerationByBlock[blockId] == gen,
                      !Task.isCancelled else { return }
                let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
                for (_, assetId) in assetIds {
                    self.textureProvider.setTexture(texture, for: assetId)
                }
                // PR2: Use render-only callback to avoid re-entrant still loop.
                // onNeedsDisplay triggers syncPausedVideoStill which calls updateVideoStillFrames again.
                self.onStillFrameDelivered?()
            } catch is CancellationError {
                // Expected: latest-wins cancellation
            } catch {
                #if DEBUG
                print("[UMS] still failed blockId=\(blockId): \(error)")
                #endif
            }
            if let self, self.stillGenerationByBlock[blockId] == gen {
                self.stillTasksByBlock.removeValue(forKey: blockId)
            }
        }
    }

    /// PR2: Awaits all in-flight still tasks to complete.
    /// Used by readiness loop to ensure still frame is actually delivered before marking `.ready`.
    public func awaitPendingStillFrames() async {
        // Snapshot current tasks (they self-remove on completion)
        let tasks = Array(stillTasksByBlock.values)
        for task in tasks {
            await task.value
        }
    }

    /// Computes target video time for a block using shared mapper.
    ///
    /// PR4: Returns video time in seconds directly. No synthetic frame conversion.
    private func computeTargetVideoTime(sceneFrameIndex: Int, blockId: String, selection: VideoSelection) -> Double {
        let blockStartFrame: Int
        if let timing = activePlayer?.blockTiming(for: blockId) {
            blockStartFrame = timing.startFrame
        } else {
            blockStartFrame = 0
        }

        let mapped = VideoTimelineTimeMapper.targetVideoTime(
            sceneFrameIndex: sceneFrameIndex,
            blockStartFrame: blockStartFrame,
            sceneFPS: sceneFPS,
            selection: selection
        )
        return mapped.targetVideoTimeSeconds
    }

    // MARK: - Clear API

    /// Clears user media for a block.
    ///
    /// Full runtime cleanup including provider release and texture/state removal.
    /// Persisted media files are not deleted here — they are owned by MediaAssetStore.
    /// Removes textures from all variant binding asset IDs and marks the block
    /// as having no user media (binding layer will be hidden).
    ///
    /// - Parameter blockId: Identifier of the media block
    public func clear(blockId: String) {
        guard let player = activePlayer else { return }

        // Clean up runtime video resources (provider + pending setup), not persisted media files
        cleanupVideoResources(for: blockId)

        // Remove textures and presentation metadata from all variant binding asset IDs
        let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
        for (_, assetId) in assetIds {
            textureProvider.removeTexture(for: assetId)
            (textureProvider as? MutableAssetPresentationInfoProvider)?
                .removePresentationInfo(for: assetId)
        }

        // Update state
        mediaState.removeValue(forKey: blockId)
        player.setUserMediaPresent(blockId: blockId, present: false)

        // P0: Remove readiness state (user explicitly cleared media)
        blockReadinessState.removeValue(forKey: blockId)
        restoreFailedBlockIds.remove(blockId)

        // PR1.1: Trigger redraw after clear
        onNeedsDisplay?()
    }

    /// Clears all user media for all blocks.
    public func clearAll() {
        // Use union of all keys to catch pending tasks during poster gating
        let allBlockIds = Set(mediaState.keys)
            .union(videoProviders.keys)
            .union(mediaSetupTasksByBlock.keys)
            .union(blockReadinessState.keys)
            .union(trimPreviewTasksByBlock.keys)
        for blockId in allBlockIds {
            clear(blockId: blockId)
        }
    }

    // MARK: - Restore Failure Marking

    /// Marks a block as failed during media restore.
    ///
    /// This API is for failures that occur before entering `setPhoto`/`setVideo`,
    /// such as missing files, unresolved paths, or unsupported media types.
    ///
    /// Behavior:
    /// 1. Cleans up any stale video resources for the block
    /// 2. Removes injected textures for all asset IDs
    /// 3. Clears media state
    /// 4. Sets visibility to false (safe state)
    /// 5. Records failure in readiness state
    /// 6. Triggers redraw
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - reason: Human-readable failure reason for debugging
    @MainActor
    internal func markRestoreFailed(blockId: String, reason: String) {
        // 1. Clean up any stale video resources
        cleanupVideoResources(for: blockId)

        // 2. Remove injected textures and presentation metadata for all asset IDs
        if let player = activePlayer {
            let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
            for (_, assetId) in assetIds {
                textureProvider.removeTexture(for: assetId)
                (textureProvider as? MutableAssetPresentationInfoProvider)?
                    .removePresentationInfo(for: assetId)
            }

            // 3. Set visibility to safe state
            player.setUserMediaPresent(blockId: blockId, present: false)
        }

        // 4. Clear media state
        mediaState.removeValue(forKey: blockId)

        // 5. Record failure in readiness state
        blockReadinessState[blockId] = .failed(reason: reason)
        restoreFailedBlockIds.insert(blockId)

        #if DEBUG
        print("[UserMediaService] markRestoreFailed: blockId=\(blockId), reason=\(reason)")
        #endif

        // 6. Trigger redraw
        onNeedsDisplay?()
    }

    // MARK: - Private Cleanup

    /// Cleans up video resources and invalidates pending media setup for a block.
    /// PR-async-race: Increments generation and cancels setup task to prevent stale updates.
    /// All media files are persistent (owned by MediaAssetStore), so no file deletion here.
    private func cleanupVideoResources(for blockId: String) {
        // PR-async-race: Invalidate pending async operations for this blockId
        mediaSetupGenerationByBlock[blockId, default: 0] += 1
        mediaSetupTasksByBlock[blockId]?.cancel()
        mediaSetupTasksByBlock.removeValue(forKey: blockId)

        // PR2: Cancel pending still frame extraction
        stillGenerationByBlock[blockId, default: 0] += 1
        stillTasksByBlock[blockId]?.cancel()
        stillTasksByBlock.removeValue(forKey: blockId)

        // Cancel interactive trim preview
        trimPreviewGenerationByBlock[blockId, default: 0] += 1
        trimPreviewTasksByBlock[blockId]?.cancel()
        trimPreviewTasksByBlock.removeValue(forKey: blockId)
        trimPreviewPendingTimeByBlock.removeValue(forKey: blockId)

        // Release video provider
        if let provider = videoProviders.removeValue(forKey: blockId) {
            provider.release()
        }
    }

    /// Marks video setup as failed for a block.
    /// P0 Readiness Contract: Preserves failure state while cleaning up resources.
    ///
    /// Unlike `clear(blockId:)`, this helper:
    /// - Keeps `blockReadinessState[blockId] = .failed(reason)` so scene readiness detects failure
    /// - Does NOT remove readiness state entry
    ///
    /// - Parameters:
    ///   - blockId: Block identifier
    ///   - reason: Failure reason for diagnostics
    ///   - token: Generation token for race protection
    private func markVideoSetupFailed(blockId: String, reason: String, token: UInt64) {
        guard let player = activePlayer else { return }

        // Token check - abort if generation changed (new setup in progress)
        guard mediaSetupGenerationByBlock[blockId] == token else {
            #if DEBUG
            print("[UserMediaService] markVideoSetupFailed: stale token for blockId=\(blockId)")
            #endif
            return
        }

        // Cancel and remove in-flight task (token-safe)
        mediaSetupTasksByBlock[blockId]?.cancel()
        mediaSetupTasksByBlock.removeValue(forKey: blockId)

        // Release provider
        if let provider = videoProviders.removeValue(forKey: blockId) {
            provider.release()
        }

        // Remove injected textures and presentation metadata for all variant assetIds
        let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
        for (_, assetId) in assetIds {
            textureProvider.removeTexture(for: assetId)
            (textureProvider as? MutableAssetPresentationInfoProvider)?
                .removePresentationInfo(for: assetId)
        }

        // Clear media state
        mediaState.removeValue(forKey: blockId)

        // Update scene player state
        player.setUserMediaPresent(blockId: blockId, present: false)

        // Mark as failed (preserves failure state for readiness check)
        blockReadinessState[blockId] = .failed(reason: reason)

        // Trigger redraw
        onNeedsDisplay?()

        #if DEBUG
        print("[UserMediaService] markVideoSetupFailed: blockId=\(blockId), reason=\(reason)")
        #endif
    }

    deinit {
        // VideoFrameProvider.deinit handles its own cleanup (release()).
        // All media files are persistent (owned by MediaAssetStore), no temp cleanup needed.
    }

    // MARK: - State Query

    /// Returns the current media kind for a block.
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: Current media kind, or `.none` if no media is set
    public func mediaKind(for blockId: String) -> UserMediaKind {
        mediaState[blockId] ?? .none
    }

    /// Returns whether a block has any user media set.
    ///
    /// - Parameter blockId: Identifier of the media block
    /// - Returns: `true` if photo or video is set, `false` otherwise
    public func hasMedia(blockId: String) -> Bool {
        mediaKind(for: blockId) != .none
    }

    /// PR4: Returns the presentation-correct media size for a loaded block.
    /// For video: `orientedSize` from `VideoPresentationInfo`.
    /// For photo: texture size from the first binding asset.
    /// Returns `nil` if media is not yet loaded or block has no media.
    public func mediaPresentationSize(blockId: String) -> (width: Double, height: Double)? {
        guard let kind = mediaState[blockId] else { return nil }
        switch kind {
        case .video:
            // Video: get orientedSize from provider's presentationInfo
            if let provider = videoProviders[blockId],
               let info = provider.presentationInfo {
                return (Double(info.orientedSize.width), Double(info.orientedSize.height))
            }
            return nil

        case .photo:
            // Photo: get texture size from first binding asset
            let player: (any ScenePlayerForMedia)? = scenePlayer ?? scenePlayerForTest
            guard let player else { return nil }
            let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
            for (_, assetId) in assetIds {
                if let texture = textureProvider.texture(for: assetId) {
                    return (Double(texture.width), Double(texture.height))
                }
            }
            return nil

        case .none:
            return nil
        }
    }

    /// Returns whether any video provider is ready for playback.
    public var hasReadyVideos: Bool {
        videoProviders.values.contains { $0.isReady }
    }

    /// Returns whether all video providers have finished loading (ready or failed, not loading).
    /// Note: This only checks provider state, not poster injection completion.
    public var areAllVideoProvidersSettled: Bool {
        for provider in videoProviders.values {
            switch provider.state {
            case .loading:
                return false
            case .idle, .ready, .failed:
                continue
            }
        }
        return true
    }

    /// Returns whether scene is fully ready for rendering.
    /// P0 Readiness Contract: Uses blockReadinessState as source of truth.
    ///
    /// Ready when:
    /// - All media blocks have state `.ready`
    /// - Or no media blocks at all
    ///
    /// Not ready when:
    /// - Any media block has state `.pending` (still loading)
    /// - Any media block has state `.failed` (cannot render)
    public var isSceneMediaReady: Bool {
        for (_, state) in blockReadinessState {
            switch state {
            case .pending:
                return false // Still loading
            case .failed:
                return false // Failed cannot be ready
            case .ready:
                continue // This block is ready
            }
        }
        // All blocks ready or no media blocks at all
        return true
    }

    /// Returns whether any media restore has failed (photo or video).
    /// P0 Readiness Contract: Uses blockReadinessState as source of truth.
    public var hasFailedMedia: Bool {
        blockReadinessState.values.contains { state in
            if case .failed = state { return true }
            return false
        }
    }

    /// Returns whether the specified block failed during media restore.
    /// Used by scene-edit UI to treat restore-failed blocks as empty.
    /// Does NOT return true for normal runtime setup failures (photo load, video setup).
    public func didBlockFailRestore(blockId: String) -> Bool {
        restoreFailedBlockIds.contains(blockId)
    }

    /// Returns all block IDs that have video media (for render-tick updates).
    public var blockIdsWithVideo: [String] {
        mediaState.compactMap { (blockId, kind) in
            if case .video = kind { return blockId }
            return nil
        }
    }

    // MARK: - Export Resource Management

    /// Releases heavy preview resources (video providers/decoders) to free memory before export.
    ///
    /// Preserves `mediaState` (contains VideoSelection metadata needed for `exportVideoSelectionsSnapshot()`).
    /// After calling this, preview video playback is no longer functional, but snapshot APIs still work.
    public func releasePreviewResources() {
        // PR2: Cancel all pending still frame tasks
        for (_, task) in stillTasksByBlock {
            task.cancel()
        }
        stillTasksByBlock.removeAll()
        stillGenerationByBlock.removeAll()

        // Cancel all interactive trim preview tasks
        for (_, task) in trimPreviewTasksByBlock {
            task.cancel()
        }
        trimPreviewTasksByBlock.removeAll()
        trimPreviewPendingTimeByBlock.removeAll()
        trimPreviewGenerationByBlock.removeAll()

        for (_, provider) in videoProviders {
            provider.releaseInteractiveStillResources()
            provider.release()
        }
        videoProviders.removeAll()
        activeVideoBlockIds.removeAll()
        tickCounter = 0
    }

    // MARK: - Export Snapshot (PR-E3)

    /// Returns a snapshot of video selections for export.
    ///
    /// PR-E3: Captures the current state of all video selections (blockId → VideoSelection).
    /// This snapshot is "frozen" and can be safely used on export queue without actor isolation.
    ///
    /// - Returns: Dictionary mapping blockId to VideoSelection for all video media blocks.
    public func exportVideoSelectionsSnapshot() -> [String: VideoSelection] {
        var result: [String: VideoSelection] = [:]
        for (blockId, kind) in mediaState {
            if case .video(let selection) = kind {
                result[blockId] = selection
            }
        }
        return result
    }

    /// Returns trim context for an already-bound video block, or nil if not trimmable.
    /// Used by UI to determine if "Trim" should be enabled and to provide bounds for the trim bar.
    public func videoTrimContext(blockId: String) -> VideoTrimContext? {
        guard case .video(let selection) = mediaState[blockId] else { return nil }
        guard let provider = videoProviders[blockId], provider.isReady else { return nil }
        let duration = provider.duration.seconds
        guard duration.isFinite, duration > VideoWindowValidator.epsilon else { return nil }
        return VideoTrimContext(
            currentSelection: PersistedVideoSelection(from: selection),
            actualDuration: duration,
            videoURL: selection.url
        )
    }

    /// Returns the current video time in seconds for a block at the given scene frame,
    /// or `nil` if the block is not visible at that frame.
    /// Used by trim UI to determine if the current playhead falls inside the clip window.
    public func currentVideoTime(blockId: String, sceneFrameIndex: Int) -> Double? {
        guard case .video(let selection) = mediaState[blockId] else { return nil }

        // Only return a meaningful time if the block is actually visible at this frame.
        // Without this check the mapper clamps out-of-range frames into [trimStart, trimEnd - ε],
        // making trim incorrectly open near trimEnd when the playhead is past the block.
        if let timing = activePlayer?.blockTiming(for: blockId),
           !timing.isVisible(at: sceneFrameIndex) {
            return nil
        }

        return computeTargetVideoTime(
            sceneFrameIndex: sceneFrameIndex,
            blockId: blockId,
            selection: selection
        )
    }

    /// Applies persisted trim/audio params to an already-bound runtime video selection.
    /// Validates via VideoWindowValidator before mutation. Throws on invalid selection.
    /// On throw: mediaState NOT mutated, blockReadinessState NOT changed, videoProviders NOT touched.
    public func applyPersistedVideoSelection(blockId: String, _ persisted: PersistedVideoSelection) throws {
        guard case .video(let currentSelection) = mediaState[blockId] else {
            throw VideoSelectionApplyError.blockNotVideo(blockId: blockId)
        }
        guard let provider = videoProviders[blockId], provider.isReady else {
            throw VideoSelectionApplyError.providerNotReady(blockId: blockId)
        }
        let validated: VideoSelection
        do {
            validated = try VideoWindowValidator.validate(
                selection: persisted,
                url: currentSelection.url,
                actualDuration: provider.duration.seconds,
                blockId: blockId
            )
        } catch let error as VideoWindowValidationError {
            throw VideoSelectionApplyError.validationFailed(underlying: error)
        }
        mediaState[blockId] = .video(validated)
    }

    // MARK: - Interactive Trim Preview (Coalescing)

    /// Updates the interactive trim preview for a block during drag gestures.
    /// Coalesces rapid calls: only the latest pending time is serviced.
    public func updateInteractiveTrimPreview(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double) {
        guard case .video(let currentSelection) = mediaState[blockId],
              let provider = videoProviders[blockId], provider.isReady,
              let player = activePlayer else { return }

        // Validate draft without mutating mediaState
        let validated: VideoSelection
        do {
            validated = try VideoWindowValidator.validate(
                selection: draftSelection,
                url: currentSelection.url,
                actualDuration: provider.duration.seconds,
                blockId: blockId
            )
        } catch {
            return
        }

        // Clamp preview time to validated range
        let clampedTime = max(validated.trimStart, min(previewTime, validated.trimEnd - VideoWindowValidator.epsilon))

        // Store latest pending time
        trimPreviewPendingTimeByBlock[blockId] = clampedTime

        // If loop already running, it will pick up the new pending time
        if trimPreviewTasksByBlock[blockId] != nil { return }

        // Start a new loop
        let gen = (trimPreviewGenerationByBlock[blockId] ?? 0) + 1
        trimPreviewGenerationByBlock[blockId] = gen

        trimPreviewTasksByBlock[blockId] = Task { @MainActor [weak self] in
            await self?.runInteractiveTrimPreviewLoop(blockId: blockId, provider: provider, player: player, generation: gen)
        }
    }

    /// Loop that drains pending interactive preview times until none remain.
    private func runInteractiveTrimPreviewLoop(blockId: String, provider: VideoSetupProviding, player: ScenePlayerForMedia, generation: UInt64) async {
        while let pendingTime = trimPreviewPendingTimeByBlock[blockId],
              trimPreviewGenerationByBlock[blockId] == generation,
              !Task.isCancelled {
            // Take the pending time
            trimPreviewPendingTimeByBlock.removeValue(forKey: blockId)

            do {
                let texture = try await provider.requestInteractiveStillTexture(atVideoTime: pendingTime)
                guard trimPreviewGenerationByBlock[blockId] == generation, !Task.isCancelled else { break }
                let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
                for (_, assetId) in assetIds {
                    textureProvider.setTexture(texture, for: assetId)
                }
                onStillFrameDelivered?()
            } catch is CancellationError {
                break
            } catch {
                #if DEBUG
                print("[UMS] interactive trim preview failed blockId=\(blockId): \(error)")
                #endif
            }
            // Loop back to check if new pending arrived during in-flight
        }
        // Cleanup on exit
        if trimPreviewGenerationByBlock[blockId] == generation {
            trimPreviewTasksByBlock.removeValue(forKey: blockId)
        }
    }

    /// Ends interactive trim preview: invalidates loop, releases generator resources.
    public func endInteractiveTrimPreview(blockId: String) {
        trimPreviewGenerationByBlock[blockId, default: 0] += 1
        trimPreviewTasksByBlock[blockId]?.cancel()
        trimPreviewTasksByBlock.removeValue(forKey: blockId)
        trimPreviewPendingTimeByBlock.removeValue(forKey: blockId)
        videoProviders[blockId]?.releaseInteractiveStillResources()
    }

    // MARK: - Exact Trim Preview

    /// Previews a video trim frame without mutating mediaState.
    ///
    /// Validates draft selection, requests exact still frame, and injects texture
    /// into binding asset IDs for immediate preview. Uses latest-wins semantics.
    ///
    /// - Parameters:
    ///   - blockId: The video block to preview
    ///   - draftSelection: Draft trim selection (not committed to mediaState)
    ///   - previewTime: Video time in seconds to preview
    public func previewExactVideoTrimFrame(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double) {
        guard case .video(let currentSelection) = mediaState[blockId],
              let provider = videoProviders[blockId], provider.isReady,
              let player = activePlayer else { return }

        // Validate draft without mutating mediaState
        let validated: VideoSelection
        do {
            validated = try VideoWindowValidator.validate(
                selection: draftSelection,
                url: currentSelection.url,
                actualDuration: provider.duration.seconds,
                blockId: blockId
            )
        } catch {
            #if DEBUG
            print("[UMS] trim preview validation failed blockId=\(blockId): \(error)")
            #endif
            return
        }

        // Clamp preview time to validated range
        let clampedTime = max(validated.trimStart, min(previewTime, validated.trimEnd - VideoWindowValidator.epsilon))

        // Request still at preview time using latest-wins
        requestStillForBlock(blockId: blockId, videoTime: clampedTime, provider: provider, player: player)
    }
}
