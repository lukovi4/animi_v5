import UIKit

// MARK: - Context Bar (PR9 + PR8)

/// Bottom bar shown when a timeline item is selected.
/// Provides context-specific actions (Duplicate/Delete/Edit for scenes, Remove/Volume for audio).
final class ContextBar: UIView {

    // MARK: - Callbacks

    /// Called when Duplicate is tapped. Parameter: scene item ID.
    var onDuplicateScene: ((UUID) -> Void)?

    /// Called when Delete is tapped. Parameter: scene item ID.
    var onDeleteScene: ((UUID) -> Void)?

    /// Called when Edit is tapped (PR-C). Parameter: scene item ID.
    var onEditScene: ((UUID) -> Void)?

    /// Called when Remove Music is tapped (PR8).
    var onRemoveMusic: (() -> Void)?

    /// Called when Volume is tapped (PR8). Parameter: audio item ID.
    var onMusicVolume: ((UUID) -> Void)?

    /// Called when Trim is tapped (PR8). Parameter: audio item ID.
    var onMusicTrim: ((UUID) -> Void)?

    /// Called when Edit Text is tapped (PR9). Parameter: text item ID.
    var onEditText: ((UUID) -> Void)?

    /// Called when Delete Text is tapped (PR9). Parameter: text item ID.
    var onDeleteText: ((UUID) -> Void)?

    // MARK: - State

    /// Currently selected scene ID (for button actions).
    private var selectedSceneId: UUID?

    /// Currently selected audio item ID (for audio actions).
    private var selectedAudioItemId: UUID?

    /// Currently selected text item ID (for text actions, PR9).
    private var selectedTextItemId: UUID?

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

    private lazy var editButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "slider.horizontal.3")
        config.title = "Edit"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        return button
    }()

    // PR8: Audio action buttons
    private lazy var audioStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .center
        stack.spacing = 16
        return stack
    }()

    private lazy var removeAudioButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "trash")
        config.title = "Remove"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .systemRed

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(removeAudioTapped), for: .touchUpInside)
        return button
    }()

    private lazy var volumeButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "speaker.wave.2")
        config.title = "Volume"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(volumeTapped), for: .touchUpInside)
        return button
    }()

    private lazy var trimAudioButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "scissors")
        config.title = "Trim"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(trimAudioTapped), for: .touchUpInside)
        return button
    }()

    // PR9: Text action buttons
    private lazy var textStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .center
        stack.spacing = 16
        return stack
    }()

    private lazy var editTextButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "pencil")
        config.title = "Edit"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(editTextTapped), for: .touchUpInside)
        return button
    }()

    private lazy var deleteTextButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "trash")
        config.title = "Remove"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .systemRed

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(deleteTextTapped), for: .touchUpInside)
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
        addSubview(audioStackView)
        addSubview(textStackView)
        addSubview(placeholderLabel)

        stackView.addArrangedSubview(duplicateButton)
        stackView.addArrangedSubview(deleteButton)
        stackView.addArrangedSubview(editButton)

        audioStackView.addArrangedSubview(trimAudioButton)
        audioStackView.addArrangedSubview(removeAudioButton)
        audioStackView.addArrangedSubview(volumeButton)

        textStackView.addArrangedSubview(editTextButton)
        textStackView.addArrangedSubview(deleteTextButton)

        // Initially hidden until item is selected
        stackView.isHidden = true
        audioStackView.isHidden = true
        textStackView.isHidden = true
        placeholderLabel.isHidden = false
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),

            audioStackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            audioStackView.centerYAnchor.constraint(equalTo: centerYAnchor),

            textStackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            textStackView.centerYAnchor.constraint(equalTo: centerYAnchor),

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
            selectedAudioItemId = nil
            selectedTextItemId = nil
            stackView.isHidden = true
            audioStackView.isHidden = true
            textStackView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.text = "Select a scene"

        case .scene(let sceneId):
            selectedSceneId = sceneId
            selectedAudioItemId = nil
            selectedTextItemId = nil
            canDelete = sceneCount > 1
            stackView.isHidden = false
            audioStackView.isHidden = true
            textStackView.isHidden = true
            placeholderLabel.isHidden = true

            // Update delete button state
            deleteButton.isEnabled = canDelete
            deleteButton.alpha = canDelete ? 1.0 : 0.5

        case .audio(let itemId):
            selectedSceneId = nil
            selectedAudioItemId = itemId
            selectedTextItemId = nil
            stackView.isHidden = true
            audioStackView.isHidden = false
            textStackView.isHidden = true
            placeholderLabel.isHidden = true

        case .text(let itemId):
            selectedSceneId = nil
            selectedAudioItemId = nil
            selectedTextItemId = itemId
            stackView.isHidden = true
            audioStackView.isHidden = true
            textStackView.isHidden = false
            placeholderLabel.isHidden = true
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

    @objc private func editTapped() {
        guard let sceneId = selectedSceneId else { return }
        onEditScene?(sceneId)
    }

    @objc private func removeAudioTapped() {
        onRemoveMusic?()
    }

    @objc private func volumeTapped() {
        guard let itemId = selectedAudioItemId else { return }
        onMusicVolume?(itemId)
    }

    @objc private func trimAudioTapped() {
        guard let itemId = selectedAudioItemId else { return }
        onMusicTrim?(itemId)
    }

    @objc private func editTextTapped() {
        guard let itemId = selectedTextItemId else { return }
        onEditText?(itemId)
    }

    @objc private func deleteTextTapped() {
        guard let itemId = selectedTextItemId else { return }
        onDeleteText?(itemId)
    }
}
