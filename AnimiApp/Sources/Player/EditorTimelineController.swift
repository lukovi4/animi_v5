import UIKit
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorTimeline")

/// Owns timeline UI/events, selection, and overlay sync.
@MainActor
internal final class EditorTimelineController {
    unowned let viewController: EditorViewController

    init(viewController: EditorViewController) {
        self.viewController = viewController
    }

    private func log(_ message: String) {
        logger.info("\(message)")
    }

    // MARK: - Focus Animation Intent

    /// One-shot flag: when true, the next focus-driven playhead-centering update
    /// should animate the timeline scroll instead of jumping. Set only
    /// immediately before a user-initiated `.focusScene` to a different scene and
    /// consumed once in the store playhead callback.
    private var pendingFocusAnimation = false

    /// Returns the pending focus-animation intent and resets it to false.
    /// Called exactly once from the `onPlayheadChanged` callback.
    func consumePendingFocusAnimation() -> Bool {
        let animated = pendingFocusAnimation
        pendingFocusAnimation = false
        return animated
    }

    // MARK: - Timeline Event Handling

    func handleTimelineEvent(_ event: TimelineEvent) {
        let vc = viewController
        switch event {
        case .scrub(let compressedFrame, let phase):
            handleTimelineScrub(compressedFrame: compressedFrame, phase: phase)

        case .selection(let selection):
            handleTimelineSelectionChanged(selection)

        case .scroll:
            break

        case .trimScene(let sceneId, let newDurationUs, let edge, let phase):
            handleTrimScene(sceneId: sceneId, newDurationUs: newDurationUs, edge: edge, phase: phase)

        case .reorderScene(let sceneId, let toIndex, let phase):
            handleReorderScene(sceneId: sceneId, toIndex: toIndex, phase: phase)

        case .editBoundaryTransition(let fromId, let toId, let anchorRect):
            vc.presentationController_.presentTransitionPicker(fromSceneId: fromId, toSceneId: toId, anchorRect: anchorRect)

        case .focusScene(let sceneId):
            // A scene tap during preview must stop playback first, mirroring the
            // scrub/trim interaction guard, so the play/pause UI returns to the
            // stopped state before focus is applied.
            if vc.runtime?.isPlaying ?? false {
                vc.runtime?.stopPlayback()
            }
            // User-initiated focus to a *different* scene should animate the
            // timeline centering. Same-scene taps preserve the playhead (no move,
            // no animation). The flag is one-shot: set before dispatch and
            // guaranteed reset after, even if `onPlayheadChanged` does not fire.
            pendingFocusAnimation = (vc.session.state?.sceneIdAtPlayhead() != sceneId)
            defer { pendingFocusAnimation = false }
            vc.session.dispatch(.focusScene(sceneId: sceneId))

        case .moveOverlayItem(let itemId, let newStartUs, let phase):
            vc.session.dispatch(.moveItem(itemId: itemId, newStartUs: newStartUs, phase: phase))

        case .trimOverlayItem(let itemId, let newDurationUs, _, let phase):
            vc.session.dispatch(.trimItem(itemId: itemId, newDurationUs: newDurationUs, phase: phase))
        }
    }

    // MARK: - Trim Scene

    func handleTrimScene(sceneId: UUID, newDurationUs: TimeUs, edge: TrimEdge, phase: InteractionPhase) {
        let vc = viewController
        if phase == .began && (vc.runtime?.isPlaying ?? false) {
            vc.runtime?.stopPlayback()
        }
        vc.session.dispatch(.trimScene(sceneId: sceneId, phase: phase, newDurationUs: newDurationUs, edge: edge))
    }

    // MARK: - Reorder Scene

    func handleReorderScene(sceneId: UUID, toIndex: Int, phase: InteractionPhase) {
        let vc = viewController
        guard phase == .ended else { return }
        guard toIndex >= 0 else { return }

        guard let sceneItems = vc.session.state?.sceneItems else { return }
        guard let fromIndex = sceneItems.firstIndex(where: { $0.id == sceneId }) else {
            log("[PR3.2] handleReorderScene: scene not found")
            return
        }

        let count = sceneItems.count
        var destIndex = toIndex

        if toIndex > fromIndex {
            destIndex -= 1
        }

        destIndex = max(0, min(destIndex, count - 1))

        guard destIndex != fromIndex else { return }

        vc.session.dispatch(.reorderScene(sceneId: sceneId, toIndex: destIndex))
    }

