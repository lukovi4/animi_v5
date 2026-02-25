import Foundation
import TVECore

// MARK: - Timeline Playback Coordinator (Release v1)

/// Coordinates playback across multiple scenes in the timeline.
/// Handles scene transitions, lazy loading, and local frame calculation.
/// Implements hold (clamp to last frame) and cut behavior.
@MainActor
public final class TimelinePlaybackCoordinator {

    // MARK: - Types

    /// Loaded scene data for playback.
    public struct LoadedScene {
        public let sceneTypeId: String
        public let player: ScenePlayer
        public let compiled: CompiledScene
        public let provider: ScenePackageTextureProvider
        public let resolver: CompositeAssetResolver
    }

    /// Scene info for time calculation.
    public struct SceneTimeInfo {
        public let sceneInstanceId: UUID
        public let sceneTypeId: String
        public let startUs: TimeUs
        public let durationUs: TimeUs
        public let baseDurationUs: TimeUs // From library, for hold calculation
    }

    // MARK: - State

    /// Currently loaded scene (lazy loaded).
    public private(set) var currentLoadedScene: LoadedScene?

    /// Current scene type ID being displayed.
    public private(set) var currentSceneTypeId: String?

    /// Current scene instance ID (PR9: for per-instance state tracking).
    public private(set) var currentSceneInstanceId: UUID?

    /// Current local frame index (within active scene).
    public private(set) var currentLocalFrame: Int = 0

    /// Scene library snapshot for lookups.
    private var sceneLibrary: SceneLibrarySnapshot?

    /// Template FPS for frame calculations.
    public private(set) var fps: Int = 30

    /// Microseconds per frame.
    public var frameDurationUs: TimeUs { TimeUs(1_000_000 / fps) }

    /// Scene timeline info (precomputed from store).
    private var sceneTimeline: [SceneTimeInfo] = []

    /// Generation counter for race protection in async operations.
    /// Increments only when target scene changes; stale requests don't modify state.
    private var requestGeneration: Int = 0

    /// Playhead generation counter for frame write protection.
    /// Increments on every setGlobalTimeUs call; prevents stale frame writes after re-entrancy.
    private var playheadGeneration: Int = 0

    /// Scene type ID currently being loaded (to avoid load starvation).
    private var pendingSceneTypeId: String?

    /// Task currently loading a scene (to reuse if same scene requested).
    private var pendingLoadTask: Task<Void, Never>?

    // MARK: - Callbacks

    /// Called when scene load completes (for UI to update).
    public var onSceneLoaded: ((LoadedScene) -> Void)?

    /// Called when scene load fails.
    public var onSceneLoadFailed: ((Error) -> Void)?

    /// Called when active scene instance changes (PR9: for per-instance state apply).
    /// Fires on every instance change, even if sceneTypeId is the same.
    public var onActiveSceneChanged: ((SceneTimeInfo) -> Void)?

    // MARK: - Dependencies

    /// Scene loader closure (injected, performs async load).
    private var loadSceneType: ((String) async throws -> LoadedScene)?

    // MARK: - Initialization

    public init() {}

    /// Configures the coordinator with dependencies.
    /// - Parameters:
    ///   - sceneLibrary: Scene library snapshot for baseDurationUs lookups
    ///   - fps: Template frame rate
    ///   - loadSceneType: Closure to load a scene type by ID
    public func configure(
        sceneLibrary: SceneLibrarySnapshot,
        fps: Int,
        loadSceneType: @escaping (String) async throws -> LoadedScene
    ) {
        self.sceneLibrary = sceneLibrary
        self.fps = fps
        self.loadSceneType = loadSceneType
    }

    // MARK: - Timeline Sync

    /// Updates scene timeline from store state.
    /// Call this when timeline changes (onTimelineChanged).
    public func updateSceneTimeline(from state: EditorState) {
        var timeline: [SceneTimeInfo] = []
        var runningStartUs: TimeUs = 0

        for item in state.sceneItems {
            guard let payload = state.canonicalTimeline.payloads[item.payloadId],
                  case .scene(let scenePayload) = payload else {
                continue
            }

            let baseDurationUs = sceneLibrary?.scene(byId: scenePayload.sceneTypeId)?.baseDurationUs ?? item.durationUs

            timeline.append(SceneTimeInfo(
                sceneInstanceId: item.id,
                sceneTypeId: scenePayload.sceneTypeId,
                startUs: runningStartUs,
                durationUs: item.durationUs,
                baseDurationUs: baseDurationUs
            ))

            runningStartUs += item.durationUs
        }

        sceneTimeline = timeline
    }

    // MARK: - Playback Position

