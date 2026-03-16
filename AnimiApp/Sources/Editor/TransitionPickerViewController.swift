import UIKit

// MARK: - Transition Picker (PR-G)

/// Modal picker for selecting scene transition presets.
/// Shows 12 fixed presets (none, fade, slide x4, push x4, dip x2).
/// All presets use 14 frames duration.
final class TransitionPickerViewController: UIViewController {

    // MARK: - Callback

    /// Called when user selects a transition. Dismiss happens before this is called.
    var onSelectTransition: ((SceneTransition) -> Void)?

    // MARK: - State

    /// Current transition type (for checkmark display).
    private let currentType: TransitionType

    /// Available presets.
    private let presets: [(label: String, type: TransitionType)] = [
        ("None (Cut)", .none),
        ("Fade", .fade),
        ("Slide Left", .slide(direction: .left)),
        ("Slide Right", .slide(direction: .right)),
        ("Slide Up", .slide(direction: .up)),
        ("Slide Down", .slide(direction: .down)),
        ("Push Left", .push(direction: .left)),
        ("Push Right", .push(direction: .right)),
        ("Push Up", .push(direction: .up)),
        ("Push Down", .push(direction: .down)),
        ("Dip to Black", .dipToBlack),
        ("Dip to White", .dipToWhite)
    ]

    // MARK: - Views

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.dataSource = self
        tv.delegate = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        return tv
    }()

    // MARK: - Initialization

    init(currentType: TransitionType) {
        self.currentType = currentType
        super.init(nibName: nil, bundle: nil)
        title = "Transition"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupNavigation()
    }

    // MARK: - Setup

    private func setupViews() {
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupNavigation() {
        // Cancel button for sheet dismissal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }
}

// MARK: - UITableViewDataSource

extension TransitionPickerViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        presets.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let preset = presets[indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = preset.label
        cell.contentConfiguration = config

        // Checkmark on current selection
        cell.accessoryType = (preset.type == currentType) ? .checkmark : .none

        return cell
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Animated transitions use a fixed duration of 14 frames."
    }
}

// MARK: - UITableViewDelegate

extension TransitionPickerViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let preset = presets[indexPath.row]
        let transition = SceneTransition.v1Preset(for: preset.type)

        // Dismiss first, then call callback
        dismiss(animated: true) { [weak self] in
            self?.onSelectTransition?(transition)
        }
    }
}
