import UIKit

/// Main templates catalog screen with categories and horizontal sliders.
final class TemplatesHomeViewController: UIViewController {

    // MARK: - State

    private var loadState: LoadState<TemplateCatalogSnapshot> = .loading
    private var categories: [TemplateCategory] = []
    private var templatesByCategory: [CategoryID: [TemplateDescriptor]] = [:]

    // MARK: - UI

    private lazy var collectionView: UICollectionView = {
        let layout = createLayout()
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .systemBackground
        cv.delegate = self
        cv.dataSource = self
        cv.register(TemplatePreviewCell.self, forCellWithReuseIdentifier: TemplatePreviewCell.reuseIdentifier)
        cv.register(CategoryHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: CategoryHeaderView.reuseIdentifier)
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
        label.text = "No templates available"
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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadCatalog()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    // MARK: - Setup

    private func setupUI() {
        title = "Templates"
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
        let layout = UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            self?.createSectionLayout(environment: environment)
        }
        return layout
    }

    private func createSectionLayout(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        // Card size: 2 visible on screen with spacing
        // Aspect ratio 9:16 (1080x1920)
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
            widthDimension: .absolute(itemWidth),
            heightDimension: .absolute(itemHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = interItemSpacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: horizontalPadding, bottom: 24, trailing: horizontalPadding)

        // Header
        let headerSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(44)
        )
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: headerSize,
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
        )
        section.boundarySupplementaryItems = [header]

        return section
    }

    // MARK: - Loading

    private func loadCatalog() {
        loadState = .loading
        updateUI()

        Task {
            let result = await TemplateCatalog.shared.load()
            await MainActor.run {
                switch result {
                case .success(let snapshot):
                    let cats = snapshot.categoriesInOrder()
                    if cats.isEmpty {
                        loadState = .empty
                    } else {
                        categories = cats
                        // Build templates cache once
                        templatesByCategory = Dictionary(grouping: snapshot.templates, by: \.categoryId)
                            .mapValues { $0.sorted { $0.order < $1.order } }
                        loadState = .content(snapshot)
                    }
                case .failure(let error):
                    loadState = .error(error.localizedDescription)
                }
                updateUI()
            }
        }
    }

    @objc private func retryTapped() {
        loadCatalog()
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
            let editorVC = PlayerViewController(mode: .editor(templateId: template.id))
            navigationController?.pushViewController(editorVC, animated: true)
        }
    }

    private func openSeeAll(for category: TemplateCategory) {
        let categoryVC = CategoryTemplatesViewController(category: category)
        navigationController?.pushViewController(categoryVC, animated: true)
    }
}

// MARK: - UICollectionViewDataSource

extension TemplatesHomeViewController: UICollectionViewDataSource {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        categories.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        let categoryId = categories[section].id
        return templatesByCategory[categoryId]?.count ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TemplatePreviewCell.reuseIdentifier, for: indexPath) as! TemplatePreviewCell
        let categoryId = categories[indexPath.section].id
        if let templates = templatesByCategory[categoryId], indexPath.item < templates.count {
            cell.configure(with: templates[indexPath.item])
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: CategoryHeaderView.reuseIdentifier, for: indexPath) as! CategoryHeaderView
        let category = categories[indexPath.section]
        header.configure(title: category.title) { [weak self] in
            self?.openSeeAll(for: category)
        }
        return header
    }
}

// MARK: - UICollectionViewDelegate

extension TemplatesHomeViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let categoryId = categories[indexPath.section].id
        if let templates = templatesByCategory[categoryId], indexPath.item < templates.count {
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

// MARK: - Category Header View

final class CategoryHeaderView: UICollectionReusableView {

    static let reuseIdentifier = "CategoryHeaderView"

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textColor = .label
        return label
    }()

    private let seeAllButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("See all", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15)
        return button
    }()

    private var onSeeAllTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let stack = UIStackView(arrangedSubviews: [titleLabel, seeAllButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])

        seeAllButton.addTarget(self, action: #selector(seeAllTapped), for: .touchUpInside)
    }

    func configure(title: String, onSeeAll: @escaping () -> Void) {
        titleLabel.text = title
        onSeeAllTapped = onSeeAll
    }

    @objc private func seeAllTapped() {
        onSeeAllTapped?()
    }
}
