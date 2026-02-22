import UIKit

// MARK: - Audio Track View (PR2.6)

/// Placeholder track for audio layer.
/// Shows an empty track with "Audio" label (no functionality in PR2).
/// PR2.6: Uses leftPadding to position track at time=0.
final class AudioTrackView: UIView {

    // MARK: - Configuration

    /// Duration in microseconds (source of truth).
    private var durationUs: TimeUs = 0

    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var leftPadding: CGFloat = 0
    private var isSelected: Bool = false

    // MARK: - Appearance

    private let normalColor: UIColor = .systemGray4
    private let selectedColor: UIColor = .systemGray3
    private let labelColor: UIColor = .secondaryLabel
    private let cornerRadius: CGFloat = 6

    // MARK: - Subviews

    private lazy var trackBackground: UIView = {
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
        iv.image = UIImage(systemName: "music.note")
        iv.tintColor = labelColor
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Audio"
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = labelColor
        return label
    }()

    private var trackWidthConstraint: NSLayoutConstraint?
    private var trackLeadingConstraint: NSLayoutConstraint?

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
        addSubview(trackBackground)
        trackBackground.addSubview(iconImageView)
        trackBackground.addSubview(titleLabel)
    }

    private func setupConstraints() {
        // PR2.6: Track starts at leftPadding (where time=0 is)
        trackLeadingConstraint = trackBackground.leadingAnchor.constraint(equalTo: leadingAnchor)
        trackWidthConstraint = trackBackground.widthAnchor.constraint(equalToConstant: 200)

        NSLayoutConstraint.activate([
            trackLeadingConstraint!,
            trackBackground.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            trackBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            trackWidthConstraint!,

            iconImageView.leadingAnchor.constraint(equalTo: trackBackground.leadingAnchor, constant: 8),
            iconImageView.centerYAnchor.constraint(equalTo: trackBackground.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 14),
            iconImageView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: trackBackground.centerYAnchor),
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
        updateTrackLayout()
    }

    /// Updates pixels per second and leftPadding (when timeline zooms or resizes).
    func setPxPerSecond(_ pxPerSec: CGFloat, leftPadding: CGFloat) {
        self.pxPerSecond = pxPerSec
        self.leftPadding = leftPadding
        updateTrackLayout()
    }

    /// Sets selection state.
    func setSelected(_ selected: Bool) {
        isSelected = selected
        UIView.animate(withDuration: 0.2) {
            self.trackBackground.backgroundColor = selected ? self.selectedColor : self.normalColor
        }
    }

    // MARK: - Private

    private func updateTrackLayout() {
        guard durationUs > 0 else { return }

        let durationSeconds = CGFloat(usToSeconds(durationUs))
        let trackWidth = durationSeconds * pxPerSecond

        trackWidthConstraint?.constant = trackWidth

        // PR2.6: Track starts at leftPadding (where time=0 is in contentView coordinates)
        trackLeadingConstraint?.constant = leftPadding
    }
}
