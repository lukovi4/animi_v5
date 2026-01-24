import UIKit
import MetalKit
import TVECore

/// Main player view controller with Metal rendering surface and debug log
final class PlayerViewController: UIViewController {

    // MARK: - UI Components

    private lazy var loadButton: UIButton = {
        makeButton(title: "Load Test Package", action: #selector(loadTestPackageTapped))
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
    private var animIR: AnimIR?
    private var currentFrameIndex = 0
    private var totalFrames = 0
    private var displayLink: CADisplayLink?
    private var isPlaying = false
    private var animationFPS = 30.0

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
                options: MetalRendererOptions(clearColor: clearCol)
            )
            log("MetalRenderer initialized")
        } catch { log("ERROR: MetalRenderer failed: \(error)") }
    }

    // MARK: - Actions

    @objc private func loadTestPackageTapped() {
        stopPlayback()
        log("---\nLoading test package...")
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
        try compileFirstAnimation(for: package)
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

    private func compileFirstAnimation(for package: ScenePackage) throws {
        guard isAnimValid,
              let loaded = loadedAnimations,
              let imagesURL = package.imagesRootURL,
              let device = metalView.device else { return }
        let animRef = "anim-1.json"
        guard let lottie = loaded.lottieByAnimRef[animRef],
              let assetIndex = loaded.assetIndexByAnimRef[animRef] else {
            log("ERROR: Animation '\(animRef)' not found"); return
        }
        let bindingKey = package.scene.mediaBlocks.first?.input.bindingKey ?? "media"
        log("---\nCompiling \(animRef)...")
        let compiler = AnimIRCompiler()
        do {
            animIR = try compiler.compile(
                lottie: lottie, animRef: animRef, bindingKey: bindingKey, assetIndex: assetIndex
            )
            guard let ir = animIR else { return }
            let size = "\(Int(ir.meta.width))x\(Int(ir.meta.height))"
            log("AnimIR: \(size) @ \(ir.meta.fps)fps, \(ir.meta.frameCount) frames")
            let assetsIR = AssetIndexIR(from: assetIndex)
            textureProvider = ScenePackageTextureProvider(
                device: device, imagesRootURL: imagesURL, assetIndex: assetsIR
            )
            totalFrames = ir.meta.frameCount
            animationFPS = ir.meta.fps
            currentFrameIndex = 0
            frameSlider.maximumValue = Float(max(0, totalFrames - 1))
            frameSlider.value = 0
            frameSlider.isEnabled = true
            playPauseButton.isEnabled = true
            updateFrameLabel()
            log("Ready for playback!")
        } catch { log("ERROR: Compile failed: \(error)") }
    }

    // MARK: - Playback

    private func startPlayback() {
        guard animIR != nil else { return }
        isPlaying = true
        updatePlayPauseButton()
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        let fps = Float(animationFPS)
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
        logTextView.text += "[\(ts)] \(message)\n"
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

        if let renderer = renderer, var ir = animIR, let provider = textureProvider {
            let target = RenderTarget(
                texture: drawable.texture,
                drawableScale: Double(view.contentScaleFactor),
                animSize: ir.meta.size
            )
            let commands = ir.renderCommands(frameIndex: currentFrameIndex)
            try? renderer.draw(
                commands: commands, target: target, textureProvider: provider, commandBuffer: cmdBuf
            )
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
