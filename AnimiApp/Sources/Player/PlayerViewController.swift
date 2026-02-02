import UIKit
import MetalKit
import TVECore

// MARK: - Scene Variant Preset (PR-20)

/// A named mapping of blockId -> variantId for scene-level style switching.
struct SceneVariantPreset {
    let id: String
    let title: String
    let mapping: [String: String]  // blockId -> variantId
}

/// Main player view controller with Metal rendering surface and debug log.
/// Supports full scene playback with multiple media blocks.
final class PlayerViewController: UIViewController {

    // MARK: - UI Components

    private lazy var sceneSelector: UISegmentedControl = {
        let control = UISegmentedControl(items: ["4 Blocks", "Alpha Matte", "Variant Demo"])
        control.translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegmentIndex = 0
        return control
    }()

    private lazy var loadButton: UIButton = {
        makeButton(title: "Load Scene", action: #selector(loadTestPackageTapped))
    }()

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
        control.isHidden = true
        return control
    }()

    /// Label shown above variant picker to indicate which block is selected.
    private lazy var variantLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.text = ""
        label.isHidden = true
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

    // MARK: - Properties

    private let loader = ScenePackageLoader()
    private let sceneValidator = SceneValidator()
    private let animLoader = AnimLoader()
    private let animValidator = AnimValidator()
    private var currentPackage: ScenePackage?
    private var loadedAnimations: LoadedAnimations?
    private var isSceneValid = false
    private var isAnimValid = false
    private lazy var commandQueue: MTLCommandQueue? = { metalView.device?.makeCommandQueue() }()
    private var renderer: MetalRenderer?
    private var textureProvider: ScenePackageTextureProvider?

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

    // MARK: - Editor (PR-19)
    private var scenePlayer: ScenePlayer?
    private let editorController = TemplateEditorController()
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        editorController.viewSize = metalView.bounds.size
        overlayView.canvasToView = editorController.canvasToViewTransform()
        // Lead fix #5: refresh overlay after layout change to prevent "jump"
        editorController.refreshOverlayIfNeeded()
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground
        [sceneSelector, loadButton, modeToggle, presetPicker, metalView, overlayView, variantLabel, variantPicker, controlsStack, frameLabel, logTextView].forEach { view.addSubview($0) }
        overlayView.translatesAutoresizingMaskIntoConstraints = false

        // MetalView constraints for normal mode
        // PR-20: metalView top anchors to presetPicker (which follows modeToggle)
        metalViewTopToLoadButtonConstraint = metalView.topAnchor.constraint(equalTo: presetPicker.bottomAnchor, constant: 8)
        metalViewTopToSafeAreaConstraint = metalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        metalViewTopToSafeAreaConstraint?.isActive = false

        // Height constraint with aspect ratio (default 16:9, will be updated when scene loads)
        metalViewHeightConstraint = metalView.heightAnchor.constraint(equalTo: metalView.widthAnchor, multiplier: 9.0 / 16.0)
        metalViewHeightConstraint?.priority = .defaultHigh

        // Bottom constraint for fullscreen mode
        metalViewBottomConstraint = metalView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        metalViewBottomConstraint?.isActive = false

