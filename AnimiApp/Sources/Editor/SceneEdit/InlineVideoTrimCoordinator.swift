import UIKit

/// Owns inline video trim session state and orchestrates trim interactions.
/// Communicates with PlayerViewController via closure-based DI.
@MainActor
final class InlineVideoTrimCoordinator {

    // MARK: - State

    private(set) var videoTrimSession: VideoTrimSession?
    private var trimThumbnailProvider: VideoTrimThumbnailProvider?

    // MARK: - Dependencies (closure DI)

    /// Reads the current EditorRuntime (may be nil).
    var getRuntime: (() -> EditorRuntime?)?
    /// Reads the current EditorSession (may be nil if PVC deallocated).
    var getSession: (() -> EditorSession?)?
    /// Reads the scene instance ID being edited.
    var getSceneEditTargetInstanceId: (() -> UUID?)?
    /// Reads the editor layout container (may be nil if PVC deallocated).
    var getEditorLayoutContainer: (() -> EditorLayoutContainerView?)?

    // MARK: - UI Callbacks

    /// Called to sync a paused video still after cancel.
    var onSyncPausedVideoStill: ((_ force: Bool) -> Void)?
    /// Called to update scene edit bottom bar after exiting trim.
    var onUpdateSceneEditBottomBar: ((_ selectedBlockId: String?) -> Void)?
    /// Called to update media block action bar for selected block.
    var onUpdateMediaBlockActionBar: (() -> Void)?
    /// Called to present an alert.
    var onPresentAlert: ((UIAlertController) -> Void)?

    // MARK: - Enter Trim

    func enterVideoTrim(for blockId: String) {
        guard let instanceId = getSceneEditTargetInstanceId?(),
              let rt = getRuntime?(),
              let context = rt.videoTrimContext(blockId: blockId) else { return }

        let session = getSession?()

        // Verify slot is actually video
        guard let slot = session?.state?.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId],
              slot.mediaRef.mediaKind == .video else { return }

        // Stop playback if playing
        if rt.isPlaying {
            rt.stopPlayback()
        }

        // Compute current video time at paused playhead
        let localFrame = rt.bestLocalFrame
        let currentVideoTime = rt.currentVideoTime(blockId: blockId, sceneFrameIndex: localFrame)

        // Create trim session
        let trimSession = VideoTrimSession(
            instanceId: instanceId,
            blockId: blockId,
            actualDuration: context.actualDuration,
            selection: context.currentSelection,
            currentVideoTime: currentVideoTime
        )
        videoTrimSession = trimSession

        // Switch layout to trim mode
        let layout = getEditorLayoutContainer?()
        layout?.setVideoTrimMode(true)

        // Configure trim bar positions
        layout?.videoTrimBar.setPositions(
            start: trimSession.trimStartFraction,
            end: trimSession.trimEndFraction,
            cursor: trimSession.cursorFraction
        )

        // Generate filmstrip thumbnails
        let thumbnailProvider = VideoTrimThumbnailProvider(
            url: context.videoURL,
            duration: context.actualDuration
        )
        self.trimThumbnailProvider = thumbnailProvider

        let barWidth = layout?.videoTrimBar.bounds.width ?? 0
        let thumbHeight = VideoTrimBarView.filmstripHeight
        let thumbWidth = thumbHeight * 16.0 / 9.0
        let count = max(1, Int(ceil(barWidth / thumbWidth)))

        thumbnailProvider.generateThumbnails(
            count: count,
            size: CGSize(width: thumbWidth, height: thumbHeight)
        ) { [weak layout] results in
            layout?.videoTrimBar.setThumbnails(results.map(\.image))
        }

