import UIKit

// MARK: - Timeline View (PR2.1)

/// Horizontal scrolling timeline with pinch zoom support.
/// Contains track views (SceneTrackView, AudioTrackView placeholder).
/// Supports scrubbing and selection.
///
/// Playhead model: playhead is fixed at center X of the view.
/// Content scrolls underneath. contentInset provides padding so
/// frame 0 can be centered and last frame can be centered.
///
/// PR2.1 Architecture:
/// - timeScrollView: horizontal X scroll + pinch zoom + contentInset
/// - tracksVerticalScrollView: vertical Y scroll for tracks
/// - X sync via transform on tracksContentView
final class TimelineView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    // MARK: - Callbacks

    /// Called when timeline is scrubbed (passes frame index under playhead)
    var onScrub: ((Int) -> Void)?

    /// Called when scroll/zoom changes (for ruler sync)
    var onScrollChanged: ((CGPoint, CGFloat) -> Void)?

    /// Called when timeline selection changes
    var onSelectionChanged: ((TimelineSelection) -> Void)?

    // MARK: - Configuration

    private var durationFrames: Int = 0
    private var fps: Int = 30
    private var currentZoom: CGFloat = 1.0
    private var currentFrame: Int = 0

    // MARK: - Continuous Scrub State (PR2.1 P1-A)

    private var lastEmittedScrubFrame: Int?

    // MARK: - Ruler Throttle State (PR2.1 P1-C)

    private var displayLink: CADisplayLink?
    private var rulerNeedsUpdate = false
    private var pendingOffset: CGPoint = .zero
    private var pendingPxPerSecond: CGFloat = 0

    // MARK: - Computed

    private var pxPerSecond: CGFloat {
        EditorConfig.basePxPerSecond * currentZoom
    }

    private var pxPerFrame: CGFloat {
        guard fps > 0 else { return 1 }
        return pxPerSecond / CGFloat(fps)
    }

    private var totalContentWidth: CGFloat {
        guard fps > 0 else { return 0 }
        let durationSeconds = CGFloat(durationFrames) / CGFloat(fps)
        return durationSeconds * pxPerSecond
    }

    /// Horizontal padding (half of view width) so playhead can reach first/last frame
    private var horizontalPadding: CGFloat {
        bounds.width / 2
    }

    /// Current content offset (for external access by ruler)
    var contentOffset: CGPoint {
        timeScrollView.contentOffset
    }

    // MARK: - Subviews (PR2.1 Architecture)

    /// Horizontal scroll for time (X) + pinch zoom + contentInset
    private lazy var timeScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.delegate = self
        sv.decelerationRate = .fast
        return sv
    }()

    /// Content inside timeScrollView (width = duration)
    private lazy var timeContentView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        return v
    }()

    /// Vertical scroll for tracks (Y)
    private lazy var tracksVerticalScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = true
        sv.alwaysBounceVertical = true
        sv.clipsToBounds = true
        return sv
    }()

    /// Content inside tracksVerticalScrollView (transform.x synced with timeScrollView)
    private lazy var tracksContentView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
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

    private var timeContentWidthConstraint: NSLayoutConstraint?
    private var tracksContentWidthConstraint: NSLayoutConstraint?

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
        setupDisplayLink()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .secondarySystemBackground

        // Time scroll view (invisible, just for X scroll/zoom tracking)
        addSubview(timeScrollView)
        timeScrollView.addSubview(timeContentView)

        // Tracks vertical scroll view (visible, contains tracks)
        addSubview(tracksVerticalScrollView)
        tracksVerticalScrollView.addSubview(tracksContentView)
        tracksContentView.addSubview(tracksStack)

        // Add tracks
        tracksStack.addArrangedSubview(sceneTrack)
        tracksStack.addArrangedSubview(audioTrack)

        #if DEBUG
        // Add stub tracks for testing vertical scroll
        for i in 0..<EditorConfig.debugExtraTracksCount {
            let stubTrack = createStubTrack(index: i)
            tracksStack.addArrangedSubview(stubTrack)
        }
        #endif
    }

    #if DEBUG
    private func createStubTrack(index: Int) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.systemGray.withAlphaComponent(0.3)
        view.layer.cornerRadius = 6

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Track \(index + 3)"
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabel
        view.addSubview(label)

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 40),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        return view
    }
    #endif

    private func setupConstraints() {
        sceneTrack.translatesAutoresizingMaskIntoConstraints = false
        audioTrack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Time scroll view fills the view (invisible layer for X scroll)
            timeScrollView.topAnchor.constraint(equalTo: topAnchor),
            timeScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            timeScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            timeScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Time content view
            timeContentView.topAnchor.constraint(equalTo: timeScrollView.contentLayoutGuide.topAnchor),
            timeContentView.leadingAnchor.constraint(equalTo: timeScrollView.contentLayoutGuide.leadingAnchor),
            timeContentView.trailingAnchor.constraint(equalTo: timeScrollView.contentLayoutGuide.trailingAnchor),
            timeContentView.bottomAnchor.constraint(equalTo: timeScrollView.contentLayoutGuide.bottomAnchor),
            timeContentView.heightAnchor.constraint(equalTo: timeScrollView.frameLayoutGuide.heightAnchor),

            // Tracks vertical scroll view fills the view
            tracksVerticalScrollView.topAnchor.constraint(equalTo: topAnchor),
            tracksVerticalScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tracksVerticalScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tracksVerticalScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Tracks content view
            tracksContentView.topAnchor.constraint(equalTo: tracksVerticalScrollView.contentLayoutGuide.topAnchor),
            tracksContentView.leadingAnchor.constraint(equalTo: tracksVerticalScrollView.contentLayoutGuide.leadingAnchor),
            tracksContentView.bottomAnchor.constraint(equalTo: tracksVerticalScrollView.contentLayoutGuide.bottomAnchor),
            // Width will be set by constraint

            // Tracks stack inside content
            tracksStack.topAnchor.constraint(equalTo: tracksContentView.topAnchor, constant: 8),
            tracksStack.leadingAnchor.constraint(equalTo: tracksContentView.leadingAnchor),
            tracksStack.trailingAnchor.constraint(equalTo: tracksContentView.trailingAnchor),
            tracksStack.bottomAnchor.constraint(equalTo: tracksContentView.bottomAnchor, constant: -8),

            // Track heights
            sceneTrack.heightAnchor.constraint(equalToConstant: 60),
            audioTrack.heightAnchor.constraint(equalToConstant: 40),
        ])

        // Content width constraints
        timeContentWidthConstraint = timeContentView.widthAnchor.constraint(equalToConstant: 1000)
        timeContentWidthConstraint?.isActive = true

        tracksContentWidthConstraint = tracksContentView.widthAnchor.constraint(equalToConstant: 1000)
        tracksContentWidthConstraint?.isActive = true
    }

    private func setupGestures() {
        // Pinch on the whole view
        addGestureRecognizer(pinchGesture)

        // Tap on tracks area
        tracksVerticalScrollView.addGestureRecognizer(tapGesture)

        // Forward pan gestures from tracksVerticalScrollView to timeScrollView for X
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        tracksVerticalScrollView.addGestureRecognizer(panGesture)
    }

    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.add(to: .main, forMode: .common)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Update contentInset when view size changes
        updateContentInset()
    }

    // MARK: - Configuration

    /// Configures timeline with duration and FPS.
    func configure(durationFrames: Int, fps: Int) {
        self.durationFrames = durationFrames
        self.fps = fps > 0 ? fps : 30

        sceneTrack.configure(durationFrames: durationFrames, fps: fps, pxPerSecond: pxPerSecond)
        audioTrack.configure(durationFrames: durationFrames, fps: fps, pxPerSecond: pxPerSecond)

        updateContentSize()
        centerOnFrame(0)
    }

    /// Updates current frame position (from playback).
    /// Skips if user is currently dragging to avoid fighting.
    func setCurrentFrame(_ frame: Int) {
        // Don't interrupt user's drag/decelerate
        guard !timeScrollView.isDragging && !timeScrollView.isDecelerating else { return }

        currentFrame = frame
        centerOnFrame(frame)
    }

    // MARK: - Private Helpers

    private func updateContentInset() {
        // Padding so frame 0 and last frame can be centered under playhead
        let padding = horizontalPadding
        timeScrollView.contentInset = UIEdgeInsets(top: 0, left: padding, bottom: 0, right: padding)
    }

    private func updateContentSize() {
        let width = totalContentWidth

        // Update time content width
        timeContentWidthConstraint?.constant = width

        // Update tracks content width
        tracksContentWidthConstraint?.constant = width

        // Update tracks
        sceneTrack.setPxPerSecond(pxPerSecond)
        audioTrack.setPxPerSecond(pxPerSecond)

        // Update inset for current bounds
        updateContentInset()

        // Mark ruler for update
        markRulerNeedsUpdate()
    }

    private func syncTracksTransform() {
        // Sync X position of tracks with timeScrollView offset
        let offsetX = timeScrollView.contentOffset.x + horizontalPadding
        tracksContentView.transform = CGAffineTransform(translationX: -offsetX, y: 0)
    }

    private func centerOnFrame(_ frame: Int) {
        guard durationFrames > 0, fps > 0 else { return }

        // Frame position in content coordinates (starts at 0)
        let frameX = CGFloat(frame) * pxPerFrame

        // To center this frame under playhead (center of view),
        // we need contentOffset.x such that:
        // contentOffset.x + padding = frameX
        // where padding = contentInset.left = bounds.width/2
        //
        // So: contentOffset.x = frameX - padding
        // Note: with contentInset, valid offset range is [-padding, contentWidth - viewWidth + padding]
        let padding = horizontalPadding
        let targetOffset = frameX - padding

        // Clamp to valid range
        let minOffset = -padding
        let maxOffset = totalContentWidth - bounds.width + padding
        let clampedOffset = max(minOffset, min(targetOffset, maxOffset))

        timeScrollView.contentOffset = CGPoint(x: clampedOffset, y: 0)
        syncTracksTransform()
    }

    private func frameUnderPlayhead() -> Int {
        // Playhead is at center of view
        // With contentInset, the content coordinate under center is:
        // contentX = contentOffset.x + padding
        // where padding = contentInset.left
        let padding = horizontalPadding
        let contentX = timeScrollView.contentOffset.x + padding

        guard pxPerFrame > 0 else { return 0 }
        let frame = Int(contentX / pxPerFrame)
        return max(0, min(frame, max(0, durationFrames - 1)))
    }

    // MARK: - Ruler Throttle (PR2.1 P1-C)

    private func markRulerNeedsUpdate() {
        rulerNeedsUpdate = true
        pendingOffset = timeScrollView.contentOffset
        pendingPxPerSecond = pxPerSecond
    }

    @objc private func displayLinkFired() {
        if rulerNeedsUpdate {
            onScrollChanged?(pendingOffset, pendingPxPerSecond)
            rulerNeedsUpdate = false
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === timeScrollView else { return }

        // Sync tracks X position
        syncTracksTransform()

        // Mark ruler for throttled update
        markRulerNeedsUpdate()

        // PR2.1 P1-A: Continuous scrub during drag
        if scrollView.isDragging {
            let frame = frameUnderPlayhead()
            if frame != lastEmittedScrubFrame {
                lastEmittedScrubFrame = frame
                onScrub?(frame)
            }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === timeScrollView else { return }
        // Reset scrub tracking for new drag session
        lastEmittedScrubFrame = nil
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === timeScrollView else { return }
        if !decelerate {
            emitScrub()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === timeScrollView else { return }
        emitScrub()
    }

    private func emitScrub() {
        let frame = frameUnderPlayhead()
        onScrub?(frame)
    }

    // MARK: - Gesture Handlers

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        // Forward horizontal pan to timeScrollView
        let translation = recognizer.translation(in: self)
        let velocity = recognizer.velocity(in: self)

        switch recognizer.state {
        case .began:
            // Begin dragging timeScrollView
            lastEmittedScrubFrame = nil

        case .changed:
            // Update timeScrollView offset
            var newOffset = timeScrollView.contentOffset
            newOffset.x -= translation.x
            timeScrollView.contentOffset = newOffset
            recognizer.setTranslation(.zero, in: self)

            // Sync and emit
            syncTracksTransform()
            markRulerNeedsUpdate()

            // Continuous scrub
            let frame = frameUnderPlayhead()
            if frame != lastEmittedScrubFrame {
                lastEmittedScrubFrame = frame
                onScrub?(frame)
            }

        case .ended, .cancelled:
            // Apply deceleration
            let decelerationRate = UIScrollView.DecelerationRate.fast.rawValue
            let projectedX = timeScrollView.contentOffset.x - velocity.x * decelerationRate

            // Clamp to valid range
            let padding = horizontalPadding
            let minOffset = -padding
            let maxOffset = totalContentWidth - bounds.width + padding
            let clampedOffset = max(minOffset, min(projectedX, maxOffset))

            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
                self.timeScrollView.contentOffset = CGPoint(x: clampedOffset, y: 0)
                self.syncTracksTransform()
            } completion: { _ in
                self.emitScrub()
            }

        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            let newZoom = currentZoom * recognizer.scale
            let clampedZoom = max(1.0, min(newZoom, EditorConfig.zoomMax))

            if clampedZoom != currentZoom {
                // Save frame under playhead before zoom
                let frameBeforeZoom = frameUnderPlayhead()

                currentZoom = clampedZoom
                updateContentSize()

                // Restore frame under playhead after zoom
                centerOnFrame(frameBeforeZoom)
            }

            recognizer.scale = 1.0

        case .ended, .cancelled:
            // Emit final scrub position
            emitScrub()

        default:
            break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: tracksContentView)

        // Check if tap is on scene track
        let sceneFrame = sceneTrack.convert(sceneTrack.bounds, to: tracksContentView)
        if sceneFrame.contains(location) {
            onSelectionChanged?(.scene)
            sceneTrack.setSelected(true)
            audioTrack.setSelected(false)
            return
        }

        // Check if tap is on audio track
        let audioFrame = audioTrack.convert(audioTrack.bounds, to: tracksContentView)
        if audioFrame.contains(location) {
            onSelectionChanged?(.audio)
            sceneTrack.setSelected(false)
            audioTrack.setSelected(true)
            return
        }

        // Tap on empty space - clear selection
        onSelectionChanged?(.none)
        sceneTrack.setSelected(false)
        audioTrack.setSelected(false)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow pinch alongside scroll/pan
        if gestureRecognizer == pinchGesture {
            return true
        }
        // Allow pan alongside vertical scroll
        if gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer == tracksVerticalScrollView.panGestureRecognizer {
            return true
        }
        return false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // For our custom pan gesture, only begin if primarily horizontal
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan != tracksVerticalScrollView.panGestureRecognizer {
            let velocity = pan.velocity(in: self)
            return abs(velocity.x) > abs(velocity.y)
        }
        return true
    }
}
