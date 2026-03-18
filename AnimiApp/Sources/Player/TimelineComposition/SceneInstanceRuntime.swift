import Foundation
import Metal
import UIKit
import TVECore

// MARK: - Scene Media Syncing Protocol (Test Seam)

/// Protocol for media frame synchronization and readiness inspection.
/// Allows test injection for verifying clamped frame forwarding and readiness state.
@MainActor
protocol SceneMediaSyncing: AnyObject {
    // MARK: Frame Update APIs
    func updateVideoFramesForScrub(sceneFrameIndex: Int)
    func updateVideoFramesForPlayback(sceneFrameIndex: Int)
    func updateVideoFramesForFrozen(sceneFrameIndex: Int)
    func startVideoPlayback(sceneFrameIndex: Int)

    // MARK: Readiness APIs (TT-02)
    var isSceneMediaReady: Bool { get }
    var hasFailedMedia: Bool { get }

    // MARK: TT-03 Budget-Aware APIs
    func playbackCandidates(sceneFrameIndex: Int) -> [PlaybackVideoCandidate]
    func startVideoPlayback(sceneFrameIndex: Int, grantedBlockIds: Set<String>)
    func updateVideoFramesForPlayback(sceneFrameIndex: Int, grantedBlockIds: Set<String>)

    // MARK: TT-03 Completion: Soft-Stop for Warm Runtimes
    /// Stops all active video playback while preserving textures (hold-last).
    /// Used when runtime transitions from active to warm state.
    /// - Does NOT clear textures (hold-last semantics)
    /// - Clears activeVideoBlockIds
    /// - Does NOT affect scrub/frozen/readiness behavior
    func stopVideoPlaybackPreservingTextures()
}

extension UserMediaService: SceneMediaSyncing {}

// MARK: - Test Configuration (Internal)

/// TT-02: Configuration for preparation timing, used by test seam.
/// Internal to allow fast timeout testing without waiting 5 seconds.
struct PreparationTimingConfig {
    let maxWaitMs: Int
    let pollIntervalMs: UInt64

    /// Production defaults: 5000ms max wait, 50ms poll interval.
    static let production = PreparationTimingConfig(maxWaitMs: 5000, pollIntervalMs: 50)

    /// Fast config for timeout tests: 100ms max wait, 10ms poll interval.
    static let fastForTesting = PreparationTimingConfig(maxWaitMs: 100, pollIntervalMs: 10)
}

// MARK: - Scene Instance Runtime

/// Runtime state for a single scene instance.
/// Wraps shared scene type resources with per-instance state.
@MainActor
public final class SceneInstanceRuntime {

    // MARK: - Identity

    /// Scene instance ID (from TimelineItem.id).
    public let sceneInstanceId: UUID

    /// Scene type ID (from ScenePayload.sceneTypeId).
    public let sceneTypeId: String

    // MARK: - Shared Resources (from SceneTypeResourcesCache)

    /// Shared resources for this scene type.
    public let resources: SceneTypeResourcesCache.Resources

    // MARK: - Per-Instance Components

    /// Scene player for this instance.
    public let scenePlayer: ScenePlayer

    /// Layered texture provider (base + overlay).
    public let layeredTextureProvider: LayeredTextureProvider

    /// Overlay texture provider for user media injection.
    public let overlayTextureProvider: MutableTextureProvider

    /// User media service for this instance.
    /// Video budget is managed by GlobalVideoBudgetCoordinator.
    public let userMediaService: UserMediaService

    /// Injected media syncing service for tests (nil in production).
    private let injectedMediaSyncing: SceneMediaSyncing?

    /// Media syncing target: injected spy in tests, userMediaService in production.
    private var mediaSyncing: SceneMediaSyncing {
        injectedMediaSyncing ?? userMediaService
    }

    /// TT-02: Timing config for preparation loop. Production by default.
    private let timingConfig: PreparationTimingConfig

    // MARK: - State

    /// TT-02: Readiness state for scene rendering.
    /// States with targetLocalFrame track the frame used for first-frame warmup.
    public enum ReadinessState: Equatable, Sendable {
        case created
        case preparing(targetLocalFrame: Int)
        case ready(targetLocalFrame: Int)
        case failed(reason: String)
        case timedOut(targetLocalFrame: Int)
    }

    /// Current readiness state.
    public private(set) var readinessState: ReadinessState = .created

    /// TT-02: Single in-flight preparation task.
    /// Used to ensure only one prepare attempt runs at a time.
    private var preparationTask: Task<Void, Never>?

    /// Convenience: whether this instance is ready for rendering.
    public var isReady: Bool {
        if case .ready = readinessState { return true }
        return false
    }

    /// Currently applied scene state.
    public private(set) var appliedState: SceneState?

