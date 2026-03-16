import UIKit
import Metal
import AVFoundation
import TVECore

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

    // Playback
    func startPlayback(atSceneFrame sceneFrameIndex: Int)
    func stopPlayback(flush: Bool)
    func frameTextureForPlayback(sceneFrameIndex: Int) -> MTLTexture?
    func frameTextureForScrub(sceneFrameIndex: Int) -> MTLTexture?
    func frameTextureForFrozen(sceneFrameIndex: Int) -> MTLTexture?
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

// MARK: - Texture Factory Protocol (P0 Testing Seam)

/// Protocol for texture factory used by UserMediaService.
/// Internal seam for dependency injection in tests.
protocol TextureFactoryForMedia {
    func makeTexture(from image: UIImage) -> MTLTexture?
}

/// Conform UserMediaTextureFactory to protocol.
extension UserMediaTextureFactory: TextureFactoryForMedia {}

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

/// Represents a user's video selection with trim/offset parameters.
///
/// PR1: Data model for video windowing. The effective playback window is:
/// - `winStart = trimStart + offset`
/// - `winEnd = trimEnd + offset`
///
/// Audio parameters are stored but not applied in PR1 (preview is always muted).
public struct VideoSelection: Equatable, Sendable {
    /// Source video URL (copied to temp directory by UserMediaService)
    public let url: URL

    /// Trim start time in seconds (relative to video start)
    public var trimStart: Double

    /// Trim end time in seconds (relative to video start)
    public var trimEnd: Double

    /// Offset in seconds (shifts the trim window within the video)
    public var offset: Double

    /// Whether audio is muted (stored for PR3 export, not applied in PR1)
    public var isMuted: Bool

    /// Audio volume 0...1 (stored for PR3 export, not applied in PR1)
    public var volume: Float

    // MARK: - Computed Properties

    /// Effective window start in video time
    public var winStart: Double { trimStart + offset }

