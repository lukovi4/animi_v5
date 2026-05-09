import UIKit

// MARK: - Audio Track View (PR8: Real Clip Display)

/// Track view for audio layer.
/// Shows a real music clip when present, or an empty lane when no music.
final class AudioTrackView: UIView {

    // MARK: - Configuration

    /// Duration in microseconds (source of truth).
    private var durationUs: TimeUs = 0

    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var leftPadding: CGFloat = 0
    private var clipOffsetPx: CGFloat = 0
    private var isSelected: Bool = false
    private var hasClip: Bool = false

    // MARK: - Appearance

    private let normalColor: UIColor = .systemGray4
    private let selectedColor: UIColor = .systemGray3
    private let emptyColor: UIColor = .systemGray5
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
        label.text = "Music"
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = labelColor
        return label
    }()

    /// Empty state label shown when no music is added
    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "No music"
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
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
        addSubview(emptyLabel)
        addSubview(trackBackground)
        trackBackground.addSubview(iconImageView)
        trackBackground.addSubview(titleLabel)
    }

    private func setupConstraints() {
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

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Configuration

    /// Configures track with duration in microseconds, pxPerSecond, leftPadding, and clip offset.
    /// - Parameters:
    ///   - durationUs: Duration in microseconds
    ///   - pxPerSecond: Pixels per second for width calculation
    ///   - leftPadding: Left padding in pixels
    ///   - clipOffsetPx: Clip start offset in pixels (from startUs)
    func configure(durationUs: TimeUs, pxPerSecond: CGFloat, leftPadding: CGFloat, clipOffsetPx: CGFloat = 0) {
        self.durationUs = durationUs
        self.pxPerSecond = pxPerSecond
        self.leftPadding = leftPadding
        self.clipOffsetPx = clipOffsetPx
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

    /// PR8: Sets whether a real music clip is present.
    func setHasClip(_ has: Bool) {
        hasClip = has
        trackBackground.isHidden = !has
        emptyLabel.isHidden = has
        if has {
            updateTrackLayout()
        }
    }

    // MARK: - Private

    private func updateTrackLayout() {
        guard durationUs > 0, hasClip else { return }

        let durationSeconds = CGFloat(usToSeconds(durationUs))
        let trackWidth = durationSeconds * pxPerSecond

        trackWidthConstraint?.constant = trackWidth
        trackLeadingConstraint?.constant = leftPadding + clipOffsetPx
    }
}
