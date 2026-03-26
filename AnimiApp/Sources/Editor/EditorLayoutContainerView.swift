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

    /// Called when undo button tapped (PR-F)
    var onUndo: (() -> Void)?

    /// Called when redo button tapped (PR-F)
    var onRedo: (() -> Void)?

    /// Called when play/pause button tapped
    var onPlayPause: (() -> Void)?

    /// Called when fullscreen preview button tapped
    var onFullScreenPreview: (() -> Void)?

    /// Unified timeline event callback (PR1).
    /// Forwards scrub and selection events to VC.
    /// Scroll events are handled locally for ruler sync.
    var onTimelineEvent: ((TimelineEvent) -> Void)?

    // PR9: Scene context actions
    /// Called when Duplicate scene is tapped
    var onDuplicateScene: ((UUID) -> Void)?

    /// Called when Delete scene is tapped
    var onDeleteScene: ((UUID) -> Void)?

    /// Called when Add Scene is tapped
    var onAddScene: (() -> Void)?

    // PR-C: Scene Edit mode callbacks
    /// Called when Edit scene is tapped (PR-C)
    var onEditScene: ((UUID) -> Void)?

    /// Called when Done is tapped in Scene Edit mode (PR-C)
    var onDone: (() -> Void)?

    // PR-E: SceneEditBar callbacks
    /// Called when Background button is tapped
    var onBackground: (() -> Void)?

    /// Called when Reset Scene button is tapped
    var onResetScene: (() -> Void)?

    // PR-E: MediaBlockActionBar callbacks (blockId parameter)
    /// Called when Add Photo button is tapped
    var onAddPhoto: ((String) -> Void)?

    /// Called when Add Video button is tapped
    var onAddVideo: ((String) -> Void)?

    /// Called when Animation button is tapped
    var onAnimation: ((String) -> Void)?

    /// Called when Disable/Enable button is tapped
    var onToggleEnabled: ((String) -> Void)?

    /// Called when Edit Video button is tapped
    var onEditVideo: ((String) -> Void)?

    /// Called when Remove button is tapped
    var onRemove: ((String) -> Void)?

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

    // PR-C: Scene Edit mode bars
    private(set) lazy var sceneEditBar = SceneEditBar()
    private(set) lazy var mediaBlockActionBar = MediaBlockActionBar()

    // MARK: - State

    private var currentSelection: TimelineSelection = .none

    /// PR3: Reorder mode state (UI-only, not part of EditorStore)
    private var isReorderMode: Bool = false

    /// PR-C: Scene Edit mode state
    private var isSceneEditMode: Bool = false

    // MARK: - Scene Edit Mode Constraints (PR-C)

    /// Constraints active in timeline mode (normal editor)
    private var timelineVisibleConstraints: [NSLayoutConstraint] = []

    /// Constraints active in Scene Edit mode (timeline hidden)
    private var sceneEditConstraints: [NSLayoutConstraint] = []

    /// Preview bottom to timeline top (timeline mode)
    private var previewBottomToTimeline: NSLayoutConstraint!

    /// Preview bottom to bottom bar top (scene edit mode)
    private var previewBottomToBottomBar: NSLayoutConstraint!

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
        bottomBarContainer.addSubview(sceneEditBar)
        bottomBarContainer.addSubview(mediaBlockActionBar)

        // Initial state: GlobalActionBar visible (no scene selected at start)
        globalActionBar.isHidden = false
        contextBar.isHidden = true
        sceneEditBar.isHidden = true
        mediaBlockActionBar.isHidden = true
    }

    private func setupConstraints() {
        navBar.translatesAutoresizingMaskIntoConstraints = false
        menuStrip.translatesAutoresizingMaskIntoConstraints = false
        rulerView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.translatesAutoresizingMaskIntoConstraints = false
        playheadView.translatesAutoresizingMaskIntoConstraints = false
        globalActionBar.translatesAutoresizingMaskIntoConstraints = false
        contextBar.translatesAutoresizingMaskIntoConstraints = false
        sceneEditBar.translatesAutoresizingMaskIntoConstraints = false
        mediaBlockActionBar.translatesAutoresizingMaskIntoConstraints = false

        // PR-C: Create alternative preview bottom constraints
        previewBottomToTimeline = previewContainer.bottomAnchor.constraint(equalTo: timelineContainer.topAnchor)
        previewBottomToBottomBar = previewContainer.bottomAnchor.constraint(equalTo: bottomBarContainer.topAnchor)

        // Shared constraints (always active)
        let sharedConstraints: [NSLayoutConstraint] = [
            // NavBar - top, full width
            navBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: EditorConfig.navBarHeight),

            // PreviewContainer - top and sides (bottom varies by mode)
            previewContainer.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

            // MenuStrip - overlay at bottom of previewContainer
            menuStrip.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            menuStrip.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            menuStrip.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            menuStrip.heightAnchor.constraint(equalToConstant: EditorConfig.previewMenuHeight),

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

            // PR-C: SceneEditBar - fills bottomBarContainer (hidden by default)
            sceneEditBar.topAnchor.constraint(equalTo: bottomBarContainer.topAnchor),
            sceneEditBar.leadingAnchor.constraint(equalTo: bottomBarContainer.leadingAnchor),
            sceneEditBar.trailingAnchor.constraint(equalTo: bottomBarContainer.trailingAnchor),
            sceneEditBar.bottomAnchor.constraint(equalTo: bottomBarContainer.bottomAnchor),

            // PR-C: MediaBlockActionBar - fills bottomBarContainer (hidden by default)
            mediaBlockActionBar.topAnchor.constraint(equalTo: bottomBarContainer.topAnchor),
            mediaBlockActionBar.leadingAnchor.constraint(equalTo: bottomBarContainer.leadingAnchor),
            mediaBlockActionBar.trailingAnchor.constraint(equalTo: bottomBarContainer.trailingAnchor),
            mediaBlockActionBar.bottomAnchor.constraint(equalTo: bottomBarContainer.bottomAnchor),
        ]

        // PR-C: Timeline visible constraints (normal editor mode)
        timelineVisibleConstraints = [
            // Preview bottom to timeline
            previewBottomToTimeline,

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
        ]

        // PR-C: Scene Edit constraints (timeline hidden)
        sceneEditConstraints = [
            // Preview bottom to bottom bar
            previewBottomToBottomBar,
        ]

        // Activate shared + timeline visible by default
        NSLayoutConstraint.activate(sharedConstraints)
        NSLayoutConstraint.activate(timelineVisibleConstraints)
    }

    private func wireCallbacks() {
        // NavBar
        navBar.onClose = { [weak self] in self?.onClose?() }
        navBar.onExport = { [weak self] in self?.onExport?() }
        navBar.onUndo = { [weak self] in self?.onUndo?() }
        navBar.onRedo = { [weak self] in self?.onRedo?() }

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

        // PR9: Context bar actions
        contextBar.onDuplicateScene = { [weak self] sceneId in
            self?.onDuplicateScene?(sceneId)
        }
        contextBar.onDeleteScene = { [weak self] sceneId in
            self?.onDeleteScene?(sceneId)
        }

        // PR9: Global action bar - Add Scene
        globalActionBar.onAddScene = { [weak self] in
            self?.onAddScene?()
        }

        // PR-C: Edit scene
        contextBar.onEditScene = { [weak self] sceneId in
            self?.onEditScene?(sceneId)
        }

        // PR-C: Done from Scene Edit
        navBar.onDone = { [weak self] in
            self?.onDone?()
        }

        // PR-E: SceneEditBar callbacks
        sceneEditBar.onBackground = { [weak self] in
            self?.onBackground?()
        }
        sceneEditBar.onResetScene = { [weak self] in
            self?.onResetScene?()
        }

        // PR-E: MediaBlockActionBar callbacks (pass blockId)
        mediaBlockActionBar.onAddPhoto = { [weak self] blockId in
            self?.onAddPhoto?(blockId)
        }
        mediaBlockActionBar.onAddVideo = { [weak self] blockId in
            self?.onAddVideo?(blockId)
        }
        mediaBlockActionBar.onEditVideo = { [weak self] blockId in
            self?.onEditVideo?(blockId)
        }
        mediaBlockActionBar.onAnimation = { [weak self] blockId in
            self?.onAnimation?(blockId)
        }
        mediaBlockActionBar.onToggleEnabled = { [weak self] blockId in
            self?.onToggleEnabled?(blockId)
        }
        mediaBlockActionBar.onRemove = { [weak self] blockId in
            self?.onRemove?(blockId)
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

        case .editBoundaryTransition:
            // PR-G: Forward to VC for picker presentation
            onTimelineEvent?(event)

        case .focusScene:
            // Forward to VC — playhead moves to scene start, selection derived from playhead
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

    /// Adds EditorOverlayView to previewContainer (PR-C: called by PlayerViewController).
    /// Inserted between metalView and menuStrip for proper z-ordering.
    func embedOverlayView(_ overlay: UIView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // Insert below menuStrip (which is already in previewContainer)
        previewContainer.insertSubview(overlay, belowSubview: menuStrip)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])
    }

    /// Switches between timeline mode and scene edit mode (PR-C).
    /// In scene edit mode: timeline hidden, preview expands, menuStrip hidden.
    /// - Parameters:
    ///   - enabled: Whether to enable scene edit mode
    ///   - animated: Whether to animate the transition
    func setSceneEditMode(_ enabled: Bool, animated: Bool) {
        guard enabled != isSceneEditMode else { return }
        isSceneEditMode = enabled

        if enabled {
            // Scene Edit mode: hide timeline, expand preview
            NSLayoutConstraint.deactivate(timelineVisibleConstraints)
            NSLayoutConstraint.activate(sceneEditConstraints)
            timelineContainer.isHidden = true
            menuStrip.isHidden = true  // Hide (not disable) per review.md

            // Set bottom bar to consistent state on enter scene edit
            globalActionBar.isHidden = true
            contextBar.isHidden = true
            sceneEditBar.isHidden = false      // Default: no block selected
            mediaBlockActionBar.isHidden = true
        } else {
            // Timeline mode: show timeline, restore preview
            NSLayoutConstraint.deactivate(sceneEditConstraints)
            NSLayoutConstraint.activate(timelineVisibleConstraints)
            timelineContainer.isHidden = false
            menuStrip.isHidden = false

            // P2 fix: Hide scene edit bars and restore timeline bar state
            sceneEditBar.isHidden = true
            mediaBlockActionBar.isHidden = true
            updateBottomBar()  // Restores globalActionBar/contextBar based on selection
        }

        if animated {
            UIView.animate(withDuration: 0.25) { self.layoutIfNeeded() }
        } else {
            layoutIfNeeded()
        }
    }

    /// Updates the bottom bar for Scene Edit mode (PR-C).
    /// - Parameter selectedBlockId: Currently selected block, or nil for no selection
    func updateSceneEditBottomBar(selectedBlockId: String?) {
        guard isSceneEditMode else { return }

        if selectedBlockId != nil {
            // Block selected: show MediaBlockActionBar
            sceneEditBar.isHidden = true
            mediaBlockActionBar.isHidden = false
        } else {
            // No block selected: show SceneEditBar
            sceneEditBar.isHidden = false
            mediaBlockActionBar.isHidden = true
        }

        // Hide timeline mode bars
        globalActionBar.isHidden = true
        contextBar.isHidden = true
    }

    /// Configures the MediaBlockActionBar with block-specific data (PR-E).
    /// Called by PlayerViewController when block selection changes.
    /// - Parameters:
    ///   - blockId: The selected block ID
    ///   - allowedMedia: Media types allowed for this block
    ///   - hasVariants: Whether the block has multiple variants
    ///   - hasMedia: Whether the block currently has media assigned
    ///   - isEnabled: Whether the block's binding layer is visible
    func configureMediaBlockActionBar(
        blockId: String,
        allowedMedia: [String]?,
        hasVariants: Bool,
        hasMedia: Bool,
        isEnabled: Bool,
        mediaKind: MediaKind? = nil,
        canEditVideoSelection: Bool = false
    ) {
        mediaBlockActionBar.configure(
            blockId: blockId,
            allowedMedia: allowedMedia,
            hasVariants: hasVariants,
            hasMedia: hasMedia,
            isEnabled: isEnabled,
            mediaKind: mediaKind,
            canEditVideoSelection: canEditVideoSelection
        )
    }

    /// Configures the SceneEditBar reset button state (PR-E).
    /// - Parameter canReset: Whether reset is allowed (false if scene is empty)
    func configureSceneEditBar(canReset: Bool) {
        sceneEditBar.setCanReset(canReset)
    }

    /// Configures timeline with scenes array (PR2: Multi-scene support).
    /// PR-G: Includes boundaries for transition controls.
    /// - Parameters:
    ///   - scenes: Array of SceneDraft objects
    ///   - boundaries: Adjacent scene boundaries with transitions
    ///   - templateFPS: Template frame rate for quantization
    ///   - minSceneDurationUs: Minimum scene duration for trim (PR2 fix: consistent with model)
    func configure(scenes: [SceneDraft], boundaries: [SceneBoundaryDraft], templateFPS: Int, minSceneDurationUs: TimeUs = ProjectDraft.minSceneDurationUs) {
        let totalDurationUs = scenes.reduce(0) { $0 + $1.durationUs }
        rulerView.configure(durationUs: totalDurationUs)
        timelineView.configure(scenes: scenes, boundaries: boundaries, templateFPS: templateFPS, minSceneDurationUs: minSceneDurationUs)
    }

    /// Updates scenes (for trim operations, without full reconfigure).
    /// PR-G: Includes boundaries for transition controls.
    func updateScenes(_ scenes: [SceneDraft], boundaries: [SceneBoundaryDraft]) {
        let totalDurationUs = scenes.reduce(0) { $0 + $1.durationUs }
        rulerView.configure(durationUs: totalDurationUs)
        timelineView.updateScenes(scenes, boundaries: boundaries)
    }

    /// Updates current position from compressed frame (from playback or scrub).
    /// Phase 2.1: Uses mapper for compressed → nominal conversion.
    /// - Parameters:
    ///   - compressedFrame: Compressed frame index
    ///   - mapper: Playhead mapper for coordinate conversion
    func setCurrentCompressedFrame(_ compressedFrame: Int, mapper: TimelinePlayheadMapper) {
        // PR2.6: Ruler sync happens via onScrollChanged callback from centerOnTimeUs()
        timelineView.setCurrentCompressedFrame(compressedFrame, mapper: mapper)
    }

    /// Sets the playhead mapper for timeline.
    /// Phase 2.1: Mapper must be wired after setup and on timeline changes.
    /// - Parameter mapper: Playhead mapper for coordinate conversion
    func setMapper(_ mapper: TimelinePlayheadMapper) {
        timelineView.setMapper(mapper)
    }

    /// Updates play/pause button state
    func setPlaying(_ isPlaying: Bool) {
        menuStrip.setPlaying(isPlaying)
    }

    /// Updates timeline selection and switches bottom bar.
    /// P1-3: Also updates track UI highlighting to stay in sync.
    /// - Parameters:
    ///   - selection: New selection state
    ///   - sceneCount: Total number of scenes (for delete validation in context bar)
    func setTimelineSelection(_ selection: TimelineSelection, sceneCount: Int = 1) {
        currentSelection = selection
        timelineView.setSelection(selection)
        contextBar.configure(for: selection, sceneCount: sceneCount)
        updateBottomBar()
    }

    // MARK: - Timeline State Snapshot/Restore (PR2, Time Refactor, Phase 2.1)

    /// Creates a snapshot of current timeline state.
    /// Phase 2.1: Uses compressed frame as source of truth.
    /// Includes compressed frame position, zoom, and selection.
    func snapshotTimelineState() -> TimelineState {
        let compressedFrame = timelineView.snapshotCompressedFrame()
        return TimelineState(
            playheadCompressedFrame: compressedFrame,
            zoom: timelineView.currentZoom,
            selection: currentSelection
        )
    }

    /// Restores timeline state from snapshot.
    /// Phase 2.1: Uses mapper for compressed frame positioning.
    /// - Parameters:
    ///   - state: Timeline state snapshot
    ///   - mapper: Playhead mapper for coordinate conversion
    func restoreTimelineState(_ state: TimelineState, mapper: TimelinePlayheadMapper) {
        // Restore selection
        setTimelineSelection(state.selection)

        // Restore position and zoom (uses compressed frame)
        timelineView.restoreState(
            compressedFrame: state.playheadCompressedFrame,
            zoom: state.zoom,
            mapper: mapper
        )
    }

    // MARK: - Private

    private func updateBottomBar() {
        guard !isSceneEditMode else { return }
        sceneEditBar.isHidden = true
        mediaBlockActionBar.isHidden = true
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
