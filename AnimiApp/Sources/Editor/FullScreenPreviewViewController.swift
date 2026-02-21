import UIKit
import MetalKit

// MARK: - Full Screen Preview View Controller (PR2)

/// Full-screen preview without timeline.
/// Minimal UI: play/pause and close button.
/// Returns to editor preserving current frame position.
final class FullScreenPreviewViewController: UIViewController {

    // MARK: - Callbacks

    /// Called when close button tapped. Returns current frame index.
    var onClose: ((Int) -> Void)?

    /// Called when play/pause tapped.
    var onPlayPause: (() -> Void)?

    // MARK: - State

    private var currentFrame: Int = 0
    private var isPlaying: Bool = false

    // MARK: - Subviews

    private lazy var metalViewContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        return view
    }()

    private lazy var controlsContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()

    private lazy var blurView: UIVisualEffectView = {
        let blur = UIBlurEffect(style: .systemThinMaterialDark)
        let view = UIVisualEffectView(effect: blur)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        view.clipsToBounds = true
        return view
    }()

    private lazy var closeButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        btn.tintColor = .white
        btn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return btn
    }()

    private lazy var playPauseButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(UIImage(systemName: "play.fill"), for: .normal)
        btn.tintColor = .white
        btn.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        return btn
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupConstraints()
        setupGestures()
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    // MARK: - Setup

    private func setupViews() {
        view.backgroundColor = .black

        view.addSubview(metalViewContainer)
        view.addSubview(controlsContainer)

        controlsContainer.addSubview(blurView)
        controlsContainer.addSubview(closeButton)
        controlsContainer.addSubview(playPauseButton)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Metal view fills screen
            metalViewContainer.topAnchor.constraint(equalTo: view.topAnchor),
            metalViewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalViewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metalViewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Controls at bottom center
            controlsContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            controlsContainer.heightAnchor.constraint(equalToConstant: 60),

            blurView.topAnchor.constraint(equalTo: controlsContainer.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: controlsContainer.bottomAnchor),

            closeButton.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            playPauseButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 24),
            playPauseButton.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -16),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func setupGestures() {
        // Tap anywhere to toggle controls visibility
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tapGesture)
    }

    // MARK: - Public API

    /// Embeds the Metal view from PlayerViewController.
    func embedMetalView(_ metalView: MTKView) {
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalViewContainer.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: metalViewContainer.topAnchor),
            metalView.leadingAnchor.constraint(equalTo: metalViewContainer.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: metalViewContainer.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: metalViewContainer.bottomAnchor),
        ])
    }

    /// Sets initial state.
    func configure(currentFrame: Int, isPlaying: Bool) {
        self.currentFrame = currentFrame
        self.isPlaying = isPlaying
        updatePlayPauseButton()
    }

    /// Updates current frame (from playback).
    func setCurrentFrame(_ frame: Int) {
        currentFrame = frame
    }

    /// Updates playing state.
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        updatePlayPauseButton()
    }

    // MARK: - Private

    private func updatePlayPauseButton() {
        let imageName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: imageName), for: .normal)
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        onClose?(currentFrame)
    }

    @objc private func playPauseTapped() {
        onPlayPause?()
    }

    @objc private func handleTap() {
        UIView.animate(withDuration: 0.2) {
            self.controlsContainer.alpha = self.controlsContainer.alpha > 0.5 ? 0 : 1
        }
    }
}
