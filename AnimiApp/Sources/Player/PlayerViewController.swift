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

// MARK: - Player Presentation Mode (PR-Templates)

/// Defines how PlayerViewController is presented and what UI is shown.
enum PlayerPresentationMode {
    /// Development mode - full debug UI (default when no mode specified)
    case dev
    /// Editor mode from Templates catalog - hides dev UI, auto-loads template
    case editor(templateId: String)
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

/// Main player view controller with Metal rendering surface and debug log.
/// Supports full scene playback with multiple media blocks.
final class PlayerViewController: UIViewController {

    // MARK: - Presentation Mode (PR-Templates)

    /// Current presentation mode (dev vs editor from catalog)
    private var presentationMode: PlayerPresentationMode = .dev

    // MARK: - Initializers

    /// Initializer with specific presentation mode
    init(mode: PlayerPresentationMode) {
        self.presentationMode = mode
        super.init(nibName: nil, bundle: nil)
    }

    /// Default initializer for dev mode
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        self.presentationMode = .dev
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        self.presentationMode = .dev
        super.init(coder: coder)
    }

    // MARK: - UI Components

    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsVerticalScrollIndicator = true
        sv.showsHorizontalScrollIndicator = false
        sv.alwaysBounceVertical = true
        return sv
    }()

    private lazy var contentView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// Available templates for selection
    private let availableTemplates: [(name: String, displayName: String)] = [
        ("example_4blocks", "4 Blocks"),
        ("polaroid_shared_demo", "Polaroid"),
        ("polaroid_2", "Polaroid 2")
    ]

    /// Template selector (available in both Debug and Release)
    private lazy var templateSelector: UISegmentedControl = {
        let items = availableTemplates.map(\.displayName)
        let control = UISegmentedControl(items: items)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = 0
        control.addTarget(self, action: #selector(templateSelectorChanged), for: .valueChanged)
        return control
    }()

    // MARK: - Export UI (Release)

    private lazy var exportButton: UIButton = {
        makeButton(title: "Export", color: .systemTeal, action: #selector(exportTapped))
    }()

    // PR3: Background Editor button
    private lazy var backgroundButton: UIButton = {
        makeButton(title: "Background", color: .systemIndigo, action: #selector(backgroundTapped))
    }()

    private var isExporting = false
    private var videoExporter: VideoExporter?
    private var exportProgressVC: ExportProgressViewController?

    #if DEBUG
    private lazy var sceneSelector: UISegmentedControl = {
        let control = UISegmentedControl(items: ["4 Blocks", "Alpha Matte", "Variant Demo", "Shared Decor"])
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = 0
        return control
    }()

    private lazy var loadButton: UIButton = {
        makeButton(title: "Load Scene", action: #selector(loadTestPackageTapped))
    }()

    private lazy var smokeTestButton: UIButton = {
        makeButton(title: "Run Export Smoke Tests", color: .systemOrange, action: #selector(smokeTestTapped))
    }()

    private lazy var smokeTestStatusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textAlignment = .center
        label.textColor = .systemOrange
        label.numberOfLines = 0
        label.text = ""
        label.isHidden = true
        return label
    }()

    private var isSmokeTestRunning = false

    /// Result status for smoke tests (pass/fail/skip)
    private enum SmokeTestResult {
        case pass
        case fail
        case skip
    }
    private var smokeTestResults: [(name: String, result: SmokeTestResult)] = []

    // Export audio configuration (DEBUG toggles)
    private var exportIncludeOriginalAudio = true
    private var exportIncludeMusic = false
    private var exportIncludeVoiceover = false

    /// Returns test music URL from bundle (ExportTestAssets/music.m4a)
    private var testMusicURL: URL? {
        Bundle.main.url(forResource: "music", withExtension: "m4a", subdirectory: "ExportTestAssets")
    }

    /// Returns test voiceover URL from bundle (ExportTestAssets/voiceover.m4a)
    private var testVoiceoverURL: URL? {
        Bundle.main.url(forResource: "voiceover", withExtension: "m4a", subdirectory: "ExportTestAssets")
    }
    #endif

    private lazy var playPauseButton: UIButton = {
        let btn = makeButton(title: "Play", color: .systemGreen, action: #selector(playPauseTapped))
        btn.isEnabled = false
        return btn
    }()

    private lazy var frameSlider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(frameSliderChanged), for: .valueChanged)
        slider.isEnabled = false
        return slider
    }()

    private lazy var frameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.text = "Frame: 0 / 0"
        return label
    }()

    private lazy var controlsStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [playPauseButton, frameSlider])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        return stack
    }()

    private lazy var logTextView: UITextView = {
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        return textView
    }()

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

    private func makeButton(title: String, color: UIColor = .systemBlue, action: Selector) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .medium
        config.baseBackgroundColor = color
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    // MARK: - Variant Switching UI (PR-20)

    /// Per-block variant picker — visible in Edit mode when a block is selected.
    private lazy var variantPicker: UISegmentedControl = {
        let control = UISegmentedControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addTarget(self, action: #selector(variantPickerChanged), for: .valueChanged)
        return control
    }()

    /// Label shown above variant picker to indicate which block is selected.
    private lazy var variantLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.text = ""
        return label
    }()

    /// Scene preset picker — always visible when scene is loaded.
    private lazy var presetPicker: UISegmentedControl = {
        let control = UISegmentedControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addTarget(self, action: #selector(presetPickerChanged), for: .valueChanged)
        control.isHidden = true
        return control
    }()

    /// Current presets for the loaded scene. Empty for scenes without variant data.
    private var scenePresets: [SceneVariantPreset] = []

    /// Cached variant IDs for the current picker — avoids reading titles from UIKit (lead fix #2).
    private var lastVariantIds: [String] = []

    // MARK: - Layer Toggle UI (PR-30)

    /// Label for toggle section.
    private lazy var toggleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.text = "Layer Toggles"
        return label
    }()

    /// Stack view containing toggle switches.
    private lazy var toggleStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }()

    /// Cached toggle IDs to detect when we need to rebuild UI.
    private var lastToggleIds: [String] = []

    // MARK: - User Media UI (PR-32)

    /// Label for user media section.
    private lazy var userMediaLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.text = "User Media"
        return label
    }()

    /// Stack view containing user media buttons.
    private lazy var userMediaStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fillEqually
        return stack
    }()

    /// Add photo button.
    private lazy var addPhotoButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Add Photo"
        config.cornerStyle = .medium
        config.baseBackgroundColor = .systemIndigo
        config.image = UIImage(systemName: "photo")
        config.imagePadding = 4
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(addPhotoTapped), for: .touchUpInside)
        return btn
    }()

    /// Clear media button.
    private lazy var clearMediaButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Clear"
        config.cornerStyle = .medium
        config.baseBackgroundColor = .systemRed
        config.image = UIImage(systemName: "xmark.circle")
        config.imagePadding = 4
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(clearMediaTapped), for: .touchUpInside)
        return btn
    }()

    /// User media status label (shows current media state).
    private lazy var userMediaStatusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.text = "No media"
        return label
    }()

    // MARK: - Properties

    #if DEBUG
    private let loader = ScenePackageLoader()
    private let sceneValidator = SceneValidator()
    private let animLoader = AnimLoader()
    private let animValidator = AnimValidator()
    private var currentPackage: ScenePackage?
    private var loadedAnimations: LoadedAnimations?
    private var isSceneValid = false
    private var isAnimValid = false
    #endif
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

    // MARK: - Editor (PR-19)
    private var scenePlayer: ScenePlayer?
    private let editorController = TemplateEditorController()

    // MARK: - PR2: EditorStore (centralized state management)
    private var editorStore: EditorStore?

    // MARK: - Release v1: Scene Library + Playback Coordinator
    private var sceneLibrarySnapshot: SceneLibrarySnapshot?
    private var playbackCoordinator: TimelinePlaybackCoordinator?
    private var defaultSceneSequence: [SceneTypeDefault] = []

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
    private lazy var modeToggle: UISegmentedControl = {
        let control = UISegmentedControl(items: ["Preview", "Edit"])
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = 0  // Preview by default
        control.addTarget(self, action: #selector(modeToggleChanged), for: .valueChanged)
        control.isEnabled = false
        return control
    }()

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

    // Fullscreen mode
    private var isFullscreen = false
    private var metalViewHeightConstraint: NSLayoutConstraint?
    private var metalViewTopToLoadButtonConstraint: NSLayoutConstraint?
    private var metalViewTopToSafeAreaConstraint: NSLayoutConstraint?
    private var metalViewBottomConstraint: NSLayoutConstraint?
    private var metalViewLeadingConstraint: NSLayoutConstraint?
    private var metalViewTrailingConstraint: NSLayoutConstraint?

    // Editor mode layout constraints (PR-Templates)
    private var exportButtonTopToTemplateSelectorConstraint: NSLayoutConstraint?
    private var exportButtonTopToContentViewConstraint: NSLayoutConstraint?
    private var logTextViewHeightConstraint: NSLayoutConstraint?
    private var logTextViewBottomConstraint: NSLayoutConstraint?
    private var mainControlsStackBottomConstraint: NSLayoutConstraint?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupRenderer()
        wireEditorController()
        applyPresentationMode()
        let deviceName = metalView.device?.name ?? "N/A"
        log("AnimiApp initialized, TVECore: \(TVECore.version), Metal: \(deviceName)")

        // PR-Templates: Handle auto-load based on presentation mode
        switch presentationMode {
        case .dev:
            // PR4: Auto-load default template on startup
            // In Release builds, load pre-compiled template automatically
            // In Debug builds, user can select and load via Load Scene button
            #if !DEBUG
            loadCompiledTemplateFromBundle(templateName: "example_4blocks")
            #endif
        case .editor(let templateId):
            // Release v1: Load SceneLibrary, Recipe, then first scene
            Task { @MainActor in
                await loadEditorContent(templateId: templateId)
            }
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

    /// Applies UI changes based on presentation mode (PR-Templates)
    private func applyPresentationMode() {
        switch presentationMode {
        case .dev:
            // Show all dev UI
            templateSelector.isHidden = false
            logTextView.isHidden = false
            scrollView.isHidden = false
            editorLayoutContainer.isHidden = true

            // Restore dev mode constraints
            exportButtonTopToContentViewConstraint?.isActive = false
            exportButtonTopToTemplateSelectorConstraint?.isActive = true

            mainControlsStackBottomConstraint?.isActive = false
            logTextViewHeightConstraint?.isActive = true
            logTextViewBottomConstraint?.isActive = true

        case .editor:
            // PR2: Use EditorLayoutContainerView instead of scrollView
            scrollView.isHidden = true
            editorLayoutContainer.isHidden = false

            // Hide dev-only UI in editor mode
            templateSelector.isHidden = true
            logTextView.isHidden = true

            // Hide system navigation bar - we have our own EditorNavBar
            navigationController?.setNavigationBarHidden(true, animated: false)

            // Setup editor layout
            setupEditorLayout()
        }
    }

    // MARK: - PR2: Editor Layout Setup

    /// Sets up the editor layout container for .editor mode
    private func setupEditorLayout() {
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

        // Wire callbacks
        wireEditorLayoutCallbacks()
    }

    /// Wires callbacks from EditorLayoutContainerView
    private func wireEditorLayoutCallbacks() {
        editorLayoutContainer.onClose = { [weak self] in
            self?.handleEditorClose()
        }

        editorLayoutContainer.onExport = { [weak self] in
            self?.exportTapped()
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
                // Restore position (convert frame to time for time-based API)
                self.currentFrameIndex = frame
                let timeUs = frameToUs(frame, fps: Int(self.sceneFPS))
                self.editorController.setCurrentTimeUs(timeUs, mode: .playback)
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
        guard case .editor = presentationMode else { return }

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

        // Step 5: Configure editor controller with time parameters
        let finalDurationUs = store.projectDurationUs
        editorController.templateFPS = fps
        editorController.durationUs = finalDurationUs
        editorController.totalFrames = totalFrames

        // Step 6: Configure timeline UI with scenes from store
        let scenes = store.sceneDrafts
        editorLayoutContainer.configure(
            scenes: scenes,
            templateFPS: fps,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )

        // Step 7: Setup TimelinePlaybackCoordinator (Release v1)
        setupPlaybackCoordinator()

        // Step 8: PR9.1 - Initial apply SceneState for first scene
        // Without this, activeSceneInstanceId stays nil until first scrub/play
        handlePlayheadChanged(store.playheadTimeUs)

        // PR10: Editor boot invariant - verify wiring is complete
        #if DEBUG
        if activeSceneInstanceId == nil {
            assertionFailure("[PR10] configureEditorTimeline: activeSceneInstanceId is nil after initial apply")
        }
        if scenePlayer == nil {
            assertionFailure("[PR10] configureEditorTimeline: scenePlayer is nil after initial apply")
        }
        if playbackCoordinator?.currentSceneInstanceId == nil {
            assertionFailure("[PR10] configureEditorTimeline: playbackCoordinator.currentSceneInstanceId is nil after initial apply")
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
        // Update current scene player for rendering
        scenePlayer = loadedScene.player
        editorController.setPlayer(loadedScene.player)
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
            }
        }

        // Update canvas size if different
        let newCanvasSize = loadedScene.compiled.runtime.canvasSize
        if canvasSize != newCanvasSize {
            canvasSize = newCanvasSize
            editorController.canvasSize = canvasSize
            updateMetalViewAspectRatio(width: canvasSize.width, height: canvasSize.height)
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
    private func handlePlayheadChanged(_ timeUs: TimeUs) {
        guard let coordinator = playbackCoordinator else { return }

        #if DEBUG
        let signpostId = ScrubSignpost.beginHandlePlayheadChanged()
        ScrubCallCounter.shared.recordHandlePlayheadChanged()
        #endif

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

            #if DEBUG
            ScrubSignpost.endHandlePlayheadChanged(signpostId, syncPath: true)
            #endif
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

            #if DEBUG
            ScrubSignpost.endHandlePlayheadChanged(signpostId, syncPath: false)
            #endif
        }

        // Sync editor controller (for UI frame display - global frame)
        // DEBUG: DebugSkipEditorControllerTimeUpdate toggle for A/B testing H2
        #if DEBUG
        if !ScrubDebugToggles.skipEditorControllerTimeUpdate {
            editorController.setCurrentTimeUs(timeUs, mode: .ended)
        }
        #else
        editorController.setCurrentTimeUs(timeUs, mode: .ended)
        #endif
    }

    /// Called when selection changes (lightweight, frequent).
    /// Used for tap/drag selection updates.
    private func handleSelectionChanged(_ selection: TimelineSelection?) {
        let sel = selection ?? .none
        let sceneCount = editorStore?.sceneItems.count ?? 1
        editorLayoutContainer.setTimelineSelection(sel, sceneCount: sceneCount)
        editorController.selectTimeline(sel)
    }

    /// Called when timeline structure changes (heavier, less frequent).
    /// Used for scene add/remove/trim commits.
    private func handleTimelineChanged(_ state: EditorState) {
        // Update scene clips UI
        let scenes = state.canonicalTimeline.toSceneDrafts()
        editorLayoutContainer.updateScenes(scenes)

        // Sync editor controller duration
        editorController.durationUs = state.projectDurationUs

        // Update coordinator timeline
        playbackCoordinator?.updateSceneTimeline(from: state)

        // Mark draft as dirty for persistence
        currentProjectDraft = state.draft
        draftIsDirty = true
    }

    /// Called during live-trim preview (lightweight, frequent).
    /// Only updates UI, skips playback coordinator and persistence.
    private func handleTimelinePreviewChanged(_ state: EditorState) {
        // Update scene clips UI only
        let scenes = state.canonicalTimeline.toSceneDrafts()
        editorLayoutContainer.updateScenes(scenes)

        // Sync editor controller duration (cheap, keeps UI consistent)
        editorController.durationUs = state.projectDurationUs

        // NOTE: Intentionally NOT updating:
        // - playbackCoordinator (expensive O(n) rebuild)
        // - currentProjectDraft / draftIsDirty (persistence only on commit)
    }

    /// Called when undo/redo availability changes.
    private func handleUndoRedoChanged(canUndo: Bool, canRedo: Bool) {
        // TODO: Update undo/redo buttons in UI when added
        #if DEBUG
        log("[PR2] Undo/Redo changed: canUndo=\(canUndo), canRedo=\(canRedo)")
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

            #if DEBUG
            log("[PR-D] Entered Scene Edit for scene: \(sceneId)")
            #endif
        }
    }

    /// Handles selected block changes in Scene Edit mode.
    /// PR-D: Updates bottom bar and overlay when block selection changes.
    private func handleSelectedBlockChanged(_ blockId: String?) {
        editorLayoutContainer.updateSceneEditBottomBar(selectedBlockId: blockId)
        sceneEditController?.updateOverlay()

        #if DEBUG
        log("[PR-D] Selected block changed: \(blockId ?? "nil")")
        #endif
    }

    /// Handles state restoration after undo/redo.
    /// PR-D: Re-applies runtime state for active scene instance to sync with restored snapshot.
    private func handleStateRestoredFromUndoRedo() {
        guard let instanceId = activeSceneInstanceId else { return }

        // Clear runtime user media to avoid "stale textures" after undo
        userMediaService?.clearAll()

        // Re-apply full persisted state for active instance
        applySceneInstanceState(instanceId: instanceId)

        // Refresh overlay and redraw
        sceneEditController?.updateOverlay()
        metalView.setNeedsDisplay()

        #if DEBUG
        log("[PR-D] State restored from undo/redo, re-applied instance: \(instanceId)")
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // PR2: Hide system navigation bar in editor mode (we use EditorNavBar)
        if case .editor = presentationMode {
            navigationController?.setNavigationBarHidden(true, animated: animated)
        }
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
        editorController.viewSize = metalView.bounds.size
        overlayView.canvasToView = editorController.canvasToViewTransform()

        // PR-D: Update Scene Edit mapper with current canvas/view sizes
        sceneEditController?.mapper.canvasSize = canvasSize
        sceneEditController?.mapper.viewSize = metalView.bounds.size

        // Lead fix #5: refresh overlay after layout change to prevent "jump"
        editorController.refreshOverlayIfNeeded()

        // P1-2: Refresh Scene Edit overlay after layout change
        if case .sceneEdit = editorStore?.state.uiMode {
            sceneEditController?.updateOverlay()
        }
    }

    /// Main vertical stack for all controls below metalView
    private lazy var mainControlsStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        return stack
    }()

    /// Container for variant controls (label + picker)
    private lazy var variantContainer: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [variantLabel, variantPicker])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }()

    /// Container for toggle controls (label + stack)
    private lazy var toggleContainer: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [toggleLabel, toggleStack])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }()

    /// Container for user media controls (label + buttons + status)
    private lazy var userMediaContainer: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [userMediaLabel, userMediaStack, userMediaStatusLabel])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }()

    /// Container for playback controls (play/pause + slider + frame label)
    private lazy var playbackContainer: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [controlsStack, frameLabel])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }()

    private func setupUI() {
        view.backgroundColor = .systemBackground

        // Setup scroll view hierarchy
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        // Add header elements to contentView
        // Export button is available in both DEBUG and Release
        contentView.addSubview(exportButton)
        contentView.addSubview(backgroundButton)  // PR3
        #if DEBUG
        [sceneSelector, loadButton, smokeTestButton, smokeTestStatusLabel].forEach { contentView.addSubview($0) }
        #endif
        [templateSelector, modeToggle, presetPicker, metalView, overlayView, preparingOverlay, mainControlsStack, logTextView].forEach { contentView.addSubview($0) }

        // Setup mainControlsStack with all control containers
        [variantContainer, toggleContainer, userMediaContainer, playbackContainer].forEach {
            mainControlsStack.addArrangedSubview($0)
        }

        // Initially hide edit-mode containers (shown when block selected)
        variantContainer.isHidden = true
        toggleContainer.isHidden = true
        userMediaContainer.isHidden = true

        // PR-32: Add user media buttons to stack
        // PR9.1: Video hidden until video persistence is implemented
        [addPhotoButton, clearMediaButton].forEach { userMediaStack.addArrangedSubview($0) }
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        preparingOverlay.translatesAutoresizingMaskIntoConstraints = false

        // ScrollView fills the entire view
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // ContentView fills scrollView width, height determined by content
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        // MetalView constraints - full width, aspect ratio height
        metalViewHeightConstraint = metalView.heightAnchor.constraint(equalTo: metalView.widthAnchor, multiplier: 9.0 / 16.0)
        metalViewHeightConstraint?.priority = .defaultHigh

        // Fullscreen mode constraints (applied to view, not contentView)
        metalViewTopToSafeAreaConstraint = metalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        metalViewTopToSafeAreaConstraint?.isActive = false
        metalViewBottomConstraint = metalView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        metalViewBottomConstraint?.isActive = false

        // Export and Background button constraints (common for DEBUG and Release)
        NSLayoutConstraint.activate([
            // Export button - left half
            exportButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            exportButton.heightAnchor.constraint(equalToConstant: 44),

            // Background button - right half (PR3)
            backgroundButton.leadingAnchor.constraint(equalTo: exportButton.trailingAnchor, constant: 8),
            backgroundButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            backgroundButton.heightAnchor.constraint(equalToConstant: 44),
            backgroundButton.widthAnchor.constraint(equalTo: exportButton.widthAnchor),
            backgroundButton.centerYAnchor.constraint(equalTo: exportButton.centerYAnchor),
        ])

        #if DEBUG
        // DEBUG: sceneSelector and loadButton at top (for test packages)
        NSLayoutConstraint.activate([
            sceneSelector.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            sceneSelector.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            sceneSelector.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            loadButton.topAnchor.constraint(equalTo: sceneSelector.bottomAnchor, constant: 8),
            loadButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            loadButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            loadButton.heightAnchor.constraint(equalToConstant: 44),

            // Export button below loadButton in DEBUG
            exportButton.topAnchor.constraint(equalTo: loadButton.bottomAnchor, constant: 8),

            smokeTestButton.topAnchor.constraint(equalTo: exportButton.bottomAnchor, constant: 8),
            smokeTestButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            smokeTestButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            smokeTestButton.heightAnchor.constraint(equalToConstant: 44),

            smokeTestStatusLabel.topAnchor.constraint(equalTo: smokeTestButton.bottomAnchor, constant: 4),
            smokeTestStatusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            smokeTestStatusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            templateSelector.topAnchor.constraint(equalTo: smokeTestStatusLabel.bottomAnchor, constant: 8),
            templateSelector.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            templateSelector.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            modeToggle.topAnchor.constraint(equalTo: templateSelector.bottomAnchor, constant: 8),
            modeToggle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            modeToggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
        #else
        // RELEASE: templateSelector at top, exportButton, then modeToggle
        // Store switchable constraints for editor mode (PR-Templates)
        exportButtonTopToTemplateSelectorConstraint = exportButton.topAnchor.constraint(equalTo: templateSelector.bottomAnchor, constant: 8)
        exportButtonTopToContentViewConstraint = exportButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12)

        NSLayoutConstraint.activate([
            templateSelector.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            templateSelector.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            templateSelector.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            // Export button below templateSelector in Release (default, switched in editor mode)
            exportButtonTopToTemplateSelectorConstraint!,

            modeToggle.topAnchor.constraint(equalTo: exportButton.bottomAnchor, constant: 8),
            modeToggle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            modeToggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
        #endif

        // Store metalView top constraint for normal mode
        metalViewTopToLoadButtonConstraint = metalView.topAnchor.constraint(equalTo: presetPicker.bottomAnchor, constant: 8)

        NSLayoutConstraint.activate([
            // presetPicker between modeToggle and metalView
            presetPicker.topAnchor.constraint(equalTo: modeToggle.bottomAnchor, constant: 6),
            presetPicker.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            presetPicker.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            // MetalView - full width (no padding), aspect ratio height
            metalViewTopToLoadButtonConstraint!,
            metalView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            metalViewHeightConstraint!,

            // overlayView pins to metalView
            overlayView.topAnchor.constraint(equalTo: metalView.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),

            // preparingOverlay pins to metalView
            preparingOverlay.topAnchor.constraint(equalTo: metalView.topAnchor),
            preparingOverlay.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            preparingOverlay.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            preparingOverlay.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),

            // Main controls stack below metalView
            mainControlsStack.topAnchor.constraint(equalTo: metalView.bottomAnchor, constant: 12),
            mainControlsStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            mainControlsStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            // User media stack height
            userMediaStack.heightAnchor.constraint(equalToConstant: 36),
            playPauseButton.widthAnchor.constraint(equalToConstant: 80),

            // logTextView with fixed height (scrollable content ends here)
            logTextView.topAnchor.constraint(equalTo: mainControlsStack.bottomAnchor, constant: 12),
            logTextView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            logTextView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])

        // Store switchable constraints for editor mode (PR-Templates)
        logTextViewHeightConstraint = logTextView.heightAnchor.constraint(equalToConstant: 150)
        logTextViewBottomConstraint = logTextView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        mainControlsStackBottomConstraint = mainControlsStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)

        // Activate default constraints (dev mode)
        logTextViewHeightConstraint?.isActive = true
        logTextViewBottomConstraint?.isActive = true

        // Remove corner radius from metalView (full-width, no rounding)
        metalView.layer.cornerRadius = 0
        metalView.clipsToBounds = false

        // PR-19: Tap gesture on metalView for dev mode
        let metalTapGesture = UITapGestureRecognizer(target: self, action: #selector(metalViewTapped))
        metalView.addGestureRecognizer(metalTapGesture)

        // PR-D: All transform gestures on overlayView for Scene Edit mode
        let overlayTapGesture = UITapGestureRecognizer(target: self, action: #selector(overlayViewTapped))
        overlayView.addGestureRecognizer(overlayTapGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation))
        panGesture.delegate = self
        pinchGesture.delegate = self
        rotationGesture.delegate = self
        overlayView.addGestureRecognizer(panGesture)
        overlayView.addGestureRecognizer(pinchGesture)
        overlayView.addGestureRecognizer(rotationGesture)
    }

    /// Wires editor controller callbacks. Called once from viewDidLoad.
    private func wireEditorController() {
        editorController.setOverlayView(overlayView)

        editorController.onNeedsDisplay = { [weak self] in
            self?.requestMetalRender()
        }

        editorController.onStateChanged = { [weak self] state in
            self?.syncUIWithState(state)
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

    // MARK: - Actions

    #if DEBUG
    @objc private func loadTestPackageTapped() {
        stopPlayback()
        renderErrorLogged = false
        log("---\nLoading scene package...")
        let sceneNames = ["example_4blocks", "alpha_matte_test", "variant_switch_demo", "polaroid_shared_demo"]
        let idx = sceneSelector.selectedSegmentIndex
        let sceneName = idx < sceneNames.count ? sceneNames[idx] : sceneNames[0]
        let subdir = "TestAssets/ScenePackages/\(sceneName)"
        guard let url = Bundle.main.url(forResource: "scene", withExtension: "json", subdirectory: subdir) else {
            log("ERROR: Test package '\(sceneName)' not found"); return
        }
        do {
            try loadAndValidatePackage(from: url.deletingLastPathComponent())
        } catch {
            log("ERROR: \(error)")
            isSceneValid = false
            isAnimValid = false
        }
    }

    #endif

    // MARK: - Export (Release + DEBUG)

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

    #if DEBUG
    // MARK: - Smoke Tests (A3)

    @objc private func smokeTestTapped() {
        guard !isSmokeTestRunning else {
            log("[SmokeTest] Tests already running")
            return
        }
        guard loadingState == .ready else {
            log("[SmokeTest] ERROR: Template not ready")
            return
        }
        runSmokeTests()
    }

    /// Runs 4 sequential export smoke tests on current scene.
    private func runSmokeTests() {
        isSmokeTestRunning = true
        smokeTestResults = []
        smokeTestButton.isEnabled = false
        smokeTestStatusLabel.isHidden = false
        smokeTestStatusLabel.text = "Starting smoke tests..."
        log("[SmokeTest] === Starting Smoke Tests ===")

        // Define test configurations
        let tests: [(name: String, config: AudioExportConfig?)] = [
            ("video-only", nil),
            ("original-audio-only", AudioExportConfig(
                music: nil,
                voiceover: nil,
                includeOriginalFromVideoSlots: true,
                originalDefaultVolume: 1.0
            )),
            ("music-only", testMusicURL.map { AudioExportConfig(
                music: AudioTrackConfig(url: $0, startTimeSeconds: 0, volume: 0.7),
                voiceover: nil,
                includeOriginalFromVideoSlots: false,
                originalDefaultVolume: 1.0
            ) }),
            ("voiceover+music", {
                guard let musicURL = testMusicURL, let voiceURL = testVoiceoverURL else { return nil }
                return AudioExportConfig(
                    music: AudioTrackConfig(url: musicURL, startTimeSeconds: 0, volume: 0.5),
                    voiceover: AudioTrackConfig(url: voiceURL, startTimeSeconds: 0, volume: 1.0),
                    includeOriginalFromVideoSlots: false,
                    originalDefaultVolume: 1.0
                )
            }())
        ]

        runNextSmokeTest(tests: tests, index: 0)
    }

    private func runNextSmokeTest(tests: [(name: String, config: AudioExportConfig?)], index: Int) {
        guard index < tests.count else {
            // All tests complete
            finishSmokeTests()
            return
        }

        let test = tests[index]
        smokeTestStatusLabel.text = "Test \(index + 1)/\(tests.count): \(test.name)"
        log("[SmokeTest] Running test \(index + 1)/\(tests.count): \(test.name)")

        // Skip test if audio config is expected but missing test files
        if index > 0 && test.config == nil && test.name != "video-only" {
            log("[SmokeTest] SKIP: \(test.name) - missing test audio files")
            smokeTestResults.append((name: test.name, result: .skip))
            runNextSmokeTest(tests: tests, index: index + 1)
            return
        }

        runSingleSmokeTest(name: test.name, audioConfig: test.config) { [weak self] success in
            guard let self = self else { return }
            self.smokeTestResults.append((name: test.name, result: success ? .pass : .fail))
            self.log("[SmokeTest] \(test.name): \(success ? "PASS" : "FAIL")")

            // Run next test after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.runNextSmokeTest(tests: tests, index: index + 1)
            }
        }
    }

    private func runSingleSmokeTest(name: String, audioConfig: AudioExportConfig?, completion: @escaping (Bool) -> Void) {
        guard let renderer = renderer,
              let compiled = compiledScene,
              let player = scenePlayer,
              let mainTextureProvider = textureProvider,
              let resolver = currentResolver else {
            completion(false)
            return
        }

        let device = renderer.commandQueue.device
        let exportTP = ExportTextureProvider(
            device: device,
            assetIndex: compiled.mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: compiled.bindingAssetIds
        )
        exportTP.preloadAll(commandQueue: renderer.commandQueue)
        exportTP.injectTextures(from: mainTextureProvider, for: compiled.bindingAssetIds)

        let runtime = compiled.runtime
        let canvasSize = runtime.canvasSize

        // Unique filename for this test
        let sceneId = runtime.scene.sceneId ?? "scene"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let filename = "smoke_\(name)_\(sceneId)_\(timestamp).mp4"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        let pixels = Int(canvasSize.width) * Int(canvasSize.height)
        let bitrate = max(5_000_000, min(25_000_000, 15_000_000 * pixels / 2_073_600))

        let settings = VideoExportSettings(
            outputURL: outputURL,
            sizePx: (width: Int(canvasSize.width), height: Int(canvasSize.height)),
            fps: runtime.fps,
            bitrate: bitrate,
            clearColor: .opaqueBlack,
            audio: audioConfig
        )

        isExporting = true
        let exporter = VideoExporter()
        videoExporter = exporter

        // PR5: Wrap in Task for async preload
        Task { @MainActor in
            // Preload background textures into export provider
            await self.preloadBackgroundTexturesForExport(exportTP: exportTP)

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
                progress: { [weak self] progress in
                    let pct = Int(progress * 100)
                    self?.smokeTestStatusLabel.text = "\(name): \(pct)%"
                },
                completion: { [weak self] result in
                    self?.isExporting = false
                    self?.videoExporter = nil

                    switch result {
                    case .success(let url):
                        // Clean up temp file
                        try? FileManager.default.removeItem(at: url)
                        completion(true)
                    case .failure(let error):
                        self?.log("[SmokeTest] \(name) error: \(error.localizedDescription)")
                        completion(false)
                    }
                }
            )
        }
    }

    private func finishSmokeTests() {
        isSmokeTestRunning = false
        smokeTestButton.isEnabled = true

        let passed = smokeTestResults.filter { $0.result == .pass }.count
        let failed = smokeTestResults.filter { $0.result == .fail }.count
        let skipped = smokeTestResults.filter { $0.result == .skip }.count
        let allPassed = failed == 0

        if skipped > 0 {
            smokeTestStatusLabel.text = "Smoke Tests: \(passed) PASSED, \(skipped) SKIPPED"
        } else {
            smokeTestStatusLabel.text = "Smoke Tests: \(passed)/\(smokeTestResults.count) PASSED"
        }
        smokeTestStatusLabel.textColor = allPassed ? .systemGreen : .systemRed

        log("[SmokeTest] === Results ===")
        for result in smokeTestResults {
            let statusStr: String
            switch result.result {
            case .pass: statusStr = "PASS"
            case .fail: statusStr = "FAIL"
            case .skip: statusStr = "SKIP"
            }
            log("[SmokeTest] \(result.name): \(statusStr)")
        }
        log("[SmokeTest] Total: \(passed) PASSED, \(failed) FAILED, \(skipped) SKIPPED")

        // Hide status after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.smokeTestStatusLabel.isHidden = true
            self?.smokeTestStatusLabel.textColor = .systemOrange
        }
    }

    #endif

    // MARK: - Export Implementation

    private func startExport() {
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
            self?.exportButton.isEnabled = true
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
        exportButton.isEnabled = false

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
                await self.preloadBackgroundTexturesForExport(exportTP: exportTP)

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
                        self.exportButton.isEnabled = true
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
        activityVC.popoverPresentationController?.sourceView = exportButton
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
        if isPlaying {
            stopPlayback()
            editorController.setPlaying(false)
        } else {
            editorController.setPlaying(true)
            startPlayback()
        }
    }

    @objc private func frameSliderChanged() {
        currentFrameIndex = Int(frameSlider.value)
        updateFrameLabel()
        editorController.scrub(to: currentFrameIndex)
        // PR-33: Update video frames for scrub mode (throttled seek)
        userMediaService?.updateVideoFramesForScrub(sceneFrameIndex: currentFrameIndex)
    }

    @objc private func metalViewTapped(_ recognizer: UITapGestureRecognizer) {
        // Tap always does hit-test for block selection (regardless of mode)
        let point = recognizer.location(in: metalView)
        print("[TAP] point=\(point), hasPlayer=\(scenePlayer != nil)")
        editorController.handleTap(viewPoint: point)
    }

    // PR-D: Tap handler for Scene Edit mode (on overlayView)
    @objc private func overlayViewTapped(_ recognizer: UITapGestureRecognizer) {
        guard case .sceneEdit = editorStore?.state.uiMode else { return }
        let point = recognizer.location(in: overlayView)
        sceneEditController?.handleTap(viewPoint: point)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        // PR-D: Route to sceneEditController in Scene Edit mode
        if case .sceneEdit = editorStore?.state.uiMode {
            sceneEditController?.handlePan(recognizer)
            persistTransformIfNeededSceneEdit(recognizer)
        } else {
            editorController.handlePan(recognizer)
            persistTransformIfNeeded(recognizer)
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        // PR-D: Route to sceneEditController in Scene Edit mode
        if case .sceneEdit = editorStore?.state.uiMode {
            sceneEditController?.handlePinch(recognizer)
            persistTransformIfNeededSceneEdit(recognizer)
        } else {
            editorController.handlePinch(recognizer)
            persistTransformIfNeeded(recognizer)
        }
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        // PR-D: Route to sceneEditController in Scene Edit mode
        if case .sceneEdit = editorStore?.state.uiMode {
            sceneEditController?.handleRotation(recognizer)
            persistTransformIfNeededSceneEdit(recognizer)
        } else {
            editorController.handleRotation(recognizer)
            persistTransformIfNeeded(recognizer)
        }
    }

    /// PR9.1: Persists current transform to store for undo/redo and save/load.
    private func persistTransformIfNeeded(_ recognizer: UIGestureRecognizer) {
        guard let instanceId = activeSceneInstanceId,
              let blockId = editorController.state.selectedBlockId,
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

    @objc private func modeToggleChanged() {
        stopPlayback()
        if modeToggle.selectedSegmentIndex == 0 {
            editorController.enterPreview()
        } else {
            editorController.enterEdit()
            // PR-33 Gate 1: Frozen frame update on edit mode entry
            userMediaService?.updateVideoFramesForFrozen(sceneFrameIndex: ScenePlayer.editFrameIndex)
        }
    }

    @objc private func templateSelectorChanged() {
        let idx = templateSelector.selectedSegmentIndex
        guard idx >= 0, idx < availableTemplates.count else { return }
        let templateName = availableTemplates[idx].name
        loadCompiledTemplateFromBundle(templateName: templateName)
    }

    // MARK: - Variant Switching Actions (PR-20)

    @objc private func variantPickerChanged() {
        let idx = variantPicker.selectedSegmentIndex
        let variants = editorController.selectedBlockVariants()
        guard idx >= 0, idx < variants.count else { return }

        // Policy: stop playback before switching (frame preserved)
        if isPlaying { stopPlayback() }
        editorController.setSelectedVariantForSelectedBlock(variants[idx].id)
        log("[Variant] block=\(editorController.state.selectedBlockId ?? "?") -> \(variants[idx].id)")

        // PR9.1: Persist variant to store (write-through)
        guard let instanceId = activeSceneInstanceId,
              let blockId = editorController.state.selectedBlockId else { return }
        editorStore?.dispatch(.setBlockVariant(
            sceneInstanceId: instanceId,
            blockId: blockId,
            variantId: variants[idx].id
        ))
    }

    @objc private func presetPickerChanged() {
        let idx = presetPicker.selectedSegmentIndex
        guard idx >= 0, idx < scenePresets.count else { return }

        // Policy: stop playback before switching (frame preserved)
        if isPlaying { stopPlayback() }
        editorController.applyScenePreset(scenePresets[idx].mapping)
        log("[Preset] \(scenePresets[idx].title)")
    }

    private func toggleFullscreen() {
        isFullscreen.toggle()

        if isFullscreen {
            // Move metalView and overlays to main view for fullscreen
            metalView.removeFromSuperview()
            overlayView.removeFromSuperview()
            preparingOverlay.removeFromSuperview()
            view.addSubview(metalView)
            view.addSubview(overlayView)
            view.addSubview(preparingOverlay)

            // Deactivate contentView constraints
            metalViewTopToLoadButtonConstraint?.isActive = false
            metalViewHeightConstraint?.isActive = false

            // Activate fullscreen constraints
            metalViewTopToSafeAreaConstraint?.isActive = true
            metalViewBottomConstraint?.isActive = true
            metalViewLeadingConstraint = metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
            metalViewTrailingConstraint = metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            metalViewLeadingConstraint?.isActive = true
            metalViewTrailingConstraint?.isActive = true

            // Re-pin overlays to metalView
            NSLayoutConstraint.activate([
                overlayView.topAnchor.constraint(equalTo: metalView.topAnchor),
                overlayView.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
                overlayView.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
                overlayView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
                preparingOverlay.topAnchor.constraint(equalTo: metalView.topAnchor),
                preparingOverlay.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
                preparingOverlay.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
                preparingOverlay.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            ])

            scrollView.isHidden = true
        } else {
            // Deactivate fullscreen constraints
            metalViewTopToSafeAreaConstraint?.isActive = false
            metalViewBottomConstraint?.isActive = false
            metalViewLeadingConstraint?.isActive = false
            metalViewTrailingConstraint?.isActive = false

            // Move metalView and overlays back to contentView
            metalView.removeFromSuperview()
            overlayView.removeFromSuperview()
            preparingOverlay.removeFromSuperview()
            contentView.addSubview(metalView)
            contentView.addSubview(overlayView)
            contentView.addSubview(preparingOverlay)

            // Re-activate contentView constraints
            metalViewTopToLoadButtonConstraint?.isActive = true
            metalViewHeightConstraint?.isActive = true

            // Re-pin metalView to contentView (full width)
            NSLayoutConstraint.activate([
                metalView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                metalView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                overlayView.topAnchor.constraint(equalTo: metalView.topAnchor),
                overlayView.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
                overlayView.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
                overlayView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
                preparingOverlay.topAnchor.constraint(equalTo: metalView.topAnchor),
                preparingOverlay.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
                preparingOverlay.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
                preparingOverlay.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            ])

            scrollView.isHidden = false
        }

        UIView.animate(withDuration: 0.3) {
            self.view.layoutIfNeeded()
        }

        setNeedsStatusBarAppearanceUpdate()
    }

    /// Syncs UI controls with editor state (called from controller's onStateChanged callback).
    private func syncUIWithState(_ state: TemplateEditorState) {
        let isPreview = state.mode == .preview

        // Playback controls visible only in preview mode
        playbackContainer.isHidden = !isPreview

        frameLabel.text = "Frame: \(state.currentPreviewFrame) / \(totalFrames)"
        frameSlider.value = Float(state.currentPreviewFrame)

        overlayView.isHidden = isPreview

        // PR-20: variant picker — only in edit mode with a selected block that has 2+ variants
        updateVariantPickerUI(state: state)

        // PR-30: toggle UI — only in edit mode with a selected block that has toggles
        updateToggleUI(state: state)

        // PR-32: user media UI — only in edit mode with a selected block that has binding layer
        updateUserMediaUI(state: state)
    }

    /// Rebuilds variant picker segments and selection for current state.
    private func updateVariantPickerUI(state: TemplateEditorState) {
        let variants = editorController.selectedBlockVariants()
        let showPicker = state.mode == .edit
            && state.selectedBlockId != nil
            && variants.count > 1

        // Hide entire container (UIStackView auto-collapses)
        variantContainer.isHidden = !showPicker

        guard showPicker else { return }

        variantLabel.text = "Block: \(state.selectedBlockId ?? "")"

        // Rebuild segments only if variant IDs changed (lead fix #2: compare cached data, not UIKit titles)
        let newIds = variants.map(\.id)
        if lastVariantIds != newIds {
            variantPicker.removeAllSegments()
            for (i, v) in variants.enumerated() {
                variantPicker.insertSegment(withTitle: v.id, at: i, animated: false)
            }
            lastVariantIds = newIds
        }

        // Sync selected segment with active variantId (lead fix #1: reset first to avoid stale selection)
        variantPicker.selectedSegmentIndex = UISegmentedControl.noSegment
        if let activeId = editorController.selectedBlockVariantId(),
           let idx = variants.firstIndex(where: { $0.id == activeId }) {
            variantPicker.selectedSegmentIndex = idx
        }
    }

    // MARK: - Layer Toggle UI (PR-30)

    /// Rebuilds toggle switches for current state.
    private func updateToggleUI(state: TemplateEditorState) {
        let toggles = editorController.selectedBlockToggles()
        let showToggles = state.mode == .edit
            && state.selectedBlockId != nil
            && !toggles.isEmpty

        // Hide entire container (UIStackView auto-collapses)
        toggleContainer.isHidden = !showToggles

        guard showToggles else { return }

        // Rebuild UI only if toggle IDs changed
        let newIds = toggles.map(\.id)
        if lastToggleIds != newIds {
            // Clear existing switches
            toggleStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

            // Create switch for each toggle
            for toggle in toggles {
                let row = createToggleRow(toggle: toggle)
                toggleStack.addArrangedSubview(row)
            }
            lastToggleIds = newIds
        }

        // Sync switch states with current values
        for (idx, toggle) in toggles.enumerated() {
            if let row = toggleStack.arrangedSubviews[safe: idx] as? UIStackView,
               let switchControl = row.arrangedSubviews.last as? UISwitch {
                let enabled = editorController.isToggleEnabled(toggleId: toggle.id) ?? toggle.defaultOn
                switchControl.isOn = enabled
            }
        }
    }

    /// Creates a row with label + switch for a toggle.
    private func createToggleRow(toggle: LayerToggle) -> UIStackView {
        let label = UILabel()
        label.text = toggle.title
        label.font = .systemFont(ofSize: 15)

        let switchControl = UISwitch()
        switchControl.accessibilityIdentifier = toggle.id
        switchControl.addTarget(self, action: #selector(toggleSwitchChanged(_:)), for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [label, switchControl])
        row.axis = .horizontal
        row.distribution = .equalSpacing
        return row
    }

    @objc private func toggleSwitchChanged(_ sender: UISwitch) {
        guard let toggleId = sender.accessibilityIdentifier else { return }
        editorController.setToggle(toggleId: toggleId, enabled: sender.isOn)
        log("[Toggle] \(toggleId) = \(sender.isOn ? "ON" : "OFF")")

        // PR9.1: Persist toggle to store (write-through)
        guard let instanceId = activeSceneInstanceId,
              let blockId = editorController.state.selectedBlockId else { return }
        editorStore?.dispatch(.setBlockToggle(
            sceneInstanceId: instanceId,
            blockId: blockId,
            toggleId: toggleId,
            enabled: sender.isOn
        ))
    }

    // MARK: - User Media UI (PR-32)

    /// Shows/hides user media section based on state.
    private func updateUserMediaUI(state: TemplateEditorState) {
        // Show user media controls only in edit mode with a selected block that has binding layer
        let hasBinding: Bool
        if let blockId = state.selectedBlockId, let player = scenePlayer {
            hasBinding = player.bindingAssetId(blockId: blockId) != nil
            print("[updateUserMediaUI] blockId=\(blockId), hasBinding=\(hasBinding), bindingAssetId=\(player.bindingAssetId(blockId: blockId) ?? "nil")")
        } else {
            hasBinding = false
            print("[updateUserMediaUI] no blockId or no player")
        }
        let showUserMedia = state.mode == .edit && hasBinding
        print("[updateUserMediaUI] mode=\(state.mode), showUserMedia=\(showUserMedia)")
        print("[updateUserMediaUI] BEFORE: userMediaContainer.isHidden=\(userMediaContainer.isHidden), superview=\(userMediaContainer.superview != nil)")

        // Hide entire container (UIStackView auto-collapses)
        userMediaContainer.isHidden = !showUserMedia

        print("[updateUserMediaUI] AFTER: userMediaContainer.isHidden=\(userMediaContainer.isHidden)")
        print("[updateUserMediaUI] scrollView.isHidden=\(scrollView.isHidden)")
        print("[updateUserMediaUI] presentationMode=\(presentationMode)")

        guard showUserMedia else { return }

        updateUserMediaStatusLabel()
    }

    /// Updates the user media status label with current media state.
    private func updateUserMediaStatusLabel() {
        guard let blockId = state.selectedBlockId,
              let service = userMediaService else {
            userMediaStatusLabel.text = "No media"
            return
        }

        let kind = service.mediaKind(for: blockId)
        switch kind {
        case .photo:
            userMediaStatusLabel.text = "Photo selected"
        case .video:
            userMediaStatusLabel.text = "Video selected"
        case .none:
            userMediaStatusLabel.text = "No media"
        }
    }

    // MARK: - User Media Actions (PR-32)

    @objc private func addPhotoTapped() {
        guard state.selectedBlockId != nil else { return }
        presentPhotoPicker(for: .images)
    }

    @objc private func clearMediaTapped() {
        guard let blockId = state.selectedBlockId else { return }

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

        updateUserMediaStatusLabel()
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
            updateUserMediaStatusLabel()
            metalView.setNeedsDisplay()
            return
        }

        log("[UserMedia] Photo set for block '\(blockId)'")

        // Step 2: Save to persistent storage and dispatch to store
        guard let instanceId = activeSceneInstanceId else {
            log("[UserMedia] No active scene instance, skipping persistence")
            updateUserMediaStatusLabel()
            metalView.setNeedsDisplay()
            return
        }

        // Resize and save to disk
        let maxDimension: CGFloat = 2048
        let resizedImage = resizeImageIfNeeded(image, maxDimension: maxDimension)

        guard let jpegData = resizedImage.jpegData(compressionQuality: 0.9) else {
            log("[UserMedia] Failed to create JPEG data for block '\(blockId)'")
            updateUserMediaStatusLabel()
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

        updateUserMediaStatusLabel()
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
            updateUserMediaStatusLabel()
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
            updateUserMediaStatusLabel()
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
            updateUserMediaStatusLabel()
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

        updateUserMediaStatusLabel()
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

    /// Convenience accessor for editor state.
    private var state: TemplateEditorState {
        editorController.state
    }

    override var prefersStatusBarHidden: Bool {
        isFullscreen
    }

    private func updateMetalViewAspectRatio(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }

        // Remove old height constraint
        metalViewHeightConstraint?.isActive = false

        // Create new constraint with correct aspect ratio (height/width)
        let aspectRatio = height / width
        metalViewHeightConstraint = metalView.heightAnchor.constraint(equalTo: metalView.widthAnchor, multiplier: aspectRatio)
        metalViewHeightConstraint?.priority = .defaultHigh
        metalViewHeightConstraint?.isActive = true

        view.layoutIfNeeded()
    }

    // MARK: - Package Loading (DEBUG only)

    #if DEBUG
    private func loadAndValidatePackage(from rootURL: URL) throws {
        let package = try loader.load(from: rootURL)
        currentPackage = package
        logPackageInfo(package)

        // PR-28: Create resolver early — needed for both validation and texture loading.
        let localIndex = try LocalAssetsIndex(imagesRootURL: package.imagesRootURL)
        let sharedIndex = try SharedAssetsIndex(bundle: Bundle.main, rootFolderName: "SharedAssets")
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)
        currentResolver = resolver

        let sceneReport = sceneValidator.validate(scene: package.scene)
        logValidationReport(sceneReport, title: "SceneValidation")
        isSceneValid = !sceneReport.hasErrors
        guard isSceneValid else { log("Scene invalid"); metalView.setNeedsDisplay(); return }
        try loadAndValidateAnimations(for: package, resolver: resolver)
        try compileScene(for: package)
        metalView.setNeedsDisplay()
    }

    private func loadAndValidateAnimations(for package: ScenePackage, resolver: CompositeAssetResolver) throws {
        let loaded = try animLoader.loadAnimations(from: package)
        loadedAnimations = loaded
        log("Loaded \(loaded.lottieByAnimRef.count) animations")
        // PR-28: Pass resolver for basename-based asset validation (TL requirement B)
        let report = animValidator.validate(scene: package.scene, package: package, loaded: loaded, resolver: resolver)
        logValidationReport(report, title: "AnimValidation")
        isAnimValid = !report.hasErrors
        if report.hasErrors { log("Animations invalid") }
    }

    private func compileScene(for package: ScenePackage) throws {
        guard isAnimValid,
              let loaded = loadedAnimations,
              let device = metalView.device else { return }

        log("---\nCompiling scene...")

        // PR3: Use SceneCompiler from TVECompilerCore (compile logic moved out of ScenePlayer)
        let sceneCompiler = SceneCompiler()
        let compiled = try sceneCompiler.compile(package: package, loadedAnimations: loaded)
        compiledScene = compiled

        // Create ScenePlayer and load the compiled scene
        let player = ScenePlayer()
        player.loadCompiledScene(compiled)

        // PR-19: Store player as property and wire to editor controller
        scenePlayer = player
        editorController.setPlayer(player)

        // Store canvas size for render target
        canvasSize = compiled.runtime.canvasSize
        editorController.canvasSize = canvasSize

        // Update metalView aspect ratio to match canvas
        updateMetalViewAspectRatio(width: canvasSize.width, height: canvasSize.height)

        // Store merged asset sizes for renderer
        mergedAssetSizes = compiled.mergedAssetIndex.sizeById

        // Create texture provider (PR-28: reuse resolver from validation, pass bindingAssetIds)
        let resolver = currentResolver ?? CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let provider = SceneTextureProviderFactory.create(
            device: device,
            mergedAssetIndex: compiled.mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: compiled.bindingAssetIds,
            logger: { [weak self] msg in self?.log(msg) }
        )
        textureProvider = provider

        // PR-B: Preload all textures before any draw/play (IO-free runtime invariant)
        // Alpha Fix: Use commandQueue for premultiplied alpha texture loading
        if let queue = commandQueue {
            provider.preloadAll(commandQueue: queue)
        }
        if let stats = provider.lastPreloadStats {
            log(String(format: "[Preload] loaded: %d, missing: %d, skipped: %d, duration: %.1fms",
                       stats.loadedCount, stats.missingCount, stats.skippedBindingCount, stats.durationMs))
        }

        // PR-32: Create UserMediaService for photo/video injection
        if let tp = textureProvider, let queue = commandQueue {
            userMediaService = UserMediaService(
                device: device,
                commandQueue: queue,
                scenePlayer: player,
                textureProvider: tp
            )
            userMediaService?.setSceneFPS(Double(compiled.runtime.fps))
            // PR1.1: Wire callback for async updates (poster ready, clear)
            userMediaService?.onNeedsDisplay = { [weak self] in
                self?.metalView.setNeedsDisplay()
            }
            log("UserMediaService initialized")
        }

        // Log compilation results
        let runtime = compiled.runtime
        let blockCount = runtime.blocks.count
        let canvasSizeStr = "\(Int(canvasSize.width))x\(Int(canvasSize.height))"
        log("Scene compiled: \(canvasSizeStr) @ \(runtime.fps)fps, \(runtime.durationFrames) frames, \(blockCount) blocks")

        // Log block details
        for block in runtime.blocks {
            let rect = block.rectCanvas
            let rectStr = "(\(Int(rect.x)),\(Int(rect.y)) \(Int(rect.width))x\(Int(rect.height)))"
            log("  Block '\(block.blockId)' z=\(block.zIndex) rect=\(rectStr)")
        }

        // Log asset count
        log("Merged assets: \(compiled.mergedAssetIndex.byId.count) textures")

        // PR-B: Diagnostic — verify preload coverage (DEBUG only)
        // After preloadAll(), texture(for:) is IO-free cache lookup
        #if DEBUG
        for (assetId, _) in compiled.mergedAssetIndex.byId {
            if let tex = textureProvider?.texture(for: assetId) {
                log("Texture: \(assetId) [\(tex.width)x\(tex.height)]")
            } else {
                log("WARNING: Texture MISSING after preload: \(assetId)")
            }
        }
        #endif

        // Setup playback controls
        totalFrames = runtime.durationFrames
        sceneFPS = Double(runtime.fps)
        currentFrameIndex = 0
        frameSlider.maximumValue = Float(max(0, totalFrames - 1))
        frameSlider.value = 0
        frameSlider.isEnabled = true
        playPauseButton.isEnabled = true
        updateFrameLabel()

        // PR-19: Enable mode toggle and start in preview
        modeToggle.isEnabled = true
        modeToggle.selectedSegmentIndex = 0
        editorController.enterPreview()

        // PR2: Configure timeline for editor mode
        configureEditorTimeline()

        // PR-20: Setup scene presets
        setupScenePresets(for: package)

        // PR-A: warmRender removed — was blocking draw via shared renderQueue.
        // Shader cache priming will be addressed in future PR if needed.

        log("Ready for playback!")
    }

    /// Configures scene presets based on loaded scene. Only variant_switch_demo has real presets.
    private func setupScenePresets(for package: ScenePackage) {
        if package.scene.sceneId == "scene_variant_switch_demo" {
            scenePresets = [
                SceneVariantPreset(id: "default", title: "Default", mapping: [:]),
                SceneVariantPreset(id: "style_a", title: "Style A",
                                   mapping: ["block_01": "v1", "block_02": "v1"]),
                SceneVariantPreset(id: "style_b", title: "Style B",
                                   mapping: ["block_01": "v2", "block_02": "v1"])
            ]
        } else {
            scenePresets = [
                SceneVariantPreset(id: "default", title: "Default", mapping: [:])
            ]
        }

        // Rebuild preset picker segments
        presetPicker.removeAllSegments()
        for (i, preset) in scenePresets.enumerated() {
            presetPicker.insertSegment(withTitle: preset.title, at: i, animated: false)
        }
        presetPicker.selectedSegmentIndex = 0
        // Debug-UI optimisation: hide if only "Default" preset — no useful choice to offer (lead fix #3)
        presetPicker.isHidden = scenePresets.count <= 1
    }
    #endif

    // MARK: - Load Pre-Compiled Template (Release Path - PR2)

    /// PR-D: Updates UI based on loading state.
    private func updateLoadingStateUI() {
        switch loadingState {
        case .idle:
            preparingOverlay.hide()
            playPauseButton.isEnabled = false
            frameSlider.isEnabled = false
            modeToggle.isEnabled = false

        case .preparing:
            preparingOverlay.reset()
            preparingOverlay.show(text: "Loading template...")
            playPauseButton.isEnabled = false
            frameSlider.isEnabled = false
            modeToggle.isEnabled = false

        case .ready:
            preparingOverlay.hide()
            playPauseButton.isEnabled = true
            frameSlider.isEnabled = true
            modeToggle.isEnabled = true

        case .failed(let message):
            preparingOverlay.showError(message)
            playPauseButton.isEnabled = false
            frameSlider.isEnabled = false
            modeToggle.isEnabled = false
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

        // Apply to state
        compiledScene = compiled
        scenePlayer = player
        editorController.setPlayer(player)
        textureProvider = provider
        currentResolver = resolver

        // Store canvas size
        canvasSize = compiled.runtime.canvasSize
        editorController.canvasSize = canvasSize
        updateMetalViewAspectRatio(width: canvasSize.width, height: canvasSize.height)

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
        frameSlider.maximumValue = Float(max(0, totalFrames - 1))
        frameSlider.value = 0
        frameSlider.isEnabled = true
        playPauseButton.isEnabled = true
        updateFrameLabel()

        // Setup mode toggle
        modeToggle.isEnabled = true
        modeToggle.selectedSegmentIndex = 0 // Preview mode

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

        // Apply to state
        compiledScene = compiled
        scenePlayer = player
        editorController.setPlayer(player)
        textureProvider = provider
        currentResolver = resolver

        // Store canvas size
        canvasSize = compiled.runtime.canvasSize
        editorController.canvasSize = canvasSize
        updateMetalViewAspectRatio(width: canvasSize.width, height: canvasSize.height)

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
        frameSlider.maximumValue = Float(max(0, totalFrames - 1))
        frameSlider.value = 0
        updateFrameLabel()

        // Enter ready state
        loadingState = .ready
        updateLoadingStateUI()

        modeToggle.selectedSegmentIndex = 0
        editorController.enterPreview()

        // PR2: Configure timeline for editor mode
        configureEditorTimeline()

        log("Ready for playback!")
        metalView.setNeedsDisplay()
    }

    // MARK: - Background Setup (PR3)

    /// Sets up background state from template and project override.
    private func setupBackgroundState(compiled: CompiledScene) {
        guard let templateId = currentTemplateId,
              let tp = textureProvider,
              let device = metalView.device,
              let queue = commandQueue else {
            log("[Background] Skipped: missing dependencies")
            return
        }

        // Create BackgroundTextureService
        backgroundTextureService = BackgroundTextureService(
            textureProvider: tp,
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
        exportTP: ExportTextureProvider
    ) async {
        guard let override = projectBackgroundOverride,
              let state = effectiveBackgroundState,
              let queue = commandQueue else { return }

        let presetId = state.preset.presetId
        let device = queue.device
        let service = BackgroundTextureService(
            textureProvider: exportTP,
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
        guard compiledScene != nil else { return }
        isPlaying = true
        updatePlayPauseButton()
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        let fps = Float(sceneFPS)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        displayLink?.add(to: .main, forMode: .common)
        // PR-33: Start video playback - use LOCAL frame from coordinator
        let localFrame = playbackCoordinator?.currentLocalFrame ?? currentFrameIndex
        userMediaService?.startVideoPlayback(sceneFrameIndex: localFrame)
        // PR2: Update editor layout play state
        editorLayoutContainer.setPlaying(true)
        fullScreenPreviewVC?.setPlaying(true)
    }

    private func stopPlayback() {
        isPlaying = false
        updatePlayPauseButton()
        displayLink?.invalidate()
        displayLink = nil
        editorController.setPlaying(false)
        // PR-33: Stop video playback (AVPlayer rate=0)
        userMediaService?.stopVideoPlayback()
        // PR2: Update editor layout play state
        editorLayoutContainer.setPlaying(false)
        fullScreenPreviewVC?.setPlaying(false)
    }

    private func updatePlayPauseButton() {
        var cfg = playPauseButton.configuration
        cfg?.title = isPlaying ? "Pause" : "Play"
        cfg?.baseBackgroundColor = isPlaying ? .systemOrange : .systemGreen
        playPauseButton.configuration = cfg
    }

    @objc private func displayLinkFired() {
        // Release v1: Calculate next time and dispatch through store
        guard let store = editorStore else {
            // Fallback for preview mode without store
            editorController.advanceFrame()
            currentFrameIndex = editorController.state.currentPreviewFrame
            return
        }

        let fps = store.state.templateFPS
        let frameDurationUs: TimeUs = 1_000_000 / TimeUs(fps)
        let currentTimeUs = store.playheadTimeUs
        let nextTimeUs = min(currentTimeUs + frameDurationUs, store.projectDurationUs)

        // Dispatch to store - onPlayheadChanged callback handles coordinator + redraw
        store.dispatch(.setPlayhead(timeUs: nextTimeUs, quantize: .playback))

        // Global frame for UI (timeline ruler, fullscreen position)
        let globalFrameIndex = Int(nextTimeUs * TimeUs(fps) / 1_000_000)

        // Update timeline/fullscreen position during playback
        if case .editor = presentationMode {
            editorLayoutContainer.setCurrentTimeUs(nextTimeUs)
            fullScreenPreviewVC?.setCurrentFrame(globalFrameIndex)
        }

        // PR-33: Gated video update - use LOCAL frame from coordinator
        let localFrame = playbackCoordinator?.currentLocalFrame ?? globalFrameIndex
        if let service = userMediaService,
           !service.blockIdsWithVideo.isEmpty,
           localFrame != lastVideoUpdateFrame {
            service.updateVideoFramesForPlayback(sceneFrameIndex: localFrame)
            lastVideoUpdateFrame = localFrame
        }

        // Auto-stop at end
        if nextTimeUs >= store.projectDurationUs {
            stopPlayback()
        }
    }

    private func updateFrameLabel() { frameLabel.text = "Frame: \(currentFrameIndex) / \(totalFrames)" }

    // MARK: - Logging

    private func log(_ message: String) {
        let ts = DateFormatter.logFormatter.string(from: Date())
        let line = "[\(ts)] \(message)"
        print(line)  // Console output for Xcode
        logTextView.text += line + "\n"
        let loc = max(0, logTextView.text.count - 1)
        logTextView.scrollRangeToVisible(NSRange(location: loc, length: 1))
    }

    #if DEBUG
    private func logPackageInfo(_ pkg: ScenePackage) {
        let scene = pkg.scene
        let canvas = scene.canvas
        let info = "v\(scene.schemaVersion), \(canvas.width)x\(canvas.height)@\(canvas.fps)fps"
        log("Scene loaded! \(info), \(canvas.durationFrames)f, \(scene.mediaBlocks.count) blocks")
    }

    private func logValidationReport(_ report: ValidationReport, title: String) {
        log("\(title): \(report.errors.count)E, \(report.warnings.count)W")
        for issue in report.issues {
            let tag = issue.severity == .error ? "E" : "W"
            log("[\(tag)] \(issue.code) \(issue.path) — \(issue.message)")
        }
    }
    #endif

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

        // PR1.5: Split timing - start
        #if DEBUG
        let tSemStart = CACurrentMediaTime()
        #endif

        // PR-A: Non-blocking wait for in-flight frame slot
        // If slot not available, drop frame to keep UI responsive
        let semResult = inFlightSemaphore.wait(timeout: .now())
        if semResult == .timedOut {
            // Frame drop: GPU is overloaded, skip this frame
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

        // Signal semaphore when GPU finishes this frame
        // PR1.3: Combined handler for semaphore + perf logging
        cmdBuf.addCompletedHandler { [weak self] cb in
            self?.inFlightSemaphore.signal()
            #if DEBUG
            // Capture GPU time for perf stats
            if let s = GPUFrameTime.fromCompleted(commandBuffer: cb) {
                self?.perfLogger.recordGPUSample(s.gpuMs)
            }
            #endif
        }

        #if DEBUG
        perfLogger.recordFrame()
        #endif

        // PR1.4: Measure draw CPU encode time
        #if DEBUG
        let drawT0 = CACurrentMediaTime()
        #endif

        // PR1.5: Split timing - commands generation start
        #if DEBUG
        var tCmdsEnd: CFAbsoluteTime = tSemEnd
        var tEncodeEnd: CFAbsoluteTime = tSemEnd
        #endif

        if let renderer = renderer,
           let compiled = compiledScene,
           let provider = textureProvider,
           canvasSize.width > 0 {
            // Use canvas size for RenderTarget (not individual anim size)
            let target = RenderTarget(
                texture: drawable.texture,
                drawableScale: Double(view.contentScaleFactor),
                animSize: canvasSize
            )

            // DIAGNOSTIC: Device header (one-time log per review.md section 5)
            // PR1.3: Guarded by kEnableRenderDiagnostics to avoid DRAW CPU spikes
            if kEnableRenderDiagnostics, !deviceHeaderLogged {
                deviceHeaderLogged = true
                let bounds = view.bounds
                let safe = view.safeAreaInsets
                let drawableSize = view.drawableSize
                let texW = drawable.texture.width
                let texH = drawable.texture.height
                DispatchQueue.main.async { [weak self] in
                    self?.log("--- DEVICE DIAGNOSTIC HEADER ---")
                    self?.log("view.bounds: \(Int(bounds.width))x\(Int(bounds.height))")
                    self?.log("safeAreaInsets: T=\(safe.top) B=\(safe.bottom) L=\(safe.left) R=\(safe.right)")
                    self?.log("drawableSize: \(Int(drawableSize.width))x\(Int(drawableSize.height))")
                    self?.log("texture size: \(texW)x\(texH)")
                    self?.log("canvasSize: \(Int(self?.canvasSize.width ?? 0))x\(Int(self?.canvasSize.height ?? 0))")
                    self?.log("target.animSize: \(Int(target.animSize.width))x\(Int(target.animSize.height))")
                    self?.log("contentScaleFactor: \(view.contentScaleFactor)")
                    self?.log("--- END DEVICE HEADER ---")
                }
            }

            // Release v1: Get render commands from coordinator (editor mode) or fallback
            let commands: [RenderCommand]
            if case .editor = presentationMode,
               let coordinatorCommands = playbackCoordinator?.currentRenderCommands(mode: .edit) {
                // Coordinator is single source of truth for editor mode
                commands = coordinatorCommands
            } else if let editorCommands = editorController.currentRenderCommands() {
                // Preview mode: use editor controller
                commands = editorCommands
            } else {
                // Fallback: direct scene render
                commands = compiled.runtime.renderCommands(sceneFrameIndex: currentFrameIndex)
            }

            // PR1.5: Split timing - commands generated
            #if DEBUG
            tCmdsEnd = CACurrentMediaTime()
            #endif

            // PR-30 DEBUG: Log layer visibility and render commands for polaroid_shared_demo
            // PR1.3: Guarded by kEnableRenderDiagnostics to avoid DRAW CPU spikes
            if kEnableRenderDiagnostics, currentFrameIndex == 0, compiled.runtime.scene.sceneId == "polaroid_shared_demo" {
                var debugLines: [String] = ["--- PR-30 DEBUG: Layer visibility ---"]
                for block in compiled.runtime.blocks {
                    if let variant = block.selectedVariant {
                        let animIR = variant.animIR
                        for (compId, comp) in animIR.comps {
                            for layer in comp.layers {
                                let hasMatte = layer.matte != nil
                                debugLines.append("[\(compId)] \(layer.name): isHidden=\(layer.isHidden), isMatteSource=\(layer.isMatteSource), hasMatte=\(hasMatte), toggleId=\(layer.toggleId ?? "nil")")
                            }
                        }
                    }
                }
                // Log render commands
                debugLines.append("--- RENDER COMMANDS ---")
                for (idx, cmd) in commands.enumerated() {
                    debugLines.append("[\(idx)] \(cmd)")
                }
                debugLines.append("--- END DEBUG ---")
                DispatchQueue.main.async { [weak self] in
                    debugLines.forEach { self?.log($0) }
                }
            }

            // DIAGNOSTIC: Log matte/shape commands every 30 frames (per review.md)
            // PR1.3: Guarded by kEnableRenderDiagnostics to avoid DRAW CPU spikes
            if kEnableRenderDiagnostics, currentFrameIndex % 30 == 0 {
                let hasMatteCommands = commands.contains { cmd in
                    if case .beginMatte = cmd { return true }
                    return false
                }
                let drawShapeFrames = commands.compactMap { cmd -> Double? in
                    if case .drawShape(_, _, _, _, let frame) = cmd { return frame }
                    return nil
                }
                let pathRegistryCount = compiled.pathRegistry.count
                let frameForLog = currentFrameIndex

                // Deep diagnostic: check if paths are actually animated
                var pathDiagnostics: [String] = []
                let registry = compiled.pathRegistry
                for cmd in commands {
                    if case .drawShape(let pathId, _, _, _, _) = cmd {
                        if let resource = registry.path(for: pathId) {
                            let animated = resource.isAnimated ? "ANIM" : "STATIC"
                            let kfCount = resource.keyframeCount
                            let times = resource.keyframeTimes
                            pathDiagnostics.append("pathId=\(pathId.value) \(animated) kf=\(kfCount) times=\(times)")
                        } else {
                            pathDiagnostics.append("pathId=\(pathId.value) NOT_FOUND")
                        }
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    self?.log("[DIAG] frame=\(frameForLog), hasMatte=\(hasMatteCommands), " +
                              "drawShapeFrames=\(drawShapeFrames), pathRegistry.count=\(pathRegistryCount)")
                    for diag in pathDiagnostics {
                        self?.log("[DIAG-PATH] \(diag)")
                    }
                }
            }

            // PR-A: Direct renderer call (no renderQueue.sync needed after warmRender removal)
            // dispatchPrecondition(.onQueue(.main)) at top ensures no reentrancy
            let assetSizes = mergedAssetSizes
            let pathRegistry = compiled.pathRegistry

            do {
                try renderer.draw(
                    commands: commands,
                    target: target,
                    textureProvider: provider,
                    commandBuffer: cmdBuf,
                    assetSizes: assetSizes,
                    pathRegistry: pathRegistry,
                    backgroundState: effectiveBackgroundState  // PR3
                )
                // PR1.5: Split timing - encode done
                #if DEBUG
                tEncodeEnd = CACurrentMediaTime()
                #endif
            } catch {
                if !renderErrorLogged {
                    renderErrorLogged = true
                    DispatchQueue.main.async { [weak self] in
                        self?.log("Render error: \(error)")
                    }
                }
            }
        } else if let desc = view.currentRenderPassDescriptor,
                  let enc = cmdBuf.makeRenderCommandEncoder(descriptor: desc) {
            enc.endEncoding()
        }
        cmdBuf.present(drawable)

        // PR1.4: Record draw CPU encode time
        #if DEBUG
        let drawDtMs = (CACurrentMediaTime() - drawT0) * 1000.0
        perfLogger.recordDrawCPU(ms: drawDtMs)

        // PR1.5: Record split timing
        let semMs = (tSemEnd - tSemStart) * 1000.0
        let cmdsMs = (tCmdsEnd - tSemEnd) * 1000.0
        let encodeMs = (tEncodeEnd - tCmdsEnd) * 1000.0
        perfLogger.recordSplitTiming(semaphoreMs: semMs, commandsMs: cmdsMs, encodeMs: encodeMs)
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
        // Pan/pinch/rotation only work in edit mode WITH a selected block
        if gestureRecognizer is UIPanGestureRecognizer ||
           gestureRecognizer is UIPinchGestureRecognizer ||
           gestureRecognizer is UIRotationGestureRecognizer {
            // Only enable if in edit mode AND block is selected
            return editorController.state.mode == .edit && editorController.state.selectedBlockId != nil
        }
        return true
    }
}

// MARK: - PHPickerViewControllerDelegate (PR-32)

extension PlayerViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let result = results.first else { return }

        // PR3: Check if this is a background image picker
        if picker.view.tag == 999, let regionId = pendingBackgroundRegionId {
            pendingBackgroundRegionId = nil
            handleBackgroundImagePicked(result: result, regionId: regionId)
            return
        }

        // User media picker
        guard let blockId = state.selectedBlockId else { return }

        // Check if it's an image or video
        if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
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
        } else if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
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
