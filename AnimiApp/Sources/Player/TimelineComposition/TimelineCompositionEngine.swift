import AVFoundation
import Foundation
import Metal
import TVECore
import os.log

// MARK: - Timeline Composition Engine

/// Engine for composing multi-scene timeline with transitions.
/// Manages scene resources, video budget, and frame resolution.
///
/// Replaces TimelinePlaybackCoordinator for timeline runtime path.
/// Scene Edit mode continues to use single-scene path.
@MainActor
public final class TimelineCompositionEngine {

    private static let logger = Logger(
        subsystem: "com.animi.app",
        category: "TimelineCompositionEngine"
    )

    // MARK: - Dependencies

    /// Timeline math for compressed positions and transitions.
    public private(set) var transitionMath: TimelineTransitionMath?

    /// Video budget coordinator.
    public let budgetCoordinator: GlobalVideoBudgetCoordinator

    /// Scene type resources cache (shared across instances of same type).
    public let resourcesCache: SceneTypeResourcesCache

    /// Metal device.
    public let device: MTLDevice

    /// Metal command queue.
    public let commandQueue: MTLCommandQueue

    /// Frame rate (v1: always 30).
    public let fps: Int

    /// Template-level canvas size (from SceneLibrarySnapshot.canvas).
    /// Source of truth for canvas - not derived from runtime.
    public private(set) var templateCanvas: CanvasConfig?

    // MARK: - State

    /// Current timeline.
    public private(set) var timeline: CanonicalTimeline?

    /// Scene states by instance ID.
    public private(set) var sceneStates: [UUID: SceneState] = [:]

    /// Current project asset registry snapshot.
    /// Updated by `setTimeline(...)`; passed into `SceneInstanceRuntime.applyState`
    /// so the runtime can pre-resolve `MediaRef` → `URL` via the injected locator.
    /// Stored here to match how `sceneStates` are already held; the engine does
    /// NOT subscribe to any global provider.
    public private(set) var currentAssetRegistry: ProjectAssetRegistry = ProjectAssetRegistry()

    /// Loaded scene runtimes by instance ID.
    internal var instanceRuntimes: [UUID: SceneInstanceRuntime] = [:]

    /// Generation counter for scrub cancellation.
    /// Incremented on each playhead change to invalidate stale async results.
    internal private(set) var scrubGeneration: UInt64 = 0

    /// TT-02: Factory for creating SceneInstanceRuntime. Non-optional.
    /// Public init provides production closure, internal init for tests.
    internal let runtimeFactory: (UUID, SceneTypeResourcesCache.Resources, MTLDevice, MTLCommandQueue) -> SceneInstanceRuntime

    /// Diagnostics sink for runtime events (test-only, nil in production).
    internal private(set) var runtimeDiagnosticsSink: RuntimeDiagnosticsSink?

    /// Diagnostics sink for render events (test-only, nil in production).
    internal private(set) var renderDiagnosticsSink: RenderDiagnosticsSink?

    /// PR4: Called when a timeline runtime needs a redraw (e.g., after async media placement re-resolve).
    /// EditorViewController wires this to `refreshCurrentTimelineFrame()`.
    public var onNeedsRedraw: (() -> Void)?

    /// Media locator for resolving MediaRef → URL in export path.
    private let mediaLocator: any ProjectMediaLocator

    /// PR10: Sticker provider for resolving sticker images. Set after init via setStickerProvider().
    private(set) var stickerProvider: StickerProviding?

    // MARK: - Internal Owners

    private var frameResolver: TimelineFrameResolver!
    private var residencyController: TimelineResidencyController!
    private var playbackSyncController: TimelinePlaybackSyncController!

    // MARK: - Init