    // MARK: - Scrub

    func handleTimelineScrub(compressedFrame: Int, phase: InteractionPhase) {
        let vc = viewController
        switch phase {
        case .began:
            vc.isScrubDragging = true
        case .ended, .cancelled:
            vc.isScrubDragging = false
            if vc.pendingScrubRender {
                vc.requestRender()
                vc.pendingScrubRender = false
            }
        case .changed:
            break
        }

        if vc.runtime?.isPlaying ?? false {
            vc.runtime?.stopPlayback()
        }

        vc.session.dispatch(.setPlayhead(compressedFrame: compressedFrame))
    }

    func handleTimelineSelectionChanged(_ selection: TimelineSelection) {
        let vc = viewController
        if vc.session.state?.uiMode == .timeline, case .scene = selection {
            return
        }
        vc.session.dispatch(.select(selection: selection))
    }

    // MARK: - Selection Changed

    func handleSelectionChanged(_ selection: TimelineSelection?) {
        let vc = viewController
        let sel = selection ?? .none
        let sceneCount = vc.session.state?.sceneItems.count ?? 1
        vc.editorLayoutContainer.setTimelineSelection(sel, sceneCount: sceneCount)
        updateOverlayPositionDrag(selection: sel)
    }

    func updateOverlayPositionDrag(selection: TimelineSelection) {
        let vc = viewController
        guard vc.session.state?.uiMode == .timeline else {
            vc.overlayPositionDrag.clearSelection()
            vc.overlayPositionDrag.isHidden = true
            return
        }

        let canvasSize = vc.runtime?.queryCanvasSize ?? SizeD(width: 0, height: 0)

        switch selection {
        case .text(let itemId):
            if let payload = vc.session.state?.canonicalTimeline.textPayload(for: itemId),
               canvasSize.width > 0 {
                vc.overlayPositionDrag.isHidden = false
                vc.overlayPositionDrag.setSelectedBox(
                    EditorTimelineController.makeSelectedBox(
                        itemId: itemId, payload: payload, canvasSize: canvasSize
                    )
                )
            } else {
                vc.overlayPositionDrag.clearSelection()
                vc.overlayPositionDrag.isHidden = true
            }
        case .sticker(let itemId):
            if let payload = vc.session.state?.canonicalTimeline.stickerPayload(for: itemId),
               canvasSize.width > 0 {
                vc.overlayPositionDrag.isHidden = false
                // Sticker border approximates the 15%-canvas-width contract.
                let side = canvasSize.width * 0.15
                vc.overlayPositionDrag.setSelectedSticker(
                    OverlayPositionDragView.SelectedSticker(
                        itemId: itemId,
                        centerX: payload.centerX,
                        centerY: payload.centerY,
                        contentCanvasSize: CGSize(width: side, height: side)
                    )
                )
            } else {
                vc.overlayPositionDrag.clearSelection()
                vc.overlayPositionDrag.isHidden = true
            }
        default:
            vc.overlayPositionDrag.clearSelection()
            vc.overlayPositionDrag.isHidden = true
        }
    }

