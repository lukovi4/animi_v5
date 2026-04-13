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
/// Manages coordinate mapping and communicates with overlay provider for overlays and transforms.
@MainActor
final class SceneEditInteractionController {

    // MARK: - Dependencies (injected)

    /// Coordinate mapper for canvas ↔ view transforms.
    var mapper: EditorCanvasMapper = EditorCanvasMapper()

    /// Overlay view for displaying block outlines.
    weak var overlayView: EditorOverlayView?

    /// Overlay view for displaying ingest status indicators.
    weak var ingestStatusOverlayView: MediaIngestStatusOverlayView?

    /// Closure to get current ingest statuses by block ID.
    var getIngestStatusesByBlockId: (() -> [String: IngestSlotStatus])?

    /// Whether to show ingest status in the overlay.
    var showsIngestStatusOverlay: Bool = true

    /// Closure to get sealed overlay/hit-test provider.
    var getOverlayProvider: (() -> SceneEditOverlayProviding?)?

    /// Closure to get current UI mode from EditorStore.
    var getUIMode: (() -> EditorUIMode)?

    /// Closure to get selected block ID from EditorStore.
    var getSelectedBlockId: (() -> String?)?

    // MARK: - Callbacks

    /// Called when a block is tapped (selected/deselected).
    var onSelectBlock: ((String?) -> Void)?

    /// Called when placement changes during gesture.
    /// Parameters: blockId, new placement, phase.
    var onPlacementChanged: ((String, MediaPlacementState, InteractionPhase) -> Void)?

    /// Reads baseline placement from store for the given block ID.
    var getBaselinePlacement: ((String) -> MediaPlacementState)?

    // MARK: - Gesture State

    /// Active gesture session (shared across simultaneous gestures).
    private var gestureSession: PlacementGestureSession?

    /// Tracks which gesture types are in-flight to prevent premature session teardown.
    private var activeGestureTypes: Set<TransformType> = []

    /// Whether any recognizer cancelled during the current session.
    private var sessionHadCancellation: Bool = false

    // MARK: - Hit Test & Selection

    /// Handles tap gesture to select/deselect blocks.
    /// - Parameter viewPoint: Tap location in view coordinates.
    func handleTap(viewPoint: CGPoint) {
        guard case .sceneEdit = getUIMode?() else { return }
        guard let player = getOverlayProvider?() else { return }

        let canvasPoint = mapper.viewToCanvas(viewPoint)
        let hit = player.hitTest(
            point: Vec2D(x: Double(canvasPoint.x), y: Double(canvasPoint.y)),
            frame: SceneRenderPlan.editFrameIndex,
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
            ingestStatusOverlayView?.update(overlays: [], statusesByBlockId: [:], showsStatus: false)
            return
        }
        guard let player = getOverlayProvider?() else {
            overlayView?.update(overlays: [], selectedBlockId: nil)
            ingestStatusOverlayView?.update(overlays: [], statusesByBlockId: [:], showsStatus: false)
            return
        }

        let overlays = player.overlays(frame: SceneRenderPlan.editFrameIndex, mode: .edit)
        let canvasToView = mapper.canvasToViewTransform()
        overlayView?.canvasToView = canvasToView
        overlayView?.update(overlays: overlays, selectedBlockId: getSelectedBlockId?())

        // Update ingest status overlay
        ingestStatusOverlayView?.canvasToView = canvasToView
        let statuses = getIngestStatusesByBlockId?() ?? [:]
        ingestStatusOverlayView?.update(
            overlays: overlays,
            statusesByBlockId: statuses,
            showsStatus: showsIngestStatusOverlay
        )
    }

    // MARK: - Pan Gesture

    /// Handles pan gesture for block translation.
    func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard case .sceneEdit = getUIMode?(),
              let blockId = getSelectedBlockId?() else { return }

        // Check if pan transforms are allowed for this block
        guard isTransformAllowed(blockId: blockId, type: .pan) else { return }

        let translation = recognizer.translation(in: recognizer.view)

