import UIKit

/// PR-D: Overlay view shown during template loading/preparation.
/// Displays a spinner and status label while blocking user interaction.
final class PreparingOverlayView: UIView {

    // MARK: - UI Components

    private let blurView: UIVisualEffectView = {
        let blur = UIBlurEffect(style: .systemMaterial)
        let view = UIVisualEffectView(effect: blur)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let containerStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let spinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .label
        spinner.hidesWhenStopped = true
        return spinner
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Setup

    private func setupUI() {
        backgroundColor = .clear
        isHidden = true

        addSubview(blurView)
        blurView.contentView.addSubview(containerStack)

        containerStack.addArrangedSubview(spinner)
        containerStack.addArrangedSubview(statusLabel)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),

            containerStack.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
            containerStack.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
            containerStack.leadingAnchor.constraint(greaterThanOrEqualTo: blurView.contentView.leadingAnchor, constant: 20),
            containerStack.trailingAnchor.constraint(lessThanOrEqualTo: blurView.contentView.trailingAnchor, constant: -20)
        ])
    }

    // MARK: - Public API

    /// Shows the overlay with given status text.
    func show(text: String) {
        statusLabel.text = text
        spinner.startAnimating()
        isHidden = false
    }

    /// Updates the status text while visible.
    func setStatus(_ text: String) {
        statusLabel.text = text
    }

    /// Hides the overlay.
    func hide() {
        spinner.stopAnimating()
        isHidden = true
    }

    /// Shows error state with message.
    func showError(_ message: String) {
        spinner.stopAnimating()
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        isHidden = false
    }

    /// Resets to normal state (for next show).
    func reset() {
        statusLabel.textColor = .secondaryLabel
    }
}