    /// Builds a `SelectedBox` from the persisted text payload, computing the
    /// unrotated content size via the shared layout in canvas units (1px = 1
    /// canvas unit so the layout result is already canvas-unit sized).
    static func makeSelectedBox(
        itemId: UUID,
        payload: TextPayload,
        canvasSize: SizeD
    ) -> OverlayPositionDragView.SelectedBox {
        let pixelWidth = max(1, Int(canvasSize.width.rounded()))
        let input = TextOverlayLayout.Input(
            text: payload.geometry.text,
            fontFamily: payload.style.fontFamily,
            fontSize: payload.style.fontSize,
            colorHex: payload.style.colorHex,
            boxWidth: payload.geometry.boxWidth
        )
        let layout = TextOverlayLayout.layout(
            input: input, canvasSize: canvasSize, canvasPixelWidth: pixelWidth
        )
        let contentSize = TextOverlayLayout.contentCanvasSize(
            pixelWidth: layout.pixelWidth,
            pixelHeight: layout.pixelHeight,
            canvasSize: canvasSize,
            canvasPixelWidth: pixelWidth
        ) ?? CGSize(width: canvasSize.width * payload.geometry.boxWidth, height: 40)
        return OverlayPositionDragView.SelectedBox(
            itemId: itemId,
            centerX: payload.geometry.centerX,
            centerY: payload.geometry.centerY,
            boxWidth: payload.geometry.boxWidth,
            fontSize: payload.style.fontSize,
            rotation: payload.geometry.rotation,
            contentCanvasSize: contentSize,
            text: payload.geometry.text,
            fontFamily: payload.style.fontFamily,
            colorHex: payload.style.colorHex
        )
    }

    // MARK: - Overlay Track

    func updateOverlayTrack(state: EditorState) {
        let vc = viewController
        let (textItems, stickerItems) = EditorViewController.extractOverlayLaneItems(from: state.canonicalTimeline)

        let selectedTextId: UUID? = if case .text(let id) = state.selection { id } else { nil }
        let selectedStickerId: UUID? = if case .sticker(let id) = state.selection { id } else { nil }

        vc.editorLayoutContainer.timelineView.setTextOverlayItems(textItems, selectedItemId: selectedTextId)
        vc.editorLayoutContainer.timelineView.setStickerOverlayItems(stickerItems, selectedItemId: selectedStickerId)
    }

    // MARK: - Supplemental UI Sync

    func syncTimelineSupplementalUI(state: EditorState) {
        let vc = viewController
        vc.editorLayoutContainer.timelineView.setMusicItem(
            state.canonicalTimeline.musicItem,
            payload: state.canonicalTimeline.musicPayload()
        )
        updateOverlayTrack(state: state)
        vc.editorLayoutContainer.setMapper(state.makePlayheadMapper())
        handleSelectionChanged(state.selection)
    }

    // MARK: - Timeline Changed

    func handleTimelineChanged(_ state: EditorState) {
        let vc = viewController
        let scenes = state.canonicalTimeline.toSceneDrafts()
        let boundaries = state.canonicalTimeline.toSceneBoundaryDrafts()
        vc.editorLayoutContainer.updateScenes(scenes, boundaries: boundaries)

        syncTimelineSupplementalUI(state: state)

        vc.runtime?.syncCoordinatorTimeline(from: state)

        vc.sceneEditModule?.refreshSceneEditBars()

        vc.runtime?.refreshCurrentTimelineFrame()

        vc.runtime?.markPreviewAudioDirty()
    }

    func handleTimelinePreviewChanged(_ state: EditorState) {
        let vc = viewController
        let scenes = state.canonicalTimeline.toSceneDrafts()
        let boundaries = state.canonicalTimeline.toSceneBoundaryDrafts()
        vc.editorLayoutContainer.updateScenes(scenes, boundaries: boundaries)

        let mapper = state.makePlayheadMapper()
        vc.editorLayoutContainer.setMapper(mapper)
    }

    // MARK: - Undo/Redo

    func handleUndoRedoChanged(canUndo: Bool, canRedo: Bool) {
        let vc = viewController
        vc.editorLayoutContainer.navBar.setUndoEnabled(canUndo)
        vc.editorLayoutContainer.navBar.setRedoEnabled(canRedo)

        #if DEBUG
        log("[PR-F] Undo/Redo changed: canUndo=\(canUndo), canRedo=\(canRedo)")
        #endif
    }

    // MARK: - Scene State Changed

    func handleSceneStateChanged(instanceId: UUID, sceneState: SceneState) {
        let vc = viewController
        vc.runtime?.applySceneStateChange(instanceId: instanceId, sceneState: sceneState)

        #if DEBUG
        logger.debug("[PR-F] Scene state changed: instanceId=\(instanceId)")
        #endif
    }
}