    public init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        fps: Int = 30,
        maxActiveDecoders: Int = 3,
        mediaLocator: any ProjectMediaLocator
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.fps = fps
        self.mediaLocator = mediaLocator
        self.budgetCoordinator = GlobalVideoBudgetCoordinator(maxActiveDecoders: maxActiveDecoders)
        self.resourcesCache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        self.runtimeDiagnosticsSink = nil
        self.renderDiagnosticsSink = nil
        // Production factory: constructs per-instance runtime sharing the
        // injected registry-backed `mediaLocator`. No raw `FileProjectMediaStore`
        // construction; no current-project state held by the engine.
        let sharedLocator = mediaLocator
        self.runtimeFactory = { instanceId, resources, dev, queue in
            SceneInstanceRuntime(
                sceneInstanceId: instanceId,
                resources: resources,
                device: dev,
                commandQueue: queue,
                mediaLocator: sharedLocator
            )
        }
        self.frameResolver = TimelineFrameResolver(engine: self)
        self.residencyController = TimelineResidencyController(engine: self)
        self.playbackSyncController = TimelinePlaybackSyncController(engine: self)
    }

    /// TT-02: Internal init for tests with injected runtime factory.
    init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        fps: Int = 30,
        maxActiveDecoders: Int = 3,
        mediaLocator: any ProjectMediaLocator,
        resourcesCache: SceneTypeResourcesCache,
        runtimeFactory: @escaping (UUID, SceneTypeResourcesCache.Resources, MTLDevice, MTLCommandQueue) -> SceneInstanceRuntime,
        runtimeDiagnosticsSink: RuntimeDiagnosticsSink? = nil,
        renderDiagnosticsSink: RenderDiagnosticsSink? = nil
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.fps = fps
        self.mediaLocator = mediaLocator
        self.budgetCoordinator = GlobalVideoBudgetCoordinator(maxActiveDecoders: maxActiveDecoders)
        self.resourcesCache = resourcesCache
        self.runtimeFactory = runtimeFactory
        self.runtimeDiagnosticsSink = runtimeDiagnosticsSink
        self.renderDiagnosticsSink = renderDiagnosticsSink
        self.frameResolver = TimelineFrameResolver(engine: self)
        self.residencyController = TimelineResidencyController(engine: self)
        self.playbackSyncController = TimelinePlaybackSyncController(engine: self)
    }

    // MARK: - Configuration

    /// Sets the template canvas (from SceneLibrarySnapshot).
    /// Must be called before timeline export.
    public func setTemplateCanvas(_ canvas: CanvasConfig) {
        self.templateCanvas = canvas
    }

    /// PR10: Sets the sticker provider for sticker overlay resolution.
    public func setStickerProvider(_ provider: StickerProviding) {
        self.stickerProvider = provider
    }

    /// Sets the timeline, scene states, and asset registry snapshot.
    /// Call this when timeline changes (scene add/remove/reorder) or when the
    /// asset registry updates (new ingest, unregister, etc.).
    ///
    /// The engine threads `assetRegistry` into
    /// `SceneInstanceRuntime.applyState(_:assetRegistry:)` so that the runtime
    /// can pre-resolve media URLs without holding any current-project state.
    ///
    /// The parameter defaults to `.init()` (empty) so tests that don't exercise
    /// media resolution can keep calling the two-argument form. Production
    /// call sites in `EditorViewController` must pass the current draft's
    /// registry explicitly (`session.state?.draft.assetRegistry ?? .init()`).
    ///
    /// PR-C: Scene states are expected to be already hydrated at project-load time.
    public func setTimeline(
        _ timeline: CanonicalTimeline,
        sceneStates: [UUID: SceneState],
        assetRegistry: ProjectAssetRegistry = ProjectAssetRegistry()
    ) {
        let previousSceneIds = Set(self.timeline?.sceneItems.map(\.id) ?? [])
        let newSceneIds = Set(timeline.sceneItems.map(\.id))

        self.timeline = timeline

        self.sceneStates = sceneStates
        self.currentAssetRegistry = assetRegistry

        // Rebuild transition math
        self.transitionMath = TimelineTransitionMath(
            sceneItems: timeline.sceneItems,
            boundaryTransitions: timeline.boundaryTransitions,
            fps: fps
        )

        // Evict orphaned runtimes (scenes that were removed)
        let orphanedIds = previousSceneIds.subtracting(newSceneIds)
        for orphanId in orphanedIds {
            if let runtime = instanceRuntimes.removeValue(forKey: orphanId) {
                runtime.pause()
                #if DEBUG
                print("[TimelineCompositionEngine] Evicted orphaned runtime: \(orphanId)")
                #endif
            }
        }
    }

    /// Updates scene state for a specific instance.
    /// If runtime is already loaded, state is also re-applied to the runtime.
    public func updateSceneState(_ state: SceneState, for instanceId: UUID, assetRegistry: ProjectAssetRegistry) async {
        self.currentAssetRegistry = assetRegistry
        sceneStates[instanceId] = state

        // If runtime already loaded, re-apply state with fresh registry.
        if let runtime = instanceRuntimes[instanceId] {
            await runtime.reloadState(state, assetRegistry: currentAssetRegistry)
            #if DEBUG
            print("[TimelineCompositionEngine] Re-applied state to loaded runtime: \(instanceId)")
            #endif
        }
    }

    /// Fast-path: applies committed video selection to cached state and loaded runtime.
    /// Defensive: only updates existing video slots in cache, no-ops for missing/photo.
    /// Cache update is authoritative. Runtime fast-apply is best-effort.
    /// Does NOT call reloadState on the runtime.
    public func applyPersistedVideoSelection(
        _ selection: PersistedVideoSelection,
        blockId: String,
        for instanceId: UUID
    ) {
        // 1. Defensive authoritative cache update (only existing video slots)
        if var sceneState = sceneStates[instanceId],
           var slots = sceneState.mediaSlotsByBlockId,
           var slot = slots[blockId],
           slot.mediaRef.mediaKind == .video {
            slot.videoWindow = selection
            slots[blockId] = slot
            sceneState.mediaSlotsByBlockId = slots
            sceneStates[instanceId] = sceneState
        }
        // 2. Best-effort runtime fast-apply (failure does NOT roll back cache)
        if let runtime = instanceRuntimes[instanceId] {
            do {
                try runtime.applyPersistedVideoSelection(blockId: blockId, selection)
            } catch {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "DebugVideoPlaybackTrace") {
                    print("[VideoPlaybackTrace] engine.applySelection.failed instanceId=\(instanceId) blockId=\(blockId) selection=[\(String(format: "%.6f", selection.trimStart)),\(String(format: "%.6f", selection.trimEnd))] error=\(error)")
                }
                print("[Phase5] Engine runtime fast-apply failed (best-effort): \(error)")
                #endif
            }
        }
    }

    // MARK: - PR4: Fast-Path Updates

    /// Fast-path: applies placement change without full runtime reload.
    /// Updates cache and applies resolved transform to loaded runtime.
    public func applyPlacementChange(
        blockId: String,
        placement: MediaPlacementState,
        for instanceId: UUID
    ) {
        // Cache update
        if var sceneState = sceneStates[instanceId],
           var slots = sceneState.mediaSlotsByBlockId,
           var slot = slots[blockId] {
            slot.asset.placement = placement
            slots[blockId] = slot
            sceneState.mediaSlotsByBlockId = slots
            sceneStates[instanceId] = sceneState
        }
        // Best-effort runtime fast-apply + sync appliedState
        if let runtime = instanceRuntimes[instanceId] {
            // Sync appliedState so handleMediaReady reads fresh placement
            if var runtimeState = runtime.appliedState,
               var slots = runtimeState.mediaSlotsByBlockId,
               var slot = slots[blockId] {
                slot.asset.placement = placement
                slots[blockId] = slot
                runtimeState.mediaSlotsByBlockId = slots
                runtime.appliedState = runtimeState
            }
            // Placement is URL-free — fast path uses FastPathDependencies and
            // never touches the media locator or file store.
            let deps = SceneRuntimeStateApplier.FastPathDependencies(
                scenePlayer: runtime.scenePlayer,
                userMediaService: runtime.userMediaService
            )
            SceneRuntimeStateApplier.applyPlacementChange(blockId: blockId, placement: placement, deps: deps)
        }
    }

    /// Fast-path: applies visibility change without full runtime reload.
    public func applyVisibilityChange(
        blockId: String,
        visible: Bool,
        for instanceId: UUID
    ) {
        // Cache update
        if var sceneState = sceneStates[instanceId],
           var slots = sceneState.mediaSlotsByBlockId,
           var slot = slots[blockId] {
            slot.visibility = visible
            slots[blockId] = slot
            sceneState.mediaSlotsByBlockId = slots
            sceneStates[instanceId] = sceneState
        }
        // Best-effort runtime fast-apply
        if let runtime = instanceRuntimes[instanceId] {
            SceneRuntimeStateApplier.applyVisibilityChange(
                blockId: blockId, visible: visible, player: runtime.scenePlayer
            )
        }
    }

    /// Increments generation counter to invalidate stale async results.
    /// Call this when playhead changes to ensure fast scrub works correctly.
    public func invalidateScrub() {
        scrubGeneration &+= 1
    }

    /// Returns current scrub generation for validation.
    public var currentScrubGeneration: UInt64 {
        scrubGeneration
    }

    // MARK: - Frame Resolution

    /// Compressed duration in frames.
    public var compressedDurationFrames: Int {
        transitionMath?.compressedDurationFrames ?? 0
    }

    /// Compressed duration in microseconds.
    public var compressedDurationUs: TimeUs {
        TimeUs(compressedDurationFrames) * 1_000_000 / TimeUs(fps)
    }

    /// TT-02: Resolves render context for a compressed frame.
    /// - Parameters:
    ///   - compressedFrame: Frame index in compressed timeline.
    ///   - generation: Optional generation token to validate against (for scrub cancellation).
    ///   - policy: Resolution policy (.presentation or .export).
    /// - Returns: Resolution result (resolved, hold, staleGeneration, or failed).
    public func resolveFrame(
        _ compressedFrame: Int,
        generation: UInt64? = nil,
        policy: TimelineResolvePolicy = .presentation
    ) async -> TimelineFrameResolution {
        guard let math = transitionMath else {
            return .failed(.invalidTimeline)
        }

        // Check generation BEFORE any work
        if let gen = generation, gen != scrubGeneration {
            return .staleGeneration
        }

        // TT-03: Budget refresh for presentation policy only
        if policy == .presentation {
            residencyController.refreshBudgetWindow(compressedFrame: compressedFrame, math: math)
        }

        guard let mode = math.renderMode(for: compressedFrame) else {
            return .failed(.invalidTimeline)
        }

        switch mode {
        case .single(let sceneIndex, let localFrame):
            return await frameResolver.resolveSingleFrame(
                math: math,
                sceneIndex: sceneIndex,
                localFrame: localFrame,
                generation: generation,
                policy: policy
            )

        case .transition(let aIndex, let frameA, let bIndex, let frameB, let transition, let progress):
            return await frameResolver.resolveTransitionFrame(
                math: math,
                aIndex: aIndex, frameA: frameA,
                bIndex: bIndex, frameB: frameB,
                transition: transition,
                progress: progress,
                generation: generation,
                policy: policy
            )
        }
    }

    // MARK: - Playback Video Sync

    /// Syncs video frames for playback tick (called from displayLinkFired).
    public func syncPlaybackTick(_ compressedFrame: Int) {
        syncPlaybackTick(compressedFrame, hostTime: nil)
    }

    /// Host-time aware playback tick sync.
    public func syncPlaybackTick(_ compressedFrame: Int, hostTime: CFTimeInterval?) {
        guard let math = transitionMath,
              let mode = math.renderMode(for: compressedFrame) else { return }

        budgetCoordinator.update(transitionMath: math, compressedFrame: compressedFrame)
        residencyController.evictNonResidentRuntimes(math: math)

        let localFrames = residencyController.activePlaybackLocalFrames(math: math, mode: mode)
        let grants = residencyController.playbackBudgetGrants(math: math, mode: mode, localFramesByInstanceId: localFrames)
        playbackSyncController.applyPlaybackBudget(
            mode: mode, math: math, localFramesByInstanceId: localFrames,
            grants: grants, isStart: false, hostTime: hostTime
        )
    }

    /// Legacy wrapper without host time.
    public func startPlayback(at compressedFrame: Int) {
        startPlayback(at: compressedFrame, hostTime: nil)
    }

    /// Host-time aware playback start.
    public func startPlayback(at compressedFrame: Int, hostTime: CFTimeInterval?) {
        guard let math = transitionMath,
              let mode = math.renderMode(for: compressedFrame) else { return }

        budgetCoordinator.update(transitionMath: math, compressedFrame: compressedFrame)
        residencyController.evictNonResidentRuntimes(math: math)

        let localFrames = residencyController.activePlaybackLocalFrames(math: math, mode: mode)
        let grants = residencyController.playbackBudgetGrants(math: math, mode: mode, localFramesByInstanceId: localFrames)
        playbackSyncController.applyPlaybackBudget(
            mode: mode, math: math, localFramesByInstanceId: localFrames,
            grants: grants, isStart: true, hostTime: hostTime
        )
    }

    #if DEBUG
    func debugFlushAllTextureCaches() {
        for runtime in instanceRuntimes.values {
            runtime.debugFlushTextureCaches()
        }
    }
    #endif

    /// PR-G: Stops playback for all loaded runtimes.
    public func stopPlayback() {
        for runtime in instanceRuntimes.values {
            runtime.pause()
        }
    }

    // MARK: - Scene Query

    /// Returns scene instance ID at given compressed frame.
    public func sceneInstanceId(at compressedFrame: Int) -> UUID? {
        guard let math = transitionMath,
              let mapping = math.frameMapping(for: compressedFrame) else { return nil }
        guard mapping.sceneIndex < math.sceneItems.count else { return nil }
        return math.sceneItems[mapping.sceneIndex].id
    }

    /// Returns whether the given compressed frame is in a transition.
    public func isInTransition(at compressedFrame: Int) -> Bool {
        transitionMath?.transitionWindow(at: compressedFrame) != nil
    }

    /// Returns transition window at given compressed frame, if any.
    public func transitionWindow(at compressedFrame: Int) -> TimelineTransitionMath.TransitionWindow? {
        transitionMath?.transitionWindow(at: compressedFrame)
    }

    // MARK: - Resource Management

    /// TT-02: Prepares scene resources for playback.
    /// PHASE 1: Awaits exact readiness for active mode (single or both transition scenes).
    /// PHASE 2: Awaits warm-scene readiness at boundary-aligned frames.
    public func prepareForPlayback(startingAt compressedFrame: Int = 0) async {
        guard let math = transitionMath else { return }

        budgetCoordinator.update(transitionMath: math, compressedFrame: compressedFrame)

        guard let renderMode = math.renderMode(for: compressedFrame) else { return }

        // PHASE 1: Await exact readiness for active mode
        switch renderMode {
        case .single(let sceneIndex, let localFrame):
            guard sceneIndex < math.sceneItems.count else { return }
            let instanceId = math.sceneItems[sceneIndex].id
            if let runtime = await frameResolver.getOrCreateRuntime(for: instanceId) {
                _ = await runtime.waitUntilReadyForPresentation(at: localFrame)
            }

        case .transition(let aIndex, let frameA, let bIndex, let frameB, _, _):
            guard aIndex < math.sceneItems.count,
                  bIndex < math.sceneItems.count else { return }
            let instanceIdA = math.sceneItems[aIndex].id
            let instanceIdB = math.sceneItems[bIndex].id

            async let runtimeATask = frameResolver.getOrCreateRuntime(for: instanceIdA)
            async let runtimeBTask = frameResolver.getOrCreateRuntime(for: instanceIdB)

            let runtimeA = await runtimeATask
            let runtimeB = await runtimeBTask

            async let stateATask = runtimeA?.waitUntilReadyForPresentation(at: frameA)
            async let stateBTask = runtimeB?.waitUntilReadyForPresentation(at: frameB)

            _ = await stateATask
            _ = await stateBTask
        }

        // PHASE 2: Warm scenes
        let warmTargets = residencyController.warmPresentationTargets(math: math, mode: renderMode)
        let orderedWarmIds = budgetCoordinator.prioritizedInstances(
            from: budgetCoordinator.warmInstanceIds,
            sceneItems: math.sceneItems
        )
        for instanceId in orderedWarmIds {
            guard let targetFrame = warmTargets[instanceId] else { continue }
            if let runtime = await frameResolver.getOrCreateRuntime(for: instanceId) {
                _ = await runtime.waitUntilReadyForPresentation(at: targetFrame)
            }
        }

        // PHASE 3: Evict non-resident runtimes
        residencyController.evictNonResidentRuntimes(math: math)
    }

    /// Releases all preview resources from scene instance runtimes.
    /// - Parameter evictTypeCache: If true, also evicts the shared scene type resources cache.
    ///   Use `true` on editor close (everything goes), `false` on export (cache needed for restore).
    /// Async: drains in-flight setup tasks to guarantee no retained providers after return.
    func releasePreviewResources(evictTypeCache: Bool) async {
        #if DEBUG
        MemoryDiagnostics.event("TCEngine.releasePreview", "runtimes=\(instanceRuntimes.count) evictCache=\(evictTypeCache)")
        #endif
        // Snapshot and clear dictionary before any await to prevent mutation during iteration
        let runtimes = Array(instanceRuntimes.values)
        instanceRuntimes.removeAll()
        for runtime in runtimes {
            await runtime.releasePreviewResources()
        }
        if evictTypeCache {
            resourcesCache.evictAll()
        }
    }

    /// Releases all scene resources.
    public func releaseResources() async {
        await releasePreviewResources(evictTypeCache: false)
    }

    /// Releases scene runtimes for export — frees GPU memory from preview.
    ///
    /// Preserves `transitionMath` (needed for buildExportSession) and
    /// `sceneStates` (needed for mediaAssignments).
    public func releaseForExport() async {
        await releasePreviewResources(evictTypeCache: false)
    }

    /// Returns runtime for given instance ID, if loaded.
    public func runtime(for instanceId: UUID) -> SceneInstanceRuntime? {
        instanceRuntimes[instanceId]
    }

    /// Adds resources to cache manually (for preloading).
    public func addResourcesToCache(_ resources: SceneTypeResourcesCache.Resources) {
        resourcesCache.addToCache(resources)
    }

    /// Returns canvas size from template (source of truth).
    /// Does not depend on loaded runtimes.
    public var canvasSize: SizeD {
        guard let canvas = templateCanvas else {
            return .zero
        }
        return SizeD(width: Double(canvas.width), height: Double(canvas.height))
    }

    // MARK: - Test-Only Budget Probe

    /// Test-only snapshot of playback budget state.
    internal struct PlaybackBudgetSnapshot {
        let mode: TimelineTransitionMath.RenderMode
        let pinnedInstanceIds: Set<UUID>
        let warmInstanceIds: Set<UUID>
        let grantsByInstance: [UUID: Set<String>]
        let activeInstanceIdsUsedForGrantComputation: [UUID]
    }

    /// Test-only: returns a snapshot of the budget state at the given compressed frame
    /// without mutating any runtime state (no side effects on runtimes).
    /// - Parameter compressedFrame: Compressed timeline frame.
    /// - Returns: Budget snapshot, or nil if no timeline/math.
    internal func debugPlaybackBudgetSnapshot(at compressedFrame: Int) -> PlaybackBudgetSnapshot? {
        guard let math = transitionMath,
              let renderMode = math.renderMode(for: compressedFrame) else { return nil }

        budgetCoordinator.update(transitionMath: math, compressedFrame: compressedFrame)

        let localFrames = residencyController.activePlaybackLocalFrames(math: math, mode: renderMode)
        let grants = residencyController.playbackBudgetGrants(math: math, mode: renderMode, localFramesByInstanceId: localFrames)

        let activeIds = budgetCoordinator.prioritizedInstances(
            from: Set(
                localFrames.keys.filter {
                    budgetCoordinator.shouldHaveActiveDecoders(for: $0)
                }
            ),
            sceneItems: math.sceneItems
        )

        return PlaybackBudgetSnapshot(
            mode: renderMode,
            pinnedInstanceIds: budgetCoordinator.pinnedInstanceIds,
            warmInstanceIds: budgetCoordinator.warmInstanceIds,
            grantsByInstance: grants,
            activeInstanceIdsUsedForGrantComputation: activeIds
        )
    }

    // MARK: - Export Support

    /// Data needed for audio export of a single scene.
    public struct SceneAudioExportData {
        /// Index of this scene in timeline (0-based).
        public let sceneIndex: Int
        /// Compiled runtime for audio timing.
        public let runtime: SceneRuntime
        /// Video selections snapshot (blockId -> VideoSelection).
        public let videoSelections: [String: VideoSelection]
    }

    /// Builds audio scene data (strict — throws on any scene failure). Used by export.
    func buildAudioSceneData() async throws -> [SceneAudioExportData] {
        guard let math = transitionMath, let timeline = timeline else { return [] }
        let context = TimelineExportSessionBuilder.Context(
            transitionMath: math,
            timeline: timeline,
            sceneStates: sceneStates,
            currentAssetRegistry: currentAssetRegistry,
            resourcesCache: resourcesCache,
            mediaLocator: mediaLocator,
            stickerProvider: stickerProvider,
            fps: fps,
            canvasSize: canvasSize
        )
        return try await TimelineExportSessionBuilder.buildAudioSceneData(context: context)
    }

    /// Builds audio scene data (resilient — skips scenes that fail). Used by preview.
    func buildAudioSceneDataForPreview() async -> [SceneAudioExportData] {
        guard let math = transitionMath, let timeline = timeline else { return [] }
        let context = TimelineExportSessionBuilder.Context(
            transitionMath: math,
            timeline: timeline,
            sceneStates: sceneStates,
            currentAssetRegistry: currentAssetRegistry,
            resourcesCache: resourcesCache,
            mediaLocator: mediaLocator,
            stickerProvider: stickerProvider,
            fps: fps,
            canvasSize: canvasSize
        )
        return await TimelineExportSessionBuilder.buildAudioSceneDataResilient(context: context)
    }

    /// Compatibility helper — timeline export after TT-05 uses session.audioSceneData instead.
    // MARK: - TT-05 Export Session

    /// Error when building an immutable export session.
    internal enum TimelineExportSessionBuildError: Error, Sendable, Equatable {
        case noTimeline
        case missingRuntime(UUID)
    }

    /// Immutable snapshot of a single scene for export.
    ///
    /// Contains lightweight media descriptors instead of live GPU textures.
    /// The `TimelineExportResidencyController` creates GPU resources on demand.
    internal struct TimelineExportSceneSnapshot {
        let sceneIndex: Int
        let instanceId: UUID
        let runtime: SceneRuntime
        let renderState: SceneRenderStateSnapshot
        let videoSelections: [String: VideoSelection]
        let mediaSnapshot: ExportMediaSnapshot
        let assetIndex: AssetIndexIR
        let resolver: CompositeAssetResolver
        let bindingAssetIds: Set<String>
        let pathRegistry: PathRegistry
        let assetSizes: [String: AssetSize]
        let sceneCanvasSize: SizeD
        /// Template background for this specific scene (may differ across scenes in a timeline).
        let templateBackground: Background?
    }

    /// Immutable export session built once before the export loop.
    internal struct TimelineExportSession {
        let transitionMath: TimelineTransitionMath
        let canvasSize: SizeD
        let fps: Int
        let scenesByInstanceId: [UUID: TimelineExportSceneSnapshot]
        let audioSceneData: [SceneAudioExportData]
        /// Unified overlay snapshot for both single-scene and timeline export paths.
        let overlaySnapshot: OverlayExportSnapshot
    }

    /// TT-05: Builds an immutable export session from current engine state.
    /// Must be called on MainActor. Does NOT call resolveFrame, prepareForPlayback,
    /// or touch TT-03 budget/eviction path.
    ///
    /// Delegates to `TimelineExportSessionBuilder` for the actual assembly.
    internal func buildExportSession() async throws -> TimelineExportSession {
        guard let math = transitionMath, templateCanvas != nil,
              let timeline = timeline else {
            throw TimelineExportSessionBuildError.noTimeline
        }

        let context = TimelineExportSessionBuilder.Context(
            transitionMath: math,
            timeline: timeline,
            sceneStates: sceneStates,
            currentAssetRegistry: currentAssetRegistry,
            resourcesCache: resourcesCache,
            mediaLocator: mediaLocator,
            stickerProvider: stickerProvider,
            fps: fps,
            canvasSize: canvasSize
        )

        return try await TimelineExportSessionBuilder.build(context: context)
    }

}
