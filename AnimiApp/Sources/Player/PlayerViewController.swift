import UIKit
import MetalKit
import PhotosUI
import UniformTypeIdentifiers
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "PlayerViewController")

// MARK: - PR-D: Template Loading State

/// State machine for template loading (PR-D: async load + "Preparing" UI).
enum TemplateLoadingState: Equatable {
    case idle
    case preparing(requestId: UUID)
    case ready
    case failed(message: String)

    static func == (lhs: TemplateLoadingState, rhs: TemplateLoadingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.ready, .ready):
            return true
        case (.preparing(let a), .preparing(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - PR-D: Async Loading Helper Structs

/// Result from ScenePlayer setup phase (main actor only, not Sendable).
private struct SceneSetupResult {
    let player: ScenePlayer
    let compiled: CompiledScene
}

/// Main player view controller with Metal rendering surface.
/// PR-E: Production-only editor mode (dev-UI removed).
final class PlayerViewController: UIViewController {

    // MARK: - Entry Context

    /// Describes how the editor was entered.
    enum EntryContext {
        case newFromTemplate(templateId: String)
        case openSavedProject(projectId: UUID, sourceTemplateId: String)
        case resumeActiveDraft
    }

    private let entryContext: EntryContext
    private var activeDraftSlot: ActiveDraftSlot?

    init(entryContext: EntryContext) {
        self.entryContext = entryContext
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        autosaveTimer?.invalidate()
        NotificationCenter.default.removeObserver(self, name: .appDidEnterBackground, object: nil)
        // Defense-in-depth: cancel ingest tasks even if viewWillDisappear was somehow skipped.
        // Uses nonisolated helper since deinit cannot call @MainActor methods.
        mediaIngestCoordinator.cancelAllFromDeinit()
    }

    @objc private func appDidEnterBackground() {
        if !userMadeExplicitCloseChoice {
            saveDraftToActiveSlot()
        }
    }

    // MARK: - Export State

    final class ActiveExportRequest {
        let id: UUID
        let exporter: VideoExporter

        /// Strongly retains the in-flight delivery operation until terminal completion.
        var deliveryFlow: ExportDeliveryFlow?

        init(id: UUID, exporter: VideoExporter) {
            self.id = id
            self.exporter = exporter
        }

        /// Returns true if `requestId` matches this request's id.
        func isActive(for requestId: UUID) -> Bool {
            id == requestId
        }
    }

    private var activeExportRequest: ActiveExportRequest?
    private var isExporting: Bool { activeExportRequest != nil }

    /// True if `requestId` matches the currently active export request.
    /// Used as the single gating predicate for all request-scoped callbacks.
    func isActiveExportRequest(_ requestId: UUID) -> Bool {
        activeExportRequest?.isActive(for: requestId) ?? false
    }

    /// Clears activeExportRequest only if it matches `requestId`.
    /// Prevents stale cancel from request A clearing active request B.
    func clearExportRequestIfCurrent(_ requestId: UUID) {
        guard isActiveExportRequest(requestId) else { return }
        activeExportRequest = nil
    }

    // MARK: - Metal View

    private lazy var metalView: MTKView = {
        let mtkView = MTKView()
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.layer.cornerRadius = 8
        mtkView.clipsToBounds = true
        mtkView.delegate = self
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        return mtkView
    }()

    // MARK: - Rendering

    private lazy var commandQueue: MTLCommandQueue? = { metalView.device?.makeCommandQueue() }()
    private var renderer: MetalRenderer?
    /// PR-33: Use protocol type for flexibility
    private var textureProvider: (any MutableTextureProvider)?
    private var currentResolver: CompositeAssetResolver?

    // Scene playback
    private var compiledScene: CompiledScene?
    private var canvasSize: SizeD = .zero
    private var mergedAssetSizes: [String: AssetSize] = [:]

    // Playback state
    private var currentFrameIndex = 0
    private var totalFrames = 0
    private var displayLink: CADisplayLink?
    private var isPlaying = false
    private var sceneFPS = 30.0

    // MARK: - Scrub Render Throttle (A/B Testing)
    /// True when user is actively dragging the timeline scrubber
    private var isScrubDragging = false
    /// Last time we triggered a Metal render during scrub drag
    private var lastScrubRenderAt: CFTimeInterval = 0
    /// True if a render was skipped due to throttle and needs to be done on .ended
    private var pendingScrubRender = false
    private var renderErrorLogged = false
    private var deviceHeaderLogged = false
    /// PR-33: Track last frame to avoid redundant video updates
    private var lastStillSyncFrame: Int = -1
    /// Release v1: Track async playhead task to cancel stale requests
    private var playheadAsyncTask: Task<Void, Never>?
    /// PR-G: Track async playback start task for cancellation
    private var playbackStartTask: Task<Void, Never>?

    // MARK: - Editor (PR-19)
    private var scenePlayer: ScenePlayer?

    // MARK: - PR2: EditorStore (centralized state management)
    private var editorStore: EditorStore?

    // MARK: - Release v1: Scene Library + Playback Coordinator
    private var sceneLibrarySnapshot: SceneLibrarySnapshot?
    private var playbackCoordinator: TimelinePlaybackCoordinator?
    private var defaultSceneSequence: [SceneTypeDefault] = []

    // MARK: - Multi-Scene Timeline Engine (PR-F)
    /// Composition engine for multi-scene timeline with transitions.
    /// Created when timeline has multiple scenes with transitions.
    private var timelineCompositionEngine: TimelineCompositionEngine?
    /// Transition compositor for GPU blending during transitions.
    private var transitionCompositor: TransitionCompositor?
    /// Cached resolved frame for timeline mode (pre-resolved async before draw).
    private var cachedTimelineFrame: ResolvedTimelineFrame?
    /// Cached compressed frame matching cachedTimelineFrame (for diagnostic tag).
    private var cachedTimelineCompressedFrame: Int?
    /// Current compressed frame for timeline mode (for scrub invalidation).
    private var currentCompressedFrame: Int = 0

    // MARK: - PR9: Active Scene Instance Tracking
    /// Currently active scene instance ID (for per-instance state apply).
    private var activeSceneInstanceId: UUID?

    /// Set after scene-edit activation completes; gates render to prevent stale frames.
    private var sceneEditReadyInstanceId: UUID?
    /// Cancellable task for scene-edit activation (prevents races on rapid switching).
    private var sceneEditActivationTask: Task<Void, Never>?

    /// Write-target resolution: in scene-edit returns uiMode target;
    /// otherwise returns runtime activeSceneInstanceId.
    /// Production code and tests share this single implementation.
    static func resolveWriteTargetForSceneEdit(
        uiMode: EditorUIMode,
        activeSceneInstanceId: UUID?
    ) -> UUID? {
        if case .sceneEdit(let id) = uiMode {
            return id
        }
        return activeSceneInstanceId
    }

    /// Write-target for scene-edit persistence: delegates to the static resolver.
    private var sceneEditTargetInstanceId: UUID? {
        guard let uiMode = editorStore?.state.uiMode else { return nil }
        return Self.resolveWriteTargetForSceneEdit(
            uiMode: uiMode,
            activeSceneInstanceId: activeSceneInstanceId
        )
    }

    private func assertSceneEditTargetMatchesRuntimeIfPossible() {
        #if DEBUG
        // Activation in progress — divergence is expected
        guard sceneEditReadyInstanceId != nil else { return }
        guard let target = sceneEditTargetInstanceId,
              let runtime = activeSceneInstanceId,
              target != runtime else { return }
        logger.debug("[BUG-GUARD] sceneEditTargetInstanceId (\(target)) != activeSceneInstanceId (\(runtime))")
        assertionFailure("[BUG-GUARD] Scene edit target diverged from runtime active scene")
        #endif
    }

    /// Activates a specific scene for scene-edit by instance ID.
    /// Blocks render via sceneEditReadyInstanceId until activation completes.
    private func activateSceneEditTarget(instanceId: UUID) {
        // Cancel any in-flight activation
        sceneEditActivationTask?.cancel()
        // Block render immediately
        sceneEditReadyInstanceId = nil

        sceneEditActivationTask = Task { @MainActor [weak self] in
            guard let self, let coordinator = self.playbackCoordinator else { return }

            guard let (_, localFrame) = await coordinator.activateSceneByInstanceId(instanceId) else {
                return // Scene not found or stale
            }
            guard !Task.isCancelled else { return }

            self.activeSceneInstanceId = instanceId
            self.currentFrameIndex = localFrame
            self.resetRuntimeForSceneInstanceChange()
            self.applySceneInstanceState(instanceId: instanceId)

            // Unblock render
            self.sceneEditReadyInstanceId = instanceId

            self.refreshSceneEditBars()
            self.sceneEditController?.updateOverlay()
            self.requestMetalRender()

            // Sync video frames at frame 0
            if !self.isPlaying {
                self.userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
                self.lastStillSyncFrame = localFrame
            }
        }
    }

    /// Active inline video trim session. Nil when not trimming.
    private var videoTrimSession: VideoTrimSession?

    /// Thumbnail provider for the active trim session filmstrip.
    private var trimThumbnailProvider: VideoTrimThumbnailProvider?

    // MARK: - PR2: Visual Editor Timeline
    private var currentProjectDraft: ProjectDraft?
    /// Tracks whether draft has unsaved changes.
    private var draftIsDirty = false
    /// Tracks whether user made explicit Save/Don't Save choice (prevents double-save in viewWillDisappear).
    private var userMadeExplicitCloseChoice = false
    /// Periodic autosave timer (crash recovery safety net).
    private var autosaveTimer: Timer?
    private lazy var editorLayoutContainer = EditorLayoutContainerView()
    private weak var fullScreenPreviewVC: FullScreenPreviewViewController?

    // MARK: - User Media (PR-32)
    private var userMediaService: UserMediaService?
    private lazy var overlayView = EditorOverlayView()

    // MARK: - Scene Edit Mode (PR-D)
    private var sceneEditController: SceneEditInteractionController?

    // MARK: - Background (PR3)
    private var backgroundTextureService: BackgroundTextureService?
    private var effectiveBackgroundState: EffectiveBackgroundState?
    private var currentProjectId: UUID?
    private var projectBackgroundOverride: ProjectBackgroundOverride?
    private var currentTemplateId: String?
    private var pendingBackgroundRegionId: String?
    private weak var pendingBackgroundEditor: BackgroundEditorViewController?
    private var lastBackgroundPresetId: String?
    /// Generation counter for background image imports. Incremented on each new picker request
    /// and on editor dismiss, so stale async completions detect they are no longer current.
    private var backgroundImportGeneration: UInt = 0

    /// PR-G: Shared background texture provider for project-level background images.
    /// Written by BackgroundTextureService, read by all render paths (preview, transition, export).
    /// Separate from scene texture providers to ensure background textures are always accessible.
    private var backgroundTextureProvider: InMemoryTextureProvider?

    /// Media ingest coordinator — handles PHPicker → prepare → persist → bind pipeline.
    /// Initialized once on VC lifecycle, not lazily in delegate callback.
    private var showsMediaIngestStatusOverlay = true
    private var showsMediaIngestStatusInActionBar = true
    private lazy var ingestStatusOverlayView = MediaIngestStatusOverlayView()
    private var ingestFailureAlertedKeys: Set<IngestSlotKey> = []

    private lazy var mediaIngestCoordinator: MediaIngestCoordinator = {
        let coordinator = MediaIngestCoordinator()
        coordinator.onIngestComplete = { [weak self] result in
            guard let self else {
                // VC deallocated — clean up orphaned persisted file immediately
                try? FileManager.default.removeItem(at: result.persistedURL)
                return
            }
            Task { @MainActor [self] in
                await self.handleIngestComplete(result)
            }
        }
        coordinator.onStatusChanged = { [weak self] key, status in
            self?.handleIngestStatusChanged(key: key, status: status)
        }
        return coordinator
    }()

    /// Pending picker request — captures (sceneInstanceId, blockId) at picker open time.
    /// Consumed in PHPickerDelegate. The sceneInstanceId is the source of truth for
    /// which scene this media belongs to, NOT the current sceneEditTargetInstanceId at callback time.
    private var pendingPickerRequest: IngestSlotKey?

    // In-flight frame limiting (must match MetalRendererOptions.maxFramesInFlight)
    private static let maxFramesInFlight = 3
    private let inFlightSemaphore = DispatchSemaphore(value: maxFramesInFlight)

    // PR-A: renderQueue removed — no longer needed after warmRender removal.
    // draw(in:) is protected by dispatchPrecondition(.onQueue(.main)).

    // MARK: - PR-D: Async Template Loading
    private var loadingState: TemplateLoadingState = .idle
    private var preparingTask: Task<Void, Never>?
    private var currentRequestId: UUID?
    private lazy var preparingOverlay = PreparingOverlayView()

    // PR1.3: Performance logging (DEBUG only)
    #if DEBUG
    private let perfLogger = PerfLogger(intervalSeconds: 2.0)
    #endif

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupRenderer()
        setupEditorLayout()
        let deviceName = metalView.device?.name ?? "N/A"
        log("AnimiApp initialized, TVECore: \(TVECore.version), Metal: \(deviceName)")

        // Lifecycle observers for background save
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: .appDidEnterBackground, object: nil
        )

        // Autosave timer (crash recovery safety net, 30s interval)
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.saveDraftToActiveSlot()
        }

        // Load content based on entry context
        Task { @MainActor in
            await loadEditorContent()
        }
    }

    // MARK: - Release v1: Editor Content Loading

    /// Loads all editor content: SceneLibrary, template defaults, ProjectDraft, and first scene.
    private func loadEditorContent() async {
        // Resolve templateId and draft from entry context
        let templateId: String
        let draft: ProjectDraft

        switch entryContext {
        case .newFromTemplate(let tplId):
            templateId = tplId
            let newDraft = ProjectDraft.create(for: tplId)
            let slot = ActiveDraftSlot(
                entryContext: .newFromTemplate(templateId: tplId),
                sourceTemplateId: tplId,
                linkedSavedProjectId: nil,
                draft: newDraft
            )
            do {
                try ProjectStore.shared.saveActiveDraft(slot)
            } catch {
                log("[Editor] ERROR: Failed to save active draft: \(error)")
            }
            activeDraftSlot = slot
            draft = newDraft
            log("[Editor] New from template: \(tplId), draft: \(newDraft.id)")

        case .openSavedProject(let projectId, let sourceTemplateId):
            templateId = sourceTemplateId
            guard let record = ProjectStore.shared.loadSavedProject(projectId: projectId) else {
                log("[Editor] ERROR: Cannot load saved project \(projectId)")
                loadingState = .failed(message: "Project load failed")
                updateLoadingStateUI()
                return
            }
            let slot = ActiveDraftSlot(
                entryContext: .openSavedProject(projectId: projectId),
                sourceTemplateId: sourceTemplateId,
                linkedSavedProjectId: projectId,
                draft: record.draft
            )
            do {
                try ProjectStore.shared.saveActiveDraft(slot)
            } catch {
                log("[Editor] ERROR: Failed to save active draft: \(error)")
            }
            activeDraftSlot = slot
            draft = record.draft
            log("[Editor] Opened saved project: \(projectId)")

        case .resumeActiveDraft:
            guard let slot = ProjectStore.shared.loadActiveDraft() else {
                log("[Editor] ERROR: No active draft to resume")
                loadingState = .failed(message: "No draft to resume")
                updateLoadingStateUI()
                return
            }
            activeDraftSlot = slot
            templateId = slot.sourceTemplateId
            draft = slot.draft
            log("[Editor] Resumed active draft: \(draft.id), template: \(templateId)")
        }

        currentTemplateId = templateId
        currentProjectDraft = draft
        currentProjectId = draft.id

        // Step 1: Load SceneLibrary
        do {
            let library = try await SceneLibrary.shared.load()
            sceneLibrarySnapshot = library
            log("[Release v1] SceneLibrary loaded: \(library.scenesById.count) scenes, fps=\(library.fps)")
        } catch {
            log("[Release v1] ERROR: Failed to load SceneLibrary: \(error)")
            loadingState = .failed(message: "Scene library load failed")
            updateLoadingStateUI()
            return
        }

        // Step 2: Get scene defaults from template catalog
        let catalogResult = await TemplateCatalog.shared.load()
        switch catalogResult {
        case .failure(let catalogError):
            // Catalog itself failed to load (IO/decode/manifest error)
            if draft.canonicalTimeline.sceneItems.isEmpty {
                log("[Release v1] ERROR: Catalog load failed and draft has no timeline: \(catalogError)")
                loadingState = .failed(message: "Catalog load failed")
                updateLoadingStateUI()
                return
            }
            log("[Release v1] WARN: Catalog load failed, using draft timeline: \(catalogError)")
            defaultSceneSequence = []

        case .success:
            do {
                defaultSceneSequence = try TemplateCatalog.shared.sceneTypeDefaults(
                    for: templateId, library: sceneLibrarySnapshot!
                )
                log("[Release v1] Template loaded: \(defaultSceneSequence.count) scenes")
            } catch {
                // Template not found in catalog (deleted/old templateId)
                if draft.canonicalTimeline.sceneItems.isEmpty {
                    log("[Release v1] ERROR: Template not in catalog and draft has no timeline: \(error)")
                    let message: String
                    if let catalogError = error as? TemplateCatalogError {
                        switch catalogError {
                        case .templateNotFound: message = "Template not found"
                        case .emptySceneList: message = "Template has no scenes"
                        case .sceneNotInLibrary: message = "Template is unavailable"
                        }
                    } else {
                        message = "Template not found"
                    }
                    loadingState = .failed(message: message)
                    updateLoadingStateUI()
                    return
                }
                log("[Release v1] WARN: Template '\(templateId)' not in catalog, using draft timeline")
                defaultSceneSequence = []
            }
        }

        let hydratedDraft = draft

        // Step 3: Determine first scene from draft or template defaults
        let firstSceneTypeId: String
        if let draftFirstSceneTypeId = hydratedDraft.canonicalTimeline.firstSceneTypeId {
            firstSceneTypeId = draftFirstSceneTypeId
            log("[Release v1] Using first scene from draft: \(firstSceneTypeId)")
        } else if let defaultFirstSceneTypeId = defaultSceneSequence.first?.sceneTypeId {
            firstSceneTypeId = defaultFirstSceneTypeId
            log("[Release v1] Using first scene from template defaults: \(firstSceneTypeId)")
        } else {
            log("[Release v1] ERROR: No scenes in draft or template defaults")
            loadingState = .failed(message: "Empty project")
            updateLoadingStateUI()
            return
        }

        // Load the first scene (this also configures the editor timeline)
        loadSceneTypeFromBundle(sceneTypeId: firstSceneTypeId)
    }

    // MARK: - PR2: Editor Layout Setup

