import UIKit

// MARK: - Timeline View (PR2: Y-scroll + Trim, PR4: Data/Layout split)

/// 2D scrolling timeline with pinch zoom and trim support.
/// Contains track views (SceneTrackView, AudioTrackView).
/// Supports scrubbing, selection, and trim handles.
///
/// PR2 Architecture:
/// - Single scrollView with 2D content (X = time, Y = tracks)
/// - No nested scroll views, no gesture conflicts
/// - Real padding via contentWidth = leftPad + duration*pps + rightPad
/// - Zoom anchored under playhead (center of screen)
///
/// PR4 Architecture:
/// - Data path: applySnapshot (scenes change) - infrequent
/// - Layout path: setLayoutContext (zoom/scroll) - frequent
/// - Scroll/zoom does NOT trigger data updates
///
/// Playhead model: playhead is fixed at center X of the view.
/// Content scrolls underneath. leftPaddingPx provides space so
/// frame 0 can be centered and last frame can be centered.
final class TimelineView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    // MARK: - Callbacks (PR1: Unified TimelineEvent)

    /// Unified event callback for all timeline interactions.
    /// Replaces onScrub, onScrollChanged, onSelectionChanged.
    var onEvent: ((TimelineEvent) -> Void)?

    // MARK: - Configuration

    /// Duration in microseconds (source of truth for timeline length).
    private var durationUs: TimeUs = 0

    /// Scenes array for multi-scene support (PR2).
    private var scenes: [SceneDraft] = []

    /// Template FPS for frame quantization (used only for derived calculations).
    private var templateFPS: Int = 30

    private var currentZoom: CGFloat = 1.0

    /// Current time under playhead in microseconds.
    private var currentTimeUs: TimeUs = 0

    /// Currently selected scene ID (for trim handles).
    private var selectedSceneId: UUID?

    /// PR3: Reorder mode state
    private var isReorderMode: Bool = false

    /// PR4: Min scene duration for trim clamp (model constraint)
    private var minSceneDurationUs: TimeUs = ProjectDraft.minSceneDurationUs

    // MARK: - Initial Positioning State

    private var didInitialPositioning = false
    private var stateWasRestored = false

    // MARK: - Scrub Session State (PR1)

    /// Tracks whether a drag-based scrub session is active.
    private var isScrubSessionActive = false

    /// Last emitted scrub time to avoid redundant .changed events during drag.
    private var lastEmittedScrubTimeUs: TimeUs?

    // MARK: - Computed Properties

    private var pxPerSecond: CGFloat {
        EditorConfig.basePxPerSecond * currentZoom
    }

    /// Pixels per frame (derived from pxPerSecond and templateFPS).
    /// Used for frame-based grid drawing if needed.
    private var pxPerFrame: CGFloat {
        guard templateFPS > 0 else { return 1 }
        return pxPerSecond / CGFloat(templateFPS)
    }

    /// Left padding = half of view width (so time=0 can be under playhead at center)
    private var leftPaddingPx: CGFloat {
        bounds.width / 2
    }

    /// Right padding = half of view width (so last frame can be under playhead)
    private var rightPaddingPx: CGFloat {
        bounds.width / 2
    }

    /// Duration in seconds (derived from durationUs).
    private var durationSeconds: CGFloat {
        CGFloat(usToSeconds(durationUs))
    }

    /// Total content width = leftPad + duration*pxPerSecond + rightPad
    private var totalContentWidth: CGFloat {
        leftPaddingPx + durationSeconds * pxPerSecond + rightPaddingPx
    }

    /// Maximum valid offset (when last frame is under playhead)
    private var maxOffsetX: CGFloat {
        durationSeconds * pxPerSecond
    }

    /// Current content offset X (for external access)
    var contentOffsetX: CGFloat {
        scrollView.contentOffset.x
    }

    // MARK: - Subviews (PR2: Single 2D ScrollView)

    /// Single scroll view for both X (time) and Y (tracks) scrolling.
    /// PR2: Replaces separate scrollView with unified 2D scroll.
    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        // PR2 v5: Hide indicators, disable bounce for clean UX
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.delegate = self
        sv.decelerationRate = .fast
        sv.alwaysBounceHorizontal = false
        sv.alwaysBounceVertical = false
        sv.isDirectionalLockEnabled = true
        return sv
    }()

    /// Content inside scrollView (width = leftPad + duration*pps + rightPad)
    private lazy var contentView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        return v
    }()

    /// Vertical stack of track views
    private lazy var tracksStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4
        stack.distribution = .fill
        return stack
    }()

    private lazy var sceneTrack = SceneTrackView()
    private lazy var audioTrack = AudioTrackView()

    #if DEBUG
    /// PR2 v8: Extra audio tracks to test Y-scroll
    private var debugAudioTracks: [AudioTrackView] = []
    #endif

    private var contentWidthConstraint: NSLayoutConstraint?

    // MARK: - Gestures

    private lazy var pinchGesture: UIPinchGestureRecognizer = {
        let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        gesture.delegate = self
        return gesture
    }()

    private lazy var tapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        return gesture
    }()

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        setupConstraints()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .secondarySystemBackground

        // PR2 Hierarchy: scrollView → contentView → tracksStack
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(tracksStack)

        // Add tracks
        tracksStack.addArrangedSubview(sceneTrack)
        tracksStack.addArrangedSubview(audioTrack)

        #if DEBUG
        // PR2 v8: Add 8 extra audio tracks to force vertical scroll for testing
        for _ in 0..<8 {
            let track = AudioTrackView()
            debugAudioTracks.append(track)
            tracksStack.addArrangedSubview(track)
        }
        #endif

        // Wire sceneTrack callbacks for selection and trim
        wireSceneTrackCallbacks()
    }

    private func wireSceneTrackCallbacks() {
        sceneTrack.onSelectScene = { [weak self] sceneId in
            guard let self = self else { return }
            self.selectedSceneId = sceneId
            self.sceneTrack.setSelectedScene(sceneId)
            self.audioTrack.setSelected(false)
            self.emitEvent(.selection(.scene(id: sceneId)))
        }

        sceneTrack.onTrimScene = { [weak self] sceneId, newDurationUs, edge, phase in
            guard let self = self else { return }
            self.emitEvent(.trimScene(sceneId: sceneId, newDurationUs: newDurationUs, edge: edge, phase: phase))
        }

        // PR3: Reorder scene callback
        sceneTrack.onReorderScene = { [weak self] sceneId, toIndex, phase in
            guard let self = self else { return }
            self.emitEvent(.reorderScene(sceneId: sceneId, toIndex: toIndex, phase: phase))
        }

        // PR2 fix: Handle pan gesture conflicts - scroll should yield to trim handle
        // PR3: Also yield to body pan gesture for reorder
        sceneTrack.onClipCreated = { [weak self] clipView in
            guard let self = self else { return }
            self.scrollView.panGestureRecognizer.require(toFail: clipView.trailingPanGesture)
            self.scrollView.panGestureRecognizer.require(toFail: clipView.bodyPanGesture)
        }
    }

    private func setupConstraints() {
        sceneTrack.translatesAutoresizingMaskIntoConstraints = false
        audioTrack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // scrollView fills TimelineView
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // contentView inside scrollView (contentLayoutGuide)
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            // PR2 v6: Only width >= viewport (NOT height - that stretches tracks!)
            contentView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),

            // tracksStack inside contentView
            tracksStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tracksStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tracksStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // PR2 v5: equalTo (not <=) so content height grows with stack
            tracksStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            // Track heights
            sceneTrack.heightAnchor.constraint(equalToConstant: 60),
            audioTrack.heightAnchor.constraint(equalToConstant: 40),
        ])

        #if DEBUG
        // PR2 v8: Height constraints for debug audio tracks
        for track in debugAudioTracks {
            track.translatesAutoresizingMaskIntoConstraints = false
            track.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
        #endif

        // Content width constraint (will be updated in updateContentSize)
        contentWidthConstraint = contentView.widthAnchor.constraint(equalToConstant: 1000)
        contentWidthConstraint?.isActive = true
    }

    private func setupGestures() {
        // Pinch on the whole view
        addGestureRecognizer(pinchGesture)

        // Tap on tracks area
        scrollView.addGestureRecognizer(tapGesture)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Update content size when view size changes (padding depends on bounds)
        updateContentSize()

        // Initial positioning: ensure frame 0 is under playhead on first layout
        // PR2 fix: setting contentOffset triggers scrollViewDidScroll which emits .scroll
        if !didInitialPositioning && !stateWasRestored && bounds.width > 0 {
            didInitialPositioning = true
            // offset=0 means time=0 is under playhead (at center)
            scrollView.contentOffset = CGPoint(x: 0, y: 0)
        }
    }

    // MARK: - Configuration

    /// Configures timeline with duration in microseconds and template FPS.
    /// Does NOT reset position - use restoreState() to set position after configure.
    /// PR4: Legacy single-scene API, converts to scenes array internally.
    /// - Parameters:
    ///   - durationUs: Duration in microseconds (source of truth)
    ///   - templateFPS: Template frame rate for quantization
    func configure(durationUs: TimeUs, templateFPS: Int) {
        // Convert to single-scene array for PR4 compatibility
        let singleScene = SceneDraft(id: UUID(), durationUs: durationUs)
        configure(scenes: [singleScene], templateFPS: templateFPS, minSceneDurationUs: ProjectDraft.minSceneDurationUs)
    }

    /// Configures timeline with scenes array (PR2: Multi-scene support).
    /// PR4: Uses applySnapshot for data, setLayoutContext for layout.
    /// - Parameters:
    ///   - scenes: Array of SceneDraft objects
    ///   - templateFPS: Template frame rate for quantization
    ///   - minSceneDurationUs: Minimum scene duration for trim (PR2 fix: consistent with model)
    func configure(scenes: [SceneDraft], templateFPS: Int, minSceneDurationUs: TimeUs = ProjectDraft.minSceneDurationUs) {
        self.scenes = scenes
        self.durationUs = scenes.reduce(0) { $0 + $1.durationUs }
        self.templateFPS = templateFPS > 0 ? templateFPS : 30
        self.minSceneDurationUs = minSceneDurationUs

        // PR4: Data path - applySnapshot
        let snapshot = SceneTrackSnapshot(
            scenes: scenes,
            selectedSceneId: selectedSceneId,
            minDurationUs: minSceneDurationUs
        )
        sceneTrack.applySnapshot(snapshot)

        // PR4: Layout path - setLayoutContext (done via updateContentSize)
        let padding = leftPaddingPx
        audioTrack.configure(durationUs: durationUs, pxPerSecond: pxPerSecond, leftPadding: padding)

        #if DEBUG
        for track in debugAudioTracks {
            track.configure(durationUs: durationUs, pxPerSecond: pxPerSecond, leftPadding: padding)
        }
        #endif

        updateContentSize()
    }

    /// Updates scenes (for trim operations).
    /// PR4: Uses applySnapshot for data (with diff), layout via updateContentSize.
    func updateScenes(_ scenes: [SceneDraft]) {
        self.scenes = scenes
        self.durationUs = scenes.reduce(0) { $0 + $1.durationUs }

        // PR4: Data path - applySnapshot (handles diff internally)
        let snapshot = SceneTrackSnapshot(
            scenes: scenes,
            selectedSceneId: selectedSceneId,
            minDurationUs: minSceneDurationUs
        )
        sceneTrack.applySnapshot(snapshot)

        // Audio: configure is ok (single block, no active gesture)
        let padding = leftPaddingPx
        audioTrack.configure(durationUs: durationUs, pxPerSecond: pxPerSecond, leftPadding: padding)

        #if DEBUG
        for track in debugAudioTracks {
            track.configure(durationUs: durationUs, pxPerSecond: pxPerSecond, leftPadding: padding)
        }
        #endif

        // PR4: Layout path via updateContentSize
        updateContentSize()
    }

    /// Updates current time position (from playback).
    /// Skips if user is currently dragging to avoid fighting.
    /// P1-1: Clamps time to valid range before storing.
    /// - Parameter timeUs: Time in microseconds
    func setCurrentTimeUs(_ timeUs: TimeUs) {
        // Don't interrupt user's drag/decelerate
        guard !scrollView.isDragging && !scrollView.isDecelerating else { return }

        // Clamp to valid range [0, durationUs]
        let clamped = clampTimeUs(timeUs, maxUs: durationUs)
        currentTimeUs = clamped
        centerOnTimeUs(clamped)
    }

    // MARK: - State Snapshot/Restore

    /// Returns current time and zoom for snapshot.
    func snapshotState() -> (timeUs: TimeUs, zoom: CGFloat) {
        (timeUnderPlayheadUs(), currentZoom)
    }

    /// Restores time and zoom from snapshot.
    /// Must be called after configure() to set position.
    /// - Parameters:
    ///   - timeUs: Time in microseconds
    ///   - zoom: Zoom level
    func restoreState(timeUs: TimeUs, zoom: CGFloat) {
        // Mark that state was restored (prevents initial positioning override)
        stateWasRestored = true
        didInitialPositioning = true

        // Restore zoom
        currentZoom = zoom

        // Update content size with new zoom
        updateContentSize()

        // Clamp time to valid range and center
        // PR2 fix: centerOnTimeUs sets contentOffset → triggers scrollViewDidScroll → emits .scroll
        let clampedTimeUs = clampTimeUs(timeUs, maxUs: durationUs)
        centerOnTimeUs(clampedTimeUs)

        // Sync internal state
        currentTimeUs = clampedTimeUs
    }

    // MARK: - Reorder Mode (PR3)

    /// Sets reorder mode and propagates to track views.
    /// - Parameter isReorderMode: Whether reorder mode is active
    func setReorderMode(_ isReorderMode: Bool) {
        self.isReorderMode = isReorderMode
        sceneTrack.setReorderMode(isReorderMode)
    }

    // MARK: - Selection (PR2: Multi-scene)

    /// Programmatically sets selection and updates track highlighting.
    /// Call this when restoring state or changing selection from outside TimelineView.
    /// - Parameter selection: The selection to apply
    func setSelection(_ selection: TimelineSelection) {
        switch selection {
        case .scene(let id):
            selectedSceneId = id
            sceneTrack.setSelectedScene(id)
            audioTrack.setSelected(false)
        case .audio:
            selectedSceneId = nil
            sceneTrack.setSelectedScene(nil)
            audioTrack.setSelected(true)
        case .none:
            selectedSceneId = nil
            sceneTrack.setSelectedScene(nil)
            audioTrack.setSelected(false)
        }
    }

    // MARK: - Private Helpers

    private func updateContentSize() {
        let width = totalContentWidth

        // Update content width
        contentWidthConstraint?.constant = width

        // PR4: Layout path only - update tracks with new layout context
        let padding = leftPaddingPx
        let layoutContext = TimelineLayoutContext(pxPerSecond: pxPerSecond, leftPadding: padding)
        sceneTrack.setLayoutContext(layoutContext)
        audioTrack.setPxPerSecond(pxPerSecond, leftPadding: padding)

        #if DEBUG
        for track in debugAudioTracks {
            track.setPxPerSecond(pxPerSecond, leftPadding: padding)
        }
        #endif
    }

    /// Centers the given time under the playhead.
    /// PR2 fix: setting contentOffset triggers scrollViewDidScroll which emits .scroll
    /// - Parameter timeUs: Time in microseconds
    private func centerOnTimeUs(_ timeUs: TimeUs) {
        guard durationUs > 0 else { return }

        // offsetX = timeSeconds * pxPerSecond
        let timeSeconds = usToSeconds(timeUs)
        let offsetX = CGFloat(timeSeconds) * pxPerSecond
        let clampedX = clampOffsetX(offsetX)

        // PR2 v7: Preserve Y position when centering X
        let currentY = scrollView.contentOffset.y
        scrollView.contentOffset = CGPoint(x: clampedX, y: currentY)
    }

    /// Returns the time currently under the playhead in microseconds.
    private func timeUnderPlayheadUs() -> TimeUs {
        guard pxPerSecond > 0 else { return 0 }

        // time = offsetX / pxPerSecond (simple, no inset math)
        let timeSeconds = Double(scrollView.contentOffset.x / pxPerSecond)
        let timeUs = secondsToUs(timeSeconds)
        return clampTimeUs(timeUs, maxUs: durationUs)
    }

    /// Clamps offset to valid range [0, maxOffsetX].
    private func clampOffsetX(_ x: CGFloat) -> CGFloat {
        max(0, min(x, maxOffsetX))
    }

    // MARK: - Event Emission (PR1)

    /// Emits a timeline event through the unified callback.
    /// Includes debug logging for PR1-PR3 development.
    private func emitEvent(_ event: TimelineEvent) {
        #if DEBUG
        switch event {
        case .scrub(let timeUs, let quantize, let phase):
            print("[Timeline] scrub: \(timeUs)us, \(quantize), \(phase)")
        case .scroll(let offsetX, let pxPerSecond):
            print("[Timeline] scroll: x=\(Int(offsetX)), pps=\(Int(pxPerSecond))")
        case .selection(let sel):
            print("[Timeline] selection: \(sel)")
        case .trimScene(let sceneId, let newDurationUs, let edge, let phase):
            print("[Timeline] trimScene: \(sceneId), \(newDurationUs)us, \(edge), \(phase)")
        case .reorderScene(let sceneId, let toIndex, let phase):
            print("[Timeline] reorderScene: \(sceneId), toIndex=\(toIndex), \(phase)")
        }
        #endif
        onEvent?(event)
    }

    /// Emits scroll event for ruler sync.
    private func emitScrollEvent() {
        emitEvent(.scroll(offsetX: scrollView.contentOffset.x, pxPerSecond: pxPerSecond))
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }

        // Clamp offset to valid range
        let rawX = scrollView.contentOffset.x
        let clampedX = clampOffsetX(rawX)
        if rawX != clampedX {
            // Setting contentOffset triggers another scrollViewDidScroll call,
            // so return here to emit event only on the normalized second call
            // PR2 v7: Preserve Y position when clamping X
            let currentY = scrollView.contentOffset.y
            scrollView.contentOffset = CGPoint(x: clampedX, y: currentY)
            return
        }

        // Emit scroll event for ruler sync
        emitScrollEvent()

        // Emit scrub .changed during drag (with deduplication)
        if scrollView.isDragging {
            let timeUs = timeUnderPlayheadUs()
            if timeUs != lastEmittedScrubTimeUs {
                lastEmittedScrubTimeUs = timeUs
                emitEvent(.scrub(timeUs: timeUs, quantize: .dragging, phase: .changed))
            }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }

        // Start new scrub session
        isScrubSessionActive = true
        lastEmittedScrubTimeUs = nil

        // Emit .began event
        let timeUs = timeUnderPlayheadUs()
        emitEvent(.scrub(timeUs: timeUs, quantize: .dragging, phase: .began))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === self.scrollView else { return }
        if !decelerate {
            emitFinalScrub()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        emitFinalScrub()
    }

    /// Emits final scrub event with .ended phase for snap-to-nearest frame.
    /// Called at end of drag or pinch gestures.
    private func emitFinalScrub() {
        let timeUs = timeUnderPlayheadUs()
        emitEvent(.scrub(timeUs: timeUs, quantize: .ended, phase: .ended))

        // Reset scrub session (if was active)
        isScrubSessionActive = false
    }

    // MARK: - Gesture Handlers

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            let newZoom = currentZoom * recognizer.scale
            let clampedZoom = max(1.0, min(newZoom, EditorConfig.zoomMax))

            if clampedZoom != currentZoom {
                // PR2.6: Zoom anchored under playhead
                // 1. Save time under playhead BEFORE zoom
                let anchorTime = scrollView.contentOffset.x / pxPerSecond

                // 2. Update zoom
                currentZoom = clampedZoom

                // 3. Update content size with new pxPerSecond
                updateContentSize()

                // 4. Calculate new offset to keep anchorTime under playhead
                let newPxPerSecond = pxPerSecond
                let newOffsetX = anchorTime * newPxPerSecond
                let clampedOffsetX = clampOffsetX(newOffsetX)

                // 5. Apply new offset (triggers scrollViewDidScroll which emits scroll event)
                // PR2 v7: Preserve Y position when applying pinch zoom
                let currentY = scrollView.contentOffset.y
                scrollView.contentOffset = CGPoint(x: clampedOffsetX, y: currentY)
            }

            recognizer.scale = 1.0

        case .ended, .cancelled:
            // Emit final scrub position
            emitFinalScrub()

        default:
            break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: contentView)

        // Scene track taps are handled by SceneClipView (via onSelectScene callback)
        // Only check for audio track and empty space here

        // Check if tap is on audio track
        let audioFrame = audioTrack.convert(audioTrack.bounds, to: contentView)
        if audioFrame.contains(location) {
            selectedSceneId = nil
            sceneTrack.setSelectedScene(nil)
            audioTrack.setSelected(true)
            emitEvent(.selection(.audio))
            return
        }

        // Check if tap is on scene track area (let clips handle their own taps)
        let sceneFrame = sceneTrack.convert(sceneTrack.bounds, to: contentView)
        if sceneFrame.contains(location) {
            // Don't clear selection - let SceneClipView handle it
            return
        }

        // Tap on empty space - clear selection
        selectedSceneId = nil
        sceneTrack.setSelectedScene(nil)
        audioTrack.setSelected(false)
        emitEvent(.selection(.none))
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow pinch alongside scroll
        if gestureRecognizer == pinchGesture {
            return true
        }
        return false
    }
}
