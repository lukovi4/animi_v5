import UIKit
import MetalKit
import TVECore

/// Main player view controller with Metal rendering surface and debug log
final class PlayerViewController: UIViewController {

    // MARK: - UI Components

    private lazy var loadButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Load Test Package"
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(loadTestPackageTapped), for: .touchUpInside)
        return button
    }()

    private lazy var playPauseButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Play"
        config.cornerStyle = .medium
        config.baseBackgroundColor = .systemGreen
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        button.isEnabled = false
        return button
    }()

    private lazy var frameSlider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = 0
        slider.isEnabled = false
        slider.addTarget(self, action: #selector(frameSliderChanged), for: .valueChanged)
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
        let view = MTKView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
        view.colorPixelFormat = .bgra8Unorm
        view.layer.cornerRadius = 8
        view.clipsToBounds = true
        view.delegate = self
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        return view
    }()

    // MARK: - Package Loading Properties

    private let loader = ScenePackageLoader()
    private let sceneValidator = SceneValidator()
    private let animLoader = AnimLoader()
    private let animValidator = AnimValidator()
    private var currentPackage: ScenePackage?
    private var loadedAnimations: LoadedAnimations?
    private var isSceneValid = false
    private var isAnimValid = false

    // MARK: - Metal Renderer Properties

    private lazy var commandQueue: MTLCommandQueue? = {
        metalView.device?.makeCommandQueue()
    }()

    private var renderer: MetalRenderer?
    private var textureProvider: ScenePackageTextureProvider?
    private var animIR: AnimIR?
    private var currentFrameIndex: Int = 0
    private var totalFrames: Int = 0

    // MARK: - Playback Properties

    private var displayLink: CADisplayLink?
    private var isPlaying: Bool = false
    private var animationFPS: Double = 30.0

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupRenderer()
        log("AnimiApp initialized")
        log("TVECore version: \(TVECore.version)")
        log("Metal device: \(metalView.device?.name ?? "not available")")
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        view.addSubview(loadButton)
        view.addSubview(metalView)
        view.addSubview(controlsStack)
        view.addSubview(frameLabel)
        view.addSubview(logTextView)

        NSLayoutConstraint.activate([
            // Load button at top
            loadButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            loadButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            loadButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            loadButton.heightAnchor.constraint(equalToConstant: 44),

            // Metal view
            metalView.topAnchor.constraint(equalTo: loadButton.bottomAnchor, constant: 12),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            metalView.heightAnchor.constraint(equalTo: metalView.widthAnchor, multiplier: 16.0 / 9.0),

            // Controls stack
            controlsStack.topAnchor.constraint(equalTo: metalView.bottomAnchor, constant: 12),
            controlsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            playPauseButton.widthAnchor.constraint(equalToConstant: 80),

            // Frame label
            frameLabel.topAnchor.constraint(equalTo: controlsStack.bottomAnchor, constant: 4),
            frameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            frameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            // Log text view at bottom
            logTextView.topAnchor.constraint(equalTo: frameLabel.bottomAnchor, constant: 12),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    private func setupRenderer() {
        guard let device = metalView.device else {
            log("ERROR: No Metal device available")
            return
        }

        do {
            renderer = try MetalRenderer(
                device: device,
                colorPixelFormat: metalView.colorPixelFormat,
                options: MetalRendererOptions(
                    clearColor: ClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0),
                    enableWarningsForUnsupportedCommands: true
                )
            )
            log("MetalRenderer initialized")
        } catch {
            log("ERROR: Failed to create MetalRenderer: \(error)")
        }
    }

    // MARK: - Actions

    @objc private func loadTestPackageTapped() {
        // Stop playback if running
        stopPlayback()

        log("---")
        log("Loading test package...")

        guard let sceneURL = Bundle.main.url(
            forResource: "scene",
            withExtension: "json",
            subdirectory: "TestAssets/ScenePackages/example_4blocks"
        ) else {
            log("ERROR: Test package not found in bundle")
            log("Expected: TestAssets/ScenePackages/example_4blocks/scene.json")
            return
        }

        let rootURL = sceneURL.deletingLastPathComponent()
        log("Package root: \(rootURL.lastPathComponent)")

        do {
            try loadAndValidatePackage(from: rootURL)
        } catch let error as ScenePackageLoadError {
            log("ERROR: \(error.localizedDescription)")
            isSceneValid = false
            isAnimValid = false
        } catch let error as AnimLoadError {
            log("ERROR: \(error.localizedDescription)")
            isAnimValid = false
        } catch {
            log("ERROR: Unexpected error - \(error)")
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
        let frame = Int(frameSlider.value)
        currentFrameIndex = frame
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
        if sceneReport.hasErrors {
            log("Scene is invalid — rendering disabled")
            metalView.setNeedsDisplay()
            return
        }

        try loadAndValidateAnimations(for: package)
        try compileFirstAnimation(for: package)
        metalView.setNeedsDisplay()
    }

    private func loadAndValidateAnimations(for package: ScenePackage) throws {
        let loaded = try animLoader.loadAnimations(from: package)
        loadedAnimations = loaded
        log("Loaded \(loaded.lottieByAnimRef.count) animations")

        let animReport = animValidator.validate(scene: package.scene, package: package, loaded: loaded)
        logValidationReport(animReport, title: "AnimValidation")

        isAnimValid = !animReport.hasErrors
        if animReport.hasErrors {
            log("Animations invalid — rendering disabled")
        }
    }

    private func compileFirstAnimation(for package: ScenePackage) throws {
        guard isAnimValid,
              let loaded = loadedAnimations,
              let imagesURL = package.imagesRootURL,
              let device = metalView.device else {
            return
        }

        // Use first animation (anim-1.json)
        let animRef = "anim-1.json"
        guard let lottie = loaded.lottieByAnimRef[animRef],
              let assetIndex = loaded.assetIndexByAnimRef[animRef] else {
            log("ERROR: Animation '\(animRef)' not found")
            return
        }

        // Get binding key from first media block
        let bindingKey = package.scene.mediaBlocks.first?.input.bindingKey ?? "media"

        // Compile to AnimIR
        log("---")
        log("Compiling \(animRef) to AnimIR...")

        let compiler = AnimIRCompiler()
        do {
            animIR = try compiler.compile(
                lottie: lottie,
                animRef: animRef,
                bindingKey: bindingKey,
                assetIndex: assetIndex
            )

            if let ir = animIR {
                log("AnimIR compiled successfully")
                log("  Size: \(Int(ir.meta.width))x\(Int(ir.meta.height))")
                log("  FPS: \(ir.meta.fps)")
                log("  Frames: \(ir.meta.frameCount)")
                log("  Binding: \(ir.binding.bindingKey) -> layer \(ir.binding.boundLayerId)")

                // Setup texture provider
                let assetsIR = AssetIndexIR(from: assetIndex)
                textureProvider = ScenePackageTextureProvider(
                    device: device,
                    imagesRootURL: imagesURL,
                    assetIndex: assetsIR
                )

                // Configure playback controls
                totalFrames = ir.meta.frameCount
                animationFPS = ir.meta.fps
                currentFrameIndex = 0

                frameSlider.minimumValue = 0
                frameSlider.maximumValue = Float(max(0, totalFrames - 1))
                frameSlider.value = 0
                frameSlider.isEnabled = true
                playPauseButton.isEnabled = true

                updateFrameLabel()
                log("Ready for playback!")
            }
        } catch {
            log("ERROR: AnimIR compilation failed: \(error)")
        }
    }

    // MARK: - Playback

    private func startPlayback() {
        guard animIR != nil else { return }

        isPlaying = true
        updatePlayPauseButton()

        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(animationFPS),
            maximum: Float(animationFPS),
            preferred: Float(animationFPS)
        )
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopPlayback() {
        isPlaying = false
        updatePlayPauseButton()

        displayLink?.invalidate()
        displayLink = nil
    }

    private func updatePlayPauseButton() {
        var config = playPauseButton.configuration
        config?.title = isPlaying ? "Pause" : "Play"
        config?.baseBackgroundColor = isPlaying ? .systemOrange : .systemGreen
        playPauseButton.configuration = config
    }

    @objc private func displayLinkFired() {
        guard let ir = animIR else { return }

        // Advance frame
        currentFrameIndex = (currentFrameIndex + 1) % totalFrames
        frameSlider.value = Float(currentFrameIndex)
        updateFrameLabel()

        // Request redraw
        metalView.setNeedsDisplay()
    }

    private func updateFrameLabel() {
        frameLabel.text = "Frame: \(currentFrameIndex) / \(totalFrames)"
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"
        logTextView.text += logMessage

        // Auto-scroll to bottom
        let range = NSRange(location: logTextView.text.count - 1, length: 1)
        logTextView.scrollRangeToVisible(range)
    }

    private func logPackageInfo(_ package: ScenePackage) {
        let scene = package.scene
        let canvas = scene.canvas

        log("Scene loaded successfully!")
        log("Schema version: \(scene.schemaVersion)")
        if let sceneId = scene.sceneId {
            log("Scene ID: \(sceneId)")
        }
        log("Canvas: \(canvas.width)x\(canvas.height) @ \(canvas.fps)fps")
        log("Duration: \(canvas.durationFrames) frames")
        log("Media blocks: \(scene.mediaBlocks.count)")

        if let imagesURL = package.imagesRootURL {
            log("Images folder: \(imagesURL.lastPathComponent)")
        }
    }

    private func logValidationReport(_ report: ValidationReport, title: String) {
        log("---")
        log("\(title): \(report.errors.count) errors, \(report.warnings.count) warnings")

        for issue in report.issues {
            let severityTag = issue.severity == .error ? "[ERROR]" : "[WARN ]"
            log("\(severityTag) \(issue.code) \(issue.path) — \(issue.message)")
        }
    }
}

// MARK: - MTKViewDelegate

extension PlayerViewController: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Redraw on size change
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandQueue = commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // If we have AnimIR and renderer, render the frame
        if let renderer = renderer,
           var ir = animIR,
           let provider = textureProvider {
            // Generate render commands for current frame
            let commands = ir.renderCommands(frameIndex: currentFrameIndex)

            let target = RenderTarget(
                texture: drawable.texture,
                drawableScale: Double(view.contentScaleFactor),
                animSize: ir.meta.size
            )

            do {
                try renderer.draw(
                    commands: commands,
                    target: target,
                    textureProvider: provider,
                    commandBuffer: commandBuffer
                )
            } catch {
                // Log error but don't crash
                #if DEBUG
                print("[PlayerVC] Render error: \(error)")
                #endif
            }
        } else {
            // Fallback: just clear the screen
            guard let descriptor = view.currentRenderPassDescriptor,
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - DateFormatter Extension

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
