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
    func updateVideoStillFrames(sceneFrameIndex: Int, mediaFrameIndex: Int)
    func awaitPendingStillFrames() async
    func updateVideoFramesForPlayback(sceneFrameIndex: Int, mediaFrameIndex: Int)
    func startVideoPlayback(sceneFrameIndex: Int, mediaFrameIndex: Int)

    // MARK: Readiness APIs (TT-02)
    var isSceneMediaReady: Bool { get }
    var hasFailedMedia: Bool { get }

    // MARK: TT-03 Budget-Aware APIs
    func playbackCandidates(sceneFrameIndex: Int) -> [PlaybackVideoCandidate]
    func startVideoPlayback(sceneFrameIndex: Int, mediaFrameIndex: Int, grantedBlockIds: Set<String>, hostTime: CFTimeInterval?)
    func updateVideoFramesForPlayback(sceneFrameIndex: Int, mediaFrameIndex: Int, grantedBlockIds: Set<String>, hostTime: CFTimeInterval?)

    // MARK: TT-03 Completion: Soft-Stop for Warm Runtimes
    /// Stops all active video playback while preserving textures (hold-last).
    /// Used when runtime transitions from active to warm state.
    /// - Does NOT clear textures (hold-last semantics)
    /// - Clears activeVideoBlockIds
    /// - Does NOT affect still/readiness behavior
    func stopVideoPlaybackPreservingTextures()
}

extension UserMediaService: SceneMediaSyncing {}

// MARK: - Stub Media Locator (Test Default)