    // MARK: - Init

    /// Creates a scene instance runtime.
    /// - Parameters:
    ///   - sceneInstanceId: Instance ID.
    ///   - resources: Shared scene type resources.
    ///   - device: Metal device.
    ///   - commandQueue: Metal command queue.
    public init(
        sceneInstanceId: UUID,
        resources: SceneTypeResourcesCache.Resources,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) {
        self.sceneInstanceId = sceneInstanceId
        self.sceneTypeId = resources.sceneTypeId
        self.resources = resources
        self.injectedMediaSyncing = nil
        self.timingConfig = .production

        // Create per-instance overlay provider
        self.overlayTextureProvider = InMemoryTextureProvider()

        // Create layered provider (base + overlay)
        self.layeredTextureProvider = LayeredTextureProvider(
            base: resources.baseTextureProvider,
            overlay: overlayTextureProvider
        )

        // Create scene player and load compiled scene
        self.scenePlayer = ScenePlayer()
        scenePlayer.loadCompiledScene(resources.compiled)

        // Create user media service for this instance
        self.userMediaService = UserMediaService(
            device: device,
            commandQueue: commandQueue,
            scenePlayer: scenePlayer,
            textureProvider: overlayTextureProvider
        )
        userMediaService.setSceneFPS(Double(resources.fps))
    }

    // MARK: - Test Init (Internal)

    /// Creates a scene instance runtime with injected media syncing for tests.
    /// - Parameters:
    ///   - sceneInstanceId: Instance ID.
    ///   - resources: Shared scene type resources.
    ///   - device: Metal device.
    ///   - commandQueue: Metal command queue.
    ///   - mediaSyncing: Injected media syncing spy for tests.
    ///   - timingConfig: Optional timing config for fast timeout testing.
    init(
        sceneInstanceId: UUID,
        resources: SceneTypeResourcesCache.Resources,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        mediaSyncing: SceneMediaSyncing,
        timingConfig: PreparationTimingConfig = .production
    ) {
        self.sceneInstanceId = sceneInstanceId
        self.sceneTypeId = resources.sceneTypeId
        self.resources = resources
        self.injectedMediaSyncing = mediaSyncing
        self.timingConfig = timingConfig

        // Create per-instance overlay provider
        self.overlayTextureProvider = InMemoryTextureProvider()

        // Create layered provider (base + overlay)
        self.layeredTextureProvider = LayeredTextureProvider(
            base: resources.baseTextureProvider,
            overlay: overlayTextureProvider
        )

        // Create scene player and load compiled scene
        self.scenePlayer = ScenePlayer()
        scenePlayer.loadCompiledScene(resources.compiled)

        // Create user media service for this instance
        self.userMediaService = UserMediaService(
            device: device,
            commandQueue: commandQueue,
            scenePlayer: scenePlayer,
            textureProvider: overlayTextureProvider
        )
        userMediaService.setSceneFPS(Double(resources.fps))
    }

    // MARK: - Frame Clamping (Hold Last Frame)

    /// Clamps localFrame to valid range [0, durationFrames - 1].
    /// Implements "hold last frame" behavior when scene is extended beyond native animation duration.
    private func clampedLocalFrame(_ localFrame: Int) -> Int {
        let maxFrame = max(0, resources.durationFrames - 1)
        return min(max(localFrame, 0), maxFrame)
    }

    // MARK: - State Application

    /// Resets runtime state before applying new state.
    /// Clears all overrides to ensure clean re-application.
    /// TT-02: Cancels in-flight preparation and resets to .created.
    public func resetState() {
        // TT-02: Cancel in-flight preparation
        preparationTask?.cancel()
        preparationTask = nil

        // Reset ScenePlayer state
        scenePlayer.resetForNewInstance()

        // Clear UserMediaService
        userMediaService.clearAll()

        // Clear applied state
        appliedState = nil
        readinessState = .created

        #if DEBUG
        print("[SceneInstanceRuntime] Reset state for instance: \(sceneInstanceId)")
        #endif
    }

    /// Applies scene state to this instance.
    /// For full reload, call resetState() first.
    /// - Parameter state: Scene state with variants, transforms, toggles, media assignments.
    public func applyState(_ state: SceneState) async {
        appliedState = state

        // Apply variant overrides
        for (blockId, variantId) in state.variantOverrides {
            scenePlayer.setSelectedVariant(blockId: blockId, variantId: variantId)
        }

        // Apply user transforms
        for (blockId, transform) in state.userTransforms {
            scenePlayer.setUserTransform(blockId: blockId, transform: transform)
        }

        // Apply layer toggles
        for (blockId, toggles) in state.layerToggles {
            for (toggleId, enabled) in toggles {
                scenePlayer.setLayerToggle(blockId: blockId, toggleId: toggleId, enabled: enabled)
            }
        }

        // Restore media assignments via MediaRestoreHelper (handles both photo and video)
        let restoredCount = MediaRestoreHelper.restore(
            assignments: state.mediaAssignments,
            userMediaPresent: state.userMediaPresent,
            to: userMediaService
        )

        #if DEBUG
        print("[SceneInstanceRuntime] Applied state for \(sceneInstanceId): restored \(restoredCount) media items")
        #endif

        // Note: userMediaPresent is now applied atomically via MediaRestoreHelper.restore()
        // which passes presentOnReady to both setPhoto() and setVideo() calls.
        // No unconditional replay needed - this preserves poster-gating semantics.
    }

