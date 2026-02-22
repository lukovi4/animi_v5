import UIKit

// MARK: - Timeline View (PR2.6 Core Rewrite)

/// Horizontal scrolling timeline with pinch zoom support.
/// Contains track views (SceneTrackView, AudioTrackView).
/// Supports scrubbing and selection.
///
/// PR2.6 Architecture:
/// - Single xScrollView as the only source of truth for X position
/// - No transform, no contentInset for time-axis math
/// - Real padding via contentWidth = leftPad + duration*pps + rightPad
/// - Zoom anchored under playhead (center of screen)
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

    /// Template FPS for frame quantization (used only for derived calculations).
    private var templateFPS: Int = 30

    private var currentZoom: CGFloat = 1.0

    /// Current time under playhead in microseconds.
    private var currentTimeUs: TimeUs = 0

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
        xScrollView.contentOffset.x
    }

    // MARK: - Subviews (PR2.6 Architecture)

    /// Horizontal scroll for time (X) - single source of truth
    /// Note: tracksVerticalScrollView removed for MVP (Y scroll not needed with 2 tracks)
    private lazy var xScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.delegate = self
        sv.decelerationRate = .fast
        sv.alwaysBounceHorizontal = false
        // Lock to horizontal only
        sv.alwaysBounceVertical = false
        sv.isDirectionalLockEnabled = true
        return sv
    }()

    /// Content inside xScrollView (width = leftPad + duration*pps + rightPad)
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

        // PR2.6 Hierarchy (MVP): xScrollView → contentView → tracksStack
        // Note: tracksVerticalScrollView can be added later when Y scroll is needed
        addSubview(xScrollView)
        xScrollView.addSubview(contentView)
        contentView.addSubview(tracksStack)

        // Add tracks
        tracksStack.addArrangedSubview(sceneTrack)
        tracksStack.addArrangedSubview(audioTrack)

        // Note: DEBUG stub tracks removed in PR2.6 MVP (no Y-scroll)
        // Will be re-added when tracksVerticalScrollView is implemented
    }

    private func setupConstraints() {
        sceneTrack.translatesAutoresizingMaskIntoConstraints = false
        audioTrack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // xScrollView fills TimelineView
            xScrollView.topAnchor.constraint(equalTo: topAnchor),
            xScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            xScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            xScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // contentView inside xScrollView (contentLayoutGuide)
            contentView.topAnchor.constraint(equalTo: xScrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: xScrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: xScrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: xScrollView.contentLayoutGuide.bottomAnchor),
            // Height matches frame for no vertical scroll in xScrollView
            contentView.heightAnchor.constraint(equalTo: xScrollView.frameLayoutGuide.heightAnchor),

            // tracksStack inside contentView
            tracksStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tracksStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tracksStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tracksStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),

            // Track heights
            sceneTrack.heightAnchor.constraint(equalToConstant: 60),
            audioTrack.heightAnchor.constraint(equalToConstant: 40),
        ])

        // Content width constraint (will be updated in updateContentSize)
        contentWidthConstraint = contentView.widthAnchor.constraint(equalToConstant: 1000)
        contentWidthConstraint?.isActive = true
    }

    private func setupGestures() {
        // Pinch on the whole view
        addGestureRecognizer(pinchGesture)

        // Tap on tracks area
        xScrollView.addGestureRecognizer(tapGesture)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Update content size when view size changes (padding depends on bounds)
        updateContentSize()

        // Initial positioning: ensure frame 0 is under playhead on first layout
        // Must be done BEFORE notifyScrollChanged to send correct initial offset
        if !didInitialPositioning && !stateWasRestored && bounds.width > 0 {
            didInitialPositioning = true
            // offset=0 means time=0 is under playhead (at center)
            xScrollView.contentOffset = CGPoint(x: 0, y: 0)
        }

        // Notify ruler of current state (after offset is set correctly)
        emitScrollEvent()
    }

    // MARK: - Configuration

    /// Configures timeline with duration in microseconds and template FPS.
    /// Does NOT reset position - use restoreState() to set position after configure.
    /// - Parameters:
    ///   - durationUs: Duration in microseconds (source of truth)
    ///   - templateFPS: Template frame rate for quantization
    func configure(durationUs: TimeUs, templateFPS: Int) {
        self.durationUs = durationUs
        self.templateFPS = templateFPS > 0 ? templateFPS : 30

        // Pass leftPaddingPx to tracks for spacer
        let padding = leftPaddingPx
        sceneTrack.configure(durationUs: durationUs, pxPerSecond: pxPerSecond, leftPadding: padding)
        audioTrack.configure(durationUs: durationUs, pxPerSecond: pxPerSecond, leftPadding: padding)

        updateContentSize()
    }

    /// Updates current time position (from playback).
    /// Skips if user is currently dragging to avoid fighting.
    /// P1-1: Clamps time to valid range before storing.
    /// - Parameter timeUs: Time in microseconds
    func setCurrentTimeUs(_ timeUs: TimeUs) {
        // Don't interrupt user's drag/decelerate
        guard !xScrollView.isDragging && !xScrollView.isDecelerating else { return }

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
        let clampedTimeUs = clampTimeUs(timeUs, maxUs: durationUs)
        centerOnTimeUs(clampedTimeUs)

        // Sync internal state
        currentTimeUs = clampedTimeUs

        // Immediate ruler sync
        emitScrollEvent()
    }

    // MARK: - Selection (P1-3)

    /// Programmatically sets selection and updates track highlighting.
    /// Call this when restoring state or changing selection from outside TimelineView.
    /// - Parameter selection: The selection to apply
    func setSelection(_ selection: TimelineSelection) {
        switch selection {
        case .scene:
            sceneTrack.setSelected(true)
            audioTrack.setSelected(false)
        case .audio:
            sceneTrack.setSelected(false)
            audioTrack.setSelected(true)
        case .none:
            sceneTrack.setSelected(false)
            audioTrack.setSelected(false)
        }
    }

    // MARK: - Private Helpers

    private func updateContentSize() {
        let width = totalContentWidth

        // Update content width
        contentWidthConstraint?.constant = width

        // Update tracks with new pxPerSecond and padding
        let padding = leftPaddingPx
        sceneTrack.setPxPerSecond(pxPerSecond, leftPadding: padding)
        audioTrack.setPxPerSecond(pxPerSecond, leftPadding: padding)
    }

    /// Centers the given time under the playhead.
    /// - Parameter timeUs: Time in microseconds
    private func centerOnTimeUs(_ timeUs: TimeUs) {
        guard durationUs > 0 else { return }

        // offsetX = timeSeconds * pxPerSecond
        let timeSeconds = usToSeconds(timeUs)
        let offsetX = CGFloat(timeSeconds) * pxPerSecond
        let clampedX = clampOffsetX(offsetX)

        xScrollView.contentOffset = CGPoint(x: clampedX, y: 0)
        emitScrollEvent()
    }

    /// Returns the time currently under the playhead in microseconds.
    private func timeUnderPlayheadUs() -> TimeUs {
        guard pxPerSecond > 0 else { return 0 }

        // time = offsetX / pxPerSecond (simple, no inset math)
        let timeSeconds = Double(xScrollView.contentOffset.x / pxPerSecond)
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
        }
        #endif
        onEvent?(event)
    }

    /// Emits scroll event for ruler sync.
    private func emitScrollEvent() {
        emitEvent(.scroll(offsetX: xScrollView.contentOffset.x, pxPerSecond: pxPerSecond))
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === xScrollView else { return }

        // Clamp offset to valid range
        let rawX = scrollView.contentOffset.x
        let clampedX = clampOffsetX(rawX)
        if rawX != clampedX {
            // Setting contentOffset triggers another scrollViewDidScroll call,
            // so return here to emit event only on the normalized second call
            scrollView.contentOffset = CGPoint(x: clampedX, y: 0)
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
        guard scrollView === xScrollView else { return }

        // Start new scrub session
        isScrubSessionActive = true
        lastEmittedScrubTimeUs = nil

        // Emit .began event
        let timeUs = timeUnderPlayheadUs()
        emitEvent(.scrub(timeUs: timeUs, quantize: .dragging, phase: .began))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === xScrollView else { return }
        if !decelerate {
            emitFinalScrub()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === xScrollView else { return }
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
                let anchorTime = xScrollView.contentOffset.x / pxPerSecond

                // 2. Update zoom
                currentZoom = clampedZoom

                // 3. Update content size with new pxPerSecond
                updateContentSize()

                // 4. Calculate new offset to keep anchorTime under playhead
                let newPxPerSecond = pxPerSecond
                let newOffsetX = anchorTime * newPxPerSecond
                let clampedOffsetX = clampOffsetX(newOffsetX)

                // 5. Apply new offset (triggers scrollViewDidScroll which emits scroll event)
                xScrollView.contentOffset = CGPoint(x: clampedOffsetX, y: 0)
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

        // Check if tap is on scene track
        let sceneFrame = sceneTrack.convert(sceneTrack.bounds, to: contentView)
        if sceneFrame.contains(location) {
            emitEvent(.selection(.scene))
            sceneTrack.setSelected(true)
            audioTrack.setSelected(false)
            return
        }

        // Check if tap is on audio track
        let audioFrame = audioTrack.convert(audioTrack.bounds, to: contentView)
        if audioFrame.contains(location) {
            emitEvent(.selection(.audio))
            sceneTrack.setSelected(false)
            audioTrack.setSelected(true)
            return
        }

        // Tap on empty space - clear selection
        emitEvent(.selection(.none))
        sceneTrack.setSelected(false)
        audioTrack.setSelected(false)
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
