import UIKit
import TVECore

// MARK: - Transform Editor Delegate

protocol BackgroundImageTransformDelegate: AnyObject {
    /// Called when user confirms transform changes.
    func transformEditorDidConfirm(regionId: String, transform: BgImageTransformOverride)
    /// Called when user cancels editing.
    func transformEditorDidCancel(regionId: String)
}

// MARK: - Background Image Transform View Controller

/// Gesture-based editor for background image transform (pan/zoom/rotate).
/// Shows region preview with mask and allows interactive manipulation.
final class BackgroundImageTransformViewController: UIViewController {

    // MARK: - Properties

    weak var delegate: BackgroundImageTransformDelegate?

    private let regionId: String
    private let image: UIImage
    private let regionBbox: CGRect  // Region bounding box in canvas space
    private var currentTransform: BgImageTransformOverride

    // Gesture state
    private var initialPan: Point2 = .zero
    private var initialZoom: Double = 1.0
    private var initialRotation: Double = 0.0

    // MARK: - UI Components

    private lazy var containerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        view.clipsToBounds = true
        return view
    }()

    private lazy var imageView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        return iv
    }()

    private lazy var instructionLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Drag to pan, pinch to zoom, rotate with two fingers"
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private lazy var buttonsStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 12
        stack.distribution = .fillEqually
        return stack
    }()

    private lazy var fitModeButton: UIButton = {
        makeButton(title: "Fill", action: #selector(fitModeTapped))
    }()

    private lazy var flipXButton: UIButton = {
        makeButton(title: "Flip H", action: #selector(flipXTapped))
    }()

    private lazy var flipYButton: UIButton = {
        makeButton(title: "Flip V", action: #selector(flipYTapped))
    }()

    private lazy var resetButton: UIButton = {
        makeButton(title: "Reset", action: #selector(resetTapped))
    }()

    private lazy var cancelButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = "Cancel"
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var doneButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Done"
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        return btn
    }()

    // MARK: - Initialization

    init(
        regionId: String,
        image: UIImage,
        regionBbox: CGRect,
        currentTransform: BgImageTransformOverride
    ) {
        self.regionId = regionId
        self.image = image
        self.regionBbox = regionBbox
        self.currentTransform = currentTransform
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupGestures()
        updateImageTransform()
        updateButtonStates()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground
        title = "Edit Image"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )

        view.addSubview(containerView)
        containerView.addSubview(imageView)
        view.addSubview(instructionLabel)
        view.addSubview(buttonsStack)

        buttonsStack.addArrangedSubview(fitModeButton)
        buttonsStack.addArrangedSubview(flipXButton)
        buttonsStack.addArrangedSubview(flipYButton)
        buttonsStack.addArrangedSubview(resetButton)

        imageView.image = image

        // Calculate aspect ratio for container
        let aspectRatio = regionBbox.width / regionBbox.height

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.9),
            containerView.heightAnchor.constraint(equalTo: containerView.widthAnchor, multiplier: 1.0 / aspectRatio),

            imageView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: containerView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: containerView.heightAnchor),

            instructionLabel.topAnchor.constraint(equalTo: containerView.bottomAnchor, constant: 16),
            instructionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            buttonsStack.topAnchor.constraint(equalTo: instructionLabel.bottomAnchor, constant: 24),
            buttonsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttonsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttonsStack.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.cornerStyle = .medium
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    // MARK: - Gestures

    private func setupGestures() {
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))

        panGesture.delegate = self
        pinchGesture.delegate = self
        rotationGesture.delegate = self

        containerView.addGestureRecognizer(panGesture)
        containerView.addGestureRecognizer(pinchGesture)
        containerView.addGestureRecognizer(rotationGesture)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            initialPan = currentTransform.pan

        case .changed:
            let translation = gesture.translation(in: containerView)
            let containerSize = containerView.bounds.size

            // Convert pixel translation to normalized bbox space
            // Negative because pan subtracts from UV (dragging right moves image right)
            let deltaX = -Double(translation.x / containerSize.width)
            let deltaY = -Double(translation.y / containerSize.height)

            currentTransform.pan = Point2(
                x: initialPan.x + deltaX,
                y: initialPan.y + deltaY
            )
            updateImageTransform()

        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            initialZoom = currentTransform.zoom

        case .changed:
            // Scale multiplies zoom (pinch out = zoom in = larger zoom value)
            let newZoom = initialZoom * Double(gesture.scale)
            currentTransform.zoom = max(0.1, min(10.0, newZoom))  // Clamp to reasonable range
            updateImageTransform()

        default:
            break
        }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began:
            initialRotation = currentTransform.rotationRadians

        case .changed:
            currentTransform.rotationRadians = initialRotation + Double(gesture.rotation)
            updateImageTransform()

        default:
            break
        }
    }

    // MARK: - Transform Application

    private func updateImageTransform() {
        // Apply transform to imageView for preview
        var transform = CGAffineTransform.identity

        // Apply zoom
        let scale = CGFloat(currentTransform.zoom)
        transform = transform.scaledBy(x: scale, y: scale)

        // Apply rotation
        transform = transform.rotated(by: CGFloat(currentTransform.rotationRadians))

        // Apply flip
        let flipX: CGFloat = currentTransform.flipX ? -1.0 : 1.0
        let flipY: CGFloat = currentTransform.flipY ? -1.0 : 1.0
        transform = transform.scaledBy(x: flipX, y: flipY)

        // Apply pan (convert from normalized to view coordinates)
        let containerSize = containerView.bounds.size
        let panX = CGFloat(currentTransform.pan.x) * containerSize.width
        let panY = CGFloat(currentTransform.pan.y) * containerSize.height
        transform = transform.translatedBy(x: -panX / scale, y: -panY / scale)

        imageView.transform = transform
    }

    private func updateButtonStates() {
        let isFill = currentTransform.fitMode == "fill"
        fitModeButton.setTitle(isFill ? "Fill" : "Fit", for: .normal)

        flipXButton.configuration?.baseBackgroundColor = currentTransform.flipX ? .systemBlue : .systemGray5
        flipYButton.configuration?.baseBackgroundColor = currentTransform.flipY ? .systemBlue : .systemGray5
    }

    // MARK: - Actions

    @objc private func fitModeTapped() {
        currentTransform.fitMode = currentTransform.fitMode == "fill" ? "fit" : "fill"
        updateButtonStates()
        updateImageTransform()
    }

    @objc private func flipXTapped() {
        currentTransform.flipX.toggle()
        updateButtonStates()
        updateImageTransform()
    }

    @objc private func flipYTapped() {
        currentTransform.flipY.toggle()
        updateButtonStates()
        updateImageTransform()
    }

    @objc private func resetTapped() {
        currentTransform = .identity
        updateButtonStates()
        updateImageTransform()
    }

    @objc private func cancelTapped() {
        delegate?.transformEditorDidCancel(regionId: regionId)
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        delegate?.transformEditorDidConfirm(regionId: regionId, transform: currentTransform)
        dismiss(animated: true)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension BackgroundImageTransformViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow simultaneous pan, pinch, and rotation
        return true
    }
}
