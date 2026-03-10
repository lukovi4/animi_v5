import UIKit

/// "See all" screen showing all templates in a category as a 2-column grid.
final class CategoryTemplatesViewController: UIViewController {

    // MARK: - Properties

    private let category: TemplateCategory
    private var templates: [TemplateDescriptor] = []
    private var loadState: LoadState<[TemplateDescriptor]> = .loading

    // MARK: - UI

    private lazy var collectionView: UICollectionView = {
        let layout = createLayout()
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .systemBackground
        cv.delegate = self
        cv.dataSource = self
        cv.register(TemplatePreviewCell.self, forCellWithReuseIdentifier: TemplatePreviewCell.reuseIdentifier)
        return cv
    }()

    private lazy var loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "No templates in this category"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.isHidden = true
        return label
    }()

    private lazy var errorView: UIStackView = {
        let label = UILabel()
        label.text = "Failed to load templates"
        label.textColor = .secondaryLabel
        label.textAlignment = .center

        let button = UIButton(type: .system)
        button.setTitle("Retry", for: .normal)
        button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        return stack
    }()

    // MARK: - Init

    init(category: TemplateCategory) {
        self.category = category
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadTemplates()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    // MARK: - Setup

    private func setupUI() {
        title = category.title
        view.backgroundColor = .systemBackground

        view.addSubview(collectionView)
        view.addSubview(loadingIndicator)
        view.addSubview(emptyLabel)
        view.addSubview(errorView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - Layout

    private func createLayout() -> UICollectionViewLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            self?.createGridSection(environment: environment)
        }
        return layout
    }

    private func createGridSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        // 2-column grid
        let containerWidth = environment.container.contentSize.width
        let horizontalPadding: CGFloat = 16
        let interItemSpacing: CGFloat = 12
        let availableWidth = containerWidth - (horizontalPadding * 2) - interItemSpacing
        let itemWidth = availableWidth / 2

        // Height based on 9:16 ratio
        let itemHeight = itemWidth * (16.0 / 9.0)

        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(itemWidth),
            heightDimension: .absolute(itemHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .absolute(itemHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item, item])
        group.interItemSpacing = .fixed(interItemSpacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = interItemSpacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: horizontalPadding, bottom: 16, trailing: horizontalPadding)

        return section
    }

    // MARK: - Loading

    private func loadTemplates() {
        loadState = .loading
        updateUI()

        Task {
            let result = await TemplateCatalog.shared.load()
            await MainActor.run {
                switch result {
                case .success:
                    let loaded = TemplateCatalog.shared.templates(for: category.id)
                    if loaded.isEmpty {
                        loadState = .empty
                    } else {
                        templates = loaded
                        loadState = .content(loaded)
                    }
                case .failure(let error):
                    loadState = .error(error.localizedDescription)
                }
                updateUI()
            }
        }
    }

    @objc private func retryTapped() {
        loadTemplates()
    }

    // MARK: - UI State

    private func updateUI() {
        switch loadState {
        case .loading:
            loadingIndicator.startAnimating()
            collectionView.isHidden = true
            emptyLabel.isHidden = true
            errorView.isHidden = true

        case .content:
            loadingIndicator.stopAnimating()
            collectionView.isHidden = false
            emptyLabel.isHidden = true
            errorView.isHidden = true
            collectionView.reloadData()

        case .empty:
            loadingIndicator.stopAnimating()
            collectionView.isHidden = true
            emptyLabel.isHidden = false
            errorView.isHidden = true

        case .error:
            loadingIndicator.stopAnimating()
            collectionView.isHidden = true
            emptyLabel.isHidden = true
            errorView.isHidden = false
        }
    }

    // MARK: - Navigation

    private func openTemplate(_ template: TemplateDescriptor) {
        switch template.openBehavior {
        case .previewFirst:
            let detailsVC = TemplateDetailsViewController(templateId: template.id)
            navigationController?.pushViewController(detailsVC, animated: true)
        case .directToEditor:
            let editorVC = PlayerViewController(templateId: template.id)
            navigationController?.pushViewController(editorVC, animated: true)
        }
    }
}

// MARK: - UICollectionViewDataSource

extension CategoryTemplatesViewController: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        templates.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TemplatePreviewCell.reuseIdentifier, for: indexPath) as! TemplatePreviewCell
        if indexPath.item < templates.count {
            cell.configure(with: templates[indexPath.item])
        }
        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension CategoryTemplatesViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.item < templates.count {
            openTemplate(templates[indexPath.item])
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? TemplatePreviewCell)?.willDisplay()
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? TemplatePreviewCell)?.didEndDisplaying()
    }
}