    /// Sets up the editor layout container (PR-E: production editor only)
    private func setupEditorLayout() {
        // PR-E: Hide system navigation bar - we use EditorNavBar
        navigationController?.setNavigationBarHidden(true, animated: false)
        // Add editorLayoutContainer to view if not already added
        if editorLayoutContainer.superview == nil {
            editorLayoutContainer.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(editorLayoutContainer)
            NSLayoutConstraint.activate([
                editorLayoutContainer.topAnchor.constraint(equalTo: view.topAnchor),
                editorLayoutContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                editorLayoutContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                editorLayoutContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        // Embed metalView in editor layout
        editorLayoutContainer.embedMetalView(metalView)

        // PR-E: Embed overlayView for gesture handling in Scene Edit
        editorLayoutContainer.embedOverlayView(overlayView)

        // Phase 6: Embed ingest status overlay (above outline overlay, below menuStrip)
        editorLayoutContainer.embedStatusOverlayView(ingestStatusOverlayView)

        // PR-E: Add preparingOverlay for loading states
        preparingOverlay.translatesAutoresizingMaskIntoConstraints = false
        editorLayoutContainer.addSubview(preparingOverlay)
        NSLayoutConstraint.activate([
            preparingOverlay.topAnchor.constraint(equalTo: editorLayoutContainer.topAnchor),
            preparingOverlay.leadingAnchor.constraint(equalTo: editorLayoutContainer.leadingAnchor),
            preparingOverlay.trailingAnchor.constraint(equalTo: editorLayoutContainer.trailingAnchor),
            preparingOverlay.bottomAnchor.constraint(equalTo: editorLayoutContainer.bottomAnchor),
        ])

        // PR-E: Setup gesture recognizers on overlayView for Scene Edit interaction
        setupOverlayGestureRecognizers()

        // Wire callbacks
        wireEditorLayoutCallbacks()
    }

    /// Sets up gesture recognizers on overlayView for Scene Edit mode
    private func setupOverlayGestureRecognizers() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(overlayViewTapped(_:)))
        overlayView.addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))

        // PR-E: Assign delegate for gesture gating (sceneEdit + selectedBlock) and simultaneous pinch+rotate
        panGesture.delegate = self
        pinchGesture.delegate = self
        rotationGesture.delegate = self

