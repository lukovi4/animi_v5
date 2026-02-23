import UIKit
import MetalKit

// MARK: - Editor Layout Container (PR2.6)

/// Main container view for editor mode layout.
/// Replaces vertical scrollView layout in PlayerViewController when in .editor mode.
///
/// Layout structure (top to bottom):
/// - EditorNavBar (60px)
/// - PreviewContainer (flex, contains MetalView + PreviewMenuStrip overlay)
/// - TimelineContainer (rulerHeight + timelineHeight = 292px)
///   - TimeRulerView (32px) - sticky, synced via direct callback
///   - TimelineView (260px with internal scroll)
///   - PlayheadView (overlay spanning ruler + timeline, fixed at centerX)
/// - BottomBarContainer (72px + safe area)
///
/// PR2.6: Ruler sync is direct (no throttle), using xScrollView.contentOffset.x
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

    /// Unified timeline event callback (PR1).
    /// Forwards scrub and selection events to VC.
    /// Scroll events are handled locally for ruler sync.
    var onTimelineEvent: ((TimelineEvent) -> Void)?

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

    /// PR3: Reorder mode state (UI-only, not part of EditorStore)
    private var isReorderMode: Bool = false

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

        // PR1: Unified timeline event handling
        timelineView.onEvent = { [weak self] event in
            self?.handleTimelineEvent(event)
        }

        // PR3: Reorder mode toggle
        rulerView.onReorderModeChanged = { [weak self] isReorderMode in
            self?.handleReorderModeChanged(isReorderMode)
        }
    }

    // MARK: - Reorder Mode (PR3)

    private func handleReorderModeChanged(_ isReorderMode: Bool) {
        self.isReorderMode = isReorderMode
        timelineView.setReorderMode(isReorderMode)
    }

    // MARK: - Timeline Event Handling (PR1 + PR2)

    /// Routes timeline events: scroll handled locally, others forwarded to VC.
    private func handleTimelineEvent(_ event: TimelineEvent) {
        switch event {
        case .scroll(let offsetX, let pxPerSecond):
            // Handle locally: sync ruler
            rulerView.setContentOffset(CGPoint(x: offsetX, y: 0))
            rulerView.setPxPerSecond(pxPerSecond)

        case .scrub:
            // Forward to VC
            onTimelineEvent?(event)

        case .selection:
            // PR3.1: Only forward to VC. UI updates via store callback.
            onTimelineEvent?(event)

        case .trimScene:
            // PR2: Forward to VC for model update
            onTimelineEvent?(event)

        case .reorderScene:
            // PR3: Forward to VC for model update
            onTimelineEvent?(event)
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

    /// Configures timeline with duration in microseconds and template FPS.
    /// - Parameters:
    ///   - durationUs: Duration in microseconds
    ///   - templateFPS: Template frame rate for quantization
    func configure(durationUs: TimeUs, templateFPS: Int) {
        rulerView.configure(durationUs: durationUs)
        timelineView.configure(durationUs: durationUs, templateFPS: templateFPS)
    }

    /// Configures timeline with scenes array (PR2: Multi-scene support).
    /// - Parameters:
    ///   - scenes: Array of SceneDraft objects
    ///   - templateFPS: Template frame rate for quantization
    ///   - minSceneDurationUs: Minimum scene duration for trim (PR2 fix: consistent with model)
    func configure(scenes: [SceneDraft], templateFPS: Int, minSceneDurationUs: TimeUs = ProjectDraft.minSceneDurationUs) {
        let totalDurationUs = scenes.reduce(0) { $0 + $1.durationUs }
        rulerView.configure(durationUs: totalDurationUs)
        timelineView.configure(scenes: scenes, templateFPS: templateFPS, minSceneDurationUs: minSceneDurationUs)
    }

    /// Updates scenes (for trim operations, without full reconfigure).
    func updateScenes(_ scenes: [SceneDraft]) {
        let totalDurationUs = scenes.reduce(0) { $0 + $1.durationUs }
        rulerView.configure(durationUs: totalDurationUs)
        timelineView.updateScenes(scenes)
    }

    /// Updates current time (from playback or scrub).
    /// - Parameter timeUs: Time in microseconds
    func setCurrentTimeUs(_ timeUs: TimeUs) {
        // PR2.6: Ruler sync happens via onScrollChanged callback from centerOnTimeUs()
        timelineView.setCurrentTimeUs(timeUs)
    }

    /// Updates play/pause button state
    func setPlaying(_ isPlaying: Bool) {
        menuStrip.setPlaying(isPlaying)
    }

    /// Updates timeline selection and switches bottom bar.
    /// P1-3: Also updates track UI highlighting to stay in sync.
    func setTimelineSelection(_ selection: TimelineSelection) {
        currentSelection = selection
        timelineView.setSelection(selection)
        updateBottomBar()
    }

    // MARK: - Timeline State Snapshot/Restore (PR2, Time Refactor)

    /// Creates a snapshot of current timeline state.
    /// Includes time position, zoom, and selection.
    func snapshotTimelineState() -> TimelineState {
        let (timeUs, zoom) = timelineView.snapshotState()
        return TimelineState(
            timeUnderPlayheadUs: timeUs,
            zoom: zoom,
            selection: currentSelection
        )
    }

    /// Reconfigures timeline with new duration while preserving state.
    /// Use this instead of configure() when duration changes to maintain playhead position and zoom.
    /// - Parameters:
    ///   - durationUs: New duration in microseconds
    ///   - templateFPS: Template frame rate for quantization
    func reconfigureTimelinePreservingState(durationUs: TimeUs, templateFPS: Int) {
        // 1. Snapshot current state
        let state = snapshotTimelineState()

        // 2. Configure with new duration (does NOT reset position)
        rulerView.configure(durationUs: durationUs)
        timelineView.configure(durationUs: durationUs, templateFPS: templateFPS)

        // 3. Clamp time if it exceeds new duration
        let clampedTimeUs = clampTimeUs(state.timeUnderPlayheadUs, maxUs: durationUs)

        // 4. Restore selection (atomic with time/zoom)
        setTimelineSelection(state.selection)

        // 5. Restore time and zoom
        timelineView.restoreState(timeUs: clampedTimeUs, zoom: state.zoom)
    }

    // MARK: - Private

    private func updateBottomBar() {
        switch currentSelection {
        case .none:
            globalActionBar.isHidden = false
            contextBar.isHidden = true
        case .scene, .audio:
            // PR2: .scene(id:) matches any scene selection
            globalActionBar.isHidden = true
            contextBar.isHidden = false
        }
    }
}