        // Leading/trailing constraints (need references for fullscreen toggle)
        metalViewLeadingConstraint = metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16)
        metalViewTrailingConstraint = metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)

        NSLayoutConstraint.activate([
            sceneSelector.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            sceneSelector.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sceneSelector.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            loadButton.topAnchor.constraint(equalTo: sceneSelector.bottomAnchor, constant: 8),
            loadButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            loadButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            loadButton.heightAnchor.constraint(equalToConstant: 44),
            // PR-19: modeToggle between loadButton and metalView
            modeToggle.topAnchor.constraint(equalTo: loadButton.bottomAnchor, constant: 8),
            modeToggle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            modeToggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            // PR-20: presetPicker between modeToggle and metalView
            presetPicker.topAnchor.constraint(equalTo: modeToggle.bottomAnchor, constant: 6),
            presetPicker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            presetPicker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            metalViewTopToLoadButtonConstraint!,
            metalViewLeadingConstraint!,
            metalViewTrailingConstraint!,
            metalViewHeightConstraint!,
            // PR-19: overlayView pins to metalView (non-interactive, CAShapeLayer overlay)
            overlayView.topAnchor.constraint(equalTo: metalView.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            // PR-20: variant picker below metalView (edit mode only)
            variantLabel.topAnchor.constraint(equalTo: metalView.bottomAnchor, constant: 8),
            variantLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            variantLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            variantPicker.topAnchor.constraint(equalTo: variantLabel.bottomAnchor, constant: 4),
            variantPicker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            variantPicker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            controlsStack.topAnchor.constraint(equalTo: variantPicker.bottomAnchor, constant: 8),
            controlsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            playPauseButton.widthAnchor.constraint(equalToConstant: 80),
            frameLabel.topAnchor.constraint(equalTo: controlsStack.bottomAnchor, constant: 4),
            frameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            frameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logTextView.topAnchor.constraint(equalTo: frameLabel.bottomAnchor, constant: 12),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])

        // PR-19: All gestures on metalView (lead fix #1 — overlay is non-interactive)
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(metalViewTapped))
        metalView.addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation))
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

    @objc private func loadTestPackageTapped() {
        stopPlayback()
        renderErrorLogged = false
        log("---\nLoading scene package...")
        let sceneNames = ["example_4blocks", "alpha_matte_test", "variant_switch_demo"]
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
        }
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

        UIView.animate(withDuration: 0.3) { [self] in
            // Hide/show UI elements
            let hidden = isFullscreen
            sceneSelector.alpha = hidden ? 0 : 1
            loadButton.alpha = hidden ? 0 : 1
            modeToggle.alpha = hidden ? 0 : 1
            presetPicker.alpha = hidden ? 0 : 1
            variantLabel.alpha = hidden ? 0 : 1
            variantPicker.alpha = hidden ? 0 : 1
            controlsStack.alpha = hidden ? 0 : 1
            frameLabel.alpha = hidden ? 0 : 1
            logTextView.alpha = hidden ? 0 : 1

            // Toggle top constraint
            metalViewTopToLoadButtonConstraint?.isActive = !isFullscreen
            metalViewTopToSafeAreaConstraint?.isActive = isFullscreen

            // Toggle bottom constraint for fullscreen
            metalViewBottomConstraint?.isActive = isFullscreen

            // Update corner radius
            metalView.layer.cornerRadius = isFullscreen ? 0 : 8

            // Update leading/trailing margins
            metalViewLeadingConstraint?.constant = isFullscreen ? 0 : 16
            metalViewTrailingConstraint?.constant = isFullscreen ? 0 : -16

            view.layoutIfNeeded()
        }

        // Update status bar
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Syncs UI controls with editor state (called from controller's onStateChanged callback).
    private func syncUIWithState(_ state: TemplateEditorState) {
        let isPreview = state.mode == .preview
        playPauseButton.isHidden = !isPreview
        frameSlider.isHidden = !isPreview
        frameLabel.isHidden = !isPreview

        frameLabel.text = "Frame: \(state.currentPreviewFrame) / \(totalFrames)"
        frameSlider.value = Float(state.currentPreviewFrame)

        overlayView.isHidden = isPreview

        // PR-20: variant picker — only in edit mode with a selected block that has 2+ variants
        updateVariantPickerUI(state: state)
    }

    /// Rebuilds variant picker segments and selection for current state.
    private func updateVariantPickerUI(state: TemplateEditorState) {
        let variants = editorController.selectedBlockVariants()
        let showPicker = state.mode == .edit
            && state.selectedBlockId != nil
            && variants.count > 1

        variantLabel.isHidden = !showPicker
        variantPicker.isHidden = !showPicker

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

    // MARK: - Package Loading

    private func loadAndValidatePackage(from rootURL: URL) throws {
        let package = try loader.load(from: rootURL)
        currentPackage = package
        logPackageInfo(package)
        let sceneReport = sceneValidator.validate(scene: package.scene)
        logValidationReport(sceneReport, title: "SceneValidation")
        isSceneValid = !sceneReport.hasErrors
        guard isSceneValid else { log("Scene invalid"); metalView.setNeedsDisplay(); return }
        try loadAndValidateAnimations(for: package)
        try compileScene(for: package)
        metalView.setNeedsDisplay()
    }

    private func loadAndValidateAnimations(for package: ScenePackage) throws {
        let loaded = try animLoader.loadAnimations(from: package)
        loadedAnimations = loaded
        log("Loaded \(loaded.lottieByAnimRef.count) animations")
        let report = animValidator.validate(scene: package.scene, package: package, loaded: loaded)
        logValidationReport(report, title: "AnimValidation")
        isAnimValid = !report.hasErrors
        if report.hasErrors { log("Animations invalid") }
    }

    private func compileScene(for package: ScenePackage) throws {
        guard isAnimValid,
              let loaded = loadedAnimations,
              let device = metalView.device else { return }

        log("---\nCompiling scene...")

        // Create and compile scene player
        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: loaded)
        compiledScene = compiled

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

        // Create texture provider for entire scene
        textureProvider = SceneTextureProviderFactory.create(
            device: device,
            package: package,
            mergedAssetIndex: compiled.mergedAssetIndex,
            logger: { [weak self] msg in self?.log(msg) }
        )

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

        // One-time diagnostic: check textures
        for (assetId, _) in compiled.mergedAssetIndex.byId {
            if let tex = textureProvider?.texture(for: assetId) {
                log("Texture: \(assetId) [\(tex.width)x\(tex.height)]")
            } else {
                log("WARNING: Texture MISSING: \(assetId)")
            }
        }

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

        log("Ready for playback!")
    }

    // MARK: - Scene Presets (PR-20)

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

    // MARK: - Playback

    private func startPlayback() {
        guard compiledScene != nil else { return }
        isPlaying = true
        updatePlayPauseButton()
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        let fps = Float(sceneFPS)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopPlayback() {
        isPlaying = false
        updatePlayPauseButton()
        displayLink?.invalidate()
        displayLink = nil
        editorController.setPlaying(false)
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
}

// MARK: - MTKViewDelegate

extension PlayerViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

    func draw(in view: MTKView) {
        // Wait for in-flight frame slot (prevents GPU falling behind > maxFramesInFlight)
        _ = inFlightSemaphore.wait(timeout: .distantFuture)

        guard let drawable = view.currentDrawable,
              let cmdQueue = commandQueue,
              let cmdBuf = cmdQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        // Signal semaphore when GPU finishes this frame
        cmdBuf.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

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
            if !deviceHeaderLogged {
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

            // DIAGNOSTIC: Log matte/shape commands every 30 frames (per review.md)
            if currentFrameIndex % 30 == 0 {
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

            do {
                try renderer.draw(
                    commands: commands,
                    target: target,
                    textureProvider: provider,
                    commandBuffer: cmdBuf,
                    assetSizes: mergedAssetSizes,
                    pathRegistry: compiled.pathRegistry
                )
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
        cmdBuf.commit()
    }
}

// MARK: - UIGestureRecognizerDelegate (PR-19)

extension PlayerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow pinch + rotation simultaneously
        let isPinchOrRotation = gestureRecognizer is UIPinchGestureRecognizer ||
                                gestureRecognizer is UIRotationGestureRecognizer
        let otherIsPinchOrRotation = otherGestureRecognizer is UIPinchGestureRecognizer ||
                                     otherGestureRecognizer is UIRotationGestureRecognizer
        return isPinchOrRotation && otherIsPinchOrRotation
    }
}

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
