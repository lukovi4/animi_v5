import UIKit

// MARK: - Text Position Overlay View (PR9: Canvas Drag Interaction)

/// Transparent overlay for dragging text overlay position on the preview canvas.
/// Embedded in previewContainer alongside EditorOverlayView.
///
/// Coordinate mapping:
/// - `centerX/centerY` are canvas-normalized [0,1]
/// - `canvasSize` is the actual canvas dimensions (from EditorCanvasMapper)
/// - `canvasToView` is the canvas→view transform (from EditorCanvasMapper.canvasToViewTransform())
/// - Display: normalized → canvas coords → view coords via transform
/// - Drag: view delta → canvas delta → normalized delta
final class OverlayPositionDragView: UIView {

    // MARK: - Callbacks

    /// Called when user drags text position. Parameters: (itemId, centerX, centerY, phase)
    var onDragPosition: ((UUID, CGFloat, CGFloat, InteractionPhase) -> Void)?

    // MARK: - State

    /// Currently selected text item for positioning.
    private(set) var selectedItem: (itemId: UUID, centerX: CGFloat, centerY: CGFloat)?

    /// Canvas size in scene units. Set by controller from EditorCanvasMapper.
    var canvasSize: CGSize = .zero {
        didSet { setNeedsLayout() }
    }

    /// Canvas-to-view affine transform. Set by controller from EditorCanvasMapper.canvasToViewTransform().
    var canvasToView: CGAffineTransform = .identity {
        didSet { setNeedsLayout() }
    }

    // MARK: - Subviews

    private lazy var handleView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        v.layer.borderColor = UIColor.white.cgColor
        v.layer.borderWidth = 1.5
        v.layer.cornerRadius = 4

        // Dash pattern via shape layer
        let dash = CAShapeLayer()
        dash.strokeColor = UIColor.white.withAlphaComponent(0.6).cgColor
        dash.fillColor = nil
        dash.lineWidth = 1.5
        dash.lineDashPattern = [4, 3]
        dash.frame = v.bounds
        v.layer.addSublayer(dash)

        v.isHidden = true
        return v
    }()

    private var dashLayer: CAShapeLayer? {
        handleView.layer.sublayers?.first as? CAShapeLayer
    }

    // MARK: - Gesture State

    private var dragStartCenterX: CGFloat = 0
    private var dragStartCenterY: CGFloat = 0
    private var dragStartPoint: CGPoint = .zero

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        isHidden = true

        addSubview(handleView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// Updates the selected text item for drag interaction.
    /// Pass nil itemId to hide the drag handle.
    func setSelectedItem(itemId: UUID?, centerX: CGFloat, centerY: CGFloat) {
        if let itemId {
            selectedItem = (itemId: itemId, centerX: centerX, centerY: centerY)
            handleView.isHidden = false
        } else {
            selectedItem = nil
            handleView.isHidden = true
        }
        setNeedsLayout()
    }

    /// Hides the drag handle.
    func clearSelection() {
        selectedItem = nil
        handleView.isHidden = true
    }

    // MARK: - Coordinate Conversion

    /// Converts normalized center (0..1) to view point via canvas coords.
    private func normalizedToView(_ centerX: CGFloat, _ centerY: CGFloat) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let canvasPoint = CGPoint(
            x: centerX * canvasSize.width,
            y: centerY * canvasSize.height
        )
        return canvasPoint.applying(canvasToView)
    }

    /// Converts a view-space delta to normalized delta (0..1 scale).
    private func viewDeltaToNormalized(_ delta: CGPoint) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        // Convert view delta to canvas delta via inverse transform (scale only)
        let inv = canvasToView.inverted()
        let originInView = CGPoint.zero.applying(canvasToView)
        let originPlusDelta = CGPoint(x: originInView.x + delta.x, y: originInView.y + delta.y)
        let canvasDelta = originPlusDelta.applying(inv)

        // Normalize by canvas size
        return CGPoint(
            x: canvasDelta.x / canvasSize.width,
            y: canvasDelta.y / canvasSize.height
        )
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let item = selectedItem,
              canvasSize.width > 0, canvasSize.height > 0 else { return }

        let viewPoint = normalizedToView(item.centerX, item.centerY)

        let handleSize: CGFloat = 60
        handleView.frame = CGRect(
            x: viewPoint.x - handleSize / 2,
            y: viewPoint.y - handleSize / 2,
            width: handleSize,
            height: handleSize
        )

        // Update dash layer path
        dashLayer?.frame = handleView.bounds
        dashLayer?.path = UIBezierPath(roundedRect: handleView.bounds, cornerRadius: 4).cgPath
    }

    // MARK: - Gesture Handling

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let item = selectedItem,
              canvasSize.width > 0, canvasSize.height > 0 else { return }

        switch recognizer.state {
        case .began:
            // Only start if touch is near the handle
            let location = recognizer.location(in: self)
            let expandedFrame = handleView.frame.insetBy(dx: -20, dy: -20)
            guard expandedFrame.contains(location) else {
                recognizer.state = .cancelled
                return
            }
            dragStartCenterX = item.centerX
            dragStartCenterY = item.centerY
            dragStartPoint = location
            onDragPosition?(item.itemId, item.centerX, item.centerY, .began)

        case .changed:
            let location = recognizer.location(in: self)
            let viewDelta = CGPoint(x: location.x - dragStartPoint.x, y: location.y - dragStartPoint.y)
            let normalizedDelta = viewDeltaToNormalized(viewDelta)

            let newCenterX = max(0, min(1, dragStartCenterX + normalizedDelta.x))
            let newCenterY = max(0, min(1, dragStartCenterY + normalizedDelta.y))

            selectedItem = (itemId: item.itemId, centerX: newCenterX, centerY: newCenterY)
            setNeedsLayout()
            onDragPosition?(item.itemId, newCenterX, newCenterY, .changed)

        case .ended:
            guard let current = selectedItem else { return }
            onDragPosition?(current.itemId, current.centerX, current.centerY, .ended)

        case .cancelled:
            onDragPosition?(item.itemId, dragStartCenterX, dragStartCenterY, .cancelled)
            selectedItem = (itemId: item.itemId, centerX: dragStartCenterX, centerY: dragStartCenterY)
            setNeedsLayout()

        default:
            break
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only capture touches near the handle
        guard let _ = selectedItem, !handleView.isHidden else { return nil }
        let expandedFrame = handleView.frame.insetBy(dx: -20, dy: -20)
        if expandedFrame.contains(point) {
            return self
        }
        return nil
    }
}
