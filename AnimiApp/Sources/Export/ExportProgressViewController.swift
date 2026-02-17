import UIKit

// MARK: - Export Progress State

/// State of export progress for UI updates.
enum ExportProgressState {
    case preparing
    case rendering(progress: Double)
    case finishing
    case completed(URL)
    case failed(Error)
    case cancelled
}

// MARK: - Export Progress View Controller

/// Modal view controller showing export progress with cancel option.
///
/// Usage:
/// ```swift
/// let vc = ExportProgressViewController()
/// vc.onCancel = { [weak exporter] in exporter?.cancel() }
/// present(vc, animated: true)
///
/// // Update progress:
/// vc.updateState(.rendering(progress: 0.5))
///
/// // On completion:
/// vc.updateState(.completed(url))
/// ```
final class ExportProgressViewController: UIViewController {

    // MARK: - Callbacks

    /// Called when user taps Cancel button.
    var onCancel: (() -> Void)?

    /// Called when export completes successfully. Caller should dismiss and show share sheet.
    var onCompleted: ((URL) -> Void)?

    /// Called when export fails. Caller should dismiss and show alert.
    var onFailed: ((Error) -> Void)?

    // MARK: - UI Components

    private lazy var containerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.layer.cornerRadius = 16
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.2
        view.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.layer.shadowRadius = 12
        return view
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Exporting Video"
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textAlignment = .center
        return label
    }()

    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Preparing..."
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    private lazy var progressView: UIProgressView = {
        let progress = UIProgressView(progressViewStyle: .default)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = .systemBlue
        progress.trackTintColor = .systemGray5
        progress.progress = 0
        return progress
    }()

    private lazy var percentLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "0%"
        label.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        label.textAlignment = .center
        return label
    }()

    private lazy var cancelButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = "Cancel"
        config.baseForegroundColor = .systemRed
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        return button
    }()

    // MARK: - State

    private var currentState: ExportProgressState = .preparing

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateUI(for: .preparing)
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        view.addSubview(containerView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(statusLabel)
        containerView.addSubview(progressView)
        containerView.addSubview(percentLabel)
        containerView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            // Container centered in view
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 280),

            // Title
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            // Status
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            // Percent
            percentLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            percentLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),

            // Progress bar
            progressView.topAnchor.constraint(equalTo: percentLabel.bottomAnchor, constant: 12),
            progressView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            // Cancel button
            cancelButton.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 20),
            cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Public API

    /// Updates the progress state and UI.
    func updateState(_ state: ExportProgressState) {
        currentState = state

        DispatchQueue.main.async { [weak self] in
            self?.updateUI(for: state)
        }
    }

    // MARK: - Private

    private func updateUI(for state: ExportProgressState) {
        switch state {
        case .preparing:
            statusLabel.text = "Preparing..."
            percentLabel.text = "0%"
            progressView.progress = 0
            cancelButton.isEnabled = true

        case .rendering(let progress):
            statusLabel.text = "Rendering..."
            let pct = Int(progress * 100)
            percentLabel.text = "\(pct)%"
            progressView.setProgress(Float(progress), animated: true)
            cancelButton.isEnabled = true

        case .finishing:
            statusLabel.text = "Finishing..."
            percentLabel.text = "100%"
            progressView.progress = 1.0
            cancelButton.isEnabled = false

        case .completed(let url):
            onCompleted?(url)

        case .failed(let error):
            onFailed?(error)

        case .cancelled:
            // Handled by caller
            break
        }
    }

    @objc private func cancelTapped() {
        cancelButton.isEnabled = false
        statusLabel.text = "Cancelling..."
        onCancel?()
    }
}
