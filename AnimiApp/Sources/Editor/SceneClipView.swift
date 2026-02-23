import UIKit

// MARK: - Scene Clip View (PR2: Multi-scene + Trim handles)

/// Represents a single scene clip on the timeline.
/// Shows the clip body with optional trim handles when selected.
/// Handles are 44pt touch targets with 10pt visual indicator.
final class SceneClipView: UIView {

    // MARK: - Callbacks

    /// Called when clip is tapped (for selection).
    var onSelect: (() -> Void)?

    /// Called when trailing handle is dragged.
    /// Parameter is the new duration in microseconds.
    var onTrimTrailing: ((TimeUs, InteractionPhase) -> Void)?

    // MARK: - Configuration

    let sceneId: UUID
    private(set) var durationUs: TimeUs
    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var isSelected: Bool = false

    // MARK: - Constants

    private let handleTouchWidth: CGFloat = 44
    private let handleVisualWidth: CGFloat = 10
    private let cornerRadius: CGFloat = 8

    /// PR2 fix: Configurable min duration (set via configure, default ~1 frame at 30fps)
    private var minDurationUs: TimeUs = 33_333

    // MARK: - Appearance

    private let normalColor: UIColor = .systemBlue
    private let selectedColor: UIColor = .systemCyan
    private let handleColor: UIColor = .white
    private let labelColor: UIColor = .white

    // MARK: - Subviews

    private lazy var bodyView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = normalColor
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        return view
    }()

    private lazy var iconImageView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.image = UIImage(systemName: "film")
        iv.tintColor = labelColor
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Scene"
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = labelColor
        return label
    }()

    /// Trailing handle (44pt touch target, visible only when selected)
    private lazy var trailingHandle: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.isHidden = true

        // Visual indicator inside the touch target
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = handleColor
        pill.layer.cornerRadius = 3
        view.addSubview(pill)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            pill.widthAnchor.constraint(equalToConstant: handleVisualWidth),
            pill.heightAnchor.constraint(equalToConstant: 30)
        ])

        return view
    }()

    // MARK: - Gestures

    private lazy var tapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        return gesture
    }()

    /// PR2 fix: Exposed for require(toFail:) setup with scrollView pan
    private(set) lazy var trailingPanGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleTrailingPan(_:)))
        return gesture
    }()

    // MARK: - State

    private var initialDurationUs: TimeUs = 0
    private var initialPanLocation: CGFloat = 0

    // MARK: - Initialization

    init(sceneId: UUID, durationUs: TimeUs) {
        self.sceneId = sceneId
        self.durationUs = durationUs
        super.init(frame: .zero)
        setupViews()
        setupConstraints()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        addSubview(bodyView)
        bodyView.addSubview(iconImageView)
        bodyView.addSubview(titleLabel)
        addSubview(trailingHandle)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Body fills the clip view with insets
            bodyView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bodyView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            // Icon
            iconImageView.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: 8),
            iconImageView.centerYAnchor.constraint(equalTo: bodyView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),

            // Title
            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: bodyView.centerYAnchor),

            // Trailing handle - positioned at trailing edge, 44pt wide
            trailingHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingHandle.topAnchor.constraint(equalTo: topAnchor),
            trailingHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingHandle.widthAnchor.constraint(equalToConstant: handleTouchWidth)
        ])
    }

    private func setupGestures() {
        bodyView.addGestureRecognizer(tapGesture)
        trailingHandle.addGestureRecognizer(trailingPanGesture)
    }

    // MARK: - Configuration

    /// PR2 fix: Added minDurationUs parameter (calculated from templateFPS)
    func configure(durationUs: TimeUs, pxPerSecond: CGFloat, minDurationUs: TimeUs) {
        self.durationUs = durationUs
        self.pxPerSecond = pxPerSecond
        self.minDurationUs = minDurationUs
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        trailingHandle.isHidden = !selected

        UIView.animate(withDuration: 0.2) {
            self.bodyView.backgroundColor = selected ? self.selectedColor : self.normalColor
            self.bodyView.transform = selected ? CGAffineTransform(scaleX: 1.0, y: 1.02) : .identity
        }
    }

    func setPxPerSecond(_ pps: CGFloat) {
        pxPerSecond = pps
    }

    // MARK: - Computed

    /// Width in pixels based on duration and pxPerSecond
    var clipWidth: CGFloat {
        let seconds = CGFloat(usToSeconds(durationUs))
        return seconds * pxPerSecond
    }

    // MARK: - Gesture Handlers

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        onSelect?()
    }

    @objc private func handleTrailingPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            initialDurationUs = durationUs
            initialPanLocation = recognizer.location(in: superview).x
            onTrimTrailing?(durationUs, .began)

        case .changed:
            let currentX = recognizer.location(in: superview).x
            let deltaX = currentX - initialPanLocation
            let deltaSeconds = Double(deltaX / pxPerSecond)
            let deltaUs = secondsToUs(deltaSeconds)

            let newDurationUs = max(minDurationUs, initialDurationUs + deltaUs)
            durationUs = newDurationUs
            onTrimTrailing?(newDurationUs, .changed)

        case .ended:
            onTrimTrailing?(durationUs, .ended)

        case .cancelled, .failed:
            onTrimTrailing?(durationUs, .cancelled)

        default:
            break
        }
    }
}