    /// Effective window end in video time
    public var winEnd: Double { trimEnd + offset }

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
        self.offset = 0
        self.isMuted = false
        self.volume = 1.0
    }

    /// Creates a video selection with explicit parameters.
    public init(
        url: URL,
        trimStart: Double,
        trimEnd: Double,
        offset: Double = 0,
        isMuted: Bool = false,
        volume: Float = 1.0
    ) {
        self.url = url
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.offset = offset
        self.isMuted = isMuted
        self.volume = volume
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

// MARK: - Media Ownership (PR-D)

/// Ownership model for video files.
///
/// PR-D: Determines whether UserMediaService should delete the file on cleanup.
/// - `temporary`: File was copied to temp by UserMediaService, delete on cleanup.
/// - `persistent`: File is managed externally (e.g., ProjectStore), do NOT delete.
public enum MediaOwnership: Equatable, Sendable {
    /// Temporary file owned by UserMediaService. Deleted on cleanup.
    case temporary
    /// Persistent file owned externally (ProjectStore). NOT deleted on cleanup.
    case persistent
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
    /// - `1` = update every tick (e.g., 60fps video at 60fps render)
    /// - `2` = update every 2nd tick (e.g., 30fps video at 60fps render)
    /// Default: 2
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
        updateDivider: Int = 2,
        holdMode: HoldMode = .lastFrame
    ) {
        self.maxActiveProviders = maxActiveProviders
        self.updateDivider = updateDivider
        self.holdMode = holdMode
    }
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
/// service.setPhoto(blockId: "block_01", image: userSelectedImage)
/// // Later...
/// service.clear(blockId: "block_01")
/// ```
@MainActor
public final class UserMediaService {

    // MARK: - Constants

    /// Epsilon for hold-last clamp (1 tick in timescale 600)
    private static let epsilon: Double = 1.0 / 600.0

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private weak var scenePlayer: ScenePlayer?
    private weak var scenePlayerForTest: (any ScenePlayerForMedia)?
    private let textureProvider: any MutableTextureProvider
    private var textureFactory: (any TextureFactoryForMedia)?

    /// Current media state per block
    private var mediaState: [String: UserMediaKind] = [:]

    /// Video frame providers per block (for video media)
    private var videoProviders: [String: VideoSetupProviding] = [:]

    /// P0 Testing Seam: Factory for creating video providers.
    /// Default creates real VideoFrameProvider. Tests can inject fake.
    var makeVideoProvider: VideoSetupProviderFactory = { device, queue, url, fps in
        VideoFrameProvider(device: device, commandQueue: queue, url: url, sceneFPS: fps)
    }

    /// Temp video file URLs per block (PR1: for cleanup)
    private var tempVideoURLByBlockId: [String: URL] = [:]

    /// PR-D: Video file ownership per block (determines cleanup behavior)
    private var videoOwnershipByBlockId: [String: MediaOwnership] = [:]

    /// Scene FPS (needed for video frame calculation)
    private var sceneFPS: Double = 30.0

    /// PR1.1: Callback for async updates that require MetalView redraw.
    /// Called after poster injection or clear/replace.
    public var onNeedsDisplay: (() -> Void)?

    // MARK: - Async Race Protection (PR-async-race)

    /// Generation token per blockId for async race protection.
    /// Incremented on setVideo/cleanup to invalidate pending async operations.
    private var videoSetupGenerationByBlock: [String: UInt64] = [:]

    /// Active video setup tasks per blockId (for cancellation on replace/cleanup).
    private var videoSetupTasksByBlock: [String: Task<Void, Never>] = [:]

    // MARK: - Block Readiness State (P0 Readiness Contract)

    /// Per-block readiness state for video restore.
    /// Source of truth for scene-level readiness check.
    private enum BlockReadinessState: Equatable {
        case pending
        case ready
        case failed(reason: String)
    }

    /// Readiness state per blockId.
    /// - `.pending`: setup task in progress
    /// - `.ready`: poster injected, userMediaPresent applied
    /// - `.failed`: setup failed, resources cleaned up
    private var blockReadinessState: [String: BlockReadinessState] = [:]

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
        self.textureFactory = UserMediaTextureFactory(device: device, commandQueue: commandQueue)
    }

    /// Internal initializer for testing.
    /// P0 Testing Seam: Allows injecting protocol-based fakes for ScenePlayer and TextureFactory.
    init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        scenePlayerForTest: any ScenePlayerForMedia,
        textureProvider: any MutableTextureProvider,
        textureFactory: any TextureFactoryForMedia
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.scenePlayer = nil
        self.scenePlayerForTest = scenePlayerForTest
        self.textureProvider = textureProvider
        self.textureFactory = textureFactory
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
    /// Creates a Metal texture from the image and injects it into ALL variant
    /// binding asset IDs, ensuring the photo persists across variant switches.
    ///
    /// P0 Readiness Contract: Updates `blockReadinessState` on success/failure.
    /// Photo failures now affect scene-level readiness like video failures.
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - image: User-selected photo
    ///   - presentOnReady: Value for `userMediaPresent` after texture injection (default: `true`)
    /// - Returns: `true` if successful, `false` if texture creation failed
    @discardableResult
    public func setPhoto(blockId: String, image: UIImage, presentOnReady: Bool = true) -> Bool {
        guard let player = activePlayer else {
            // P0: Mark as failed - no player available
            blockReadinessState[blockId] = .failed(reason: "no scene player")
            return false
        }
        guard let factory = textureFactory else {
            // P0: Mark as failed - no texture factory (test-only case)
            blockReadinessState[blockId] = .failed(reason: "no texture factory")
            return false
        }

        // PR1: Clean up any existing video provider and temp file
        cleanupVideoResources(for: blockId)

        // Create texture from image
        guard let texture = factory.makeTexture(from: image) else {
            // P0: Mark as failed - texture creation failed
            blockReadinessState[blockId] = .failed(reason: "texture creation failed")
            return false
        }

        // Inject texture into all variant binding asset IDs
        let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
        for (_, assetId) in assetIds {
            textureProvider.setTexture(texture, for: assetId)
        }

        // Update state (lightweight marker, no UIImage storage)
        mediaState[blockId] = .photo

        // P0: Mark as ready - photo successfully injected
        blockReadinessState[blockId] = .ready

        // Apply visibility (respects presentOnReady for restore semantics)
        player.setUserMediaPresent(blockId: blockId, present: presentOnReady)

        return true
    }

    // MARK: - Video API

    /// Sets a video as user media for a block.
    ///
    /// PR1: Creates provider, generates poster before enabling binding.
    /// Uses poster gating: `userMediaPresent` is only set to `true` after poster is ready.
    /// PR-async-race: Token-protected to prevent stale updates on rapid replace.
    ///
    /// PR-D: Added ownership parameter to control cleanup behavior:
    /// - `.temporary`: File will be deleted on cleanup (default, for PHPicker temp files)
    /// - `.persistent`: File will NOT be deleted (for persisted videos from ProjectStore)
    ///
    /// - Parameters:
    ///   - blockId: Identifier of the media block
    ///   - url: URL of the video file
    ///   - ownership: Who owns the file lifecycle (default: `.temporary`)
    ///   - presentOnReady: Value for `userMediaPresent` after poster extraction (default: `true`)
    /// - Returns: `true` if video accepted (async poster generation started), `false` on validation error
    @discardableResult
    public func setVideo(blockId: String, url: URL, ownership: MediaOwnership = .temporary, presentOnReady: Bool = true) -> Bool {
        guard let player = activePlayer else {
            // P0: Mark as failed - no player available (symmetric with setPhoto)
            blockReadinessState[blockId] = .failed(reason: "no scene player")
            print("[UserMediaService] setVideo failed: no scene player")
            return false
        }

        // PR1: Clean up any existing video provider and temp file
        cleanupVideoResources(for: blockId)

        // PR-async-race: Increment generation and cancel previous setup task
        let newGeneration = (videoSetupGenerationByBlock[blockId] ?? 0) + 1
        videoSetupGenerationByBlock[blockId] = newGeneration
        let token = newGeneration

        videoSetupTasksByBlock[blockId]?.cancel()

        // PR-D: Store URL and ownership for cleanup
        tempVideoURLByBlockId[blockId] = url
        videoOwnershipByBlockId[blockId] = ownership

        // Create video frame provider with scene FPS (uses injectable factory)
        let provider = makeVideoProvider(device, commandQueue, url, sceneFPS)
        videoProviders[blockId] = provider

        // P0: Mark block as pending (setup task in progress)
        blockReadinessState[blockId] = .pending

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
                // Request poster at time 0 first to ensure provider is ready
                let poster = try await provider.requestPoster(at: 0)

                // PR-async-race: Check token after await — abort if generation changed
                guard self.videoSetupGenerationByBlock[blockId] == token, !Task.isCancelled else {
                    #if DEBUG
                    print("[UserMediaService] setVideo: stale task ignored for blockId=\(blockId)")
                    #endif
                    // P0: Token-safe remove task (only if we're still current generation)
                    if self.videoSetupGenerationByBlock[blockId] == token {
                        self.videoSetupTasksByBlock.removeValue(forKey: blockId)
                    }
                    await self.posterSemaphore.release()
                    return
                }

                // Get duration after provider is ready
                let duration = provider.duration.seconds

                // Validate duration
                guard duration > Self.epsilon else {
                    // P0: Use failure helper to preserve failure state
                    self.markVideoSetupFailed(blockId: blockId, reason: "video duration too short (\(duration)s)", token: token)
                    await self.posterSemaphore.release()
                    return
                }

                // Create proper VideoSelection with duration
                let selection = VideoSelection(url: url, duration: duration)

                // Validate selection
                guard selection.isValid else {
                    // P0: Use failure helper to preserve failure state
                    self.markVideoSetupFailed(blockId: blockId, reason: "invalid selection (winEnd <= winStart)", token: token)
                    await self.posterSemaphore.release()
                    return
                }

                // PR-async-race: Final check before side effects
                guard self.videoSetupGenerationByBlock[blockId] == token, !Task.isCancelled else {
                    #if DEBUG
                    print("[UserMediaService] setVideo: stale task ignored (pre-commit) for blockId=\(blockId)")
                    #endif
                    // P0: Token-safe remove task (only if we're still current generation)
                    if self.videoSetupGenerationByBlock[blockId] == token {
                        self.videoSetupTasksByBlock.removeValue(forKey: blockId)
                    }
                    await self.posterSemaphore.release()
                    return
                }

                // Update state with proper selection
                self.mediaState[blockId] = .video(selection)

                // Inject poster texture into all variant binding asset IDs
                // (poster at winStart=0 is the default, which is what we already have)
                let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
                for (_, assetId) in assetIds {
                    self.textureProvider.setTexture(poster, for: assetId)
                }

                // NOW enable binding layer (poster gating complete)
                // P0-3 fix: Use presentOnReady instead of hardcoded true
                player.setUserMediaPresent(blockId: blockId, present: presentOnReady)

                // P0: Mark block as ready (poster injected, userMediaPresent applied)
                self.blockReadinessState[blockId] = .ready

                // P0: Token-safe remove task from task map
                if self.videoSetupGenerationByBlock[blockId] == token {
                    self.videoSetupTasksByBlock.removeValue(forKey: blockId)
                }

                // PR1.1: Trigger redraw after async poster injection
                self.onNeedsDisplay?()

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
                if self.videoSetupGenerationByBlock[blockId] == token {
                    self.videoSetupTasksByBlock.removeValue(forKey: blockId)
                }
                await self.posterSemaphore.release()
            } catch {
                // PR-async-race: Only mark failed if still current generation
                guard self.videoSetupGenerationByBlock[blockId] == token else {
                    await self.posterSemaphore.release()
                    return
                }
                // P0: Use failure helper to preserve failure state
                self.markVideoSetupFailed(blockId: blockId, reason: "poster generation error - \(error.localizedDescription)", token: token)
                await self.posterSemaphore.release()
            }
        }

        videoSetupTasksByBlock[blockId] = setupTask

        return true
    }

    /// Copies video to temp directory.
    private func copyVideoToTemp(sourceURL: URL, blockId: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("\(blockId)_\(UUID().uuidString).mov")

        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    // MARK: - Playback Control

    /// Starts video playback for visible video providers.
    ///
    /// PR1 FIX: Computes syntheticFrame for each block to account for blockTiming + trim/offset.
    /// PR1.2: Respects playback gating — only starts providers for blocks visible at sceneFrameIndex.
    /// PR1.2.1: Safe default (false) for missing timing.
    /// PR-F: Resets tick counter so first update tick fires immediately.
    ///
    /// - Parameter sceneFrameIndex: Current scene frame to sync to
    public func startVideoPlayback(sceneFrameIndex: Int) {
        guard let player = activePlayer else { return }

        // PR-F: Reset tick counter so first updateVideoFramesForPlayback() fires immediately
        // (divider - 1) means next increment will be divisible by divider
        tickCounter = UInt64(budgetPolicy.updateDivider - 1)

        for (blockId, kind) in mediaState {
            guard case .video(let selection) = kind,
                  let provider = videoProviders[blockId] else { continue }

            // PR1.2.1: Safe default — if timing unknown, don't start (gating will handle later)
            let timing = player.blockTiming(for: blockId)
            let isVisible = timing?.isVisible(at: sceneFrameIndex) ?? false

            guard isVisible else {
                #if DEBUG
                print("[UserMediaService] startVideoPlayback: skipped '\(blockId)' (not visible at frame \(sceneFrameIndex))")
                #endif
                continue
            }

            // Compute synthetic frame for this block
            let syntheticFrame = computeSyntheticSceneFrame(
                sceneFrameIndex: sceneFrameIndex,
                blockId: blockId,
                selection: selection
            )

            provider.startPlayback(atSceneFrame: syntheticFrame)
        }
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

    // MARK: - Frame Update API

    /// Updates video textures for playback mode (NO seek per frame).
    ///
    /// PR1 FIX: Uses syntheticFrame + frameTextureForPlayback to preserve NO-seek behavior.
    /// PR1.2: Playback gating — only decode videos for blocks that are visible by timing.
    /// PR1.2.1: Soft stop (no flush) on gating, safe default (false) for missing timing.
    /// PR-F: Video budget — limits active providers to N, uses frame divider for update cadence.
    ///
    /// - Parameter sceneFrameIndex: Current scene frame (for drift detection)
    public func updateVideoFramesForPlayback(sceneFrameIndex: Int) {
        guard let player = activePlayer else { return }

        // PR-F: Frame divider — skip video texture updates on non-update ticks
        tickCounter += 1
        let shouldUpdateTextures = (tickCounter % UInt64(budgetPolicy.updateDivider)) == 0

        // Collect video candidates with priority info
        var candidates: [(blockId: String, selection: VideoSelection, provider: VideoSetupProviding, priority: BlockPriorityInfo)] = []

        for (blockId, kind) in mediaState {
            guard case .video(let selection) = kind,
                  let provider = videoProviders[blockId],
                  provider.isReady else { continue }

            // Get priority info from ScenePlayer
            let priorityInfo = player.blockPriorityInfo(blockId: blockId, at: sceneFrameIndex)
                ?? BlockPriorityInfo(isVisible: false, area: 0, zIndex: 0)

            candidates.append((blockId, selection, provider, priorityInfo))
        }

        // PR-F: Sort by priority (visible first, then by area desc, then by zIndex desc, then by blockId for determinism)
        candidates.sort { a, b in
            // 1. Visibility: visible > not visible
            if a.priority.isVisible != b.priority.isVisible {
                return a.priority.isVisible
            }
            // 2. Area: larger > smaller
            if a.priority.area != b.priority.area {
                return a.priority.area > b.priority.area
            }
            // 3. zIndex: higher > lower
            if a.priority.zIndex != b.priority.zIndex {
                return a.priority.zIndex > b.priority.zIndex
            }
            // 4. Deterministic tiebreaker: alphabetical by blockId
            return a.blockId < b.blockId
        }

        // PR-F: Select top-N as active
        let activeCount = min(candidates.count, budgetPolicy.maxActiveProviders)
        let activeCandidates = Array(candidates.prefix(activeCount))
        let inactiveCandidates = Array(candidates.dropFirst(activeCount))

        // Update active set for diagnostics
        activeVideoBlockIds = Set(activeCandidates.map(\.blockId))

        // Process inactive videos first — stop playback, keep last texture
        for (blockId, _, provider, _) in inactiveCandidates {
            if provider.isPlaybackActive {
                provider.stopPlayback(flush: false)
                #if DEBUG
                print("[UserMediaService] PR-F Budget: deactivated '\(blockId)' (over limit)")
                #endif
            }
            // Texture stays as-is in textureProvider (holdLastFrame behavior)
        }

        // Process active videos
        for (blockId, selection, provider, priority) in activeCandidates {
            // Check visibility gating (even active videos skip if not visible)
            if !priority.isVisible {
                if provider.isPlaybackActive {
                    provider.stopPlayback(flush: false)
                    #if DEBUG
                    print("[UserMediaService] Gating: soft-stopped playback for '\(blockId)' (not visible)")
                    #endif
                }
                continue
            }

            // Compute syntheticFrame for this block
            let syntheticFrame = computeSyntheticSceneFrame(
                sceneFrameIndex: sceneFrameIndex,
                blockId: blockId,
                selection: selection
            )

            // Ensure playback is running
            if !provider.isPlaybackActive {
                provider.startPlayback(atSceneFrame: syntheticFrame)
                #if DEBUG
                print("[UserMediaService] Gating: started playback for '\(blockId)' at frame \(sceneFrameIndex)")
                #endif
            }

            // PR-F: Only update texture on divider ticks
            guard shouldUpdateTextures else { continue }

            // Get frame texture using playback mode (drift correction, no seek per tick)
            guard let texture = provider.frameTextureForPlayback(sceneFrameIndex: syntheticFrame) else { continue }

            // Update texture in all variant binding asset IDs
            let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
            for (_, assetId) in assetIds {
                textureProvider.setTexture(texture, for: assetId)
            }
        }
    }

    /// Updates video textures for scrub mode (throttled seek).
    ///
    /// PR1 FIX: Uses syntheticFrame + frameTextureForScrub to preserve throttling.
    /// Seeks are throttled to ~30Hz max to avoid overwhelming the decoder.
    ///
    /// - Parameter sceneFrameIndex: Target scene frame
    public func updateVideoFramesForScrub(sceneFrameIndex: Int) {
        guard let player = activePlayer else { return }

        #if DEBUG
        let signpostId = ScrubSignpost.beginUpdateVideoFramesForScrub()
        var processedBlockCount = 0
        #endif

        for (blockId, kind) in mediaState {
            guard case .video(let selection) = kind,
                  let provider = videoProviders[blockId] else { continue }

            // Skip if provider not ready
            guard provider.isReady else { continue }

            // PR1 FIX: Compute synthetic frame, use existing scrub method (throttled)
            let syntheticFrame = computeSyntheticSceneFrame(
                sceneFrameIndex: sceneFrameIndex,
                blockId: blockId,
                selection: selection
            )

            // Get frame texture using scrub mode (throttled seek)
            guard let texture = provider.frameTextureForScrub(sceneFrameIndex: syntheticFrame) else { continue }

            // Update texture in all variant binding asset IDs
            let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
            for (_, assetId) in assetIds {
                textureProvider.setTexture(texture, for: assetId)
            }

            #if DEBUG
            processedBlockCount += 1
            #endif
        }

        #if DEBUG
        ScrubSignpost.endUpdateVideoFramesForScrub(signpostId, blockCount: processedBlockCount)
        #endif
    }

    /// Updates video textures for frozen/edit mode.
    ///
    /// PR1 FIX: Uses syntheticFrame + frameTextureForFrozen to preserve caching.
    /// In edit mode, scene is frozen at editFrameIndex.
    ///
    /// - Parameter sceneFrameIndex: Edit frame index
    public func updateVideoFramesForFrozen(sceneFrameIndex: Int) {
        guard let player = activePlayer else { return }

        for (blockId, kind) in mediaState {
            guard case .video(let selection) = kind,
                  let provider = videoProviders[blockId] else { continue }

            // Skip if provider not ready
            guard provider.isReady else { continue }

            // PR1 FIX: Compute synthetic frame, use existing frozen method (cached)
            let syntheticFrame = computeSyntheticSceneFrame(
                sceneFrameIndex: sceneFrameIndex,
                blockId: blockId,
                selection: selection
            )

            // Get frozen frame texture (with caching)
            guard let texture = provider.frameTextureForFrozen(sceneFrameIndex: syntheticFrame) else { continue }

            // Update texture in all variant binding asset IDs
            let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
            for (_, assetId) in assetIds {
                textureProvider.setTexture(texture, for: assetId)
            }
        }
    }

    /// Computes synthetic scene frame for video provider.
    ///
    /// PR1 FIX: Transforms scene frame → video time → synthetic frame.
    /// This preserves provider's NO-seek-per-frame behavior while accounting for trim/offset.
    ///
    /// Formula:
    /// 1. tBlock = (sceneFrameIndex - blockStartFrame) / sceneFPS
    /// 2. tVideo = winStart + tBlock
    /// 3. tVideoClamped = clamp(tVideo, winStart, winEnd - epsilon)
    /// 4. syntheticFrame = Int((tVideoClamped * sceneFPS).rounded(.down))
    private func computeSyntheticSceneFrame(sceneFrameIndex: Int, blockId: String, selection: VideoSelection) -> Int {
        // Get block timing (startFrame)
        let blockStartFrame: Int
        if let timing = activePlayer?.blockTiming(for: blockId) {
            blockStartFrame = timing.startFrame
        } else {
            blockStartFrame = 0
        }

        // Compute tBlock (time from block start)
        let framesIntoBlock = sceneFrameIndex - blockStartFrame
        let tBlock = max(0.0, Double(framesIntoBlock) / sceneFPS)

        // Compute tVideo with window
        let tVideo = selection.winStart + tBlock

        // Clamp to window (hold-last)
        let tVideoClamped = min(max(tVideo, selection.winStart), selection.winEnd - Self.epsilon)

        // Convert back to synthetic scene frame
        let syntheticFrame = Int((tVideoClamped * sceneFPS).rounded(.down))

        return syntheticFrame
    }

    /// Legacy compatibility: Updates video textures (calls scrub mode internally).
    ///
    /// - Parameter sceneFrameIndex: Current frame index in the scene timeline
    @available(*, deprecated, message: "Use updateVideoFramesForPlayback/Scrub/Frozen instead")
    public func updateAllVideoFrames(sceneFrameIndex: Int) {
        updateVideoFramesForScrub(sceneFrameIndex: sceneFrameIndex)
    }

    // MARK: - Clear API

    /// Clears user media for a block.
    ///
    /// PR1: Full cleanup including provider release and temp file deletion.
    /// Removes textures from all variant binding asset IDs and marks the block
    /// as having no user media (binding layer will be hidden).
    ///
    /// - Parameter blockId: Identifier of the media block
    public func clear(blockId: String) {
        guard let player = activePlayer else { return }

        // PR1: Clean up video resources (provider + temp file)
        cleanupVideoResources(for: blockId)

        // Remove textures from all variant binding asset IDs
        let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
        for (_, assetId) in assetIds {
            textureProvider.removeTexture(for: assetId)
        }

        // Update state
        mediaState.removeValue(forKey: blockId)
        player.setUserMediaPresent(blockId: blockId, present: false)

        // P0: Remove readiness state (user explicitly cleared media)
        blockReadinessState.removeValue(forKey: blockId)

        // PR1.1: Trigger redraw after clear
        onNeedsDisplay?()
    }

    /// Clears all user media for all blocks.
    public func clearAll() {
        // P1-1 fix: Use union of all keys to catch pending tasks during poster gating
        // P0: Include blockReadinessState.keys for failed blocks
        let allBlockIds = Set(mediaState.keys)
            .union(tempVideoURLByBlockId.keys)
            .union(videoProviders.keys)
            .union(videoSetupTasksByBlock.keys)
            .union(blockReadinessState.keys)
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

        // 2. Remove injected textures for all asset IDs
        if let player = activePlayer {
            let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
            for (_, assetId) in assetIds {
                textureProvider.removeTexture(for: assetId)
            }

            // 3. Set visibility to safe state
            player.setUserMediaPresent(blockId: blockId, present: false)
        }

        // 4. Clear media state
        mediaState.removeValue(forKey: blockId)

        // 5. Record failure in readiness state
        blockReadinessState[blockId] = .failed(reason: reason)

        #if DEBUG
        print("[UserMediaService] markRestoreFailed: blockId=\(blockId), reason=\(reason)")
        #endif

        // 6. Trigger redraw
        onNeedsDisplay?()
    }

    // MARK: - Private Cleanup

    /// Cleans up video resources for a block (provider + temp file).
    /// PR-async-race: Increments generation and cancels setup task to prevent stale updates.
    /// PR-D: Only deletes file if ownership is `.temporary`.
    private func cleanupVideoResources(for blockId: String) {
        // PR-async-race: Invalidate pending async operations for this blockId
        videoSetupGenerationByBlock[blockId, default: 0] += 1
        videoSetupTasksByBlock[blockId]?.cancel()
        videoSetupTasksByBlock.removeValue(forKey: blockId)

        // Release video provider
        if let provider = videoProviders.removeValue(forKey: blockId) {
            provider.release()
        }

        // PR-D: Get ownership before removing URL
        let ownership = videoOwnershipByBlockId.removeValue(forKey: blockId) ?? .temporary

        // Delete file only if temporary (owned by UserMediaService)
        if let fileURL = tempVideoURLByBlockId.removeValue(forKey: blockId) {
            if ownership == .temporary {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    #if DEBUG
                    print("[UserMediaService] Deleted temp file: \(fileURL.lastPathComponent)")
                    #endif
                } catch {
                    print("[UserMediaService] Failed to delete temp file: \(error.localizedDescription)")
                }
            } else {
                #if DEBUG
                print("[UserMediaService] Preserved persistent file: \(fileURL.lastPathComponent)")
                #endif
            }
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
        guard videoSetupGenerationByBlock[blockId] == token else {
            #if DEBUG
            print("[UserMediaService] markVideoSetupFailed: stale token for blockId=\(blockId)")
            #endif
            return
        }

        // Cancel and remove in-flight task (token-safe)
        videoSetupTasksByBlock[blockId]?.cancel()
        videoSetupTasksByBlock.removeValue(forKey: blockId)

        // Release provider
        if let provider = videoProviders.removeValue(forKey: blockId) {
            provider.release()
        }

        // Remove injected textures for all variant assetIds
        let assetIds = player.bindingAssetIdsByVariant(blockId: blockId)
        for (_, assetId) in assetIds {
            textureProvider.removeTexture(for: assetId)
        }

        // Clear media state
        mediaState.removeValue(forKey: blockId)

        // Update scene player state
        player.setUserMediaPresent(blockId: blockId, present: false)

        // Mark as failed (preserves failure state for readiness check)
        blockReadinessState[blockId] = .failed(reason: reason)

        // Clean up temp file (use ownership check)
        let ownership = videoOwnershipByBlockId.removeValue(forKey: blockId) ?? .temporary
        if let fileURL = tempVideoURLByBlockId.removeValue(forKey: blockId) {
            if ownership == .temporary {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        // Trigger redraw
        onNeedsDisplay?()

        #if DEBUG
        print("[UserMediaService] markVideoSetupFailed: blockId=\(blockId), reason=\(reason)")
        #endif
    }

    deinit {
        // Note: For @MainActor classes, deinit runs on main when last reference
        // is released on main (which is the typical case for UI-owned services).
        // VideoFrameProvider.deinit handles its own cleanup (release()).
        // Temp files are cleaned up here - FileManager operations are thread-safe.
        //
        // We access ivars directly without actor isolation because:
        // 1. deinit is the final access point - no other references exist
        // 2. No concurrent access is possible during deinitialization
        //
        // PR-D: Only delete files with .temporary ownership
        for (blockId, fileURL) in tempVideoURLByBlockId {
            let ownership = videoOwnershipByBlockId[blockId] ?? .temporary
            if ownership == .temporary {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
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
    /// - All video blocks have state `.ready`
    /// - Or no video blocks at all
    ///
    /// Not ready when:
    /// - Any video block has state `.pending` (still loading)
    /// - Any video block has state `.failed` (cannot render)
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
        // All blocks ready or no video blocks at all
        return true
    }

    /// Returns whether any video restore has failed.
    /// P0 Readiness Contract: Uses blockReadinessState as source of truth.
    /// Returns whether any media restore has failed (photo or video).
    /// P0 Readiness Contract: Uses blockReadinessState as source of truth.
    public var hasFailedMedia: Bool {
        blockReadinessState.values.contains { state in
            if case .failed = state { return true }
            return false
        }
    }

    /// Returns all block IDs that have video media (for render-tick updates).
    public var blockIdsWithVideo: [String] {
        mediaState.compactMap { (blockId, kind) in
            if case .video = kind { return blockId }
            return nil
        }
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
}
