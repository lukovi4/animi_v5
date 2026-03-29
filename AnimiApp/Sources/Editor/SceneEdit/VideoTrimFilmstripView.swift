import UIKit

// MARK: - Video Trim Filmstrip View

/// Horizontal strip of video thumbnails used inside VideoTrimBarView.
/// Displays evenly-spaced frames from the video asset.
final class VideoTrimFilmstripView: UIView {

    // MARK: - Properties

    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        clipsToBounds = true
        layer.cornerRadius = 4

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Public API

    /// Sets the filmstrip thumbnails.
    /// - Parameter images: Ordered array of thumbnail images
    func setThumbnails(_ images: [UIImage]) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for image in images {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            stackView.addArrangedSubview(imageView)
        }
    }

    /// Clears all thumbnails.
    func clear() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }
}
