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

    private(set) var currentZoom: CGFloat = 1.0

    /// Currently selected scene ID (for trim handles).
    private var selectedSceneId: UUID?

    /// PR3: Reorder mode state
    private var isReorderMode: Bool = false

    /// PR4: Min scene duration for trim clamp (model constraint)
    private var minSceneDurationUs: TimeUs = ProjectDraft.minSceneDurationUs

    /// PR8: Current music item ID (for selection events)
    private var musicItemId: UUID?

    // MARK: - Initial Positioning State

    private var didInitialPositioning = false
    private var stateWasRestored = false

    // MARK: - Scrub Session State (PR1)

    /// Tracks whether a drag-based scrub session is active.
    private var isScrubSessionActive = false

    /// Last emitted compressed frame to avoid redundant .changed events during drag.
    private var lastEmittedCompressedFrame: Int?

    // MARK: - Authoritative Frame State (TT-01 Phase 2)

    /// Authoritative compressed frame for session-correct scrubbing.
    /// Updated by setCurrentCompressedFrame, restoreState, and emitFinalScrub.
    private var currentCompressedFrame: Int = 0

    /// Last known scroll offset for directional clamp during scrub.
    private var lastScrubOffsetX: CGFloat?

    // MARK: - Playhead Mapper (Phase 2.1)

    /// Current playhead mapper for offset ↔ compressed frame conversion.
    /// Updated when timeline data changes via configure().
    private var mapper: TimelinePlayheadMapper?

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
    private lazy var textOverlayLane = OverlayLaneView(laneKind: .text)
    private lazy var stickerOverlayLane = OverlayLaneView(laneKind: .sticker)
    private lazy var audioTrack = AudioTrackView()

    private var textLaneHeightConstraint: NSLayoutConstraint?
    private var stickerLaneHeightConstraint: NSLayoutConstraint?


    private var contentWidthConstraint: NSLayoutConstraint?

    // MARK: - Gestures

    private lazy var pinchGesture: UIPinchGestureRecognizer = {
        let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        gesture.delegate = self
        return gesture
    }()

    private lazy var tapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        gesture.delegate = self
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

        // Add tracks (scene → text lane → sticker lane → audio)
        tracksStack.addArrangedSubview(sceneTrack)
        tracksStack.addArrangedSubview(textOverlayLane)
        tracksStack.addArrangedSubview(stickerOverlayLane)
        tracksStack.addArrangedSubview(audioTrack)

        // Wire sceneTrack callbacks for selection and trim
        wireSceneTrackCallbacks()
        wireOverlayLaneCallbacks()
    }

    private func wireSceneTrackCallbacks() {
        sceneTrack.onSelectScene = { [weak self] sceneId in
            guard let self = self else { return }
            // Emit focusScene — playhead moves to scene start, selection follows via store
            self.emitEvent(.focusScene(sceneId: sceneId))
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

        // PR-G: Boundary tap callback
        sceneTrack.onTapBoundary = { [weak self] fromId, toId, rectInTrack in
            guard let self = self else { return }
            // Convert rect from track coordinates to TimelineView coordinates
            let rectInTimeline = self.sceneTrack.convert(rectInTrack, to: self)
            self.emitEvent(.editBoundaryTransition(fromSceneId: fromId, toSceneId: toId, anchorRect: rectInTimeline))
        }
    }

    private func wireOverlayLaneCallbacks() {
        // Text lane
        textOverlayLane.onSelectItem = { [weak self] itemId in
            self?.emitEvent(.selection(.text(itemId: itemId)))
        }
        textOverlayLane.onMoveItem = { [weak self] itemId, newStartUs, phase in
            self?.emitEvent(.moveOverlayItem(itemId: itemId, newStartUs: newStartUs, phase: phase))
        }
        textOverlayLane.onTrimItem = { [weak self] itemId, newDurationUs, edge, phase in
            self?.emitEvent(.trimOverlayItem(itemId: itemId, newDurationUs: newDurationUs, edge: edge, phase: phase))
        }

        // Sticker lane
        stickerOverlayLane.onSelectItem = { [weak self] itemId in
            self?.emitEvent(.selection(.sticker(itemId: itemId)))
        }
        stickerOverlayLane.onMoveItem = { [weak self] itemId, newStartUs, phase in
            self?.emitEvent(.moveOverlayItem(itemId: itemId, newStartUs: newStartUs, phase: phase))
        }
        stickerOverlayLane.onTrimItem = { [weak self] itemId, newDurationUs, edge, phase in
            self?.emitEvent(.trimOverlayItem(itemId: itemId, newDurationUs: newDurationUs, edge: edge, phase: phase))
        }
    }

    private func setupConstraints() {
        sceneTrack.translatesAutoresizingMaskIntoConstraints = false
        textOverlayLane.translatesAutoresizingMaskIntoConstraints = false
        stickerOverlayLane.translatesAutoresizingMaskIntoConstraints = false
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

        // Dynamic height constraints for overlay lanes
        textLaneHeightConstraint = textOverlayLane.heightAnchor.constraint(equalToConstant: 32)
        textLaneHeightConstraint?.isActive = true
        stickerLaneHeightConstraint = stickerOverlayLane.heightAnchor.constraint(equalToConstant: 32)
        stickerLaneHeightConstraint?.isActive = true


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

    /// Sets the playhead mapper for offset ↔ compressed frame conversion.
    /// Called by EditorLayoutContainerView when timeline structure changes.
    func setMapper(_ mapper: TimelinePlayheadMapper) {
        self.mapper = mapper
    }

    /// Configures timeline with scenes array (PR2: Multi-scene support).
    /// PR4: Uses applySnapshot for data, setLayoutContext for layout.
    /// PR-G: Includes boundaries for transition controls.
    /// - Parameters:
    ///   - scenes: Array of SceneDraft objects
    ///   - boundaries: Adjacent scene boundaries with transitions
    ///   - templateFPS: Template frame rate for quantization
    ///   - minSceneDurationUs: Minimum scene duration for trim (PR2 fix: consistent with model)
    func configure(scenes: [SceneDraft], boundaries: [SceneBoundaryDraft], templateFPS: Int, minSceneDurationUs: TimeUs = ProjectDraft.minSceneDurationUs) {
        self.scenes = scenes
        self.durationUs = scenes.reduce(0) { $0 + $1.durationUs }
        self.templateFPS = templateFPS > 0 ? templateFPS : 30
        self.minSceneDurationUs = minSceneDurationUs

        // PR4: Data path - applySnapshot (PR-G: includes boundaries)
        let snapshot = SceneTrackSnapshot(
            scenes: scenes,
            boundaries: boundaries,
            selectedSceneId: selectedSceneId,
            minDurationUs: minSceneDurationUs
        )
        sceneTrack.applySnapshot(snapshot)

        // PR4: Layout path - setLayoutContext (done via updateContentSize)
        let padding = leftPaddingPx
        textOverlayLane.configure(pxPerSecond: pxPerSecond, leftPadding: padding)
        stickerOverlayLane.configure(pxPerSecond: pxPerSecond, leftPadding: padding)
        audioTrack.configure(durationUs: durationUs, pxPerSecond: pxPerSecond, leftPadding: padding)

        updateContentSize()
    }

    /// Updates scenes (for trim operations).
    /// PR4: Uses applySnapshot for data (with diff), layout via updateContentSize.
    /// PR-G: Includes boundaries for transition controls.
    func updateScenes(_ scenes: [SceneDraft], boundaries: [SceneBoundaryDraft]) {
        self.scenes = scenes
        self.durationUs = scenes.reduce(0) { $0 + $1.durationUs }

        // PR4: Data path - applySnapshot (handles diff internally, PR-G: includes boundaries)
        let snapshot = SceneTrackSnapshot(
            scenes: scenes,
            boundaries: boundaries,
            selectedSceneId: selectedSceneId,
            minDurationUs: minSceneDurationUs
        )
        sceneTrack.applySnapshot(snapshot)

        // Audio: configure is ok (single block, no active gesture)
        let padding = leftPaddingPx
        textOverlayLane.configure(pxPerSecond: pxPerSecond, leftPadding: padding)
        stickerOverlayLane.configure(pxPerSecond: pxPerSecond, leftPadding: padding)
        audioTrack.configure(durationUs: durationUs, pxPerSecond: pxPerSecond, leftPadding: padding)

        // PR4: Layout path via updateContentSize
        updateContentSize()
    }

    /// Updates current position from compressed frame (from playback).
    /// Skips scroll update if user is currently dragging to avoid fighting.
    /// TT-01 Phase 2: Always updates authoritative frame for session-correct scrubbing.
    /// - Parameters:
    ///   - compressedFrame: Compressed frame index
    ///   - mapper: Playhead mapper for coordinate conversion
    func setCurrentCompressedFrame(_ compressedFrame: Int, mapper: TimelinePlayheadMapper) {
        // TT-01 Phase 2: Always update authoritative frame (even during drag)
        // This syncs store echo to local state without interrupting scroll
        currentCompressedFrame = compressedFrame

        // Don't interrupt user's drag/decelerate
        guard !scrollView.isDragging && !scrollView.isDecelerating else { return }

        // TT-01: Direct frame-based positioning without TimeUs roundtrip
        let offsetX = mapper.offsetX(forCompressedFrame: compressedFrame, pxPerSecond: pxPerSecond)
        centerOnOffsetX(offsetX)
    }

    // MARK: - State Snapshot/Restore (Phase 2.1: Compressed Frame Domain)

    /// Returns current compressed frame for snapshot.
    /// Phase 2.1: Returns compressed frame directly, not timeUs.
    func snapshotCompressedFrame() -> Int {
        compressedFrameUnderPlayhead(quantize: .ended)
    }

    /// Restores state from compressed frame and zoom.
    /// Must be called after configure() to set position.
    /// TT-01 Phase 2: Uses direct frame-based positioning and updates authoritative frame.
    /// Spec section 5: Must apply zoom before centering.
    /// - Parameters:
    ///   - compressedFrame: Compressed frame index
    ///   - zoom: Zoom level
    ///   - mapper: Playhead mapper for coordinate conversion
    func restoreState(compressedFrame: Int, zoom: CGFloat, mapper: TimelinePlayheadMapper) {
        // TT-01 Phase 2: Update authoritative frame
        currentCompressedFrame = compressedFrame

        // Step 1: Mark that state was restored (prevents initial positioning override)
        stateWasRestored = true
        didInitialPositioning = true

        // Step 2: Restore zoom
        currentZoom = zoom

        // Step 3: Update content size with new zoom (MUST be before centering)
        updateContentSize()

        // Step 4: TT-01: Direct frame-based positioning without TimeUs roundtrip
        let offsetX = mapper.offsetX(forCompressedFrame: compressedFrame, pxPerSecond: pxPerSecond)
        centerOnOffsetX(offsetX)
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
            textOverlayLane.setSelectedItem(nil)
            stickerOverlayLane.setSelectedItem(nil)
        case .audio:
            selectedSceneId = nil
            sceneTrack.setSelectedScene(nil)
            audioTrack.setSelected(true)
            textOverlayLane.setSelectedItem(nil)
            stickerOverlayLane.setSelectedItem(nil)
        case .text(let itemId):
            selectedSceneId = nil
            sceneTrack.setSelectedScene(nil)
            audioTrack.setSelected(false)
            textOverlayLane.setSelectedItem(itemId)
            stickerOverlayLane.setSelectedItem(nil)
        case .sticker(let itemId):
            selectedSceneId = nil
            sceneTrack.setSelectedScene(nil)
            audioTrack.setSelected(false)
            textOverlayLane.setSelectedItem(nil)
            stickerOverlayLane.setSelectedItem(itemId)
        case .none:
            selectedSceneId = nil
            sceneTrack.setSelectedScene(nil)
            audioTrack.setSelected(false)
            textOverlayLane.setSelectedItem(nil)
            stickerOverlayLane.setSelectedItem(nil)
        }
    }

    /// Updates text overlay items for the text lane.
    func setTextOverlayItems(_ items: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)], selectedItemId: UUID?) {
        let (rowItems, rowCount) = OverlayLaneSnapshot.packRows(items)
        let snapshot = OverlayLaneSnapshot(items: rowItems, selectedItemId: selectedItemId, rowCount: rowCount)
        textOverlayLane.applySnapshot(snapshot)
        textOverlayLane.configure(pxPerSecond: pxPerSecond, leftPadding: leftPaddingPx)
        textOverlayLane.isHidden = items.isEmpty
        textLaneHeightConstraint?.constant = CGFloat(max(1, rowCount) * 28 + 4)
    }

    /// Updates sticker overlay items for the sticker lane.
    func setStickerOverlayItems(_ items: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)], selectedItemId: UUID?) {
        let (rowItems, rowCount) = OverlayLaneSnapshot.packRows(items)
        let snapshot = OverlayLaneSnapshot(items: rowItems, selectedItemId: selectedItemId, rowCount: rowCount)
        stickerOverlayLane.applySnapshot(snapshot)
        stickerOverlayLane.configure(pxPerSecond: pxPerSecond, leftPadding: leftPaddingPx)
        stickerOverlayLane.isHidden = items.isEmpty
        stickerLaneHeightConstraint?.constant = CGFloat(max(1, rowCount) * 28 + 4)
    }

    /// PR8: Updates the music item data for audio track display and selection.
    func setMusicItem(_ item: TimelineItem?, payload: AudioPayload?) {
        musicItemId = item?.id
        if let item, let payload {
            audioTrack.configure(
                durationUs: item.durationUs,
                pxPerSecond: pxPerSecond,
                leftPadding: leftPaddingPx,
                clipOffsetPx: CGFloat(usToSeconds(item.startUs ?? 0)) * pxPerSecond
            )
            audioTrack.setHasClip(true)
        } else {
            audioTrack.setHasClip(false)
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
        textOverlayLane.configure(pxPerSecond: pxPerSecond, leftPadding: padding)
        stickerOverlayLane.configure(pxPerSecond: pxPerSecond, leftPadding: padding)
        audioTrack.setPxPerSecond(pxPerSecond, leftPadding: padding)

    }

    /// Centers the timeline on a specific X offset.
    /// TT-01: This is the acceptance path for playhead positioning.
    /// - Parameter offsetX: X offset in pixels
    private func centerOnOffsetX(_ offsetX: CGFloat) {
        let clampedX = clampOffsetX(offsetX)
        let currentY = scrollView.contentOffset.y
        scrollView.contentOffset = CGPoint(x: clampedX, y: currentY)
    }

    /// Centers the given time under the playhead.
    /// TT-01: Thin wrapper for non-acceptance paths.
    /// - Parameter timeUs: Time in microseconds
    private func centerOnTimeUs(_ timeUs: TimeUs) {
        guard durationUs > 0 else { return }
        let timeSeconds = usToSeconds(timeUs)
        let offsetX = CGFloat(timeSeconds) * pxPerSecond
        centerOnOffsetX(offsetX)
    }

    /// Returns the time currently under the playhead in microseconds.
    private func timeUnderPlayheadUs() -> TimeUs {
        guard pxPerSecond > 0 else { return 0 }

        // time = offsetX / pxPerSecond (simple, no inset math)
        let timeSeconds = Double(scrollView.contentOffset.x / pxPerSecond)
        let timeUs = secondsToUs(timeSeconds)
        return clampTimeUs(timeUs, maxUs: durationUs)
    }

    /// Returns the compressed frame currently under the playhead.
    /// Uses mapper for offset → compressed frame conversion.
    /// Phase 2.1: Fail-loud if mapper not wired (spec section 12).
    private func compressedFrameUnderPlayhead(quantize: QuantizeMode) -> Int {
        guard pxPerSecond > 0 else { return 0 }

        if let mapper = mapper {
            // Use mapper for accurate zone-based conversion
            return mapper.compressedFrame(
                forOffsetX: scrollView.contentOffset.x,
                pxPerSecond: pxPerSecond,
                quantize: quantize
            )
        } else {
            // Phase 2.1: Fail-loud - mapper must be wired in production
            assertionFailure("[TimelineView] Mapper not wired - this is a configuration error")
            // Defensive fallback (not acceptance path)
            let timeUs = timeUnderPlayheadUs()
            return quantizeFrame(timeUs: timeUs, fps: templateFPS, mode: quantize)
        }
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
        case .scrub(let compressedFrame, let phase):
            print("[Timeline] scrub: frame=\(compressedFrame), \(phase)")
        case .scroll(let offsetX, let pxPerSecond):
            print("[Timeline] scroll: x=\(Int(offsetX)), pps=\(Int(pxPerSecond))")
        case .selection(let sel):
            print("[Timeline] selection: \(sel)")
        case .trimScene(let sceneId, let newDurationUs, let edge, let phase):
            print("[Timeline] trimScene: \(sceneId), \(newDurationUs)us, \(edge), \(phase)")
        case .reorderScene(let sceneId, let toIndex, let phase):
            print("[Timeline] reorderScene: \(sceneId), toIndex=\(toIndex), \(phase)")
        case .editBoundaryTransition(let fromId, let toId, _):
            print("[Timeline] editBoundaryTransition: \(fromId) → \(toId)")
        case .focusScene(let sceneId):
            print("[Timeline] focusScene: \(sceneId)")
        case .moveOverlayItem(let itemId, let newStartUs, let phase):
            print("[Timeline] moveOverlayItem: \(itemId), \(newStartUs)us, \(phase)")
        case .trimOverlayItem(let itemId, let newDurationUs, let edge, let phase):
            print("[Timeline] trimOverlayItem: \(itemId), \(newDurationUs)us, \(edge), \(phase)")
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

        #if DEBUG
        let signpostId = ScrubSignpost.beginScrollViewDidScroll()
        ScrubCallCounter.shared.recordScrollViewDidScroll()
        defer { ScrubSignpost.endScrollViewDidScroll(signpostId) }
        #endif

        // Clamp offset to valid range
        let rawX = scrollView.contentOffset.x
        let clampedX = clampOffsetX(rawX)
        if rawX != clampedX {
            #if DEBUG
            ScrubSignpost.emitClampHit()
            ScrubCallCounter.shared.recordClampHit()
            #endif
            // Setting contentOffset triggers another scrollViewDidScroll call,
            // so return here to emit event only on the normalized second call
            // PR2 v7: Preserve Y position when clamping X
            let currentY = scrollView.contentOffset.y
            scrollView.contentOffset = CGPoint(x: clampedX, y: currentY)
            return
        }

        // Emit scroll event for ruler sync
        emitScrollEvent()

        // Emit scrub .changed during drag (with deduplication + directional clamp)
        if scrollView.isDragging {
            let currentOffsetX = scrollView.contentOffset.x
            let candidate = compressedFrameUnderPlayhead(quantize: .dragging)

            // TT-01 Phase 2: Directional clamp - prevent backward rollback
            let resolved = resolveScrubFrame(
                candidate: candidate,
                currentOffsetX: currentOffsetX
            )

            // Update authoritative state
            currentCompressedFrame = resolved

            if resolved != lastEmittedCompressedFrame {
                lastEmittedCompressedFrame = resolved
                #if DEBUG
                let timeUs = timeUnderPlayheadUs()
                ScrubSignpost.emitScrubChanged(timeUs: timeUs)
                ScrubCallCounter.shared.recordScrubChanged()
                #endif
                emitEvent(.scrub(compressedFrame: resolved, phase: .changed))
            }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }

        // Start new scrub session
        isScrubSessionActive = true

        // TT-01 Phase 2: Use authoritative frame, not offset recalculation
        // This prevents rollback in scaled zone where round() vs floor() asymmetry exists
        lastScrubOffsetX = scrollView.contentOffset.x
        lastEmittedCompressedFrame = currentCompressedFrame

        // Emit .began event with authoritative frame (no rollback)
        emitEvent(.scrub(compressedFrame: currentCompressedFrame, phase: .began))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === self.scrollView else { return }
        #if DEBUG
        ScrubCallCounter.shared.forceReport()
        #endif
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
        // Final snap uses .ended quantization (round)
        let compressedFrame = compressedFrameUnderPlayhead(quantize: .ended)

        // TT-01 Phase 2: Update authoritative frame and clear scrub state
        currentCompressedFrame = compressedFrame
        lastScrubOffsetX = nil

        emitEvent(.scrub(compressedFrame: compressedFrame, phase: .ended))

        // Reset scrub session (if was active)
        isScrubSessionActive = false
    }

    // MARK: - Scrub Frame Resolution (TT-01 Phase 2)

    /// Sub-pixel tolerance for directional clamp.
    /// At default zoom (20 px/s, 30 fps), one frame ≈ 0.67 px.
    /// Using 0.5 px allows small deltas to accumulate before triggering frame change.
    private static let scrubEpsilon: CGFloat = 0.5

    /// Resolves scrub frame with directional clamp to prevent rollback in scaled zones.
    /// Instance method that updates lastScrubOffsetX state.
    /// - Parameters:
    ///   - candidate: Frame calculated from current offset via mapper
    ///   - currentOffsetX: Current scroll offset
    /// - Returns: Resolved frame respecting directional constraints
    func resolveScrubFrame(candidate: Int, currentOffsetX: CGFloat) -> Int {
        guard let lastOffset = lastScrubOffsetX else {
            // First callback in session - use candidate directly
            lastScrubOffsetX = currentOffsetX
            return candidate
        }

        let result = Self.resolveScrubFramePure(
            candidate: candidate,
            currentFrame: currentCompressedFrame,
            deltaX: currentOffsetX - lastOffset,
            epsilon: Self.scrubEpsilon
        )

        // Only update lastScrubOffsetX when movement is meaningful
        if result.shouldUpdateOffset {
            lastScrubOffsetX = currentOffsetX
        }

        return result.frame
    }

    /// Pure static function for directional clamp logic. Testable without instance state.
    /// - Parameters:
    ///   - candidate: Frame calculated from current offset via mapper
    ///   - currentFrame: Current authoritative frame
    ///   - deltaX: Change in offset since last meaningful movement
    ///   - epsilon: Sub-pixel tolerance threshold
    /// - Returns: Tuple of (resolved frame, whether offset should be updated)
    static func resolveScrubFramePure(
        candidate: Int,
        currentFrame: Int,
        deltaX: CGFloat,
        epsilon: CGFloat
    ) -> (frame: Int, shouldUpdateOffset: Bool) {
        if deltaX > epsilon {
            // Moving right: never go backward
            return (max(candidate, currentFrame), true)
        } else if deltaX < -epsilon {
            // Moving left: never go forward
            return (min(candidate, currentFrame), true)
        } else {
            // Minimal movement: keep current frame, don't update offset
            return (currentFrame, false)
        }
    }

    // MARK: - Test Helpers (TT-01 Phase 2)

    #if DEBUG
    /// Simulates begin dragging for testing.
    /// - Note: For unit tests only.
    func simulateBeginDragging() {
        scrollViewWillBeginDragging(scrollView)
    }

    /// Simulates scroll by delta for testing.
    /// - Parameter deltaX: Horizontal scroll delta in points
    func simulateScrollDelta(_ deltaX: CGFloat) {
        scrollView.contentOffset.x += deltaX
        scrollViewDidScroll(scrollView)
    }

    /// Simulates end dragging for testing.
    func simulateEndDragging() {
        scrollViewDidEndDragging(scrollView, willDecelerate: false)
    }

    /// Returns current scroll offset for testing.
    var testCurrentOffsetX: CGFloat {
        scrollView.contentOffset.x
    }

    /// Sets absolute scroll offset for testing.
    /// Use this to position scroll at exact offset (e.g., between frames).
    func setTestScrollOffset(_ offset: CGFloat) {
        scrollView.contentOffset.x = offset
    }
    #endif

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
        // Only check for overlay, audio track and empty space here

        // Check if tap is on overlay lanes (handled by OverlayLaneView's onSelectItem)
        if !textOverlayLane.isHidden {
            let textFrame = textOverlayLane.convert(textOverlayLane.bounds, to: contentView)
            if textFrame.contains(location) { return }
        }
        if !stickerOverlayLane.isHidden {
            let stickerFrame = stickerOverlayLane.convert(stickerOverlayLane.bounds, to: contentView)
            if stickerFrame.contains(location) { return }
        }

        // Check if tap is on audio track
        let audioFrame = audioTrack.convert(audioTrack.bounds, to: contentView)
        if audioFrame.contains(location), let itemId = musicItemId {
            emitEvent(.selection(.audio(itemId: itemId)))
            return
        }

        // Check if tap is on scene track area (let clips handle their own taps)
        let sceneFrame = sceneTrack.convert(sceneTrack.bounds, to: contentView)
        if sceneFrame.contains(location) {
            // Don't clear selection - let SceneClipView handle it
            return
        }

        // Tap on empty space - clear selection
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

    /// PR-G: Prevent tapGesture from blocking UIControl touches (TransitionBoundaryView).
    /// When tapGesture recognizes, it cancels touches to the hit view by default.
    /// This allows UIControls to receive their full touch sequence.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer == tapGesture {
            // Don't let tapGesture interfere with UIControl touches
            if touch.view is UIControl {
                return false
            }
        }
        return true
    }
}
