import UIKit

/// Full-screen template preview with Close and Use template buttons.
final class TemplateDetailsViewController: UIViewController {

    // MARK: - Properties

    private let templateId: TemplateID
    private var template: TemplateDescriptor?
    private var loadState: LoadState<TemplateDescriptor> = .loading

    // MARK: - UI

    private let previewVideoView = PreviewVideoView()

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.layer.cornerRadius = 20
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return button
    }()

    private lazy var useTemplateButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Use template", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 12
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(useTemplateTapped), for: .touchUpInside)
        return button
    }()

    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        indicator.color = .white
        return indicator
    }()

    private lazy var errorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Failed to load template"
        label.textColor = .white
        label.textAlignment = .center
        label.isHidden = true
        return label
    }()

    // MARK: - Init

    init(templateId: TemplateID) {
        self.templateId = templateId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadTemplate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Hide navigation bar for full-screen preview
        navigationController?.setNavigationBarHidden(true, animated: animated)
        previewVideoView.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        previewVideoView.pause()
    }

    override var prefersStatusBarHidden: Bool {
        true
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .black

        previewVideoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewVideoView)
        view.addSubview(closeButton)
        view.addSubview(useTemplateButton)
        view.addSubview(loadingIndicator)
        view.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            // Full-screen video
            previewVideoView.topAnchor.constraint(equalTo: view.topAnchor),
            previewVideoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewVideoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewVideoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Close button - top right
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),

            // Use template button - bottom center
            useTemplateButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            useTemplateButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            useTemplateButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            useTemplateButton.heightAnchor.constraint(equalToConstant: 50),

            // Loading indicator
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            // Error label
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - Loading

    private func loadTemplate() {
        loadState = .loading
        updateUI()

        Task {
            let result = await TemplateCatalog.shared.load()
            await MainActor.run {
                switch result {
                case .success:
                    if let loaded = TemplateCatalog.shared.template(by: templateId) {
                        template = loaded
                        loadState = .content(loaded)
                        previewVideoView.configure(url: loaded.previewURL)
                        previewVideoView.play()
                    } else {
                        loadState = .error("Template not found")
                    }
                case .failure(let error):
                    loadState = .error(error.localizedDescription)
                }
                updateUI()
            }
        }
    }

    // MARK: - UI State

    private func updateUI() {
        switch loadState {
        case .loading:
            loadingIndicator.startAnimating()
            useTemplateButton.isHidden = true
            errorLabel.isHidden = true

        case .content:
            loadingIndicator.stopAnimating()
            useTemplateButton.isHidden = false
            errorLabel.isHidden = true

        case .empty, .error:
            loadingIndicator.stopAnimating()
            useTemplateButton.isHidden = true
            errorLabel.isHidden = false
        }
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        // Pop to root (Home) as per spec
        navigationController?.popToRootViewController(animated: true)
    }

    @objc private func useTemplateTapped() {
        guard template != nil else { return }
        let editorVC = PlayerViewController(mode: .editor(templateId: templateId))
        navigationController?.pushViewController(editorVC, animated: true)
    }
}
