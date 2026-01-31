import UIKit
import TVECore

// MARK: - State

/// UI state machine for template editor (PR-19).
struct TemplateEditorState {
    var mode: TemplateMode = .preview
    var selectedBlockId: String?
    var currentPreviewFrame: Int = 0
    var isPlaying: Bool = false
}

// MARK: - Controller

/// Coordinates template editing: mode switching, selection, gestures, render loop.
///
/// Does NOT own views or renderer — receives them via `setPlayer` / `setOverlayView`.
/// VC remains the thin host: creates views, connects controller, forwards events.
///
/// PR-19 canonical contract:
/// - Edit mode: time frozen at `editFrameIndex`, hit-test + gestures active, overlay visible.
/// - Preview mode: scrubber + playback, overlay hidden, selection nil.
final class TemplateEditorController {

    // MARK: - State

    private(set) var state = TemplateEditorState()

    // MARK: - Dependencies (injected)

    private var player: ScenePlayer?
    private weak var overlayView: EditorOverlayView?

    /// Callback: controller requests a Metal redraw (VC calls `metalView.setNeedsDisplay()`).
    var onNeedsDisplay: (() -> Void)?

    /// Callback: controller requests UI update (frame label, slider, play/pause button).
    var onStateChanged: ((TemplateEditorState) -> Void)?

    // MARK: - Gesture state (canvas space)

    /// Snapshot of `player.userTransform` at gesture `.began`.
    /// Single source of truth — no separate accumulatedTransforms dict (lead review fix #7).
    private var gestureBaseTransform: Matrix2D = .identity

    /// Last transform applied during `.changed` — committed on `.ended` (lead review fix #2).
    /// Initialized to `gestureBaseTransform` on `.began` to be safe for instant gestures (fix #8).
    private var lastAppliedTransform: Matrix2D = .identity

    // MARK: - Canvas <-> View mapping

    /// Canvas dimensions (e.g. 1080x1920). Set by VC after compile.
    var canvasSize: SizeD = .zero

    /// MetalView bounds size in points. Set by VC in `viewDidLayoutSubviews`.
    var viewSize: CGSize = .zero

    // MARK: - Dependency Injection

    /// Connects a newly compiled ScenePlayer. Resets selection and gesture state.
    func setPlayer(_ player: ScenePlayer) {
        self.player = player
        state.selectedBlockId = nil
        gestureBaseTransform = .identity
        lastAppliedTransform = .identity
        // Don't change mode — preserve user's last choice
    }

    /// Connects the overlay view (weak reference).
    func setOverlayView(_ view: EditorOverlayView) {
        self.overlayView = view
    }

    // MARK: - Mode Switching

    /// Enters preview mode: selection cleared, overlay hidden, playback allowed.
    func enterPreview() {
        state.mode = .preview
        state.selectedBlockId = nil
        updateOverlay()
        requestDisplay()
        onStateChanged?(state)
    }

    /// Enters edit mode: playback stopped, overlay visible, gestures active.
    func enterEdit() {
        state.mode = .edit
        state.isPlaying = false
        updateOverlay()
        requestDisplay()
        onStateChanged?(state)
    }

    // MARK: - Render Commands

    /// Returns render commands for current state. Called by VC inside `MTKViewDelegate.draw`.
    func currentRenderCommands() -> [RenderCommand]? {
        guard let player = player else { return nil }
        switch state.mode {
        case .preview:
            return player.renderCommands(mode: .preview, sceneFrameIndex: state.currentPreviewFrame)
        case .edit:
            return player.renderCommands(mode: .edit)
        }
    }

    // MARK: - Playback (preview only)

    /// Advances frame by 1 (called from displayLink). No-op in edit mode.
    func advanceFrame(totalFrames: Int) {
        guard state.mode == .preview, state.isPlaying else { return }
        state.currentPreviewFrame = (state.currentPreviewFrame + 1) % totalFrames
        onStateChanged?(state)
        requestDisplay()
    }

    /// Scrubs to specific frame (called from slider). No-op in edit mode.
    func scrub(to frame: Int) {
        guard state.mode == .preview else { return }
        state.currentPreviewFrame = frame
        onStateChanged?(state)
        requestDisplay()
    }

    /// Sets playing state (VC manages the actual displayLink).
    func setPlaying(_ playing: Bool) {
        state.isPlaying = playing
        onStateChanged?(state)
    }

    // MARK: - Hit-Test & Selection (edit only)

    /// Handles tap in view coordinates. Converts to canvas, runs hit-test, updates selection.
    func handleTap(viewPoint: CGPoint) {
        guard state.mode == .edit, let player = player else { return }
        let canvasPoint = viewToCanvas(viewPoint)
        let hit = player.hitTest(
            point: Vec2D(x: Double(canvasPoint.x), y: Double(canvasPoint.y)),
            frame: ScenePlayer.editFrameIndex
        )
        state.selectedBlockId = hit
        updateOverlay()
        requestDisplay()
        onStateChanged?(state)
    }

    // MARK: - Gesture Handling (edit only)

    // Strategy (lead review fixes #2, #3, #7, #8, #9):
    // - .began: snapshot player.userTransform as gestureBaseTransform + lastAppliedTransform
    // - .changed: compute delta, apply base.concatenating(delta), store in lastAppliedTransform
    // - .ended: just commit lastAppliedTransform (no re-computation — avoids double-apply)
    // - Pinch/Rotation use pivot = gesture location in canvas: T(p) . S/R . T(-p)
    // - A.concatenating(B) = A * B = apply B first, then A

