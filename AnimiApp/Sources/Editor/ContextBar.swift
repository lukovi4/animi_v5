import UIKit

// MARK: - Context Bar (PR2)

/// Bottom bar shown when a timeline item is selected.
/// Empty container in PR2 - will contain context-specific controls in future PRs.
final class ContextBar: UIView {

    // MARK: - Subviews

    private lazy var placeholderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Context Actions"
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
        addSubview(placeholderLabel)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Public API (for future PRs)

    /// Configures context bar for the given selection type.
    func configure(for selection: TimelineSelection) {
        switch selection {
        case .none:
            placeholderLabel.text = "Context Actions"
        case .scene:
            placeholderLabel.text = "Scene Options"
        case .audio:
            placeholderLabel.text = "Audio Options"
        }
    }
}
