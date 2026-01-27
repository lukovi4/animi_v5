import UIKit
import MetalKit
import TVECore

/// Main player view controller with Metal rendering surface and debug log.
/// Supports full scene playback with multiple media blocks.
final class PlayerViewController: UIViewController {

    // MARK: - UI Components

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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupRenderer()
        let deviceName = metalView.device?.name ?? "N/A"
        log("AnimiApp initialized, TVECore: \(TVECore.version), Metal: \(deviceName)")
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground
        [loadButton, metalView, controlsStack, frameLabel, logTextView].forEach { view.addSubview($0) }
        NSLayoutConstraint.activate([
            loadButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            loadButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            loadButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            loadButton.heightAnchor.constraint(equalToConstant: 44),
            metalView.topAnchor.constraint(equalTo: loadButton.bottomAnchor, constant: 12),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            metalView.heightAnchor.constraint(equalTo: metalView.widthAnchor, multiplier: 16.0 / 9.0),
            controlsStack.topAnchor.constraint(equalTo: metalView.bottomAnchor, constant: 12),
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
    }

    private func setupRenderer() {
        guard let device = metalView.device else { log("ERROR: No Metal device"); return }
        do {
            let clearCol = ClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
            renderer = try MetalRenderer(
                device: device,
                colorPixelFormat: metalView.colorPixelFormat,
                options: MetalRendererOptions(clearColor: clearCol, enableDiagnostics: true)
            )
            log("MetalRenderer initialized")
        } catch { log("ERROR: MetalRenderer failed: \(error)") }
    }

    // MARK: - Actions

    @objc private func loadTestPackageTapped() {
        stopPlayback()
        renderErrorLogged = false
        log("---\nLoading scene package...")
        let subdir = "TestAssets/ScenePackages/example_4blocks"
        guard let url = Bundle.main.url(forResource: "scene", withExtension: "json", subdirectory: subdir) else {
            log("ERROR: Test package not found"); return
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
        } else {
            startPlayback()
        }
    }

    @objc private func frameSliderChanged() {
        currentFrameIndex = Int(frameSlider.value)
        updateFrameLabel()
        metalView.setNeedsDisplay()
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

        // Store canvas size for render target
        canvasSize = compiled.runtime.canvasSize

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
        log("Ready for playback!")
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
    }

    private func updatePlayPauseButton() {
        var cfg = playPauseButton.configuration
        cfg?.title = isPlaying ? "Pause" : "Play"
        cfg?.baseBackgroundColor = isPlaying ? .systemOrange : .systemGreen
        playPauseButton.configuration = cfg
    }

    @objc private func displayLinkFired() {
        currentFrameIndex = (currentFrameIndex + 1) % totalFrames
        frameSlider.value = Float(currentFrameIndex)
        updateFrameLabel()
        metalView.setNeedsDisplay()
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
        guard let drawable = view.currentDrawable,
              let cmdQueue = commandQueue,
              let cmdBuf = cmdQueue.makeCommandBuffer() else { return }

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

            // Get render commands for current scene frame
            let commands = compiled.runtime.renderCommands(sceneFrameIndex: currentFrameIndex)

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

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
