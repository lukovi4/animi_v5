import UIKit
import MetalKit
import PhotosUI
import UniformTypeIdentifiers
import TVECore
#if DEBUG
import TVECompilerCore
#endif

// MARK: - PR1.3: Render Diagnostics Flag

/// Set to `true` to enable [DIAG]/[DIAG-PATH] logging in draw loop.
/// **WARNING**: Enabling this causes DRAW CPU spikes (200-450ms) and "gesture gate timeout".
/// Keep disabled for normal use.
private let kEnableRenderDiagnostics = false

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

// MARK: - Scene Variant Preset (PR-20)

/// A named mapping of blockId -> variantId for scene-level style switching.
struct SceneVariantPreset {
    let id: String
    let title: String
    let mapping: [String: String]  // blockId -> variantId
}

// MARK: - PR-D: Async Loading Helper Structs

/// Result from background phase of template loading.
/// Note: @unchecked Sendable because CompiledScenePackage is a value type with immutable data.
private struct BackgroundLoadResult: @unchecked Sendable {
    let compiledPackage: CompiledScenePackage
    let resolver: CompositeAssetResolver
}

/// Result from ScenePlayer setup phase (main actor only, not Sendable).
private struct SceneSetupResult {
    let player: ScenePlayer
    let compiled: CompiledScene
}

/// Main player view controller with Metal rendering surface.
/// PR-E: Production-only editor mode (dev-UI removed).
final class PlayerViewController: UIViewController {

    // MARK: - Initializers (PR-E: editor mode only)

    /// Current template ID for editor mode
    private var currentEditorTemplateId: String?

    /// Initializer with template ID for editor mode
    init(templateId: String) {
        self.currentEditorTemplateId = templateId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Export State

    private var isExporting = false
    private var videoExporter: VideoExporter?
    private var exportProgressVC: ExportProgressViewController?

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
    private var lastVideoUpdateFrame: Int = -1
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
    /// Current compressed frame for timeline mode (for scrub invalidation).
    private var currentCompressedFrame: Int = 0

    // MARK: - PR9: Active Scene Instance Tracking
    /// Currently active scene instance ID (for per-instance state apply).
    private var activeSceneInstanceId: UUID?

    // MARK: - PR2: Visual Editor Timeline
    private var currentProjectDraft: ProjectDraft?
    /// Tracks whether draft has unsaved changes (Time Refactor: dirty flag for save optimization).
    private var draftIsDirty = false
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
    private var lastBackgroundPresetId: String?

    /// PR-G: Shared background texture provider for project-level background images.
    /// Written by BackgroundTextureService, read by all render paths (preview, transition, export).
    /// Separate from scene texture providers to ensure background textures are always accessible.
    private var backgroundTextureProvider: InMemoryTextureProvider?

    // PR-E: Pending media picker state (deterministic blockId tracking)
    private var pendingPickedMediaBlockId: String?
    private var pendingMediaKind: MediaKind?

    /// Media kind for picker validation (PR-E)
    private enum MediaKind {
        case photo
        case video
    }

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

        // PR-E: Production editor mode - load content from stored templateId
        guard let templateId = currentEditorTemplateId else {
            log("[PR-E] ERROR: No templateId provided")
            return
        }
        Task { @MainActor in
            await loadEditorContent(templateId: templateId)
        }
    }

    // MARK: - Release v1: Editor Content Loading

