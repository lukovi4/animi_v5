import UIKit

// MARK: - Media Block Action Bar (PR-C)

/// Bottom bar shown in Scene Edit mode when a media block is selected.
/// Provides block-level actions: Add Photo, Add Video, Animation, Disable/Enable, Remove.
final class MediaBlockActionBar: UIView {

    // MARK: - Callbacks

    /// Called when Add Photo button is tapped
    var onAddPhoto: (() -> Void)?

    /// Called when Add Video button is tapped
    var onAddVideo: (() -> Void)?

    /// Called when Animation button is tapped (variant picker)
    var onAnimation: (() -> Void)?

    /// Called when Disable/Enable button is tapped
    var onToggleEnabled: (() -> Void)?

    /// Called when Remove button is tapped
    var onRemove: (() -> Void)?

    // MARK: - State

    /// Current enabled state of the block
    private var isBlockEnabled: Bool = true

    // MARK: - Subviews

    private lazy var scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        return scroll
    }()

    private lazy var stackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        return stack
    }()

    private lazy var addPhotoButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "photo")
        config.title = "Photo"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(addPhotoTapped), for: .touchUpInside)
        return button
    }()

    private lazy var addVideoButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "video")
        config.title = "Video"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(addVideoTapped), for: .touchUpInside)
        return button
    }()

    private lazy var animationButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "sparkles.rectangle.stack")
        config.title = "Animation"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(animationTapped), for: .touchUpInside)
        return button
    }()

    private lazy var toggleEnabledButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "eye.slash")
        config.title = "Disable"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(toggleEnabledTapped), for: .touchUpInside)
        return button
    }()

    private lazy var removeButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "trash")
        config.title = "Remove"
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .systemRed

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
        return button
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

        addSubview(scrollView)
        scrollView.addSubview(stackView)

        stackView.addArrangedSubview(addPhotoButton)
        stackView.addArrangedSubview(addVideoButton)
        stackView.addArrangedSubview(animationButton)
        stackView.addArrangedSubview(toggleEnabledButton)
        stackView.addArrangedSubview(removeButton)
    }

    private func setupConstraints() {
        // P1 fix: Use contentLayoutGuide for content positioning, frameLayoutGuide for height.
        // This enables horizontal scrolling when content exceeds scrollView width.
        NSLayoutConstraint.activate([
            // ScrollView fills the bar
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // StackView positioned via contentLayoutGuide (allows content to exceed frame)
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            // Height matches frame (vertical centering, no vertical scroll)
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    // MARK: - Public API

    /// Configures the action bar for the given block.
    /// - Parameters:
    ///   - allowedMedia: Media types allowed for this block (from MediaInput.allowedMedia)
    ///   - hasVariants: Whether the block has multiple variants (animation picker)
    ///   - hasMedia: Whether the block currently has media assigned
    ///   - isEnabled: Whether the block's binding layer is visible (userMediaPresent)
    func configure(
        allowedMedia: [String]?,
        hasVariants: Bool,
        hasMedia: Bool,
        isEnabled: Bool
    ) {
        // Photo button: shown if allowedMedia contains "photo" or is nil (backward compat)
        let canPhoto = allowedMedia?.contains("photo") ?? true
        addPhotoButton.isHidden = !canPhoto

        // Video button: shown if allowedMedia contains "video" or is nil (backward compat)
        let canVideo = allowedMedia?.contains("video") ?? true
        addVideoButton.isHidden = !canVideo

        // Animation button: shown if block has variants
        animationButton.isHidden = !hasVariants

        // Remove button: shown only if media is assigned
        removeButton.isHidden = !hasMedia
        removeButton.isEnabled = hasMedia
        removeButton.alpha = hasMedia ? 1.0 : 0.5

        // Toggle button: update title/icon based on current state
        isBlockEnabled = isEnabled
        updateToggleButton()
    }

    // MARK: - Private

    private func updateToggleButton() {
        var config = toggleEnabledButton.configuration ?? UIButton.Configuration.plain()

        if isBlockEnabled {
            config.image = UIImage(systemName: "eye.slash")
            config.title = "Disable"
        } else {
            config.image = UIImage(systemName: "eye")
            config.title = "Enable"
        }

        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label
        toggleEnabledButton.configuration = config
    }

    // MARK: - Actions

    @objc private func addPhotoTapped() {
        onAddPhoto?()
    }

    @objc private func addVideoTapped() {
        onAddVideo?()
    }

    @objc private func animationTapped() {
        onAnimation?()
    }

    @objc private func toggleEnabledTapped() {
        onToggleEnabled?()
    }

    @objc private func removeTapped() {
        onRemove?()
    }
}
