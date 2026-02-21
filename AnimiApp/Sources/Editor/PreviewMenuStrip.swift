import UIKit

// MARK: - Preview Menu Strip (PR2)

/// Overlay strip at bottom of preview area.
/// Contains: Play/Pause (left), Fullscreen toggle (right).
final class PreviewMenuStrip: UIView {

    // MARK: - Callbacks

    var onPlayPause: (() -> Void)?
    var onFullScreen: (() -> Void)?

    // MARK: - State

    private var isPlaying: Bool = false

    // MARK: - Subviews

    private lazy var blurView: UIVisualEffectView = {
        let blur = UIBlurEffect(style: .systemThinMaterial)
        let view = UIVisualEffectView(effect: blur)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var playPauseButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(UIImage(systemName: "play.fill"), for: .normal)
        btn.tintColor = .label
        btn.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var fullScreenButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
        btn.tintColor = .label
        btn.addTarget(self, action: #selector(fullScreenTapped), for: .touchUpInside)
        return btn
    }()

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
        addSubview(blurView)
        addSubview(playPauseButton)
        addSubview(fullScreenButton)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            playPauseButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            playPauseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),

            fullScreenButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            fullScreenButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            fullScreenButton.widthAnchor.constraint(equalToConstant: 44),
            fullScreenButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: - Public API

    /// Updates play/pause button state.
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        let imageName = playing ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: imageName), for: .normal)
    }

    // MARK: - Actions

    @objc private func playPauseTapped() {
        onPlayPause?()
    }

    @objc private func fullScreenTapped() {
        onFullScreen?()
    }
}
