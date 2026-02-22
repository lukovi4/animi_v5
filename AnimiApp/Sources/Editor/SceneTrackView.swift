import UIKit

// MARK: - Scene Track View (PR2.6)

/// Visualizes the base scene layer on the timeline.
/// Shows a clip from frame 0 to effectiveDurationFrames.
/// PR2.6: Uses leftPadding to position clip at time=0.
final class SceneTrackView: UIView {

    // MARK: - Configuration

    /// Duration in microseconds (source of truth).
    private var durationUs: TimeUs = 0

    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var leftPadding: CGFloat = 0
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
        // PR2.6: Clip starts at leftPadding (where time=0 is)
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

    /// Configures track with duration in microseconds, pxPerSecond, and leftPadding.
    /// PR2.6: leftPadding is the X position where time=0 starts.
    /// - Parameters:
    ///   - durationUs: Duration in microseconds
    ///   - pxPerSecond: Pixels per second for width calculation
    ///   - leftPadding: Left padding in pixels
    func configure(durationUs: TimeUs, pxPerSecond: CGFloat, leftPadding: CGFloat) {
        self.durationUs = durationUs
        self.pxPerSecond = pxPerSecond
        self.leftPadding = leftPadding
        updateClipLayout()
    }

    /// Updates pixels per second and leftPadding (when timeline zooms or resizes).
    func setPxPerSecond(_ pxPerSec: CGFloat, leftPadding: CGFloat) {
        self.pxPerSecond = pxPerSec
        self.leftPadding = leftPadding
        updateClipLayout()
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

    private func updateClipLayout() {
        guard durationUs > 0 else { return }

        let durationSeconds = CGFloat(usToSeconds(durationUs))
        let clipWidth = durationSeconds * pxPerSecond

        clipWidthConstraint?.constant = clipWidth

        // PR2.6: Clip starts at leftPadding (where time=0 is in contentView coordinates)
        clipLeadingConstraint?.constant = leftPadding
    }
}
