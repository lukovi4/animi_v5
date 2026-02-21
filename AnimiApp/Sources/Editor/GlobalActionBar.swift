import UIKit

// MARK: - Global Action Bar (PR2)

/// Bottom bar shown when no timeline item is selected.
/// Contains action buttons: Add Text, Add Scene, Music, Sticker, Media.
/// All buttons are placeholders in PR2 (no functionality).
final class GlobalActionBar: UIView {

    // MARK: - Callbacks (for future PRs)

    var onAddText: (() -> Void)?
    var onAddScene: (() -> Void)?
    var onMusic: (() -> Void)?
    var onSticker: (() -> Void)?
    var onMedia: (() -> Void)?

    // MARK: - Subviews

    private lazy var stackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .center
        stack.spacing = 0
        return stack
    }()

    private lazy var textButton = makeActionButton(icon: "textformat", title: "Text")
    private lazy var sceneButton = makeActionButton(icon: "film", title: "Scene")
    private lazy var musicButton = makeActionButton(icon: "music.note", title: "Music")
    private lazy var stickerButton = makeActionButton(icon: "face.smiling", title: "Sticker")
    private lazy var mediaButton = makeActionButton(icon: "photo", title: "Media")

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

        [textButton, sceneButton, musicButton, stickerButton, mediaButton].forEach {
            stackView.addArrangedSubview($0)
        }
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeActionButton(icon: String, title: String) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: icon)
        config.title = title
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = .label

        button.configuration = config

        // Store title for identifying which button was tapped
        button.accessibilityIdentifier = title
        button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)

        container.addSubview(button)

        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    // MARK: - Actions

    @objc private func buttonTapped(_ sender: UIButton) {
        switch sender.accessibilityIdentifier {
        case "Text": onAddText?()
        case "Scene": onAddScene?()
        case "Music": onMusic?()
        case "Sticker": onSticker?()
        case "Media": onMedia?()
        default: break
        }
    }
}
