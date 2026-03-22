import UIKit

/// Collection view cell for displaying a saved project in My Projects.
final class ProjectPreviewCell: UICollectionViewCell {

    static let reuseIdentifier = "ProjectPreviewCell"

    // MARK: - UI

    private let previewVideoView = PreviewVideoView()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .label
        label.numberOfLines = 1
        return label
    }()

    private let dateLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    private let deleteButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "trash"), for: .normal)
        button.tintColor = .systemRed
        return button
    }()

    var onDelete: (() -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupUI() {
        previewVideoView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(previewVideoView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(dateLabel)
        contentView.addSubview(deleteButton)

        previewVideoView.layer.cornerRadius = 8
        previewVideoView.clipsToBounds = true

        NSLayoutConstraint.activate([
            previewVideoView.topAnchor.constraint(equalTo: contentView.topAnchor),
            previewVideoView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            previewVideoView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: previewVideoView.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),

            dateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            dateLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),
            dateLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),

            deleteButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 32),
            deleteButton.heightAnchor.constraint(equalToConstant: 32)
        ])

        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
    }

    // MARK: - Configure

    func configure(templateTitle: String, previewURL: URL?, savedAt: Date) {
        titleLabel.text = templateTitle
        dateLabel.text = Self.dateFormatter.string(from: savedAt)
        previewVideoView.configure(url: previewURL)
    }

    /// Call when cell becomes visible.
    func willDisplay() {
        previewVideoView.play()
    }

    /// Call when cell goes off-screen.
    func didEndDisplaying() {
        previewVideoView.pause()
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        previewVideoView.prepareForReuse()
        titleLabel.text = nil
        dateLabel.text = nil
        onDelete = nil
    }

    // MARK: - Actions

    @objc private func deleteTapped() {
        onDelete?()
    }

    // MARK: - Date Formatting

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
