import UIKit

// MARK: - Context Bar (PR9)

/// Bottom bar shown when a timeline item is selected.
/// Provides context-specific actions (Duplicate/Delete for scenes).
final class ContextBar: UIView {

    // MARK: - Callbacks

    /// Called when Duplicate is tapped. Parameter: scene item ID.
    var onDuplicateScene: ((UUID) -> Void)?

    /// Called when Delete is tapped. Parameter: scene item ID.
    var onDeleteScene: ((UUID) -> Void)?

    // MARK: - State

    /// Currently selected scene ID (for button actions).
    private var selectedSceneId: UUID?

    /// Whether delete is allowed (false if only one scene remains).
    private var canDelete: Bool = true

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

    private lazy var duplicateButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "doc.on.doc")
        config.title = "Duplicate"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(duplicateTapped), for: .touchUpInside)
        return button
    }()

    private lazy var deleteButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "trash")
        config.title = "Delete"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .systemRed

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        return button
    }()

    private lazy var placeholderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Select a scene"
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
        addSubview(placeholderLabel)

        stackView.addArrangedSubview(duplicateButton)
        stackView.addArrangedSubview(deleteButton)

        // Initially hidden until scene is selected
        stackView.isHidden = true
        placeholderLabel.isHidden = false
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Public API

    /// Configures context bar for the given selection type.
    /// - Parameters:
    ///   - selection: Current timeline selection
    ///   - sceneCount: Total number of scenes (for delete validation)
    func configure(for selection: TimelineSelection, sceneCount: Int = 1) {
        switch selection {
        case .none:
            selectedSceneId = nil
            stackView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.text = "Select a scene"

        case .scene(let sceneId):
            selectedSceneId = sceneId
            canDelete = sceneCount > 1
            stackView.isHidden = false
            placeholderLabel.isHidden = true

            // Update delete button state
            deleteButton.isEnabled = canDelete
            deleteButton.alpha = canDelete ? 1.0 : 0.5

        case .audio:
            selectedSceneId = nil
            stackView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.text = "Audio Options"
        }
    }

    // MARK: - Actions

    @objc private func duplicateTapped() {
        guard let sceneId = selectedSceneId else { return }
        onDuplicateScene?(sceneId)
    }

    @objc private func deleteTapped() {
        guard let sceneId = selectedSceneId, canDelete else { return }
        onDeleteScene?(sceneId)
    }
}
