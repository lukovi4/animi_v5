import UIKit

// MARK: - Scene Catalog View Controller (PR9)

/// Simple table view for selecting a scene to add from SceneLibrary.
final class SceneCatalogViewController: UITableViewController {

    // MARK: - Types

    /// Scene item for display in table.
    struct SceneItem {
        let sceneTypeId: String
        let title: String
        let baseDurationUs: TimeUs
    }

    // MARK: - Properties

    /// Scenes available for selection.
    private var scenes: [SceneItem] = []

    /// Called when a scene is selected.
    var onSelectScene: ((String, TimeUs) -> Void)?

    // MARK: - Initialization

    /// Creates a catalog with scenes from the library snapshot.
    init(sceneLibrary: SceneLibrarySnapshot) {
        super.init(style: .plain)

        // Build scene items from library (ordered)
        scenes = sceneLibrary.scenesInOrder.map { descriptor in
            SceneItem(
                sceneTypeId: descriptor.id,
                title: descriptor.title,
                baseDurationUs: descriptor.baseDurationUs
            )
        }
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
        let item = scenes[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.secondaryText = formatDuration(item.baseDurationUs)
        cell.contentConfiguration = content

        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = scenes[indexPath.row]
        dismiss(animated: true) { [weak self] in
            self?.onSelectScene?(item.sceneTypeId, item.baseDurationUs)
        }
    }

    // MARK: - Private

    private func formatDuration(_ us: TimeUs) -> String {
        let seconds = Double(us) / 1_000_000.0
        return String(format: "%.1fs", seconds)
    }
}
