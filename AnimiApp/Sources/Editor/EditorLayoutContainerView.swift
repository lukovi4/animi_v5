import UIKit
import MetalKit

// MARK: - Editor Layout Container (PR2)

/// Main container view for editor mode layout.
/// Replaces vertical scrollView layout in PlayerViewController when in .editor mode.
///
/// Layout structure (top to bottom):
/// - EditorNavBar (60px)
/// - PreviewContainer (flex, contains MetalView + PreviewMenuStrip overlay)
/// - TimelineContainer (rulerHeight + timelineHeight = 292px)
///   - TimeRulerView (32px)
///   - TimelineView (260px with internal scroll)
///   - PlayheadView (overlay spanning ruler + timeline)
/// - BottomBarContainer (72px + safe area)
final class EditorLayoutContainerView: UIView {

    // MARK: - Callbacks

    /// Called when close button tapped
    var onClose: (() -> Void)?

    /// Called when export button tapped
    var onExport: (() -> Void)?

    /// Called when play/pause button tapped
    var onPlayPause: (() -> Void)?

    /// Called when fullscreen preview button tapped
    var onFullScreenPreview: (() -> Void)?

    /// Called when timeline is scrubbed (frame index)
    var onScrub: ((Int) -> Void)?

    /// Called when timeline selection changes
    var onTimelineSelectionChanged: ((TimelineSelection) -> Void)?

    // MARK: - Subviews

    private(set) lazy var navBar = EditorNavBar()

