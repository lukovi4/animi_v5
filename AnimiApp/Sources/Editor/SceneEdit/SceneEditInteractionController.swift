import UIKit
import TVECore

// MARK: - PR-D: Scene Edit Interaction Controller

// Note: InteractionPhase is defined in TimelineEvents.swift

/// Transform gesture type for permission checking.
enum TransformType {
    case pan
    case pinch
    case rotate
}

/// Controller for Scene Edit mode interactions: hit testing, selection, and gestures.
/// Manages coordinate mapping and communicates with ScenePlayer for overlays and transforms.
@MainActor
final class SceneEditInteractionController {

    // MARK: - Dependencies (injected)

    /// Coordinate mapper for canvas ↔ view transforms.
    var mapper: EditorCanvasMapper = EditorCanvasMapper()

    /// Overlay view for displaying block outlines.
    weak var overlayView: EditorOverlayView?

    /// Closure to get current ScenePlayer instance.
    var getScenePlayer: (() -> ScenePlayer?)?

    /// Closure to get current UI mode from EditorStore.
    var getUIMode: (() -> EditorUIMode)?

    /// Closure to get selected block ID from EditorStore.
    var getSelectedBlockId: (() -> String?)?

    // MARK: - Callbacks

    /// Called when a block is tapped (selected/deselected).
    var onSelectBlock: ((String?) -> Void)?

    /// Called when user transform changes during gesture.
    /// Parameters: blockId, new transform, phase.
    var onTransformChanged: ((String, Matrix2D, InteractionPhase) -> Void)?

    // MARK: - Gesture State

    /// Base transform at gesture start.
    private var gestureBaseTransform: Matrix2D = .identity

    /// Last applied transform during gesture.
    private var lastAppliedTransform: Matrix2D = .identity

    // MARK: - Hit Test & Selection

    /// Handles tap gesture to select/deselect blocks.
    /// - Parameter viewPoint: Tap location in view coordinates.
    func handleTap(viewPoint: CGPoint) {
        guard case .sceneEdit = getUIMode?() else { return }
        guard let player = getScenePlayer?() else { return }

        let canvasPoint = mapper.viewToCanvas(viewPoint)
        let hit = player.hitTest(
            point: Vec2D(x: Double(canvasPoint.x), y: Double(canvasPoint.y)),
            frame: ScenePlayer.editFrameIndex,
            mode: .edit
        )
        onSelectBlock?(hit)
    }

    // MARK: - Overlay Update

    /// Updates the overlay view with current block outlines.
    /// Called after selection changes or layout updates.
    func updateOverlay() {
        guard case .sceneEdit = getUIMode?() else {
            overlayView?.update(overlays: [], selectedBlockId: nil)
            return
        }
        guard let player = getScenePlayer?() else {
            overlayView?.update(overlays: [], selectedBlockId: nil)
            return
        }

        let overlays = player.overlays(frame: ScenePlayer.editFrameIndex, mode: .edit)
        let canvasToView = mapper.canvasToViewTransform()
        overlayView?.canvasToView = canvasToView
        overlayView?.update(overlays: overlays, selectedBlockId: getSelectedBlockId?())
    }

    // MARK: - Pan Gesture

    /// Handles pan gesture for block translation.
    func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard case .sceneEdit = getUIMode?(),
              let blockId = getSelectedBlockId?(),
              let player = getScenePlayer?() else { return }

        // Check if pan transforms are allowed for this block
        guard isTransformAllowed(blockId: blockId, type: .pan) else { return }

        let translation = recognizer.translation(in: recognizer.view)

        switch recognizer.state {
        case .began:
            gestureBaseTransform = player.userTransform(blockId: blockId)
            lastAppliedTransform = gestureBaseTransform

        case .changed:
            let canvasDelta = mapper.viewDeltaToCanvas(translation)
            let delta = Matrix2D.translation(x: Double(canvasDelta.x), y: Double(canvasDelta.y))
            let combined = gestureBaseTransform.concatenating(delta)
            lastAppliedTransform = combined
            onTransformChanged?(blockId, combined, .changed)

        case .ended:
            onTransformChanged?(blockId, lastAppliedTransform, .ended)

        case .cancelled:
            onTransformChanged?(blockId, gestureBaseTransform, .cancelled)

        default:
            break
        }
    }

    // MARK: - Pinch Gesture

    /// Handles pinch gesture for block scaling.
    func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard case .sceneEdit = getUIMode?(),
              let blockId = getSelectedBlockId?(),
              let player = getScenePlayer?() else { return }

        // Check if zoom transforms are allowed for this block
        guard isTransformAllowed(blockId: blockId, type: .pinch) else { return }

        switch recognizer.state {
        case .began:
            gestureBaseTransform = player.userTransform(blockId: blockId)
            lastAppliedTransform = gestureBaseTransform

        case .changed:
            let scale = Double(recognizer.scale)
            let scaleMatrix = Matrix2D.scale(x: scale, y: scale)
            let combined = gestureBaseTransform.concatenating(scaleMatrix)
            lastAppliedTransform = combined
            onTransformChanged?(blockId, combined, .changed)

        case .ended:
            onTransformChanged?(blockId, lastAppliedTransform, .ended)
            recognizer.scale = 1.0

        case .cancelled:
            onTransformChanged?(blockId, gestureBaseTransform, .cancelled)
            recognizer.scale = 1.0

        default:
            break
        }
    }

    // MARK: - Rotation Gesture

    /// Handles rotation gesture for block rotation.
    func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard case .sceneEdit = getUIMode?(),
              let blockId = getSelectedBlockId?(),
              let player = getScenePlayer?() else { return }

        // Check if rotation transforms are allowed for this block
        guard isTransformAllowed(blockId: blockId, type: .rotate) else { return }

        switch recognizer.state {
        case .began:
            gestureBaseTransform = player.userTransform(blockId: blockId)
            lastAppliedTransform = gestureBaseTransform

        case .changed:
            let angle = Double(recognizer.rotation)
            let rotationMatrix = Matrix2D.rotation(angle)
            let combined = gestureBaseTransform.concatenating(rotationMatrix)
            lastAppliedTransform = combined
            onTransformChanged?(blockId, combined, .changed)

        case .ended:
            onTransformChanged?(blockId, lastAppliedTransform, .ended)
            recognizer.rotation = 0

        case .cancelled:
            onTransformChanged?(blockId, gestureBaseTransform, .cancelled)
            recognizer.rotation = 0

        default:
            break
        }
    }

    // MARK: - Transform Permission Check

    /// Checks if a transform type is allowed for the given block.
    /// - Parameters:
    ///   - blockId: Block to check.
    ///   - type: Transform type (pan, pinch, rotate).
    /// - Returns: `true` if transform is allowed, `false` otherwise.
    ///
    /// - Note: `nil` from `userTransformsAllowed` means all transforms are allowed (backward compatible).
    private func isTransformAllowed(blockId: String, type: TransformType) -> Bool {
        guard let player = getScenePlayer?(),
              let allowed = player.userTransformsAllowed(blockId: blockId) else {
            return true // nil = all allowed
        }

        switch type {
        case .pan:
            return allowed.pan != false
        case .pinch:
            return allowed.zoom != false
        case .rotate:
            return allowed.rotate != false
        }
    }
}