        // Preview initial frame at trimStart
        rt.previewExactVideoTrimFrame(
            blockId: blockId,
            draftSelection: trimSession.draftSelection,
            previewTime: trimSession.currentPreviewTime
        )
    }

    // MARK: - Handle Drags

    func handleTrimStartDrag(_ fraction: Double) {
        guard var session = videoTrimSession else { return }
        let newTrimStart = fraction * session.actualDuration
        session.draftSelection.trimStart = newTrimStart
        session.currentPreviewTime = newTrimStart
        videoTrimSession = session

        getRuntime?()?.updateInteractiveTrimPreview(
            blockId: session.blockId,
            draftSelection: session.draftSelection,
            previewTime: newTrimStart
        )
    }

    func handleTrimEndDrag(_ fraction: Double) {
        guard var session = videoTrimSession else { return }
        let newTrimEnd = fraction * session.actualDuration
        session.draftSelection.trimEnd = newTrimEnd
        session.currentPreviewTime = newTrimEnd
        videoTrimSession = session

        getRuntime?()?.updateInteractiveTrimPreview(
            blockId: session.blockId,
            draftSelection: session.draftSelection,
            previewTime: newTrimEnd
        )
    }

    func handleTrimCursorDrag(_ fraction: Double) {
        guard var session = videoTrimSession else { return }
        let previewTime = fraction * session.actualDuration
        session.currentPreviewTime = previewTime
        videoTrimSession = session

        getRuntime?()?.updateInteractiveTrimPreview(
            blockId: session.blockId,
            draftSelection: session.draftSelection,
            previewTime: previewTime
        )
    }

    func handleTrimDragEnded() {
        guard let session = videoTrimSession else { return }
        getRuntime?()?.endInteractiveTrimPreview(blockId: session.blockId)
        getRuntime?()?.previewExactVideoTrimFrame(
            blockId: session.blockId,
            draftSelection: session.draftSelection,
            previewTime: session.currentPreviewTime
        )
    }

    // MARK: - Commit / Cancel / Exit

    func commitVideoTrim() {
        guard let session = videoTrimSession else { return }
        let rt = getRuntime?()

        // End interactive preview before commit
        rt?.endInteractiveTrimPreview(blockId: session.blockId)

        if session.hasChanges {
            guard rt?.canCommitVideoTrim == true else {
                exitVideoTrim()
                return
            }

            // 1. Validate + apply to runtime
            do {
                try rt?.applyPersistedVideoSelection(blockId: session.blockId, session.draftSelection)
            } catch {
                let alert = UIAlertController(
                    title: "Invalid Selection",
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                onPresentAlert?(alert)
                return
            }

            // 2. Render exact still at new trimStart for poster/cover
            rt?.previewExactVideoTrimFrame(
                blockId: session.blockId,
                draftSelection: session.draftSelection,
                previewTime: session.draftSelection.trimStart
            )

            // 3. Dispatch to store
            getSession?()?.dispatch(.setVideoSelection(
                sceneInstanceId: session.instanceId,
                blockId: session.blockId,
                selection: session.draftSelection
            ))
        }

        exitVideoTrim()
    }

    func cancelVideoTrim() {
        guard let session = videoTrimSession else { return }
        let rt = getRuntime?()

        // End interactive preview
        rt?.endInteractiveTrimPreview(blockId: session.blockId)

        // Revert draft selection if handles were moved
        if session.hasChanges {
            try? rt?.applyPersistedVideoSelection(blockId: session.blockId, session.originalSelection)
        }

        // Clear before sync so the trim guard in syncPausedVideoStill does not block
        videoTrimSession = nil
        onSyncPausedVideoStill?(true)

        exitVideoTrim()
    }

    func exitVideoTrim() {
        // Safety-net: ensure interactive preview is cleaned up
        if let session = videoTrimSession {
            getRuntime?()?.endInteractiveTrimPreview(blockId: session.blockId)
        }
        trimThumbnailProvider?.cancel()
        trimThumbnailProvider = nil
        videoTrimSession = nil

        getEditorLayoutContainer?()?.setVideoTrimMode(false)

        // Restore scene edit bottom bar state
        let selectedBlockId = getSession?()?.state?.selectedBlockId
        onUpdateSceneEditBottomBar?(selectedBlockId)
        if selectedBlockId != nil {
            onUpdateMediaBlockActionBar?()
        }
    }
}
