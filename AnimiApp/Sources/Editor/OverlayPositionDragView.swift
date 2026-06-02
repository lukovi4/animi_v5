import UIKit
import TVECore

// MARK: - Text Box Transform Overlay View

/// Transparent overlay for transforming the selected text overlay box on the
/// preview canvas: one-finger pan (move), two-finger pinch (boxWidth + fontSize),
/// two-finger rotate. Draws the real rotated text-box selection border AND, while
/// a text box is being transformed, the live text itself via a transient Core
/// Animation layer (`TextOverlayLiveTextLayer`).
///
/// Live interaction model: during a text-box gesture the committed Metal copy of
/// the text is hidden by the runtime (begin/end hiding, driven by the controller
/// via the `.began`/`.ended`/`.cancelled` callbacks) and this view's live layer
/// is the only visible text. `.changed` updates ONLY the transient live layer +
/// selection border — never the store, engine, resolver, texture cache, Metal
/// render executor, or audio. The model is committed exactly once on `.ended`.
/// Raw gesture events are coalesced to display frames via `CADisplayLink`.
///
/// Single gesture ownership: this view owns the pan/pinch/rotate recognizers for
/// timeline text boxes. The parent preview gesture handlers remain scene-edit
/// only, so the same gesture deltas are never applied twice.
///
/// Coordinate mapping:
/// - `centerX/centerY` are canvas-normalized [0,1]
/// - `canvasSize` is the actual canvas dimensions (from EditorCanvasMapper)
/// - `canvasToView` is the canvas→view transform (from EditorCanvasMapper.canvasToViewTransform())
final class OverlayPositionDragView: UIView {

    // MARK: - Callbacks

    /// Called as the user transforms the selected text box.
    /// Parameters: (itemId, centerX, centerY, boxWidth, fontSize, rotation, phase).
    /// `boxWidth` is canvas-normalized, `rotation` is radians.
    var onTransform: ((UUID, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, InteractionPhase) -> Void)?

    /// Called as the user drags a selected sticker's position (pan only).
    /// Parameters: (itemId, centerX, centerY, phase). Preserves the pre-existing
    /// sticker position-drag behavior.
    var onDragPosition: ((UUID, CGFloat, CGFloat, InteractionPhase) -> Void)?

    /// Single tap at a preview view point (only fired while this view owns the
    /// surface, i.e. a text box is selected). Routes to the existing tap
    /// selection logic so the user can select a different/empty target.
    var onSingleTap: ((CGPoint) -> Void)?

    /// Double tap at a preview view point (only while a text box is selected).
    /// Opens the existing text editor for the tapped/selected text.
    var onDoubleTap: ((CGPoint) -> Void)?

    // MARK: - Selected Box State

    /// Snapshot of the selected text box used for drawing the border and seeding
    /// gesture baselines.
    struct SelectedBox {
        let itemId: UUID
        var centerX: CGFloat
        var centerY: CGFloat
        var boxWidth: CGFloat
        var fontSize: CGFloat
        var rotation: CGFloat
        /// Rendered content size in canvas units (from shared layout). Drives the
        /// drawn border rectangle. Falls back to a small default if unavailable.
        var contentCanvasSize: CGSize
        // Text style/content for the live text layer (matches the committed
        // render inputs so the live text is pixel-equivalent to the Metal copy).
        var text: String
        var fontFamily: String?
        var colorHex: String
    }

    private(set) var selectedBox: SelectedBox?

    /// Snapshot of a selected sticker (pan-only, axis-aligned border).
    struct SelectedSticker {
        let itemId: UUID
        var centerX: CGFloat
        var centerY: CGFloat
        var contentCanvasSize: CGSize
    }

    private(set) var selectedSticker: SelectedSticker?

    // Sticker pan baseline.
    private var stickerDragStartCenterX: CGFloat = 0
    private var stickerDragStartCenterY: CGFloat = 0

    /// Canvas size in scene units. Set by controller from EditorCanvasMapper.
    var canvasSize: CGSize = .zero {
        didSet { setNeedsLayout() }
    }

    /// Canvas-to-view affine transform. Set by controller from EditorCanvasMapper.canvasToViewTransform().
    var canvasToView: CGAffineTransform = .identity {
        didSet { setNeedsLayout() }
    }

    // MARK: - Subviews