    /// Sets global time and ensures the correct scene is loaded.
    /// Returns the local frame index for the active scene.
    /// Race-protected: only invalidates when target scene changes (prevents load starvation).
    /// - Parameter globalTimeUs: Global playhead position in microseconds
    /// - Returns: Local frame index within active scene (clamped for hold)
    @discardableResult
    public func setGlobalTimeUs(_ globalTimeUs: TimeUs) async -> Int {
        // P0 fix: Capture playhead generation to detect stale calls after re-entrancy
        playheadGeneration += 1
        let g = playheadGeneration

        guard let activeScene = findActiveScene(at: globalTimeUs) else {
            pendingSceneTypeId = nil
            pendingLoadTask?.cancel()
            pendingLoadTask = nil
            currentSceneInstanceId = nil
            currentLocalFrame = 0
            return 0
        }

        // PR9: Check instance change BEFORE sceneType check
        // This ensures VC knows which instance is active even if scene is still loading
        if activeScene.sceneInstanceId != currentSceneInstanceId {
            currentSceneInstanceId = activeScene.sceneInstanceId
            onActiveSceneChanged?(activeScene)
        }

        let targetSceneTypeId = activeScene.sceneTypeId

        // Load scene if needed
        if currentSceneTypeId != targetSceneTypeId {
            // Check if we're already loading this scene
            if pendingSceneTypeId == targetSceneTypeId, let existingTask = pendingLoadTask {
                // Same scene already loading - wait for it (don't invalidate)
                await existingTask.value
                // P0 fix: Check if this call is still the latest
                guard g == playheadGeneration else { return currentLocalFrame }

                // P0-1 fix: Task finished - clear pending state
                if pendingSceneTypeId == targetSceneTypeId {
                    pendingSceneTypeId = nil
                    pendingLoadTask = nil
                }

                // P0-1 fix: If scene didn't become current (error/cancelled), return
                // Next tick will retry via the "else" branch
                guard currentSceneTypeId == targetSceneTypeId else {
                    return currentLocalFrame
                }
            } else {
                // Different scene - invalidate previous load and start new one
                requestGeneration += 1
                pendingSceneTypeId = targetSceneTypeId
                pendingLoadTask?.cancel()

                let generation = requestGeneration
                pendingLoadTask = Task {
                    await loadScene(targetSceneTypeId)
                }
                await pendingLoadTask?.value

                // Check if this load is still relevant
                guard generation == requestGeneration else {
                    #if DEBUG
                    print("[PlaybackCoordinator] Discarding stale scene load (gen \(generation) < \(requestGeneration))")
                    #endif
                    return currentLocalFrame
                }

                // P0 fix: Check if this call is still the latest
                guard g == playheadGeneration else { return currentLocalFrame }

                // Clear pending state after successful load
                pendingSceneTypeId = nil
                pendingLoadTask = nil
            }
        }

        // P0 fix: Final check before frame write
        guard g == playheadGeneration else { return currentLocalFrame }

        // Calculate and store local frame
        currentLocalFrame = computeLocalFrameForScene(activeScene, globalTimeUs: globalTimeUs)

        return currentLocalFrame
    }

    /// Synchronous frame calculation and update (without async loading).
    /// Use for preview when scene is already loaded.
    /// - Parameter globalTimeUs: Global playhead position in microseconds
    /// - Returns: Local frame index, or nil if no active scene
    public func syncSetGlobalTimeUs(_ globalTimeUs: TimeUs) -> Int? {
        guard let activeScene = findActiveScene(at: globalTimeUs) else {
            currentSceneInstanceId = nil
            currentLocalFrame = 0
            return nil
        }

        // PR9: Check instance change BEFORE sceneType check
        if activeScene.sceneInstanceId != currentSceneInstanceId {
            currentSceneInstanceId = activeScene.sceneInstanceId
            onActiveSceneChanged?(activeScene)
        }

        // Check if scene switch needed
        if currentSceneTypeId != activeScene.sceneTypeId {
            // Different scene - need async load, return nil
            return nil
        }

        // P0 fix: Invalidate pending load if we're back in current scene
        // Prevents stale load from switching scene after user returned
        if pendingSceneTypeId != nil && pendingSceneTypeId != currentSceneTypeId {
            requestGeneration += 1
            pendingLoadTask?.cancel()
            pendingLoadTask = nil
            pendingSceneTypeId = nil
        }

        // Same scene - just update frame
        currentLocalFrame = computeLocalFrameForScene(activeScene, globalTimeUs: globalTimeUs)
        return currentLocalFrame
    }

    /// Computes local frame for a given scene at global time.
    /// Implements hold behavior (clamp to last animation frame).
    public func computeLocalFrame(globalTimeUs: TimeUs) -> (sceneTypeId: String, frame: Int)? {
        guard let activeScene = findActiveScene(at: globalTimeUs) else {
            return nil
        }

        let frame = computeLocalFrameForScene(activeScene, globalTimeUs: globalTimeUs)
        return (activeScene.sceneTypeId, frame)
    }

    // MARK: - Render

    /// Returns render commands for current frame.
    /// Uses the stored currentLocalFrame from last setGlobalTimeUs call.
    /// - Parameter mode: Template mode (.preview or .edit)
    /// - Returns: Render commands or nil if no scene loaded
    public func currentRenderCommands(mode: TemplateMode) -> [RenderCommand]? {
        guard let scene = currentLoadedScene else { return nil }
        return scene.player.renderCommands(mode: mode, sceneFrameIndex: currentLocalFrame)
    }

    /// Returns current scene player.
    public var currentScenePlayer: ScenePlayer? {
        currentLoadedScene?.player
    }

