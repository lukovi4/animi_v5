import Foundation
import MetalKit
import TVECore
import UIKit
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorRuntime")

/// Error emitted when export fails before the VideoExporter session starts.
struct ExportAbortError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thrown when a background import becomes stale (generation/preset changed mid-flight).
struct BackgroundImportStaleError: Error {}

// MARK: - UI-Safe Query Types

/// Sealed context for media block action bar UI.
struct MediaActionBarContext {
    let allowedMedia: [String]?
    let availableVariants: [VariantInfo]
    let selectedVariantId: String?
    let canTrimVideo: Bool
}


/// Protocol for scene-edit overlay and hit-test operations.
/// Replaces direct ScenePlayer exposure to UI layer.
@MainActor
protocol SceneEditOverlayProviding: AnyObject {
    func hitTest(point: Vec2D, frame: Int, mode: TemplateMode) -> String?
    func overlays(frame: Int, mode: TemplateMode) -> [MediaInputOverlay]
    func editBindingToCanvasMatrix(blockId: String) -> Matrix2D?
    func userTransformsAllowed(blockId: String) -> UserTransformsAllowed?
}

extension ScenePlayer: SceneEditOverlayProviding {}

/// Metal context needed to boot the runtime (passed from controller's MTKView).
struct EditorRuntimeMetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let colorPixelFormat: MTLPixelFormat
}

/// Single owner of runtime/playback/render/export execution state.
///
/// The controller creates this after session bootstrap and delegates all
/// runtime operations through its public API. UI updates flow back via `onOutput`.
@MainActor
final class EditorRuntime {

    // MARK: - Dependencies

    private let session: EditorSession

    // MARK: - State

    private(set) var state: EditorRuntimeState = .idle

    /// Current render source for the view layer.
    /// Every assignment increments `renderSourceRevision` for test observability.
    private(set) var currentRenderSource: EditorRuntimeRenderSource = .none {
        didSet { renderSourceRevision &+= 1 }
    }

    /// Monotonically increasing counter incremented on every `currentRenderSource` assignment.
    /// Read-only test seam — proves render-source was regenerated, not merely retained.
    private(set) var renderSourceRevision: UInt = 0

    /// Tracks which codepath last triggered a timeline frame refresh.
    /// Read-only test seam — proves engine.onNeedsRedraw fired vs manual playhead change.
    enum RefreshTrigger: Equatable { case none, playheadChanged, engineRedraw, sceneEditMutation }
    private(set) var lastRefreshTrigger: RefreshTrigger = .none

    var onOutput: ((EditorRuntimeOutput) -> Void)?

    // MARK: - Metal Context

    private var metalContext: EditorRuntimeMetalContext?

    // MARK: - Subsystems (moved from PVC)

    private var sceneLibrarySnapshot: SceneLibrarySnapshot?
    private var playbackCoordinator: TimelinePlaybackCoordinator?
    private var timelineCompositionEngine: TimelineCompositionEngine?
    private var transitionCompositor: TransitionCompositor?

    /// Per-owner overlay texture cache for the preview path.
    /// Purged on memory warning; released on deinit.
    let overlayRenderCache = OverlayRenderResourceCache()
    private var memoryWarningObserver: NSObjectProtocol?

    private var scenePlayer: ScenePlayer?
    private var compiledScene: CompiledScene?
    private var textureProvider: (any MutableTextureProvider)?
    private var assetResolver: CompositeAssetResolver?

    private var userMediaService: UserMediaService?
    private var backgroundTextureService: BackgroundTextureService?
    private var backgroundTextureProvider: InMemoryTextureProvider?
    private(set) var effectiveBackgroundState: EffectiveBackgroundState?

    /// True after enterExportMode() has torn down preview resources.
    /// Cleared by restorePreExportState(). Guards reload to avoid
    /// re-preloading when cancel fires before teardown.
    private var exportTeardownOccurred = false

    private var canvasSize: SizeD = .zero
    private var mergedAssetSizes: [String: AssetSize] = [:]

    // MARK: - Frame State

    private var cachedTimelineFrame: ResolvedTimelineFrame?
    private var cachedTimelineCompressedFrame: Int?
    private var currentCompressedFrame: Int = 0
    private var currentFrameIndex = 0
    private var totalFrames = 0
    private var sceneFPS = 30.0

    // MARK: - Playback

    private(set) var isPlaying = false
    private var displayLink: CADisplayLink?
    private var playheadAsyncTask: Task<Void, Never>?
    private var playbackStartTask: Task<Void, Never>?
    private var lastStillSyncFrame: Int = -1

    // MARK: - Scene Edit

    private var activeSceneInstanceId: UUID?
    private var sceneEditReadyInstanceId: UUID?
    private var sceneEditActivationTask: Task<Void, Never>?

    // MARK: - Export

    final class ActiveExportRequest {
        let id: UUID
        let exporter: VideoExporter
        let deliveryPolicy: ExportDeliveryPolicy

        /// Strongly retains the in-flight delivery operation until terminal completion.
        var deliveryFlow: ExportDeliveryFlow?

        init(id: UUID, exporter: VideoExporter, deliveryPolicy: ExportDeliveryPolicy) {
            self.id = id
            self.exporter = exporter
            self.deliveryPolicy = deliveryPolicy
        }

        func isActive(for requestId: UUID) -> Bool {
            id == requestId
        }
    }

    private var activeExportRequest: ActiveExportRequest?
    var isExporting: Bool { activeExportRequest != nil }
    private var preExportState: EditorRuntimeState?

    /// Generation counter for background image imports. Incremented on each new
    /// picker request and on editor dismiss, so stale async completions detect
    /// they are no longer current.
    private(set) var backgroundImportGeneration: UInt = 0

    /// Scope of the active background editor session.
    enum BackgroundEditScope {
        case project
        case scene(instanceId: UUID)
    }

    /// Whether a background editor is actively presented (defers store commits).
    private(set) var hasActiveBackgroundEditor: Bool = false

    /// Active background edit scope — project or scene.
    private var backgroundEditScope: BackgroundEditScope = .project

    /// Preset ID from the last background editor session (for texture cleanup on preset change).
    private var lastBackgroundPresetId: String?

    /// Asset IDs registered during the current background editor session.
    /// Swept on dismiss to unregister intermediate imports that didn't land in the final override.
    private var backgroundEditorTrackedAssetIds: Set<ProjectAssetID> = []

    // MARK: - Init

    init(session: EditorSession) {
        self.session = session
        // Subscribe to memory warnings to purge overlay texture cache.
        let cache = overlayRenderCache
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            cache.purgeOnMemoryPressure()
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        overlayRenderCache.invalidateAll()
    }

    // MARK: - Boot

    #if DEBUG
    func bootForTesting(state: EditorRuntimeState = .timelinePreview) {
        self.state = state
    }

    /// Test seam: forwards to the private runtime-owned `handleMediaReadyForPlacement`.
    /// Exercises the exact same path that `UserMediaService.onMediaReady` invokes in production.
    func simulateMediaReadyCallback(blockId: String) {
        handleMediaReadyForPlacement(blockId: blockId)
    }

    /// Test seam: exposes the timeline composition engine for cache pre-population.
    var testTimelineCompositionEngine: TimelineCompositionEngine? { timelineCompositionEngine }

    /// Test seam: exposes background texture service for export-restore verification.
    var testBackgroundTextureService: BackgroundTextureService? { backgroundTextureService }

    /// Test seam: triggers export teardown without starting actual export.
    func simulateEnterExportMode() {
        enterExportMode()
    }

    /// Test seam: async exit-export-mode with background texture restore.
    func simulateExitExportModeToIdle() async {
        await exitExportModeToIdle()
    }

    /// Test seam: simulates exporter completion callback with a fake active request.
    func simulateHandleExportCompletion(result: Result<URL, Error>) {
        let exporter = VideoExporter(mediaLocator: session.mediaLocator)
        let request = ActiveExportRequest(id: UUID(), exporter: exporter, deliveryPolicy: pendingDeliveryPolicy)
        activeExportRequest = request
        handleExportCompletion(result: result, requestId: request.id)
    }
    #endif

    func boot(metalContext: EditorRuntimeMetalContext, library: SceneLibrarySnapshot) {
        guard state == .idle else { return }
        self.metalContext = metalContext
        self.sceneLibrarySnapshot = library
        state = .booting
    }

    /// Result of the initial scene load pipeline.
    struct InitialSceneLoadResult {
        let player: ScenePlayer
        let compiled: CompiledScene
        let provider: ScenePackageTextureProvider
        let resolver: CompositeAssetResolver
        let preloadStats: PreloadStats?
    }

    /// Loads the initial scene type: package IO → ScenePlayer → texture provider → preload.
    /// Runs heavy work off main actor. Returns scene data for boot.
    static func loadInitialScene(
        sceneTypeId: String,
        sceneURL: URL,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        onStatus: @escaping @MainActor (String) -> Void
    ) async throws -> InitialSceneLoadResult {
        // Phase 1: Heavy IO
        let loaded = try await SceneTypeLoadPipeline.load(
            sceneTypeId: sceneTypeId,
            from: sceneURL
        )

        try Task.checkCancellation()

        // Phase 2: ScenePlayer setup (main actor)
        await onStatus("Preparing scene...")
        let (player, compiled): (ScenePlayer, CompiledScene) = await MainActor.run {
            let p = ScenePlayer()
            let c = p.loadCompiledScene(loaded.compiled)
            return (p, c)
        }

        try Task.checkCancellation()

        // Phase 3: Texture provider + preload
        await onStatus("Loading textures...")
        let provider: ScenePackageTextureProvider = await MainActor.run {
            SceneTextureProviderFactory.create(
                device: device,
                mergedAssetIndex: compiled.mergedAssetIndex,
                resolver: loaded.resolver,
                bindingAssetIds: compiled.bindingAssetIds,
                logger: { _ in }
            )
        }

        try await Task(priority: .userInitiated) {
            try Task.checkCancellation()
            provider.preloadAll(commandQueue: commandQueue)
        }.value

        return InitialSceneLoadResult(
            player: player,
            compiled: compiled,
            provider: provider,
            resolver: loaded.resolver,
            preloadStats: provider.lastPreloadStats
        )
    }