        overlayView.addGestureRecognizer(panGesture)
        overlayView.addGestureRecognizer(pinchGesture)
        overlayView.addGestureRecognizer(rotationGesture)
    }

    /// Wires callbacks from EditorLayoutContainerView
    private func wireEditorLayoutCallbacks() {
        editorLayoutContainer.onClose = { [weak self] in
            self?.handleEditorClose()
        }

        editorLayoutContainer.onExport = { [weak self] in
            self?.exportTapped()
        }

        // PR-F: Undo/Redo
        editorLayoutContainer.onUndo = { [weak self] in
            self?.editorStore?.dispatch(.undo)
        }

        editorLayoutContainer.onRedo = { [weak self] in
            self?.editorStore?.dispatch(.redo)
        }

        editorLayoutContainer.onPlayPause = { [weak self] in
            self?.playPauseTapped()
        }

        editorLayoutContainer.onFullScreenPreview = { [weak self] in
            self?.handleFullScreenPreview()
        }

        // PR1: Unified timeline event handling
        editorLayoutContainer.onTimelineEvent = { [weak self] event in
            self?.handleTimelineEvent(event)
        }

        // PR9: Scene context actions
        editorLayoutContainer.onDuplicateScene = { [weak self] sceneId in
            self?.editorStore?.dispatch(.duplicateScene(sceneItemId: sceneId))
        }

        editorLayoutContainer.onDeleteScene = { [weak self] sceneId in
            // Cancel all in-flight ingests for the scene being deleted
            self?.mediaIngestCoordinator.cancelAll(for: sceneId)
            self?.editorStore?.dispatch(.deleteScene(sceneId: sceneId))
        }

        editorLayoutContainer.onAddScene = { [weak self] in
            self?.presentSceneCatalog()
        }

        // PR-D: Scene Edit Mode callbacks
        editorLayoutContainer.onEditScene = { [weak self] sceneId in
            self?.editorStore?.dispatch(.enterSceneEdit(sceneId: sceneId))
        }

        editorLayoutContainer.onDone = { [weak self] in
            self?.editorStore?.dispatch(.exitSceneEdit)
        }

        // PR-E: SceneEditBar callbacks
        editorLayoutContainer.onBackground = { [weak self] in
            self?.backgroundTapped()
        }

        editorLayoutContainer.onResetScene = { [weak self] in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId else { return }

            // PR-F: Show confirmation only if scene has state to reset
            let sceneState = self.editorStore?.state.draft.sceneInstanceStates[instanceId]
            guard sceneState != nil && sceneState != .empty else { return }

            let alert = UIAlertController(
                title: "Reset Scene",
                message: "This will reset all changes to this scene. This action can be undone.",
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                // Cancel all in-flight ingests for this scene before resetting
                self.mediaIngestCoordinator.cancelAll(for: instanceId)
                self.editorStore?.dispatch(.resetSceneState(sceneInstanceId: instanceId))
                self.reloadRuntimeState(for: instanceId)
                self.refreshSceneEditBars()
            })

            self.present(alert, animated: true)
        }

        // PR-E: MediaBlockActionBar callbacks
        editorLayoutContainer.onAddPhoto = { [weak self] blockId in
            self?.presentMediaPicker(for: blockId, kind: .photo)
        }

        editorLayoutContainer.onAddVideo = { [weak self] blockId in
            self?.presentMediaPicker(for: blockId, kind: .video)
        }

        editorLayoutContainer.onTrimVideo = { [weak self] blockId in
            self?.enterVideoTrim(for: blockId)
        }

        editorLayoutContainer.onTrimCancel = { [weak self] in
            self?.cancelVideoTrim()
        }

        editorLayoutContainer.onTrimDone = { [weak self] in
            self?.commitVideoTrim()
        }

        // VideoTrimBar handle/cursor callbacks
        editorLayoutContainer.videoTrimBar.onTrimStartChanged = { [weak self] fraction in
            self?.handleTrimStartDrag(fraction)
        }
        editorLayoutContainer.videoTrimBar.onTrimEndChanged = { [weak self] fraction in
            self?.handleTrimEndDrag(fraction)
        }
        editorLayoutContainer.videoTrimBar.onCursorChanged = { [weak self] fraction in
            self?.handleTrimCursorDrag(fraction)
        }
        editorLayoutContainer.videoTrimBar.onDragEnded = { [weak self] in
            self?.handleTrimDragEnded()
        }

        editorLayoutContainer.onAnimation = { [weak self] blockId in
            self?.presentVariantPicker(blockId: blockId)
        }

        editorLayoutContainer.onToggleEnabled = { [weak self] blockId in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId else { return }
            // Toggle current state
            let currentPresent = self.editorStore?.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.visibility ?? true
            self.editorStore?.dispatch(.setBlockMediaPresent(
                sceneInstanceId: instanceId,
                blockId: blockId,
                present: !currentPresent
            ))
            // Update runtime
            self.scenePlayer?.setUserMediaPresent(blockId: blockId, present: !currentPresent)
            self.metalView.setNeedsDisplay()
            // Refresh MediaBlockActionBar to update Disable/Enable button state
            self.updateMediaBlockActionBarForSelectedBlock()
        }

        editorLayoutContainer.onRemove = { [weak self] blockId in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId else { return }
            // Cancel any in-flight ingest for this slot
            self.mediaIngestCoordinator.cancelIngest(
                for: IngestSlotKey(sceneInstanceId: instanceId, blockId: blockId)
            )
            // Clear runtime
            self.userMediaService?.clear(blockId: blockId)
            // Dispatch to store (removes slot)
            self.editorStore?.dispatch(.setMediaSlot(
                sceneInstanceId: instanceId,
                blockId: blockId,
                slot: nil
            ))
            self.metalView.setNeedsDisplay()
            // Refresh MediaBlockActionBar
            self.updateMediaBlockActionBarForSelectedBlock()
        }

        editorLayoutContainer.onResetTransform = { [weak self] blockId in
            guard let self, let instanceId = self.sceneEditTargetInstanceId else { return }
            self.editorStore?.dispatch(.resetMediaPlacement(sceneInstanceId: instanceId, blockId: blockId))
            self.updateMediaBlockActionBarForSelectedBlock()
        }
    }

    // MARK: - PR1 + PR2: Unified Timeline Event Handling

    /// Routes timeline events from EditorLayoutContainerView.
    /// Scroll events are handled by the container (ruler sync).
    private func handleTimelineEvent(_ event: TimelineEvent) {
        switch event {
        case .scrub(let compressedFrame, let phase):
            handleTimelineScrub(compressedFrame: compressedFrame, phase: phase)

        case .selection(let selection):
            handleTimelineSelectionChanged(selection)

        case .scroll:
            // Handled by container (ruler sync), nothing to do here
            break

        case .trimScene(let sceneId, let newDurationUs, let edge, let phase):
            handleTrimScene(sceneId: sceneId, newDurationUs: newDurationUs, edge: edge, phase: phase)

        case .reorderScene(let sceneId, let toIndex, let phase):
            handleReorderScene(sceneId: sceneId, toIndex: toIndex, phase: phase)

        case .editBoundaryTransition(let fromId, let toId, let anchorRect):
            presentTransitionPicker(fromSceneId: fromId, toSceneId: toId, anchorRect: anchorRect)

        case .focusScene(let sceneId):
            editorStore?.dispatch(.focusScene(sceneId: sceneId))
        }
    }

    // MARK: - PR2: Trim Scene Handling

    /// Handles trim scene events from timeline.
    /// PR2: Dispatches to EditorStore instead of direct mutation.
    /// - Parameters:
    ///   - sceneId: ID of the scene being trimmed
    ///   - newDurationUs: New duration in microseconds
    ///   - edge: Which edge is being trimmed
    ///   - phase: Gesture phase
    private func handleTrimScene(sceneId: UUID, newDurationUs: TimeUs, edge: TrimEdge, phase: InteractionPhase) {
        guard let store = editorStore else {
            log("[PR2] handleTrimScene: editorStore is nil")
            return
        }

        // Stop playback on trim start to avoid coordinator/UI desync during preview
        if phase == .began && isPlaying {
            stopPlayback()
        }

        // PR2: Dispatch trim action to store
        // PR3.1: All UI updates happen via handleStoreStateChanged callback
        store.dispatch(.trimScene(sceneId: sceneId, phase: phase, newDurationUs: newDurationUs, edge: edge))
    }

    // MARK: - PR3: Reorder Scene Handling

    /// Handles reorder scene events from timeline.
    /// PR3: Dispatches to EditorStore on .ended phase only.
    /// PR3.2: Converts UI insertion index (0...count) to reducer destination index (0...count-1).
    /// - Parameters:
    ///   - sceneId: ID of the scene being moved
    ///   - toIndex: Insertion index from UI (0...count, where count means "insert at end")
    ///   - phase: Gesture phase
    private func handleReorderScene(sceneId: UUID, toIndex: Int, phase: InteractionPhase) {
        // Only commit reorder on .ended phase
        guard phase == .ended else { return }
        guard toIndex >= 0 else { return } // -1 means cancelled

        guard let store = editorStore else {
            log("[PR3] handleReorderScene: editorStore is nil")
            return
        }

        // PR3.2: Convert insertion index to destination index
        // UI emits insertion index (0...count), reducer expects destination index (0...count-1)
        let sceneItems = store.sceneItems
        guard let fromIndex = sceneItems.firstIndex(where: { $0.id == sceneId }) else {
            log("[PR3.2] handleReorderScene: scene not found")
            return
        }

        let count = sceneItems.count
        var destIndex = toIndex

        // If inserting after current position, adjust for removal
        if toIndex > fromIndex {
            destIndex -= 1
        }

        // Clamp to valid destination range
        destIndex = max(0, min(destIndex, count - 1))

        // Skip if no actual move
        guard destIndex != fromIndex else { return }

        // PR3: Dispatch reorder action to store
        // PR3.1: All UI updates happen via handleStoreStateChanged callback
        store.dispatch(.reorderScene(sceneId: sceneId, toIndex: destIndex))
    }

    // MARK: - PR-G: Transition Picker

    /// Presents transition picker for a scene boundary.
    /// - Parameters:
    ///   - fromSceneId: ID of the outgoing scene
    ///   - toSceneId: ID of the incoming scene
    ///   - anchorRect: Rect for popover anchor (in TimelineView coordinates)
    private func presentTransitionPicker(fromSceneId: UUID, toSceneId: UUID, anchorRect: CGRect) {
        let key = SceneBoundaryKey(fromSceneId, toSceneId)
        let current = editorStore?.state.canonicalTimeline.boundaryTransitions[key] ?? .none

        let handler = PlayerViewController.makeBoundaryTransitionDispatchHandler(
            fromSceneId: fromSceneId,
            toSceneId: toSceneId
        ) { [weak self] action in
            self?.editorStore?.dispatch(action)
        }

        let picker = PlayerViewController.makeTransitionPicker(
            currentType: current.type,
            onSelect: handler
        )

        // Wrap in navigation controller for title/cancel button
        let nav = UINavigationController(rootViewController: picker)

        // iPad: popover, iPhone: sheet
        if traitCollection.userInterfaceIdiom == .pad {
            nav.modalPresentationStyle = .popover
            if let popover = nav.popoverPresentationController {
                popover.sourceView = editorLayoutContainer.timelineView
                popover.sourceRect = anchorRect
            }
        } else {
            nav.modalPresentationStyle = .pageSheet
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.medium()]
                sheet.prefersGrabberVisible = true
            }
        }

        present(nav, animated: true)
    }

    /// Handles editor notices (e.g., transition reset alerts).
    private func handleEditorNotice(_ notice: EditorNotice) {
        switch notice {
        case .boundaryTransitionsReset:
            let alert = PlayerViewController.makeBoundaryTransitionsResetAlert()
            present(alert, animated: true)
        }
    }

    // MARK: - TT-08: Internal Test Seams

    /// Creates a configured transition picker.
    /// - Parameters:
    ///   - currentType: Current transition type for checkmark display.
    ///   - onSelect: Called with selected transition after dismiss.
    /// - Returns: Configured `TransitionPickerViewController`.
    static func makeTransitionPicker(
        currentType: TransitionType,
        onSelect: @escaping (SceneTransition) -> Void
    ) -> TransitionPickerViewController {
        let picker = TransitionPickerViewController(currentType: currentType)
        picker.onSelectTransition = onSelect
        return picker
    }

    /// Creates a dispatch handler that maps a selected transition to a `.setBoundaryTransition` action.
    /// - Parameters:
    ///   - fromSceneId: ID of the outgoing scene.
    ///   - toSceneId: ID of the incoming scene.
    ///   - dispatch: Action dispatch closure.
    /// - Returns: Closure suitable for `onSelectTransition`.
    static func makeBoundaryTransitionDispatchHandler(
        fromSceneId: UUID,
        toSceneId: UUID,
        dispatch: @escaping (EditorAction) -> Void
    ) -> (SceneTransition) -> Void {
        { transition in
            dispatch(.setBoundaryTransition(
                fromSceneId: fromSceneId,
                toSceneId: toSceneId,
                transition: transition
            ))
        }
    }

    /// Creates the alert shown when boundary transitions are auto-reset.
    /// - Returns: Configured `UIAlertController`.
    static func makeBoundaryTransitionsResetAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: "Transitions Removed",
            message: "Some transitions were removed because scene boundaries changed or adjacent scenes are too short.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }

    // MARK: - TT-10: Scene Edit Isolation

    /// Isolates timeline activity when entering scene edit mode.
    /// Contract: cancel pending timeline resolve first, then stop playback.
    /// Order matters — stale resolve must not complete after lifecycle stop.
    static func isolateTimelineActivityForSceneEdit(
        cancelPendingTimelineResolve: () -> Void,
        stopPlayback: () -> Void
    ) {
        cancelPendingTimelineResolve()
        stopPlayback()
    }

    // MARK: - PR2: Editor Callbacks

    private func handleEditorClose() {
        stopPlayback()

        let alert = UIAlertController(title: nil, message: "Save changes?", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            self?.saveAndClose()
        })
        alert.addAction(UIAlertAction(title: "Don't Save", style: .destructive) { [weak self] _ in
            self?.discardAndClose()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    private func saveAndClose() {
        guard var slot = activeDraftSlot,
              let draft = currentMergedDraft() else {
            navigationController?.popViewController(animated: true)
            return
        }
        slot.draft = draft
        slot.draft.updatedAt = Date()

        do {
            try ProjectStore.shared.materializeSavedProject(from: &slot)
            try ProjectStore.shared.deleteActiveDraft()
        } catch {
            log("[Close] Save failed: \(error)")
            presentSaveError(error)
            return
        }

        userMadeExplicitCloseChoice = true
        navigationController?.popViewController(animated: true)
    }

    private func discardAndClose() {
        do { try ProjectStore.shared.deleteActiveDraft() }
        catch { log("[Close] Discard error: \(error)") }
        userMadeExplicitCloseChoice = true
        navigationController?.popViewController(animated: true)
    }

    private func presentSaveError(_ error: Error) {
        let alert = UIAlertController(
            title: "Save Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Materializes saved project after successful export.
    private func handleExportSuccess() {
        guard var slot = activeDraftSlot,
              let draft = currentMergedDraft() else { return }
        slot.draft = draft
        slot.draft.updatedAt = Date()
        do {
            try ProjectStore.shared.materializeSavedProject(from: &slot)
            activeDraftSlot = slot
            try ProjectStore.shared.saveActiveDraft(slot)
        } catch {
            log("[Export] Save error: \(error.localizedDescription)")
        }
    }

    private func handleFullScreenPreview() {
        // PR-F: Fullscreen preview only allowed in timeline mode
        let uiMode = editorStore?.state.uiMode ?? .timeline
        guard case .timeline = uiMode else {
            assertionFailure("handleFullScreenPreview called outside timeline mode")
            return
        }

        let fullScreenVC = FullScreenPreviewViewController()
        fullScreenVC.modalPresentationStyle = .fullScreen
        fullScreenPreviewVC = fullScreenVC

        // Phase 2.1: Use compressed frame from store (not currentFrameIndex)
        let compressedFrame = editorStore?.playheadCompressedFrame ?? 0
        fullScreenVC.configure(compressedFrame: compressedFrame, isPlaying: isPlaying)

        // Move metalView to fullscreen VC
        metalView.removeFromSuperview()
        fullScreenVC.embedMetalView(metalView)

        // Wire callbacks
        fullScreenVC.onClose = { [weak self] returnedCompressedFrame in
            guard let self = self else { return }

            // Clear reference
            self.fullScreenPreviewVC = nil

            // Return metalView to editor layout before dismissing
            self.metalView.removeFromSuperview()
            self.editorLayoutContainer.embedMetalView(self.metalView)

            self.dismiss(animated: true) {
                // Phase 2.1: Dispatch compressed frame directly (no frameToUs conversion)
                self.editorStore?.dispatch(.setPlayhead(compressedFrame: returnedCompressedFrame))
                self.metalView.setNeedsDisplay()
            }
        }

        fullScreenVC.onPlayPause = { [weak self] in
            self?.playPauseTapped()
        }

        present(fullScreenVC, animated: true)
    }

    /// Handles timeline scrub events.
    /// Release v1: Routes through EditorStore for single source of truth.
    /// Phase 2.1: Uses compressed frame directly.
    /// - Parameters:
    ///   - compressedFrame: Compressed frame index (quantize applied at TimelineView)
    ///   - phase: Gesture phase for scrub drag state tracking
    private func handleTimelineScrub(compressedFrame: Int, phase: InteractionPhase) {
        // Track scrub drag state for render throttling (A/B testing)
        switch phase {
        case .began:
            isScrubDragging = true
        case .ended, .cancelled:
            isScrubDragging = false
            // Force final render if any was skipped due to throttle
            if pendingScrubRender {
                metalView.setNeedsDisplay()
                pendingScrubRender = false
            }
        case .changed:
            break
        }

        // Stop playback on scrub
        if isPlaying {
            stopPlayback()
        }

        // Dispatch to store - onPlayheadChanged callback handles coordinator + redraw + currentFrameIndex
        editorStore?.dispatch(.setPlayhead(compressedFrame: compressedFrame))
    }

    private func handleTimelineSelectionChanged(_ selection: TimelineSelection) {
        // In timeline mode, scene selection comes from playhead via focusScene.
        // Only allow .audio and .none through direct .select dispatch.
        if editorStore?.state.uiMode == .timeline, case .scene = selection {
            return
        }
        // PR3: Only dispatch to store. UI updates happen in handleStoreStateChanged.
        editorStore?.dispatch(.select(selection: selection))
    }

    /// Configures timeline after scene is loaded.
    /// Release v1: Uses EditorStore with split callbacks and defaultSceneSequence.
    /// No legacy migrations - schema mismatch creates new project.
    private func configureEditorTimeline() {
        let fps = sceneLibrarySnapshot?.fps ?? Int(sceneFPS)

        // Step 1: Ensure we have a draft
        guard let draft = currentProjectDraft else {
            log("[Release v1] configureEditorTimeline: no draft available")
            return
        }

        // Step 2: Create EditorStore and dispatch loadProject
        // Release v1: Reducer populates timeline from defaultSceneSequence if empty
        let store = EditorStore()
        store.dispatch(.loadProject(
            draft: draft,
            templateFPS: fps,
            defaultSceneSequence: defaultSceneSequence
        ))
        self.editorStore = store

        // Step 3: Wire split callbacks (Release v1)
        // onPlayheadChanged: lightweight, frequent updates (scrubbing, playback tick)
        store.onPlayheadChanged = { [weak self] compressedFrame in
            self?.handlePlayheadChanged(compressedFrame)
        }

        // onSelectionChanged: lightweight updates (highlight, handles)
        store.onSelectionChanged = { [weak self] selection in
            self?.handleSelectionChanged(selection)
        }

        // onTimelineChanged: heavier updates (scene add/remove/trim commit)
        store.onTimelineChanged = { [weak self] state in
            self?.handleTimelineChanged(state)
        }

        // onTimelinePreviewChanged: lightweight updates (trim preview only)
        store.onTimelinePreviewChanged = { [weak self] state in
            self?.handleTimelinePreviewChanged(state)
        }

        store.onUndoRedoChanged = { [weak self] canUndo, canRedo in
            self?.handleUndoRedoChanged(canUndo: canUndo, canRedo: canRedo)
        }

        // PR-D: Scene Edit Mode callbacks
        store.onUIModeChanged = { [weak self] mode in
            self?.handleUIModeChanged(mode)
        }

        store.onSelectedBlockChanged = { [weak self] blockId in
            self?.handleSelectedBlockChanged(blockId)
        }

        store.onStateRestoredFromUndoRedo = { [weak self] in
            self?.handleStateRestoredFromUndoRedo()
        }

        // PR-F: Scene state change callback for incremental engine sync
        store.onSceneStateChanged = { [weak self] instanceId, sceneState in
            self?.handleSceneStateChanged(instanceId: instanceId, sceneState: sceneState)
        }

        // Video selection committed callback
        store.onVideoSelectionChanged = { [weak self] instanceId, blockId, selection in
            self?.handleVideoSelectionChanged(instanceId: instanceId, blockId: blockId, selection: selection)
        }

        // PR2/PR4: Fast-path callbacks for media placement, visibility, and slot changes
        store.onMediaPlacementChanged = { [weak self] instanceId, blockId, placement in
            self?.handleMediaPlacementChanged(instanceId: instanceId, blockId: blockId, placement: placement)
        }
        store.onMediaVisibilityChanged = { [weak self] instanceId, blockId, visible in
            self?.handleMediaVisibilityChanged(instanceId: instanceId, blockId: blockId, visible: visible)
        }
        store.onMediaSlotChanged = { [weak self] instanceId, blockId, slot in
            self?.handleMediaSlotChanged(instanceId: instanceId, blockId: blockId, slot: slot)
        }

        // PR-G: Notice callback for user-facing feedback (e.g., transition reset alerts)
        store.onNotice = { [weak self] notice in
            self?.handleEditorNotice(notice)
        }

        // PR-D: Setup Scene Edit interaction controller
        let sceneEditCtrl = SceneEditInteractionController()
        sceneEditCtrl.overlayView = overlayView
        sceneEditCtrl.getScenePlayer = { [weak self] in self?.scenePlayer }
        sceneEditCtrl.getUIMode = { [weak self] in self?.editorStore?.state.uiMode ?? .timeline }
        sceneEditCtrl.getSelectedBlockId = { [weak self] in self?.editorStore?.state.selectedBlockId }

        sceneEditCtrl.onSelectBlock = { [weak self] blockId in
            self?.editorStore?.dispatch(.selectBlock(blockId: blockId))
        }

        sceneEditCtrl.getBaselinePlacement = { [weak self] blockId in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId,
                  let slot = self.editorStore?.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId] else {
                return .defaultCover
            }
            return slot.asset.placement
        }

        sceneEditCtrl.onPlacementChanged = { [weak self] blockId, placement, phase in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId,
                  let player = self.scenePlayer,
                  let ums = self.userMediaService else { return }

            let deps = SceneRuntimeStateApplier.Dependencies(
                scenePlayer: player,
                userMediaService: ums
            )

            // Live preview via resolver
            SceneRuntimeStateApplier.applyPlacementChange(
                blockId: blockId,
                placement: placement,
                deps: deps
            )
            self.metalView.setNeedsDisplay()

            // Persist to store
            self.editorStore?.dispatch(.setMediaPlacement(
                sceneInstanceId: instanceId,
                blockId: blockId,
                placement: placement,
                phase: phase
            ))

            // Cancel: restore baseline visually
            if phase == .cancelled {
                let restored = self.editorStore?.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.asset.placement ?? .defaultCover
                SceneRuntimeStateApplier.applyPlacementChange(
                    blockId: blockId,
                    placement: restored,
                    deps: deps
                )
                self.metalView.setNeedsDisplay()
            }
        }

        // Phase 6: Wire ingest status overlay
        sceneEditCtrl.ingestStatusOverlayView = ingestStatusOverlayView
        sceneEditCtrl.showsIngestStatusOverlay = showsMediaIngestStatusOverlay
        sceneEditCtrl.getIngestStatusesByBlockId = { [weak self] in
            self?.currentIngestStatusesByBlockId() ?? [:]
        }

        self.sceneEditController = sceneEditCtrl

        // Step 4: Sync local state from store
        currentProjectDraft = store.currentDraft
        log("[Release v1] Timeline configured: \(store.sceneItems.count) scenes, duration=\(store.projectDurationUs)us")

        // PR-E: Configure timeline UI with scenes from store (PR-G: includes boundaries)
        let scenes = store.sceneDrafts
        let boundaries = store.state.canonicalTimeline.toSceneBoundaryDrafts()
        editorLayoutContainer.configure(
            scenes: scenes,
            boundaries: boundaries,
            templateFPS: fps,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )

        // Step 7: Setup TimelinePlaybackCoordinator (Release v1)
        setupPlaybackCoordinator()

        // Step 7b: Setup TimelineCompositionEngine (PR-F: multi-scene with transitions)
        setupTimelineCompositionEngine()

        // Step 8: PR9.1 - Initial apply SceneState for first scene
        // Without this, activeSceneInstanceId stays nil until first scrub/play
        handlePlayheadChanged(store.playheadCompressedFrame)

        // PR10: Editor boot invariant - verify wiring is complete
        #if DEBUG
        let bootUIMode = store.state.uiMode
        if activeSceneInstanceId == nil {
            assertionFailure("[PR10] configureEditorTimeline: activeSceneInstanceId is nil after initial apply")
        }
        if scenePlayer == nil {
            assertionFailure("[PR10] configureEditorTimeline: scenePlayer is nil after initial apply")
        }
        // PR-F: In timeline mode, engine is source of truth; in scene edit mode, coordinator is.
        switch bootUIMode {
        case .timeline:
            if timelineCompositionEngine?.transitionMath == nil {
                assertionFailure("[PR10] configureEditorTimeline: engine.transitionMath is nil in timeline mode")
            }
        case .sceneEdit:
            if playbackCoordinator?.currentSceneInstanceId == nil {
                assertionFailure("[PR10] configureEditorTimeline: playbackCoordinator.currentSceneInstanceId is nil in scene edit mode")
            }
        }
        #endif
    }

    /// Sets up the TimelinePlaybackCoordinator for multi-scene playback.
    private func setupPlaybackCoordinator() {
        guard let library = sceneLibrarySnapshot,
              let store = editorStore else { return }

        let coordinator = TimelinePlaybackCoordinator()
        coordinator.configure(
            sceneLibrary: library,
            fps: library.fps,
            loadSceneType: { [weak self] sceneTypeId in
                guard let self = self else {
                    throw NSError(domain: "PlayerViewController", code: -1)
                }
                return try await self.loadSceneTypeAsync(sceneTypeId: sceneTypeId)
            }
        )

        // Initialize timeline from store
        coordinator.updateSceneTimeline(from: store.state)

        // P1 fix: Bootstrap with already-loaded first scene (prevents double load)
        // P0-2 fix: Use store.state to get the actual first scene (matches what was loaded)
        if let player = scenePlayer,
           let compiled = compiledScene,
           let provider = textureProvider as? ScenePackageTextureProvider,
           let resolver = currentResolver,
           let firstSceneTypeId = store.state.canonicalTimeline.firstSceneTypeId {
            coordinator.bootstrap(
                sceneTypeId: firstSceneTypeId,
                player: player,
                compiled: compiled,
                provider: provider,
                resolver: resolver
            )
        }

        // Wire coordinator callbacks
        coordinator.onSceneLoaded = { [weak self] loadedScene in
            self?.handleCoordinatorSceneLoaded(loadedScene)
        }

        // PR9: Wire active scene change callback for per-instance state
        coordinator.onActiveSceneChanged = { [weak self] sceneInfo in
            self?.handleActiveSceneChanged(sceneInfo)
        }

        self.playbackCoordinator = coordinator
    }

    /// Sets up the TimelineCompositionEngine for multi-scene rendering with transitions.
    /// Call this after setupPlaybackCoordinator and when timeline changes.
    private func setupTimelineCompositionEngine() {
        guard let device = metalView.device,
              let queue = commandQueue,
              let store = editorStore,
              let library = sceneLibrarySnapshot else {
            return
        }

        // Create or reuse engine
        let engine: TimelineCompositionEngine
        if let existing = timelineCompositionEngine {
            engine = existing
        } else {
            engine = TimelineCompositionEngine(
                device: device,
                commandQueue: queue,
                fps: library.fps
            )

            // Configure scene URL provider (captures library by value - it's a struct)
            engine.resourcesCache.sceneURLProvider = { sceneTypeId in
                library.scene(byId: sceneTypeId)?.folderURL
            }

            // PR-F: Set template canvas from library
            engine.setTemplateCanvas(library.canvas)

            // PR4: Wire engine redraw callback for async media readiness
            engine.onNeedsRedraw = { [weak self] in
                self?.refreshCurrentTimelineFrame()
            }

            timelineCompositionEngine = engine
        }

        // Update timeline from store
        let timeline = store.state.canonicalTimeline
        let sceneStates = store.state.draft.sceneInstanceStates
        engine.setTimeline(timeline, sceneStates: sceneStates)

        // PR-G: Create transition compositor unconditionally
        // Compositor doesn't depend on timeline contents, only on device/pixelFormat
        // Creating lazily based on boundaryTransitions caused bugs when first transition was added later
        if transitionCompositor == nil {
            do {
                transitionCompositor = try TransitionCompositor(
                    device: device,
                    colorPixelFormat: metalView.colorPixelFormat
                )
            } catch {
                log("[TimelineComposition] Failed to create TransitionCompositor: \(error)")
            }
        }

        // Phase 2.1: Wire mapper to timeline UI after engine setup
        let mapper = store.state.makePlayheadMapper()
        editorLayoutContainer.setMapper(mapper)
    }


    /// Loads a scene type asynchronously for the coordinator.
    /// Heavy IO (file loading, decoding) runs on background thread to avoid main thread freezes.
    private func loadSceneTypeAsync(sceneTypeId: String) async throws -> TimelinePlaybackCoordinator.LoadedScene {
        guard let sceneDescriptor = sceneLibrarySnapshot?.scene(byId: sceneTypeId),
              let sceneURL = sceneDescriptor.folderURL else {
            throw NSError(domain: "PlayerViewController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Scene not found: \(sceneTypeId)"])
        }

        // Heavy IO on background thread via shared pipeline
        let loaded = try await SceneTypeLoadPipeline.load(
            sceneTypeId: sceneTypeId,
            from: sceneURL
        )

        // Metal resources on main thread
        let player = await MainActor.run { ScenePlayer() }
        let compiled = await MainActor.run { player.loadCompiledScene(loaded.compiled) }
        let resolver = loaded.resolver

        guard let device = await MainActor.run(body: { metalView.device }) else {
            throw NSError(domain: "PlayerViewController", code: -2, userInfo: [NSLocalizedDescriptionKey: "No Metal device"])
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

        // P1-1 fix: Preload textures on background thread (Sendable-safe)
        let queue = await MainActor.run(body: { commandQueue })
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

    /// Called when coordinator loads a new scene.
    private func handleCoordinatorSceneLoaded(_ loadedScene: TimelinePlaybackCoordinator.LoadedScene) {
        // PR-E: Update current scene player for rendering
        scenePlayer = loadedScene.player
        compiledScene = loadedScene.compiled
        textureProvider = loadedScene.provider
        currentResolver = loadedScene.resolver

        // Reset video update gate on scene change (prevents skipped updates when localFrame matches)
        lastStillSyncFrame = -1

        // P0 fix: Recreate UserMediaService for new scene
        // Old service holds stale scenePlayer/textureProvider references
        if let device = metalView.device, let queue = commandQueue {
            userMediaService = UserMediaService(
                device: device,
                commandQueue: queue,
                scenePlayer: loadedScene.player,
                textureProvider: loadedScene.provider
            )
            userMediaService?.setSceneFPS(Double(loadedScene.compiled.runtime.fps))
            userMediaService?.onNeedsDisplay = { [weak self] in
                self?.metalView.setNeedsDisplay()
                // PR-F: Sync video frame when provider becomes ready after undo/redo
                self?.syncPausedVideoStill(force: true)
            }
            // PR2: Render-only callback for async still frame delivery (no re-sync)
            userMediaService?.onStillFrameDelivered = { [weak self] in
                self?.metalView.setNeedsDisplay()
            }
            // PR4: Re-resolve placement after async media load (correct media dimensions)
            userMediaService?.onMediaReady = { [weak self] blockId in
                self?.handleMediaReadyForPlacement(blockId: blockId)
            }
            // Video selection persistence is now handled by MediaIngestCoordinator
            // (slot includes videoWindow). No runtime → persistence callback needed.
        }

        // PR-E: Update canvas size if different
        let newCanvasSize = loadedScene.compiled.runtime.canvasSize
        if canvasSize != newCanvasSize {
            canvasSize = newCanvasSize
        }

        log("[Release v1] Coordinator loaded scene: \(loadedScene.sceneTypeId)")

        // PR9: Apply per-instance state after scene load
        // Skip during scene-edit activation — activation method is the single owner
        if sceneEditReadyInstanceId != nil, let instanceId = activeSceneInstanceId {
            resetRuntimeForSceneInstanceChange()
            applySceneInstanceState(instanceId: instanceId)
        }

        metalView.setNeedsDisplay()
    }

    // MARK: - PR9: Active Scene Instance Handling

    /// Called when active scene instance changes.
    /// Fires on every instance change, even if sceneTypeId is the same.
    private func handleActiveSceneChanged(_ sceneInfo: TimelinePlaybackCoordinator.SceneTimeInfo) {
        // PR-G: In timeline mode, engine is source of truth - ignore coordinator callback
        let uiMode = editorStore?.state.uiMode ?? .timeline
        guard case .sceneEdit = uiMode else { return }

        let previousInstanceId = activeSceneInstanceId
        activeSceneInstanceId = sceneInfo.sceneInstanceId

        // During scene-edit activation, the activation method handles state apply
        guard sceneEditReadyInstanceId != nil else { return }

        // If scene is already loaded (same sceneTypeId), apply state immediately
        // Otherwise, state will be applied in handleCoordinatorSceneLoaded after load
        if let coordinator = playbackCoordinator,
           coordinator.currentSceneTypeId == sceneInfo.sceneTypeId,
           scenePlayer != nil {
            // Only reset/apply if instance actually changed
            if previousInstanceId != sceneInfo.sceneInstanceId {
                resetRuntimeForSceneInstanceChange()
                applySceneInstanceState(instanceId: sceneInfo.sceneInstanceId)
                metalView.setNeedsDisplay()
            }
        }
    }

    /// Resets runtime state for a scene instance change.
    /// Clears all overrides before applying new instance state.
    private func resetRuntimeForSceneInstanceChange() {
        // 1. Reset ScenePlayer state
        scenePlayer?.resetForNewInstance()

        // 2. Clear UserMediaService
        userMediaService?.clearAll()

        // 3. Reset video update gate
        lastStillSyncFrame = -1
    }

    /// Applies persisted SceneState to runtime for a scene instance.
    private func applySceneInstanceState(instanceId: UUID) {
        guard let state = editorStore?.state.draft.sceneInstanceStates[instanceId],
              let player = scenePlayer,
              let service = userMediaService else {
            return
        }

        let deps = SceneRuntimeStateApplier.Dependencies(scenePlayer: player, userMediaService: service)
        let restoredCount = SceneRuntimeStateApplier.apply(state, deps: deps)

        #if DEBUG
        logger.debug("[PlayerVC] Applied state for instance \(instanceId): slots=\(state.mediaSlotsByBlockId?.count ?? 0), variants=\(state.variantOverrides.count), restored=\(restoredCount), toggles=\(state.layerToggles.count)")
        #endif
    }

    // MARK: - Release v1: Store Callbacks (Split for Performance)

    /// Called when playhead position changes (lightweight, frequent).
    /// Used for scrubbing and playback tick updates.
    /// PR-F: Routes to engine path for timeline mode, coordinator path for sceneEdit mode.
    /// Phase 2.1: Takes compressed frame directly from store.
    private func handlePlayheadChanged(_ compressedFrame: Int) {
        let uiMode = editorStore?.state.uiMode ?? .timeline

        #if DEBUG
        let signpostId = ScrubSignpost.beginHandlePlayheadChanged()
        ScrubCallCounter.shared.recordHandlePlayheadChanged()
        #endif

        switch uiMode {
        case .timeline:
            // PR-F: Use TimelineCompositionEngine for timeline mode
            handleTimelineModePlayheadChanged(compressedFrame)

        case .sceneEdit:
            // Scene Edit mode: use old coordinator path (single-scene)
            handleSceneEditModePlayheadChanged(compressedFrame)
        }

        #if DEBUG
        ScrubSignpost.endHandlePlayheadChanged(signpostId, syncPath: uiMode != .timeline)
        #endif
    }

    /// PR-F: Handles playhead changes in timeline mode via TimelineCompositionEngine.
    /// Phase 2.1: Takes compressed frame directly (no conversion needed).
    private func handleTimelineModePlayheadChanged(_ compressedFrame: Int) {
        // PR-G: Timeline mode is engine-only, no fallback to coordinator path
        guard let engine = timelineCompositionEngine else {
            assertionFailure("handleTimelineModePlayheadChanged requires timelineCompositionEngine")
            return
        }

        // Phase 2.1: Compressed frame is now source of truth
        currentCompressedFrame = compressedFrame

        // PR-F: Set activeSceneInstanceId SYNCHRONOUSLY for boot invariant.
        activeSceneInstanceId = engine.sceneInstanceId(at: compressedFrame)

        // Sync timeline scroll to follow playhead
        if let mapper = editorStore?.state.makePlayheadMapper() {
            editorLayoutContainer.setCurrentCompressedFrame(compressedFrame, mapper: mapper)
        }

        // PR-G: Use shared helper with scrub invalidation
        // Phase 2.1: Pass compressed frame directly (no round-trip conversion)
        resolveAndPresentTimelineFrame(compressedFrame: compressedFrame, invalidateScrub: true)
    }

    /// PR-G: Refreshes current timeline frame after edits (variant/media/toggle/transform/transition).
    /// Unlike scrub, this doesn't invalidate generation - just re-resolves current position.
    private func refreshCurrentTimelineFrame() {
        let uiMode = editorStore?.state.uiMode ?? .timeline
        guard uiMode == .timeline else { return }
        guard timelineCompositionEngine != nil else { return }

        // Phase 2.1: Use compressed frame directly from store
        let compressedFrame = editorStore?.playheadCompressedFrame ?? 0
        resolveAndPresentTimelineFrame(compressedFrame: compressedFrame, invalidateScrub: false)
    }

    /// PR-G: Shared helper for timeline frame resolution.
    /// Used by both scrub (handleTimelineModePlayheadChanged) and edit refresh (refreshCurrentTimelineFrame).
    /// - Parameters:
    ///   - compressedFrame: Playhead position in compressed frames (Phase 2.1)
    ///   - invalidateScrub: If true, invalidates scrub generation for stale detection (used during scrub)
    private func resolveAndPresentTimelineFrame(compressedFrame: Int, invalidateScrub: Bool) {
        guard let engine = timelineCompositionEngine else { return }

        // Capture generation for stale detection (only if invalidating)
        var generation: UInt64?
        if invalidateScrub {
            engine.invalidateScrub()
            generation = engine.currentScrubGeneration
        }

        // Cancel previous playhead task
        playheadAsyncTask?.cancel()

        playheadAsyncTask = Task { @MainActor in
            // TT-02: Resolve frame via engine with explicit resolution result
            let resolution = await engine.resolveFrame(compressedFrame, generation: generation, policy: .presentation)

            // Check if this task was cancelled
            guard !Task.isCancelled else { return }

            switch resolution {
            case .resolved(let resolved):
                // Cache resolved frame for draw()
                self.cachedTimelineFrame = resolved
                self.cachedTimelineCompressedFrame = compressedFrame

                // PR-F: Set activeSceneInstanceId from engine (required for controller invariants)
                // For single: use context's sceneInstanceId
                // For transition: use primary scene from frameMapping
                switch resolved {
                case .single(let ctx):
                    self.activeSceneInstanceId = ctx.sceneInstanceId
                case .transition:
                    // Use primary scene (frameMapping gives the "current" scene during transition)
                    self.activeSceneInstanceId = engine.sceneInstanceId(at: compressedFrame)
                }

                // Update video frames for scrub based on resolved context
                if !self.isPlaying {
                    switch resolved {
                    case .single(let ctx):
                        if let runtime = engine.runtime(for: ctx.sceneInstanceId) {
                            runtime.syncVideoFrame(ctx.localFrame)
                        }
                    case .transition(let ctx):
                        // Sync both scenes in transition
                        if let runtimeA = engine.runtime(for: ctx.sceneA.sceneInstanceId) {
                            runtimeA.syncVideoFrame(ctx.sceneA.localFrame)
                        }
                        if let runtimeB = engine.runtime(for: ctx.sceneB.sceneInstanceId) {
                            runtimeB.syncVideoFrame(ctx.sceneB.localFrame)
                        }
                    }
                }

                // Trigger redraw
                self.requestMetalRender()

            case .hold:
                // TT-02: Keep cachedTimelineFrame unchanged, keep activeSceneInstanceId
                // Do NOT fabricate fallback frame, do NOT force redraw
                #if DEBUG
                logger.debug("[PlayerVC] Hold: keeping last frame")
                #endif

            case .staleGeneration:
                // TT-02: Nothing changes
                #if DEBUG
                logger.debug("[PlayerVC] Stale generation: ignoring")
                #endif

            case .failed(let failure):
                // TT-02: Nothing changes, only debug log
                #if DEBUG
                logger.debug("[PlayerVC] Resolution failed: \(String(describing: failure))")
                #endif
            }
        }
    }

    /// Handles playhead changes in Scene Edit mode via TimelinePlaybackCoordinator.
    /// Phase 2.1: Takes compressed frame and converts to nominal timeUs for coordinator.
    private func handleSceneEditModePlayheadChanged(_ compressedFrame: Int) {
        // Don't process playhead changes until scene-edit activation completes
        guard sceneEditReadyInstanceId != nil else { return }
        guard let coordinator = playbackCoordinator else { return }

        // Phase 2.1: Convert compressed frame to nominal timeUs for coordinator
        let mapper = editorStore?.state.makePlayheadMapper() ?? TimelinePlayheadMapper.empty
        let timeUs = mapper.nominalTimeUs(forCompressedFrame: compressedFrame)

        // Try sync path first (same scene, no load needed)
        if let localFrame = coordinator.syncSetGlobalTimeUs(timeUs) {
            // P1 fix: Cancel pending async task since we're back in loaded scene
            playheadAsyncTask?.cancel()
            playheadAsyncTask = nil

            // Same scene - update frame and redraw
            currentFrameIndex = localFrame
            requestMetalRender()

            // P1: Update video frames during timeline scrub (when not playing)
            // DEBUG: DebugSkipStillVideoUpdates toggle for A/B testing H1
            if !isPlaying, localFrame != lastStillSyncFrame {
                #if DEBUG
                if !ScrubDebugToggles.skipStillVideoUpdates {
                    userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
                }
                #else
                userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
                #endif
                lastStillSyncFrame = localFrame
            }
        } else {
            // Scene switch needed - use async path
            // Cancel previous playhead task to avoid stale frame application
            playheadAsyncTask?.cancel()
            let requestedTimeUs = timeUs
            playheadAsyncTask = Task { @MainActor in
                let localFrame = await coordinator.setGlobalTimeUs(requestedTimeUs)

                // Check if this task was cancelled (superseded by newer request)
                guard !Task.isCancelled else { return }

                self.currentFrameIndex = localFrame
                self.requestMetalRender()

                // P1: Update video frames after scene switch (when not playing)
                // DEBUG: DebugSkipStillVideoUpdates toggle for A/B testing H1
                if !self.isPlaying, localFrame != self.lastStillSyncFrame {
                    #if DEBUG
                    if !ScrubDebugToggles.skipStillVideoUpdates {
                        self.userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
                    }
                    #else
                    self.userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
                    #endif
                    self.lastStillSyncFrame = localFrame
                }
            }
        }
    }

    /// Called when selection changes (lightweight, frequent).
    /// Used for tap/drag selection updates.
    private func handleSelectionChanged(_ selection: TimelineSelection?) {
        let sel = selection ?? .none
        let sceneCount = editorStore?.sceneItems.count ?? 1
        editorLayoutContainer.setTimelineSelection(sel, sceneCount: sceneCount)
    }

    /// Called when timeline structure changes (heavier, less frequent).
    /// Used for scene add/remove/trim commits.
    private func handleTimelineChanged(_ state: EditorState) {
        // Update scene clips UI (PR-G: includes boundaries)
        let scenes = state.canonicalTimeline.toSceneDrafts()
        let boundaries = state.canonicalTimeline.toSceneBoundaryDrafts()
        editorLayoutContainer.updateScenes(scenes, boundaries: boundaries)

        // Update coordinator timeline (legacy path for Scene Edit)
        playbackCoordinator?.updateSceneTimeline(from: state)

        // PR-F: Update TimelineCompositionEngine for timeline preview path
        timelineCompositionEngine?.setTimeline(
            state.canonicalTimeline,
            sceneStates: state.draft.sceneInstanceStates
        )

        // Phase 2.1: Update mapper in timeline UI after timeline changes
        let mapper = state.makePlayheadMapper()
        editorLayoutContainer.setMapper(mapper)

        // Mark draft as dirty for persistence
        currentProjectDraft = state.draft
        draftIsDirty = true

        // PR-F: Refresh bottom bars if in Scene Edit mode
        refreshSceneEditBars()

        // PR-G: Refresh current frame to reflect timeline changes
        refreshCurrentTimelineFrame()
    }

    /// PR-F: Called when scene state changes (but not timeline structure).
    /// Routes to engine for incremental sync instead of full setTimeline().
    private func handleSceneStateChanged(instanceId: UUID, sceneState: SceneState) {
        // Update engine via incremental path, then refresh current frame
        Task { @MainActor in
            await timelineCompositionEngine?.updateSceneState(sceneState, for: instanceId)

            // PR-G: Refresh current frame AFTER engine state is updated
            self.refreshCurrentTimelineFrame()
        }

        // PR-G: Sync local draft cache to maintain consistency
        currentProjectDraft = editorStore?.currentDraft

        // Mark draft as dirty for persistence
        draftIsDirty = true

        #if DEBUG
        logger.debug("[PR-F] Scene state changed: instanceId=\(instanceId)")
        #endif
    }

    // MARK: - PR4: Fast-Path Handlers

    /// Fast-path: placement committed — apply to active scene without full reload.
    private func handleMediaPlacementChanged(instanceId: UUID, blockId: String, placement: MediaPlacementState) {
        // Scene-edit path: apply directly to local player
        if let player = scenePlayer, let service = userMediaService,
           activeSceneInstanceId == instanceId || sceneEditTargetInstanceId == instanceId {
            let deps = SceneRuntimeStateApplier.Dependencies(scenePlayer: player, userMediaService: service)
            SceneRuntimeStateApplier.applyPlacementChange(blockId: blockId, placement: placement, deps: deps)
            metalView.setNeedsDisplay()
        }

        // Timeline path: engine fast-path (no full reload)
        timelineCompositionEngine?.applyPlacementChange(blockId: blockId, placement: placement, for: instanceId)
        refreshCurrentTimelineFrame()

        currentProjectDraft = editorStore?.currentDraft
        draftIsDirty = true
    }

    /// Fast-path: visibility toggled — apply to active scene without full reload.
    private func handleMediaVisibilityChanged(instanceId: UUID, blockId: String, visible: Bool) {
        // Scene-edit path: apply directly to local player
        if let player = scenePlayer,
           activeSceneInstanceId == instanceId || sceneEditTargetInstanceId == instanceId {
            SceneRuntimeStateApplier.applyVisibilityChange(blockId: blockId, visible: visible, player: player)
            metalView.setNeedsDisplay()
        }

        // Timeline path: engine fast-path (no full reload)
        timelineCompositionEngine?.applyVisibilityChange(blockId: blockId, visible: visible, for: instanceId)
        refreshCurrentTimelineFrame()

        currentProjectDraft = editorStore?.currentDraft
        draftIsDirty = true
        refreshSceneEditBars()
    }

    /// Fast-path: slot changed (insert/replace/remove) — apply to active scene.
    /// Slot changes use full engine update (media needs restore).
    private func handleMediaSlotChanged(instanceId: UUID, blockId: String, slot: SceneMediaSlot?) {
        let isActiveScene = activeSceneInstanceId == instanceId || sceneEditTargetInstanceId == instanceId

        // Scene-edit path: apply directly (only for active scene)
        if isActiveScene, let player = scenePlayer, let service = userMediaService {
            let deps = SceneRuntimeStateApplier.Dependencies(scenePlayer: player, userMediaService: service)
            SceneRuntimeStateApplier.applySlotChange(blockId: blockId, slot: slot, deps: deps)
            metalView.setNeedsDisplay()
        }

        // Timeline path: full state update for any scene
        if let sceneState = editorStore?.state.draft.sceneInstanceStates[instanceId] {
            Task { @MainActor in
                await timelineCompositionEngine?.updateSceneState(sceneState, for: instanceId)
                self.refreshCurrentTimelineFrame()
            }
        }

        currentProjectDraft = editorStore?.currentDraft
        draftIsDirty = true
        refreshSceneEditBars()
    }

    /// PR4: Re-resolve placement after media finishes async loading.
    /// Called by UserMediaService.onMediaReady — now we have actual media dimensions.
    private func handleMediaReadyForPlacement(blockId: String) {
        guard let player = scenePlayer, let service = userMediaService else { return }

        // Find active instance and its placement
        let instanceId = sceneEditTargetInstanceId ?? activeSceneInstanceId
        guard let instanceId,
              let slot = editorStore?.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId] else { return }
        let placement = slot.asset.placement

        // Re-resolve with actual media size now available
        let deps = SceneRuntimeStateApplier.Dependencies(scenePlayer: player, userMediaService: service)
        SceneRuntimeStateApplier.applyPlacementChange(blockId: blockId, placement: placement, deps: deps)
        metalView.setNeedsDisplay()
    }

    /// Called during live-trim preview (lightweight, frequent).
    /// Only updates UI, skips playback coordinator and persistence.
    /// Phase 2.1: Must update mapper for live trim scrub to work correctly.
    private func handleTimelinePreviewChanged(_ state: EditorState) {
        // Update scene clips UI only (PR-G: includes boundaries)
        let scenes = state.canonicalTimeline.toSceneDrafts()
        let boundaries = state.canonicalTimeline.toSceneBoundaryDrafts()
        editorLayoutContainer.updateScenes(scenes, boundaries: boundaries)

        // Phase 2.1: Update mapper in timeline UI for live trim preview
        // This is required for scrub/layout to use correct mapping during trim drag
        let mapper = state.makePlayheadMapper()
        editorLayoutContainer.setMapper(mapper)

        // NOTE: Intentionally NOT updating:
        // - playbackCoordinator (expensive O(n) rebuild)
        // - currentProjectDraft / draftIsDirty (persistence only on commit)
    }

    /// Called when undo/redo availability changes.
    /// PR-F: Updates navbar button enabled states.
    private func handleUndoRedoChanged(canUndo: Bool, canRedo: Bool) {
        editorLayoutContainer.navBar.setUndoEnabled(canUndo)
        editorLayoutContainer.navBar.setRedoEnabled(canRedo)

        #if DEBUG
        log("[PR-F] Undo/Redo changed: canUndo=\(canUndo), canRedo=\(canRedo)")
        #endif
    }

    // MARK: - PR-D: Scene Edit Mode Handlers

    /// Handles UI mode changes (timeline ↔ sceneEdit).
    /// PR-D: Wires store.onUIModeChanged to layout and interaction controller.
    private func handleUIModeChanged(_ mode: EditorUIMode) {
        switch mode {
        case .timeline:
            // Exit Scene Edit: restore timeline UI
            sceneEditActivationTask?.cancel()
            sceneEditActivationTask = nil
            sceneEditReadyInstanceId = nil
            editorLayoutContainer.setSceneEditMode(false, animated: true)
            editorLayoutContainer.navBar.setMode(.timeline)
            sceneEditController?.updateOverlay()

        case .sceneEdit(let sceneId):
            // TT-10: Isolate timeline activity unconditionally on scene edit entry.
            // Cancel pending timeline resolve before stopping playback lifecycle,
            // so stale async resolve cannot complete after scene edit is active.
            PlayerViewController.isolateTimelineActivityForSceneEdit(
                cancelPendingTimelineResolve: { [weak self] in
                    self?.playheadAsyncTask?.cancel()
                    self?.playheadAsyncTask = nil
                },
                stopPlayback: { [weak self] in
                    self?.stopPlayback()
                }
            )
            editorLayoutContainer.setSceneEditMode(true, animated: true)
            editorLayoutContainer.navBar.setMode(.sceneEdit)
            sceneEditController?.updateOverlay()

            // PR-F: Configure bottom bars state
            refreshSceneEditBars()

            // Activate target scene by instance ID (async, render-gated)
            activateSceneEditTarget(instanceId: sceneId)

            #if DEBUG
            log("[PR-D] Entered Scene Edit for scene: \(sceneId)")
            #endif
        }
    }

    /// Handles selected block changes in Scene Edit mode.
    /// PR-D: Updates bottom bar and overlay when block selection changes.
    /// PR-F: Uses refreshSceneEditBars() for consistent bar updates.
    private func handleSelectedBlockChanged(_ blockId: String?) {
        editorLayoutContainer.updateSceneEditBottomBar(selectedBlockId: blockId)
        sceneEditController?.updateOverlay()

        // PR-F: Refresh bottom bars state
        refreshSceneEditBars()

        #if DEBUG
        log("[PR-D] Selected block changed: \(blockId ?? "nil")")
        #endif
    }

    /// Updates MediaBlockActionBar configuration for currently selected block (PR-E).
    private func updateMediaBlockActionBarForSelectedBlock() {
        guard let blockId = editorStore?.state.selectedBlockId,
              let player = scenePlayer,
              let instanceId = sceneEditTargetInstanceId else { return }

        // Get block capabilities from ScenePlayer
        let allowedMedia = player.allowedMedia(blockId: blockId)
        let variants = player.availableVariants(blockId: blockId)
        let hasVariants = variants.count > 1

        // Check if block has media assigned (unified slots)
        let sceneState = editorStore?.state.draft.sceneInstanceStates[instanceId]
        let slot = sceneState?.mediaSlotsByBlockId?[blockId]
        var hasMedia = slot != nil

        // Check if block is enabled (slot visibility)
        let isEnabled = slot?.visibility ?? true

        // Determine media kind and trim capability
        var mediaKind = slot?.mediaRef.mediaKind
        var canTrimVideo = userMediaService?.videoTrimContext(blockId: blockId) != nil

        // Phase 6: Restore-failed blocks treated as empty in scene-edit UI
        if userMediaService?.didBlockFailRestore(blockId: blockId) == true {
            hasMedia = false
            mediaKind = nil
            canTrimVideo = false
        }

        // Phase 6: Get ingest status for this block
        let ingestKey = IngestSlotKey(sceneInstanceId: instanceId, blockId: blockId)
        let ingestStatus = mediaIngestCoordinator.status(for: ingestKey)

        // Check if placement is at default (for reset button visibility)
        let isPlacementDefault = slot?.asset.placement.isNearDefault ?? true

        editorLayoutContainer.configureMediaBlockActionBar(
            blockId: blockId,
            allowedMedia: allowedMedia,
            hasVariants: hasVariants,
            hasMedia: hasMedia,
            isEnabled: isEnabled,
            mediaKind: mediaKind,
            canTrimVideo: canTrimVideo,
            ingestStatus: ingestStatus,
            showsIngestStatus: showsMediaIngestStatusInActionBar,
            isPlacementDefault: isPlacementDefault
        )
    }

    /// Refreshes SceneEditBar and MediaBlockActionBar states.
    /// PR-F: Called after state changes to keep bottom bars in sync.
    private func refreshSceneEditBars() {
        guard let instanceId = sceneEditTargetInstanceId else { return }

        // 1. Update SceneEditBar reset button state
        let sceneState = editorStore?.state.draft.sceneInstanceStates[instanceId]
        let canReset = sceneState != nil && sceneState != .empty
        editorLayoutContainer.configureSceneEditBar(canReset: canReset)

        // 2. Update MediaBlockActionBar if block is selected
        if editorStore?.state.selectedBlockId != nil {
            updateMediaBlockActionBarForSelectedBlock()
        }
    }

    // MARK: - Phase 6: Ingest Status

    /// Returns current ingest statuses keyed by blockId for the active scene-edit scene.
    private func currentIngestStatusesByBlockId() -> [String: IngestSlotStatus] {
        guard let instanceId = sceneEditTargetInstanceId else { return [:] }
        var result: [String: IngestSlotStatus] = [:]
        for (key, status) in mediaIngestCoordinator.slotStatus
            where key.sceneInstanceId == instanceId {
            result[key.blockId] = status
        }
        return result
    }

    /// Handles ingest status changes: updates overlay, action bar, and shows failure alerts.
    private func handleIngestStatusChanged(key: IngestSlotKey, status: IngestSlotStatus) {
        // Only update UI if this status change is for the active scene-edit scene
        guard key.sceneInstanceId == sceneEditTargetInstanceId else { return }

        // Update ingest status overlay
        sceneEditController?.updateOverlay()

        // Update action bar if this block is selected
        if editorStore?.state.selectedBlockId == key.blockId {
            updateMediaBlockActionBarForSelectedBlock()
        }

        // Alert dedupe
        switch status {
        case .processing, .idle:
            ingestFailureAlertedKeys.remove(key)

        case .failed(let reason):
            guard !ingestFailureAlertedKeys.contains(key) else { return }
            ingestFailureAlertedKeys.insert(key)
            let alert = UIAlertController(
                title: "Media Import Failed",
                message: reason,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)

        case .ready:
            break // Transient, no action
        }
    }

    // MARK: - Inline Video Trim (PR 3+4)

    /// Enters inline video trim mode for the given block.
    private func enterVideoTrim(for blockId: String) {
        guard let instanceId = sceneEditTargetInstanceId,
              let ums = userMediaService,
              let context = ums.videoTrimContext(blockId: blockId) else { return }

        // Verify slot is actually video
        guard let slot = editorStore?.state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId],
              slot.mediaRef.mediaKind == .video else { return }

        // Stop playback if playing
        if isPlaying {
            stopPlayback()
        }

        // Compute current video time at paused playhead
        let localFrame = playbackCoordinator?.currentLocalFrame ?? currentFrameIndex
        let currentVideoTime = ums.currentVideoTime(blockId: blockId, sceneFrameIndex: localFrame)

        // Create trim session (opens at current playhead if inside clip, else trimStart)
        let session = VideoTrimSession(
            instanceId: instanceId,
            blockId: blockId,
            actualDuration: context.actualDuration,
            selection: context.currentSelection,
            currentVideoTime: currentVideoTime
        )
        videoTrimSession = session

        // Switch layout to trim mode
        editorLayoutContainer.setVideoTrimMode(true)

        // Configure trim bar positions
        editorLayoutContainer.videoTrimBar.setPositions(
            start: session.trimStartFraction,
            end: session.trimEndFraction,
            cursor: session.cursorFraction
        )

        // Generate filmstrip thumbnails
        let thumbnailProvider = VideoTrimThumbnailProvider(
            url: context.videoURL,
            duration: context.actualDuration
        )
        self.trimThumbnailProvider = thumbnailProvider

        let barWidth = editorLayoutContainer.videoTrimBar.bounds.width
        let thumbHeight = VideoTrimBarView.filmstripHeight
        let thumbWidth = thumbHeight * 16.0 / 9.0 // Approximate 16:9 aspect
        let count = max(1, Int(ceil(barWidth / thumbWidth)))

        thumbnailProvider.generateThumbnails(
            count: count,
            size: CGSize(width: thumbWidth, height: thumbHeight)
        ) { [weak self] results in
            self?.editorLayoutContainer.videoTrimBar.setThumbnails(results.map(\.image))
        }

        // Preview initial frame at trimStart
        ums.previewExactVideoTrimFrame(
            blockId: blockId,
            draftSelection: session.draftSelection,
            previewTime: session.currentPreviewTime
        )
    }

    /// Handles left handle drag during trim.
    private func handleTrimStartDrag(_ fraction: Double) {
        guard var session = videoTrimSession else { return }
        let newTrimStart = fraction * session.actualDuration
        session.draftSelection.trimStart = newTrimStart
        session.currentPreviewTime = newTrimStart
        videoTrimSession = session

        // Interactive preview during drag (tolerant, coalescing)
        userMediaService?.updateInteractiveTrimPreview(
            blockId: session.blockId,
            draftSelection: session.draftSelection,
            previewTime: newTrimStart
        )
    }

    /// Handles right handle drag during trim.
    private func handleTrimEndDrag(_ fraction: Double) {
        guard var session = videoTrimSession else { return }
        let newTrimEnd = fraction * session.actualDuration
        session.draftSelection.trimEnd = newTrimEnd
        session.currentPreviewTime = newTrimEnd
        videoTrimSession = session

        // Interactive preview during drag (tolerant, coalescing)
        userMediaService?.updateInteractiveTrimPreview(
            blockId: session.blockId,
            draftSelection: session.draftSelection,
            previewTime: newTrimEnd
        )
    }

    /// Handles cursor drag during trim (scrub within trim range).
    private func handleTrimCursorDrag(_ fraction: Double) {
        guard var session = videoTrimSession else { return }
        let previewTime = fraction * session.actualDuration
        session.currentPreviewTime = previewTime
        videoTrimSession = session

        // Interactive preview during drag (tolerant, coalescing)
        userMediaService?.updateInteractiveTrimPreview(
            blockId: session.blockId,
            draftSelection: session.draftSelection,
            previewTime: previewTime
        )
    }

    /// Handles end of any trim drag gesture: switch from interactive to exact.
    private func handleTrimDragEnded() {
        guard let session = videoTrimSession else { return }
        userMediaService?.endInteractiveTrimPreview(blockId: session.blockId)
        userMediaService?.previewExactVideoTrimFrame(
            blockId: session.blockId,
            draftSelection: session.draftSelection,
            previewTime: session.currentPreviewTime
        )
    }

    /// Commits the trim session: validates, applies, dispatches, exits.
    private func commitVideoTrim() {
        guard let session = videoTrimSession else { return }

        // End interactive preview before commit
        userMediaService?.endInteractiveTrimPreview(blockId: session.blockId)

        if session.hasChanges {
            guard let ums = userMediaService else {
                exitVideoTrim()
                return
            }

            // 1. Validate + apply to runtime
            do {
                try ums.applyPersistedVideoSelection(blockId: session.blockId, session.draftSelection)
            } catch {
                let alert = UIAlertController(
                    title: "Invalid Selection",
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
                return
            }

            // 2. Render exact still at new trimStart for poster/cover
            ums.previewExactVideoTrimFrame(
                blockId: session.blockId,
                draftSelection: session.draftSelection,
                previewTime: session.draftSelection.trimStart
            )

            // 3. Dispatch to store
            editorStore?.dispatch(.setVideoSelection(
                sceneInstanceId: session.instanceId,
                blockId: session.blockId,
                selection: session.draftSelection
            ))
        }

        exitVideoTrim()
    }

    /// Cancels the trim session: reverts runtime preview, exits.
    private func cancelVideoTrim() {
        guard let session = videoTrimSession else { return }

        // End interactive preview
        userMediaService?.endInteractiveTrimPreview(blockId: session.blockId)

        // Revert draft selection if handles were moved
        if session.hasChanges, let ums = userMediaService {
            try? ums.applyPersistedVideoSelection(blockId: session.blockId, session.originalSelection)
        }

        // Always restore the committed scene-frame still.
        // Even cursor-only scrubs change the displayed texture without touching draftSelection,
        // so we must re-sync to the paused playhead regardless of hasChanges.
        videoTrimSession = nil  // clear before sync so the trim guard in syncPausedVideoStill does not block
        syncPausedVideoStill(force: true)

        exitVideoTrim()
    }

    /// Exits trim mode and cleans up session state.
    private func exitVideoTrim() {
        // Safety-net: ensure interactive preview is cleaned up
        if let session = videoTrimSession {
            userMediaService?.endInteractiveTrimPreview(blockId: session.blockId)
        }
        trimThumbnailProvider?.cancel()
        trimThumbnailProvider = nil
        videoTrimSession = nil

        editorLayoutContainer.setVideoTrimMode(false)

        // Restore scene edit bottom bar state
        let selectedBlockId = editorStore?.state.selectedBlockId
        editorLayoutContainer.updateSceneEditBottomBar(selectedBlockId: selectedBlockId)
        if selectedBlockId != nil {
            updateMediaBlockActionBarForSelectedBlock()
        }
    }

    /// Handles committed video selection change from store callback.
    private func handleVideoSelectionChanged(instanceId: UUID, blockId: String, selection: PersistedVideoSelection) {
        // Fast-path engine update (non-throwing, best-effort)
        timelineCompositionEngine?.applyPersistedVideoSelection(selection, blockId: blockId, for: instanceId)

        // Sync local draft cache
        currentProjectDraft = editorStore?.currentDraft
        draftIsDirty = true

        // Refresh bars (edit button state may have changed)
        refreshSceneEditBars()
    }

    /// Reloads runtime state for a given scene instance.
    /// PR-F: Single sync-point for runtime reload after undo/redo or Reset Scene.
    /// Order: resetForNewInstance -> clearAll -> applySceneInstanceState -> overlay/redraw -> video sync
    private func reloadRuntimeState(for instanceId: UUID) {
        // 1. Reset ScenePlayer mutable state (transforms, variants, toggles, media presence)
        scenePlayer?.resetForNewInstance()

        // 2. Clear UserMediaService to remove stale textures
        userMediaService?.clearAll()

        // 3. Reset video update gate (PR-F: match canonical path)
        lastStillSyncFrame = -1

        // 4. Re-apply persisted state from store
        applySceneInstanceState(instanceId: instanceId)

        // 5. Refresh overlay and redraw
        sceneEditController?.updateOverlay()
        metalView.setNeedsDisplay()

        // 6. Force video frame sync for already-ready providers (PR-F)
        syncPausedVideoStill(force: true)

        #if DEBUG
        log("[PR-F] Runtime state reloaded for instance: \(instanceId)")
        #endif
    }

    /// Syncs video frames to current playhead when paused.
    /// PR-F: Used after runtime reload and when video providers become ready.
    /// Suppressed during active trim session to prevent onNeedsDisplay events from
    /// overwriting the trim preview with scene-frame stills.
    /// - Parameter force: If true, bypasses lastStillSyncFrame gate
    private func syncPausedVideoStill(force: Bool) {
        guard !isPlaying else { return }
        // During active trim, preview is driven by previewExactVideoTrimFrame — don't stomp it
        guard videoTrimSession == nil else { return }

        let localFrame = playbackCoordinator?.currentLocalFrame ?? currentFrameIndex

        if force {
            userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
        } else {
            // Respect lastStillSyncFrame gate
            guard localFrame != lastStillSyncFrame else { return }
            lastStillSyncFrame = localFrame
            userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame)
        }
    }

    /// Handles state restoration after undo/redo.
    /// PR-D: Re-applies runtime state for active scene instance to sync with restored snapshot.
    /// PR-F: Also refreshes bottom bars and syncs TimelineCompositionEngine.
    private func handleStateRestoredFromUndoRedo() {
        // Conservatively cancel all in-flight ingests before reloading restored state.
        // Undo/redo may have reverted the scene structure, making ongoing ingests stale.
        mediaIngestCoordinator.cancelAll()

        if let targetId = sceneEditTargetInstanceId {
            reloadRuntimeState(for: targetId)
        } else if let runtimeId = activeSceneInstanceId {
            reloadRuntimeState(for: runtimeId)
        }
        refreshSceneEditBars()

        // PR-F: Sync TimelineCompositionEngine with restored state
        if let store = editorStore, let engine = timelineCompositionEngine {
            engine.setTimeline(
                store.state.canonicalTimeline,
                sceneStates: store.state.draft.sceneInstanceStates
            )

            // Re-apply state to loaded runtimes
            Task { @MainActor in
                for (instanceId, state) in store.state.draft.sceneInstanceStates {
                    await engine.updateSceneState(state, for: instanceId)
                }
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // PR-E: Hide system navigation bar (we use EditorNavBar)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        perfLogger.start()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Cancel all in-flight ingests on permanent leave
        if isMovingFromParent || isBeingDismissed {
            mediaIngestCoordinator.cancelAll()
        }

        // Safety net: save to active slot when leaving editor without explicit choice
        if (isMovingFromParent || isBeingDismissed) && !userMadeExplicitCloseChoice {
            saveDraftToActiveSlot()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if DEBUG
        perfLogger.stop()
        #endif

        // PR4: Cleanup background textures when VC disappears
        backgroundTextureService?.clearAllTrackedTextures()
    }

    // MARK: - Draft Persistence

    /// Assembles the full current draft including background from authoritative source.
    private func currentMergedDraft() -> ProjectDraft? {
        guard var draft = editorStore?.currentDraft
                ?? activeDraftSlot?.draft else { return nil }
        if let bg = projectBackgroundOverride {
            draft.background = bg
        }
        return draft
    }

    /// Saves current draft to the active draft slot (not to SavedProject).
    /// Called on background, autosave timer, and viewWillDisappear safety net.
    private func saveDraftToActiveSlot() {
        guard draftIsDirty, var slot = activeDraftSlot,
              let draft = currentMergedDraft() else { return }
        slot.draft = draft
        slot.draft.updatedAt = Date()
        do {
            try ProjectStore.shared.saveActiveDraft(slot)
            activeDraftSlot = slot
            draftIsDirty = false
            log("[Autosave] Draft saved to active slot")
        } catch {
            log("[Autosave] Error: \(error.localizedDescription)")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // PR-E: Update Scene Edit mapper with current canvas/view sizes
        sceneEditController?.mapper.canvasSize = canvasSize
        sceneEditController?.mapper.viewSize = metalView.bounds.size

        // P1-2: Refresh Scene Edit overlay after layout change
        if case .sceneEdit = editorStore?.state.uiMode {
            sceneEditController?.updateOverlay()
        }
    }

    private func setupRenderer() {
        guard let device = metalView.device else { log("ERROR: No Metal device"); return }
        do {
            let clearCol = ClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
            renderer = try MetalRenderer(
                device: device,
                colorPixelFormat: metalView.colorPixelFormat,
                options: MetalRendererOptions(
                    clearColor: clearCol,
                    enableDiagnostics: true,
                    maxFramesInFlight: Self.maxFramesInFlight  // Must match inFlightSemaphore
                )
            )
            log("MetalRenderer initialized (maxFramesInFlight=\(Self.maxFramesInFlight))")
        } catch { log("ERROR: MetalRenderer failed: \(error)") }
    }

    // MARK: - Export

    @objc private func exportTapped() {
        guard !isExporting else {
            log("[Export] Export already in progress")
            return
        }
        guard loadingState == .ready else {
            log("[Export] ERROR: Template not ready")
            return
        }
        startExport()
    }

    // MARK: - Background Editor (PR3)

    @objc private func backgroundTapped() {
        guard loadingState == .ready else {
            log("[Background] Template not ready")
            return
        }

        let templateBackground = compiledScene?.runtime.scene.background
        let editor = BackgroundEditorViewController(
            presetLibrary: BackgroundPresetLibrary.shared,
            templateBackground: templateBackground,
            currentOverride: projectBackgroundOverride ?? .empty
        )
        editor.delegate = self

        let nav = UINavigationController(rootViewController: editor)
        // Prevent interactive dismiss — override commit must go through Done button
        // (backgroundEditorWillDismiss) to guarantee consistent state.
        nav.isModalInPresentation = true
        present(nav, animated: true)
    }

    /// Handles background image selection from PHPicker.
    private func handleBackgroundImagePicked(result: PHPickerResult, regionId: String) {
        pendingBackgroundEditor?.isImportInFlight = true
        Task { @MainActor in
            defer { pendingBackgroundEditor?.isImportInFlight = false }
            do {
                let picked = try await PickerAssetAdapter.extractPhoto(from: result)
                guard case .photo(let tempURL) = picked else { return }
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await saveAndSetBackgroundImage(from: tempURL, for: regionId)
            } catch {
                log("[Background] Failed to handle picked image: \(error.localizedDescription)")
            }
        }
    }

    /// Persists background image, loads texture, and updates editor.
    ///
    /// Session-safe: captures import generation + preset ID at call time and verifies both
    /// after each async boundary. If a newer import was requested, the editor closed, or
    /// the preset changed mid-flight, the persisted file is cleaned up as orphan.
    private func saveAndSetBackgroundImage(from sourceFileURL: URL, for regionId: String) async throws {
        guard let service = backgroundTextureService,
              let state = effectiveBackgroundState else {
            log("[Background] Service or state not available")
            return
        }

        // Capture session identity at call time
        let capturedGeneration = backgroundImportGeneration
        let sessionPresetId = state.preset.presetId

        // 1. Persist image (off-main-actor work)
        let (mediaRef, _) = try await service.persistImage(from: sourceFileURL)
        log("[Background] Persisted image: \(mediaRef.id)")

        // 2. Generation + preset guard after persist
        guard backgroundImportGeneration == capturedGeneration,
              effectiveBackgroundState?.preset.presetId == sessionPresetId else {
            log("[Background] Import generation stale after persist — cleaning up orphan")
            try? service.deleteMediaFile(mediaRef)
            return
        }

        // 3. Load texture
        let slotKey = EffectiveBackgroundBuilder.makeSlotKey(
            presetId: sessionPresetId,
            regionId: regionId
        )

        do {
            try await service.loadTexture(slotKey: slotKey, mediaRef: mediaRef)
        } catch {
            try? service.deleteMediaFile(mediaRef)
            throw error
        }

        // 4. Generation + preset guard after texture load
        guard backgroundImportGeneration == capturedGeneration,
              effectiveBackgroundState?.preset.presetId == sessionPresetId else {
            log("[Background] Import generation stale after texture load — clearing stale texture")
            service.clearTexture(slotKey: slotKey)
            try? service.deleteMediaFile(mediaRef)
            return
        }

        // 5. Commit to editor or directly to persisted override
        if let editor = pendingBackgroundEditor {
            editor.setImage(for: regionId, mediaRef: mediaRef)
        } else {
            let imageOverride = ImageOverride(mediaRef: mediaRef, transform: .identity)
            projectBackgroundOverride?.regions[regionId] = RegionOverride(
                source: .image(imageOverride)
            )
            let templateBackground = compiledScene?.runtime.scene.background
            effectiveBackgroundState = EffectiveBackgroundBuilder.build(
                templateBackground: templateBackground,
                projectOverride: projectBackgroundOverride ?? .empty,
                presetLibrary: BackgroundPresetLibrary.shared
            )
            draftIsDirty = true
        }
        pendingBackgroundEditor = nil

        // 6. Refresh display
        metalView.setNeedsDisplay()
    }

    // MARK: - Export Mode

    /// Tears down preview resources before export to free GPU memory.
    ///
    /// 1. Stops playback and cancels pending playback start
    /// 2. Clears preview background textures
    /// 3. Pauses Metal rendering
    private func enterExportMode() {
        stopPlayback()
        playbackStartTask?.cancel()
        playbackStartTask = nil
        backgroundTextureService?.clearAllTrackedTextures()
        userMediaService?.releasePreviewResources()
        timelineCompositionEngine?.releaseForExport()
        metalView.isPaused = true
    }

    /// Decision from the preflight memory warning alert.
    private enum ExportPreflightDecision {
        case cancel
        case continueOriginal
        case useRecommended(suggestedPreset: VideoQualityPreset, suggestedSizePx: (width: Int, height: Int))
    }

    /// Shows alert recommending lower quality when memory is constrained.
    private func showLowerPresetAlert(
        suggestedPreset: VideoQualityPreset,
        suggestedSizePx: (width: Int, height: Int)
    ) async -> ExportPreflightDecision {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Memory Warning",
                message: "This project may be too large to export at the current quality. We recommend reducing the quality to \(suggestedSizePx.width)x\(suggestedSizePx.height) for a stable export.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Reduce Quality", style: .default) { _ in
                continuation.resume(returning: .useRecommended(
                    suggestedPreset: suggestedPreset,
                    suggestedSizePx: suggestedSizePx
                ))
            })
            alert.addAction(UIAlertAction(title: "Continue as-is", style: .default) { _ in
                continuation.resume(returning: .continueOriginal)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: .cancel)
            })
            self.present(alert, animated: true)
        }
    }

    /// Builds single-scene export settings with the given size and preset.
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

    /// Builds timeline export settings with the given size and preset.
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

    /// Restores editor to idle state after export completes.
    ///
    /// Does NOT auto-restore playback — editor stays idle.
    /// Preview textures reload on next user interaction.
    private func exitExportModeToIdle() {
        metalView.isPaused = false
        metalView.setNeedsDisplay()
    }

    // MARK: - Export Implementation

    private func startExport() {
        // PR-G: Multi-scene timeline uses timeline export (regardless of transitions)
        // VideoExporter.exportTimeline handles both .single and .transition frames
        if let store = editorStore, store.state.sceneItems.count > 1 {
            guard let engine = timelineCompositionEngine else {
                assertionFailure("Multi-scene timeline requires timelineCompositionEngine")
                log("[Export] ERROR: Multi-scene timeline but engine is nil")
                return
            }
            startTimelineExport(engine: engine)
            return
        }

        // Single-scene export (only for single-scene projects)
        // 1. Guard dependencies
        guard let device = metalView.device,
              let compiled = compiledScene,
              let player = scenePlayer,
              let resolver = currentResolver else {
            log("[Export] ERROR: Missing dependencies")
            return
        }

        // Tear down preview resources to free GPU memory
        enterExportMode()

        // 2. Create ExportTextureProvider (user photos loaded via DownsampledImageLoader on export queue)
        let exportTP = ExportTextureProvider(
            device: device,
            assetIndex: compiled.mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: compiled.bindingAssetIds
        )

        // 3. Prepare output URL and audio config (settings built after preflight decision)
        let runtime = compiled.runtime
        let canvasSize = runtime.canvasSize

        // Unique filename format: export_<sceneId>_<timestamp>_<uuid>.mp4
        let sceneId = runtime.scene.sceneId ?? "scene"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let uuid8 = UUID().uuidString.prefix(8)
        let filename = "export_\(sceneId)_\(timestamp)_\(uuid8).mp4"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        // Release audio config: only original audio from video slots
        let audioConfig = AudioExportConfig(
            music: nil,
            voiceover: nil,
            includeOriginalFromVideoSlots: true,
            originalDefaultVolume: 1.0
        )

        // 4. Present progress modal
        let progressVC = ExportProgressViewController()
        progressVC.modalPresentationStyle = .overFullScreen
        progressVC.modalTransitionStyle = .crossDissolve

        let exporter = VideoExporter()
        let request = ActiveExportRequest(id: UUID(), exporter: exporter)
        activeExportRequest = request
        let requestId = request.id

        progressVC.onCancel = { [weak self, weak exporter] in
            exporter?.cancel()
            guard let self else { return }
            self.clearExportRequestIfCurrent(requestId)
            self.dismiss(animated: true)
        }

        present(progressVC, animated: true) { [weak self] in
            guard let self = self else { return }

            self.log("[Export] Starting export...")
            self.log("[Export] Output: \(outputURL.lastPathComponent)")
            self.log("[Export] Size: \(Int(canvasSize.width))x\(Int(canvasSize.height)) @ \(runtime.fps)fps")
            self.log("[Export] Duration: \(runtime.durationFrames) frames")

            progressVC.updateState(.preparing)

            Task { @MainActor in
                // Run preflight to get budget (persisted-only: read from draft slots)
                let instanceId = self.activeSceneInstanceId
                let mediaSlots: [String: SceneMediaSlot] = instanceId.flatMap {
                    self.editorStore?.state.draft.sceneInstanceStates[$0]?.mediaSlotsByBlockId
                } ?? [:]
                let videoSlotCount = mediaSlots.values.filter { $0.mediaRef.mediaKind == .video }.count
                let backgroundRegionCount = self.projectBackgroundOverride?.regions.count ?? 0
                let preflightResult = ExportPreflightPlanner.plan(
                    sceneCount: 1,
                    canvasSize: (width: Int(canvasSize.width), height: Int(canvasSize.height)),
                    videoSlotCount: videoSlotCount,
                    backgroundRegionCount: backgroundRegionCount,
                    currentPreset: .high,
                    fps: runtime.fps
                )

                // Handle preflight recommendation — build settings after decision
                let originalSizePx = (width: Int(canvasSize.width), height: Int(canvasSize.height))
                let exportSizePx: (width: Int, height: Int)
                let exportPreset: VideoQualityPreset

                switch preflightResult {
                case .recommendLowerPreset(_, let suggestedPreset, let suggestedSizePx):
                    let decision = await self.showLowerPresetAlert(
                        suggestedPreset: suggestedPreset,
                        suggestedSizePx: suggestedSizePx
                    )
                    guard self.isActiveExportRequest(requestId) else {
                        self.exitExportModeToIdle()
                        return
                    }
                    switch decision {
                    case .cancel:
                        self.exitExportModeToIdle()
                        self.clearExportRequestIfCurrent(requestId)
                        self.dismiss(animated: true)
                        return
                    case .continueOriginal:
                        exportSizePx = originalSizePx
                        exportPreset = .high
                    case .useRecommended(let preset, let sizePx):
                        exportSizePx = sizePx
                        exportPreset = preset
                        self.log("[Export] User chose reduced quality: \(sizePx.width)x\(sizePx.height) preset=\(preset)")
                    }
                case .safe:
                    exportSizePx = originalSizePx
                    exportPreset = .high
                }

                // Recompute budget with final export parameters (cheap, stateless)
                let budget = ExportPreflightPlanner.plan(
                    sceneCount: 1,
                    canvasSize: exportSizePx,
                    videoSlotCount: videoSlotCount,
                    backgroundRegionCount: backgroundRegionCount,
                    currentPreset: exportPreset,
                    fps: runtime.fps
                ).budget
                let settings = self.makeSingleSceneExportSettings(
                    outputURL: outputURL,
                    sizePx: exportSizePx,
                    preset: exportPreset,
                    fps: runtime.fps,
                    audio: audioConfig
                )

                // Build lightweight media snapshot from persisted slots (no runtime reads)
                let mediaSnapshot: ExportMediaSnapshot
                do {
                    mediaSnapshot = try await ExportMediaSnapshot.build(
                        compiledScene: compiled,
                        mediaSlots: mediaSlots,
                        projectStore: ProjectStore.shared,
                        runtime: runtime
                    )
                } catch {
                    self.log("[Export] Media snapshot error: \(error.localizedDescription)")
                    self.exitExportModeToIdle()
                    self.clearExportRequestIfCurrent(requestId)
                    self.dismiss(animated: true) { self.presentExportError(error) }
                    return
                }

                // Build background snapshot (lightweight — no texture loading)
                let bgSnapshot = ExportBackgroundSnapshot.build(
                    from: self.projectBackgroundOverride,
                    effectiveState: self.effectiveBackgroundState
                )

                // P1: Cancel may have arrived during preflight — bail out
                guard self.isActiveExportRequest(requestId) else {
                    self.log("[Export] Cancelled during preflight (stale request)")
                    self.exitExportModeToIdle()
                    return
                }

                exporter.exportVideo(
                    compiledScene: compiled,
                    scenePlayer: player,
                    device: device,
                    textureProvider: exportTP,
                    pathRegistry: compiled.pathRegistry,
                    assetSizes: compiled.mergedAssetIndex.sizeById,
                    settings: settings,
                    backgroundState: self.effectiveBackgroundState,
                    budget: budget,
                    mediaSnapshot: mediaSnapshot,
                    backgroundSnapshot: bgSnapshot,
                    onFinishing: { [weak self, weak progressVC] in
                        guard let self, self.isActiveExportRequest(requestId) else { return }
                        progressVC?.updateState(.finishing)
                    },
                    progress: { [weak self, weak progressVC] progress in
                        guard let self, self.isActiveExportRequest(requestId) else { return }
                        progressVC?.updateState(.rendering(progress: progress))
                    },
                    completion: { [weak self] result in
                        guard let self else { return }
                        self.exitExportModeToIdle()
                        guard self.isActiveExportRequest(requestId) else {
                            self.log("[Export] Ignoring stale completion")
                            return
                        }

                        switch result {
                        case .success(let url):
                            self.log("[Export] SUCCESS: \(url.lastPathComponent)")
                            self.handleExportSuccess()
                            progressVC.updateState(.savingToPhotos)
                            self.saveExportedVideoToPhotos(url, requestId: requestId, progressVC: progressVC)

                        case .failure(let error as VideoExportError) where error.isCancelled:
                            self.log("[Export] Cancelled")
                            self.clearExportRequestIfCurrent(requestId)

                        case .failure(let error):
                            self.log("[Export] ERROR: \(error.localizedDescription)")
                            self.clearExportRequestIfCurrent(requestId)
                            self.dismiss(animated: true) {
                                self.presentExportError(error)
                            }
                        }
                    }
                )
            }
        }
    }

    /// Exports multi-scene timeline with transitions.
    /// Uses TimelineCompositionEngine and TransitionCompositor.
    private func startTimelineExport(engine: TimelineCompositionEngine) {
        guard let transitionMath = engine.transitionMath else {
            log("[Export] ERROR: No timeline configured")
            return
        }

        // Get canvas size from first scene
        let canvasSize = engine.canvasSize
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            log("[Export] ERROR: Invalid canvas size")
            return
        }

        // Tear down preview resources to free GPU memory
        enterExportMode()

        // Configure output URL and audio config (settings built after preflight decision)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let uuid8 = UUID().uuidString.prefix(8)
        let filename = "export_timeline_\(timestamp)_\(uuid8).mp4"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        // Audio config: include original audio from video slots, no music/voiceover
        let audioConfig = AudioExportConfig(
            music: nil,
            voiceover: nil,
            includeOriginalFromVideoSlots: true,
            originalDefaultVolume: 1.0
        )

        // Present progress modal
        let progressVC = ExportProgressViewController()
        progressVC.modalPresentationStyle = .overFullScreen
        progressVC.modalTransitionStyle = .crossDissolve

        let exporter = VideoExporter()
        let request = ActiveExportRequest(id: UUID(), exporter: exporter)
        activeExportRequest = request
        let requestId = request.id

        progressVC.onCancel = { [weak self, weak exporter] in
            exporter?.cancel()
            guard let self else { return }
            self.clearExportRequestIfCurrent(requestId)
            self.dismiss(animated: true)
        }

        present(progressVC, animated: true) { [weak self] in
            guard let self = self else { return }

            self.log("[Export] Starting timeline export...")
            self.log("[Export] Output: \(outputURL.lastPathComponent)")
            self.log("[Export] Size: \(Int(canvasSize.width))x\(Int(canvasSize.height)) @ \(engine.fps)fps")
            self.log("[Export] Duration: \(transitionMath.compressedDurationFrames) frames")

            progressVC.updateState(.preparing)

            Task { @MainActor in
                // Run preflight to get budget
                let sceneCount = self.editorStore?.state.sceneItems.count ?? 1
                let allStates = self.editorStore?.state.draft.sceneInstanceStates ?? [:]
                let totalVideoSlots = allStates.values.reduce(0) { count, state in
                    count + (state.mediaSlotsByBlockId ?? [:]).values.filter { $0.mediaRef.mediaKind == .video }.count
                }
                let backgroundRegionCount = self.projectBackgroundOverride?.regions.count ?? 0
                let preflightResult = ExportPreflightPlanner.plan(
                    sceneCount: sceneCount,
                    canvasSize: (width: Int(canvasSize.width), height: Int(canvasSize.height)),
                    videoSlotCount: totalVideoSlots,
                    backgroundRegionCount: backgroundRegionCount,
                    currentPreset: .high,
                    fps: engine.fps
                )

                // Handle preflight recommendation — build settings after decision
                let originalSizePx = (width: Int(canvasSize.width), height: Int(canvasSize.height))
                let exportSizePx: (width: Int, height: Int)
                let exportPreset: VideoQualityPreset

                switch preflightResult {
                case .recommendLowerPreset(_, let suggestedPreset, let suggestedSizePx):
                    let decision = await self.showLowerPresetAlert(
                        suggestedPreset: suggestedPreset,
                        suggestedSizePx: suggestedSizePx
                    )
                    guard self.isActiveExportRequest(requestId) else {
                        self.exitExportModeToIdle()
                        return
                    }
                    switch decision {
                    case .cancel:
                        self.exitExportModeToIdle()
                        self.clearExportRequestIfCurrent(requestId)
                        self.dismiss(animated: true)
                        return
                    case .continueOriginal:
                        exportSizePx = originalSizePx
                        exportPreset = .high
                    case .useRecommended(let preset, let sizePx):
                        exportSizePx = sizePx
                        exportPreset = preset
                        self.log("[Export] User chose reduced quality: \(sizePx.width)x\(sizePx.height) preset=\(preset)")
                    }
                case .safe:
                    exportSizePx = originalSizePx
                    exportPreset = .high
                }

                // Recompute budget with final export parameters (cheap, stateless)
                let budget = ExportPreflightPlanner.plan(
                    sceneCount: sceneCount,
                    canvasSize: exportSizePx,
                    videoSlotCount: totalVideoSlots,
                    backgroundRegionCount: backgroundRegionCount,
                    currentPreset: exportPreset,
                    fps: engine.fps
                ).budget
                let settings = self.makeTimelineExportSettings(
                    outputURL: outputURL,
                    sizePx: exportSizePx,
                    preset: exportPreset,
                    fps: engine.fps,
                    audio: audioConfig
                )

                // Build lightweight background snapshot (textures loaded on exportQueue)
                let bgSnapshot = ExportBackgroundSnapshot.build(
                    from: self.projectBackgroundOverride,
                    effectiveState: self.effectiveBackgroundState
                )

                // P1: Cancel may have arrived during preflight — bail out
                guard self.isActiveExportRequest(requestId) else {
                    self.log("[Export] Cancelled during preflight (stale request)")
                    self.exitExportModeToIdle()
                    return
                }

                exporter.exportTimeline(
                    engine: engine,
                    backgroundState: self.effectiveBackgroundState,
                    backgroundSnapshot: bgSnapshot,
                    settings: settings,
                    budget: budget,
                    onFinishing: { [weak self, weak progressVC] in
                        guard let self, self.isActiveExportRequest(requestId) else { return }
                        progressVC?.updateState(.finishing)
                    },
                    progress: { [weak self, weak progressVC] progress in
                        guard let self, self.isActiveExportRequest(requestId) else { return }
                        progressVC?.updateState(.rendering(progress: progress))
                    },
                    completion: { [weak self] result in
                        guard let self else { return }
                        self.exitExportModeToIdle()
                        guard self.isActiveExportRequest(requestId) else {
                            self.log("[Export] Ignoring stale completion")
                            return
                        }

                        switch result {
                        case .success(let url):
                            self.log("[Export] SUCCESS: \(url.lastPathComponent)")
                            self.handleExportSuccess()
                            progressVC.updateState(.savingToPhotos)
                            self.saveExportedVideoToPhotos(url, requestId: requestId, progressVC: progressVC)

                        case .failure(let error as VideoExportError) where error.isCancelled:
                            self.log("[Export] Cancelled")
                            self.clearExportRequestIfCurrent(requestId)

                        case .failure(let error):
                            self.log("[Export] ERROR: \(error.localizedDescription)")
                            self.clearExportRequestIfCurrent(requestId)
                            self.dismiss(animated: true) {
                                self.presentExportError(error)
                            }
                        }
                    }
                )
            }
        }
    }

    /// Production test seam: deliverer factory.
    /// Tests can replace this to inject a mock deliverer.
    var makeDeliverer: () -> ExportDelivering = { ExportDeliveryCoordinator() }

    private func saveExportedVideoToPhotos(_ url: URL, requestId: UUID, progressVC: ExportProgressViewController) {
        let deliverer = makeDeliverer()
        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            isRequestActive: { [weak self] id in self?.isActiveExportRequest(id) ?? false },
            clearRequestIfCurrent: { [weak self] id in self?.clearExportRequestIfCurrent(id) },
            completion: { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .ignoredStale:
                    self.log("[Export] Ignoring stale delivery completion")
                case .savedToPhotos:
                    self.dismiss(animated: true) { self.presentSavedToPhotosAlert() }
                case .showPermissionSettings:
                    self.dismiss(animated: true) { self.presentPhotoLibraryPermissionAlert() }
                case .showError(let error):
                    self.dismiss(animated: true) { self.presentExportError(error) }
                }
            }
        )
        // Store flow in active request so it's strongly retained through delivery
        activeExportRequest?.deliveryFlow = flow
        flow.start(fileURL: url, destination: .photoLibrary)
    }

    private func presentSavedToPhotosAlert() {
        let alert = UIAlertController(title: "Saved to Photos",
            message: "Your video has been saved to the Photos library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentPhotoLibraryPermissionAlert() {
        let alert = UIAlertController(title: "Photos Access Required",
            message: "Animi needs permission to save videos to your Photos library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func presentExportError(_ error: Error) {
        let alert = UIAlertController(
            title: "Export Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.addAction(UIAlertAction(title: "Copy Error Details", style: .default) { _ in
            UIPasteboard.general.string = error.localizedDescription
        })
        present(alert, animated: true)
    }

    @objc private func playPauseTapped() {
        // PR-G: Check both isPlaying AND pending prewarm task
        // During prewarm, isPlaying is false but playbackStartTask is active
        // Tap should cancel prewarm in that case
        if isPlaying || playbackStartTask != nil {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    // PR-D: Tap handler for Scene Edit mode (on overlayView)
    @objc private func overlayViewTapped(_ recognizer: UITapGestureRecognizer) {
        guard case .sceneEdit = editorStore?.state.uiMode else { return }
        let point = recognizer.location(in: overlayView)
        sceneEditController?.handleTap(viewPoint: point)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard case .sceneEdit = editorStore?.state.uiMode else { return }
        sceneEditController?.handlePan(recognizer)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard case .sceneEdit = editorStore?.state.uiMode else { return }
        sceneEditController?.handlePinch(recognizer)
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard case .sceneEdit = editorStore?.state.uiMode else { return }
        sceneEditController?.handleRotation(recognizer)
    }

    // MARK: - User Media Actions (PR-32)

    @objc private func addPhotoTapped() {
        guard editorStore?.state.selectedBlockId != nil else { return }
        presentPhotoPicker(for: .images)
    }

    /// Handles ingest completion from MediaIngestCoordinator.
    ///
    /// Identity contract:
    /// 1. Check target scene still exists in timeline (prevent resurrection of deleted scene).
    /// 2. Persist slot to store for result.sceneInstanceId (always, if scene exists).
    /// 3. Runtime apply ONLY if activeSceneInstanceId == result.sceneInstanceId.
    /// 4. If target scene was deleted, delete the persisted file (orphan cleanup).
    @MainActor
    private func handleIngestComplete(_ result: IngestResult) async {
        let timeline = editorStore?.state.canonicalTimeline

        // Guard: target scene must still exist in the timeline
        guard let sceneItem = timeline?.sceneItems.first(where: { $0.id == result.sceneInstanceId }) else {
            // Scene was deleted while ingest was in-flight — clean up persisted file
            try? FileManager.default.removeItem(at: result.persistedURL)
            log("[UserMedia] Ingest completed for deleted scene \(result.sceneInstanceId), cleaned up orphan")
            return
        }

        // Resolve defaultFit from template metadata of the target scene
        let defaultFit: FitMode = await resolveDefaultFitAsync(
            sceneItem: sceneItem,
            timeline: timeline,
            blockId: result.blockId
        )

        // Re-validate: scene may have been deleted during async defaultFit resolution
        let currentTimeline = editorStore?.state.canonicalTimeline
        guard currentTimeline?.sceneItems.contains(where: { $0.id == result.sceneInstanceId }) == true else {
            try? FileManager.default.removeItem(at: result.persistedURL)
            log("[UserMedia] Scene \(result.sceneInstanceId) deleted during defaultFit resolution, cleaned up orphan")
            return
        }

        let placement = MediaPlacementState.default(fitMode: defaultFit)

        // Build final slot with non-nil placement
        let slot: SceneMediaSlot
        switch result.mediaKind {
        case .photo:
            slot = .photo(mediaRef: result.mediaRef, placement: placement)
        case .video:
            guard let videoWindow = result.videoWindow else {
                assertionFailure("[UserMedia] Video ingest missing videoWindow")
                try? FileManager.default.removeItem(at: result.persistedURL)
                log("[UserMedia] Video ingest missing videoWindow, cleaned up orphan")
                return
            }
            slot = .video(mediaRef: result.mediaRef, placement: placement, videoWindow: videoWindow)
        }

        // Persist slot to store
        editorStore?.dispatch(.setMediaSlot(
            sceneInstanceId: result.sceneInstanceId,
            blockId: result.blockId,
            slot: slot
        ))

        log("[UserMedia] Ingest complete for block '\(result.blockId)'@\(result.sceneInstanceId): \(result.mediaRef.id)")
    }

    /// Resolves defaultFit from template metadata via scene-type resources cache.
    /// For cold/inactive scenes, preloads metadata asynchronously before retry.
    private func resolveDefaultFitAsync(
        sceneItem: TimelineItem,
        timeline: CanonicalTimeline?,
        blockId: String
    ) async -> FitMode {
        guard let payload = timeline?.payloads[sceneItem.payloadId],
              case .scene(let scenePayload) = payload,
              let cache = timelineCompositionEngine?.resourcesCache else {
            return .cover
        }
        return await DefaultFitResolver.resolve(
            sceneTypeId: scenePayload.sceneTypeId,
            blockId: blockId,
            cache: cache
        )
    }

    private func presentPhotoPicker(for filter: PHPickerFilter) {
        var config = PHPickerConfiguration()
        config.filter = filter
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: - PR-E: Scene Edit Media Picker

    /// Presents media picker for Scene Edit with deterministic blockId tracking.
    /// - Parameters:
    ///   - blockId: The block ID for which media is being picked
    ///   - kind: Whether to pick photo or video
    private func presentMediaPicker(for blockId: String, kind: MediaKind) {
        // Capture identity at picker-open time (not at callback time)
        assertSceneEditTargetMatchesRuntimeIfPossible()
        guard let instanceId = sceneEditTargetInstanceId else {
            log("[UserMedia] No scene edit target, cannot open picker")
            return
        }
        pendingPickerRequest = IngestSlotKey(sceneInstanceId: instanceId, blockId: blockId)

        var config = PHPickerConfiguration()
        config.filter = (kind == .photo) ? .images : .videos
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Presents variant picker as action sheet for Scene Edit (PR-E).
    /// - Parameter blockId: The block ID for which to show variants
    private func presentVariantPicker(blockId: String) {
        guard let player = scenePlayer else { return }

        let variants = player.availableVariants(blockId: blockId)
        guard !variants.isEmpty else { return }

        // Get current variant for checkmark
        let currentVariantId = player.selectedVariantId(blockId: blockId)

        let alert = UIAlertController(title: "Animation", message: nil, preferredStyle: .actionSheet)

        for variant in variants {
            let action = UIAlertAction(title: variant.id, style: .default) { [weak self] _ in
                self?.applyVariant(blockId: blockId, variantId: variant.id)
            }
            // Show checkmark for current variant
            if variant.id == currentVariantId {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad support: configure popover
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        present(alert, animated: true)
    }

    /// Applies variant selection to runtime and persists to store (PR-E).
    private func applyVariant(blockId: String, variantId: String) {
        // 1. Apply to runtime
        scenePlayer?.setSelectedVariant(blockId: blockId, variantId: variantId)
        metalView.setNeedsDisplay()

        // 2. Update overlay
        sceneEditController?.updateOverlay()

        // 3. Persist to store
        assertSceneEditTargetMatchesRuntimeIfPossible()
        guard let instanceId = sceneEditTargetInstanceId else { return }
        editorStore?.dispatch(.setBlockVariant(
            sceneInstanceId: instanceId,
            blockId: blockId,
            variantId: variantId
        ))
    }

    // MARK: - Scene Catalog

    /// Presents the scene catalog for adding a new scene.
    private func presentSceneCatalog() {
        guard let library = sceneLibrarySnapshot else {
            log("[SceneCatalog] presentSceneCatalog: sceneLibrarySnapshot is nil")
            let alert = UIAlertController(
                title: "Scenes Unavailable",
                message: "Scene library could not be loaded. Please try again.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let catalogVC = SceneCatalogViewController(sceneLibrary: library)
        catalogVC.onSelectScene = { [weak self] sceneTypeId, baseDurationUs in
            self?.handleAddScene(sceneTypeId: sceneTypeId, baseDurationUs: baseDurationUs)
        }

        let navController = UINavigationController(rootViewController: catalogVC)
        present(navController, animated: true)
    }

    /// Handles scene selection from catalog.
    private func handleAddScene(sceneTypeId: String, baseDurationUs: TimeUs) {
        guard let store = editorStore else {
            log("[SceneCatalog] handleAddScene: editorStore is nil")
            return
        }

        // Dispatch addScene action to store
        store.dispatch(.addScene(sceneTypeId: sceneTypeId, durationUs: baseDurationUs))
        log("[SceneCatalog] Added scene: \(sceneTypeId) duration=\(baseDurationUs)us")
    }

    override var prefersStatusBarHidden: Bool {
        fullScreenPreviewVC != nil
    }

    // MARK: - Load Pre-Compiled Template (Release Path - PR2)

    /// PR-D: Updates UI based on loading state.
    private func updateLoadingStateUI() {
        switch loadingState {
        case .idle:
            preparingOverlay.hide()

        case .preparing:
            preparingOverlay.reset()
            preparingOverlay.show(text: "Loading template...")

        case .ready:
            preparingOverlay.hide()

        case .failed(let message):
            preparingOverlay.showError(message)
        }
    }

    // MARK: - Release v1: Scene Type Loading

    /// Loads a scene type from the SceneLibrary.
    /// Uses sceneLibrarySnapshot.folderURL for scene resolution.
    private func loadSceneTypeFromBundle(sceneTypeId: String) {
        stopPlayback()
        renderErrorLogged = false
        log("---\n[Release v1] Loading scene type '\(sceneTypeId)'...")

        guard let device = metalView.device else {
            log("ERROR: No Metal device")
            loadingState = .failed(message: "No Metal device")
            updateLoadingStateUI()
            return
        }

        // Get scene folder URL from SceneLibrary
        guard let sceneDescriptor = sceneLibrarySnapshot?.scene(byId: sceneTypeId),
              let sceneURL = sceneDescriptor.folderURL else {
            log("ERROR: Scene type '\(sceneTypeId)' not found in library")
            loadingState = .failed(message: "Scene not found")
            updateLoadingStateUI()
            return
        }

        // PR-D: Cancel previous loading task if any
        preparingTask?.cancel()

        // PR-D: Generate new request ID for cancellation check
        let requestId = UUID()
        currentRequestId = requestId
        loadingState = .preparing(requestId: requestId)
        updateLoadingStateUI()

        // PR-D: Async loading pipeline
        preparingTask = Task { [weak self] in
            guard let self = self else { return }

            // === PHASE 1: Background ===
            do {
                try Task.checkCancellation()

                // Heavy IO via shared pipeline
                let loaded = try await SceneTypeLoadPipeline.load(
                    sceneTypeId: sceneTypeId,
                    from: sceneURL
                )

                guard !Task.isCancelled, self.currentRequestId == requestId else {
                    await MainActor.run { self.log("Scene load cancelled") }
                    return
                }

                // === PHASE 2: Main Actor — ScenePlayer setup ===
                await MainActor.run {
                    self.log("Scene package loaded: \(sceneTypeId)")
                    self.preparingOverlay.setStatus("Preparing scene...")
                }

                let sceneSetupResult: SceneSetupResult = await MainActor.run {
                    let player = ScenePlayer()
                    let compiled = player.loadCompiledScene(loaded.compiled)
                    return SceneSetupResult(player: player, compiled: compiled)
                }

                guard !Task.isCancelled, self.currentRequestId == requestId else { return }

                // === PHASE 3: Background — Texture preload ===
                await MainActor.run {
                    self.preparingOverlay.setStatus("Loading textures...")
                }

                let (provider, queue): (ScenePackageTextureProvider, MTLCommandQueue?) = await MainActor.run {
                    let p = SceneTextureProviderFactory.create(
                        device: device,
                        mergedAssetIndex: sceneSetupResult.compiled.mergedAssetIndex,
                        resolver: loaded.resolver,
                        bindingAssetIds: sceneSetupResult.compiled.bindingAssetIds,
                        logger: { [weak self] msg in
                            Task { @MainActor in self?.log(msg) }
                        }
                    )
                    return (p, self.commandQueue)
                }

                try await Task(priority: .userInitiated) {
                    try Task.checkCancellation()
                    if let q = queue {
                        provider.preloadAll(commandQueue: q)
                    }
                }.value

                guard !Task.isCancelled, self.currentRequestId == requestId else { return }

                // === PHASE 4: Main Actor — Finalize ===
                await MainActor.run {
                    self.applyLoadedSceneType(
                        sceneTypeId: sceneTypeId,
                        player: sceneSetupResult.player,
                        compiled: sceneSetupResult.compiled,
                        provider: provider,
                        resolver: loaded.resolver,
                        requestId: requestId
                    )
                }

            } catch is CancellationError {
                await MainActor.run { self.log("Scene load cancelled") }
            } catch {
                guard self.currentRequestId == requestId else { return }
                await MainActor.run {
                    self.log("ERROR: Failed to load scene: \(error)")
                    self.loadingState = .failed(message: "Failed to load scene")
                    self.updateLoadingStateUI()
                }
            }
        }
    }

    /// Release v1: Applies loaded scene type to UI.
    private func applyLoadedSceneType(
        sceneTypeId: String,
        player: ScenePlayer,
        compiled: CompiledScene,
        provider: ScenePackageTextureProvider,
        resolver: CompositeAssetResolver,
        requestId: UUID
    ) {
        guard currentRequestId == requestId else {
            log("Scene load result discarded")
            return
        }

        // Log preload stats
        if let stats = provider.lastPreloadStats {
            log(String(format: "[Preload] loaded: %d, missing: %d, skipped: %d, duration: %.1fms",
                       stats.loadedCount, stats.missingCount, stats.skippedBindingCount, stats.durationMs))
        }

        // PR-E: Apply to state
        compiledScene = compiled
        scenePlayer = player
        textureProvider = provider
        currentResolver = resolver

        // Store canvas size
        canvasSize = compiled.runtime.canvasSize

        // Store merged asset sizes
        mergedAssetSizes = compiled.mergedAssetIndex.sizeById

        // Create UserMediaService
        if let tp = textureProvider, let queue = commandQueue {
            userMediaService = UserMediaService(
                device: metalView.device!,
                commandQueue: queue,
                scenePlayer: player,
                textureProvider: tp
            )
            userMediaService?.setSceneFPS(Double(compiled.runtime.fps))
            userMediaService?.onNeedsDisplay = { [weak self] in
                self?.metalView.setNeedsDisplay()
                // PR-F: Sync video frame when provider becomes ready after undo/redo
                self?.syncPausedVideoStill(force: true)
            }
            // PR2: Render-only callback for async still frame delivery (no re-sync)
            userMediaService?.onStillFrameDelivered = { [weak self] in
                self?.metalView.setNeedsDisplay()
            }
            // PR4: Re-resolve placement after async media load
            userMediaService?.onMediaReady = { [weak self] blockId in
                self?.handleMediaReadyForPlacement(blockId: blockId)
            }
            log("UserMediaService initialized")
        }

        // PR3: Setup background state
        setupBackgroundState(compiled: compiled)

        // Log results
        let runtime = compiled.runtime
        let canvasSizeStr = "\(Int(canvasSize.width))x\(Int(canvasSize.height))"
        log("[Release v1] Scene loaded: \(canvasSizeStr) @ \(runtime.fps)fps, \(runtime.durationFrames) frames")

        // Store scene properties
        totalFrames = runtime.durationFrames
        sceneFPS = Double(runtime.fps)

        // Configure editor timeline (Release v1: uses new loadProject action)
        configureEditorTimeline()

        // Setup playback controls
        currentFrameIndex = 0

        // Transition to ready state
        loadingState = .ready
        updateLoadingStateUI()

        // Trigger first frame render
        metalView.setNeedsDisplay()
    }

    // MARK: - Background Setup (PR3)

    /// Sets up background state from template and project override.
    private func setupBackgroundState(compiled: CompiledScene) {
        guard currentTemplateId != nil,
              let device = metalView.device,
              let queue = commandQueue else {
            log("[Background] Skipped: missing dependencies")
            return
        }

        // PR-G: Create shared background texture provider (project-level, not per-scene)
        backgroundTextureProvider = InMemoryTextureProvider()

        // Create BackgroundTextureService with shared background provider
        backgroundTextureService = BackgroundTextureService(
            textureProvider: backgroundTextureProvider!,
            device: device,
            commandQueue: queue
        )

        // Load background from active draft slot
        projectBackgroundOverride = activeDraftSlot?.draft.background

        // Build effective state
        let templateBackground = compiled.runtime.scene.background
        effectiveBackgroundState = EffectiveBackgroundBuilder.build(
            templateBackground: templateBackground,
            projectOverride: projectBackgroundOverride,
            presetLibrary: BackgroundPresetLibrary.shared
        )

        if let state = effectiveBackgroundState {
            log("[Background] Loaded preset '\(state.preset.presetId)' with \(state.regionStates.count) regions")

            // Preload image textures asynchronously
            if let override = projectBackgroundOverride {
                Task {
                    let loadedKeys = await backgroundTextureService?.preloadTextures(
                        from: override,
                        presetId: state.preset.presetId
                    )
                    if let keys = loadedKeys, !keys.isEmpty {
                        log("[Background] Preloaded \(keys.count) textures")
                    }
                    metalView.setNeedsDisplay()
                }
            }
        } else {
            log("[Background] No effective state (preset not found)")
        }
    }

    // MARK: - Playback

    private func startPlayback() {
        // PR-F: Playback only allowed in timeline mode
        let uiMode = editorStore?.state.uiMode ?? .timeline
        guard EditorRenderContract.isPlaybackAllowed(in: uiMode) else {
            assertionFailure("startPlayback called outside timeline mode")
            return
        }

        // PR-G: Guard re-entry - don't start another if already starting
        guard playbackStartTask == nil else { return }

        // PR-G: Timeline mode requires engine (not legacy compiledScene)
        guard let engine = timelineCompositionEngine else {
            assertionFailure("startPlayback requires timelineCompositionEngine")
            return
        }

        // Phase 2.1: Use compressed frame directly from store (no conversion needed)
        let compressedFrame = editorStore?.playheadCompressedFrame ?? 0
        let fps = Float(sceneFPS)

        // PR-G: Prewarm scenes BEFORE starting display link
        // This ensures pinned + warm runtimes are ready before first playback tick
        playbackStartTask = Task { @MainActor in
            // Step 1: Prewarm (awaited)
            await engine.prepareForPlayback(startingAt: compressedFrame)

            // Check if playback was cancelled during prewarm
            guard !Task.isCancelled else {
                self.playbackStartTask = nil
                return
            }

            // Step 2: Start playback state
            self.isPlaying = true

            // Step 3: Create and start display link
            self.displayLink = CADisplayLink(target: self, selector: #selector(self.displayLinkFired))
            self.displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
            self.displayLink?.add(to: .main, forMode: .common)

            // Step 4: Start video playback through engine
            engine.startPlayback(at: compressedFrame)

            // PR2: Update editor layout play state
            self.editorLayoutContainer.setPlaying(true)
            self.fullScreenPreviewVC?.setPlaying(true)

            // Clear task reference
            self.playbackStartTask = nil
        }
    }

    private func stopPlayback() {
        // PR-G: Cancel pending playback start task (if prewarm is in progress)
        playbackStartTask?.cancel()
        playbackStartTask = nil

        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil

        // PR-G: Stop video playback through engine for timeline mode
        if timelineCompositionEngine != nil {
            timelineCompositionEngine?.stopPlayback()
        } else {
            // Fallback: legacy path for sceneEdit mode
            userMediaService?.stopVideoPlayback()
        }

        // PR2: Update editor layout play state
        editorLayoutContainer.setPlaying(false)
        fullScreenPreviewVC?.setPlaying(false)
    }

    @objc private func displayLinkFired() {
        // Phase 2.1: Calculate next frame in compressed domain
        guard let store = editorStore else { return }

        // Increment by 1 frame in compressed domain
        let currentFrame = store.playheadCompressedFrame
        let maxFrame = store.state.compressedDurationFrames - 1
        let nextFrame = min(currentFrame + 1, maxFrame)

        // Dispatch to store - onPlayheadChanged callback handles coordinator + redraw + timeline scroll
        store.dispatch(.setPlayhead(compressedFrame: nextFrame))

        // Full screen preview (not driven by store callback)
        fullScreenPreviewVC?.setCurrentCompressedFrame(nextFrame)

        // PR-F: Video sync via engine in timeline mode, legacy path in sceneEdit mode
        let uiMode = store.state.uiMode
        switch uiMode {
        case .timeline:
            // Use engine-driven video sync (routes to per-instance UserMediaService)
            // Phase 2.1: Use nextFrame directly (already compressed)
            timelineCompositionEngine?.syncPlaybackTick(nextFrame)

        case .sceneEdit:
            // Legacy path - use coordinator's local frame
            let mapper = store.state.makePlayheadMapper()
            let nextTimeUs = mapper.nominalTimeUs(forCompressedFrame: nextFrame)
            let fps = store.state.templateFPS
            let globalFrameIndex = Int(nextTimeUs * TimeUs(fps) / 1_000_000)
            let localFrame = playbackCoordinator?.currentLocalFrame ?? globalFrameIndex
            if let service = userMediaService,
               !service.blockIdsWithVideo.isEmpty,
               localFrame != lastStillSyncFrame {
                service.updateVideoFramesForPlayback(sceneFrameIndex: localFrame)
                lastStillSyncFrame = localFrame
            }
        }

        // Auto-stop at end (check using compressed domain)
        if nextFrame >= maxFrame {
            stopPlayback()
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        logger.info("\(message)")
    }

    // MARK: - Scrub Render Throttle (A/B Testing)

    /// Requests Metal render with optional throttling during scrub drag.
    /// Used for A/B testing render pipeline bottleneck hypothesis.
    /// - Only applies throttle/skip when `isScrubDragging == true`
    /// - Otherwise passes through to `metalView.setNeedsDisplay()` immediately
    private func requestMetalRender() {
        #if DEBUG
        // Only apply throttle/skip during active scrub drag
        guard isScrubDragging else {
            metalView.setNeedsDisplay()
            return
        }

        // H3: Skip render entirely during drag (test if render is the bottleneck)
        if ScrubDebugToggles.skipMetalRender {
            pendingScrubRender = true
            return
        }

        // H3-throttle: Limit render to 30Hz during drag
        if ScrubDebugToggles.throttleRender30Hz {
            let now = CACurrentMediaTime()
            let minInterval = 1.0 / 30.0  // 33.3ms
            if now - lastScrubRenderAt < minInterval {
                pendingScrubRender = true
                return
            }
            lastScrubRenderAt = now
            pendingScrubRender = false
        }
        #endif

        metalView.setNeedsDisplay()
    }
}

// MARK: - MTKViewDelegate

extension PlayerViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

    func draw(in view: MTKView) {
        // Model A contract: draw must execute on main thread
        dispatchPrecondition(condition: .onQueue(.main))

        // PR-D.1: No draw while template is loading (prevents race with background preload)
        guard loadingState == .ready else { return }

        // PR-F: Route to appropriate render path based on UI mode
        let uiMode = editorStore?.state.uiMode ?? .timeline

        switch uiMode {
        case .timeline:
            drawTimelineMode(in: view)
        case .sceneEdit:
            drawSceneEditMode(in: view)
        }
    }

    /// PR-F: Renders timeline mode using TimelineCompositionEngine.
    /// Handles single scene and transition rendering.
    /// PR-G: Uses split-pass architecture - background pre-pass with backgroundTextureProvider,
    /// then scene pass with scene provider using initialLoadAction: .load.
    private func drawTimelineMode(in view: MTKView) {
        // Use cached timeline frame from async resolve
        guard let resolvedFrame = cachedTimelineFrame else {
            // PR-G: No cached frame yet - skip rendering, keep last valid frame
            // Timeline mode NEVER calls drawSceneEditMode() to maintain render contract separation
            return
        }

        switch resolvedFrame {
        case .single(let ctx):
            // PR-G: Split-pass rendering for single scene
            drawTimelineSingleScene(in: view, context: ctx)
        case .transition:
            // Transition rendering requires compositor - handle separately
            drawTimelineTransition(in: view, context: resolvedFrame)
        }
    }

    /// TT-06: Renders single scene in timeline mode via unified TimelineRenderExecutor.
    private func drawTimelineSingleScene(in view: MTKView, context ctx: SceneRenderContext) {
        guard ctx.canvasSize.width > 0 else { return }
        guard let renderer = renderer,
              let cmdQueue = commandQueue else { return }

        // PR-A: Non-blocking wait for in-flight frame slot
        let semResult = inFlightSemaphore.wait(timeout: .now())
        if semResult == .timedOut {
            #if DEBUG
            perfLogger.recordDroppedFrame()
            #endif
            return
        }

        guard let drawable = view.currentDrawable else {
            inFlightSemaphore.signal()
            return
        }

        #if DEBUG
        perfLogger.recordFrame()
        #endif

        let request = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: drawable.texture,
            drawableScale: Double(view.contentScaleFactor),
            timelineCanvasSize: ctx.canvasSize,
            backgroundState: effectiveBackgroundState,
            backgroundTextureProvider: backgroundTextureProvider,
            clearColorOverride: nil,
            presentationDrawable: drawable,
            waitUntilCompleted: false,
            diagnosticFrameTag: cachedTimelineCompressedFrame
        )

        do {
            try TimelineRenderExecutor.render(
                request, renderer: renderer,
                commandQueue: cmdQueue, transitionCompositor: nil,
                completionQueue: nil,
                onCommandBufferCompleted: { [weak self] _ in self?.inFlightSemaphore.signal() },
                renderSink: timelineCompositionEngine?.renderDiagnosticsSink
            )
        } catch {
            inFlightSemaphore.signal()
            if !renderErrorLogged {
                renderErrorLogged = true
                log("Render error: \(error)")
            }
        }
    }

    /// TT-06: Renders transition between two scenes via unified TimelineRenderExecutor.
    /// Fallback: render scene B only if compositor unavailable (instant cut behavior).
    private func drawTimelineTransition(in view: MTKView, context: ResolvedTimelineFrame) {
        guard case .transition(let transCtx) = context else { return }
        guard let renderer = renderer,
              let cmdQueue = commandQueue,
              let compositor = transitionCompositor else {
            // Fallback: render scene B only (instant cut behavior)
            drawWithParams(
                in: view,
                commands: transCtx.sceneB.commands,
                textureProvider: transCtx.sceneB.textureProvider,
                pathRegistry: transCtx.sceneB.pathRegistry,
                assetSizes: transCtx.sceneB.assetSizes,
                animSize: transCtx.sceneB.canvasSize
            )
            return
        }

        // PR-A: Non-blocking wait for in-flight frame slot
        let semResult = inFlightSemaphore.wait(timeout: .now())
        if semResult == .timedOut {
            #if DEBUG
            perfLogger.recordDroppedFrame()
            #endif
            return
        }

        guard let drawable = view.currentDrawable else {
            inFlightSemaphore.signal()
            return
        }

        #if DEBUG
        perfLogger.recordFrame()
        #endif

        let request = TimelineRenderRequest(
            resolved: context,
            targetTexture: drawable.texture,
            drawableScale: Double(view.contentScaleFactor),
            timelineCanvasSize: transCtx.sceneA.canvasSize,
            backgroundState: effectiveBackgroundState,
            backgroundTextureProvider: backgroundTextureProvider,
            clearColorOverride: nil,
            presentationDrawable: drawable,
            waitUntilCompleted: false,
            diagnosticFrameTag: cachedTimelineCompressedFrame
        )

        do {
            try TimelineRenderExecutor.render(
                request, renderer: renderer,
                commandQueue: cmdQueue, transitionCompositor: compositor,
                completionQueue: .main,
                onCommandBufferCompleted: { [weak self] _ in self?.inFlightSemaphore.signal() },
                renderSink: timelineCompositionEngine?.renderDiagnosticsSink
            )
        } catch {
            inFlightSemaphore.signal()
            if !renderErrorLogged {
                renderErrorLogged = true
                log("[TT-06] Transition render error: \(error)")
            }
        }
    }

    /// PR-F: Renders Scene Edit mode using EditorRenderCommandResolver (legacy path).
    private func drawSceneEditMode(in view: MTKView) {
        let coordinator = playbackCoordinator
        let player = scenePlayer
        let frameIndex = currentFrameIndex

        guard let uiMode = editorStore?.state.uiMode,
              case .sceneEdit(let sceneEditTargetId) = uiMode else { return }

        // Render guard: don't draw until activation completes for the target scene
        guard sceneEditReadyInstanceId == sceneEditTargetId else { return }

        guard let resolved = EditorRenderCommandResolver.resolve(
            uiMode: uiMode,
            coordinatorLocalFrame: coordinator?.currentLocalFrame,
            currentFrameIndex: frameIndex,
            coordinatorCommands: { mode in
                coordinator?.currentRenderCommands(mode: mode)
            },
            scenePlayerCommands: { mode, frame in
                player?.renderCommands(mode: mode, sceneFrameIndex: frame)
            }
        ) else {
            // No valid commands - keep last valid frame
            return
        }

        guard let compiled = compiledScene,
              let provider = textureProvider else { return }

        drawWithParams(
            in: view,
            commands: resolved.commands,
            textureProvider: provider,
            pathRegistry: compiled.pathRegistry,
            assetSizes: mergedAssetSizes,
            animSize: canvasSize
        )
    }

    /// PR-F: Common render path with resolved parameters.
    private func drawWithParams(
        in view: MTKView,
        commands: [RenderCommand],
        textureProvider provider: TextureProvider,
        pathRegistry: PathRegistry,
        assetSizes: [String: AssetSize],
        animSize: SizeD
    ) {
        guard animSize.width > 0 else { return }

        // PR1.5: Split timing - start
        #if DEBUG
        let tSemStart = CACurrentMediaTime()
        #endif

        // PR-A: Non-blocking wait for in-flight frame slot
        let semResult = inFlightSemaphore.wait(timeout: .now())
        if semResult == .timedOut {
            #if DEBUG
            perfLogger.recordDroppedFrame()
            #endif
            return
        }

        #if DEBUG
        let tSemEnd = CACurrentMediaTime()
        #endif

        guard let drawable = view.currentDrawable,
              let cmdQueue = commandQueue,
              let cmdBuf = cmdQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        cmdBuf.addCompletedHandler { [weak self] cb in
            self?.inFlightSemaphore.signal()
            #if DEBUG
            if let s = GPUFrameTime.fromCompleted(commandBuffer: cb) {
                self?.perfLogger.recordGPUSample(s.gpuMs)
            }
            #endif
        }

        #if DEBUG
        perfLogger.recordFrame()
        let drawT0 = CACurrentMediaTime()
        var tEncodeEnd: CFAbsoluteTime = tSemEnd
        #endif

        if let renderer = renderer {
            let target = RenderTarget(
                texture: drawable.texture,
                drawableScale: Double(view.contentScaleFactor),
                animSize: animSize
            )

            do {
                // PR-G: Split-pass architecture (same as timeline single-scene path)
                // Pass 1: Background pre-pass with backgroundTextureProvider
                let bgProvider: TextureProvider = backgroundTextureProvider ?? InMemoryTextureProvider()
                try renderer.draw(
                    commands: [],
                    target: target,
                    textureProvider: bgProvider,
                    commandBuffer: cmdBuf,
                    assetSizes: [:],
                    pathRegistry: PathRegistry(),
                    backgroundState: effectiveBackgroundState,
                    initialLoadAction: .clear
                )

                // Pass 2: Scene pass (preserves background)
                try renderer.draw(
                    commands: commands,
                    target: target,
                    textureProvider: provider,
                    commandBuffer: cmdBuf,
                    assetSizes: assetSizes,
                    pathRegistry: pathRegistry,
                    backgroundState: nil,
                    initialLoadAction: .load
                )
                #if DEBUG
                tEncodeEnd = CACurrentMediaTime()
                #endif
            } catch {
                if !renderErrorLogged {
                    renderErrorLogged = true
                    log("Render error: \(error)")
                }
            }
        } else if let desc = view.currentRenderPassDescriptor,
                  let enc = cmdBuf.makeRenderCommandEncoder(descriptor: desc) {
            enc.endEncoding()
        }

        cmdBuf.present(drawable)

        #if DEBUG
        let drawDtMs = (CACurrentMediaTime() - drawT0) * 1000.0
        perfLogger.recordDrawCPU(ms: drawDtMs)
        let semMs = (tSemEnd - tSemStart) * 1000.0
        let encodeMs = (tEncodeEnd - tSemEnd) * 1000.0
        perfLogger.recordSplitTiming(semaphoreMs: semMs, commandsMs: 0, encodeMs: encodeMs)
        #endif

        cmdBuf.commit()
    }
}

// MARK: - UIGestureRecognizerDelegate (PR-19)

extension PlayerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow pinch + rotation simultaneously (for edit mode transforms)
        let isPinchOrRotation = gestureRecognizer is UIPinchGestureRecognizer ||
                                gestureRecognizer is UIRotationGestureRecognizer
        let otherIsPinchOrRotation = otherGestureRecognizer is UIPinchGestureRecognizer ||
                                     otherGestureRecognizer is UIRotationGestureRecognizer
        if isPinchOrRotation && otherIsPinchOrRotation {
            return true
        }

        // Allow scroll view gestures to work simultaneously
        if otherGestureRecognizer.view is UIScrollView {
            return true
        }

        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // PR-E: Pan/pinch/rotation only work in Scene Edit mode WITH a selected block
        if gestureRecognizer is UIPanGestureRecognizer ||
           gestureRecognizer is UIPinchGestureRecognizer ||
           gestureRecognizer is UIRotationGestureRecognizer {
            // Only enable if in Scene Edit mode AND block is selected
            guard case .sceneEdit = editorStore?.state.uiMode else { return false }
            return editorStore?.state.selectedBlockId != nil
        }
        return true
    }
}

// MARK: - PHPickerViewControllerDelegate (PR-32, PR-E)

extension PlayerViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let result = results.first else {
            // User cancelled - clear pending state
            pendingPickerRequest = nil
            return
        }

        // PR3: Check if this is a background image picker
        if picker.view.tag == 999, let regionId = pendingBackgroundRegionId {
            pendingBackgroundRegionId = nil
            handleBackgroundImagePicked(result: result, regionId: regionId)
            return
        }

        // Use the request captured at picker-open time — NOT current sceneEditTargetInstanceId.
        // This ensures the media is attributed to the scene that was active when the user opened the picker.
        guard let key = pendingPickerRequest else {
            log("[UserMedia] No pending picker request, skipping ingest")
            return
        }
        pendingPickerRequest = nil

        mediaIngestCoordinator.ingest(pickerResult: result, key: key)
    }

    /// Shows alert when picked media type doesn't match expected type.
    private func showMediaTypeMismatchAlert() {
        let alert = UIAlertController(
            title: "Wrong Media Type",
            message: "Please select the correct type of media.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - BackgroundEditorDelegate (PR3)

extension PlayerViewController: BackgroundEditorDelegate {

    func backgroundEditorDidUpdateState(_ state: EffectiveBackgroundState) {
        effectiveBackgroundState = state
        metalView.setNeedsDisplay()
    }

    func backgroundEditorDidRequestImagePicker(for regionId: String) {
        // Invalidate any in-flight import from a previous picker request
        backgroundImportGeneration &+= 1

        // Store regionId and editor ref for callback
        pendingBackgroundRegionId = regionId
        if let nav = presentedViewController as? UINavigationController,
           let editor = nav.viewControllers.first as? BackgroundEditorViewController {
            pendingBackgroundEditor = editor
        }

        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        // Use a tag to differentiate from user media picker
        picker.view.tag = 999  // Background image picker tag

        // Present from the editor if visible
        if let presented = presentedViewController {
            presented.present(picker, animated: true)
        } else {
            present(picker, animated: true)
        }
    }

    func backgroundEditorDidChangePreset(oldPresetId: String, newPresetId: String) {
        // P0-2: Cleanup textures for the old preset immediately on change
        backgroundTextureService?.clearTextures(prefix: "bg/\(oldPresetId)/")
        log("[Background] Cleared textures for preset: \(oldPresetId)")

        // Update tracking
        lastBackgroundPresetId = newPresetId

        metalView.setNeedsDisplay()
    }

    func backgroundEditorWillDismiss(override: ProjectBackgroundOverride, presetId: String) {
        // End editor session — invalidate any in-flight async background import so its
        // stale completion cannot apply to a future editor session or persisted state.
        backgroundImportGeneration &+= 1
        pendingBackgroundEditor = nil

        // Mark dirty — will be persisted via saveDraftToActiveSlot/materialize
        draftIsDirty = true

        // P0-2: Check if preset changed and cleanup old textures
        let presetChanged = lastBackgroundPresetId != nil && lastBackgroundPresetId != presetId
        if presetChanged, let oldPresetId = lastBackgroundPresetId {
            backgroundTextureService?.clearTextures(prefix: "bg/\(oldPresetId)/")
            log("[Background] Cleared textures for old preset: \(oldPresetId)")
        }
        lastBackgroundPresetId = presetId

        // Update local state
        projectBackgroundOverride = override

        // Rebuild effective state
        let templateBackground = compiledScene?.runtime.scene.background
        effectiveBackgroundState = EffectiveBackgroundBuilder.build(
            templateBackground: templateBackground,
            projectOverride: override,
            presetLibrary: BackgroundPresetLibrary.shared
        )

        // P0-2: Preload textures for regions with image source
        if let service = backgroundTextureService, let state = effectiveBackgroundState {
            Task { @MainActor in
                for (regionId, regionState) in state.regionStates {
                    if case .image(let imageSource) = regionState.source,
                       let mediaRef = self.projectBackgroundOverride?.regions[regionId]?.imageMediaRef {
                        do {
                            try await service.loadTexture(
                                slotKey: imageSource.slotKey,
                                mediaRef: mediaRef
                            )
                            self.log("[Background] Preloaded texture for \(regionId)")
                        } catch {
                            self.log("[Background] Failed to preload texture: \(error.localizedDescription)")
                        }
                    }
                }
                self.metalView.setNeedsDisplay()
            }
        }

        metalView.setNeedsDisplay()
    }
}

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