    /// Reloads state from scratch (reset + apply).
    /// Use this after undo/redo or when state needs full refresh.
    /// TT-02: No auto-prepare — caller controls readiness via startPreparingForPresentation.
    public func reloadState(_ state: SceneState) async {
        resetState()  // Sets readinessState = .created, cancels preparationTask
        await applyState(state)
        // NO auto-prepare
    }

    // MARK: - TT-02: Readiness State Machine

    /// TT-02: Internal helper to sync frozen frame with clamping.
    private func syncFrozenFrame(_ localFrame: Int) {
        mediaSyncing.updateVideoFramesForFrozen(sceneFrameIndex: clampedLocalFrame(localFrame))
    }

    /// TT-02: Starts preparing runtime for presentation at specific local frame.
    /// Uses frozen-frame API for exact first-frame warmup.
    ///
    /// STATE MACHINE RULES:
    /// - From .created: start new preparation
    /// - From .preparing(_): no-op (let current task finish)
    /// - From .ready(_): no-op (already scene-ready)
    /// - From .failed/.timedOut: no-op (retry via resetState/reloadState only)
    ///
    /// Does NOT block - use waitUntilReadyForPresentation to await completion.
    public func startPreparingForPresentation(at localFrame: Int) {
        let targetFrame = clampedLocalFrame(localFrame)

        switch readinessState {
        case .ready:
            // Already scene-ready. Do NOT downgrade to .preparing.
            return

        case .preparing:
            // Already preparing. Let it finish.
            return

        case .failed, .timedOut:
            // Terminal failure. Retry only via resetState()/reloadState().
            // This is intentional: preview gets explicit failure, not infinite hold/retry loop.
            return

        case .created:
            // Start new preparation
            break
        }

        readinessState = .preparing(targetLocalFrame: targetFrame)

        // Initial frozen sync
        syncFrozenFrame(targetFrame)

        // Start single in-flight preparation task
        preparationTask = Task { @MainActor [weak self] in
            await self?.runPreparationLoop(targetFrame: targetFrame)
        }
    }

    /// TT-02: Internal preparation loop. Only called from startPreparingForPresentation.
    private func runPreparationLoop(targetFrame: Int) async {
        let maxWaitMs = timingConfig.maxWaitMs
        let pollIntervalMs = timingConfig.pollIntervalMs
        var elapsed = 0

        while elapsed < maxWaitMs {
            // Check for external state changes (reset, reload, cancel)
            guard case .preparing(let current) = readinessState, current == targetFrame else {
                return  // State changed externally, abort this loop
            }

            // Check for failures early
            if mediaSyncing.hasFailedMedia {
                readinessState = .failed(reason: "Media restore failed")
                return
            }

            // Check if ready
            if mediaSyncing.isSceneMediaReady {
                // Final frozen sync before marking ready
                syncFrozenFrame(targetFrame)
                readinessState = .ready(targetLocalFrame: targetFrame)
                #if DEBUG
                print("[SceneInstanceRuntime] Ready for presentation at frame \(targetFrame): \(sceneInstanceId)")
                #endif
                return
            }

            try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
            elapsed += Int(pollIntervalMs)

            // Re-sync frozen frame during poll
            syncFrozenFrame(targetFrame)
        }

        // Timeout
        readinessState = .timedOut(targetLocalFrame: targetFrame)
        #if DEBUG
        print("[SceneInstanceRuntime] Timed out preparing at frame \(targetFrame): \(sceneInstanceId)")
        #endif
    }

    /// TT-02: Waits until runtime reaches terminal state.
    /// Delegates all state decisions to startPreparingForPresentation.
    /// Does NOT have own timeout policy - just polls until terminal.
    public func waitUntilReadyForPresentation(at localFrame: Int) async -> ReadinessState {
        // If created, delegate to single owner
        if case .created = readinessState {
            startPreparingForPresentation(at: localFrame)
        }

        // If already terminal, return immediately
        switch readinessState {
        case .ready, .failed, .timedOut:
            return readinessState
        case .created, .preparing:
            break
        }

        // Poll until terminal state (no own timeout)
        let pollIntervalMs: UInt64 = 50

        while true {
            switch readinessState {
            case .ready, .failed, .timedOut:
                return readinessState
            case .created:
                // Unexpected - should not happen after startPreparing
                return readinessState
            case .preparing:
                break
            }

            try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
        }
    }