/// Minimal no-op `ProjectMediaLocator` used as the default for test inits of
/// `SceneInstanceRuntime`. Throws on resolution so any accidental production
/// use is loud.
struct StubProjectMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        throw NSError(
            domain: "StubProjectMediaLocator",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "StubProjectMediaLocator must not be used in production paths"]
        )
    }
}

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

    /// Registry-backed media locator. Used to pre-resolve `MediaRef` → `URL`
    /// into a `ResolvedMediaMap` before entering the synchronous apply path.
    /// The locator holds no current-project state; the registry snapshot is
    /// passed per-call from `applyState(_:assetRegistry:)`.
    private let mediaLocator: any ProjectMediaLocator

    /// Diagnostics sink for runtime events (test-only, nil in production).
    internal var runtimeDiagnosticsSink: RuntimeDiagnosticsSink?

    /// PR4: Called when runtime state changes after async media load (placement re-resolved).
    /// Engine wires this to trigger timeline frame refresh.
    public var onNeedsRedraw: (() -> Void)?

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
    /// Last applied scene state. `internal(set)` for engine fast-path sync.
    public internal(set) var appliedState: SceneState?

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
        commandQueue: MTLCommandQueue,
        mediaLocator: any ProjectMediaLocator
    ) {
        self.sceneInstanceId = sceneInstanceId
        self.sceneTypeId = resources.sceneTypeId
        self.resources = resources
        self.injectedMediaSyncing = nil
        self.timingConfig = .production
        self.mediaLocator = mediaLocator

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

        // PR4: Re-resolve placement after async media load with actual dimensions
        setupMediaReadyHook()

        #if DEBUG
        MemoryDiagnostics.increment("SceneInstanceRuntime")
        MemoryDiagnostics.event("SceneInstanceRuntime.init", "obj=\(ObjectIdentifier(self).hashValue) id=\(sceneInstanceId) type=\(sceneTypeId)")
        #endif
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
        timingConfig: PreparationTimingConfig = .production,
        mediaLocator: any ProjectMediaLocator = StubProjectMediaLocator()
    ) {
        self.sceneInstanceId = sceneInstanceId
        self.sceneTypeId = resources.sceneTypeId
        self.resources = resources
        self.injectedMediaSyncing = mediaSyncing
        self.timingConfig = timingConfig
        self.mediaLocator = mediaLocator

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

        // PR4: Re-resolve placement after async media load with actual dimensions
        setupMediaReadyHook()

        #if DEBUG
        MemoryDiagnostics.increment("SceneInstanceRuntime")
        MemoryDiagnostics.event("SceneInstanceRuntime.init", "obj=\(ObjectIdentifier(self).hashValue) id=\(sceneInstanceId) type=\(sceneTypeId)")
        #endif
    }

    #if DEBUG
    func debugFlushTextureCaches() {
        userMediaService.debugFlushAllTextureCaches()
    }
    #endif

    deinit {
        #if DEBUG
        MemoryDiagnostics.decrement("SceneInstanceRuntime")
        MemoryDiagnostics.event("SceneInstanceRuntime.deinit", "obj=\(ObjectIdentifier(self).hashValue) id=\(sceneInstanceId)")
        #endif
    }

    // MARK: - PR4: Media Ready Hook

    /// Wires `onMediaReady` to re-resolve placement with actual media dimensions.
    private func setupMediaReadyHook() {
        userMediaService.onMediaReady = { [weak self] blockId in
            self?.handleMediaReady(blockId: blockId)
        }
    }

    /// Re-resolves placement for a block after its media finishes loading.
    /// URL-free fast path — uses `FastPathDependencies`.
    private func handleMediaReady(blockId: String) {
        guard let placement = appliedState?.mediaSlotsByBlockId?[blockId]?.asset.placement else { return }

        let deps = SceneRuntimeStateApplier.FastPathDependencies(
            scenePlayer: scenePlayer,
            userMediaService: userMediaService
        )
        SceneRuntimeStateApplier.applyPlacementChange(blockId: blockId, placement: placement, deps: deps)
        onNeedsRedraw?()
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
        MemoryDiagnostics.event("SceneInstanceRuntime.resetState", "obj=\(ObjectIdentifier(self).hashValue) id=\(sceneInstanceId)")
        #endif
    }

    /// Applies scene state to this instance.
    /// For full reload, call resetState() first.
    ///
    /// - Parameters:
    ///   - state: Scene state with variants, transforms, toggles, media assignments.
    ///   - assetRegistry: Registry snapshot used to pre-resolve `MediaRef` → `URL`
    ///     via the injected `mediaLocator`. Passed explicitly by the caller; the
    ///     runtime holds no current-project state. Defaults to an empty registry
    ///     so tests that don't exercise media resolution can keep calling the
    ///     one-argument form.
    public func applyState(_ state: SceneState, assetRegistry: ProjectAssetRegistry = ProjectAssetRegistry()) async {
        appliedState = state

        // Pre-resolve media URLs on the async path so the synchronous applier
        // never has to touch a locator / file store.
        let resolved = await ResolvedMediaMapBuilder.build(
            slots: state.mediaSlotsByBlockId,
            locator: mediaLocator,
            registry: assetRegistry
        )

        let deps = SceneRuntimeStateApplier.RestoreDependencies(
            scenePlayer: scenePlayer,
            userMediaService: userMediaService,
            resolvedMedia: resolved
        )
        let restoredCount = SceneRuntimeStateApplier.apply(state, deps: deps)
        runtimeDiagnosticsSink?.receive(.mediaRestore(instanceId: sceneInstanceId, restoredCount: restoredCount))

        #if DEBUG
        MemoryDiagnostics.event("SceneInstanceRuntime.applyState", "obj=\(ObjectIdentifier(self).hashValue) id=\(sceneInstanceId) restored=\(restoredCount)")
        #endif
    }

    /// Reloads state from scratch (reset + apply).
    /// Use this after undo/redo or when state needs full refresh.
    /// TT-02: No auto-prepare — caller controls readiness via startPreparingForPresentation.
    public func reloadState(_ state: SceneState, assetRegistry: ProjectAssetRegistry = ProjectAssetRegistry()) async {
        resetState()  // Sets readinessState = .created, cancels preparationTask
        await applyState(state, assetRegistry: assetRegistry)
        // NO auto-prepare
    }

    // MARK: - Video Selection Fast Path

    /// Fast-path: applies video selection without full reload.
    /// Defensive: only updates existing video slots, no-ops for missing/photo slots.
    /// Throws if UMS validation fails; appliedState unchanged on throw.
    public func applyPersistedVideoSelection(blockId: String, _ selection: PersistedVideoSelection) throws {
        // Defensive: only update existing video slot in appliedState
        guard let state = appliedState,
              let slots = state.mediaSlotsByBlockId,
              let slot = slots[blockId],
              slot.mediaRef.mediaKind == .video else {
            return // no-op for missing/photo slots
        }
        // Delegate to UMS (validates, throws on failure)
        try userMediaService.applyPersistedVideoSelection(blockId: blockId, selection)
        // Update appliedState cache only after successful UMS apply
        var mutableState = state
        var mutableSlots = slots
        var mutableSlot = slot
        mutableSlot.videoWindow = selection
        mutableSlots[blockId] = mutableSlot
        mutableState.mediaSlotsByBlockId = mutableSlots
        appliedState = mutableState
    }

    // MARK: - TT-02: Readiness State Machine

    /// TT-02: Internal helper to sync frozen frame with clamping.
    private func syncFrozenFrame(_ localFrame: Int) {
        let visibilityFrame = clampedLocalFrame(localFrame)
        let mediaFrame = max(localFrame, 0)
        mediaSyncing.updateVideoStillFrames(sceneFrameIndex: visibilityFrame, mediaFrameIndex: mediaFrame)
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
        #if DEBUG
        MemoryDiagnostics.event("SceneInstanceRuntime.prepare", "obj=\(ObjectIdentifier(self).hashValue) id=\(sceneInstanceId) frame=\(localFrame)")
        #endif
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
        runtimeDiagnosticsSink?.receive(.instancePrepareStarted(instanceId: sceneInstanceId, targetFrame: targetFrame))

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
            // PR3: Exit immediately on task cancellation (teardown path)
            guard !Task.isCancelled else { return }

            // Check for external state changes (reset, reload, cancel)
            guard case .preparing(let current) = readinessState, current == targetFrame else {
                return  // State changed externally, abort this loop
            }

            // Check for failures early
            if mediaSyncing.hasFailedMedia {
                readinessState = .failed(reason: "Media restore failed")
                runtimeDiagnosticsSink?.receive(.instancePrepareFailed(instanceId: sceneInstanceId, reason: "Media restore failed"))
                return
            }

            // Check if ready
            if mediaSyncing.isSceneMediaReady {
                // Final still sync before marking ready
                syncFrozenFrame(targetFrame)
                // PR2: Await still frame delivery so texture is on-screen before .ready
                await mediaSyncing.awaitPendingStillFrames()

                // PR3: Re-check cancellation after await
                guard !Task.isCancelled else { return }

                // Re-check state hasn't changed during await
                guard case .preparing(let current) = readinessState, current == targetFrame else {
                    return
                }

                readinessState = .ready(targetLocalFrame: targetFrame)
                onNeedsRedraw?()
                runtimeDiagnosticsSink?.receive(.instancePrepareCompleted(instanceId: sceneInstanceId, targetFrame: targetFrame))
                #if DEBUG
                print("[SceneInstanceRuntime] Ready for presentation at frame \(targetFrame): \(sceneInstanceId)")
                #endif
                return
            }

            try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
            // PR3: Check cancellation after sleep (exit fast on teardown)
            guard !Task.isCancelled else { return }
            elapsed += Int(pollIntervalMs)

            // Re-sync frozen frame during poll
            syncFrozenFrame(targetFrame)
        }

        // Timeout
        readinessState = .timedOut(targetLocalFrame: targetFrame)
        runtimeDiagnosticsSink?.receive(.instancePrepareFailed(instanceId: sceneInstanceId, reason: "Timed out"))
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
            // PR3: Exit on cancellation (teardown path)
            guard !Task.isCancelled else { return readinessState }

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
        let visibilityFrame = clampedLocalFrame(localFrame)
        let mediaFrame = max(localFrame, 0)
        mediaSyncing.updateVideoStillFrames(sceneFrameIndex: visibilityFrame, mediaFrameIndex: mediaFrame)
    }

    /// Syncs video frames for playback tick (gated to video frame rate).
    /// Legacy wrapper: uses local budget policy. For engine-owned budget use budget-aware variant.
    public func syncPlaybackTick(_ localFrame: Int) {
        let visibilityFrame = clampedLocalFrame(localFrame)
        let mediaFrame = max(localFrame, 0)
        mediaSyncing.updateVideoFramesForPlayback(sceneFrameIndex: visibilityFrame, mediaFrameIndex: mediaFrame)
    }

    /// Starts video playback at the given local frame.
    /// Legacy wrapper: uses local budget policy. For engine-owned budget use budget-aware variant.
    public func startPlayback(at localFrame: Int) {
        let visibilityFrame = clampedLocalFrame(localFrame)
        let mediaFrame = max(localFrame, 0)
        mediaSyncing.startVideoPlayback(sceneFrameIndex: visibilityFrame, mediaFrameIndex: mediaFrame)
    }

    /// Pauses playback.
    public func pause() {
        userMediaService.stopVideoPlayback()
    }

    /// Releases all preview resources (video providers, setup tasks).
    /// Called on editor close and export enter to ensure GPU memory is freed.
    /// Transitions readinessState to terminal so any pending waitUntilReady returns immediately.
    /// Async: drains in-flight setup tasks to guarantee no retained providers after return.
    func releasePreviewResources() async {
        preparationTask?.cancel()
        preparationTask = nil
        // Move to terminal state so waitUntilReadyForPresentation exits its poll loop
        if case .preparing = readinessState {
            readinessState = .failed(reason: "released")
        }
        pause()
        await userMediaService.releasePreviewResources()
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
    ///   - hostTime: Host time from transport (nil for legacy callers)
    func startPlayback(at localFrame: Int, grantedBlockIds: Set<String>, hostTime: CFTimeInterval? = nil) {
        let visibilityFrame = clampedLocalFrame(localFrame)
        let mediaFrame = max(localFrame, 0)
        mediaSyncing.startVideoPlayback(
            sceneFrameIndex: visibilityFrame,
            mediaFrameIndex: mediaFrame,
            grantedBlockIds: grantedBlockIds,
            hostTime: hostTime
        )
    }

    /// Syncs video frames for playback tick with engine-owned budget.
    ///
    /// - Parameters:
    ///   - localFrame: Local frame for sync (clamped to valid range)
    ///   - grantedBlockIds: Set of block IDs that have been granted decoder slots by engine
    ///   - hostTime: Host time from transport (nil for legacy callers)
    func syncPlaybackTick(_ localFrame: Int, grantedBlockIds: Set<String>, hostTime: CFTimeInterval? = nil) {
        let visibilityFrame = clampedLocalFrame(localFrame)
        let mediaFrame = max(localFrame, 0)
        mediaSyncing.updateVideoFramesForPlayback(
            sceneFrameIndex: visibilityFrame,
            mediaFrameIndex: mediaFrame,
            grantedBlockIds: grantedBlockIds,
            hostTime: hostTime
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
