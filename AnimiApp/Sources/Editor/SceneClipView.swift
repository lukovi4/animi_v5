import UIKit

// MARK: - Scene Clip View (PR2: Multi-scene + Trim handles, PR3: Reorder, PR4: Data/Layout split)

/// Represents a single scene clip on the timeline.
/// Shows the clip body with optional trim handles when selected.
/// Handles are 44pt touch targets with 10pt visual indicator.
/// PR3: Supports body drag for reorder in reorder mode.
/// PR4: Conforms to ClipViewContract - separates data (applySnapshot) from layout (applyLayout).
final class SceneClipView: UIView, ClipViewContract {

    // MARK: - Callbacks

    /// Called when clip is tapped (for selection).
    var onSelect: (() -> Void)?

    /// Called when trailing handle is dragged.
    /// Parameter is the new duration in microseconds.
    var onTrimTrailing: ((TimeUs, InteractionPhase) -> Void)?

    /// PR3: Called when clip body is dragged for reorder.
    /// Parameters: dragX position in superview coordinates, phase.
    var onReorderDrag: ((CGFloat, InteractionPhase) -> Void)?

    // MARK: - Configuration

    let sceneId: UUID
    private(set) var durationUs: TimeUs
    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var isSelected: Bool = false

    /// PR3: Reorder mode state
    private var isReorderMode: Bool = false

    // MARK: - Constants

    private let handleTouchWidth: CGFloat = 44
    private let handleVisualWidth: CGFloat = 10
    private let cornerRadius: CGFloat = 8

    /// PR2 fix: Configurable min duration (set via configure, default 0.1s per spec)
    private var minDurationUs: TimeUs = ProjectDraft.minSceneDurationUs

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

    /// PR3: Body pan gesture for reorder mode.
    /// Exposed for require(toFail:) setup with scrollView pan.
    private(set) lazy var bodyPanGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleBodyPan(_:)))
        gesture.isEnabled = false // Disabled by default, enabled in reorder mode
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
        // PR3: Body pan for reorder (disabled by default)
        bodyView.addGestureRecognizer(bodyPanGesture)
    }

    // MARK: - ClipViewContract (PR4)

    /// Applies data snapshot. Called when clip data changes, NOT during scroll/zoom.
    /// - Parameter snapshot: Data snapshot with duration, selection, constraints
    func applySnapshot(_ snapshot: SceneClipSnapshot) {
        #if DEBUG
        TimelinePerfCounters.incrementApplySnapshot(.scene)
        #endif

        self.durationUs = snapshot.durationUs
        self.minDurationUs = snapshot.minDurationUs
        // Note: isSelected is handled via setSelected() for animation support
    }

    /// Applies layout parameters. Called during layout pass.
    /// - Parameter pxPerSecond: Pixels per second for gesture calculations
    func applyLayout(pxPerSecond: CGFloat) {
        self.pxPerSecond = pxPerSecond
    }

    // MARK: - Configuration (Legacy - PR4 deprecated)

    /// PR2 fix: Added minDurationUs parameter (calculated from templateFPS)
    /// PR4: Deprecated - use applySnapshot + applyLayout instead
    @available(*, deprecated, message: "Use applySnapshot + applyLayout instead")
    func configure(durationUs: TimeUs, pxPerSecond: CGFloat, minDurationUs: TimeUs) {
        self.durationUs = durationUs
        self.pxPerSecond = pxPerSecond
        self.minDurationUs = minDurationUs
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        // PR3: Hide trim handle in reorder mode even if selected
        trailingHandle.isHidden = !selected || isReorderMode

        UIView.animate(withDuration: 0.2) {
            self.bodyView.backgroundColor = selected ? self.selectedColor : self.normalColor
            self.bodyView.transform = selected ? CGAffineTransform(scaleX: 1.0, y: 1.02) : .identity
        }
    }

    /// PR3: Sets reorder mode - enables/disables appropriate gestures.
    /// - Parameter isReorderMode: Whether reorder mode is active
    func setReorderMode(_ isReorderMode: Bool) {
        self.isReorderMode = isReorderMode

        // Enable body pan in reorder mode, disable trim
        bodyPanGesture.isEnabled = isReorderMode
        trailingPanGesture.isEnabled = !isReorderMode

        // Hide trim handle in reorder mode
        trailingHandle.isHidden = !isSelected || isReorderMode
    }

    /// PR4: Legacy method, use applyLayout(pxPerSecond:) instead
    @available(*, deprecated, message: "Use applyLayout(pxPerSecond:) instead")
    func setPxPerSecond(_ pps: CGFloat) {
        applyLayout(pxPerSecond: pps)
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

    // MARK: - PR3: Reorder Gesture Handler

    @objc private func handleBodyPan(_ recognizer: UIPanGestureRecognizer) {
        guard isReorderMode else { return }

        let location = recognizer.location(in: superview)

        switch recognizer.state {
        case .began:
            // Apply ghost effect
            applyGhostEffect(true)
            onReorderDrag?(location.x, .began)

        case .changed:
            onReorderDrag?(location.x, .changed)

        case .ended:
            // Remove ghost effect
            applyGhostEffect(false)
            onReorderDrag?(location.x, .ended)

        case .cancelled, .failed:
            // Remove ghost effect
            applyGhostEffect(false)
            onReorderDrag?(location.x, .cancelled)

        default:
            break
        }
    }

    /// Applies or removes ghost effect during reorder drag.
    /// - Parameter apply: Whether to apply or remove the effect
    private func applyGhostEffect(_ apply: Bool) {
        UIView.animate(withDuration: 0.15) {
            if apply {
                self.alpha = 0.85
                self.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
                self.layer.shadowColor = UIColor.black.cgColor
                self.layer.shadowOpacity = 0.3
                self.layer.shadowOffset = CGSize(width: 0, height: 4)
                self.layer.shadowRadius = 8
            } else {
                self.alpha = 1.0
                self.transform = self.isSelected ? CGAffineTransform(scaleX: 1.0, y: 1.02) : .identity
                self.layer.shadowOpacity = 0
            }
        }
    }
}