    private(set) lazy var previewContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clipsToBounds = true
        return view
    }()

    private(set) lazy var menuStrip = PreviewMenuStrip()

    private(set) lazy var timelineContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clipsToBounds = true
        view.backgroundColor = .secondarySystemBackground
        return view
    }()

    private(set) lazy var rulerView = TimeRulerView()
    private(set) lazy var timelineView = TimelineView()
    private(set) lazy var playheadView = PlayheadView()

    private(set) lazy var bottomBarContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }()

    private(set) lazy var globalActionBar = GlobalActionBar()
    private(set) lazy var contextBar = ContextBar()

    // MARK: - State

    private var currentSelection: TimelineSelection = .none

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        setupConstraints()
        wireCallbacks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .systemBackground

        // Add subviews
        addSubview(navBar)
        addSubview(previewContainer)
        addSubview(timelineContainer)
        addSubview(bottomBarContainer)

        // Preview container contents
        previewContainer.addSubview(menuStrip)

        // Timeline container contents
        timelineContainer.addSubview(rulerView)
        timelineContainer.addSubview(timelineView)
        timelineContainer.addSubview(playheadView)

        // Bottom bar contents
        bottomBarContainer.addSubview(globalActionBar)
        bottomBarContainer.addSubview(contextBar)

        // Initial state: show GlobalActionBar
        contextBar.isHidden = true
    }

    private func setupConstraints() {
        navBar.translatesAutoresizingMaskIntoConstraints = false
        menuStrip.translatesAutoresizingMaskIntoConstraints = false
        rulerView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.translatesAutoresizingMaskIntoConstraints = false
        playheadView.translatesAutoresizingMaskIntoConstraints = false
        globalActionBar.translatesAutoresizingMaskIntoConstraints = false
        contextBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // NavBar - top, full width
            navBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: EditorConfig.navBarHeight),

            // PreviewContainer - between navBar and timelineContainer
            previewContainer.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: timelineContainer.topAnchor),

            // MenuStrip - overlay at bottom of previewContainer
            menuStrip.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            menuStrip.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            menuStrip.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            menuStrip.heightAnchor.constraint(equalToConstant: EditorConfig.previewMenuHeight),

            // TimelineContainer - fixed height above bottomBar
            timelineContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            timelineContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            timelineContainer.bottomAnchor.constraint(equalTo: bottomBarContainer.topAnchor),
            timelineContainer.heightAnchor.constraint(equalToConstant: EditorConfig.rulerHeight + EditorConfig.timelineHeight),

            // RulerView - top of timelineContainer
            rulerView.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            rulerView.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            rulerView.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            rulerView.heightAnchor.constraint(equalToConstant: EditorConfig.rulerHeight),

            // TimelineView - below ruler
            timelineView.topAnchor.constraint(equalTo: rulerView.bottomAnchor),
            timelineView.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            timelineView.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            timelineView.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),

            // PlayheadView - overlay spanning ruler + timeline, centered horizontally
            playheadView.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            playheadView.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            playheadView.centerXAnchor.constraint(equalTo: timelineContainer.centerXAnchor),
            playheadView.widthAnchor.constraint(equalToConstant: 2),

            // BottomBarContainer - bottom with safe area
            bottomBarContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBarContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBarContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            bottomBarContainer.heightAnchor.constraint(equalToConstant: EditorConfig.bottomBarHeight),

            // GlobalActionBar - fills bottomBarContainer
            globalActionBar.topAnchor.constraint(equalTo: bottomBarContainer.topAnchor),
            globalActionBar.leadingAnchor.constraint(equalTo: bottomBarContainer.leadingAnchor),
            globalActionBar.trailingAnchor.constraint(equalTo: bottomBarContainer.trailingAnchor),
            globalActionBar.bottomAnchor.constraint(equalTo: bottomBarContainer.bottomAnchor),

            // ContextBar - fills bottomBarContainer (hidden by default)
            contextBar.topAnchor.constraint(equalTo: bottomBarContainer.topAnchor),
            contextBar.leadingAnchor.constraint(equalTo: bottomBarContainer.leadingAnchor),
            contextBar.trailingAnchor.constraint(equalTo: bottomBarContainer.trailingAnchor),
            contextBar.bottomAnchor.constraint(equalTo: bottomBarContainer.bottomAnchor),
        ])
    }

    private func wireCallbacks() {
        // NavBar
        navBar.onClose = { [weak self] in self?.onClose?() }
        navBar.onExport = { [weak self] in self?.onExport?() }

        // MenuStrip
        menuStrip.onPlayPause = { [weak self] in self?.onPlayPause?() }
        menuStrip.onFullScreen = { [weak self] in self?.onFullScreenPreview?() }

        // Timeline
        timelineView.onScrub = { [weak self] frame in self?.onScrub?(frame) }
        timelineView.onSelectionChanged = { [weak self] selection in
            self?.handleTimelineSelectionChanged(selection)
        }

        // Sync ruler with timeline scroll/zoom
        timelineView.onScrollChanged = { [weak self] offset, pxPerSecond in
            self?.rulerView.setContentOffset(offset)
            self?.rulerView.setPxPerSecond(pxPerSecond)
        }
    }

    // MARK: - Public API

    /// Adds MetalView to previewContainer (called by PlayerViewController)
    func embedMetalView(_ metalView: MTKView) {
        metalView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.insertSubview(metalView, at: 0)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            metalView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])
    }

    /// Configures timeline with duration and FPS
    func configure(durationFrames: Int, fps: Int) {
        rulerView.configure(durationFrames: durationFrames, fps: fps)
        timelineView.configure(durationFrames: durationFrames, fps: fps)
    }

    /// Updates current frame (from playback or scrub)
    func setCurrentFrame(_ frame: Int) {
        timelineView.setCurrentFrame(frame)
        rulerView.setContentOffset(timelineView.contentOffset)
    }

    /// Updates play/pause button state
    func setPlaying(_ isPlaying: Bool) {
        menuStrip.setPlaying(isPlaying)
    }

    /// Updates timeline selection and switches bottom bar
    func setTimelineSelection(_ selection: TimelineSelection) {
        currentSelection = selection
        updateBottomBar()
    }

    // MARK: - Private

    private func handleTimelineSelectionChanged(_ selection: TimelineSelection) {
        currentSelection = selection
        updateBottomBar()
        onTimelineSelectionChanged?(selection)
    }

    private func updateBottomBar() {
        switch currentSelection {
        case .none:
            globalActionBar.isHidden = false
            contextBar.isHidden = true
        case .scene, .audio:
            globalActionBar.isHidden = true
            contextBar.isHidden = false
        }
    }
}