    /// Single-call boot: metal context → scene → background → coordinator → engine → timeline preview.
    /// Owns the entire boot sequence so the controller only passes initial data.
    func configureAndBoot(
        metalContext: EditorRuntimeMetalContext,
        library: SceneLibrarySnapshot,
        loadResult: InitialSceneLoadResult,
        editorState: EditorState
    ) {
        boot(metalContext: metalContext, library: library)
        bootWithLoadedScene(player: loadResult.player, compiled: loadResult.compiled,
                            provider: loadResult.provider, resolver: loadResult.resolver)
        setupBackground(compiled: loadResult.compiled)
        setupPlaybackCoordinator(library: library, state: editorState)
        setupTimelineCompositionEngine(state: editorState)
        transitionToTimelinePreview()
        // Initial playhead application must run after the runtime enters
        // timelinePreview; in .booting, handlePlayheadChanged() is a no-op.
        handlePlayheadChanged(editorState.playheadCompressedFrame)
    }

    /// Boots the runtime with the initial scene loaded during template load.
    /// Creates UserMediaService internally (same pattern as `handleCoordinatorSceneLoaded`).
    /// Must be called BEFORE `setupPlaybackCoordinator` / `setupTimelineCompositionEngine`.
    func bootWithLoadedScene(
        player: ScenePlayer,
        compiled: CompiledScene,
        provider: ScenePackageTextureProvider,
        resolver: CompositeAssetResolver
    ) {
        self.scenePlayer = player
        self.compiledScene = compiled
        self.textureProvider = provider
        self.assetResolver = resolver
        self.canvasSize = compiled.runtime.canvasSize
        self.mergedAssetSizes = compiled.mergedAssetIndex.sizeById
        self.totalFrames = compiled.runtime.durationFrames
        self.sceneFPS = Double(compiled.runtime.fps)

        // Create UserMediaService (same as handleCoordinatorSceneLoaded)
        if let ctx = metalContext {
            let ums = UserMediaService(
                device: ctx.device,
                commandQueue: ctx.commandQueue,
                scenePlayer: player,
                textureProvider: provider
            )
            ums.setSceneFPS(Double(compiled.runtime.fps))
            ums.onNeedsDisplay = { [weak self] in
                self?.refreshSceneEditIfActive()
                self?.syncPausedVideoStill(force: true)
            }
            ums.onStillFrameDelivered = { [weak self] in
                self?.refreshSceneEditIfActive()
            }
            ums.onMediaReady = { [weak self] blockId in
                self?.handleMediaReadyForPlacement(blockId: blockId)
            }
            self.userMediaService = ums
        }
    }

    /// Sets up background state from template and project override.
    /// Creates BackgroundTextureService and InMemoryTextureProvider internally.
    func setupBackground(compiled: CompiledScene) {
        guard let ctx = metalContext else {
            logger.info("[EditorRuntime] setupBackground skipped: no metal context")
            return
        }

        let bgProvider = InMemoryTextureProvider()
        self.backgroundTextureProvider = bgProvider

        let bgService = BackgroundTextureService(
            textureProvider: bgProvider,
            device: ctx.device,
            commandQueue: ctx.commandQueue,
            mediaLocator: session.mediaLocator,
            mediaWriter: session.mediaWriter
        )
        self.backgroundTextureService = bgService

        let bgOverride = session.state?.draft.background
        let sceneOverride = currentSceneBackgroundOverride()
        let templateBackground = compiled.runtime.scene.background
        let effState = EffectiveBackgroundBuilder.build(
            templateBackground: templateBackground,
            projectOverride: bgOverride,
            sceneOverride: sceneOverride,
            presetLibrary: session.backgroundPresetProvider
        )
        self.effectiveBackgroundState = effState

        if let state = effState {
            logger.info("[EditorRuntime] Background preset '\(state.preset.presetId)' with \(state.regionStates.count) regions")

            if let override = bgOverride {
                let registry = selfHealedRegistry()
                Task { [weak self] in
                    let loadedKeys = await bgService.preloadTextures(
                        from: override,
                        presetId: state.preset.presetId,
                        assetRegistry: registry
                    )
                    if !loadedKeys.isEmpty {
                        logger.info("[EditorRuntime] Preloaded \(loadedKeys.count) background textures")
                    }
                    self?.onOutput?(.renderSourceUpdated)
                }
            }
        }

        // Refresh render source with new background
        switch self.state {
        case .timelinePreview:
            refreshCurrentTimelineFrame()
        case .sceneEdit:
            updateSceneEditRenderSource()
        default:
            break
        }
    }

    /// Transitions to timeline preview after subsystem setup completes.
    func transitionToTimelinePreview() {
        state = .timelinePreview
        onOutput?(.runtimeReady)
    }

    // MARK: - Playback Coordinator Setup

    func setupPlaybackCoordinator(library: SceneLibrarySnapshot, state editorState: EditorState) {
        let coordinator = TimelinePlaybackCoordinator()
        coordinator.configure(
            sceneLibrary: library,
            fps: library.fps,
            loadSceneType: { [weak self] sceneTypeId in
                guard let self = self else {
                    throw NSError(domain: "EditorRuntime", code: -1)
                }
                return try await self.loadSceneTypeAsync(sceneTypeId: sceneTypeId)
            }
        )

        coordinator.updateSceneTimeline(from: editorState)

        // Bootstrap with already-loaded first scene
        if let player = scenePlayer,
           let compiled = compiledScene,
           let provider = textureProvider as? ScenePackageTextureProvider,
           let resolver = assetResolver,
           let firstSceneTypeId = editorState.canonicalTimeline.firstSceneTypeId {
            coordinator.bootstrap(
                sceneTypeId: firstSceneTypeId,
                player: player,
                compiled: compiled,
                provider: provider,
                resolver: resolver
            )
        }

        coordinator.onSceneLoaded = { [weak self] loadedScene in
            self?.handleCoordinatorSceneLoaded(loadedScene)
        }

        coordinator.onActiveSceneChanged = { [weak self] sceneInfo in
            self?.handleActiveSceneChanged(sceneInfo)
        }

        self.playbackCoordinator = coordinator
    }

    // MARK: - Timeline Composition Engine Setup

    func setupTimelineCompositionEngine(state editorState: EditorState) {
        guard let ctx = metalContext, let library = sceneLibrarySnapshot else { return }

        let engine: TimelineCompositionEngine
        if let existing = timelineCompositionEngine {
            engine = existing
        } else {
            engine = TimelineCompositionEngine(
                device: ctx.device,
                commandQueue: ctx.commandQueue,
                fps: library.fps,
                mediaLocator: session.mediaLocator
            )

            engine.resourcesCache.sceneURLProvider = { sceneTypeId in
                library.scene(byId: sceneTypeId)?.folderURL
            }

            engine.setTemplateCanvas(library.canvas)
            engine.setStickerProvider(session.stickerProvider)

            engine.onNeedsRedraw = { [weak self] in
                self?.refreshCurrentTimelineFrame()
            }

            timelineCompositionEngine = engine
        }

        let timeline = editorState.canonicalTimeline
        let sceneStates = editorState.draft.sceneInstanceStates
        engine.setTimeline(
            timeline,
            sceneStates: sceneStates,
            assetRegistry: editorState.draft.assetRegistry.selfHealed(for: editorState.draft)
        )

        if transitionCompositor == nil {
            do {
                transitionCompositor = try TransitionCompositor(
                    device: ctx.device,
                    colorPixelFormat: ctx.colorPixelFormat
                )
            } catch {
                logger.error("[EditorRuntime] Failed to create TransitionCompositor: \(error)")
            }
        }
    }

    // MARK: - Scene Loading

