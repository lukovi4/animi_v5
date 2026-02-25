import UIKit
import TVECore

// MARK: - Background Editor Delegate

/// Delegate protocol for background editor changes.
protocol BackgroundEditorDelegate: AnyObject {
    /// Called when the background state changes.
    func backgroundEditorDidUpdateState(_ state: EffectiveBackgroundState)

    /// Called when user selects an image for a region.
    func backgroundEditorDidRequestImagePicker(for regionId: String)

    /// Called when preset changes (for texture cleanup).
    func backgroundEditorDidChangePreset(oldPresetId: String, newPresetId: String)

    /// Called when editor is dismissed and changes should be saved.
    func backgroundEditorWillDismiss(override: ProjectBackgroundOverride, presetId: String)
}

// MARK: - Background Editor View Controller

/// View controller for editing background presets and region sources.
final class BackgroundEditorViewController: UIViewController {

    // MARK: - Properties

    weak var delegate: BackgroundEditorDelegate?

    private let presetLibrary: BackgroundPresetLibrary
    private var templateBackground: Background?
    private var currentOverride: ProjectBackgroundOverride
    private var currentPresetId: String

    /// Cached images for regions (for transform editor preview)
    private var regionImages: [String: UIImage] = [:]

    // MARK: - UI Components

    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.alwaysBounceVertical = true
        return sv
    }()

    private lazy var contentStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 24
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.isLayoutMarginsRelativeArrangement = true
        return stack
    }()

    private lazy var presetSectionLabel: UILabel = {
        makeSectionLabel("Preset")
    }()

    private lazy var presetPicker: UISegmentedControl = {
        let presets = presetLibrary.allPresets
        let items = presets.map { $0.title }
        let control = UISegmentedControl(items: items)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addTarget(self, action: #selector(presetChanged), for: .valueChanged)
        return control
    }()

    private lazy var regionsSectionLabel: UILabel = {
        makeSectionLabel("Regions")
    }()

    private lazy var regionsStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        return stack
    }()

    private lazy var doneButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Done"
        config.cornerStyle = .medium
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        return btn
    }()

    // MARK: - Initialization

    init(
        presetLibrary: BackgroundPresetLibrary,
        templateBackground: Background?,
        currentOverride: ProjectBackgroundOverride
    ) {
        self.presetLibrary = presetLibrary
        self.templateBackground = templateBackground
        self.currentOverride = currentOverride

        // Determine current preset ID
        if let overridePresetId = currentOverride.selectedPresetId {
            self.currentPresetId = overridePresetId
        } else if let background = templateBackground {
            self.currentPresetId = background.effectivePresetId
        } else {
            self.currentPresetId = BackgroundPresetLibrary.fallbackPresetId
        }

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updatePresetPicker()
        updateRegionsUI()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground
        title = "Background"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        contentStack.addArrangedSubview(presetSectionLabel)
        contentStack.addArrangedSubview(presetPicker)
        contentStack.addArrangedSubview(regionsSectionLabel)
        contentStack.addArrangedSubview(regionsStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    private func makeSectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.text = text
        return label
    }

    // MARK: - Preset Picker

    private func updatePresetPicker() {
        let presets = presetLibrary.allPresets
        if let index = presets.firstIndex(where: { $0.presetId == currentPresetId }) {
            presetPicker.selectedSegmentIndex = index
        } else {
            presetPicker.selectedSegmentIndex = 0
        }
    }

    @objc private func presetChanged() {
        let presets = presetLibrary.allPresets
        guard presetPicker.selectedSegmentIndex < presets.count else { return }

        let newPreset = presets[presetPicker.selectedSegmentIndex]

        // Clear old region overrides if preset changed
        if newPreset.presetId != currentPresetId {
            let oldPresetId = currentPresetId

            currentOverride.selectedPresetId = newPreset.presetId
            currentOverride.regions.removeAll()
            currentPresetId = newPreset.presetId

            // Notify delegate for texture cleanup
            delegate?.backgroundEditorDidChangePreset(
                oldPresetId: oldPresetId,
                newPresetId: newPreset.presetId
            )
        }

        updateRegionsUI()
        notifyStateChanged()
    }

    // MARK: - Regions UI

    private func updateRegionsUI() {
        // Clear existing region views
        regionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let preset = presetLibrary.preset(for: currentPresetId) else { return }

        for regionPreset in preset.regions {
            let regionView = makeRegionView(for: regionPreset)
            regionsStack.addArrangedSubview(regionView)
        }
    }

    private func makeRegionView(for regionPreset: BackgroundRegionPreset) -> UIView {
        let regionId = regionPreset.regionId
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 12

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.text = regionPreset.displayName

        let sourceControl = UISegmentedControl(items: ["Color", "Gradient", "Image"])
        sourceControl.translatesAutoresizingMaskIntoConstraints = false
        sourceControl.tag = regionPreset.regionId.hashValue
        sourceControl.addTarget(self, action: #selector(sourceTypeChanged(_:)), for: .valueChanged)

        // Determine current source type
        if let override = currentOverride.regions[regionId] {
            switch override.source {
            case .solid:
                sourceControl.selectedSegmentIndex = 0
            case .gradient:
                sourceControl.selectedSegmentIndex = 1
            case .image:
                sourceControl.selectedSegmentIndex = 2
            }
        } else {
            sourceControl.selectedSegmentIndex = 0  // Default to color
        }

        // Color/Image picker button
        let actionButton = UIButton(type: .system)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.setTitle("Configure...", for: .normal)
        actionButton.tag = regionPreset.regionId.hashValue
        actionButton.addTarget(self, action: #selector(configureRegionTapped(_:)), for: .touchUpInside)

        container.addSubview(titleLabel)
        container.addSubview(sourceControl)
        container.addSubview(actionButton)

        // Store regionId for lookup
        container.accessibilityIdentifier = regionId

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),

            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            sourceControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            sourceControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            sourceControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            actionButton.topAnchor.constraint(equalTo: sourceControl.bottomAnchor, constant: 12),
            actionButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            actionButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        return container
    }

    // MARK: - Region Actions

    @objc private func sourceTypeChanged(_ sender: UISegmentedControl) {
        guard let regionId = findRegionId(for: sender) else { return }

        let sourceType = sender.selectedSegmentIndex

        switch sourceType {
        case 0: // Color
            // Set default black color
            currentOverride.regions[regionId] = RegionOverride(
                source: .solid(colorHex: "#000000")
            )
        case 1: // Gradient
            // Set default vertical gradient using preset.canvasSize
            let preset = presetLibrary.preset(for: currentPresetId)
            let canvasHeight = preset?.canvasSize[1] ?? 1920
            let gradientOverride = GradientOverride(
                stops: [
                    GradientStopOverride(t: 0, colorHex: "#000000"),
                    GradientStopOverride(t: 1, colorHex: "#FFFFFF")
                ],
                p0: Point2(x: 0, y: 0),
                p1: Point2(x: 0, y: Double(canvasHeight))  // Vertical gradient
            )
            currentOverride.regions[regionId] = RegionOverride(
                source: .gradient(gradientOverride)
            )
        case 2: // Image
            // Request image picker from delegate
            delegate?.backgroundEditorDidRequestImagePicker(for: regionId)
        default:
            break
        }

        notifyStateChanged()
    }

    @objc private func configureRegionTapped(_ sender: UIButton) {
        guard let regionId = findRegionId(for: sender) else { return }

        // Check current source type
        if let override = currentOverride.regions[regionId] {
            switch override.source {
            case .solid:
                presentColorPicker(for: regionId, isGradient: false, stopIndex: nil)
            case .gradient:
                presentGradientEditor(for: regionId)
            case .image:
                delegate?.backgroundEditorDidRequestImagePicker(for: regionId)
            }
        } else {
            // Default to color picker
            presentColorPicker(for: regionId, isGradient: false, stopIndex: nil)
        }
    }

    private func findRegionId(for view: UIView) -> String? {
        var current: UIView? = view
        while let v = current {
            if let regionId = v.accessibilityIdentifier, !regionId.isEmpty {
                return regionId
            }
            current = v.superview
        }
        return nil
    }

    // MARK: - Color Picker

    private func presentColorPicker(for regionId: String, isGradient: Bool, stopIndex: Int?) {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = true
        picker.delegate = self

        // Store context for callback
        picker.view.accessibilityIdentifier = regionId
        picker.view.tag = isGradient ? (stopIndex ?? 0) + 1000 : 0

        // Set initial color
        if let override = currentOverride.regions[regionId] {
            switch override.source {
            case .solid(let colorHex):
                if let color = HexColorParser.parse(colorHex) {
                    picker.selectedColor = UIColor(
                        red: CGFloat(color.red),
                        green: CGFloat(color.green),
                        blue: CGFloat(color.blue),
                        alpha: CGFloat(color.alpha)
                    )
                }
            case .gradient(let gradient):
                if let index = stopIndex, index < gradient.stops.count {
                    if let color = HexColorParser.parse(gradient.stops[index].colorHex) {
                        picker.selectedColor = UIColor(
                            red: CGFloat(color.red),
                            green: CGFloat(color.green),
                            blue: CGFloat(color.blue),
                            alpha: CGFloat(color.alpha)
                        )
                    }
                }
            default:
                break
            }
        }

        present(picker, animated: true)
    }

    private func presentGradientEditor(for regionId: String) {
        let alert = UIAlertController(
            title: "Gradient",
            message: "Edit gradient colors",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "Start Color", style: .default) { [weak self] _ in
            self?.presentColorPicker(for: regionId, isGradient: true, stopIndex: 0)
        })

        alert.addAction(UIAlertAction(title: "End Color", style: .default) { [weak self] _ in
            self?.presentColorPicker(for: regionId, isGradient: true, stopIndex: 1)
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        present(alert, animated: true)
    }

    // MARK: - Image Configuration

    /// Called by PlayerViewController after image is selected and saved.
    /// Also stores the image for transform editor preview.
    func setImage(for regionId: String, mediaRef: MediaRef, image: UIImage? = nil) {
        let imageOverride = ImageOverride(
            mediaRef: mediaRef,
            transform: .identity
        )
        currentOverride.regions[regionId] = RegionOverride(
            source: .image(imageOverride)
        )

        // Store image for transform editor preview
        if let img = image {
            regionImages[regionId] = img
        }

        notifyStateChanged()
    }

    /// Opens gesture-based transform editor for an image region.
    func presentImageTransformEditor(for regionId: String) {
        guard let override = currentOverride.regions[regionId],
              case .image(let imageOverride) = override.source,
              let image = regionImages[regionId] else {
            return
        }

        // Get region bbox from preset
        guard let preset = presetLibrary.preset(for: currentPresetId),
              let regionPreset = preset.regions.first(where: { $0.regionId == regionId }) else {
            return
        }

        // Calculate bbox from mask vertices
        let vertices = regionPreset.mask.vertices
        let minX = vertices.map { $0.x }.min() ?? 0
        let minY = vertices.map { $0.y }.min() ?? 0
        let maxX = vertices.map { $0.x }.max() ?? 1
        let maxY = vertices.map { $0.y }.max() ?? 1
        let bbox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        let transformVC = BackgroundImageTransformViewController(
            regionId: regionId,
            image: image,
            regionBbox: bbox,
            currentTransform: imageOverride.transform
        )
        transformVC.delegate = self

        let nav = UINavigationController(rootViewController: transformVC)
        present(nav, animated: true)
    }

    // MARK: - State Updates

    private func notifyStateChanged() {
        guard let state = EffectiveBackgroundBuilder.build(
            templateBackground: templateBackground,
            projectOverride: currentOverride,
            presetLibrary: presetLibrary
        ) else { return }

        delegate?.backgroundEditorDidUpdateState(state)
    }

    // MARK: - Done Action

    @objc private func doneTapped() {
        delegate?.backgroundEditorWillDismiss(
            override: currentOverride,
            presetId: currentPresetId
        )
        dismiss(animated: true)
    }

    // MARK: - Public Access

    /// Returns the current override state.
    var override: ProjectBackgroundOverride {
        currentOverride
    }

    /// Returns the current preset ID.
    var presetId: String {
        currentPresetId
    }
}

// MARK: - UIColorPickerViewControllerDelegate

extension BackgroundEditorViewController: UIColorPickerViewControllerDelegate {

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard !continuously else { return }  // Only update on final selection

        guard let regionId = viewController.view.accessibilityIdentifier else { return }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let clearColor = ClearColor(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
        let colorHex = HexColorParser.toHex(clearColor, includeAlpha: a < 1.0)

        let isGradient = viewController.view.tag >= 1000
        let stopIndex = viewController.view.tag - 1000

        if isGradient {
            // Update gradient stop
            if var override = currentOverride.regions[regionId],
               case .gradient(var gradient) = override.source,
               stopIndex < gradient.stops.count {
                gradient.stops[stopIndex].colorHex = colorHex
                override.source = .gradient(gradient)
                currentOverride.regions[regionId] = override
            }
        } else {
            // Update solid color
            currentOverride.regions[regionId] = RegionOverride(
                source: .solid(colorHex: colorHex)
            )
        }

        notifyStateChanged()
    }
}

// MARK: - BackgroundImageTransformDelegate

extension BackgroundEditorViewController: BackgroundImageTransformDelegate {

    func transformEditorDidConfirm(regionId: String, transform: BgImageTransformOverride) {
        guard var override = currentOverride.regions[regionId],
              case .image(var imageOverride) = override.source else {
            return
        }

        // Update transform in image override
        imageOverride.transform = transform
        override.source = .image(imageOverride)
        currentOverride.regions[regionId] = override

        // Notify delegate to update main MetalView
        notifyStateChanged()
    }

    func transformEditorDidCancel(regionId: String) {
        // No changes needed - transform editor was dismissed without saving
    }
}
