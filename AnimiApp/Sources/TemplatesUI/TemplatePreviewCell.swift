import UIKit

/// Collection view cell for template preview in catalog.
/// Displays video preview with 9:16 aspect ratio.
final class TemplatePreviewCell: UICollectionViewCell {

    static let reuseIdentifier = "TemplatePreviewCell"

    // MARK: - UI

    private let previewVideoView = PreviewVideoView()

    // MARK: - Data

    private(set) var templateId: TemplateID?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        contentView.backgroundColor = .systemGray6
        contentView.layer.cornerRadius = 8
        contentView.clipsToBounds = true

        previewVideoView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewVideoView)

        NSLayoutConstraint.activate([
            previewVideoView.topAnchor.constraint(equalTo: contentView.topAnchor),
            previewVideoView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            previewVideoView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            previewVideoView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    // MARK: - Configuration

    /// Configures the cell with a template descriptor.
    func configure(with template: TemplateDescriptor) {
        templateId = template.id
        previewVideoView.configure(url: template.previewURL)
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        templateId = nil
        previewVideoView.prepareForReuse()
    }

    // MARK: - Visibility

    /// Call when cell becomes visible.
    func willDisplay() {
        previewVideoView.play()
    }

    /// Call when cell goes off-screen.
    func didEndDisplaying() {
        previewVideoView.pause()
    }
}
