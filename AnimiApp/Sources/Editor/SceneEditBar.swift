import UIKit

// MARK: - Scene Edit Bar (PR-C)

/// Bottom bar shown in Scene Edit mode when no block is selected.
/// Provides scene-level actions (Background, Reset Scene) and a hint label.
final class SceneEditBar: UIView {

    // MARK: - Callbacks

    /// Called when Background button is tapped
    var onBackground: (() -> Void)?

    /// Called when Reset Scene button is tapped
    var onResetScene: (() -> Void)?

    // MARK: - Subviews

    private lazy var stackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .center
        stack.spacing = 16
        return stack
    }()

    private lazy var backgroundButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "photo.artframe")
        config.title = "Background"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(backgroundTapped), for: .touchUpInside)
        return button
    }()

    private lazy var resetSceneButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "arrow.counterclockwise")
        config.title = "Reset Scene"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .systemRed

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(resetSceneTapped), for: .touchUpInside)
        return button
    }()

    private lazy var hintLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Tap a media slot to edit"
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        setupConstraints()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .systemBackground

        addSubview(stackView)
        addSubview(hintLabel)

        stackView.addArrangedSubview(backgroundButton)
        stackView.addArrangedSubview(resetSceneButton)
    }

    private func setupConstraints() {
        // P1 fix: Add constraint between stackView and hintLabel to prevent overlap.
        // Also set compression priorities so hintLabel can compress while buttons stay intact.
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Anti-overlap: stackView trailing must not exceed hintLabel leading
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: hintLabel.leadingAnchor, constant: -12),

            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Public API

    /// Configures the Reset Scene button enabled state.
    /// - Parameter canReset: Whether reset is allowed (false if scene is empty)
    func setCanReset(_ canReset: Bool) {
        resetSceneButton.isEnabled = canReset
        resetSceneButton.alpha = canReset ? 1.0 : 0.5
    }

    // MARK: - Actions

    @objc private func backgroundTapped() {
        onBackground?()
    }

    @objc private func resetSceneTapped() {
        onResetScene?()
    }
}