    /// Border drawn as a rotated dashed rectangle following the text box.
    private let borderLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        l.fillColor = UIColor.white.withAlphaComponent(0.06).cgColor
        l.lineWidth = 1.5
        l.lineDashPattern = [4, 3]
        l.isHidden = true
        return l
    }()

    /// Full-bounds host for the live text layer. The canvas clip mask is applied
    /// HERE (not on `liveTextLayer`): the host's `frame == bounds` and it is never
    /// translated/rotated, so a mask path built in this view's coordinate space
    /// (like `canvasRectInView`) is already in the host's local space and clips
    /// correctly. The transformed `liveTextLayer` lives inside it, so it inherits
    /// the canvas clip at the template edge regardless of its own position/rotation.
    private let liveTextHost: CALayer = {
        let l = CALayer()
        l.isHidden = true
        return l
    }()

    /// Transient live text layer, visible only during a text-box transform.
    /// Renders the selected text in lockstep with the gesture so the committed
    /// Metal copy can stay hidden (no ghost). Hosted inside `liveTextHost`.
    private let liveTextLayer = TextOverlayLiveTextLayer()

    // MARK: - Gesture State

    private var session: TextOverlayTransformSession?
    private var activeGestures: Set<ObjectIdentifier> = []
    private var sessionCancelled = false

    /// Coalesces raw gesture events to display frames: recognizers set
    /// `pendingResult` and the display link applies the latest result once per
    /// frame, avoiding redundant layout/redraw between vsyncs.
    private var displayLink: CADisplayLink?
    private var pendingResult: TextOverlayTransformSession.Result?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        isHidden = true
        // Live text (inside its clipping host) below the selection border so the
        // dashed frame stays visible above the text.
        liveTextHost.addSublayer(liveTextLayer)
        layer.addSublayer(liveTextHost)
        layer.addSublayer(borderLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        pinch.delegate = self
        rotate.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
        addGestureRecognizer(rotate)

        // Tap + double-tap: only relevant while this view owns the surface (a
        // text box is selected). Single tap waits for double tap so selection
        // does not fight editing.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(singleTap)
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        onSingleTap?(convertToPreview(recognizer.location(in: self)))
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        onDoubleTap?(convertToPreview(recognizer.location(in: self)))
    }

    /// Tap location is already in this view's coordinate space, which matches
    /// the preview container/overlay space used by hit testing.
    private func convertToPreview(_ point: CGPoint) -> CGPoint { point }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// Updates the selected text box for transform interaction.
    /// Pass nil to hide the selection border.
    ///
    /// Applying a fresh box from the store also tears down any live text layer:
    /// this is the seam where the just-committed (or restored) Metal render takes
    /// over, so hiding the transient layer here avoids a ghost without flicker.
    /// While a gesture is in flight (`session != nil`) the live layer is kept —
    /// the controller does not re-seed the box mid-gesture, so this only fires on
    /// commit/cancel/selection sync.
    func setSelectedBox(_ box: SelectedBox?) {
        selectedBox = box
        if box != nil { selectedSticker = nil }
        borderLayer.isHidden = (box == nil)
        if session == nil { hideLiveTextLayer() }
        setNeedsLayout()
    }

    /// Updates the selected sticker for pan-only position drag.
    func setSelectedSticker(_ sticker: SelectedSticker?) {
        selectedSticker = sticker
        if sticker != nil { selectedBox = nil }
        borderLayer.isHidden = (sticker == nil)
        hideLiveTextLayer()
        setNeedsLayout()
    }

    /// Hides the selection border and the live text layer.
    func clearSelection() {
        selectedBox = nil
        selectedSticker = nil
        borderLayer.isHidden = true
        hideLiveTextLayer()
    }

    // MARK: - Coordinate Conversion

    /// Converts normalized center (0..1) to view point via canvas coords.
    private func normalizedToView(_ centerX: CGFloat, _ centerY: CGFloat) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let canvasPoint = CGPoint(x: centerX * canvasSize.width, y: centerY * canvasSize.height)
        return canvasPoint.applying(canvasToView)
    }

    /// Converts a view-space delta to normalized delta (0..1 scale).
    private func viewDeltaToNormalized(_ delta: CGPoint) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let inv = canvasToView.inverted()
        let originInView = CGPoint.zero.applying(canvasToView)
        let originPlusDelta = CGPoint(x: originInView.x + delta.x, y: originInView.y + delta.y)
        let canvasDelta = originPlusDelta.applying(inv)
        return CGPoint(x: canvasDelta.x / canvasSize.width, y: canvasDelta.y / canvasSize.height)
    }

    /// Points-per-canvas-unit scale of the canvas→view transform (uniform).
    private var pointsPerCanvasUnit: CGFloat {
        let origin = CGPoint.zero.applying(canvasToView)
        let unit = CGPoint(x: 1, y: 0).applying(canvasToView)
        return hypot(unit.x - origin.x, unit.y - origin.y)
    }

    /// The canvas/template rect in view-point space (where the preview is drawn).
    private var canvasRectInView: CGRect {
        let topLeft = normalizedToView(0, 0)
        let bottomRight = normalizedToView(1, 1)
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    /// Clips a layer to the canvas rect so an off-canvas text box's content/border
    /// disappears under the template edge, matching the render clip.
    private func canvasClipMask() -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.path = UIBezierPath(rect: canvasRectInView).cgPath
        return mask
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let scale = pointsPerCanvasUnit
        borderLayer.mask = canvasClipMask()

        if let box = selectedBox {
            let center = normalizedToView(box.centerX, box.centerY)
            let w = max(box.contentCanvasSize.width, 1) * scale
            let h = max(box.contentCanvasSize.height, 1) * scale
            // Build the rotated border from the SHARED layout corners so the box
            // rotates in lockstep with the rendered text (one rotation convention).
            let corners = TextOverlayLayout.rotatedCorners(
                center: center, size: CGSize(width: w, height: h), rotation: box.rotation
            )
            let path = UIBezierPath()
            path.move(to: corners[0])
            for c in corners.dropFirst() { path.addLine(to: c) }
            path.close()
            borderLayer.frame = bounds
            borderLayer.path = path.cgPath
            layoutLiveTextLayer(box: box, center: center, size: CGSize(width: w, height: h))
        } else if let sticker = selectedSticker {
            let center = normalizedToView(sticker.centerX, sticker.centerY)
            let w = max(sticker.contentCanvasSize.width, 1) * scale
            let h = max(sticker.contentCanvasSize.height, 1) * scale
            let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            borderLayer.frame = bounds
            borderLayer.path = UIBezierPath(rect: rect).cgPath
        }
    }

    /// Positions/sizes the live text layer to the box's rotated content rect and
    /// refreshes its drawn text. Implicit animations are disabled so the layer
    /// tracks the gesture without rubber-banding.
    ///
    /// Clipping contract: the canvas mask is applied to `liveTextHost` (frame ==
    /// this view's bounds, never transformed), so the mask path — built in this
    /// view's coordinate space by `canvasRectInView` — is already in the host's
    /// local space and clips at the template edge correctly. The `liveTextLayer`
    /// is a child of the host with its own center/rotation and therefore inherits
    /// that clip regardless of how far off-canvas it is dragged.
    private func layoutLiveTextLayer(box: SelectedBox, center: CGPoint, size: CGSize) {
        guard !liveTextHost.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        liveTextHost.frame = bounds
        liveTextHost.mask = canvasClipMask()

        liveTextLayer.update(
            content: TextOverlayLiveTextLayer.Content(
                text: box.text,
                fontFamily: box.fontFamily,
                fontSize: box.fontSize,
                colorHex: box.colorHex,
                boxWidth: box.boxWidth
            ),
            pointsPerCanvasUnit: pointsPerCanvasUnit,
            canvasSize: SizeD(width: Double(canvasSize.width), height: Double(canvasSize.height))
        )
        liveTextLayer.bounds = CGRect(origin: .zero, size: size)
        // `center` is in this view's space; the host fills bounds at origin .zero,
        // so the host's local space equals the view's space — use `center` directly.
        liveTextLayer.position = center
        liveTextLayer.setAffineTransform(CGAffineTransform(rotationAngle: box.rotation))

        CATransaction.commit()
    }

    /// Shows the live text layer at the current selected-box state (called on
    /// gesture begin so the live text appears as the committed copy is hidden).
    private func showLiveTextLayer() {
        liveTextHost.isHidden = false
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Hides the live text layer (called on end/cancel after the committed copy
    /// is restored, and on selection/mode changes that tear down the gesture).
    private func hideLiveTextLayer() {
        liveTextHost.isHidden = true
    }

    // MARK: - Display-Frame Coalescing

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(applyPendingResult))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        pendingResult = nil
    }

    /// Applies the latest coalesced gesture result once per display frame: update
    /// the transient live layer + border only. NO store/engine/render work.
    @objc private func applyPendingResult() {
        guard let r = pendingResult else { return }
        pendingResult = nil
        applyToSelectedBox(r)
    }

    // MARK: - Gesture Handling

    private func beginIfNeeded(_ recognizer: UIGestureRecognizer) {
        let id = ObjectIdentifier(recognizer)
        let firstGesture = activeGestures.isEmpty
        activeGestures.insert(id)
        if session == nil, let box = selectedBox {
            session = TextOverlayTransformSession(
                itemId: box.itemId,
                baselineCenterX: box.centerX,
                baselineCenterY: box.centerY,
                baselineBoxWidth: box.boxWidth,
                baselineFontSize: box.fontSize,
                baselineRotation: box.rotation
            )
            sessionCancelled = false
        }
        if firstGesture, let session {
            // Begin: show the live text layer and start display-frame coalescing.
            // The committed Metal copy is hidden by the controller in response to
            // this `.began` callback (one scoped refresh — no per-tick render).
            showLiveTextLayer()
            startDisplayLink()
            let b = session.baseline()
            onTransform?(session.itemId, b.centerX, b.centerY, b.boxWidth, b.fontSize, b.rotation, .began)
        }
    }

    /// Records the latest gesture result for the next display frame. NO store /
    /// engine / resolver / render work happens here — only the transient live
    /// layer + border update, applied once per vsync by `applyPendingResult`.
    private func scheduleChanged() {
        guard let session else { return }
        pendingResult = session.current()
    }

    private func endGesture(_ recognizer: UIGestureRecognizer, cancelled: Bool) {
        let id = ObjectIdentifier(recognizer)
        activeGestures.remove(id)
        guard let session else { return }
        if cancelled { sessionCancelled = true }

        // Only commit when the LAST active recognizer ends; meanwhile keep the
        // live layer tracking via coalesced display-frame updates.
        guard activeGestures.isEmpty else {
            scheduleChanged()
            return
        }

        // Apply the final transform to the live layer immediately (no waiting for
        // the next vsync) so the committed callback fires on the exact end state.
        stopDisplayLink()

        let itemId = session.itemId
        let cancelled = sessionCancelled
        let result = cancelled ? session.baseline() : session.current()
        applyToSelectedBox(result)

        // Clear the session BEFORE the terminal callback so that when the
        // controller re-seeds the selection box in response (commit/cancel sync),
        // `setSelectedBox` sees `session == nil` and tears down the live layer
        // after the committed Metal render is back — no ghost, no flicker.
        self.session = nil
        sessionCancelled = false

        // Cancel: no model mutation. Commit: persist once. Either way the
        // controller restores the committed render and re-applies the selection.
        onTransform?(
            itemId, result.centerX, result.centerY, result.boxWidth,
            result.fontSize, result.rotation, cancelled ? .cancelled : .ended
        )
    }

    /// Mirrors session result into the local selection snapshot so the border and
    /// live text layer track the gesture (box size/rotation update on next layout).
    private func applyToSelectedBox(_ r: TextOverlayTransformSession.Result) {
        guard var box = selectedBox else { return }
        box.centerX = r.centerX
        box.centerY = r.centerY
        box.boxWidth = r.boxWidth
        box.fontSize = r.fontSize
        box.rotation = r.rotation
        box.contentCanvasSize = liveContentCanvasSize(for: box)
        selectedBox = box
        setNeedsLayout()
    }

    /// Test seam: shows the live text layer as a gesture `.began` would, so tests
    /// can inspect the live host/mask without driving private recognizers.
    func beginLiveInteractionForTesting() {
        showLiveTextLayer()
    }

    /// Test seam: applies a transform result to the selected box exactly as the
    /// per-display-frame coalescer does on `.changed`, so tests can prove live
    /// bounds reflow through the shared layout and that the live host/mask are
    /// configured, without driving private gesture recognizers.
    func applyTransformResultForTesting(_ r: TextOverlayTransformSession.Result) {
        applyToSelectedBox(r)
        layoutIfNeeded()
    }

    /// Test seam: the live text host layer (carries the canvas clip mask).
    var liveTextHostForTesting: CALayer { liveTextHost }

    /// Test seam: the live text layer hosted inside `liveTextHost`.
    var liveTextLayerForTesting: CALayer { liveTextLayer }

    /// Recomputes the box's content size through the SHARED `TextOverlayLayout`
    /// for the current text/font/boxWidth/fontSize, so the live border + live
    /// text layer reflow exactly like the committed render. This is what keeps
    /// pinch (which changes wrapping) from diverging — proportional scaling of
    /// the cached size is wrong when line breaks change. Falls back to the
    /// existing cached size if the canvas is not yet known.
    private func liveContentCanvasSize(for box: SelectedBox) -> CGSize {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return box.contentCanvasSize }
        let computed = TextOverlayLiveTextLayer.contentCanvasSize(
            content: TextOverlayLiveTextLayer.Content(
                text: box.text,
                fontFamily: box.fontFamily,
                fontSize: box.fontSize,
                colorHex: box.colorHex,
                boxWidth: box.boxWidth
            ),
            canvasSize: SizeD(width: Double(canvasSize.width), height: Double(canvasSize.height))
        )
        return computed ?? box.contentCanvasSize
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        if selectedBox != nil {
            switch recognizer.state {
            case .began:
                beginIfNeeded(recognizer)
            case .changed:
                let t = recognizer.translation(in: self)
                let n = viewDeltaToNormalized(t)
                session?.translationDelta = (n.x, n.y)
                scheduleChanged()
            case .ended:
                endGesture(recognizer, cancelled: false)
            case .cancelled, .failed:
                endGesture(recognizer, cancelled: true)
            default:
                break
            }
            return
        }

        // Sticker pan-only path (preserves prior behavior).
        guard let sticker = selectedSticker else { return }
        switch recognizer.state {
        case .began:
            stickerDragStartCenterX = sticker.centerX
            stickerDragStartCenterY = sticker.centerY
            onDragPosition?(sticker.itemId, sticker.centerX, sticker.centerY, .began)
        case .changed:
            let t = recognizer.translation(in: self)
            let n = viewDeltaToNormalized(t)
            let nx = max(0, min(1, stickerDragStartCenterX + n.x))
            let ny = max(0, min(1, stickerDragStartCenterY + n.y))
            var updated = sticker
            updated.centerX = nx
            updated.centerY = ny
            selectedSticker = updated
            setNeedsLayout()
            onDragPosition?(sticker.itemId, nx, ny, .changed)
        case .ended:
            guard let current = selectedSticker else { return }
            onDragPosition?(current.itemId, current.centerX, current.centerY, .ended)
        case .cancelled, .failed:
            var reverted = sticker
            reverted.centerX = stickerDragStartCenterX
            reverted.centerY = stickerDragStartCenterY
            selectedSticker = reverted
            setNeedsLayout()
            onDragPosition?(sticker.itemId, stickerDragStartCenterX, stickerDragStartCenterY, .cancelled)
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard selectedBox != nil else { return }
        switch recognizer.state {
        case .began:
            beginIfNeeded(recognizer)
        case .changed:
            session?.scaleDelta = recognizer.scale
            scheduleChanged()
        case .ended:
            endGesture(recognizer, cancelled: false)
        case .cancelled, .failed:
            endGesture(recognizer, cancelled: true)
        default:
            break
        }
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard selectedBox != nil else { return }
        switch recognizer.state {
        case .began:
            beginIfNeeded(recognizer)
        case .changed:
            // UIRotationGestureRecognizer.rotation is positive counter-clockwise.
            // Stored rotation follows the render (Matrix2D) convention where
            // positive rotates clockwise on screen, so negate to keep the box
            // turning the same way the fingers turn.
            session?.rotationDelta = -recognizer.rotation
            scheduleChanged()
        case .ended:
            endGesture(recognizer, cancelled: false)
        case .cancelled, .failed:
            endGesture(recognizer, cancelled: true)
        default:
            break
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !borderLayer.isHidden else { return nil }
        let scale = pointsPerCanvasUnit
        let margin: CGFloat = 22

        if selectedBox != nil {
            // Confirmed product decision: while a text box is selected, the WHOLE
            // preview surface controls it — pan/pinch/rotate (and tap/double-tap
            // routed via callbacks) begin anywhere inside the preview bounds.
            return bounds.contains(point) ? self : nil
        }

        if let sticker = selectedSticker {
            let center = normalizedToView(sticker.centerX, sticker.centerY)
            let w = max(sticker.contentCanvasSize.width, 1) * scale
            let h = max(sticker.contentCanvasSize.height, 1) * scale
            let rect = CGRect(
                x: center.x - w / 2 - margin,
                y: center.y - h / 2 - margin,
                width: w + margin * 2,
                height: h + margin * 2
            )
            if rect.contains(point) { return self }
            return nil
        }

        return nil
    }
}

// MARK: - Simultaneous pinch + rotation

extension OverlayPositionDragView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Allow pinch and rotation to run together (single combined session).
        let pinchOrRotate: (UIGestureRecognizer) -> Bool = {
            $0 is UIPinchGestureRecognizer || $0 is UIRotationGestureRecognizer
        }
        return pinchOrRotate(gestureRecognizer) && pinchOrRotate(other)
    }
}
