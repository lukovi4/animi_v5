import UIKit

// MARK: - Video Trim Bar View

/// Inline video trim bar with filmstrip, left/right handles, cursor, and dimming.
/// Does NOT contain Cancel/Done buttons (those live in EditorNavBar).
///
/// Layout (horizontal):
/// [dim-left][handle-left][filmstrip-visible][handle-right][dim-right]
///
/// Callbacks fire during drag gestures with normalized positions [0..1].
final class VideoTrimBarView: UIView {

    // MARK: - Callbacks

    /// Called when left handle position changes. Parameter: normalized position [0..1].
    var onTrimStartChanged: ((Double) -> Void)?

    /// Called when right handle position changes. Parameter: normalized position [0..1].
    var onTrimEndChanged: ((Double) -> Void)?

    /// Called when cursor position changes. Parameter: normalized position [0..1].
    var onCursorChanged: ((Double) -> Void)?

    /// Called when any drag gesture ends.
    var onDragEnded: (() -> Void)?

    // MARK: - Configuration

    /// Handle width in points.
    private static let handleWidth: CGFloat = 16

    /// Cursor width in points.
    private static let cursorWidth: CGFloat = 4

    /// Minimum distance between handles as fraction of total width.
    private static let minTrimFraction: Double = 0.02

    /// Filmstrip height in points.
    static let filmstripHeight: CGFloat = 56

    // MARK: - State

    /// Current trim start position [0..1]
    private(set) var trimStartFraction: Double = 0.0

    /// Current trim end position [0..1]
    private(set) var trimEndFraction: Double = 1.0

    /// Current cursor position [0..1]
    private(set) var cursorFraction: Double = 0.0

    // MARK: - Subviews

    private let filmstripView = VideoTrimFilmstripView()