    // MARK: - Playback (Legacy Compatibility)

    /// Syncs video frames to specific local frame (for scrubbing).
    public func syncVideoFrame(_ localFrame: Int) {
        mediaSyncing.updateVideoFramesForScrub(sceneFrameIndex: clampedLocalFrame(localFrame))
    }

    /// Syncs video frames for playback tick (gated to video frame rate).
    /// Legacy wrapper: uses local budget policy. For engine-owned budget use budget-aware variant.
    public func syncPlaybackTick(_ localFrame: Int) {
        mediaSyncing.updateVideoFramesForPlayback(sceneFrameIndex: clampedLocalFrame(localFrame))
    }

    /// Starts video playback at the given local frame.
    /// Legacy wrapper: uses local budget policy. For engine-owned budget use budget-aware variant.
    public func startPlayback(at localFrame: Int) {
        mediaSyncing.startVideoPlayback(sceneFrameIndex: clampedLocalFrame(localFrame))
    }

    /// Pauses playback.
    public func pause() {
        userMediaService.stopVideoPlayback()
    }

    /// TT-03 Completion: Deactivates playback while preserving textures (hold-last).
    ///
    /// Used when runtime transitions from active to warm state.
    /// Unlike `pause()`, this does NOT flush textures - it keeps the last frame visible.
    ///
    /// Contract:
    /// - Stops all active video decoders
    /// - Preserves last textures (hold-last semantics)
    /// - Runtime remains resident and ready for quick reactivation
    func deactivatePlaybackPreservingTextures() {
        mediaSyncing.stopVideoPlaybackPreservingTextures()
    }

    // MARK: - TT-03 Budget-Aware Playback

    /// Returns sorted playback candidates for budget allocation.
    /// Used by engine to collect candidates across scenes for global priority ordering.
    ///
    /// - Parameter localFrame: Local frame for priority calculation (clamped to valid range)
    /// - Returns: Sorted candidates (visible first, then area desc, zIndex desc, blockId asc)
    func playbackCandidates(at localFrame: Int) -> [PlaybackVideoCandidate] {
        mediaSyncing.playbackCandidates(sceneFrameIndex: clampedLocalFrame(localFrame))
    }

    /// Starts video playback for granted blocks only (engine-owned budget).
    ///
    /// - Parameters:
    ///   - localFrame: Local frame to sync to (clamped to valid range)
    ///   - grantedBlockIds: Set of block IDs that have been granted decoder slots by engine
    func startPlayback(at localFrame: Int, grantedBlockIds: Set<String>) {
        mediaSyncing.startVideoPlayback(
            sceneFrameIndex: clampedLocalFrame(localFrame),
            grantedBlockIds: grantedBlockIds
        )
    }

    /// Syncs video frames for playback tick with engine-owned budget.
    ///
    /// - Parameters:
    ///   - localFrame: Local frame for sync (clamped to valid range)
    ///   - grantedBlockIds: Set of block IDs that have been granted decoder slots by engine
    func syncPlaybackTick(_ localFrame: Int, grantedBlockIds: Set<String>) {
        mediaSyncing.updateVideoFramesForPlayback(
            sceneFrameIndex: clampedLocalFrame(localFrame),
            grantedBlockIds: grantedBlockIds
        )
    }

    // MARK: - Rendering

    /// Returns render commands for the given local frame.
    /// - Parameters:
    ///   - localFrame: Frame index within this scene.
    ///   - mode: Template mode (preview or edit).
    /// - Returns: Render commands.
    public func renderCommands(localFrame: Int, mode: TemplateMode) -> [RenderCommand] {
        scenePlayer.renderCommands(mode: mode, sceneFrameIndex: clampedLocalFrame(localFrame))
    }

    /// Creates scene render context for this instance.
    /// - Parameter localFrame: Frame index within this scene.
    /// - Returns: Scene render context with clamped localFrame for hold-last-frame semantics.
    public func makeRenderContext(localFrame: Int) -> SceneRenderContext {
        let clamped = clampedLocalFrame(localFrame)
        return SceneRenderContext(
            commands: renderCommands(localFrame: clamped, mode: .preview),
            textureProvider: layeredTextureProvider,
            pathRegistry: resources.pathRegistry,
            assetSizes: resources.assetSizes,
            localFrame: clamped,
            canvasSize: resources.canvasSize,
            sceneInstanceId: sceneInstanceId
        )
    }
}