    /// Loads all editor content: SceneLibrary, Recipe, ProjectDraft, and first scene.
    private func loadEditorContent(templateId: String) async {
        currentTemplateId = templateId

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

        // Step 2: Load Recipe
        do {
            let recipeLoader = BundleTemplateRecipeLoader()
            defaultSceneSequence = try recipeLoader.loadWithDefaults(
                templateId: templateId,
                library: sceneLibrarySnapshot!
            )
            log("[Release v1] Recipe loaded: \(defaultSceneSequence.count) scenes")
        } catch {
            log("[Release v1] ERROR: Failed to load recipe: \(error)")
            loadingState = .failed(message: "Recipe load failed")
            updateLoadingStateUI()
            return
        }

        // Step 3: Load or create ProjectDraft via ProjectStore (single source of truth)
        do {
            let draft = try ProjectStore.shared.createOrLoadProjectDraft(for: templateId)
            currentProjectDraft = draft
            currentProjectId = draft.id
            log("[Release v1] Project draft loaded/created: \(draft.id)")
        } catch {
            log("[Release v1] ERROR: Failed to load/create project: \(error)")
            loadingState = .failed(message: "Project load failed")
            updateLoadingStateUI()
            return
        }

        // Step 4: Load first scene from SceneLibrary
        // P0-2 fix: Use draft timeline first (for saved projects), fallback to recipe
        let firstSceneTypeId: String
        if let draftFirstSceneTypeId = currentProjectDraft?.canonicalTimeline.firstSceneTypeId {
            firstSceneTypeId = draftFirstSceneTypeId
            log("[Release v1] Using first scene from draft: \(firstSceneTypeId)")
        } else if let recipeFirstSceneTypeId = defaultSceneSequence.first?.sceneTypeId {
            firstSceneTypeId = recipeFirstSceneTypeId
            log("[Release v1] Using first scene from recipe: \(firstSceneTypeId)")
        } else {
            log("[Release v1] ERROR: No scenes in draft or recipe")
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
                  case .sceneEdit(let instanceId) = self.editorStore?.state.uiMode else { return }

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
                self.editorStore?.dispatch(.resetSceneState(sceneInstanceId: instanceId))
                self.reloadRuntimeStateForActiveScene()
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

        editorLayoutContainer.onAnimation = { [weak self] blockId in
            self?.presentVariantPicker(blockId: blockId)
        }

        editorLayoutContainer.onToggleEnabled = { [weak self] blockId in
            guard let self = self,
                  case .sceneEdit(let instanceId) = self.editorStore?.state.uiMode else { return }
            // Toggle current state
            let currentPresent = self.editorStore?.state.draft.sceneInstanceStates[instanceId]?.userMediaPresent?[blockId] ?? true
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
                  case .sceneEdit(let instanceId) = self.editorStore?.state.uiMode else { return }
            // Clear runtime
            self.userMediaService?.clear(blockId: blockId)
            // Dispatch to store (sets mediaAssignments = nil, userMediaPresent = false)
            self.editorStore?.dispatch(.setBlockMedia(
                sceneInstanceId: instanceId,
                blockId: blockId,
                media: nil
            ))
            self.metalView.setNeedsDisplay()
            // Refresh MediaBlockActionBar
            self.updateMediaBlockActionBarForSelectedBlock()
        }
    }

    // MARK: - PR1 + PR2: Unified Timeline Event Handling

    /// Routes timeline events from EditorLayoutContainerView.
    /// Scroll events are handled by the container (ruler sync).
    private func handleTimelineEvent(_ event: TimelineEvent) {
        switch event {
        case .scrub(let timeUs, let quantize, let phase):
            handleTimelineScrub(timeUs: timeUs, mode: quantize, phase: phase)

        case .selection(let selection):
            handleTimelineSelectionChanged(selection)

        case .scroll:
            // Handled by container (ruler sync), nothing to do here
            break

        case .trimScene(let sceneId, let newDurationUs, let edge, let phase):
            handleTrimScene(sceneId: sceneId, newDurationUs: newDurationUs, edge: edge, phase: phase)

        case .reorderScene(let sceneId, let toIndex, let phase):
            handleReorderScene(sceneId: sceneId, toIndex: toIndex, phase: phase)
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

    // MARK: - PR2: Editor Callbacks

    private func handleEditorClose() {
        // Stop playback before closing
        stopPlayback()

        // Save draft before closing (Time Refactor: ensures migrated durationUs is persisted)
        saveDraftIfNeeded()

        // Pop back to previous screen
        navigationController?.popViewController(animated: true)
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

        // Configure with current state
        fullScreenVC.configure(currentFrame: currentFrameIndex, isPlaying: isPlaying)

        // Move metalView to fullscreen VC
        metalView.removeFromSuperview()
        fullScreenVC.embedMetalView(metalView)

        // Wire callbacks
        fullScreenVC.onClose = { [weak self] frame in
            guard let self = self else { return }

            // Clear reference
            self.fullScreenPreviewVC = nil

            // Return metalView to editor layout before dismissing
            self.metalView.removeFromSuperview()
            self.editorLayoutContainer.embedMetalView(self.metalView)

            self.dismiss(animated: true) {
                // PR-E: Restore position
                self.currentFrameIndex = frame
                let timeUs = frameToUs(frame, fps: Int(self.sceneFPS))
                self.editorLayoutContainer.setCurrentTimeUs(timeUs)
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
    /// - Parameters:
    ///   - timeUs: Time in microseconds
    ///   - mode: Quantize mode for frame calculation
    ///   - phase: Gesture phase for scrub drag state tracking
    private func handleTimelineScrub(timeUs: TimeUs, mode: QuantizeMode, phase: InteractionPhase) {
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
        editorStore?.dispatch(.setPlayhead(timeUs: timeUs, quantize: mode))
    }

    private func handleTimelineSelectionChanged(_ selection: TimelineSelection) {
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
        store.onPlayheadChanged = { [weak self] timeUs in
            self?.handlePlayheadChanged(timeUs)
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

        // PR-D: Setup Scene Edit interaction controller
        let sceneEditCtrl = SceneEditInteractionController()
        sceneEditCtrl.overlayView = overlayView
        sceneEditCtrl.getScenePlayer = { [weak self] in self?.scenePlayer }
        sceneEditCtrl.getUIMode = { [weak self] in self?.editorStore?.state.uiMode ?? .timeline }
        sceneEditCtrl.getSelectedBlockId = { [weak self] in self?.editorStore?.state.selectedBlockId }

        sceneEditCtrl.onSelectBlock = { [weak self] blockId in
            self?.editorStore?.dispatch(.selectBlock(blockId: blockId))
        }

        sceneEditCtrl.onTransformChanged = { [weak self] blockId, transform, phase in
            guard let self = self else { return }
            // Apply to runtime
            self.scenePlayer?.setUserTransform(blockId: blockId, transform: transform)
            self.metalView.setNeedsDisplay()
        }

        self.sceneEditController = sceneEditCtrl

        // Step 4: Sync local state from store
        currentProjectDraft = store.currentDraft
        log("[Release v1] Timeline configured: \(store.sceneItems.count) scenes, duration=\(store.projectDurationUs)us")

        // PR-E: Configure timeline UI with scenes from store
        let scenes = store.sceneDrafts
        editorLayoutContainer.configure(
            scenes: scenes,
            templateFPS: fps,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )

        // Step 7: Setup TimelinePlaybackCoordinator (Release v1)
        setupPlaybackCoordinator()

        // Step 7b: Setup TimelineCompositionEngine (PR-F: multi-scene with transitions)
        setupTimelineCompositionEngine()

        // Step 8: PR9.1 - Initial apply SceneState for first scene
        // Without this, activeSceneInstanceId stays nil until first scrub/play
        handlePlayheadChanged(store.playheadTimeUs)

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
    }

    /// Resolves a MediaRef to UIImage for the composition engine.
    private func resolveMediaRef(_ mediaRef: MediaRef) async -> UIImage? {
        // Only handle file-based media refs
        guard mediaRef.kind == .file else { return nil }

        // Resolve URL from relative path via ProjectStore
        guard let url = try? ProjectStore.shared.absoluteURL(for: mediaRef) else {
            return nil
        }

        // Load image from URL
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    /// Loads a scene type asynchronously for the coordinator.
    /// Heavy IO (file loading, decoding) runs on background thread to avoid main thread freezes.
    private func loadSceneTypeAsync(sceneTypeId: String) async throws -> TimelinePlaybackCoordinator.LoadedScene {
        guard let sceneDescriptor = sceneLibrarySnapshot?.scene(byId: sceneTypeId),
              let sceneURL = sceneDescriptor.folderURL else {
            throw NSError(domain: "PlayerViewController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Scene not found: \(sceneTypeId)"])
        }

        // Heavy IO on background thread (prevents main thread freezes)
        let (compiledPackage, resolver) = try await Task.detached(priority: .userInitiated) {
            let compiledLoader = CompiledScenePackageLoader(engineVersion: TVECore.version)
            let compiledPackage = try compiledLoader.load(from: sceneURL)

            let localIndex = try LocalAssetsIndex(imagesRootURL: sceneURL.appendingPathComponent("images"))
            let sharedIndex = try SharedAssetsIndex(bundle: Bundle.main, rootFolderName: "SharedAssets")
            let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)

            return (compiledPackage, resolver)
        }.value

        // Metal resources on main thread
        let player = await MainActor.run { ScenePlayer() }
        let compiled = await MainActor.run { player.loadCompiledScene(compiledPackage.compiled) }

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
        lastVideoUpdateFrame = -1

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
                self?.syncPausedVideoFrame(force: true)
            }
        }

        // PR-E: Update canvas size if different
        let newCanvasSize = loadedScene.compiled.runtime.canvasSize
        if canvasSize != newCanvasSize {
            canvasSize = newCanvasSize
        }

        log("[Release v1] Coordinator loaded scene: \(loadedScene.sceneTypeId)")

        // PR9: Apply per-instance state after scene load
        if let instanceId = activeSceneInstanceId {
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
        lastVideoUpdateFrame = -1
    }

    /// Applies persisted SceneState to runtime for a scene instance.
    private func applySceneInstanceState(instanceId: UUID) {
        guard let state = editorStore?.state.draft.sceneInstanceStates[instanceId],
              let player = scenePlayer else {
            return
        }

        // PR-D: Correct order for state restoration:
        // 1. Media assignments (auto sets present=true)
        // 2. Explicit userMediaPresent overrides (can disable)
        // 3. Variant overrides, transforms, toggles

        // STEP 1: Apply media assignments (PR-D: now includes video)
        // This automatically sets userMediaPresent=true for assigned blocks
        // P0-3 fix: Pass userMediaPresent for video presentOnReady calculation
        if let mediaAssignments = state.mediaAssignments {
            applyMediaAssignments(mediaAssignments, userMediaPresent: state.userMediaPresent)
        }

        // STEP 2: Apply explicit userMediaPresent overrides (PR-D: critical fix)
        // This allows "Disable" to override the automatic present=true from assignments
        if let userMediaPresent = state.userMediaPresent {
            for (blockId, present) in userMediaPresent {
                player.setUserMediaPresent(blockId: blockId, present: present)
            }
        }

        // STEP 3: Apply variant overrides
        player.applyVariantSelection(state.variantOverrides)

        // STEP 4: Apply user transforms
        for (blockId, transform) in state.userTransforms {
            player.setUserTransform(blockId: blockId, transform: transform)
        }

        // STEP 5: Apply layer toggles
        for (blockId, toggles) in state.layerToggles {
            for (toggleId, enabled) in toggles {
                player.setLayerToggle(blockId: blockId, toggleId: toggleId, enabled: enabled)
            }
        }

        #if DEBUG
        print("[PlayerVC] Applied state for instance \(instanceId): " +
              "assignments=\(state.mediaAssignments?.count ?? 0), " +
              "present=\(state.userMediaPresent?.count ?? 0), " +
              "variants=\(state.variantOverrides.count), " +
              "transforms=\(state.userTransforms.count), " +
              "toggles=\(state.layerToggles.count)")
        #endif
    }

    /// Applies media assignments from SceneState.
    /// - Parameters:
    ///   - assignments: Media assignments (blockId -> MediaRef)
    ///   - userMediaPresent: Optional overrides for userMediaPresent (for video presentOnReady)
    private func applyMediaAssignments(_ assignments: [String: MediaRef], userMediaPresent: [String: Bool]?) {
        for (blockId, mediaRef) in assignments {
            guard mediaRef.kind == .file else { continue }

            // Resolve URL from relative path
            guard let url = try? ProjectStore.shared.absoluteURL(for: mediaRef) else {
                #if DEBUG
                print("[PlayerVC] Failed to resolve media URL: \(mediaRef.id)")
                #endif
                continue
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                #if DEBUG
                print("[PlayerVC] Media file not found: \(url.path)")
                #endif
                continue
            }

            // Determine media type from extension
            let ext = url.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "heic"].contains(ext) {
                // Photo (sync, override will work in STEP 2)
                if let image = UIImage(contentsOfFile: url.path) {
                    let success = userMediaService?.setPhoto(blockId: blockId, image: image) ?? false
                    #if DEBUG
                    print("[PlayerVC] Applied photo for \(blockId): \(success ? "success" : "failed")")
                    #endif
                }
            } else if ["mov", "mp4", "m4v"].contains(ext) {
                // PR-D: Video support with persistent ownership (file is in ProjectStore)
                // P0-3 fix: Use presentOnReady from userMediaPresent to respect Disable state
                let presentOnReady = userMediaPresent?[blockId] ?? true
                let success = userMediaService?.setVideo(
                    blockId: blockId,
                    url: url,
                    ownership: .persistent,
                    presentOnReady: presentOnReady
                ) ?? false
                #if DEBUG
                print("[PlayerVC] Applied video for \(blockId): presentOnReady=\(presentOnReady), \(success ? "success" : "failed")")
                #endif
            }
        }
    }

    // MARK: - Release v1: Store Callbacks (Split for Performance)

    /// Called when playhead position changes (lightweight, frequent).
    /// Used for scrubbing and playback tick updates.
    /// PR-F: Routes to engine path for timeline mode, coordinator path for sceneEdit mode.
    private func handlePlayheadChanged(_ timeUs: TimeUs) {
        let uiMode = editorStore?.state.uiMode ?? .timeline

        #if DEBUG
        let signpostId = ScrubSignpost.beginHandlePlayheadChanged()
        ScrubCallCounter.shared.recordHandlePlayheadChanged()
        #endif

        switch uiMode {
        case .timeline:
            // PR-F: Use TimelineCompositionEngine for timeline mode
            handleTimelineModePlayheadChanged(timeUs)

        case .sceneEdit:
            // Scene Edit mode: use old coordinator path (single-scene)
            handleSceneEditModePlayheadChanged(timeUs)
        }

        #if DEBUG
        ScrubSignpost.endHandlePlayheadChanged(signpostId, syncPath: uiMode != .timeline)
        #endif
    }

    /// PR-F: Handles playhead changes in timeline mode via TimelineCompositionEngine.
    private func handleTimelineModePlayheadChanged(_ timeUs: TimeUs) {
        // PR-G: Timeline mode is engine-only, no fallback to coordinator path
        guard let engine = timelineCompositionEngine else {
            assertionFailure("handleTimelineModePlayheadChanged requires timelineCompositionEngine")
            return
        }

        // Convert timeUs to compressed frame
        let compressedFrame = engine.compressedFrame(forTimeUs: timeUs)
        currentCompressedFrame = compressedFrame

        // PR-F: Set activeSceneInstanceId SYNCHRONOUSLY for boot invariant.
        activeSceneInstanceId = engine.sceneInstanceId(at: compressedFrame)

        // PR-G: Use shared helper with scrub invalidation
        resolveAndPresentTimelineFrame(timeUs: timeUs, invalidateScrub: true)
    }

    /// PR-G: Refreshes current timeline frame after edits (variant/media/toggle/transform/transition).
    /// Unlike scrub, this doesn't invalidate generation - just re-resolves current position.
    private func refreshCurrentTimelineFrame() {
        let uiMode = editorStore?.state.uiMode ?? .timeline
        guard uiMode == .timeline else { return }
        guard timelineCompositionEngine != nil else { return }

        let timeUs = editorStore?.playheadTimeUs ?? 0
        resolveAndPresentTimelineFrame(timeUs: timeUs, invalidateScrub: false)
    }

    /// PR-G: Shared helper for timeline frame resolution.
    /// Used by both scrub (handleTimelineModePlayheadChanged) and edit refresh (refreshCurrentTimelineFrame).
    /// - Parameters:
    ///   - timeUs: Playhead position in microseconds
    ///   - invalidateScrub: If true, invalidates scrub generation for stale detection (used during scrub)
    private func resolveAndPresentTimelineFrame(timeUs: TimeUs, invalidateScrub: Bool) {
        guard let engine = timelineCompositionEngine else { return }

        let compressedFrame = engine.compressedFrame(forTimeUs: timeUs)

        // Capture generation for stale detection (only if invalidating)
        var generation: UInt64?
        if invalidateScrub {
            engine.invalidateScrub()
            generation = engine.currentScrubGeneration
        }

        // Cancel previous playhead task
        playheadAsyncTask?.cancel()

        playheadAsyncTask = Task { @MainActor in
            // Resolve frame via engine (async - may prepare runtimes)
            guard let resolved = await engine.resolveFrame(compressedFrame, generation: generation) else {
                // Generation mismatch or failed to prepare - skip
                return
            }

            // Check if this task was cancelled
            guard !Task.isCancelled else { return }

            // Cache resolved frame for draw()
            self.cachedTimelineFrame = resolved

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
        }
    }

    /// Handles playhead changes in Scene Edit mode via TimelinePlaybackCoordinator.
    private func handleSceneEditModePlayheadChanged(_ timeUs: TimeUs) {
        guard let coordinator = playbackCoordinator else { return }

        // Try sync path first (same scene, no load needed)
        if let localFrame = coordinator.syncSetGlobalTimeUs(timeUs) {
            // P1 fix: Cancel pending async task since we're back in loaded scene
            playheadAsyncTask?.cancel()
            playheadAsyncTask = nil

            // Same scene - update frame and redraw
            currentFrameIndex = localFrame
            requestMetalRender()

            // P1: Update video frames during timeline scrub (when not playing)
            // DEBUG: DebugSkipScrubVideoUpdates toggle for A/B testing H1
            if !isPlaying, localFrame != lastVideoUpdateFrame {
                #if DEBUG
                if !ScrubDebugToggles.skipScrubVideoUpdates {
                    userMediaService?.updateVideoFramesForScrub(sceneFrameIndex: localFrame)
                }
                #else
                userMediaService?.updateVideoFramesForScrub(sceneFrameIndex: localFrame)
                #endif
                lastVideoUpdateFrame = localFrame
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
                // DEBUG: DebugSkipScrubVideoUpdates toggle for A/B testing H1
                if !self.isPlaying, localFrame != self.lastVideoUpdateFrame {
                    #if DEBUG
                    if !ScrubDebugToggles.skipScrubVideoUpdates {
                        self.userMediaService?.updateVideoFramesForScrub(sceneFrameIndex: localFrame)
                    }
                    #else
                    self.userMediaService?.updateVideoFramesForScrub(sceneFrameIndex: localFrame)
                    #endif
                    self.lastVideoUpdateFrame = localFrame
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
        // Update scene clips UI
        let scenes = state.canonicalTimeline.toSceneDrafts()
        editorLayoutContainer.updateScenes(scenes)

        // Update coordinator timeline (legacy path for Scene Edit)
        playbackCoordinator?.updateSceneTimeline(from: state)

        // PR-F: Update TimelineCompositionEngine for timeline preview path
        timelineCompositionEngine?.setTimeline(
            state.canonicalTimeline,
            sceneStates: state.draft.sceneInstanceStates
        )

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
        print("[PR-F] Scene state changed: instanceId=\(instanceId)")
        #endif
    }

    /// Called during live-trim preview (lightweight, frequent).
    /// Only updates UI, skips playback coordinator and persistence.
    private func handleTimelinePreviewChanged(_ state: EditorState) {
        // Update scene clips UI only
        let scenes = state.canonicalTimeline.toSceneDrafts()
        editorLayoutContainer.updateScenes(scenes)

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
            editorLayoutContainer.setSceneEditMode(false, animated: true)
            editorLayoutContainer.navBar.setMode(.timeline)
            sceneEditController?.updateOverlay()

        case .sceneEdit(let sceneId):
            // Enter Scene Edit: stop playback, collapse timeline
            if isPlaying {
                stopPlayback()
            }
            editorLayoutContainer.setSceneEditMode(true, animated: true)
            editorLayoutContainer.navBar.setMode(.sceneEdit)
            sceneEditController?.updateOverlay()

            // PR-F: Configure bottom bars state
            refreshSceneEditBars()

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
              case .sceneEdit(let instanceId) = editorStore?.state.uiMode else { return }

        // Get block capabilities from ScenePlayer
        let allowedMedia = player.allowedMedia(blockId: blockId)
        let variants = player.availableVariants(blockId: blockId)
        let hasVariants = variants.count > 1

        // Check if block has media assigned
        let sceneState = editorStore?.state.draft.sceneInstanceStates[instanceId]
        let hasMedia = sceneState?.mediaAssignments?[blockId] != nil

        // Check if block is enabled (userMediaPresent)
        let isEnabled = sceneState?.userMediaPresent?[blockId] ?? true

        editorLayoutContainer.configureMediaBlockActionBar(
            blockId: blockId,
            allowedMedia: allowedMedia,
            hasVariants: hasVariants,
            hasMedia: hasMedia,
            isEnabled: isEnabled
        )
    }

    /// Refreshes SceneEditBar and MediaBlockActionBar states.
    /// PR-F: Called after state changes to keep bottom bars in sync.
    private func refreshSceneEditBars() {
        guard case .sceneEdit(let instanceId) = editorStore?.state.uiMode else { return }

        // 1. Update SceneEditBar reset button state
        let sceneState = editorStore?.state.draft.sceneInstanceStates[instanceId]
        let canReset = sceneState != nil && sceneState != .empty
        editorLayoutContainer.configureSceneEditBar(canReset: canReset)

        // 2. Update MediaBlockActionBar if block is selected
        if editorStore?.state.selectedBlockId != nil {
            updateMediaBlockActionBarForSelectedBlock()
        }
    }

    /// Reloads runtime state for the active scene instance.
    /// PR-F: Single sync-point for runtime reload after undo/redo or Reset Scene.
    /// Order: resetForNewInstance -> clearAll -> applySceneInstanceState -> overlay/redraw -> video sync
    private func reloadRuntimeStateForActiveScene() {
        guard let instanceId = activeSceneInstanceId else { return }

        // 1. Reset ScenePlayer mutable state (transforms, variants, toggles, media presence)
        scenePlayer?.resetForNewInstance()

        // 2. Clear UserMediaService to remove stale textures
        userMediaService?.clearAll()

        // 3. Reset video update gate (PR-F: match canonical path)
        lastVideoUpdateFrame = -1

        // 4. Re-apply persisted state from store
        applySceneInstanceState(instanceId: instanceId)

        // 5. Refresh overlay and redraw
        sceneEditController?.updateOverlay()
        metalView.setNeedsDisplay()

        // 6. Force video frame sync for already-ready providers (PR-F)
        syncPausedVideoFrame(force: true)

        #if DEBUG
        log("[PR-F] Runtime state reloaded for instance: \(instanceId)")
        #endif
    }

    /// Syncs video frames to current playhead when paused.
    /// PR-F: Used after runtime reload and when video providers become ready.
    /// - Parameter force: If true, bypasses lastVideoUpdateFrame gate
    private func syncPausedVideoFrame(force: Bool) {
        guard !isPlaying else { return }

        let localFrame = playbackCoordinator?.currentLocalFrame ?? currentFrameIndex

        if force {
            userMediaService?.updateVideoFramesForScrub(sceneFrameIndex: localFrame)
        } else {
            // Respect lastVideoUpdateFrame gate
            guard localFrame != lastVideoUpdateFrame else { return }
            lastVideoUpdateFrame = localFrame
            userMediaService?.updateVideoFramesForScrub(sceneFrameIndex: localFrame)
        }
    }

    /// Handles state restoration after undo/redo.
    /// PR-D: Re-applies runtime state for active scene instance to sync with restored snapshot.
    /// PR-F: Also refreshes bottom bars and syncs TimelineCompositionEngine.
    private func handleStateRestoredFromUndoRedo() {
        reloadRuntimeStateForActiveScene()
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

        // Time Refactor: Save draft as safety net when leaving editor
        if isMovingFromParent || isBeingDismissed {
            saveDraftIfNeeded()
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

    // MARK: - Draft Persistence (Time Refactor)

    /// Saves current project draft if it has unsaved changes.
    /// Called on editor close and viewWillDisappear.
    /// Saves current project draft if it has unsaved changes.
    /// Called on editor close and viewWillDisappear.
    /// PR2: Reads draft from EditorStore (single source of truth).
    private func saveDraftIfNeeded() {
        guard draftIsDirty else { return }

        // PR2: Get draft from store (single source of truth)
        var draft: ProjectDraft
        if let store = editorStore {
            draft = store.currentDraft
        } else if let localDraft = currentProjectDraft {
            // Fallback to local draft if store not initialized
            draft = localDraft
        } else {
            return
        }

        // Update timestamp before save
        draft.updatedAt = Date()

        // Sync local reference
        currentProjectDraft = draft

        do {
            try ProjectStore.shared.saveProjectDraft(draft)
            draftIsDirty = false
            log("[PR2] Draft saved: \(draft.id)")
        } catch {
            log("[PR2] Failed to save draft: \(error.localizedDescription)")
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
        present(nav, animated: true)
    }

    /// Handles background image selection from PHPicker.
    private func handleBackgroundImagePicked(result: PHPickerResult, regionId: String) {
        guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else {
            log("[Background] Selected item is not an image")
            return
        }

        result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            guard let self = self,
                  let image = object as? UIImage else {
                if let error = error {
                    DispatchQueue.main.async {
                        self?.log("[Background] Failed to load image: \(error)")
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self.saveAndSetBackgroundImage(image, for: regionId)
            }
        }
    }

    /// Saves background image to project and updates editor.
    private func saveAndSetBackgroundImage(_ image: UIImage, for regionId: String) {
        guard let service = backgroundTextureService,
              let state = effectiveBackgroundState else {
            log("[Background] Service or state not available")
            return
        }

        // P1-3: Get old mediaRef before replacing (for cleanup after successful inject)
        let oldMediaRef = projectBackgroundOverride?.regions[regionId]?.imageMediaRef

        do {
            // Save image to project store
            let mediaRef = try service.saveImage(image)
            log("[Background] Saved image: \(mediaRef.id)")

            // Load texture
            let slotKey = EffectiveBackgroundBuilder.makeSlotKey(
                presetId: state.preset.presetId,
                regionId: regionId
            )

            Task {
                do {
                    try await service.loadTexture(slotKey: slotKey, mediaRef: mediaRef)

                    // Update editor if visible
                    if let nav = presentedViewController as? UINavigationController,
                       let editor = nav.viewControllers.first as? BackgroundEditorViewController {
                        editor.setImage(for: regionId, mediaRef: mediaRef, image: image)
                    }

                    // P1-3: Delete old file after successful inject
                    if let oldRef = oldMediaRef, oldRef != mediaRef {
                        service.deleteMediaFile(oldRef)
                        log("[Background] Deleted old media file: \(oldRef.id)")
                    }

                    metalView.setNeedsDisplay()
                } catch {
                    log("[Background] Failed to load texture: \(error.localizedDescription)")
                }
            }
        } catch {
            log("[Background] Failed to save image: \(error.localizedDescription)")
        }
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
        guard let renderer = renderer,
              let compiled = compiledScene,
              let player = scenePlayer,
              let mainTextureProvider = textureProvider,
              let resolver = currentResolver else {
            log("[Export] ERROR: Missing dependencies")
            return
        }

        // 2. Create ExportTextureProvider
        let device = renderer.commandQueue.device
        let exportTP = ExportTextureProvider(
            device: device,
            assetIndex: compiled.mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: compiled.bindingAssetIds
        )

        // Preload package assets
        exportTP.preloadAll(commandQueue: renderer.commandQueue)

        // Inject user media textures from main provider
        exportTP.injectTextures(from: mainTextureProvider, for: compiled.bindingAssetIds)

        // 3. Configure VideoExportSettings
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

        // Use .high quality preset
        let bitrate = VideoQualityPreset.high.bitrate(for: (width: Int(canvasSize.width), height: Int(canvasSize.height)))

        // Release audio config: only original audio from video slots
        let audioConfig = AudioExportConfig(
            music: nil,
            voiceover: nil,
            includeOriginalFromVideoSlots: true,
            originalDefaultVolume: 1.0
        )

        let settings = VideoExportSettings(
            outputURL: outputURL,
            sizePx: (width: Int(canvasSize.width), height: Int(canvasSize.height)),
            fps: runtime.fps,
            bitrate: bitrate,
            clearColor: .opaqueBlack,
            audio: audioConfig
        )

        // 4. Present progress modal
        let progressVC = ExportProgressViewController()
        progressVC.modalPresentationStyle = .overFullScreen
        progressVC.modalTransitionStyle = .crossDissolve

        let exporter = VideoExporter()
        videoExporter = exporter
        exportProgressVC = progressVC

        // Fix 2: Track cancellation to ignore late completion callbacks
        var wasCancelled = false

        progressVC.onCancel = { [weak self, weak exporter] in
            wasCancelled = true
            exporter?.cancel()
            // Fix 1: Restore UI state on cancel
            self?.isExporting = false
            self?.videoExporter = nil
            self?.dismiss(animated: true)
        }

        progressVC.onCompleted = { [weak self] url in
            self?.dismiss(animated: true) {
                self?.presentShareSheet(for: url)
            }
        }

        progressVC.onFailed = { [weak self] error in
            self?.dismiss(animated: true) {
                self?.presentExportError(error)
            }
        }

        isExporting = true

        present(progressVC, animated: true) { [weak self] in
            guard let self = self else { return }

            self.log("[Export] Starting export...")
            self.log("[Export] Output: \(outputURL.lastPathComponent)")
            self.log("[Export] Size: \(Int(canvasSize.width))x\(Int(canvasSize.height)) @ \(runtime.fps)fps")
            self.log("[Export] Duration: \(runtime.durationFrames) frames")

            progressVC.updateState(.preparing)

            // PR5: Wrap in Task for async preload
            Task { @MainActor in
                // Preload background textures into export provider
                await self.preloadBackgroundTexturesForExport(provider: exportTP)

                exporter.exportVideo(
                    compiledScene: compiled,
                    scenePlayer: player,
                    renderer: renderer,
                    textureProvider: exportTP,
                    pathRegistry: compiled.pathRegistry,
                    assetSizes: compiled.mergedAssetIndex.sizeById,
                    userMediaService: self.userMediaService,
                    settings: settings,
                    backgroundState: self.effectiveBackgroundState,
                    progress: { progress in
                        // Fix 2: Ignore progress updates after cancel
                        guard !wasCancelled else { return }
                        progressVC.updateState(.rendering(progress: progress))
                    },
                    completion: { [weak self] result in
                        guard let self = self else { return }

                        // Fix 2: Ignore completion after cancel (UI already restored in onCancel)
                        guard !wasCancelled else {
                            self.log("[Export] Completion ignored (was cancelled)")
                            return
                        }

                        self.isExporting = false
                        self.videoExporter = nil

                        switch result {
                        case .success(let url):
                            self.log("[Export] SUCCESS: \(url.lastPathComponent)")
                            progressVC.updateState(.completed(url))

                        case .failure(let error):
                            self.log("[Export] ERROR: \(error.localizedDescription)")
                            progressVC.updateState(.failed(error))
                        }
                    }
                )
            }
        }
    }

    /// Exports multi-scene timeline with transitions.
    /// Uses TimelineCompositionEngine and TransitionCompositor.
    private func startTimelineExport(engine: TimelineCompositionEngine) {
        guard let renderer = renderer,
              let compositor = transitionCompositor else {
            log("[Export] ERROR: Missing renderer or compositor for timeline export")
            return
        }

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

        // Configure export settings
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let uuid8 = UUID().uuidString.prefix(8)
        let filename = "export_timeline_\(timestamp)_\(uuid8).mp4"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        let bitrate = VideoQualityPreset.high.bitrate(for: (width: Int(canvasSize.width), height: Int(canvasSize.height)))

        // Audio config: include original audio from video slots, no music/voiceover
        let audioConfig = AudioExportConfig(
            music: nil,
            voiceover: nil,
            includeOriginalFromVideoSlots: true,
            originalDefaultVolume: 1.0
        )

        let settings = VideoExporter.TimelineExportSettings(
            outputURL: outputURL,
            sizePx: (width: Int(canvasSize.width), height: Int(canvasSize.height)),
            fps: engine.fps,
            bitrate: bitrate,
            audio: audioConfig
        )

        // Present progress modal
        let progressVC = ExportProgressViewController()
        progressVC.modalPresentationStyle = .overFullScreen
        progressVC.modalTransitionStyle = .crossDissolve

        let exporter = VideoExporter()
        videoExporter = exporter
        exportProgressVC = progressVC

        var wasCancelled = false

        progressVC.onCancel = { [weak self, weak exporter] in
            wasCancelled = true
            exporter?.cancel()
            self?.isExporting = false
            self?.videoExporter = nil
            self?.dismiss(animated: true)
        }

        progressVC.onCompleted = { [weak self] url in
            self?.dismiss(animated: true) {
                self?.presentShareSheet(for: url)
            }
        }

        progressVC.onFailed = { [weak self] error in
            self?.dismiss(animated: true) {
                self?.presentExportError(error)
            }
        }

        isExporting = true

        present(progressVC, animated: true) { [weak self] in
            guard let self = self else { return }

            self.log("[Export] Starting timeline export...")
            self.log("[Export] Output: \(outputURL.lastPathComponent)")
            self.log("[Export] Size: \(Int(canvasSize.width))x\(Int(canvasSize.height)) @ \(engine.fps)fps")
            self.log("[Export] Duration: \(transitionMath.compressedDurationFrames) frames")

            progressVC.updateState(.preparing)

            // PR-G: Create thread-safe background provider for export queue
            Task { @MainActor in
                let exportBackgroundProvider = ThreadSafeInMemoryTextureProvider()
                await self.preloadBackgroundTexturesForExport(provider: exportBackgroundProvider)

                exporter.exportTimeline(
                    engine: engine,
                    renderer: renderer,
                    transitionCompositor: compositor,
                    backgroundState: self.effectiveBackgroundState,
                    backgroundTextureProvider: exportBackgroundProvider,
                    settings: settings,
                    progress: { progress in
                        guard !wasCancelled else { return }
                        progressVC.updateState(.rendering(progress: progress))
                    },
                    completion: { [weak self] result in
                        guard let self = self else { return }
                        guard !wasCancelled else {
                            self.log("[Export] Completion ignored (was cancelled)")
                            return
                        }

                        self.isExporting = false
                        self.videoExporter = nil

                        switch result {
                        case .success(let url):
                            self.log("[Export] SUCCESS: \(url.lastPathComponent)")
                            progressVC.updateState(.completed(url))

                        case .failure(let error):
                            self.log("[Export] ERROR: \(error.localizedDescription)")
                            progressVC.updateState(.failed(error))
                        }
                    }
                )
            }
        }
    }

    private func presentShareSheet(for url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activityVC.popoverPresentationController?.sourceView = view
        present(activityVC, animated: true)
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

    @objc private func metalViewTapped(_ recognizer: UITapGestureRecognizer) {
        // PR-E: Block selection via tap is now handled by Scene Edit mode
        // This handler is legacy dev-UI path - no-op in production
    }

    // PR-D: Tap handler for Scene Edit mode (on overlayView)
    @objc private func overlayViewTapped(_ recognizer: UITapGestureRecognizer) {
        guard case .sceneEdit = editorStore?.state.uiMode else { return }
        let point = recognizer.location(in: overlayView)
        sceneEditController?.handleTap(viewPoint: point)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        // PR-E: Only works in Scene Edit mode (dev-UI path removed)
        guard case .sceneEdit = editorStore?.state.uiMode else { return }
        sceneEditController?.handlePan(recognizer)
        persistTransformIfNeededSceneEdit(recognizer)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        // PR-E: Only works in Scene Edit mode (dev-UI path removed)
        guard case .sceneEdit = editorStore?.state.uiMode else { return }
        sceneEditController?.handlePinch(recognizer)
        persistTransformIfNeededSceneEdit(recognizer)
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        // PR-E: Only works in Scene Edit mode (dev-UI path removed)
        guard case .sceneEdit = editorStore?.state.uiMode else { return }
        sceneEditController?.handleRotation(recognizer)
        persistTransformIfNeededSceneEdit(recognizer)
    }

    /// PR9.1: Persists current transform to store for undo/redo and save/load.
    private func persistTransformIfNeeded(_ recognizer: UIGestureRecognizer) {
        guard let instanceId = activeSceneInstanceId,
              let blockId = editorStore?.state.selectedBlockId,
              let player = scenePlayer else { return }

        let phase: InteractionPhase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: return
        }

        let transform = player.userTransform(blockId: blockId)

        editorStore?.dispatch(.setBlockTransform(
            sceneInstanceId: instanceId,
            blockId: blockId,
            transform: transform,
            phase: phase
        ))

        // On cancel, Store restores baseline but runtime still has "last" value.
        // Apply restored baseline transform back to runtime.
        // Use .identity as fallback when baseline has no saved transform.
        if phase == .cancelled {
            let restored = editorStore?.state.draft.sceneInstanceStates[instanceId]?.userTransforms[blockId] ?? .identity
            player.setUserTransform(blockId: blockId, transform: restored)
            metalView.setNeedsDisplay()
        }
    }

    /// PR-D: Persists transform from Scene Edit mode gestures.
    private func persistTransformIfNeededSceneEdit(_ recognizer: UIGestureRecognizer) {
        guard let instanceId = activeSceneInstanceId,
              let blockId = editorStore?.state.selectedBlockId,
              let player = scenePlayer else { return }

        let phase: InteractionPhase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: return
        }

        let transform = player.userTransform(blockId: blockId)

        editorStore?.dispatch(.setBlockTransform(
            sceneInstanceId: instanceId,
            blockId: blockId,
            transform: transform,
            phase: phase
        ))

        // On cancel, restore baseline transform
        if phase == .cancelled {
            let restored = editorStore?.state.draft.sceneInstanceStates[instanceId]?.userTransforms[blockId] ?? .identity
            player.setUserTransform(blockId: blockId, transform: restored)
            metalView.setNeedsDisplay()
        }
    }

    // MARK: - User Media Actions (PR-32)

    @objc private func addPhotoTapped() {
        guard editorStore?.state.selectedBlockId != nil else { return }
        presentPhotoPicker(for: .images)
    }

    @objc private func clearMediaTapped() {
        guard let blockId = editorStore?.state.selectedBlockId else { return }

        // PR9: Clear from runtime service
        userMediaService?.clear(blockId: blockId)

        // PR9: Clear from store (persistent)
        if let instanceId = activeSceneInstanceId {
            editorStore?.dispatch(.setBlockMedia(
                sceneInstanceId: instanceId,
                blockId: blockId,
                media: nil
            ))
        }

        metalView.setNeedsDisplay()
        log("[UserMedia] Cleared media for block '\(blockId)'")
    }

    /// PR9: Handles user media image picked from PHPicker.
    /// Saves to persistent storage and dispatches to store.
    private func handleUserMediaImagePicked(blockId: String, image: UIImage) {
        // Step 1: Apply to runtime (for immediate preview)
        let runtimeSuccess = userMediaService?.setPhoto(blockId: blockId, image: image) ?? false

        if !runtimeSuccess {
            log("[UserMedia] Failed to set photo for block '\(blockId)'")
            metalView.setNeedsDisplay()
            return
        }

        log("[UserMedia] Photo set for block '\(blockId)'")

        // Step 2: Save to persistent storage and dispatch to store
        guard let instanceId = activeSceneInstanceId else {
            log("[UserMedia] No active scene instance, skipping persistence")
            metalView.setNeedsDisplay()
            return
        }

        // Resize and save to disk
        let maxDimension: CGFloat = 2048
        let resizedImage = resizeImageIfNeeded(image, maxDimension: maxDimension)

        guard let jpegData = resizedImage.jpegData(compressionQuality: 0.9) else {
            log("[UserMedia] Failed to create JPEG data for block '\(blockId)'")
            metalView.setNeedsDisplay()
            return
        }

        do {
            let mediaRef = try ProjectStore.shared.saveUserMedia(
                jpegData,
                sceneInstanceId: instanceId,
                blockId: blockId
            )

            // Dispatch to store for persistence
            editorStore?.dispatch(.setBlockMedia(
                sceneInstanceId: instanceId,
                blockId: blockId,
                media: mediaRef
            ))

            log("[UserMedia] Saved media: \(mediaRef.id)")
        } catch {
            log("[UserMedia] Failed to save media: \(error)")
        }

        metalView.setNeedsDisplay()
    }

    /// PR-D: Handles video picked from PHPicker with full persistence flow.
    /// - Parameters:
    ///   - blockId: Target block ID
    ///   - tempURL: Temporary URL of copied video file (will be deleted after processing)
    private func handleUserMediaVideoPicked(blockId: String, tempURL: URL) {
        // Step 1: Get active scene instance for persistence
        guard let instanceId = activeSceneInstanceId else {
            log("[UserMedia] No active scene instance, skipping video persistence")
            try? FileManager.default.removeItem(at: tempURL)
            metalView.setNeedsDisplay()
            return
        }

        // Step 2: Save video to persistent storage
        let mediaRef: MediaRef
        let persistedURL: URL
        do {
            mediaRef = try ProjectStore.shared.saveUserVideo(
                from: tempURL,
                sceneInstanceId: instanceId,
                blockId: blockId
            )
            persistedURL = try ProjectStore.shared.absoluteURL(for: mediaRef)
        } catch {
            log("[UserMedia] Failed to save video: \(error)")
            try? FileManager.default.removeItem(at: tempURL)
            metalView.setNeedsDisplay()
            return
        }

        // Step 3: Apply to runtime with persistent ownership
        let runtimeSuccess = userMediaService?.setVideo(
            blockId: blockId,
            url: persistedURL,
            ownership: .persistent
        ) ?? false

        if !runtimeSuccess {
            log("[UserMedia] Failed to set video for block '\(blockId)'")
            try? FileManager.default.removeItem(at: tempURL)
            metalView.setNeedsDisplay()
            return
        }

        // Step 4: Dispatch to store for persistence
        editorStore?.dispatch(.setBlockMedia(
            sceneInstanceId: instanceId,
            blockId: blockId,
            media: mediaRef
        ))

        log("[UserMedia] Video saved and set for block '\(blockId)': \(mediaRef.id)")

        // Step 5: Cleanup temp file (already copied to persistent storage)
        try? FileManager.default.removeItem(at: tempURL)

        metalView.setNeedsDisplay()
    }

    /// Resizes image if larger than maxDimension while preserving aspect ratio.
    private func resizeImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else {
            return image
        }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxDimension / size.width
        } else {
            scale = maxDimension / size.height
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
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
        // Store pending state for picker delegate
        pendingPickedMediaBlockId = blockId
        pendingMediaKind = kind

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
        guard let instanceId = activeSceneInstanceId else { return }
        editorStore?.dispatch(.setBlockVariant(
            sceneInstanceId: instanceId,
            blockId: blockId,
            variantId: variantId
        ))
    }

    // MARK: - PR9: Scene Catalog

    /// Presents the scene catalog for adding a new scene.
    private func presentSceneCatalog() {
        guard let library = sceneLibrarySnapshot else {
            log("[PR9] presentSceneCatalog: sceneLibrarySnapshot is nil")
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
            log("[PR9] handleAddScene: editorStore is nil")
            return
        }

        // Dispatch addScene action to store
        store.dispatch(.addScene(sceneTypeId: sceneTypeId, durationUs: baseDurationUs))
        log("[PR9] Added scene: \(sceneTypeId) duration=\(baseDurationUs)us")
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

    /// Loads a pre-compiled template from the app bundle.
    /// PR-D: Async pipeline — file IO and texture preload on background, UI never blocks.
    private func loadCompiledTemplateFromBundle(templateName: String) {
        stopPlayback()
        renderErrorLogged = false
        currentTemplateId = templateName  // PR3: Store for ProjectStore
        log("---\nLoading compiled template '\(templateName)'...")

        guard let device = metalView.device else {
            log("ERROR: No Metal device")
            loadingState = .failed(message: "No Metal device")
            updateLoadingStateUI()
            return
        }

        // Find template folder in bundle
        guard let templateURL = Bundle.main.url(forResource: templateName, withExtension: nil, subdirectory: "Templates") else {
            log("ERROR: Template '\(templateName)' not found in bundle")
            loadingState = .failed(message: "Template not found")
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
            // File IO + JSON decode + asset index creation
            // PR-D.1: Use child Task (not detached) so cancellation propagates
            do {
                let result: BackgroundLoadResult = try await Task(priority: .userInitiated) {
                    // Check cancellation before starting
                    try Task.checkCancellation()

                    // Load .tve file (IO)
                    let compiledLoader = CompiledScenePackageLoader(engineVersion: TVECore.version)
                    let compiledPackage = try compiledLoader.load(from: templateURL)

                    // Check cancellation after file load
                    try Task.checkCancellation()

                    // Create asset indices (may scan directories)
                    let localIndex = try LocalAssetsIndex(imagesRootURL: templateURL.appendingPathComponent("images"))
                    let sharedIndex = try SharedAssetsIndex(bundle: Bundle.main, rootFolderName: "SharedAssets")
                    let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)

                    return BackgroundLoadResult(
                        compiledPackage: compiledPackage,
                        resolver: resolver
                    )
                }.value

                // Check if this request is still current
                guard !Task.isCancelled, self.currentRequestId == requestId else {
                    await MainActor.run { self.log("Load cancelled (new template selected)") }
                    return
                }

                // === PHASE 2: Main Actor — ScenePlayer setup ===
                await MainActor.run {
                    self.log("Compiled package loaded: \(result.compiledPackage.sceneId ?? "unknown")")
                    self.preparingOverlay.setStatus("Preparing scene...")
                }

                let sceneSetupResult: SceneSetupResult = await MainActor.run {
                    let player = ScenePlayer()
                    let compiled = player.loadCompiledScene(result.compiledPackage.compiled)
                    return SceneSetupResult(player: player, compiled: compiled)
                }

                // Check cancellation
                guard !Task.isCancelled, self.currentRequestId == requestId else { return }

                // === PHASE 3: Background — Texture preload ===
                await MainActor.run {
                    self.preparingOverlay.setStatus("Loading textures...")
                }

                // Capture commandQueue on main before background preload
                let (provider, queue): (ScenePackageTextureProvider, MTLCommandQueue?) = await MainActor.run {
                    let p = SceneTextureProviderFactory.create(
                        device: device,
                        mergedAssetIndex: sceneSetupResult.compiled.mergedAssetIndex,
                        resolver: result.resolver,
                        bindingAssetIds: sceneSetupResult.compiled.bindingAssetIds,
                        logger: { [weak self] msg in
                            Task { @MainActor in self?.log(msg) }
                        }
                    )
                    return (p, self.commandQueue)
                }

                // Preload on background (PR-D: safe because draw not running)
                // PR-D.1: Use child Task so cancellation propagates
                // Alpha Fix: Use commandQueue for premultiplied alpha texture loading
                try await Task(priority: .userInitiated) {
                    try Task.checkCancellation()
                    if let q = queue {
                        provider.preloadAll(commandQueue: q)
                    }
                }.value

                // Check cancellation after preload
                guard !Task.isCancelled, self.currentRequestId == requestId else { return }

                // === PHASE 4: Main Actor — Finalize and go ready ===
                await MainActor.run {
                    self.applyLoadedTemplate(
                        player: sceneSetupResult.player,
                        compiled: sceneSetupResult.compiled,
                        provider: provider,
                        resolver: result.resolver,
                        requestId: requestId
                    )
                }

            } catch is CancellationError {
                await MainActor.run { self.log("Load cancelled") }
            } catch {
                // Check if still current request before showing error
                guard self.currentRequestId == requestId else { return }
                await MainActor.run {
                    self.log("ERROR: Failed to load compiled template: \(error)")
                    self.loadingState = .failed(message: "Failed to load template")
                    self.updateLoadingStateUI()
                }
            }
        }
    }

    // MARK: - Release v1: Scene Type Loading

    /// Loads a scene type from the SceneLibrary.
    /// Release v1: Replaces loadCompiledTemplateFromBundle for editor mode.
    /// Uses sceneLibrarySnapshot.folderURL instead of Templates/<name>.
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
                let result: BackgroundLoadResult = try await Task(priority: .userInitiated) {
                    try Task.checkCancellation()

                    // Load .tve file from SceneLibrary folder
                    let compiledLoader = CompiledScenePackageLoader(engineVersion: TVECore.version)
                    let compiledPackage = try compiledLoader.load(from: sceneURL)

                    try Task.checkCancellation()

                    // Create asset indices
                    let localIndex = try LocalAssetsIndex(imagesRootURL: sceneURL.appendingPathComponent("images"))
                    let sharedIndex = try SharedAssetsIndex(bundle: Bundle.main, rootFolderName: "SharedAssets")
                    let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)

                    return BackgroundLoadResult(
                        compiledPackage: compiledPackage,
                        resolver: resolver
                    )
                }.value

                guard !Task.isCancelled, self.currentRequestId == requestId else {
                    await MainActor.run { self.log("Scene load cancelled") }
                    return
                }

                // === PHASE 2: Main Actor — ScenePlayer setup ===
                await MainActor.run {
                    self.log("Scene package loaded: \(result.compiledPackage.sceneId ?? sceneTypeId)")
                    self.preparingOverlay.setStatus("Preparing scene...")
                }

                let sceneSetupResult: SceneSetupResult = await MainActor.run {
                    let player = ScenePlayer()
                    let compiled = player.loadCompiledScene(result.compiledPackage.compiled)
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
                        resolver: result.resolver,
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
                        resolver: result.resolver,
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
                self?.syncPausedVideoFrame(force: true)
            }
            log("UserMediaService initialized")
        }

        // Setup background state
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

    /// PR-D: Applies loaded template to UI (must be called on main).
    private func applyLoadedTemplate(
        player: ScenePlayer,
        compiled: CompiledScene,
        provider: ScenePackageTextureProvider,
        resolver: CompositeAssetResolver,
        requestId: UUID
    ) {
        // Final cancellation check
        guard currentRequestId == requestId else {
            log("Load result discarded (new template selected)")
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
                self?.syncPausedVideoFrame(force: true)
            }
            log("UserMediaService initialized")
        }

        // PR3: Setup background state
        setupBackgroundState(compiled: compiled)

        // Log results
        let runtime = compiled.runtime
        let canvasSizeStr = "\(Int(canvasSize.width))x\(Int(canvasSize.height))"
        log("Template loaded: \(canvasSizeStr) @ \(runtime.fps)fps, \(runtime.durationFrames) frames, \(runtime.blocks.count) blocks")

        // Setup playback controls
        totalFrames = runtime.durationFrames
        sceneFPS = Double(runtime.fps)
        currentFrameIndex = 0

        // Enter ready state
        loadingState = .ready
        updateLoadingStateUI()

        // PR-E: Configure timeline for editor mode
        configureEditorTimeline()

        log("Ready for playback!")
        metalView.setNeedsDisplay()
    }

    // MARK: - Background Setup (PR3)

    /// Sets up background state from template and project override.
    private func setupBackgroundState(compiled: CompiledScene) {
        guard let templateId = currentTemplateId,
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

        // Load or create project
        do {
            currentProjectId = try ProjectStore.shared.createOrLoadProjectId(for: templateId)
            if let projectId = currentProjectId {
                projectBackgroundOverride = try ProjectStore.shared.loadBackgroundOverride(projectId: projectId, templateId: templateId)
            }
        } catch {
            log("[Background] ProjectStore error: \(error.localizedDescription)")
            currentProjectId = nil
            projectBackgroundOverride = nil
        }

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

    /// Preloads background image textures into the export texture provider.
    /// PR5: Called before export to ensure background images are available.
    @MainActor
    private func preloadBackgroundTexturesForExport(
        provider: MutableTextureProvider
    ) async {
        guard let override = projectBackgroundOverride,
              let state = effectiveBackgroundState,
              let queue = commandQueue else { return }

        let presetId = state.preset.presetId
        let device = queue.device
        let service = BackgroundTextureService(
            textureProvider: provider,
            device: device,
            commandQueue: queue
        )

        for (regionId, regionOverride) in override.regions {
            guard let mediaRef = regionOverride.imageMediaRef else { continue }
            let slotKey = EffectiveBackgroundBuilder.makeSlotKey(
                presetId: presetId,
                regionId: regionId
            )
            // missing file → log+return (PR4), so try? is acceptable
            try? await service.loadTexture(slotKey: slotKey, mediaRef: mediaRef)
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

        let compressedFrame = engine.compressedFrame(forTimeUs: editorStore?.playheadTimeUs ?? 0)
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
        // PR-E: Calculate next time and dispatch through store
        guard let store = editorStore else { return }

        let fps = store.state.templateFPS
        let frameDurationUs: TimeUs = 1_000_000 / TimeUs(fps)
        let currentTimeUs = store.playheadTimeUs
        let nextTimeUs = min(currentTimeUs + frameDurationUs, store.projectDurationUs)

        // Dispatch to store - onPlayheadChanged callback handles coordinator + redraw
        store.dispatch(.setPlayhead(timeUs: nextTimeUs, quantize: .playback))

        // Global frame for UI (timeline ruler, fullscreen position)
        let globalFrameIndex = Int(nextTimeUs * TimeUs(fps) / 1_000_000)

        // PR-E: Update timeline/fullscreen position during playback
        editorLayoutContainer.setCurrentTimeUs(nextTimeUs)
        fullScreenPreviewVC?.setCurrentFrame(globalFrameIndex)

        // PR-F: Video sync via engine in timeline mode, legacy path in sceneEdit mode
        let uiMode = store.state.uiMode
        switch uiMode {
        case .timeline:
            // Use engine-driven video sync (routes to per-instance UserMediaService)
            let compressedFrame = timelineCompositionEngine?.compressedFrame(forTimeUs: nextTimeUs) ?? 0
            timelineCompositionEngine?.syncPlaybackTick(compressedFrame)

        case .sceneEdit:
            // Legacy path - use coordinator's local frame
            let localFrame = playbackCoordinator?.currentLocalFrame ?? globalFrameIndex
            if let service = userMediaService,
               !service.blockIdsWithVideo.isEmpty,
               localFrame != lastVideoUpdateFrame {
                service.updateVideoFramesForPlayback(sceneFrameIndex: localFrame)
                lastVideoUpdateFrame = localFrame
            }
        }

        // Auto-stop at end
        if nextTimeUs >= store.projectDurationUs {
            stopPlayback()
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let ts = DateFormatter.logFormatter.string(from: Date())
        print("[\(ts)] \(message)")
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

    /// PR-G: Renders single scene in timeline mode using split-pass architecture.
    /// Pass 1: Background pre-pass with backgroundTextureProvider
    /// Pass 2: Scene pass with scene provider (preserves background via initialLoadAction: .load)
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

        guard let drawable = view.currentDrawable,
              let cmdBuf = cmdQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        cmdBuf.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        #if DEBUG
        perfLogger.recordFrame()
        #endif

        let target = RenderTarget(
            texture: drawable.texture,
            drawableScale: Double(view.contentScaleFactor),
            animSize: ctx.canvasSize
        )

        do {
            // PR-G: Pass 1 - Background pre-pass (always prepare target)
            let bgProvider: TextureProvider = backgroundTextureProvider ?? InMemoryTextureProvider()
            if let bg = effectiveBackgroundState {
                try renderer.draw(
                    commands: [],
                    target: target,
                    textureProvider: bgProvider,
                    commandBuffer: cmdBuf,
                    assetSizes: [:],
                    pathRegistry: PathRegistry(),
                    backgroundState: bg,
                    initialLoadAction: .clear
                )
            } else {
                // Clear target even without background
                try renderer.draw(
                    commands: [],
                    target: target,
                    textureProvider: bgProvider,
                    commandBuffer: cmdBuf,
                    assetSizes: [:],
                    pathRegistry: PathRegistry(),
                    backgroundState: nil,
                    initialLoadAction: .clear
                )
            }

            // PR-G: Pass 2 - Scene pass (preserves background)
            try renderer.draw(
                commands: ctx.commands,
                target: target,
                textureProvider: ctx.textureProvider,
                commandBuffer: cmdBuf,
                assetSizes: ctx.assetSizes,
                pathRegistry: ctx.pathRegistry,
                backgroundState: nil,  // Already rendered in pass 1
                initialLoadAction: .load  // Preserve background
            )
        } catch {
            if !renderErrorLogged {
                renderErrorLogged = true
                log("Render error: \(error)")
            }
        }

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// PR-F: Renders transition between two scenes using TexturePool and single commandBuffer.
    /// Contract: Offscreen scenes rendered with backgroundState=nil, background drawn once to final target.
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

        guard let drawable = view.currentDrawable,
              let cmdBuf = cmdQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        cmdBuf.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        #if DEBUG
        perfLogger.recordFrame()
        #endif

        // Calculate texture size for offscreen render
        let scale = view.contentScaleFactor
        let texWidth = Int(transCtx.sceneA.canvasSize.width * scale)
        let texHeight = Int(transCtx.sceneA.canvasSize.height * scale)
        let sizePx = (width: texWidth, height: texHeight)

        // Acquire offscreen textures from pool (non-blocking)
        let texturePool = renderer.texturePool
        guard let textureA = texturePool.acquireColorTexture(size: sizePx),
              let textureB = texturePool.acquireColorTexture(size: sizePx) else {
            inFlightSemaphore.signal()
            if !renderErrorLogged {
                renderErrorLogged = true
                log("[PR-F] Failed to acquire offscreen textures from pool")
            }
            return
        }

        defer {
            texturePool.release(textureA)
            texturePool.release(textureB)
        }

        do {
            // Render scene A to offscreen texture (transparent, no background)
            let targetA = RenderTarget(
                texture: textureA,
                drawableScale: 1.0,
                animSize: transCtx.sceneA.canvasSize
            )
            try renderer.draw(
                commands: transCtx.sceneA.commands,
                target: targetA,
                clearColor: .transparentBlack,
                textureProvider: transCtx.sceneA.textureProvider,
                commandBuffer: cmdBuf,
                assetSizes: transCtx.sceneA.assetSizes,
                pathRegistry: transCtx.sceneA.pathRegistry,
                backgroundState: nil  // No background for offscreen scenes
            )

            // Render scene B to offscreen texture (transparent, no background)
            let targetB = RenderTarget(
                texture: textureB,
                drawableScale: 1.0,
                animSize: transCtx.sceneB.canvasSize
            )
            try renderer.draw(
                commands: transCtx.sceneB.commands,
                target: targetB,
                clearColor: .transparentBlack,
                textureProvider: transCtx.sceneB.textureProvider,
                commandBuffer: cmdBuf,
                assetSizes: transCtx.sceneB.assetSizes,
                pathRegistry: transCtx.sceneB.pathRegistry,
                backgroundState: nil
            )

            // Prepare final target (drawable) with background
            let finalTarget = RenderTarget(
                texture: drawable.texture,
                drawableScale: Double(view.contentScaleFactor),
                animSize: transCtx.sceneA.canvasSize
            )

            // PR-G: Render background to final target using shared backgroundTextureProvider
            // Background pre-pass doesn't need scene assets - only background texture slots
            let bgProvider: TextureProvider = backgroundTextureProvider ?? InMemoryTextureProvider()
            if let bg = effectiveBackgroundState {
                try renderer.draw(
                    commands: [],
                    target: finalTarget,
                    clearColor: .transparentBlack,
                    textureProvider: bgProvider,
                    commandBuffer: cmdBuf,
                    assetSizes: [:],
                    pathRegistry: PathRegistry(),
                    backgroundState: bg,
                    initialLoadAction: .clear
                )
            } else {
                // PR-G: Clear target even without background to avoid stale pixels
                try renderer.draw(
                    commands: [],
                    target: finalTarget,
                    clearColor: .transparentBlack,
                    textureProvider: bgProvider,
                    commandBuffer: cmdBuf,
                    assetSizes: [:],
                    pathRegistry: PathRegistry(),
                    backgroundState: nil,
                    initialLoadAction: .clear
                )
            }

            // Convert SceneTransition to TransitionParams
            let transitionParams = TransitionParams(
                type: transCtx.transition.type.toTVECoreType(),
                easing: transCtx.transition.easing.toTVECoreType()
            )

            // Composite A + B to drawable (loadAction: .load preserves background)
            try compositor.composite(
                sceneA: textureA,
                sceneB: textureB,
                transition: transitionParams,
                progress: transCtx.progress,
                canvasSize: transCtx.sceneA.canvasSize,
                target: drawable.texture,
                commandBuffer: cmdBuf
            )
        } catch {
            if !renderErrorLogged {
                renderErrorLogged = true
                log("[PR-F] Transition render error: \(error)")
            }
        }

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// PR-F: Renders Scene Edit mode using EditorRenderCommandResolver (legacy path).
    private func drawSceneEditMode(in view: MTKView) {
        let coordinator = playbackCoordinator
        let player = scenePlayer
        let frameIndex = currentFrameIndex

        guard let resolved = EditorRenderCommandResolver.resolve(
            uiMode: .sceneEdit(sceneInstanceId: activeSceneInstanceId ?? UUID()),
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
            pendingPickedMediaBlockId = nil
            pendingMediaKind = nil
            return
        }

        // PR3: Check if this is a background image picker
        if picker.view.tag == 999, let regionId = pendingBackgroundRegionId {
            pendingBackgroundRegionId = nil
            handleBackgroundImagePicked(result: result, regionId: regionId)
            return
        }

        // PR-E: Use pending blockId for deterministic tracking
        // Fall back to state.selectedBlockId for backward compatibility with dev-UI
        let blockId: String
        let expectedKind: MediaKind?

        if let pendingBlockId = pendingPickedMediaBlockId {
            blockId = pendingBlockId
            expectedKind = pendingMediaKind
            // Clear pending state
            pendingPickedMediaBlockId = nil
            pendingMediaKind = nil
        } else if let stateBlockId = editorStore?.state.selectedBlockId {
            // Backward compatibility with dev-UI path
            blockId = stateBlockId
            expectedKind = nil
        } else {
            return
        }

        // Determine actual type of picked media
        let isImage = result.itemProvider.canLoadObject(ofClass: UIImage.self)
        let isVideo = result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)

        // PR-E: Validate against expected kind (if set)
        if let expected = expectedKind {
            switch expected {
            case .photo where !isImage:
                showMediaTypeMismatchAlert()
                return
            case .video where !isVideo:
                showMediaTypeMismatchAlert()
                return
            default:
                break
            }
        }

        // Process based on actual type
        if isImage {
            // Load image
            result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                guard let self = self,
                      let image = object as? UIImage else {
                    if let error = error {
                        DispatchQueue.main.async {
                            self?.log("[UserMedia] Failed to load image: \(error)")
                        }
                    }
                    return
                }

                DispatchQueue.main.async {
                    // PR9: Save image to persistent storage and dispatch to store
                    self.handleUserMediaImagePicked(blockId: blockId, image: image)
                }
            }
        } else if isVideo {
            // Load video
            result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
                guard let self = self,
                      let sourceURL = url else {
                    if let error = error {
                        DispatchQueue.main.async {
                            self?.log("[UserMedia] Failed to load video: \(error)")
                        }
                    }
                    return
                }

                // PHPicker API: sourceURL is only valid inside this callback!
                // Must copy BEFORE async dispatch, then pass copied URL to service
                let tempDir = FileManager.default.temporaryDirectory
                let tempURL = tempDir.appendingPathComponent("\(blockId)_\(UUID().uuidString).mov")

                do {
                    try FileManager.default.copyItem(at: sourceURL, to: tempURL)
                } catch {
                    DispatchQueue.main.async {
                        self.log("[UserMedia] Failed to copy video: \(error)")
                    }
                    return
                }

                DispatchQueue.main.async {
                    // PR-D: Use full persistence flow
                    self.handleUserMediaVideoPicked(blockId: blockId, tempURL: tempURL)
                }
            }
        }
    }

    /// Shows alert when picked media type doesn't match expected type (PR-E).
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
        // Store regionId for callback
        pendingBackgroundRegionId = regionId

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
        // Save to ProjectStore
        guard let projectId = currentProjectId,
              let templateId = currentTemplateId else { return }

        do {
            try ProjectStore.shared.saveBackgroundOverride(projectId: projectId, templateId: templateId, override: override)
            log("[Background] Saved override for project \(projectId), template \(templateId)")
        } catch {
            log("[Background] Failed to save: \(error.localizedDescription)")
        }

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