    private let leftDimView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        v.isUserInteractionEnabled = false
        return v
    }()

    private let rightDimView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        v.isUserInteractionEnabled = false
        return v
    }()

    private let leftHandle: UIView = {
        let v = UIView()
        v.backgroundColor = .systemYellow
        v.layer.cornerRadius = 4
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        return v
    }()

    private let rightHandle: UIView = {
        let v = UIView()
        v.backgroundColor = .systemYellow
        v.layer.cornerRadius = 4
        v.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        return v
    }()

    private let topBorder: UIView = {
        let v = UIView()
        v.backgroundColor = .systemYellow
        v.isUserInteractionEnabled = false
        return v
    }()

    private let bottomBorder: UIView = {
        let v = UIView()
        v.backgroundColor = .systemYellow
        v.isUserInteractionEnabled = false
        return v
    }()

    private let cursorView: UIView = {
        let v = UIView()
        v.backgroundColor = .white
        v.layer.cornerRadius = 2
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.5
        v.layer.shadowRadius = 2
        v.layer.shadowOffset = .zero
        return v
    }()

    // MARK: - Gesture State

    private enum DragTarget {
        case leftHandle
        case rightHandle
        case cursor
    }

    private var activeDrag: DragTarget?
    private var dragStartX: CGFloat = 0
    private var dragStartFraction: Double = 0

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .black

        filmstripView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filmstripView)
        NSLayoutConstraint.activate([
            filmstripView.topAnchor.constraint(equalTo: topAnchor),
            filmstripView.leadingAnchor.constraint(equalTo: leadingAnchor),
            filmstripView.trailingAnchor.constraint(equalTo: trailingAnchor),
            filmstripView.heightAnchor.constraint(equalToConstant: Self.filmstripHeight),
        ])

        // Dimming overlays (positioned in layoutSubviews)
        addSubview(leftDimView)
        addSubview(rightDimView)

        // Handles (positioned in layoutSubviews)
        addSubview(leftHandle)
        addSubview(rightHandle)

        // Top/bottom borders between handles
        addSubview(topBorder)
        addSubview(bottomBorder)

        // Cursor
        addSubview(cursorView)
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFrames()
    }

    private func updateFrames() {
        let w = bounds.width
        let h = Self.filmstripHeight

        let leftX = w * trimStartFraction
        let rightX = w * trimEndFraction
        let hw = Self.handleWidth

        // Left dim
        leftDimView.frame = CGRect(x: 0, y: 0, width: leftX, height: h)

        // Right dim
        rightDimView.frame = CGRect(x: rightX, y: 0, width: w - rightX, height: h)

        // Handles
        leftHandle.frame = CGRect(x: leftX, y: 0, width: hw, height: h)
        rightHandle.frame = CGRect(x: rightX - hw, y: 0, width: hw, height: h)

        // Top/bottom borders
        let borderHeight: CGFloat = 3
        topBorder.frame = CGRect(x: leftX + hw, y: 0,
                                 width: rightX - leftX - 2 * hw, height: borderHeight)
        bottomBorder.frame = CGRect(x: leftX + hw, y: h - borderHeight,
                                    width: rightX - leftX - 2 * hw, height: borderHeight)

        // Cursor
        let cursorX = leftX + hw + (rightX - leftX - 2 * hw) * cursorPositionInTrimRange()
        cursorView.frame = CGRect(x: cursorX - Self.cursorWidth / 2, y: 0,
                                  width: Self.cursorWidth, height: h)
    }

    /// Returns cursor position as fraction within the visible trim range [0..1].
    private func cursorPositionInTrimRange() -> Double {
        let range = trimEndFraction - trimStartFraction
        guard range > 0 else { return 0 }
        return (cursorFraction - trimStartFraction) / range
    }

    // MARK: - Public API

    /// Sets the filmstrip thumbnails.
    func setThumbnails(_ images: [UIImage]) {
        filmstripView.setThumbnails(images)
    }

    /// Sets the trim range and cursor position.
    /// - Parameters:
    ///   - start: Trim start as fraction of total duration [0..1]
    ///   - end: Trim end as fraction of total duration [0..1]
    ///   - cursor: Cursor position as fraction of total duration [0..1]
    func setPositions(start: Double, end: Double, cursor: Double) {
        trimStartFraction = max(0, min(start, 1))
        trimEndFraction = max(0, min(end, 1))
        cursorFraction = max(trimStartFraction, min(cursor, trimEndFraction))
        updateFrames()
    }

    // MARK: - Gesture Handling

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        let w = bounds.width
        guard w > 0 else { return }

        switch gesture.state {
        case .began:
            activeDrag = hitTarget(at: location)
            dragStartX = location.x
            switch activeDrag {
            case .leftHandle: dragStartFraction = trimStartFraction
            case .rightHandle: dragStartFraction = trimEndFraction
            case .cursor: dragStartFraction = cursorFraction
            case nil: break
            }

        case .changed:
            guard let target = activeDrag else { return }
            let dx = location.x - dragStartX
            let dFraction = Double(dx) / Double(w)
            let newFraction = dragStartFraction + dFraction

            switch target {
            case .leftHandle:
                let clamped = max(0, min(newFraction, trimEndFraction - Self.minTrimFraction))
                trimStartFraction = clamped
                // Snap cursor to new start when dragging left handle
                cursorFraction = clamped
                onTrimStartChanged?(clamped)

            case .rightHandle:
                let clamped = max(trimStartFraction + Self.minTrimFraction, min(newFraction, 1.0))
                trimEndFraction = clamped
                // Snap cursor to new end when dragging right handle
                cursorFraction = clamped
                onTrimEndChanged?(clamped)

            case .cursor:
                let clamped = max(trimStartFraction, min(newFraction, trimEndFraction))
                cursorFraction = clamped
                onCursorChanged?(clamped)
            }
            updateFrames()

        case .ended, .cancelled, .failed:
            if activeDrag != nil {
                onDragEnded?()
            }
            activeDrag = nil

        default:
            break
        }
    }

    /// Determines which element the touch is closest to.
    private func hitTarget(at point: CGPoint) -> DragTarget? {
        let w = bounds.width
        let hw = Self.handleWidth
        let leftHandleCenter = w * trimStartFraction + hw / 2
        let rightHandleCenter = w * trimEndFraction - hw / 2
        let cursorCenter = leftHandle.frame.maxX + (rightHandle.frame.minX - leftHandle.frame.maxX) * cursorPositionInTrimRange()

        let hitRadius: CGFloat = 30

        // Priority: handles first (they're on the edges and most important)
        if abs(point.x - leftHandleCenter) < hitRadius {
            return .leftHandle
        }
        if abs(point.x - rightHandleCenter) < hitRadius {
            return .rightHandle
        }
        if abs(point.x - cursorCenter) < hitRadius {
            return .cursor
        }

        // Fallback: if touching between handles, move cursor
        if point.x > leftHandle.frame.maxX && point.x < rightHandle.frame.minX {
            return .cursor
        }

        return nil
    }
}
