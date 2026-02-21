import UIKit

// MARK: - Editor Nav Bar (PR2)

/// Navigation bar for editor mode.
/// Contains: Close (left), Undo/Redo (center, disabled in PR2), Export (right).
final class EditorNavBar: UIView {

    // MARK: - Callbacks

    var onClose: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onExport: (() -> Void)?

    // MARK: - Subviews

    private lazy var closeButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(UIImage(systemName: "xmark"), for: .normal)
        btn.tintColor = .label
        btn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var undoButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        btn.tintColor = .label
        btn.isEnabled = false // Disabled in PR2
        btn.alpha = 0.4
        btn.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var redoButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(UIImage(systemName: "arrow.uturn.forward"), for: .normal)
        btn.tintColor = .label
        btn.isEnabled = false // Disabled in PR2
        btn.alpha = 0.4
        btn.addTarget(self, action: #selector(redoTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var centerStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [undoButton, redoButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 24
        return stack
    }()

    private lazy var exportButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Export"
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .systemBlue
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)
        return btn
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
        addSubview(closeButton)
        addSubview(centerStack)
        addSubview(exportButton)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            centerStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            undoButton.widthAnchor.constraint(equalToConstant: 44),
            undoButton.heightAnchor.constraint(equalToConstant: 44),
            redoButton.widthAnchor.constraint(equalToConstant: 44),
            redoButton.heightAnchor.constraint(equalToConstant: 44),

            exportButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            exportButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Public API

    /// Sets undo button enabled state (for future PRs).
    func setUndoEnabled(_ enabled: Bool) {
        undoButton.isEnabled = enabled
        undoButton.alpha = enabled ? 1.0 : 0.4
    }

    /// Sets redo button enabled state (for future PRs).
    func setRedoEnabled(_ enabled: Bool) {
        redoButton.isEnabled = enabled
        redoButton.alpha = enabled ? 1.0 : 0.4
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func undoTapped() {
        onUndo?()
    }

    @objc private func redoTapped() {
        onRedo?()
    }

    @objc private func exportTapped() {
        onExport?()
    }
}
