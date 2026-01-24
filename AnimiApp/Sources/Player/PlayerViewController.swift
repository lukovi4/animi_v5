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

    private lazy var logTextView: UITextView = {
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
        view.layer.cornerRadius = 8
        view.clipsToBounds = true
        view.delegate = self
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        return view
    }()

    // MARK: - Properties

    private let loader = ScenePackageLoader()
    private let validator = SceneValidator()
    private var currentPackage: ScenePackage?
    private var isSceneValid = false

    // MARK: - Metal Resources

    private lazy var commandQueue: MTLCommandQueue? = {
        metalView.device?.makeCommandQueue()
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        log("AnimiApp initialized")
        log("TVECore version: \(TVECore.version)")
        log("Metal device: \(metalView.device?.name ?? "not available")")
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        view.addSubview(loadButton)
        view.addSubview(metalView)
        view.addSubview(logTextView)

        NSLayoutConstraint.activate([
            // Load button at top
            loadButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            loadButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            loadButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            loadButton.heightAnchor.constraint(equalToConstant: 44),

            // Metal view in the middle (16:9 aspect ratio container)
            metalView.topAnchor.constraint(equalTo: loadButton.bottomAnchor, constant: 16),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            metalView.heightAnchor.constraint(equalTo: metalView.widthAnchor, multiplier: 16.0 / 9.0),

            // Log text view at bottom
            logTextView.topAnchor.constraint(equalTo: metalView.bottomAnchor, constant: 16),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    // MARK: - Actions

    @objc private func loadTestPackageTapped() {
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
            let package = try loader.load(from: rootURL)
            currentPackage = package
            logPackageInfo(package)

            // Validate the scene
            let report = validator.validate(scene: package.scene)
            logValidationReport(report)

            isSceneValid = !report.hasErrors
            if report.hasErrors {
                log("Scene is invalid — rendering disabled")
            }

            metalView.setNeedsDisplay()
        } catch let error as ScenePackageLoadError {
            log("ERROR: \(error.localizedDescription)")
            isSceneValid = false
        } catch {
            log("ERROR: Unexpected error - \(error)")
            isSceneValid = false
        }
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
        log("Duration: \(canvas.durationFrames) frames (\(Double(canvas.durationFrames) / Double(canvas.fps))s)")
        log("Media blocks: \(scene.mediaBlocks.count)")

        for block in scene.mediaBlocks {
            let rect = block.rect
            log("  [\(block.id)] z=\(block.zIndex)")
            log("    rect: (\(Int(rect.x)),\(Int(rect.y))) \(Int(rect.width))x\(Int(rect.height))")
            log("    clip: \(block.containerClip)")
            log("    binding: \(block.input.bindingKey)")
            log("    variants: \(block.variants.count)")
            for variant in block.variants {
                log("      - \(variant.id): \(variant.animRef)")
            }
        }

        log("Anim files resolved: \(package.animFilesByRef.count)")
        for (ref, url) in package.animFilesByRef.sorted(by: { $0.key < $1.key }) {
            log("  \(ref) -> \(url.lastPathComponent)")
        }

        if let imagesURL = package.imagesRootURL {
            log("Images folder: \(imagesURL.lastPathComponent)")
        }
    }

    private func logValidationReport(_ report: ValidationReport) {
        log("---")
        log("Validation: \(report.errors.count) errors, \(report.warnings.count) warnings")

        for issue in report.issues {
            let severityTag = issue.severity == .error ? "[ERROR]" : "[WARN ]"
            log("\(severityTag) \(issue.code) \(issue.path) — \(issue.message)")
        }
    }
}

// MARK: - MTKViewDelegate

extension PlayerViewController: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle drawable size change - will be implemented in later PRs
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandQueue = commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        // Clear with background color (rendering will be added in later PRs)
        encoder.endEncoding()
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