    /// Pan gesture — translates in canvas space (no pivot needed).
    func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard state.mode == .edit, let blockId = state.selectedBlockId,
              let player = player else { return }
        let translation = recognizer.translation(in: recognizer.view)

        switch recognizer.state {
        case .began:
            gestureBaseTransform = player.userTransform(blockId: blockId)
            lastAppliedTransform = gestureBaseTransform
        case .changed:
            let canvasDelta = viewDeltaToCanvas(translation)
            let delta = Matrix2D.translation(x: canvasDelta.x, y: canvasDelta.y)
            let combined = gestureBaseTransform.concatenating(delta)
            lastAppliedTransform = combined
            applyTransform(combined, for: blockId)
        case .ended, .cancelled:
            applyTransform(lastAppliedTransform, for: blockId)
        default: break
        }
    }

    /// Pinch gesture — scales around gesture location (pivot in canvas coords).
    func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard state.mode == .edit, let blockId = state.selectedBlockId,
              let player = player, let view = recognizer.view else { return }

        switch recognizer.state {
        case .began:
            gestureBaseTransform = player.userTransform(blockId: blockId)
            lastAppliedTransform = gestureBaseTransform
        case .changed:
            let pivot = viewToCanvas(recognizer.location(in: view))
            let s = Double(recognizer.scale)
            // T(pivot) . Scale(s) . T(-pivot)
            let delta = Matrix2D.translation(x: pivot.x, y: pivot.y)
                .concatenating(Matrix2D.scale(s))
                .concatenating(Matrix2D.translation(x: -pivot.x, y: -pivot.y))
            let combined = gestureBaseTransform.concatenating(delta)
            lastAppliedTransform = combined
            applyTransform(combined, for: blockId)
        case .ended, .cancelled:
            applyTransform(lastAppliedTransform, for: blockId)
            recognizer.scale = 1.0  // lead fix #9: reset UIKit state
        default: break
        }
    }

    /// Rotation gesture — rotates around gesture location (pivot in canvas coords).
    func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard state.mode == .edit, let blockId = state.selectedBlockId,
              let player = player, let view = recognizer.view else { return }

        switch recognizer.state {
        case .began:
            gestureBaseTransform = player.userTransform(blockId: blockId)
            lastAppliedTransform = gestureBaseTransform
        case .changed:
            let pivot = viewToCanvas(recognizer.location(in: view))
            let angle = Double(recognizer.rotation)
            // T(pivot) . Rotate(angle) . T(-pivot)
            let delta = Matrix2D.translation(x: pivot.x, y: pivot.y)
                .concatenating(Matrix2D.rotation(angle))
                .concatenating(Matrix2D.translation(x: -pivot.x, y: -pivot.y))
            let combined = gestureBaseTransform.concatenating(delta)
            lastAppliedTransform = combined
            applyTransform(combined, for: blockId)
        case .ended, .cancelled:
            applyTransform(lastAppliedTransform, for: blockId)
            recognizer.rotation = 0.0  // lead fix #9: reset UIKit state
        default: break
        }
    }

    private func applyTransform(_ transform: Matrix2D, for blockId: String) {
        player?.setUserTransform(blockId: blockId, transform: transform)
        requestDisplay()
    }

    // MARK: - Overlay

    /// Refreshes overlay if currently in edit mode. Called by VC after layout changes (fix #5).
    func refreshOverlayIfNeeded() {
        guard state.mode == .edit else { return }
        updateOverlay()
    }

    private func updateOverlay() {
        guard let overlayView = overlayView else { return }

        guard state.mode == .edit, let player = player else {
            overlayView.update(overlays: [], selectedBlockId: nil)
            return
        }

        let overlays = player.overlays(frame: ScenePlayer.editFrameIndex)
        overlayView.update(overlays: overlays, selectedBlockId: state.selectedBlockId)
    }

    // MARK: - Coordinate Helpers (aspect-fit, matches Metal renderer)

    /// Canvas-to-View affine transform. Uses the same contain (aspect-fit) formula
    /// as MetalRenderer: `GeometryMapping.animToInputContain` (lead fix #6).
    func canvasToViewTransform() -> CGAffineTransform {
        guard canvasSize.width > 0, canvasSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .identity }
        let targetRect = RectD(x: 0, y: 0,
                               width: Double(viewSize.width),
                               height: Double(viewSize.height))
        let m = GeometryMapping.animToInputContain(animSize: canvasSize, inputRect: targetRect)
        return CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty)
    }

    /// View point -> Canvas point (invert aspect-fit transform).
    private func viewToCanvas(_ viewPoint: CGPoint) -> CGPoint {
        let inverted = canvasToViewTransform().inverted()
        return viewPoint.applying(inverted)
    }

    /// View delta -> Canvas delta (scale only, no offset).
    /// `animToInputContain` produces uniform scale + translation only (no rotation/shear);
    /// delta conversion via inverse uniform scale is exact (lead fix #10).
    private func viewDeltaToCanvas(_ delta: CGPoint) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return delta }
        let containScale = min(
            Double(viewSize.width) / canvasSize.width,
            Double(viewSize.height) / canvasSize.height
        )
        guard containScale > 0 else { return delta }
        return CGPoint(x: Double(delta.x) / containScale,
                       y: Double(delta.y) / containScale)
    }

    private func requestDisplay() {
        onNeedsDisplay?()
    }
}
