import UIKit

// MARK: - Audio Track View (PR2)

/// Placeholder track for audio layer.
/// Shows an empty track with "Audio" label (no functionality in PR2).
final class AudioTrackView: UIView {

    // MARK: - Configuration

    private var durationFrames: Int = 0
    private var fps: Int = 30
    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
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
        trackWidthConstraint = trackBackground.widthAnchor.constraint(equalToConstant: 200)

        NSLayoutConstraint.activate([
            trackBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
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

    /// Configures track with duration and FPS.
    func configure(durationFrames: Int, fps: Int, pxPerSecond: CGFloat) {
        self.durationFrames = durationFrames
        self.fps = fps > 0 ? fps : 30
        self.pxPerSecond = pxPerSecond
        updateTrackSize()
    }

    /// Updates pixels per second (when timeline zooms).
    func setPxPerSecond(_ pxPerSec: CGFloat) {
        pxPerSecond = pxPerSec
        updateTrackSize()
    }

    /// Sets selection state.
    func setSelected(_ selected: Bool) {
        isSelected = selected
        UIView.animate(withDuration: 0.2) {
            self.trackBackground.backgroundColor = selected ? self.selectedColor : self.normalColor
        }
    }

    // MARK: - Private

    private func updateTrackSize() {
        guard durationFrames > 0, fps > 0 else { return }

        let durationSeconds = CGFloat(durationFrames) / CGFloat(fps)
        let trackWidth = durationSeconds * pxPerSecond

        trackWidthConstraint?.constant = trackWidth
    }
}
