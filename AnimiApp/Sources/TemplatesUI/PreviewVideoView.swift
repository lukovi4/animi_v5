import UIKit
import AVFoundation

/// A view that plays video preview with loop, autoplay, and mute.
/// Designed for template preview cards in catalog.
final class PreviewVideoView: UIView {

    // MARK: - Properties

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: Any?
    private var resignActiveObserver: Any?
    private var becomeActiveObserver: Any?

    /// Whether the view is currently visible and should play.
    private var isVisible = false

    /// URL of the current video.
    private(set) var currentURL: URL?

    // MARK: - Placeholder

    private lazy var placeholderView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.systemGray5
        view.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: UIImage(systemName: "play.rectangle"))
        iconView.tintColor = .systemGray3
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40)
        ])

        return view
    }()

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
        backgroundColor = .black
        clipsToBounds = true

        addSubview(placeholderView)
        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: topAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Subscribe to app lifecycle notifications
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.player?.pause()
        }

        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isVisible else { return }
            self.player?.play()
        }
    }

    deinit {
        if let observer = resignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = becomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        cleanup()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    // MARK: - Configuration

    /// Configures the view with a video URL. Pass nil to show placeholder.
    func configure(url: URL?) {
        // Skip if same URL
        guard url != currentURL else { return }

        cleanup()
        currentURL = url

        guard let url = url else {
            showPlaceholder()
            return
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            showPlaceholder()
            return
        }

        setupPlayer(with: url)
    }

    private func setupPlayer(with url: URL) {
        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        player.actionAtItemEnd = .none

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        layer.insertSublayer(playerLayer, at: 0)

        self.player = player
        self.playerLayer = playerLayer

        // Setup loop
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isVisible else { return }
            self.player?.seek(to: .zero)
            self.player?.play()
        }

        hidePlaceholder()

        // Start playing if visible
        if isVisible {
            player.play()
        }
    }

    private func cleanup() {
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        currentURL = nil
    }

    // MARK: - Placeholder

    private func showPlaceholder() {
        placeholderView.isHidden = false
    }

    private func hidePlaceholder() {
        placeholderView.isHidden = true
    }

    // MARK: - Playback Control

    /// Call when the view becomes visible (e.g., willDisplay).
    func play() {
        isVisible = true
        player?.play()
    }

    /// Call when the view becomes invisible (e.g., didEndDisplaying).
    func pause() {
        isVisible = false
        player?.pause()
    }

    /// Prepares for reuse (pause but keep configured).
    func prepareForReuse() {
        pause()
    }
}