    private func loadSceneTypeAsync(sceneTypeId: String) async throws -> TimelinePlaybackCoordinator.LoadedScene {
        guard let sceneDescriptor = sceneLibrarySnapshot?.scene(byId: sceneTypeId),
              let sceneURL = sceneDescriptor.folderURL else {
            throw NSError(domain: "EditorRuntime", code: -1, userInfo: [NSLocalizedDescriptionKey: "Scene not found: \(sceneTypeId)"])
        }

        let loaded = try await SceneTypeLoadPipeline.load(
            sceneTypeId: sceneTypeId,
            from: sceneURL
        )

        let player = await MainActor.run { ScenePlayer() }
        let compiled = await MainActor.run { player.loadCompiledScene(loaded.compiled) }
        let resolver = loaded.resolver

        guard let device = await MainActor.run(body: { metalContext?.device }) else {
            throw NSError(domain: "EditorRuntime", code: -2, userInfo: [NSLocalizedDescriptionKey: "No Metal device"])
        }

        let provider = await MainActor.run {
            SceneTextureProviderFactory.create(
                device: device,
                mergedAssetIndex: compiled.mergedAssetIndex,
                resolver: resolver,
                bindingAssetIds: compiled.bindingAssetIds,
                logger: { _ in }
            )
        }

        let queue = await MainActor.run(body: { metalContext?.commandQueue })
        if let queue = queue {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    provider.preloadAll(commandQueue: queue)
                    cont.resume()
                }
            }
        }

        return TimelinePlaybackCoordinator.LoadedScene(
            sceneTypeId: sceneTypeId,
            player: player,
            compiled: compiled,
            provider: provider,
            resolver: resolver
        )
    }

    // MARK: - Coordinator Scene Loaded

    private func handleCoordinatorSceneLoaded(_ loadedScene: TimelinePlaybackCoordinator.LoadedScene) {
        scenePlayer = loadedScene.player
        compiledScene = loadedScene.compiled
        textureProvider = loadedScene.provider
        assetResolver = loadedScene.resolver

        lastStillSyncFrame = -1

        if let ctx = metalContext {
            userMediaService = UserMediaService(
                device: ctx.device,
                commandQueue: ctx.commandQueue,
                scenePlayer: loadedScene.player,
                textureProvider: loadedScene.provider
            )
            userMediaService?.setSceneFPS(Double(loadedScene.compiled.runtime.fps))
            userMediaService?.onNeedsDisplay = { [weak self] in
                self?.refreshSceneEditIfActive()
                self?.syncPausedVideoStill(force: true)
            }
            userMediaService?.onStillFrameDelivered = { [weak self] in
                self?.refreshSceneEditIfActive()
            }
            userMediaService?.onMediaReady = { [weak self] blockId in
                self?.handleMediaReadyForPlacement(blockId: blockId)
            }
        }

        let newCanvasSize = loadedScene.compiled.runtime.canvasSize
        if canvasSize != newCanvasSize {
            canvasSize = newCanvasSize
        }

        logger.debug("[EditorRuntime] Coordinator loaded scene: \(loadedScene.sceneTypeId)")

        // Apply per-instance state after scene load (skip during scene-edit activation)
        if sceneEditReadyInstanceId != nil, let instanceId = activeSceneInstanceId {
            resetRuntimeForSceneInstanceChange()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.applySceneInstanceState(instanceId: instanceId)
                self.refreshSceneEditIfActive()
            }
        }

        refreshSceneEditIfActive()
    }

    // MARK: - Active Scene Changed

    private func handleActiveSceneChanged(_ sceneInfo: TimelinePlaybackCoordinator.SceneTimeInfo) {
        // In timeline mode, engine is source of truth — ignore coordinator callback
        guard case .sceneEdit = state else { return }

        let previousInstanceId = activeSceneInstanceId
        activeSceneInstanceId = sceneInfo.sceneInstanceId

        guard sceneEditReadyInstanceId != nil else { return }

        if let coordinator = playbackCoordinator,
           coordinator.currentSceneTypeId == sceneInfo.sceneTypeId,
           scenePlayer != nil {
            if previousInstanceId != sceneInfo.sceneInstanceId {
                resetRuntimeForSceneInstanceChange()
                let newInstanceId = sceneInfo.sceneInstanceId
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.applySceneInstanceState(instanceId: newInstanceId)
                    self.refreshSceneEditIfActive()
                }
            }
        }
    }

    // MARK: - Scene Instance State

    func resetRuntimeForSceneInstanceChange() {
        scenePlayer?.resetForNewInstance()
        userMediaService?.clearAll()
        lastStillSyncFrame = -1
    }

    func applySceneInstanceState(instanceId: UUID) async {
        guard let sceneState = session.state?.draft.sceneInstanceStates[instanceId],
              let player = scenePlayer,
              let service = userMediaService else {
            return
        }

        let registry = selfHealedRegistry()
        let resolved = await ResolvedMediaMapBuilder.build(
            slots: sceneState.mediaSlotsByBlockId,
            locator: session.mediaLocator,
            registry: registry
        )

        let deps = SceneRuntimeStateApplier.RestoreDependencies(
            scenePlayer: player,
            userMediaService: service,
            resolvedMedia: resolved
        )
        let _ = SceneRuntimeStateApplier.apply(sceneState, deps: deps)

        session.updateMissingMedia(for: instanceId, failures: service.currentRestoreFailedBlockIds)
    }

    // MARK: - Playhead Handling

    func handlePlayheadChanged(_ compressedFrame: Int) {
        switch state {
        case .timelinePreview, .exporting:
            handleTimelineModePlayheadChanged(compressedFrame)
        case .sceneEdit:
            handleSceneEditModePlayheadChanged(compressedFrame)
        default:
            break
        }
    }

    private func handleTimelineModePlayheadChanged(_ compressedFrame: Int) {
        guard let engine = timelineCompositionEngine else { return }

        currentCompressedFrame = compressedFrame
        activeSceneInstanceId = engine.sceneInstanceId(at: compressedFrame)

        // Eagerly recompute background for the background-owning scene.
        // For transitions, the outgoing scene (A) owns the background.
        let bgOwnerId = backgroundOwnerInstanceId(at: compressedFrame, engine: engine)
        if let bgOwnerId {
            updatePreviewBackgroundForScene(bgOwnerId)
        }

        lastRefreshTrigger = .playheadChanged
        resolveAndPresentTimelineFrame(compressedFrame: compressedFrame, invalidateScrub: true)
    }

    func refreshCurrentTimelineFrame() {
        guard case .timelinePreview = state else { return }
        guard timelineCompositionEngine != nil else { return }

        lastRefreshTrigger = .engineRedraw
        let compressedFrame = session.state?.playheadCompressedFrame ?? 0
        resolveAndPresentTimelineFrame(compressedFrame: compressedFrame, invalidateScrub: false)
    }

    private func resolveAndPresentTimelineFrame(compressedFrame: Int, invalidateScrub: Bool) {
        guard let engine = timelineCompositionEngine else { return }

        var generation: UInt64?
        if invalidateScrub {
            engine.invalidateScrub()
            generation = engine.currentScrubGeneration
        }

        playheadAsyncTask?.cancel()

        playheadAsyncTask = Task { @MainActor in
            let resolution = await engine.resolveFrame(compressedFrame, generation: generation, policy: .presentation)

            guard !Task.isCancelled else { return }

            switch resolution {
            case .resolved(let resolved):
                self.cachedTimelineFrame = resolved
                self.cachedTimelineCompressedFrame = compressedFrame

                switch resolved {
                case .single(let ctx):
                    self.activeSceneInstanceId = ctx.sceneInstanceId
                case .transition:
                    self.activeSceneInstanceId = engine.sceneInstanceId(at: compressedFrame)
                }

                if !self.isPlaying {
                    switch resolved {
                    case .single(let ctx):
                        if let runtime = engine.runtime(for: ctx.sceneInstanceId) {
                            runtime.syncVideoFrame(ctx.localFrame)
                        }
                    case .transition(let ctx):
                        if let runtimeA = engine.runtime(for: ctx.sceneA.sceneInstanceId) {
                            runtimeA.syncVideoFrame(ctx.sceneA.localFrame)
                        }
                        if let runtimeB = engine.runtime(for: ctx.sceneB.sceneInstanceId) {
                            runtimeB.syncVideoFrame(ctx.sceneB.localFrame)
                        }
                    }
                }

                // Resolve overlays via shared OverlayResolver
                let overlayItems: [ResolvedOverlayRenderItem]
                if let engine = self.timelineCompositionEngine,
                   let timeline = engine.timeline,
                   let math = engine.transitionMath,
                   let timeUs = OverlayTimeMapping.globalTimeUs(for: compressedFrame, math: math, fps: engine.fps) {
                    overlayItems = OverlayResolver.resolve(
                        from: timeline, at: timeUs, stickerProvider: engine.stickerProvider
                    )
                } else {
                    overlayItems = []
                }

                // Resolve per-scene background for this frame's owner scene.
                if let previewBgState = self.resolvePreviewBackgroundState(for: resolved) {
                    self.effectiveBackgroundState = previewBgState
                }

                // Update render source
                self.currentRenderSource = .timeline(TimelineRenderSourcePayload(
                    resolvedFrame: resolved,
                    backgroundState: self.effectiveBackgroundState,
                    backgroundTextureProvider: self.backgroundTextureProvider,
                    diagnosticFrameTag: compressedFrame,
                    overlayItems: overlayItems
                ))
                self.onOutput?(.renderSourceUpdated)

            case .hold:
                #if DEBUG
                logger.debug("[EditorRuntime] Hold: keeping last frame")
                #endif

            case .staleGeneration:
                #if DEBUG
                logger.debug("[EditorRuntime] Stale generation: ignoring")
                #endif

            case .failed(let failure):
                #if DEBUG
                logger.debug("[EditorRuntime] Resolution failed: \(String(describing: failure))")
                #endif
            }
        }
    }

    private func handleSceneEditModePlayheadChanged(_ compressedFrame: Int) {
        guard sceneEditReadyInstanceId != nil else { return }
        guard let coordinator = playbackCoordinator else { return }

        let mapper = session.state?.makePlayheadMapper() ?? TimelinePlayheadMapper.empty
        let timeUs = mapper.nominalTimeUs(forCompressedFrame: compressedFrame)

        if let localFrame = coordinator.syncSetGlobalTimeUs(timeUs) {
            playheadAsyncTask?.cancel()
            playheadAsyncTask = nil

            currentFrameIndex = localFrame
            updateSceneEditRenderSource()

            if !isPlaying, localFrame != lastStillSyncFrame {
                userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
                lastStillSyncFrame = localFrame
            }
        } else {
            playheadAsyncTask?.cancel()
            let requestedTimeUs = timeUs
            playheadAsyncTask = Task { @MainActor in
                let localFrame = await coordinator.setGlobalTimeUs(requestedTimeUs)
                guard !Task.isCancelled else { return }

                self.currentFrameIndex = localFrame
                self.updateSceneEditRenderSource()

                if !self.isPlaying, localFrame != self.lastStillSyncFrame {
                    self.userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
                    self.lastStillSyncFrame = localFrame
                }
            }
        }
    }

    // MARK: - Scene Edit Render Source

    /// Rebuilds render source if in scene-edit mode, otherwise emits bare event.
    /// Consolidates the pattern of "if sceneEdit → rebuild, else → emit" used by fast-path mutations.
    private func refreshSceneEditIfActive() {
        if case .sceneEdit = state {
            lastRefreshTrigger = .sceneEditMutation
            updateSceneEditRenderSource()
        } else {
            onOutput?(.renderSourceUpdated)
        }
    }

    private func updateSceneEditRenderSource() {
        guard case .sceneEdit(let targetId) = state else { return }
        guard sceneEditReadyInstanceId == targetId else { return }

        let coordinator = playbackCoordinator
        let player = scenePlayer
        let frameIndex = currentFrameIndex

        guard let resolved = EditorRenderCommandResolver.resolve(
            uiMode: .sceneEdit(sceneInstanceId: targetId),
            coordinatorLocalFrame: coordinator?.currentLocalFrame,
            currentFrameIndex: frameIndex,
            coordinatorCommands: { mode in
                coordinator?.currentRenderCommands(mode: mode)
            },
            scenePlayerCommands: { mode, frame in
                player?.renderCommands(mode: mode, sceneFrameIndex: frame)
            }
        ) else { return }

        guard let compiled = compiledScene,
              let provider = textureProvider else { return }

        currentRenderSource = .sceneEdit(SceneEditRenderSourcePayload(
            commands: resolved.commands,
            textureProvider: provider,
            pathRegistry: compiled.pathRegistry,
            assetSizes: mergedAssetSizes,
            canvasSize: canvasSize,
            backgroundState: effectiveBackgroundState,
            backgroundTextureProvider: backgroundTextureProvider
        ))
        onOutput?(.renderSourceUpdated)
    }

    // MARK: - Scene Edit Activation

    func activateSceneEditTarget(instanceId: UUID) {
        sceneEditActivationTask?.cancel()
        sceneEditReadyInstanceId = nil

        sceneEditActivationTask = Task { @MainActor [weak self] in
            guard let self, let coordinator = self.playbackCoordinator else { return }

            guard let (_, localFrame) = await coordinator.activateSceneByInstanceId(instanceId) else {
                return
            }
            guard !Task.isCancelled else { return }

            self.activeSceneInstanceId = instanceId
            self.currentFrameIndex = localFrame
            self.resetRuntimeForSceneInstanceChange()
            await self.applySceneInstanceState(instanceId: instanceId)

            self.state = .sceneEdit(instanceId: instanceId)
            self.sceneEditReadyInstanceId = instanceId

            self.updateSceneEditRenderSource()
            self.onOutput?(.sceneEditActivated(instanceId: instanceId))

            if !self.isPlaying {
                self.userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
                self.lastStillSyncFrame = localFrame
            }
        }
    }

    func deactivateSceneEdit() {
        sceneEditActivationTask?.cancel()
        sceneEditReadyInstanceId = nil
        state = .timelinePreview
        onOutput?(.sceneEditDeactivated)
        refreshCurrentTimelineFrame()
    }

    // MARK: - Playback Control

    func startPlayback() {
        guard EditorRenderContract.isPlaybackAllowed(in: .timeline) else { return }
        guard playbackStartTask == nil else { return }
        guard let engine = timelineCompositionEngine else { return }

        let compressedFrame = session.state?.playheadCompressedFrame ?? 0
        let fps = Float(sceneFPS)

        playbackStartTask = Task { @MainActor in
            await engine.prepareForPlayback(startingAt: compressedFrame)

            guard !Task.isCancelled else {
                self.playbackStartTask = nil
                return
            }

            self.isPlaying = true

            self.displayLink = CADisplayLink(target: DisplayLinkTarget { [weak self] in
                self?.displayLinkFired()
            }, selector: #selector(DisplayLinkTarget.tick))
            self.displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
            self.displayLink?.add(to: .main, forMode: .common)

            engine.startPlayback(at: compressedFrame)

            self.onOutput?(.playbackStateChanged(isPlaying: true))
            self.playbackStartTask = nil
        }
    }

    func stopPlayback() {
        playbackStartTask?.cancel()
        playbackStartTask = nil

        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil

        if timelineCompositionEngine != nil {
            timelineCompositionEngine?.stopPlayback()
        } else {
            userMediaService?.stopVideoPlayback()
        }

        onOutput?(.playbackStateChanged(isPlaying: false))
    }

    private func displayLinkFired() {
        guard let editorState = session.state else { return }

        let currentFrame = editorState.playheadCompressedFrame
        let maxFrame = editorState.compressedDurationFrames - 1
        let nextFrame = min(currentFrame + 1, maxFrame)

        session.dispatch(.setPlayhead(compressedFrame: nextFrame))

        let uiMode = editorState.uiMode
        switch uiMode {
        case .timeline:
            timelineCompositionEngine?.syncPlaybackTick(nextFrame)
        case .sceneEdit:
            let mapper = editorState.makePlayheadMapper()
            let nextTimeUs = mapper.nominalTimeUs(forCompressedFrame: nextFrame)
            let fps = editorState.templateFPS
            let globalFrameIndex = Int(nextTimeUs * TimeUs(fps) / 1_000_000)
            let localFrame = playbackCoordinator?.currentLocalFrame ?? globalFrameIndex
            if let service = userMediaService,
               !service.blockIdsWithVideo.isEmpty,
               localFrame != lastStillSyncFrame {
                service.updateVideoFramesForPlayback(sceneFrameIndex: localFrame)
                lastStillSyncFrame = localFrame
            }
        }

        if nextFrame >= maxFrame {
            stopPlayback()
        }
    }

    // MARK: - Export

    private var pendingDeliveryPolicy: ExportDeliveryPolicy = .photoLibraryOnly

    func startExport(policy: ExportDeliveryPolicy) {
        guard state == .timelinePreview || {
            if case .sceneEdit = state { return true }
            return false
        }() else { return }

        // Hard gate: missing media blocks export entirely
        if let summary = session.missingMediaSummary, summary.hasFailedMedia {
            onOutput?(.presentError("Export unavailable: some media files are missing."))
            return
        }

        pendingDeliveryPolicy = policy
        preExportState = state
        state = .exporting
        onOutput?(.exportStarted)
    }

    func cancelExport() {
        guard state == .exporting else { return }
        activeExportRequest?.exporter.cancel()
        preflightContinuation?.resume(returning: .cancel)
        preflightContinuation = nil
        clearActiveExportRequest()
        let needsReload = exportTeardownOccurred && hasImageBackgroundRegions
        restorePreExportState()
        if needsReload {
            Task {
                await reloadBackgroundTextures()
                onOutput?(.exportCancelled)
            }
        } else {
            onOutput?(.exportCancelled)
        }
    }

    /// Returns true if `requestId` matches the currently active export request.
    func isActiveExportRequest(_ requestId: UUID) -> Bool {
        activeExportRequest?.isActive(for: requestId) ?? false
    }

    /// Clears activeExportRequest only if it matches `requestId`.
    func clearExportRequestIfCurrent(_ requestId: UUID) {
        guard isActiveExportRequest(requestId) else { return }
        activeExportRequest = nil
    }

    enum ExportPreflightChoice {
        case cancel
        case continueOriginal
        case useRecommended(preset: VideoQualityPreset, sizePx: (width: Int, height: Int))
    }

    /// Continuation for async preflight pause — resumed by `applyExportPreflightChoice`.
    private var preflightContinuation: CheckedContinuation<ExportPreflightChoice, Never>?

    /// Resumes the preflight continuation with the user's choice.
    func applyExportPreflightChoice(_ choice: ExportPreflightChoice) {
        preflightContinuation?.resume(returning: choice)
        preflightContinuation = nil
    }

    /// Injectable deliverer factory. Tests can replace to inject a mock.
    var makeDeliverer: () -> ExportDelivering = { ExportDeliveryCoordinator() }

    /// Full export orchestration — single-scene or timeline, preflight, delivery.
    func executeExport() async {
        guard state == .exporting else { return }
        guard let ctx = metalContext else {
            abortExport(message: "No Metal context available")
            return
        }

        let isTimeline = (session.state?.sceneItems.count ?? 1) > 1

        // Tear down preview resources to free GPU memory
        enterExportMode()

        if isTimeline {
            await executeTimelineExport(ctx: ctx)
        } else {
            await executeSingleSceneExport(ctx: ctx)
        }
    }

    // MARK: - Per-Scene Preview Background

    /// Returns the scene instance that owns the background at a given compressed frame.
    /// Uses `renderMode` as the single source of truth:
    /// - `.single(sceneIndex, _)` → that scene
    /// - `.transition(sceneAIndex, ..., ...)` → outgoing scene (A)
    private func backgroundOwnerInstanceId(
        at compressedFrame: Int,
        engine: TimelineCompositionEngine
    ) -> UUID? {
        guard let math = engine.transitionMath else { return nil }
        guard let mode = math.renderMode(for: compressedFrame) else { return nil }
        let ownerIndex: Int = switch mode {
        case .single(let sceneIndex, _): sceneIndex
        case .transition(let sceneAIndex, _, _, _, _, _): sceneAIndex
        }
        guard ownerIndex < math.sceneItems.count else { return nil }
        return math.sceneItems[ownerIndex].id
    }

    /// Builds effective background state for a specific scene instance.
    private func buildPreviewBackgroundState(
        for instanceId: UUID
    ) -> EffectiveBackgroundState? {
        let sceneOverride = session.state?.draft.sceneInstanceStates[instanceId]?.backgroundOverride
        let projectOverride = session.state?.draft.background
        let templateBg = timelineCompositionEngine?.runtime(for: instanceId)?
            .resources.compiled.runtime.scene.background

        return EffectiveBackgroundBuilder.build(
            templateBackground: templateBg,
            projectOverride: projectOverride,
            sceneOverride: sceneOverride,
            presetLibrary: session.backgroundPresetProvider
        )
    }

    /// Recomputes and updates the global effective background state for a scene instance.
    private func updatePreviewBackgroundForScene(_ instanceId: UUID) {
        let newState = buildPreviewBackgroundState(for: instanceId)
        if newState != effectiveBackgroundState {
            effectiveBackgroundState = newState
        }
    }

    /// Resolves the background-owning scene from a resolved frame and builds its state.
    private func resolvePreviewBackgroundState(
        for resolved: ResolvedTimelineFrame
    ) -> EffectiveBackgroundState? {
        let ownerId: UUID? = switch resolved {
        case .single(let ctx): ctx.sceneInstanceId
        case .transition(let ctx): ctx.sceneA.sceneInstanceId
        }
        guard let ownerId else { return nil }
        return buildPreviewBackgroundState(for: ownerId)
    }

    // MARK: - Export Private Methods

    /// Resolves the current scene-level background override, if any.
    /// Returns nil when no scene is being edited or the scene has no override.
    private func currentSceneBackgroundOverride() -> ProjectBackgroundOverride? {
        guard let instanceId = activeSceneInstanceId else { return nil }
        return session.state?.draft.sceneInstanceStates[instanceId]?.backgroundOverride
    }

    /// Builds per-scene background data for all scenes with explicit overrides.
    /// Scenes without overrides use the project-level fallback at render time.
    /// Builds per-scene export background data for every scene in the export session.
    /// Uses each scene's own template background (not the active editor scene's template).
    private func buildPerSceneBackgrounds(
        from exportSession: TimelineCompositionEngine.TimelineExportSession
    ) -> [UUID: SceneExportBackgroundData] {
        let allStates = session.state?.draft.sceneInstanceStates ?? [:]
        let projectOverride = session.state?.draft.background
        var result: [UUID: SceneExportBackgroundData] = [:]
        for (instanceId, sceneSnapshot) in exportSession.scenesByInstanceId {
            let sceneOverride = allStates[instanceId]?.backgroundOverride
            let effState = EffectiveBackgroundBuilder.build(
                templateBackground: sceneSnapshot.templateBackground,
                projectOverride: projectOverride,
                sceneOverride: sceneOverride,
                presetLibrary: session.backgroundPresetProvider
            )
            let snapshot = ExportBackgroundSnapshot.build(
                from: projectOverride,
                sceneOverride: sceneOverride,
                effectiveState: effState
            )
            result[instanceId] = SceneExportBackgroundData(
                state: effState,
                snapshot: snapshot
            )
        }
        return result
    }

    private func enterExportMode() {
        stopPlayback()
        backgroundTextureService?.clearAllTrackedTextures()
        userMediaService?.releasePreviewResources()
        timelineCompositionEngine?.releaseForExport()
        exportTeardownOccurred = true
    }

    private func exitExportModeToIdle() async {
        let needsReload = exportTeardownOccurred && hasImageBackgroundRegions
        restorePreExportState()
        if needsReload {
            await reloadBackgroundTextures()
        }
    }

    /// True when the current background has at least one image region that would
    /// need texture reload after export teardown. Used to avoid unnecessary async
    /// deferral of terminal output for color-only backgrounds.
    private var hasImageBackgroundRegions: Bool {
        guard let effState = effectiveBackgroundState else { return false }
        return effState.regionStates.values.contains(where: {
            if case .image = $0.source { return true }
            return false
        })
    }

    /// Re-preloads background textures after export teardown.
    /// Caller must verify `hasImageBackgroundRegions` before invoking.
    private func reloadBackgroundTextures() async {
        let proj = session.state?.draft.background
        let scene = currentSceneBackgroundOverride()
        guard let effState = effectiveBackgroundState else { return }
        await preloadBackgroundTexturesScoped(
            projectOverride: proj, sceneOverride: scene, effectiveState: effState
        )
    }

    /// Canonical terminal cleanup for export precondition failures.
    /// Restores runtime to pre-export state and emits a terminal error output
    /// so the controller can dismiss any export UI.
    private func abortExport(message: String) {
        logger.error("[Export] Aborted: \(message)")
        preflightContinuation?.resume(returning: .cancel)
        preflightContinuation = nil
        clearActiveExportRequest()
        restorePreExportState()
        onOutput?(.exportRenderFailed(ExportAbortError(message: message)))
    }

    /// Async abort for post-teardown paths — restores background textures before emitting error.
    private func abortExportAfterTeardown(message: String) async {
        logger.error("[Export] Aborted: \(message)")
        preflightContinuation?.resume(returning: .cancel)
        preflightContinuation = nil
        clearActiveExportRequest()
        await exitExportModeToIdle()
        onOutput?(.exportRenderFailed(ExportAbortError(message: message)))
    }

    private func executeSingleSceneExport(ctx: EditorRuntimeMetalContext) async {
        guard let compiled = compiledScene,
              let player = scenePlayer,
              let resolver = assetResolver else {
            await abortExportAfterTeardown(message: "Missing dependencies for single-scene export")
            return
        }

        let exporter = VideoExporter(mediaLocator: session.mediaLocator)
        let request = ActiveExportRequest(id: UUID(), exporter: exporter, deliveryPolicy: pendingDeliveryPolicy)
        activeExportRequest = request
        let requestId = request.id

        // Build export texture provider
        let exportTP = ExportTextureProvider(
            device: ctx.device,
            assetIndex: compiled.mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: compiled.bindingAssetIds
        )

        let sceneRuntime = compiled.runtime
        let canvasSize = sceneRuntime.canvasSize

        // Output URL
        let outputURL = makeExportOutputURL(prefix: "export_\(sceneRuntime.scene.sceneId ?? "scene")")

        // Audio config (PR8: bridge project music from canonical timeline)
        let musicConfig = await buildProjectMusicTrackConfig()
        let audioConfig = AudioExportConfig(
            music: musicConfig,
            voiceover: nil,
            includeOriginalFromVideoSlots: true,
            originalDefaultVolume: 1.0
        )

        // Preflight
        let instanceId = activeSceneInstanceId
        let mediaSlots: [String: SceneMediaSlot] = instanceId.flatMap {
            session.state?.draft.sceneInstanceStates[$0]?.mediaSlotsByBlockId
        } ?? [:]
        let videoSlotCount = mediaSlots.values.filter { $0.mediaRef.mediaKind == .video }.count
        let backgroundRegionCount = session.state?.draft.background.regions.count ?? 0

        let preflightResult = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: (width: Int(canvasSize.width), height: Int(canvasSize.height)),
            videoSlotCount: videoSlotCount,
            backgroundRegionCount: backgroundRegionCount,
            currentPreset: .high,
            fps: sceneRuntime.fps
        )

        let originalSizePx = (width: Int(canvasSize.width), height: Int(canvasSize.height))
        let exportSizePx: (width: Int, height: Int)
        let exportPreset: VideoQualityPreset

        switch preflightResult {
        case .recommendLowerPreset(_, let suggestedPreset, let suggestedSizePx):
            onOutput?(.exportPreflightRecommendation(preflightResult))
            let choice = await withCheckedContinuation { (cont: CheckedContinuation<ExportPreflightChoice, Never>) in
                self.preflightContinuation = cont
            }
            guard isActiveExportRequest(requestId) else {
                return
            }
            switch choice {
            case .cancel:
                await exitExportModeToIdle()
                clearActiveExportRequest()
                onOutput?(.exportCancelled)
                return
            case .continueOriginal:
                exportSizePx = originalSizePx
                exportPreset = .high
            case .useRecommended(let preset, let sizePx):
                exportSizePx = sizePx
                exportPreset = preset
                logger.info("[Export] User chose reduced quality: \(sizePx.width)x\(sizePx.height) preset=\(String(describing: preset))")
            }
        case .safe:
            exportSizePx = originalSizePx
            exportPreset = .high
        }

        // Recompute budget with final export parameters
        let budget = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: exportSizePx,
            videoSlotCount: videoSlotCount,
            backgroundRegionCount: backgroundRegionCount,
            currentPreset: exportPreset,
            fps: sceneRuntime.fps
        ).budget

        let settings = makeSingleSceneExportSettings(
            outputURL: outputURL,
            sizePx: exportSizePx,
            preset: exportPreset,
            fps: sceneRuntime.fps,
            audio: audioConfig
        )

        // Build media snapshot
        let mediaSnapshot: ExportMediaSnapshot
        do {
            mediaSnapshot = try await ExportMediaSnapshot.build(
                compiledScene: compiled,
                mediaSlots: mediaSlots,
                mediaLocator: session.mediaLocator,
                assetRegistry: selfHealedRegistry(),
                runtime: sceneRuntime
            )
        } catch {
            logger.error("[Export] Media snapshot error: \(error.localizedDescription)")
            await exitExportModeToIdle()
            clearActiveExportRequest()
            onOutput?(.exportRenderFailed(error))
            return
        }

        let bgSnapshot = ExportBackgroundSnapshot.build(
            from: session.state?.draft.background,
            sceneOverride: currentSceneBackgroundOverride(),
            effectiveState: effectiveBackgroundState
        )

        guard isActiveExportRequest(requestId) else {
            logger.info("[Export] Cancelled during preflight (stale request)")
            return
        }

        await exporter.exportVideo(
            compiledScene: compiled,
            scenePlayer: player,
            device: ctx.device,
            textureProvider: exportTP,
            pathRegistry: compiled.pathRegistry,
            assetSizes: compiled.mergedAssetIndex.sizeById,
            settings: settings,
            backgroundState: effectiveBackgroundState,
            overlaySnapshot: session.state.map { state in
                OverlayExportSnapshot.build(from: state.canonicalTimeline, stickerProvider: session.stickerProvider)
            },
            budget: budget,
            mediaSnapshot: mediaSnapshot,
            backgroundSnapshot: bgSnapshot,
            assetRegistry: selfHealedRegistry(),
            onFinishing: { [weak self] in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.onOutput?(.exportFinishing)
            },
            progress: { [weak self] progress in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.onOutput?(.exportProgress(Float(progress)))
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.handleExportCompletion(result: result, requestId: requestId)
            }
        )
    }

    private func executeTimelineExport(ctx: EditorRuntimeMetalContext) async {
        guard let engine = timelineCompositionEngine,
              let transitionMath = engine.transitionMath else {
            await abortExportAfterTeardown(message: "No timeline configured for timeline export")
            return
        }

        let canvasSize = engine.canvasSize
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            await abortExportAfterTeardown(message: "Invalid canvas size for timeline export")
            return
        }

        let exporter = VideoExporter(mediaLocator: session.mediaLocator)
        let request = ActiveExportRequest(id: UUID(), exporter: exporter, deliveryPolicy: pendingDeliveryPolicy)
        activeExportRequest = request
        let requestId = request.id

        let outputURL = makeExportOutputURL(prefix: "export_timeline")

        // Audio config (PR8: bridge project music from canonical timeline)
        let musicConfig = await buildProjectMusicTrackConfig()
        let audioConfig = AudioExportConfig(
            music: musicConfig,
            voiceover: nil,
            includeOriginalFromVideoSlots: true,
            originalDefaultVolume: 1.0
        )

        // Preflight
        let sceneCount = session.state?.sceneItems.count ?? 1
        let allStates = session.state?.draft.sceneInstanceStates ?? [:]
        let totalVideoSlots = allStates.values.reduce(0) { count, state in
            count + (state.mediaSlotsByBlockId ?? [:]).values.filter { $0.mediaRef.mediaKind == .video }.count
        }
        let backgroundRegionCount = session.state?.draft.background.regions.count ?? 0

        let preflightResult = ExportPreflightPlanner.plan(
            sceneCount: sceneCount,
            canvasSize: (width: Int(canvasSize.width), height: Int(canvasSize.height)),
            videoSlotCount: totalVideoSlots,
            backgroundRegionCount: backgroundRegionCount,
            currentPreset: .high,
            fps: engine.fps
        )

        let originalSizePx = (width: Int(canvasSize.width), height: Int(canvasSize.height))
        let exportSizePx: (width: Int, height: Int)
        let exportPreset: VideoQualityPreset

        switch preflightResult {
        case .recommendLowerPreset(_, let suggestedPreset, let suggestedSizePx):
            onOutput?(.exportPreflightRecommendation(preflightResult))
            let choice = await withCheckedContinuation { (cont: CheckedContinuation<ExportPreflightChoice, Never>) in
                self.preflightContinuation = cont
            }
            guard isActiveExportRequest(requestId) else {
                return
            }
            switch choice {
            case .cancel:
                await exitExportModeToIdle()
                clearActiveExportRequest()
                onOutput?(.exportCancelled)
                return
            case .continueOriginal:
                exportSizePx = originalSizePx
                exportPreset = .high
            case .useRecommended(let preset, let sizePx):
                exportSizePx = sizePx
                exportPreset = preset
                logger.info("[Export] User chose reduced quality: \(sizePx.width)x\(sizePx.height) preset=\(String(describing: preset))")
            }
        case .safe:
            exportSizePx = originalSizePx
            exportPreset = .high
        }

        let budget = ExportPreflightPlanner.plan(
            sceneCount: sceneCount,
            canvasSize: exportSizePx,
            videoSlotCount: totalVideoSlots,
            backgroundRegionCount: backgroundRegionCount,
            currentPreset: exportPreset,
            fps: engine.fps
        ).budget

        let settings = makeTimelineExportSettings(
            outputURL: outputURL,
            sizePx: exportSizePx,
            preset: exportPreset,
            fps: engine.fps,
            audio: audioConfig
        )

        // Build the export session first so we can resolve per-scene template backgrounds.
        let tlSession: TimelineCompositionEngine.TimelineExportSession
        do {
            tlSession = try await engine.buildExportSession()
        } catch {
            await abortExportAfterTeardown(message: "Failed to build timeline export session: \(error.localizedDescription)")
            return
        }

        // Build per-scene background data using each scene's own template background.
        let sceneBackgrounds = buildPerSceneBackgrounds(from: tlSession)

        guard isActiveExportRequest(requestId) else {
            logger.info("[Export] Cancelled during preflight (stale request)")
            return
        }

        exporter.exportTimeline(
            engine: engine,
            sceneBackgrounds: sceneBackgrounds,
            preBuiltSession: tlSession,
            settings: settings,
            budget: budget,
            assetRegistry: selfHealedRegistry(),
            onFinishing: { [weak self] in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.onOutput?(.exportFinishing)
            },
            progress: { [weak self] progress in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.onOutput?(.exportProgress(Float(progress)))
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.handleExportCompletion(result: result, requestId: requestId)
            }
        )
    }

    private func handleExportCompletion(result: Result<URL, Error>, requestId: UUID) {
        guard isActiveExportRequest(requestId) else {
            logger.info("[Export] Ignoring stale completion")
            return
        }
        let needsReload = exportTeardownOccurred && hasImageBackgroundRegions
        restorePreExportState()
        if needsReload {
            Task {
                await reloadBackgroundTextures()
                self.emitExportCompletionOutput(result: result, requestId: requestId)
            }
        } else {
            emitExportCompletionOutput(result: result, requestId: requestId)
        }
    }

    private func emitExportCompletionOutput(result: Result<URL, Error>, requestId: UUID) {
        switch result {
        case .success(let url):
            logger.info("[Export] SUCCESS: \(url.lastPathComponent)")
            Task { await session.commitAfterExportSuccess() }
            onOutput?(.exportRenderSucceeded(url))
            saveExportedVideoToPhotos(url, requestId: requestId)

        case .failure(let error as VideoExportError) where error.isCancelled:
            logger.info("[Export] Cancelled")
            clearActiveExportRequest()
            onOutput?(.exportCancelled)

        case .failure(let error):
            logger.error("[Export] ERROR: \(error.localizedDescription)")
            clearActiveExportRequest()
            onOutput?(.exportRenderFailed(error))
        }
    }

    private func saveExportedVideoToPhotos(_ url: URL, requestId: UUID) {
        let deliverer = makeDeliverer()
        let policy = activeExportRequest?.deliveryPolicy ?? .photoLibraryOnly
        let shareHandoff: ((URL) -> Void)? = policy == .photoLibraryThenShare
            ? { [weak self] url in self?.onOutput?(.exportDeliveryShareHandoff(url)) }
            : nil
        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: policy,
            isRequestActive: { [weak self] id in self?.isActiveExportRequest(id) ?? false },
            clearRequestIfCurrent: { [weak self] id in self?.clearExportRequestIfCurrent(id) },
            completion: { [weak self] outcome in
                self?.onOutput?(.exportDeliveryCompleted(outcome))
            },
            shareHandoff: shareHandoff
        )
        activeExportRequest?.deliveryFlow = flow
        flow.start(fileURL: url, destination: .photoLibrary)
    }

    func confirmShareCompleted() {
        activeExportRequest?.deliveryFlow?.finalizeAfterShare()
    }

    /// PR8: Builds AudioTrackConfig from the project's canonical timeline music item.
    /// Returns nil if no music is set or resolution fails.
    ///
    /// - Note: `internal` visibility for `#if DEBUG` test access via
    ///   `_testBuildProjectMusicTrackConfig()`. Production call sites remain
    ///   the two export paths in this file.
    func buildProjectMusicTrackConfig() async -> AudioTrackConfig? {
        guard let state = session.state,
              let item = state.canonicalTimeline.musicItem,
              let payload = state.canonicalTimeline.musicPayload(),
              case .imported(let assetId, let contentStoragePath) = payload.assetRef else {
            return nil
        }

        // Resolve file URL through self-healed registry (covers undo-asymmetry / stale registry).
        let registry = selfHealedRegistry()
        let storagePath = registry.storagePath(for: assetId) ?? contentStoragePath
        guard !storagePath.isEmpty else {
            #if DEBUG
            logger.warning("[PR8] Music asset has no resolvable storage path: \(assetId.rawValue.uuidString)")
            #endif
            return nil
        }

        let mediaRef = MediaRef(storagePath: storagePath, mediaKind: .audio, assetId: assetId)
        guard let fileURL = try? await session.mediaLocator.absoluteURL(for: mediaRef, registry: registry) else {
            #if DEBUG
            logger.warning("[PR8] Failed to resolve music asset URL")
            #endif
            return nil
        }

        return AudioTrackConfig(
            url: fileURL,
            startTimeSeconds: usToSeconds(item.startUs ?? 0),
            volume: payload.volume,
            trimStartSeconds: usToSeconds(payload.trimStartUs),
            trimEndSeconds: usToSeconds(payload.trimEndUs)
        )
    }

    private func makeExportOutputURL(prefix: String) -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let uuid8 = UUID().uuidString.prefix(8)
        let filename = "\(prefix)_\(timestamp)_\(uuid8).mp4"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    private func makeSingleSceneExportSettings(
        outputURL: URL,
        sizePx: (width: Int, height: Int),
        preset: VideoQualityPreset,
        fps: Int,
        audio: AudioExportConfig?
    ) -> VideoExportSettings {
        let bitrate = preset.bitrate(for: sizePx)
        return VideoExportSettings(
            outputURL: outputURL,
            sizePx: sizePx,
            fps: fps,
            bitrate: bitrate,
            clearColor: .opaqueBlack,
            audio: audio
        )
    }

    private func makeTimelineExportSettings(
        outputURL: URL,
        sizePx: (width: Int, height: Int),
        preset: VideoQualityPreset,
        fps: Int,
        audio: AudioExportConfig?
    ) -> VideoExporter.TimelineExportSettings {
        let bitrate = preset.bitrate(for: sizePx)
        return VideoExporter.TimelineExportSettings(
            outputURL: outputURL,
            sizePx: sizePx,
            fps: fps,
            bitrate: bitrate,
            audio: audio
        )
    }

    private func restorePreExportState() {
        state = preExportState ?? .timelinePreview
        preExportState = nil
        exportTeardownOccurred = false
    }

    private func clearActiveExportRequest() {
        activeExportRequest = nil
    }

    // MARK: - Video Trim (Runtime Input API)

    func updateInteractiveTrimPreview(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double) {
        userMediaService?.updateInteractiveTrimPreview(blockId: blockId, draftSelection: draftSelection, previewTime: previewTime)
    }

    func endInteractiveTrimPreview(blockId: String) {
        userMediaService?.endInteractiveTrimPreview(blockId: blockId)
    }

    func previewExactVideoTrimFrame(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double) {
        userMediaService?.previewExactVideoTrimFrame(blockId: blockId, draftSelection: draftSelection, previewTime: previewTime)
    }

    func applyPersistedVideoSelection(blockId: String, _ selection: PersistedVideoSelection) throws {
        try userMediaService?.applyPersistedVideoSelection(blockId: blockId, selection)
    }

    // MARK: - Media Slot Management

    func clearMediaSlot(blockId: String) {
        userMediaService?.clear(blockId: blockId)
    }

    // MARK: - Scene Player State

    func resetScenePlayerForNewInstance() {
        scenePlayer?.resetForNewInstance()
    }

    func setSelectedVariant(blockId: String, variantId: String) {
        scenePlayer?.setSelectedVariant(blockId: blockId, variantId: variantId)
    }

    // MARK: - Background Texture Management

    func clearBackgroundTextures(prefix: String) {
        backgroundTextureService?.clearTextures(prefix: prefix)
    }

    func setEffectiveBackgroundState(_ state: EffectiveBackgroundState?) {
        effectiveBackgroundState = state
        // Refresh render source with new background
        switch self.state {
        case .timelinePreview:
            refreshCurrentTimelineFrame()
        case .sceneEdit:
            updateSceneEditRenderSource()
        default:
            break
        }
    }

    func incrementBackgroundImportGeneration() {
        backgroundImportGeneration &+= 1
    }

    // MARK: - Video Still Frame Sync

    func syncVideoStillFrames(sceneFrameIndex: Int) {
        guard !isPlaying else { return }
        userMediaService?.updateVideoStillFrames(sceneFrameIndex: sceneFrameIndex)
        lastStillSyncFrame = sceneFrameIndex
    }

    // MARK: - Media Fast-Path Mutations

    /// Applies placement change to active scene player and timeline engine.
    /// Returns true if the local scene-edit path was applied.
    func applyMediaPlacementChange(instanceId: UUID, blockId: String, placement: MediaPlacementState) -> Bool {
        var localApplied = false

        // Scene-edit path: apply to local player (URL-free)
        if let player = scenePlayer, let service = userMediaService,
           activeSceneInstanceId == instanceId {
            let deps = SceneRuntimeStateApplier.FastPathDependencies(scenePlayer: player, userMediaService: service)
            SceneRuntimeStateApplier.applyPlacementChange(blockId: blockId, placement: placement, deps: deps)
            refreshSceneEditIfActive()
            localApplied = true
        }

        // Timeline path: engine fast-path
        timelineCompositionEngine?.applyPlacementChange(blockId: blockId, placement: placement, for: instanceId)
        refreshCurrentTimelineFrame()

        return localApplied
    }

    /// Applies visibility change to active scene player and timeline engine.
    /// Returns true if the local scene-edit path was applied.
    func applyMediaVisibilityChange(instanceId: UUID, blockId: String, visible: Bool) -> Bool {
        var localApplied = false

        // Scene-edit path: apply to local player
        if let player = scenePlayer, activeSceneInstanceId == instanceId {
            SceneRuntimeStateApplier.applyVisibilityChange(blockId: blockId, visible: visible, player: player)
            refreshSceneEditIfActive()
            localApplied = true
        }

        // Timeline path: engine fast-path
        timelineCompositionEngine?.applyVisibilityChange(blockId: blockId, visible: visible, for: instanceId)
        refreshCurrentTimelineFrame()

        return localApplied
    }

    /// Applies slot change (insert/replace/remove) to active scene and timeline engine.
    /// For non-nil slots, resolves media URLs async before applying.
    func applyMediaSlotChange(instanceId: UUID, blockId: String, slot: SceneMediaSlot?) {
        let isActiveScene = activeSceneInstanceId == instanceId

        // Scene-edit path: apply directly (only for active scene)
        if isActiveScene, let player = scenePlayer, let service = userMediaService {
            if slot == nil {
                // Remove is URL-free — sync fast path.
                let deps = SceneRuntimeStateApplier.RestoreDependencies(
                    scenePlayer: player,
                    userMediaService: service,
                    resolvedMedia: .empty
                )
                SceneRuntimeStateApplier.applySlotChange(blockId: blockId, slot: slot, deps: deps)
                refreshSceneEditIfActive()
                session.updateMissingMedia(for: instanceId, failures: service.currentRestoreFailedBlockIds)
            } else {
                // Insert/replace: resolve URL async, then apply
                let registry = selfHealedRegistry()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let singleMap: [String: SceneMediaSlot] = [blockId: slot!]
                    let resolved = await ResolvedMediaMapBuilder.build(
                        slots: singleMap,
                        locator: self.session.mediaLocator,
                        registry: registry
                    )
                    let deps = SceneRuntimeStateApplier.RestoreDependencies(
                        scenePlayer: player,
                        userMediaService: service,
                        resolvedMedia: resolved
                    )
                    SceneRuntimeStateApplier.applySlotChange(blockId: blockId, slot: slot, deps: deps)
                    self.refreshSceneEditIfActive()
                    self.session.updateMissingMedia(for: instanceId, failures: service.currentRestoreFailedBlockIds)
                }
            }
        }

        // Timeline path: full state update for any scene
        if let sceneState = session.state?.draft.sceneInstanceStates[instanceId] {
            Task { @MainActor in
                await self.timelineCompositionEngine?.updateSceneState(sceneState, for: instanceId, assetRegistry: self.selfHealedRegistry())
                self.refreshCurrentTimelineFrame()
            }
        }
    }

    /// Re-resolves placement after async media load completes with actual dimensions.
    /// Returns true if the placement was reapplied.
    func reapplyPlacementAfterMediaReady(instanceId: UUID?, blockId: String, placement: MediaPlacementState) -> Bool {
        guard let player = scenePlayer, let service = userMediaService else { return false }
        let deps = SceneRuntimeStateApplier.FastPathDependencies(scenePlayer: player, userMediaService: service)
        SceneRuntimeStateApplier.applyPlacementChange(blockId: blockId, placement: placement, deps: deps)
        refreshSceneEditIfActive()
        return true
    }

    /// Applies incremental scene state change to timeline engine.
    func applySceneStateChange(instanceId: UUID, sceneState: SceneState) {
        Task { @MainActor in
            await self.timelineCompositionEngine?.updateSceneState(sceneState, for: instanceId, assetRegistry: self.selfHealedRegistry())
            self.refreshCurrentTimelineFrame()
        }
    }

    /// Applies persisted video selection to timeline engine.
    func applyVideoSelectionToEngine(selection: PersistedVideoSelection, blockId: String, instanceId: UUID) {
        timelineCompositionEngine?.applyPersistedVideoSelection(selection, blockId: blockId, for: instanceId)
    }

    /// Syncs full engine timeline after undo/redo — setTimeline + updateSceneState for all instances.
    func syncEngineAfterUndoRedo(state: EditorState) {
        guard let engine = timelineCompositionEngine else { return }
        engine.setTimeline(
            state.canonicalTimeline,
            sceneStates: state.draft.sceneInstanceStates,
            assetRegistry: state.draft.assetRegistry.selfHealed(for: state.draft)
        )
        Task { @MainActor in
            let registry = state.draft.assetRegistry.selfHealed(for: state.draft)
            for (instanceId, sceneState) in state.draft.sceneInstanceStates {
                await engine.updateSceneState(sceneState, for: instanceId, assetRegistry: registry)
            }
        }
    }

    // MARK: - Background Mutations

    /// Persists background image to disk and returns the media ref.
    /// Checks generation + preset guard; cleans up orphan if stale.
    func persistBackgroundImage(
        sourceFileURL: URL,
        generation: UInt,
        sessionPresetId: String
    ) async throws -> MediaRef {
        guard let service = backgroundTextureService else {
            throw ExportAbortError(message: "Background texture service not available")
        }

        let (mediaRef, _) = try await service.persistImage(from: sourceFileURL)
        logger.info("[Background] Persisted image: \(mediaRef.storagePath)")

        guard backgroundImportGeneration == generation,
              effectiveBackgroundState?.preset.presetId == sessionPresetId else {
            logger.info("[Background] Import generation stale after persist — cleaning up orphan")
            try? await service.deleteMediaFile(mediaRef)
            throw BackgroundImportStaleError()
        }

        return mediaRef
    }

    /// Loads a background texture for a region. Must be called after asset registration.
    /// Checks generation + preset guard after load; cleans up if stale.
    func loadBackgroundTexture(
        mediaRef: MediaRef,
        regionId: String,
        generation: UInt,
        sessionPresetId: String
    ) async throws -> String {
        guard let service = backgroundTextureService else {
            throw ExportAbortError(message: "Background texture service not available")
        }

        let slotKey = EffectiveBackgroundBuilder.makeSlotKey(
            presetId: sessionPresetId,
            regionId: regionId
        )

        let freshRegistry = selfHealedRegistry()
        do {
            try await service.loadTexture(slotKey: slotKey, mediaRef: mediaRef, assetRegistry: freshRegistry)
        } catch {
            try? await service.deleteMediaFile(mediaRef)
            throw error
        }

        guard backgroundImportGeneration == generation,
              effectiveBackgroundState?.preset.presetId == sessionPresetId else {
            logger.info("[Background] Import generation stale after texture load — clearing stale texture")
            service.clearTexture(slotKey: slotKey)
            try? await service.deleteMediaFile(mediaRef)
            throw BackgroundImportStaleError()
        }

        return slotKey
    }

    /// Deletes a media file via the background texture service.
    func deleteBackgroundMediaFile(_ mediaRef: MediaRef) async throws {
        try await backgroundTextureService?.deleteMediaFile(mediaRef)
    }

    /// Clears a specific background texture slot.
    func clearBackgroundTexture(slotKey: String) {
        backgroundTextureService?.clearTexture(slotKey: slotKey)
    }

    /// Clears all tracked background textures.
    func clearAllBackgroundTextures() {
        backgroundTextureService?.clearAllTrackedTextures()
    }

    /// Rebuilds effective background state from template + override and applies it.
    /// Centralizes `EffectiveBackgroundBuilder.build(...)` so controller never calls it directly.
    /// Resolves background inputs for render based on current edit scope.
    /// Returns (projectOverride, sceneOverride) pair.
    private func resolveBackgroundInputs(
        previewOverride: ProjectBackgroundOverride? = nil
    ) -> (projectOverride: ProjectBackgroundOverride?, sceneOverride: ProjectBackgroundOverride?) {
        switch backgroundEditScope {
        case .project:
            return (
                projectOverride: previewOverride ?? session.state?.draft.background,
                sceneOverride: currentSceneBackgroundOverride()
            )
        case .scene(let instanceId):
            return (
                projectOverride: session.state?.draft.background,
                sceneOverride: previewOverride ?? session.state?.draft.sceneInstanceStates[instanceId]?.backgroundOverride
            )
        }
    }

    /// Scope-aware effective background rebuild.
    private func rebuildEffectiveBackgroundScoped(
        projectOverride: ProjectBackgroundOverride?,
        sceneOverride: ProjectBackgroundOverride?
    ) {
        let effState = EffectiveBackgroundBuilder.build(
            templateBackground: compiledScene?.runtime.scene.background,
            projectOverride: projectOverride,
            sceneOverride: sceneOverride,
            presetLibrary: session.backgroundPresetProvider
        )
        setEffectiveBackgroundState(effState)
    }

    /// Scope-aware texture preload: resolves image refs from the correct owner chain.
    func preloadBackgroundTexturesScoped(
        projectOverride: ProjectBackgroundOverride?,
        sceneOverride: ProjectBackgroundOverride?,
        effectiveState: EffectiveBackgroundState?
    ) async {
        guard let service = backgroundTextureService, let state = effectiveState else { return }
        let registry = selfHealedRegistry()
        for (regionId, regionState) in state.regionStates {
            if case .image(let imageSource) = regionState.source {
                // Scene override region wins over project override region.
                let mediaRef = sceneOverride?.regions[regionId]?.imageMediaRef
                    ?? projectOverride?.regions[regionId]?.imageMediaRef
                guard let mediaRef else { continue }
                do {
                    try await service.loadTexture(
                        slotKey: imageSource.slotKey,
                        mediaRef: mediaRef,
                        assetRegistry: registry
                    )
                } catch {
                    logger.error("[Background] Failed to preload texture: \(error.localizedDescription)")
                }
            }
        }
        onOutput?(.renderSourceUpdated)
    }

    /// Applies a background preview override from the background editor.
    /// Uses `backgroundEditScope` to determine whether the override applies to project or scene.
    func applyBackgroundPreviewOverride(_ override: ProjectBackgroundOverride) {
        let (proj, scene) = resolveBackgroundInputs(previewOverride: override)
        rebuildEffectiveBackgroundScoped(projectOverride: proj, sceneOverride: scene)
        let effState = effectiveBackgroundState
        let resolvedOverride = scene ?? proj
        Task { @MainActor in
            if let resolvedOverride {
                await self.preloadBackgroundTexturesScoped(
                    projectOverride: proj, sceneOverride: scene, effectiveState: effState
                )
            }
        }
    }

    /// Marks preview audio state as dirty (e.g. after timeline music changes).
    /// Currently a no-op — audio preview is rebuilt on next export or playback start.
    func markPreviewAudioDirty() {
        // Intentional no-op: audio preview rebuild is deferred to next export/playback start.
        // This method exists as a seam for future audio preview invalidation.
    }

    // MARK: - Background Editor Session

    /// Opens a background editor session — resets tracked intermediate imports.
    func beginBackgroundEditorSession(scope: BackgroundEditScope = .project) {
        hasActiveBackgroundEditor = true
        backgroundEditScope = scope
        backgroundEditorTrackedAssetIds.removeAll()
    }

    /// Returns the current override for the active background edit scope.
    func currentOverrideForEditScope() -> ProjectBackgroundOverride {
        switch backgroundEditScope {
        case .project:
            return session.state?.draft.background ?? .empty
        case .scene(let instanceId):
            return session.state?.draft.sceneInstanceStates[instanceId]?.backgroundOverride
                ?? session.state?.draft.background ?? .empty
        }
    }

    /// Handles preset change during active editor session.
    func handleBackgroundPresetChange(oldPresetId: String, newPresetId: String) {
        clearBackgroundTextures(prefix: "bg/\(oldPresetId)/")
        lastBackgroundPresetId = newPresetId
    }

    /// Full background image import: persist → register → load texture → commit.
    /// All bookkeeping and controller-state branching is runtime-internal.
    /// - Parameter setEditorImage: closure to update the live editor VC (if active).
    func importBackgroundImage(
        sourceFileURL: URL,
        regionId: String,
        setEditorImage: ((String, MediaRef) -> Void)?
    ) async throws {
        guard let bgState = effectiveBackgroundState else { return }

        let capturedGeneration = backgroundImportGeneration
        let sessionPresetId = bgState.preset.presetId

        // 1. Persist
        let mediaRef = try await persistBackgroundImage(
            sourceFileURL: sourceFileURL,
            generation: capturedGeneration,
            sessionPresetId: sessionPresetId
        )

        // 2. Register asset (before texture load so registry resolves)
        session.registerAssetBookkeeping(ProjectAssetDescriptor(
            assetId: mediaRef.assetId,
            mediaKind: mediaRef.mediaKind,
            storagePath: mediaRef.storagePath
        ))
        if hasActiveBackgroundEditor {
            backgroundEditorTrackedAssetIds.insert(mediaRef.assetId)
        }

        // 3. Load texture
        do {
            _ = try await loadBackgroundTexture(
                mediaRef: mediaRef,
                regionId: regionId,
                generation: capturedGeneration,
                sessionPresetId: sessionPresetId
            )
        } catch is BackgroundImportStaleError {
            session.unregisterAssetBookkeeping(mediaRef.assetId)
            backgroundEditorTrackedAssetIds.remove(mediaRef.assetId)
            throw BackgroundImportStaleError()
        } catch {
            session.unregisterAssetBookkeeping(mediaRef.assetId)
            backgroundEditorTrackedAssetIds.remove(mediaRef.assetId)
            throw error
        }

        // 4. Commit
        if hasActiveBackgroundEditor, let setImage = setEditorImage {
            setImage(regionId, mediaRef)
        } else {
            let oldBgAssetId = session.state?.draft.background.regions[regionId]?.imageMediaRef?.assetId
            var bg = session.state?.draft.background ?? .empty
            bg.regions[regionId] = RegionOverride(
                source: .image(ImageOverride(mediaRef: mediaRef, transform: .identity))
            )
            session.dispatch(.setBackground(bg))
            if let oldId = oldBgAssetId, oldId != mediaRef.assetId {
                session.unregisterAssetIfUnreferenced(oldId)
            }
            rebuildEffectiveBackgroundScoped(
                projectOverride: bg,
                sceneOverride: currentSceneBackgroundOverride()
            )
            hasActiveBackgroundEditor = false
        }
    }

    /// Commits background editor dismiss: dispatch override, cleanup, rebuild.
    /// Branches by edit scope: project-level or scene-level.
    func commitBackgroundEditorDismiss(
        override: ProjectBackgroundOverride,
        presetId: String
    ) {
        let scope = backgroundEditScope
        hasActiveBackgroundEditor = false
        incrementBackgroundImportGeneration()

        // Cleanup textures for old preset if changed
        if let oldPresetId = lastBackgroundPresetId, oldPresetId != presetId {
            clearBackgroundTextures(prefix: "bg/\(oldPresetId)/")
        }
        lastBackgroundPresetId = presetId

        switch scope {
        case .project:
            let oldBgAssetIds: Set<ProjectAssetID> = Set(
                (session.state?.draft.background.regions.values ?? [:].values)
                    .compactMap { $0.imageMediaRef?.assetId }
            )
            session.dispatch(.setBackground(override))
            for oldAssetId in oldBgAssetIds {
                session.unregisterAssetIfUnreferenced(oldAssetId)
            }

        case .scene(let instanceId):
            let oldBgAssetIds: Set<ProjectAssetID> = Set(
                (session.state?.draft.sceneInstanceStates[instanceId]?.backgroundOverride?.regions.values ?? [:].values)
                    .compactMap { $0.imageMediaRef?.assetId }
            )
            session.setSceneBackgroundOverride(override, for: instanceId)
            for oldAssetId in oldBgAssetIds {
                session.unregisterAssetIfUnreferenced(oldAssetId)
            }
        }

        // Sweep intermediate imports
        for trackedAssetId in backgroundEditorTrackedAssetIds {
            session.unregisterAssetIfUnreferenced(trackedAssetId)
        }
        backgroundEditorTrackedAssetIds.removeAll()

        // Scope-correct rebuild: resolve project and scene inputs post-commit.
        let projectOverride: ProjectBackgroundOverride?
        let sceneOverride: ProjectBackgroundOverride?
        switch scope {
        case .project:
            projectOverride = override
            sceneOverride = currentSceneBackgroundOverride()
        case .scene:
            projectOverride = session.state?.draft.background
            sceneOverride = override
        }
        rebuildEffectiveBackgroundScoped(projectOverride: projectOverride, sceneOverride: sceneOverride)
        let effState = effectiveBackgroundState
        Task { @MainActor in
            await self.preloadBackgroundTexturesScoped(
                projectOverride: projectOverride, sceneOverride: sceneOverride, effectiveState: effState
            )
        }
    }

    // MARK: - UI Queries

    func videoTrimContext(blockId: String) -> VideoTrimContext? {
        userMediaService?.videoTrimContext(blockId: blockId)
    }

    /// Whether the runtime can commit a video trim (user media service available).
    var canCommitVideoTrim: Bool { userMediaService != nil }

    /// Current video time for a block at a given scene frame index.
    func currentVideoTime(blockId: String, sceneFrameIndex: Int) -> Double {
        userMediaService?.currentVideoTime(blockId: blockId, sceneFrameIndex: sceneFrameIndex) ?? 0
    }

    /// Best estimate of the current local frame for paused video sync.
    var bestLocalFrame: Int {
        playbackCoordinator?.currentLocalFrame ?? currentFrameIndex
    }

    /// Sealed context for media block action bar UI.
    func mediaActionBarContext(blockId: String) -> MediaActionBarContext {
        MediaActionBarContext(
            allowedMedia: scenePlayer?.allowedMedia(blockId: blockId),
            availableVariants: scenePlayer?.availableVariants(blockId: blockId) ?? [],
            selectedVariantId: scenePlayer?.selectedVariantId(blockId: blockId),
            canTrimVideo: userMediaService?.videoTrimContext(blockId: blockId) != nil
        )
    }

    /// Resolves default fit mode for a scene type + block via the timeline engine cache.
    func resolveDefaultFitMode(sceneTypeId: String, blockId: String) async -> FitMode {
        guard let cache = timelineCompositionEngine?.resourcesCache else { return .cover }
        return await DefaultFitResolver.resolve(sceneTypeId: sceneTypeId, blockId: blockId, cache: cache)
    }

    /// Template background definition from the compiled scene.
    var templateBackground: Background? {
        compiledScene?.runtime.scene.background
    }

    /// Canvas size for the scene-edit interaction mapper.
    var queryCanvasSize: SizeD { canvasSize }

    /// Sync coordinator timeline after structure change (scene add/remove/trim).
    func syncCoordinatorTimeline(from state: EditorState) {
        playbackCoordinator?.updateSceneTimeline(from: state)
    }

    /// Sealed overlay/hit-test adapter for scene-edit interaction controller.
    func sceneEditOverlayProvider() -> SceneEditOverlayProviding? {
        scenePlayer
    }

    /// Whether the runtime has a transition compositor available for render.
    var hasTransitionCompositor: Bool { transitionCompositor != nil }

    /// Executes a timeline render request using runtime-owned compositor and diagnostics sink.
    /// Returns false if render could not be executed (e.g. missing compositor for transition).
    func executeTimelineRender(
        _ request: TimelineRenderRequest,
        renderer: MetalRenderer,
        commandQueue: MTLCommandQueue,
        needsTransitionCompositor: Bool,
        completionQueue: DispatchQueue?,
        onCommandBufferCompleted: ((MTLCommandBuffer) -> Void)?
    ) throws -> Bool {
        let compositor = needsTransitionCompositor ? transitionCompositor : nil
        if needsTransitionCompositor && compositor == nil { return false }

        try TimelineRenderExecutor.render(
            request,
            renderer: renderer,
            commandQueue: commandQueue,
            transitionCompositor: compositor,
            completionQueue: completionQueue,
            overlayCache: overlayRenderCache,
            onCommandBufferCompleted: onCommandBufferCompleted,
            renderSink: timelineCompositionEngine?.renderDiagnosticsSink
        )
        return true
    }

    // MARK: - Scene Edit State Queries

    var currentActiveSceneInstanceId: UUID? { activeSceneInstanceId }
    var currentSceneEditReadyInstanceId: UUID? { sceneEditReadyInstanceId }

    /// DEBUG: Verifies boot invariants after initial timeline configuration.
    #if DEBUG
    func assertBootInvariants(uiMode: EditorUIMode) {
        if activeSceneInstanceId == nil {
            assertionFailure("[PR10] configureEditorTimeline: activeSceneInstanceId is nil after initial apply")
        }
        if scenePlayer == nil {
            assertionFailure("[PR10] configureEditorTimeline: scenePlayer is nil after initial apply")
        }
        switch uiMode {
        case .timeline:
            if timelineCompositionEngine?.transitionMath == nil {
                assertionFailure("[PR10] configureEditorTimeline: engine.transitionMath is nil in timeline mode")
            }
        case .sceneEdit:
            if playbackCoordinator?.currentSceneInstanceId == nil {
                assertionFailure("[PR10] configureEditorTimeline: playbackCoordinator.currentSceneInstanceId is nil in scene edit mode")
            }
        }
    }
    #endif

    // MARK: - Private Helpers

    private func selfHealedRegistry() -> ProjectAssetRegistry {
        guard let draft = session.state?.draft else { return ProjectAssetRegistry() }
        return draft.assetRegistry.selfHealed(for: draft)
    }

    private func syncPausedVideoStill(force: Bool) {
        guard !isPlaying else { return }
        let frameIndex: Int
        switch state {
        case .sceneEdit:
            frameIndex = currentFrameIndex
        default:
            // In timeline mode, use engine
            return
        }
        if force || frameIndex != lastStillSyncFrame {
            userMediaService?.updateVideoStillFrames(sceneFrameIndex: frameIndex)
            lastStillSyncFrame = frameIndex
        }
    }

    private func handleMediaReadyForPlacement(blockId: String) {
        guard let instanceId = activeSceneInstanceId,
              let slot = session.state?.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId] else {
            onOutput?(.renderSourceUpdated)
            return
        }
        let _ = reapplyPlacementAfterMediaReady(instanceId: instanceId, blockId: blockId, placement: slot.asset.placement)
    }
}

// MARK: - DisplayLinkTarget

/// Non-self target for CADisplayLink to avoid retain cycle with EditorRuntime.
private final class DisplayLinkTarget {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    @objc func tick() { callback() }
}
