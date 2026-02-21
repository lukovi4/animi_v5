import UIKit

// MARK: - Scene Track View (PR2)

/// Visualizes the base scene layer on the timeline.
/// Shows a clip from frame 0 to effectiveDurationFrames.
final class SceneTrackView: UIView {

    // MARK: - Configuration

    private var durationFrames: Int = 0
    private var fps: Int = 30
    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var isSelected: Bool = false

    // MARK: - Appearance

    private let normalColor: UIColor = .systemBlue
    private let selectedColor: UIColor = .systemCyan
    private let labelColor: UIColor = .white
    private let cornerRadius: CGFloat = 8

    // MARK: - Subviews

    private lazy var clipView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = normalColor
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        return view
    }()

    private lazy var iconImageView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.image = UIImage(systemName: "film")
        iv.tintColor = labelColor
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Scene"
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = labelColor
        return label
    }()

    private var clipWidthConstraint: NSLayoutConstraint?
    private var clipLeadingConstraint: NSLayoutConstraint?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        setupConstraints()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .clear
        addSubview(clipView)
        clipView.addSubview(iconImageView)
        clipView.addSubview(titleLabel)
    }

    private func setupConstraints() {
        // Clip starts after left padding (half screen width in TimelineView)
        // But for simplicity, we use leading constraint that will be updated
        clipLeadingConstraint = clipView.leadingAnchor.constraint(equalTo: leadingAnchor)
        clipWidthConstraint = clipView.widthAnchor.constraint(equalToConstant: 200)

        NSLayoutConstraint.activate([
            clipLeadingConstraint!,
            clipView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            clipWidthConstraint!,

            iconImageView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 8),
            iconImageView.centerYAnchor.constraint(equalTo: clipView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: clipView.centerYAnchor),
        ])
    }

    // MARK: - Configuration

    /// Configures track with duration and FPS.
    func configure(durationFrames: Int, fps: Int, pxPerSecond: CGFloat) {
        self.durationFrames = durationFrames
        self.fps = fps > 0 ? fps : 30
        self.pxPerSecond = pxPerSecond
        updateClipSize()
    }

    /// Updates pixels per second (when timeline zooms).
    func setPxPerSecond(_ pxPerSec: CGFloat) {
        pxPerSecond = pxPerSec
        updateClipSize()
    }

    /// Sets selection state.
    func setSelected(_ selected: Bool) {
        isSelected = selected
        UIView.animate(withDuration: 0.2) {
            self.clipView.backgroundColor = selected ? self.selectedColor : self.normalColor
            self.clipView.transform = selected ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }
    }

    // MARK: - Private

    private func updateClipSize() {
        guard durationFrames > 0, fps > 0 else { return }

        let durationSeconds = CGFloat(durationFrames) / CGFloat(fps)
        let clipWidth = durationSeconds * pxPerSecond

        clipWidthConstraint?.constant = clipWidth

        // Clip starts at "frame 0" position which is at leading edge of content
        // (padding is handled by TimelineView's contentView)
        clipLeadingConstraint?.constant = 0
    }
}