        switch recognizer.state {
        case .began:
            beginGesture(type: .pan, blockId: blockId)

        case .changed:
            guard var session = gestureSession else { return }
            let canvasDelta = mapper.viewDeltaToCanvas(translation)

            // Convert canvas delta to binding-local delta via inverse edit binding matrix
            let bindingLocalDelta: (x: Double, y: Double)
            if let player = getOverlayProvider?(),
               let bindingToCanvas = player.editBindingToCanvasMatrix(blockId: blockId),
               let inverseBTC = bindingToCanvas.inverse {
                // Transform delta vector (not point): apply inverse matrix to direction only
                let localDelta = inverseBTC.applyToVector(Vec2D(x: Double(canvasDelta.x), y: Double(canvasDelta.y)))
                bindingLocalDelta = (x: localDelta.x, y: localDelta.y)
            } else {
                // Fallback: use canvas delta directly (scale-only, no rotation)
                bindingLocalDelta = (x: Double(canvasDelta.x), y: Double(canvasDelta.y))
            }

            session.translationDelta = bindingLocalDelta
            gestureSession = session
            onPlacementChanged?(blockId, session.currentPlacement(), .changed)

        case .ended:
            endGesture(type: .pan, blockId: blockId, phase: .ended)

        case .cancelled, .failed:
            endGesture(type: .pan, blockId: blockId, phase: .cancelled)

        default:
            break
        }
    }

    // MARK: - Pinch Gesture

    /// Handles pinch gesture for block scaling.
    func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard case .sceneEdit = getUIMode?(),
              let blockId = getSelectedBlockId?() else { return }

        // Check if zoom transforms are allowed for this block
        guard isTransformAllowed(blockId: blockId, type: .pinch) else { return }

        switch recognizer.state {
        case .began:
            beginGesture(type: .pinch, blockId: blockId)

        case .changed:
            guard var session = gestureSession else { return }
            session.scaleDelta = Double(recognizer.scale)
            gestureSession = session
            onPlacementChanged?(blockId, session.currentPlacement(), .changed)

        case .ended:
            endGesture(type: .pinch, blockId: blockId, phase: .ended)
            recognizer.scale = 1.0

        case .cancelled, .failed:
            endGesture(type: .pinch, blockId: blockId, phase: .cancelled)
            recognizer.scale = 1.0

        default:
            break
        }
    }

    // MARK: - Rotation Gesture

    /// Handles rotation gesture for block rotation.
    func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard case .sceneEdit = getUIMode?(),
              let blockId = getSelectedBlockId?() else { return }

        // Check if rotation transforms are allowed for this block
        guard isTransformAllowed(blockId: blockId, type: .rotate) else { return }

        switch recognizer.state {
        case .began:
            beginGesture(type: .rotate, blockId: blockId)

        case .changed:
            guard var session = gestureSession else { return }
            session.rotationDelta = Double(recognizer.rotation)
            gestureSession = session
            onPlacementChanged?(blockId, session.currentPlacement(), .changed)

        case .ended:
            endGesture(type: .rotate, blockId: blockId, phase: .ended)
            recognizer.rotation = 0

        case .cancelled, .failed:
            endGesture(type: .rotate, blockId: blockId, phase: .cancelled)
            recognizer.rotation = 0

        default:
            break
        }
    }

    // MARK: - Gesture Session Management

    private func beginGesture(type: TransformType, blockId: String) {
        let isFirstGesture = activeGestureTypes.isEmpty
        activeGestureTypes.insert(type)
        if gestureSession == nil {
            let baseline = getBaselinePlacement?(blockId) ?? .defaultCover
            gestureSession = PlacementGestureSession(blockId: blockId, baseline: baseline)
        }
        // Emit .began exactly once — when the first recognizer starts the session
        if isFirstGesture, let session = gestureSession {
            onPlacementChanged?(blockId, session.baseline, .began)
        }
    }

    private func endGesture(type: TransformType, blockId: String, phase: InteractionPhase) {
        activeGestureTypes.remove(type)
        guard let session = gestureSession else { return }

        if phase == .cancelled {
            sessionHadCancellation = true
        }

        // Only emit terminal phase when the last active gesture ends.
        // While other gestures are still in-flight, just emit .changed to keep preview alive.
        guard activeGestureTypes.isEmpty else {
            onPlacementChanged?(blockId, session.currentPlacement(), .changed)
            return
        }

        // If any recognizer cancelled during this session, treat the whole session as cancelled.
        let terminalPhase: InteractionPhase = sessionHadCancellation ? .cancelled : phase
        let placement = terminalPhase == .cancelled ? session.baseline : session.currentPlacement()

        onPlacementChanged?(blockId, placement, terminalPhase)
        gestureSession = nil
        sessionHadCancellation = false
    }

    // MARK: - Transform Permission Check

    /// Checks if a transform type is allowed for the given block.
    /// - Note: `nil` from `userTransformsAllowed` means all transforms are allowed (backward compatible).
    private func isTransformAllowed(blockId: String, type: TransformType) -> Bool {
        guard let player = getOverlayProvider?(),
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
