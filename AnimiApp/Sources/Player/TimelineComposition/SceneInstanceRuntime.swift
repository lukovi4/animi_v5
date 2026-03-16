import Foundation
import Metal
import UIKit
import TVECore

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

    // MARK: - State

    /// Readiness state for scene rendering.
    public enum ReadinessState: Equatable, Sendable {
        case notReady
        case ready
        case failed(reason: String)
        case timedOut
    }

    /// Current readiness state.
    public private(set) var readinessState: ReadinessState = .notReady

    /// Convenience: whether this instance is ready for rendering.
    public var isReady: Bool {
        readinessState == .ready
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

    // MARK: - State Application

    /// Resets runtime state before applying new state.
    /// Clears all overrides to ensure clean re-application.
    public func resetState() {
        // Reset ScenePlayer state
        scenePlayer.resetForNewInstance()

        // Clear UserMediaService
        userMediaService.clearAll()

        // Clear applied state
        appliedState = nil
        readinessState = .notReady

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
    public func reloadState(_ state: SceneState) async {
        resetState()
        await applyState(state)
        await prepareForPlayback()
    }

    // MARK: - Playback

    /// Prepares instance for playback.
    /// Warms video providers and syncs paused frame for prewarmed incoming scenes.
    /// Waits for scene to be fully ready (provider + poster injected + not failed).
    public func prepareForPlayback() async {
        // Sync video frames to frame 0 for prewarmed incoming scene
        // This ensures first transition frame is ready
        userMediaService.updateVideoFramesForScrub(sceneFrameIndex: 0)

        // Wait for scene-level readiness (all setup tasks complete, all textures injected)
        let result = await waitForSceneMediaReady()

        switch result {
        case .ready:
            readinessState = .ready
            #if DEBUG
            print("[SceneInstanceRuntime] Ready for playback: \(sceneInstanceId)")
            #endif

        case .failed(let reason):
            readinessState = .failed(reason: reason)
            #if DEBUG
            print("[SceneInstanceRuntime] Failed to prepare: \(sceneInstanceId) - \(reason)")
            #endif

        case .timedOut:
            readinessState = .timedOut
            #if DEBUG
            print("[SceneInstanceRuntime] Timed out preparing: \(sceneInstanceId)")
            #endif
        }
    }

    /// Result of waiting for scene media readiness.
    private enum WaitResult {
        case ready
        case failed(String)
        case timedOut
    }

    /// Waits for all scene media to be ready.
    /// Returns `.ready` when all setup tasks complete and all media ready.
    /// Returns `.failed` if any media restore failed (photo, video, or unsupported assignment).
    /// Returns `.timedOut` after max wait exceeded.
    private func waitForSceneMediaReady() async -> WaitResult {
        // Poll with short interval until scene is ready
        // Max wait: 5 seconds to prevent infinite hang
        let maxWaitMs = 5000
        let pollIntervalMs: UInt64 = 50
        var elapsed = 0

        while !userMediaService.isSceneMediaReady && elapsed < maxWaitMs {
            // Check for failures early - no point waiting if already failed
            if userMediaService.hasFailedMedia {
                #if DEBUG
                print("[SceneInstanceRuntime] Waited \(elapsed)ms, detected failed media")
                #endif
                return .failed("Media restore failed")
            }

            try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
            elapsed += Int(pollIntervalMs)
        }

        #if DEBUG
        if elapsed > 0 {
            print("[SceneInstanceRuntime] Waited \(elapsed)ms for scene media ready")
        }
        #endif

        // Final state check
        if userMediaService.hasFailedMedia {
            return .failed("Media restore failed")
        }

        if userMediaService.isSceneMediaReady {
            return .ready
        }

        return .timedOut
    }

    /// Syncs video frames to specific local frame (for scrubbing).
    public func syncVideoFrame(_ localFrame: Int) {
        userMediaService.updateVideoFramesForScrub(sceneFrameIndex: localFrame)
    }

    /// Syncs video frames for playback tick (gated to video frame rate).
    public func syncPlaybackTick(_ localFrame: Int) {
        userMediaService.updateVideoFramesForPlayback(sceneFrameIndex: localFrame)
    }

    /// PR-G: Starts video playback at the given local frame.
    /// Resets tick counter so first tick fires immediately, starts visible providers.
    public func startPlayback(at localFrame: Int) {
        userMediaService.startVideoPlayback(sceneFrameIndex: localFrame)
    }

    /// Pauses playback.
    public func pause() {
        userMediaService.stopVideoPlayback()
    }

    // MARK: - Rendering

    /// Returns render commands for the given local frame.
    /// - Parameters:
    ///   - localFrame: Frame index within this scene.
    ///   - mode: Template mode (preview or edit).
    /// - Returns: Render commands.
    public func renderCommands(localFrame: Int, mode: TemplateMode) -> [RenderCommand] {
        scenePlayer.renderCommands(mode: mode, sceneFrameIndex: localFrame)
    }

    /// Creates scene render context for this instance.
    /// - Parameter localFrame: Frame index within this scene.
    /// - Returns: Scene render context.
    public func makeRenderContext(localFrame: Int) -> SceneRenderContext {
        SceneRenderContext(
            commands: renderCommands(localFrame: localFrame, mode: .preview),
            textureProvider: layeredTextureProvider,
            pathRegistry: resources.pathRegistry,
            assetSizes: resources.assetSizes,
            localFrame: localFrame,
            canvasSize: resources.canvasSize,
            sceneInstanceId: sceneInstanceId
        )
    }
}
