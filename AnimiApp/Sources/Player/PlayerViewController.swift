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

/// Main player view controller with Metal rendering surface and debug log.
/// Supports full scene playback with multiple media blocks.
final class PlayerViewController: UIViewController {

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
        ("polaroid_shared_demo", "Polaroid")
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

    /// Add video button.
    private lazy var addVideoButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Add Video"
        config.cornerStyle = .medium
        config.baseBackgroundColor = .systemPurple
        config.image = UIImage(systemName: "video")
        config.imagePadding = 4
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(addVideoTapped), for: .touchUpInside)
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
    private var renderErrorLogged = false
    private var deviceHeaderLogged = false
    /// PR-33: Track last frame to avoid redundant video updates
    private var lastVideoUpdateFrame: Int = -1

    // MARK: - Editor (PR-19)
    private var scenePlayer: ScenePlayer?
    private let editorController = TemplateEditorController()

    // MARK: - User Media (PR-32)
    private var userMediaService: UserMediaService?
    private lazy var overlayView = EditorOverlayView()
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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupRenderer()
        wireEditorController()
        let deviceName = metalView.device?.name ?? "N/A"
        log("AnimiApp initialized, TVECore: \(TVECore.version), Metal: \(deviceName)")

        // PR4: Auto-load default template on startup
        // In Release builds, load pre-compiled template automatically
        // In Debug builds, user can select and load via Load Scene button
        #if !DEBUG
        loadCompiledTemplateFromBundle(templateName: "example_4blocks")
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        perfLogger.start()
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if DEBUG
        perfLogger.stop()
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        editorController.viewSize = metalView.bounds.size
        overlayView.canvasToView = editorController.canvasToViewTransform()
        // Lead fix #5: refresh overlay after layout change to prevent "jump"
        editorController.refreshOverlayIfNeeded()
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
        #if DEBUG
        [sceneSelector, loadButton].forEach { contentView.addSubview($0) }
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
        [addPhotoButton, addVideoButton, clearMediaButton].forEach { userMediaStack.addArrangedSubview($0) }
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

            templateSelector.topAnchor.constraint(equalTo: loadButton.bottomAnchor, constant: 8),
            templateSelector.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            templateSelector.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            modeToggle.topAnchor.constraint(equalTo: templateSelector.bottomAnchor, constant: 8),
            modeToggle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            modeToggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
        #else
        // RELEASE: templateSelector at top, then modeToggle
        NSLayoutConstraint.activate([
            templateSelector.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            templateSelector.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            templateSelector.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            modeToggle.topAnchor.constraint(equalTo: templateSelector.bottomAnchor, constant: 8),
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
            logTextView.heightAnchor.constraint(equalToConstant: 150),
            logTextView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        // Remove corner radius from metalView (full-width, no rounding)
        metalView.layer.cornerRadius = 0
        metalView.clipsToBounds = false

        // PR-19: All gestures on metalView
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(metalViewTapped))
        metalView.addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation))
        panGesture.delegate = self
        pinchGesture.delegate = self
        rotationGesture.delegate = self
        metalView.addGestureRecognizer(panGesture)
        metalView.addGestureRecognizer(pinchGesture)
        metalView.addGestureRecognizer(rotationGesture)
    }

    /// Wires editor controller callbacks. Called once from viewDidLoad.
    private func wireEditorController() {
        editorController.setOverlayView(overlayView)

        editorController.onNeedsDisplay = { [weak self] in
            self?.metalView.setNeedsDisplay()
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
        // PR-19: In edit mode, tap does hit-test for block selection
        if editorController.state.mode == .edit {
            let point = recognizer.location(in: metalView)
            editorController.handleTap(viewPoint: point)
            return
        }
        // Preview mode: toggle fullscreen
        toggleFullscreen()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        editorController.handlePan(recognizer)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        editorController.handlePinch(recognizer)
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        editorController.handleRotation(recognizer)
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
    }

    // MARK: - User Media UI (PR-32)

    /// Shows/hides user media section based on state.
    private func updateUserMediaUI(state: TemplateEditorState) {
        // Show user media controls only in edit mode with a selected block that has binding layer
        let hasBinding: Bool
        if let blockId = state.selectedBlockId, let player = scenePlayer {
            hasBinding = player.bindingAssetId(blockId: blockId) != nil
        } else {
            hasBinding = false
        }
        let showUserMedia = state.mode == .edit && hasBinding

        // Hide entire container (UIStackView auto-collapses)
        userMediaContainer.isHidden = !showUserMedia

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

    @objc private func addVideoTapped() {
        guard state.selectedBlockId != nil else { return }
        presentPhotoPicker(for: .videos)
    }

    @objc private func clearMediaTapped() {
        guard let blockId = state.selectedBlockId else { return }
        userMediaService?.clear(blockId: blockId)
        updateUserMediaStatusLabel()
        metalView.setNeedsDisplay()
        log("[UserMedia] Cleared media for block '\(blockId)'")
    }

    private func presentPhotoPicker(for filter: PHPickerFilter) {
        var config = PHPickerConfiguration()
        config.filter = filter
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
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
        provider.preloadAll()
        if let stats = provider.lastPreloadStats {
            log(String(format: "[Preload] loaded: %d, missing: %d, skipped: %d, duration: %.1fms",
                       stats.loadedCount, stats.missingCount, stats.skippedBindingCount, stats.durationMs))
        }

        // PR-32: Create UserMediaService for photo/video injection
        if let tp = textureProvider {
            userMediaService = UserMediaService(
                device: device,
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

                let provider: ScenePackageTextureProvider = await MainActor.run {
                    SceneTextureProviderFactory.create(
                        device: device,
                        mergedAssetIndex: sceneSetupResult.compiled.mergedAssetIndex,
                        resolver: result.resolver,
                        bindingAssetIds: sceneSetupResult.compiled.bindingAssetIds,
                        logger: { [weak self] msg in
                            Task { @MainActor in self?.log(msg) }
                        }
                    )
                }

                // Preload on background (PR-D: safe because draw not running)
                // PR-D.1: Use child Task so cancellation propagates
                try await Task(priority: .userInitiated) {
                    try Task.checkCancellation()
                    provider.preloadAll()
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
        if let tp = textureProvider {
            userMediaService = UserMediaService(
                device: metalView.device!,
                scenePlayer: player,
                textureProvider: tp
            )
            userMediaService?.setSceneFPS(Double(compiled.runtime.fps))
            userMediaService?.onNeedsDisplay = { [weak self] in
                self?.metalView.setNeedsDisplay()
            }
            log("UserMediaService initialized")
        }

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

        log("Ready for playback!")
        metalView.setNeedsDisplay()
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
        // PR-33: Start video playback (AVPlayer rate=1)
        userMediaService?.startVideoPlayback(sceneFrameIndex: currentFrameIndex)
    }

    private func stopPlayback() {
        isPlaying = false
        updatePlayPauseButton()
        displayLink?.invalidate()
        displayLink = nil
        editorController.setPlaying(false)
        // PR-33: Stop video playback (AVPlayer rate=0)
        userMediaService?.stopVideoPlayback()
    }

    private func updatePlayPauseButton() {
        var cfg = playPauseButton.configuration
        cfg?.title = isPlaying ? "Pause" : "Play"
        cfg?.baseBackgroundColor = isPlaying ? .systemOrange : .systemGreen
        playPauseButton.configuration = cfg
    }

    @objc private func displayLinkFired() {
        editorController.advanceFrame(totalFrames: totalFrames)
        // Also update VC's local frame tracking for legacy compatibility
        currentFrameIndex = editorController.state.currentPreviewFrame

        // PR-33: Gated video update (playback mode, no seek per frame)
        // Only update if:
        // 1. Playing (isPlaying = true)
        // 2. Has video blocks
        // 3. Frame changed since last update
        if let service = userMediaService,
           !service.blockIdsWithVideo.isEmpty,
           currentFrameIndex != lastVideoUpdateFrame {
            service.updateVideoFramesForPlayback(sceneFrameIndex: currentFrameIndex)
            lastVideoUpdateFrame = currentFrameIndex
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

            // PR-19: Get render commands from editor controller (mode-aware)
            let commands: [RenderCommand]
            if let editorCommands = editorController.currentRenderCommands() {
                commands = editorCommands
            } else {
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
                    pathRegistry: pathRegistry
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

        guard let result = results.first,
              let blockId = state.selectedBlockId else { return }

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
                    let success = self.userMediaService?.setPhoto(blockId: blockId, image: image) ?? false
                    if success {
                        self.log("[UserMedia] Photo set for block '\(blockId)'")
                    } else {
                        self.log("[UserMedia] Failed to set photo for block '\(blockId)'")
                    }
                    self.updateUserMediaStatusLabel()
                    self.metalView.setNeedsDisplay()
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
                    let success = self.userMediaService?.setVideo(blockId: blockId, tempURL: tempURL) ?? false
                    if success {
                        self.log("[UserMedia] Video set for block '\(blockId)' (async poster pending)")
                    } else {
                        self.log("[UserMedia] Failed to set video for block '\(blockId)'")
                        // Clean up temp file on failure
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    self.updateUserMediaStatusLabel()
                    self.metalView.setNeedsDisplay()
                }
            }
        }
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
