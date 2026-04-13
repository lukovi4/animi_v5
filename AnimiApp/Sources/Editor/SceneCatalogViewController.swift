import UIKit

// MARK: - Scene Catalog View Controller

/// Simple table view for selecting a scene to add from SceneLibrary.
final class SceneCatalogViewController: UITableViewController {

    // MARK: - Properties

    /// Scenes available for selection.
    private let scenes: [SceneTypeDescriptor]

    /// Called when a scene is selected.
    var onSelectScene: ((String, TimeUs) -> Void)?

    // MARK: - Initialization

    /// Creates a catalog with catalog-visible scenes from the library snapshot.
    init(sceneLibrary: SceneLibrarySnapshot) {
        scenes = sceneLibrary.catalogScenes
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Add Scene"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SceneCell")
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    // MARK: - UITableViewDataSource

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        scenes.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SceneCell", for: indexPath)
        let scene = scenes[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = scene.title
        content.secondaryText = formatDuration(scene.baseDurationUs)
        cell.contentConfiguration = content

        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let scene = scenes[indexPath.row]
        dismiss(animated: true) { [weak self] in
            self?.onSelectScene?(scene.id, scene.baseDurationUs)
        }
    }

    // MARK: - Private

    private func formatDuration(_ us: TimeUs) -> String {
        let seconds = Double(us) / 1_000_000.0
        return String(format: "%.1fs", seconds)
    }
}