    /// Returns current compiled scene.
    public var currentCompiledScene: CompiledScene? {
        currentLoadedScene?.compiled
    }

    /// Returns current texture provider.
    public var currentTextureProvider: ScenePackageTextureProvider? {
        currentLoadedScene?.provider
    }

    /// Returns current resolver.
    public var currentResolver: CompositeAssetResolver? {
        currentLoadedScene?.resolver
    }

    /// Returns total frames for animation duration (from baseDurationUs).
    /// PR9 fix: Uses currentSceneInstanceId to handle duplicate sceneTypeIds correctly.
    public var currentAnimationTotalFrames: Int {
        guard let instanceId = currentSceneInstanceId,
              let info = sceneTimeline.first(where: { $0.sceneInstanceId == instanceId }) else {
            return 0
        }
        return timeUsToFrame(info.baseDurationUs)
    }

    // MARK: - Scene Loading

    /// Bootstraps the coordinator with an already-loaded scene.
    /// Use this to prevent double-loading when the first scene was loaded outside the coordinator.
    /// - Parameters:
    ///   - sceneTypeId: Scene type ID that was loaded
    ///   - player: Already-created ScenePlayer
    ///   - compiled: Already-compiled scene
    ///   - provider: Already-created texture provider
    ///   - resolver: Already-created asset resolver
    public func bootstrap(
        sceneTypeId: String,
        player: ScenePlayer,
        compiled: CompiledScene,
        provider: ScenePackageTextureProvider,
        resolver: CompositeAssetResolver
    ) {
        // P1-2 fix: Clear any pending state for idempotent/safe bootstrap
        pendingSceneTypeId = nil
        pendingLoadTask?.cancel()
        pendingLoadTask = nil
        requestGeneration = 0
        playheadGeneration = 0

        currentLoadedScene = LoadedScene(
            sceneTypeId: sceneTypeId,
            player: player,
            compiled: compiled,
            provider: provider,
            resolver: resolver
        )
        currentSceneTypeId = sceneTypeId
        // PR9: currentSceneInstanceId will be set by first setGlobalTimeUs call
        currentSceneInstanceId = nil
        currentLocalFrame = 0
    }

    /// Preloads a specific scene type (for initial load).
    /// - Parameter sceneTypeId: Scene type ID to load
    public func preloadScene(_ sceneTypeId: String) async {
        await loadScene(sceneTypeId)
    }

    /// Returns first scene type ID from timeline.
    public var firstSceneTypeId: String? {
        sceneTimeline.first?.sceneTypeId
    }

    // MARK: - Private

    private func findActiveScene(at globalTimeUs: TimeUs) -> SceneTimeInfo? {
        for scene in sceneTimeline {
            let sceneEndUs = scene.startUs + scene.durationUs
            if globalTimeUs >= scene.startUs && globalTimeUs < sceneEndUs {
                return scene
            }
        }
        // If past all scenes, return last scene (for hold)
        return sceneTimeline.last
    }

    private func computeLocalFrameForScene(_ scene: SceneTimeInfo, globalTimeUs: TimeUs) -> Int {
        // Calculate local time within scene
        let localTimeUs = globalTimeUs - scene.startUs

        // Calculate local frame
        let localFrame = timeUsToFrame(localTimeUs)

        // Calculate max frame based on animation duration (for hold)
        let animationFrames = timeUsToFrame(scene.baseDurationUs)
        let maxFrame = max(0, animationFrames - 1)

        // Hold: clamp to last animation frame if scene extends beyond
        return min(localFrame, maxFrame)
    }

    private func loadScene(_ sceneTypeId: String) async {
        guard let loader = loadSceneType else {
            #if DEBUG
            print("[PlaybackCoordinator] No scene loader configured")
            #endif
            return
        }

        // Capture generation before async work (for stale check after)
        let generationBeforeLoad = requestGeneration

        do {
            let loadedScene = try await loader(sceneTypeId)

            // Only apply result if this is still the latest request
            guard generationBeforeLoad == requestGeneration else {
                #if DEBUG
                print("[PlaybackCoordinator] Discarding stale load result for \(sceneTypeId) (gen \(generationBeforeLoad) < \(requestGeneration))")
                #endif
                return
            }

            currentLoadedScene = loadedScene
            currentSceneTypeId = sceneTypeId

            // PR9: onActiveSceneChanged is now called in setGlobalTimeUs on instance change
            // onSceneLoaded is called here only when .tve is actually loaded
            onSceneLoaded?(loadedScene)

            #if DEBUG
            print("[PlaybackCoordinator] Loaded scene: \(sceneTypeId)")
            #endif
        } catch {
            // Only report error if this is still the latest request
            guard generationBeforeLoad == requestGeneration else { return }

            onSceneLoadFailed?(error)
            #if DEBUG
            print("[PlaybackCoordinator] Failed to load scene \(sceneTypeId): \(error)")
            #endif
        }
    }

    private func timeUsToFrame(_ timeUs: TimeUs) -> Int {
        guard frameDurationUs > 0 else { return 0 }
        return Int(timeUs / frameDurationUs)
    }
}
