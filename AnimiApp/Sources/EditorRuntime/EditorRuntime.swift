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

    let session: EditorSession

    // MARK: - State

    internal(set) var state: EditorRuntimeState = .idle

    /// Current render source for the view layer.
    /// Every assignment increments `renderSourceRevision` for test observability.
    internal(set) var currentRenderSource: EditorRuntimeRenderSource = .none {
        didSet { renderSourceRevision &+= 1 }
    }

    /// Monotonically increasing counter incremented on every `currentRenderSource` assignment.
    /// Read-only test seam — proves render-source was regenerated, not merely retained.
    private(set) var renderSourceRevision: UInt = 0

    /// Tracks which codepath last triggered a timeline frame refresh.
    /// Read-only test seam — proves engine.onNeedsRedraw fired vs manual playhead change.
    enum RefreshTrigger: Equatable { case none, playheadChanged, engineRedraw, sceneEditMutation }
    internal(set) var lastRefreshTrigger: RefreshTrigger = .none

    var onOutput: ((EditorRuntimeOutput) -> Void)?

    // MARK: - Metal Context

    var metalContext: EditorRuntimeMetalContext?

    // MARK: - Subsystems (moved from PVC)

    private var sceneLibrarySnapshot: SceneLibrarySnapshot?
    var playbackCoordinator: TimelinePlaybackCoordinator?
    internal var timelineCompositionEngine: TimelineCompositionEngine?
    private var transitionCompositor: TransitionCompositor?

    /// Per-owner overlay texture cache for the preview path.
    /// Purged on memory warning; released on deinit.
    let overlayRenderCache = OverlayRenderResourceCache()
    private var memoryWarningObserver: NSObjectProtocol?

    var scenePlayer: ScenePlayer?
    var compiledScene: CompiledScene?
    var textureProvider: (any MutableTextureProvider)?
    var assetResolver: CompositeAssetResolver?

    var userMediaService: UserMediaService?

    // MARK: - Background
    private(set) lazy var background = EditorRuntimeBackgroundController(runtime: self)

    // MARK: - Export
    private(set) lazy var exportController = EditorRuntimeExportController(runtime: self)

    var canvasSize: SizeD = .zero
    var mergedAssetSizes: [String: AssetSize] = [:]

    // MARK: - Frame State

    private var cachedTimelineFrame: ResolvedTimelineFrame?
    private var cachedTimelineCompressedFrame: Int?
    private var currentCompressedFrame: Int = 0
    var currentFrameIndex = 0
    private var totalFrames = 0
    var sceneFPS = 30.0

    // MARK: - Playback

    private(set) var isPlaying = false
    private var displayLink: CADisplayLink?
    private var playheadAsyncTask: Task<Void, Never>?
    private var playbackStartTask: Task<Void, Never>?
    var lastStillSyncFrame: Int = -1
    private let playbackTransport = PlaybackTransport()
    private var playbackCurrentCompressedFrame: Int = 0
    var playbackCurrentProjectTimeUs: TimeUs = 0

    // MARK: - Preview Audio
    private(set) lazy var previewAudio = EditorRuntimePreviewAudioCoordinator(runtime: self)
    var playbackCurrentHostTime: CFTimeInterval = 0

    #if DEBUG
    /// Test-observable counter: incremented each time timeline presentation is resolved.
    private(set) var timelinePresentResolveCount: Int = 0
    #endif

    // MARK: - Scene Edit
    private(set) lazy var sceneEdit = EditorRuntimeSceneEditController(runtime: self)

    typealias ActiveExportRequest = EditorRuntimeExportController.ActiveExportRequest

    /// Scope of the active background editor session.
    enum BackgroundEditScope {
        case project
        case scene(instanceId: UUID)
    }

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

    /// Test seam: simulate playback active state without requiring CADisplayLink.
    func setPlayingForTesting(_ playing: Bool) {
        self.isPlaying = playing
    }

    /// Test seam: forwards to the production `handleMediaReadyForPlacement`.
    /// Exercises the exact same path that `UserMediaService.onMediaReady` invokes in production.
    func simulateMediaReadyCallback(blockId: String) {
        sceneEdit.handleMediaReadyForPlacement(blockId: blockId)
    }

    /// Test seam: exposes the timeline composition engine for cache pre-population.
    var testTimelineCompositionEngine: TimelineCompositionEngine? { timelineCompositionEngine }

    /// Test seam: exposes background texture service for export-restore verification.
    var testBackgroundTextureService: BackgroundTextureService? { background.backgroundTextureService }

    /// Test seam: triggers export teardown without starting actual export.
    func simulateEnterExportMode() {
        exportController.enterExportMode()
    }

    /// Test seam: async exit-export-mode with background texture restore.
    func simulateExitExportModeToIdle() async {
        await exportController.exitExportModeToIdle()
    }

    /// Test seam: simulates exporter completion callback with a fake active request.
    func simulateHandleExportCompletion(result: Result<URL, Error>) {
        exportController.simulateHandleExportCompletion(result: result)
    }

    /// Test seam: inject a mock preview audio controller.
    func setPreviewAudioController(_ controller: PreviewAudioControlling) {
        previewAudio.controller = controller
    }

    var previewAudioDirty: Bool { previewAudio.dirty }
    var previewAudioGeneration: UInt { previewAudio.generation }

    /// Test seam: override pipeline builder for controllable async builds.
    var previewAudioPipelineBuilder: (() async -> BuiltAudioPipeline?)? {
        get { previewAudio.pipelineBuilder }
        set { previewAudio.pipelineBuilder = newValue }
    }

    /// Test seam: gate that suspends production build before detached task launch.
    var previewAudioBuildGate: (() async -> Void)? {
        get { previewAudio.buildGate }
        set { previewAudio.buildGate = newValue }
    }

    /// Test seam: whether the detached audio build task or orchestration task is active.
    var hasActivePreviewAudioBuildTask: Bool {
        previewAudio.buildTask != nil
    }

    /// Test seam: whether orchestration or detached build is active.
    var hasActivePreviewAudioOrchestration: Bool {
        previewAudio.orchestrationTask != nil || previewAudio.buildTask != nil
    }

    /// Test seam: set isPlaying without full playback machinery.
    func simulateSetPlaying(_ playing: Bool) {
        setPlayingForTesting(playing)
    }

    /// Test seam: inject a timeline composition engine for playback tests.
    func injectTimelineCompositionEngine(_ engine: TimelineCompositionEngine) {
        self.timelineCompositionEngine = engine
    }

    /// Test seam: inject known transport time for readiness tests.
    func setPreviewAudioPlaybackTimeForTesting(projectTimeUs: TimeUs, hostTime: CFTimeInterval) {
        playbackCurrentProjectTimeUs = projectTimeUs
        playbackCurrentHostTime = hostTime
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
        background.setupBackground(compiled: loadResult.compiled)
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
                self?.sceneEdit.refreshSceneEditIfActive()
                self?.syncPausedVideoStill(force: true)
            }
            ums.onStillFrameDelivered = { [weak self] in
                self?.sceneEdit.refreshSceneEditIfActive()
            }
            ums.onMediaReady = { [weak self] blockId in
                self?.sceneEdit.handleMediaReadyForPlacement(blockId: blockId)
            }
            self.userMediaService = ums
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
                self?.sceneEdit.refreshSceneEditIfActive()
                self?.syncPausedVideoStill(force: true)
            }
            userMediaService?.onStillFrameDelivered = { [weak self] in
                self?.sceneEdit.refreshSceneEditIfActive()
            }
            userMediaService?.onMediaReady = { [weak self] blockId in
                self?.sceneEdit.handleMediaReadyForPlacement(blockId: blockId)
            }
        }

        let newCanvasSize = loadedScene.compiled.runtime.canvasSize
        if canvasSize != newCanvasSize {
            canvasSize = newCanvasSize
        }

        logger.debug("[EditorRuntime] Coordinator loaded scene: \(loadedScene.sceneTypeId)")

        // Apply per-instance state after scene load (skip during scene-edit activation)
        if sceneEdit.sceneEditReadyInstanceId != nil, let instanceId = sceneEdit.activeSceneInstanceId {
            sceneEdit.resetRuntimeForSceneInstanceChange()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.applySceneInstanceState(instanceId: instanceId)
                self.sceneEdit.refreshSceneEditIfActive()
            }
        }

        sceneEdit.refreshSceneEditIfActive()
    }

    // MARK: - Active Scene Changed

    private func handleActiveSceneChanged(_ sceneInfo: TimelinePlaybackCoordinator.SceneTimeInfo) {
        // In timeline mode, engine is source of truth — ignore coordinator callback
        guard case .sceneEdit = state else { return }

        let previousInstanceId = sceneEdit.activeSceneInstanceId
        sceneEdit.activeSceneInstanceId = sceneInfo.sceneInstanceId

        guard sceneEdit.sceneEditReadyInstanceId != nil else { return }

        if let coordinator = playbackCoordinator,
           coordinator.currentSceneTypeId == sceneInfo.sceneTypeId,
           scenePlayer != nil {
            if previousInstanceId != sceneInfo.sceneInstanceId {
                sceneEdit.resetRuntimeForSceneInstanceChange()
                let newInstanceId = sceneInfo.sceneInstanceId
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.applySceneInstanceState(instanceId: newInstanceId)
                    self.sceneEdit.refreshSceneEditIfActive()
                }
            }
        }
    }

    func applySceneInstanceState(instanceId: UUID) async {
        await sceneEdit.applySceneInstanceState(instanceId: instanceId)
    }

    // MARK: - Playhead Handling

    func handlePlayheadChanged(_ compressedFrame: Int) {
        // During playback, transport drives presentation directly via displayLinkFired.
        // Store playhead changes are UI-mirror only — must not re-enter presentation path.
        guard !isPlaying else { return }

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
        sceneEdit.activeSceneInstanceId = engine.sceneInstanceId(at: compressedFrame)

        // Eagerly recompute background for the background-owning scene.
        // For transitions, the outgoing scene (A) owns the background.
        let bgOwnerId = background.backgroundOwnerInstanceId(at: compressedFrame, engine: engine)
        if let bgOwnerId {
            background.updatePreviewBackgroundForScene(bgOwnerId)
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

        #if DEBUG
        timelinePresentResolveCount += 1
        #endif

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
                    self.sceneEdit.activeSceneInstanceId = ctx.sceneInstanceId
                case .transition:
                    self.sceneEdit.activeSceneInstanceId = engine.sceneInstanceId(at: compressedFrame)
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
                if let previewBgState = self.background.resolvePreviewBackgroundState(for: resolved) {
                    self.background.effectiveBackgroundState = previewBgState
                }

                // Update render source
                self.currentRenderSource = .timeline(TimelineRenderSourcePayload(
                    resolvedFrame: resolved,
                    backgroundState: self.background.effectiveBackgroundState,
                    backgroundTextureProvider: self.background.backgroundTextureProvider,
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
        guard sceneEdit.sceneEditReadyInstanceId != nil else { return }
        guard let coordinator = playbackCoordinator else { return }

        let mapper = session.state?.makePlayheadMapper() ?? TimelinePlayheadMapper.empty
        let timeUs = mapper.nominalTimeUs(forCompressedFrame: compressedFrame)

        if let localFrame = coordinator.syncSetGlobalTimeUs(timeUs) {
            playheadAsyncTask?.cancel()
            playheadAsyncTask = nil

            currentFrameIndex = localFrame
            sceneEdit.updateSceneEditRenderSource()

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
                self.sceneEdit.updateSceneEditRenderSource()

                if !self.isPlaying, localFrame != self.lastStillSyncFrame {
                    self.userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
                    self.lastStillSyncFrame = localFrame
                }
            }
        }
    }
    func activateSceneEditTarget(instanceId: UUID) {
        sceneEdit.activateSceneEditTarget(instanceId: instanceId)
    }

    func deactivateSceneEdit() {
        sceneEdit.deactivateSceneEdit()
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

            // Compute start project time from compressed frame
            let mapper = self.session.state?.makePlayheadMapper() ?? .empty
            let startProjectTimeUs = mapper.nominalTimeUs(forCompressedFrame: compressedFrame)
            let hostTime = CACurrentMediaTime()
            self.playbackCurrentHostTime = hostTime

            self.playbackCurrentCompressedFrame = compressedFrame
            self.playbackCurrentProjectTimeUs = startProjectTimeUs
            self.playbackTransport.start(
                atProjectTimeUs: startProjectTimeUs,
                hostTime: hostTime,
                fps: Int(self.sceneFPS)
            )

            self.isPlaying = true

            self.displayLink = CADisplayLink(target: DisplayLinkTarget { [weak self] link in
                self?.displayLinkFired(link)
            }, selector: #selector(DisplayLinkTarget.tick))
            self.displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
            self.displayLink?.add(to: .main, forMode: .common)

            engine.startPlayback(at: compressedFrame, hostTime: hostTime)

            self.onOutput?(.playbackStateChanged(isPlaying: true))
            self.previewAudio.startForTimelinePlayback()
            self.playbackStartTask = nil
        }
    }

    func stopPlayback() {
        playbackStartTask?.cancel()
        playbackStartTask = nil
        previewAudio.controller.pause()
        previewAudio.generation &+= 1
        previewAudio.cancelBuild()

        playbackTransport.stop()
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

    private func displayLinkFired(_ link: CADisplayLink) {
        guard let editorState = session.state else { return }

        let hostTime = link.targetTimestamp
        let mapper = editorState.makePlayheadMapper()
        let maxFrame = editorState.compressedDurationFrames - 1

        guard let sample = playbackTransport.sample(
            mapper: mapper,
            maxCompressedFrame: maxFrame,
            hostTime: hostTime
        ) else { return }

        let nextFrame = sample.compressedFrame
        playbackCurrentCompressedFrame = nextFrame
        playbackCurrentProjectTimeUs = sample.projectTimeUs
        playbackCurrentHostTime = hostTime

        let uiMode = editorState.uiMode
        switch uiMode {
        case .timeline:
            // Drive frame presentation directly from transport
            handleTimelineModePlayheadChanged(nextFrame)
            timelineCompositionEngine?.syncPlaybackTick(nextFrame, hostTime: hostTime)
        case .sceneEdit:
            let fps = editorState.templateFPS
            let globalFrameIndex = Int(sample.projectTimeUs * TimeUs(fps) / 1_000_000)
            let localFrame = playbackCoordinator?.currentLocalFrame ?? globalFrameIndex
            if let service = userMediaService,
               !service.blockIdsWithVideo.isEmpty,
               localFrame != lastStillSyncFrame {
                service.updateVideoFramesForPlayback(sceneFrameIndex: localFrame)
                lastStillSyncFrame = localFrame
            }
        }

        // Mirror to store as compatibility projection (only if frame changed)
        if nextFrame != editorState.playheadCompressedFrame {
            session.dispatch(.setPlayhead(compressedFrame: nextFrame))
        }

        if nextFrame >= maxFrame {
            stopPlayback()
        }
    }

    // MARK: - Export Facade

    enum ExportPreflightChoice {
        case cancel
        case continueOriginal
        case useRecommended(preset: VideoQualityPreset, sizePx: (width: Int, height: Int))
    }

    var isExporting: Bool { exportController.isExporting }

    var makeDeliverer: () -> ExportDelivering {
        get { exportController.makeDeliverer }
        set { exportController.makeDeliverer = newValue }
    }

    func startExport(policy: ExportDeliveryPolicy) { exportController.startExport(policy: policy) }
    func cancelExport() { exportController.cancelExport() }
    func applyExportPreflightChoice(_ choice: ExportPreflightChoice) { exportController.applyExportPreflightChoice(choice) }
    func executeExport() async { await exportController.executeExport() }
    func confirmShareCompleted() { exportController.confirmShareCompleted() }

    func isActiveExportRequest(_ requestId: UUID) -> Bool { exportController.isActiveExportRequest(requestId) }
    func clearExportRequestIfCurrent(_ requestId: UUID) { exportController.clearExportRequestIfCurrent(requestId) }

    /// PR8: Builds AudioTrackConfig from the project's canonical timeline music item.
    func buildProjectMusicTrackConfig() async -> AudioTrackConfig? {
        guard let state = session.state,
              let item = state.canonicalTimeline.musicItem,
              let payload = state.canonicalTimeline.musicPayload(),
              case .imported(let assetId, let contentStoragePath) = payload.assetRef else {
            return nil
        }

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

    // MARK: - Scene Edit Delegates

    func updateInteractiveTrimPreview(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double) {
        sceneEdit.updateInteractiveTrimPreview(blockId: blockId, draftSelection: draftSelection, previewTime: previewTime)
    }

    func endInteractiveTrimPreview(blockId: String) {
        sceneEdit.endInteractiveTrimPreview(blockId: blockId)
    }

    func previewExactVideoTrimFrame(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double) {
        sceneEdit.previewExactVideoTrimFrame(blockId: blockId, draftSelection: draftSelection, previewTime: previewTime)
    }

    func applyPersistedVideoSelection(blockId: String, _ selection: PersistedVideoSelection) throws {
        try sceneEdit.applyPersistedVideoSelection(blockId: blockId, selection)
    }

    func clearMediaSlot(blockId: String) {
        sceneEdit.clearMediaSlot(blockId: blockId)
    }

    func setSelectedVariant(blockId: String, variantId: String) {
        sceneEdit.setSelectedVariant(blockId: blockId, variantId: variantId)
    }

    func syncVideoStillFrames(sceneFrameIndex: Int) {
        sceneEdit.syncVideoStillFrames(sceneFrameIndex: sceneFrameIndex)
    }

    @discardableResult
    func applyMediaPlacementChange(instanceId: UUID, blockId: String, placement: MediaPlacementState) -> Bool {
        sceneEdit.applyMediaPlacementChange(instanceId: instanceId, blockId: blockId, placement: placement)
    }

    @discardableResult
    func applyMediaVisibilityChange(instanceId: UUID, blockId: String, visible: Bool) -> Bool {
        sceneEdit.applyMediaVisibilityChange(instanceId: instanceId, blockId: blockId, visible: visible)
    }

    func applyMediaSlotChange(instanceId: UUID, blockId: String, slot: SceneMediaSlot?) {
        sceneEdit.applyMediaSlotChange(instanceId: instanceId, blockId: blockId, slot: slot)
    }

    func applySceneStateChange(instanceId: UUID, sceneState: SceneState) {
        sceneEdit.applySceneStateChange(instanceId: instanceId, sceneState: sceneState)
    }

    func applyVideoSelectionToEngine(selection: PersistedVideoSelection, blockId: String, instanceId: UUID) {
        sceneEdit.applyVideoSelectionToEngine(selection: selection, blockId: blockId, instanceId: instanceId)
    }

    func syncEngineAfterUndoRedo(state: EditorState) {
        sceneEdit.syncEngineAfterUndoRedo(state: state)
    }

    // MARK: - Background Facade

    var effectiveBackgroundState: EffectiveBackgroundState? { background.effectiveBackgroundState }
    var hasActiveBackgroundEditor: Bool { background.hasActiveBackgroundEditor }
    var backgroundImportGeneration: UInt { background.backgroundImportGeneration }

    func persistBackgroundImage(sourceFileURL: URL, generation: UInt, sessionPresetId: String) async throws -> MediaRef {
        try await background.persistBackgroundImage(sourceFileURL: sourceFileURL, generation: generation, sessionPresetId: sessionPresetId)
    }

    func loadBackgroundTexture(mediaRef: MediaRef, regionId: String, generation: UInt, sessionPresetId: String) async throws -> String {
        try await background.loadBackgroundTexture(mediaRef: mediaRef, regionId: regionId, generation: generation, sessionPresetId: sessionPresetId)
    }

    func deleteBackgroundMediaFile(_ mediaRef: MediaRef) async throws {
        try await background.deleteBackgroundMediaFile(mediaRef)
    }

    func clearBackgroundTexture(slotKey: String) { background.clearBackgroundTexture(slotKey: slotKey) }
    func clearAllBackgroundTextures() { background.clearAllBackgroundTextures() }
    func incrementBackgroundImportGeneration() { background.incrementBackgroundImportGeneration() }

    func applyBackgroundPreviewOverride(_ override: ProjectBackgroundOverride) {
        background.applyBackgroundPreviewOverride(override)
    }

    func beginBackgroundEditorSession(scope: BackgroundEditScope = .project) {
        background.beginBackgroundEditorSession(scope: scope)
    }

    func currentOverrideForEditScope() -> ProjectBackgroundOverride {
        background.currentOverrideForEditScope()
    }

    func handleBackgroundPresetChange(oldPresetId: String, newPresetId: String) {
        background.handleBackgroundPresetChange(oldPresetId: oldPresetId, newPresetId: newPresetId)
    }

    func importBackgroundImage(sourceFileURL: URL, regionId: String, setEditorImage: ((String, MediaRef) -> Void)?) async throws {
        try await background.importBackgroundImage(sourceFileURL: sourceFileURL, regionId: regionId, setEditorImage: setEditorImage)
    }

    func commitBackgroundEditorDismiss(override: ProjectBackgroundOverride, presetId: String) {
        background.commitBackgroundEditorDismiss(override: override, presetId: presetId)
    }

    func preloadBackgroundTexturesScoped(
        projectOverride: ProjectBackgroundOverride?,
        sceneOverride: ProjectBackgroundOverride?,
        effectiveState: EffectiveBackgroundState?
    ) async {
        await background.preloadBackgroundTexturesScoped(
            projectOverride: projectOverride, sceneOverride: sceneOverride, effectiveState: effectiveState
        )
    }

    @discardableResult
    func reapplyPlacementAfterMediaReady(instanceId: UUID?, blockId: String, placement: MediaPlacementState) -> Bool {
        sceneEdit.reapplyPlacementAfterMediaReady(instanceId: instanceId, blockId: blockId, placement: placement)
    }

    /// Marks preview audio state as dirty (e.g. after timeline music changes).
    func markPreviewAudioDirty() {
        previewAudio.markDirty()
    }

    /// Builds an AudioExportConfig from the project's canonical timeline music.
    func buildPreviewAudioConfig(includeOriginalFromVideoSlots: Bool) async -> AudioExportConfig? {
        await previewAudio.buildConfig(includeOriginalFromVideoSlots: includeOriginalFromVideoSlots)
    }

    // MARK: - UI Queries

    func videoTrimContext(blockId: String) -> VideoTrimContext? {
        sceneEdit.videoTrimContext(blockId: blockId)
    }

    var canCommitVideoTrim: Bool { userMediaService != nil }

    func currentVideoTime(blockId: String, sceneFrameIndex: Int) -> Double {
        sceneEdit.currentVideoTime(blockId: blockId, sceneFrameIndex: sceneFrameIndex)
    }

    var bestLocalFrame: Int {
        playbackCoordinator?.currentLocalFrame ?? currentFrameIndex
    }

    func mediaActionBarContext(blockId: String) -> MediaActionBarContext {
        sceneEdit.mediaActionBarContext(blockId: blockId)
    }

    func resolveDefaultFitMode(sceneTypeId: String, blockId: String) async -> FitMode {
        guard let cache = timelineCompositionEngine?.resourcesCache else { return .cover }
        return await DefaultFitResolver.resolve(sceneTypeId: sceneTypeId, blockId: blockId, cache: cache)
    }

    var templateBackground: Background? {
        compiledScene?.runtime.scene.background
    }

    var queryCanvasSize: SizeD { canvasSize }

    func syncCoordinatorTimeline(from state: EditorState) {
        playbackCoordinator?.updateSceneTimeline(from: state)
    }

    func sceneEditOverlayProvider() -> SceneEditOverlayProviding? {
        sceneEdit.sceneEditOverlayProvider()
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

    var currentActiveSceneInstanceId: UUID? { sceneEdit.activeSceneInstanceId }
    var currentSceneEditReadyInstanceId: UUID? { sceneEdit.sceneEditReadyInstanceId }

    /// DEBUG: Verifies boot invariants after initial timeline configuration.
    #if DEBUG
    func assertBootInvariants(uiMode: EditorUIMode) {
        if sceneEdit.activeSceneInstanceId == nil {
            assertionFailure("[PR10] configureEditorTimeline: sceneEdit.activeSceneInstanceId is nil after initial apply")
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

    func selfHealedRegistry() -> ProjectAssetRegistry {
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

}

// MARK: - SceneEditToolRuntimeControlling

extension EditorRuntime: SceneEditToolRuntimeControlling {
    func reloadSceneEditState(instanceId: UUID) async {
        sceneEdit.resetRuntimeForSceneInstanceChange()
        await applySceneInstanceState(instanceId: instanceId)
    }
}

// MARK: - DisplayLinkTarget

/// Non-self target for CADisplayLink to avoid retain cycle with EditorRuntime.
private final class DisplayLinkTarget {
    let callback: (CADisplayLink) -> Void
    init(callback: @escaping (CADisplayLink) -> Void) { self.callback = callback }
    @objc func tick(_ link: CADisplayLink) { callback(link) }
}
