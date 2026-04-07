import UIKit

/// Displays a list of saved projects with preview, title, date, and delete.
final class MyProjectsViewController: UIViewController {

    // MARK: - Dependencies

    private let catalogRepository: TemplateCatalogProviding
    private let onOpenEditor: (EditorLaunchIntent) -> Void

    // MARK: - Section Model

    private struct Section {
        let title: String
        var entries: [SavedProjectIndexEntry]
    }

    // MARK: - State

    private var sections: [Section] = []

    // MARK: - UI

    private static let sectionHeaderKind = UICollectionView.elementKindSectionHeader
    private static let headerReuseIdentifier = "SectionHeader"

    private lazy var collectionView: UICollectionView = {
        let layout = createLayout()
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .systemBackground
        cv.delegate = self
        cv.dataSource = self
        cv.register(ProjectPreviewCell.self, forCellWithReuseIdentifier: ProjectPreviewCell.reuseIdentifier)
        cv.register(
            SectionHeaderView.self,
            forSupplementaryViewOfKind: Self.sectionHeaderKind,
            withReuseIdentifier: Self.headerReuseIdentifier
        )
        return cv
    }()

    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "No saved projects"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.isHidden = true
        return label
    }()

    // MARK: - Init

    init(
        catalogRepository: TemplateCatalogProviding,
        onOpenEditor: @escaping (EditorLaunchIntent) -> Void
    ) {
        self.catalogRepository = catalogRepository
        self.onOpenEditor = onOpenEditor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "My Projects"
        view.backgroundColor = .systemBackground
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)

        // Ensure catalog is loaded before displaying (needed for template titles/previews)
        Task { @MainActor in
            _ = await catalogRepository.load()
            reloadData()
        }
    }

    // MARK: - Setup

    private func setupUI() {
        view.addSubview(collectionView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - Layout

    private func createLayout() -> UICollectionViewLayout {
        let itemWidth: CGFloat = (UIScreen.main.bounds.width - 48) / 2
        let itemHeight = itemWidth * (16.0 / 9.0) + 44 // video + labels

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
        group.interItemSpacing = .fixed(16)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 16
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16)

        // Section header
        let headerSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(44)
        )
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: headerSize,
            elementKind: Self.sectionHeaderKind,
            alignment: .top
        )
        section.boundarySupplementaryItems = [header]

        return UICollectionViewCompositionalLayout(section: section)
    }

    // MARK: - Data

    private func reloadData() {
        // ProjectStore.shared allowed here for listing/delete until PR 4
        let allEntries = ProjectStore.shared.allSavedProjectEntries()
        sections = Self.groupByDate(allEntries)

        let isEmpty = sections.allSatisfy { $0.entries.isEmpty }
        emptyLabel.isHidden = !isEmpty
        collectionView.isHidden = isEmpty
        collectionView.reloadData()
    }

    private static func groupByDate(_ entries: [SavedProjectIndexEntry]) -> [Section] {
        let calendar = Calendar.current

        var today: [SavedProjectIndexEntry] = []
        var yesterday: [SavedProjectIndexEntry] = []
        var earlier: [SavedProjectIndexEntry] = []

        let sorted = entries.sorted { $0.savedAt > $1.savedAt }

        for entry in sorted {
            if calendar.isDateInToday(entry.savedAt) {
                today.append(entry)
            } else if calendar.isDateInYesterday(entry.savedAt) {
                yesterday.append(entry)
            } else {
                earlier.append(entry)
            }
        }

        var result: [Section] = []
        if !today.isEmpty { result.append(Section(title: "Today", entries: today)) }
        if !yesterday.isEmpty { result.append(Section(title: "Yesterday", entries: yesterday)) }
        if !earlier.isEmpty { result.append(Section(title: "Earlier", entries: earlier)) }
        return result
    }

    private func entry(at indexPath: IndexPath) -> SavedProjectIndexEntry {
        sections[indexPath.section].entries[indexPath.item]
    }

    private func deleteProject(at indexPath: IndexPath) {
        let entry = self.entry(at: indexPath)
        do {
            // ProjectStore.shared allowed here for listing/delete until PR 4
            try ProjectStore.shared.deleteSavedProject(projectId: entry.projectId)
            reloadData()
        } catch {
            #if DEBUG
            print("[MyProjects] Delete failed: \(error)")
            #endif
        }
    }
}

// MARK: - UICollectionViewDataSource

extension MyProjectsViewController: UICollectionViewDataSource {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].entries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ProjectPreviewCell.reuseIdentifier,
            for: indexPath
        ) as! ProjectPreviewCell

        let entry = self.entry(at: indexPath)
        let template = catalogRepository.template(by: entry.sourceTemplateId)
        cell.configure(
            templateTitle: template?.title ?? entry.sourceTemplateId,
            previewURL: template?.previewURL,
            savedAt: entry.savedAt
        )

        cell.onDelete = { [weak self] in
            self?.confirmDelete(at: indexPath)
        }

        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: Self.headerReuseIdentifier,
            for: indexPath
        ) as! SectionHeaderView
        header.configure(title: sections[indexPath.section].title)
        return header
    }

    private func confirmDelete(at indexPath: IndexPath) {
        let alert = UIAlertController(
            title: "Delete Project?",
            message: "This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteProject(at: indexPath)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - UICollectionViewDelegate

extension MyProjectsViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let entry = self.entry(at: indexPath)
        onOpenEditor(.savedProject(projectId: entry.projectId))
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ProjectPreviewCell)?.willDisplay()
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ProjectPreviewCell)?.didEndDisplaying()
    }
}

// MARK: - Section Header

private final class SectionHeaderView: UICollectionReusableView {

    static let reuseIdentifier = "SectionHeader"

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textColor = .label
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    func configure(title: String) {
        titleLabel.text = title
    }
}
