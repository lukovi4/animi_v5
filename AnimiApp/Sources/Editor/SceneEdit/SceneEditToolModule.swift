import UIKit
import PhotosUI
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "SceneEditToolModule")

// MARK: - Delegate

@MainActor protocol SceneEditToolModuleDelegate: AnyObject, PHPickerViewControllerDelegate {
    func sceneEditModuleNeedsRedraw()
    func sceneEditModule(_ module: SceneEditToolModule, presentAlert: UIAlertController)
    func sceneEditModule(_ module: SceneEditToolModule, presentPHPicker: PHPickerViewController)
    func sceneEditModuleRequestBackgroundEditor()
    var sceneEditLayoutContainer: EditorLayoutContainerView { get }
    var sceneEditPopoverSourceView: UIView { get }
}

// MARK: - Module

@MainActor final class SceneEditToolModule {

    // MARK: - Dependencies

    private weak var runtime: SceneEditToolRuntimeControlling?
    private let session: EditorSession
    weak var delegate: SceneEditToolModuleDelegate?

    // MARK: - Owned Workers

    private(set) var interactionController: SceneEditInteractionController?
    private(set) var videoTrimCoordinator: InlineVideoTrimCoordinator

    // MARK: - Weak View Refs

    private weak var overlayView: EditorOverlayView?
    private weak var ingestStatusOverlayView: MediaIngestStatusOverlayView?

    // MARK: - Ingest Integration (closure DI — mediaIngestCoordinator stays on VC)

    /// Raw ingest status source — module filters by its own sceneEditTargetInstanceId.
    var getRawIngestStatus: (() -> [IngestSlotKey: IngestSlotStatus])?
    /// Cancel ingest for a single slot (e.g. on Remove).
    var cancelIngestForSlot: ((IngestSlotKey) -> Void)?
    /// Cancel all ingests for a scene (e.g. on Reset Scene).
    var cancelAllIngestsForScene: ((UUID) -> Void)?

    // MARK: - Ingest Failure Dedup

    private var ingestFailureAlertedKeys: Set<IngestSlotKey> = []

    // MARK: - Pending Picker Request

    private var pendingPickerRequest: IngestSlotKey?

    // MARK: - Init

    init(
        runtime: SceneEditToolRuntimeControlling,
        session: EditorSession,
        overlayView: EditorOverlayView,
        ingestStatusOverlayView: MediaIngestStatusOverlayView
    ) {
        self.runtime = runtime
        self.session = session
        self.overlayView = overlayView
        self.ingestStatusOverlayView = ingestStatusOverlayView
        self.videoTrimCoordinator = InlineVideoTrimCoordinator()

        // Wire coordinator closures after all stored properties are initialized
        videoTrimCoordinator.getRuntime = { [weak self] in self?.runtime }
        videoTrimCoordinator.getSession = { [weak self] in self?.session }
        videoTrimCoordinator.getSceneEditTargetInstanceId = { [weak self] in self?.sceneEditTargetInstanceId }
        videoTrimCoordinator.getEditorLayoutContainer = { [weak self] in self?.delegate?.sceneEditLayoutContainer }
        videoTrimCoordinator.onSyncPausedVideoStill = { [weak self] force in self?.syncPausedVideoStill(force: force) }
        videoTrimCoordinator.onUpdateSceneEditBottomBar = { [weak self] blockId in
            self?.delegate?.sceneEditLayoutContainer.updateSceneEditBottomBar(selectedBlockId: blockId)
        }
        videoTrimCoordinator.onUpdateMediaBlockActionBar = { [weak self] in self?.updateMediaBlockActionBarForSelectedBlock() }
        videoTrimCoordinator.onPresentAlert = { [weak self] alert in
            guard let self else { return }
            self.delegate?.sceneEditModule(self, presentAlert: alert)
        }
    }

    // MARK: - Static: Write Target Resolution

    /// Write-target resolution: in scene-edit returns uiMode target;
    /// otherwise returns runtime activeSceneInstanceId.
    /// Production code and tests share this single implementation.
    static func resolveWriteTargetForSceneEdit(
        uiMode: EditorUIMode,
        activeSceneInstanceId: UUID?
    ) -> UUID? {
        if case .sceneEdit(let id) = uiMode {
            return id
        }
        return activeSceneInstanceId
    }

    // MARK: - Computed Properties

    /// Write-target for scene-edit persistence: delegates to the static resolver.
    var sceneEditTargetInstanceId: UUID? {
        guard let uiMode = session.state?.uiMode else { return nil }
        return Self.resolveWriteTargetForSceneEdit(
            uiMode: uiMode,
            activeSceneInstanceId: runtime?.currentActiveSceneInstanceId
        )
    }

    private func assertSceneEditTargetMatchesRuntimeIfPossible() {
        #if DEBUG
        guard runtime?.currentSceneEditReadyInstanceId != nil else { return }
        guard let target = sceneEditTargetInstanceId,
              let runtimeId = runtime?.currentActiveSceneInstanceId,
              target != runtimeId else { return }
        logger.debug("[BUG-GUARD] sceneEditTargetInstanceId (\(target)) != activeSceneInstanceId (\(runtimeId))")
        assertionFailure("[BUG-GUARD] Scene edit target diverged from runtime active scene")
        #endif
    }

    // MARK: - Setup

    /// Assembles the SceneEditInteractionController with all closure bindings.
    func setupInteractionController(loadResult: EditorRuntime.InitialSceneLoadResult) {
        let ctrl = SceneEditInteractionController()
        ctrl.overlayView = overlayView
        ctrl.getOverlayProvider = { [weak self] in self?.runtime?.sceneEditOverlayProvider() }
        ctrl.getUIMode = { [weak self] in self?.session.state?.uiMode ?? .timeline }
        ctrl.getSelectedBlockId = { [weak self] in self?.session.state?.selectedBlockId }

        ctrl.onSelectBlock = { [weak self] blockId in
            self?.session.dispatch(.selectBlock(blockId: blockId))
        }

        ctrl.getBaselinePlacement = { [weak self] blockId in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId,
                  let slot = self.session.state?.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId] else {
                return .defaultCover
            }
            return slot.asset.placement
        }

        ctrl.onPlacementChanged = { [weak self] blockId, placement, phase in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId else { return }

            self.runtime?.applyMediaPlacementChange(instanceId: instanceId, blockId: blockId, placement: placement)

            self.session.dispatch(.setMediaPlacement(
                sceneInstanceId: instanceId,
                blockId: blockId,
                placement: placement,
                phase: phase
            ))

            if phase == .cancelled {
                let restored = self.session.state?.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.asset.placement ?? .defaultCover
                self.runtime?.applyMediaPlacementChange(instanceId: instanceId, blockId: blockId, placement: restored)
            }
        }

        ctrl.ingestStatusOverlayView = ingestStatusOverlayView
        ctrl.showsIngestStatusOverlay = true
        ctrl.getIngestStatusesByBlockId = { [weak self] in
            self?.currentIngestStatusesByBlockId() ?? [:]
        }

        self.interactionController = ctrl
    }

    // MARK: - Layout Callbacks

    /// Wires scene-edit layout callbacks on the container.
    func wireLayoutCallbacks(container: EditorLayoutContainerView) {
        container.onBackground = { [weak self] in
            self?.delegate?.sceneEditModuleRequestBackgroundEditor()
        }

        container.onResetScene = { [weak self] in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId else { return }

            let sceneState = self.session.state?.draft.sceneInstanceStates[instanceId]
            guard sceneState != nil && sceneState != .empty else { return }

            let alert = UIAlertController(
                title: "Reset Scene",
                message: "This will reset all changes to this scene. This action can be undone.",
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
                self?.performResetScene(instanceId: instanceId)
            })

            self.delegate?.sceneEditModule(self, presentAlert: alert)
        }

        container.onAddPhoto = { [weak self] blockId in
            self?.presentMediaPicker(for: blockId, kind: .photo)
        }

        container.onAddVideo = { [weak self] blockId in
            self?.presentMediaPicker(for: blockId, kind: .video)
        }

        container.onTrimVideo = { [weak self] blockId in
            self?.videoTrimCoordinator.enterVideoTrim(for: blockId)
        }

        container.onVideoVolume = { [weak self] blockId in
            self?.presentVideoVolumeSlider(blockId: blockId)
        }

        container.onTrimCancel = { [weak self] in
            self?.videoTrimCoordinator.cancelVideoTrim()
        }

        container.onTrimDone = { [weak self] in
            self?.videoTrimCoordinator.commitVideoTrim()
        }

        container.videoTrimBar.onTrimStartChanged = { [weak self] fraction in
            self?.videoTrimCoordinator.handleTrimStartDrag(fraction)
        }
        container.videoTrimBar.onTrimEndChanged = { [weak self] fraction in
            self?.videoTrimCoordinator.handleTrimEndDrag(fraction)
        }
        container.videoTrimBar.onCursorChanged = { [weak self] fraction in
            self?.videoTrimCoordinator.handleTrimCursorDrag(fraction)
        }
        container.videoTrimBar.onDragEnded = { [weak self] in
            self?.videoTrimCoordinator.handleTrimDragEnded()
        }

        container.onAnimation = { [weak self] blockId in
            self?.presentVariantPicker(blockId: blockId)
        }

        container.onToggleEnabled = { [weak self] blockId in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId else { return }
            let currentPresent = self.session.state?.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.visibility ?? true
            self.session.dispatch(.setBlockMediaPresent(
                sceneInstanceId: instanceId,
                blockId: blockId,
                present: !currentPresent
            ))
            self.runtime?.applyMediaVisibilityChange(instanceId: instanceId, blockId: blockId, visible: !currentPresent)
            self.updateMediaBlockActionBarForSelectedBlock()
        }

        container.onRemove = { [weak self] blockId in
            self?.performRemoveMedia(blockId: blockId)
        }

        container.onResetTransform = { [weak self] blockId in
            guard let self = self, let instanceId = self.sceneEditTargetInstanceId else { return }
            self.session.dispatch(.resetMediaPlacement(sceneInstanceId: instanceId, blockId: blockId))
            self.updateMediaBlockActionBarForSelectedBlock()
        }
    }

    // MARK: - Video Volume

    private func presentVideoVolumeSlider(blockId: String) {
        guard let instanceId = sceneEditTargetInstanceId,
              let slot = session.state?.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId],
              slot.mediaRef.mediaKind == .video,
              let videoWindow = slot.videoWindow else { return }

        let alert = UIAlertController(
            title: "Video Volume",
            message: "\n\n",
            preferredStyle: .alert
        )

        let slider = UISlider()
        slider.minimumValue = 0.0
        slider.maximumValue = 1.0
        slider.value = videoWindow.isMuted ? 0.0 : videoWindow.volume
        slider.translatesAutoresizingMaskIntoConstraints = false

        alert.view.addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: alert.view.trailingAnchor, constant: -20),
            slider.topAnchor.constraint(equalTo: alert.view.topAnchor, constant: 60),
        ])

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self] _ in
            guard let self else { return }
            let updated = videoWindow.applyingSliderValue(slider.value)

            try? self.runtime?.applyPersistedVideoSelection(blockId: blockId, updated)

            self.session.dispatch(.setVideoSelection(
                sceneInstanceId: instanceId,
                blockId: blockId,
                selection: updated
            ))
        })

        delegate?.sceneEditModule(self, presentAlert: alert)
    }

    // MARK: - Destructive Flow Helpers

    /// Executes the reset-scene destructive path.
    /// Order: cancel ingests → dispatch reset → reload runtime → refresh bars.
    func performResetScene(instanceId: UUID) {
        cancelAllIngestsForScene?(instanceId)
        session.dispatch(.resetSceneState(sceneInstanceId: instanceId))
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reloadRuntimeState(for: instanceId)
            self.refreshSceneEditBars()
        }
    }

    /// Executes the remove-media destructive path.
    /// Order: cancel slot ingest → clear runtime → dispatch nil slot → unregister asset → redraw.
    func performRemoveMedia(blockId: String) {
        guard let instanceId = sceneEditTargetInstanceId else { return }
        cancelIngestForSlot?(IngestSlotKey(sceneInstanceId: instanceId, blockId: blockId))
        let oldAssetId = session.state?.draft
            .sceneInstanceStates[instanceId]?
            .mediaSlotsByBlockId?[blockId]?.mediaRef.assetId
        runtime?.clearMediaSlot(blockId: blockId)
        session.dispatch(.setMediaSlot(
            sceneInstanceId: instanceId,
            blockId: blockId,
            slot: nil
        ))
        if let oldAssetId {
            session.unregisterAssetIfUnreferenced(oldAssetId)
        }
        delegate?.sceneEditModuleNeedsRedraw()
        updateMediaBlockActionBarForSelectedBlock()
    }

    // MARK: - Store Callback Handlers

    /// Handles UI mode changes (timeline ↔ sceneEdit).
    func handleUIModeChanged(_ mode: EditorUIMode) {
        guard let container = delegate?.sceneEditLayoutContainer else { return }
        switch mode {
        case .timeline:
            runtime?.deactivateSceneEdit()
            container.setSceneEditMode(false, animated: true)
            container.navBar.setMode(.timeline)
            interactionController?.updateOverlay()

        case .sceneEdit(let sceneId):
            runtime?.stopPlayback()
            container.setSceneEditMode(true, animated: true)
            container.navBar.setMode(.sceneEdit)
            interactionController?.updateOverlay()

            refreshSceneEditBars()
            runtime?.activateSceneEditTarget(instanceId: sceneId)

            #if DEBUG
            logger.debug("[PR-D] Entered Scene Edit for scene: \(sceneId)")
            #endif
        }
    }

    /// Handles selected block changes in Scene Edit mode.
    func handleSelectedBlockChanged(_ blockId: String?) {
        delegate?.sceneEditLayoutContainer.updateSceneEditBottomBar(selectedBlockId: blockId)
        interactionController?.updateOverlay()
        refreshSceneEditBars()

        #if DEBUG
        logger.debug("[PR-D] Selected block changed: \(blockId ?? "nil")")
        #endif
    }

    /// Updates MediaBlockActionBar configuration for currently selected block.
    func updateMediaBlockActionBarForSelectedBlock() {
        guard let blockId = session.state?.selectedBlockId,
              let rt = runtime,
              let instanceId = sceneEditTargetInstanceId,
              let container = delegate?.sceneEditLayoutContainer else { return }

        let ctx = rt.mediaActionBarContext(blockId: blockId)
        let hasVariants = ctx.availableVariants.count > 1

        let sceneState = session.state?.draft.sceneInstanceStates[instanceId]
        let slot = sceneState?.mediaSlotsByBlockId?[blockId]
        var hasMedia = slot != nil
        let isEnabled = slot?.visibility ?? true

        var mediaKind = slot?.mediaRef.mediaKind
        var canTrimVideo = ctx.canTrimVideo

        if let instanceId = sceneEditTargetInstanceId,
           session.missingMediaSummary?.isBlockFailed(sceneInstanceId: instanceId, blockId: blockId) == true {
            hasMedia = false
            mediaKind = nil
            canTrimVideo = false
        }

        let ingestKey = IngestSlotKey(sceneInstanceId: instanceId, blockId: blockId)
        let rawStatuses = getRawIngestStatus?() ?? [:]
        let ingestStatus = rawStatuses[ingestKey] ?? .idle

        let isPlacementDefault = slot?.asset.placement.isNearDefault ?? true

        let canAdjustVideoAudio: Bool = {
            guard mediaKind == .video, hasMedia else { return false }
            return slot?.videoWindow != nil
        }()

        container.configureMediaBlockActionBar(
            blockId: blockId,
            allowedMedia: ctx.allowedMedia,
            hasVariants: hasVariants,
            hasMedia: hasMedia,
            isEnabled: isEnabled,
            mediaKind: mediaKind,
            canTrimVideo: canTrimVideo,
            canAdjustVideoAudio: canAdjustVideoAudio,
            ingestStatus: ingestStatus,
            showsIngestStatus: true,
            isPlacementDefault: isPlacementDefault
        )
    }

    /// Refreshes SceneEditBar and MediaBlockActionBar states.
    func refreshSceneEditBars() {
        guard let instanceId = sceneEditTargetInstanceId,
              let container = delegate?.sceneEditLayoutContainer else { return }

        let sceneState = session.state?.draft.sceneInstanceStates[instanceId]
        let canReset = sceneState != nil && sceneState != .empty
        container.configureSceneEditBar(canReset: canReset)

        if session.state?.selectedBlockId != nil {
            updateMediaBlockActionBarForSelectedBlock()
        }
    }

    // MARK: - Ingest Status

    /// Returns current ingest statuses keyed by blockId for the active scene-edit scene.
    func currentIngestStatusesByBlockId() -> [String: IngestSlotStatus] {
        guard let instanceId = sceneEditTargetInstanceId else { return [:] }
        let rawStatuses = getRawIngestStatus?() ?? [:]
        var result: [String: IngestSlotStatus] = [:]
        for (key, status) in rawStatuses where key.sceneInstanceId == instanceId {
            result[key.blockId] = status
        }
        return result
    }

    /// Handles ingest status changes: updates overlay, action bar, and shows failure alerts.
    func handleIngestStatusChanged(key: IngestSlotKey, status: IngestSlotStatus) {
        guard key.sceneInstanceId == sceneEditTargetInstanceId else { return }

        interactionController?.updateOverlay()

        if session.state?.selectedBlockId == key.blockId {
            updateMediaBlockActionBarForSelectedBlock()
        }

        switch status {
        case .processing, .idle:
            ingestFailureAlertedKeys.remove(key)

        case .failed(let reason):
            guard !ingestFailureAlertedKeys.contains(key) else { return }
            ingestFailureAlertedKeys.insert(key)
            let alert = UIAlertController(
                title: "Media Import Failed",
                message: reason,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            delegate?.sceneEditModule(self, presentAlert: alert)

        case .ready:
            break
        }
    }

    // MARK: - Video Selection

    /// Handles committed video selection change from store callback.
    func handleVideoSelectionChanged(instanceId: UUID, blockId: String, selection: PersistedVideoSelection) {
        runtime?.applyVideoSelectionToEngine(selection: selection, blockId: blockId, instanceId: instanceId)
        refreshSceneEditBars()
    }

    // MARK: - Runtime State Reload

    /// Reloads runtime state for a given scene instance.
    private func reloadRuntimeState(for instanceId: UUID) async {
        await runtime?.reloadSceneEditState(instanceId: instanceId)
        interactionController?.updateOverlay()
        delegate?.sceneEditModuleNeedsRedraw()
        syncPausedVideoStill(force: true)

        #if DEBUG
        logger.debug("[PR-F] Runtime state reloaded for instance: \(instanceId)")
        #endif
    }

    /// Syncs video frames to current playhead when paused.
    func syncPausedVideoStill(force: Bool) {
        guard !(runtime?.isPlaying ?? false) else { return }
        guard videoTrimCoordinator.videoTrimSession == nil else { return }
        let localFrame = runtime?.bestLocalFrame ?? 0
        runtime?.syncVideoStillFrames(sceneFrameIndex: localFrame)
    }

    // MARK: - Undo / Redo

    /// Handles state restoration after undo/redo.
    func handleStateRestoredFromUndoRedo(cancelIngests: @escaping () -> Void) {
        cancelIngests()

        let targetId = sceneEditTargetInstanceId
        let runtimeId = runtime?.currentActiveSceneInstanceId

        Task { @MainActor [weak self] in
            guard let self else { return }

            if let targetId = targetId {
                await self.reloadRuntimeState(for: targetId)
            } else if let runtimeId = runtimeId {
                await self.reloadRuntimeState(for: runtimeId)
            }
            self.refreshSceneEditBars()

            if let state = self.session.state {
                self.runtime?.syncEngineAfterUndoRedo(state: state)
            }
        }
    }

    // MARK: - Fast-Path Handlers

    func handleMediaPlacementChanged(instanceId: UUID, blockId: String, placement: MediaPlacementState) {
        let resolvedInstanceId = sceneEditTargetInstanceId ?? instanceId
        runtime?.applyMediaPlacementChange(instanceId: resolvedInstanceId, blockId: blockId, placement: placement)
    }

    func handleMediaVisibilityChanged(instanceId: UUID, blockId: String, visible: Bool) {
        let resolvedInstanceId = sceneEditTargetInstanceId ?? instanceId
        runtime?.applyMediaVisibilityChange(instanceId: resolvedInstanceId, blockId: blockId, visible: visible)
        refreshSceneEditBars()
    }

    func handleMediaSlotChanged(instanceId: UUID, blockId: String, slot: SceneMediaSlot?) {
        let resolvedInstanceId = sceneEditTargetInstanceId ?? instanceId
        runtime?.applyMediaSlotChange(instanceId: resolvedInstanceId, blockId: blockId, slot: slot)
        refreshSceneEditBars()
    }

    // MARK: - Scene Edit Activated (from RuntimeOutput)

    func handleSceneEditActivated() {
        refreshSceneEditBars()
        interactionController?.updateOverlay()
        delegate?.sceneEditModuleNeedsRedraw()
    }

    // MARK: - Gesture Forwards

    func handleTap(viewPoint: CGPoint) {
        interactionController?.handleTap(viewPoint: viewPoint)
    }

    func handlePan(_ recognizer: UIPanGestureRecognizer) {
        interactionController?.handlePan(recognizer)
    }

    func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        interactionController?.handlePinch(recognizer)
    }

    func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        interactionController?.handleRotation(recognizer)
    }

    // MARK: - Picker / Variant Orchestration

    /// Presents media picker for Scene Edit with deterministic blockId tracking.
    func presentMediaPicker(for blockId: String, kind: MediaKind) {
        assertSceneEditTargetMatchesRuntimeIfPossible()
        guard let instanceId = sceneEditTargetInstanceId else {
            logger.debug("[UserMedia] No scene edit target, cannot open picker")
            return
        }
        pendingPickerRequest = IngestSlotKey(sceneInstanceId: instanceId, blockId: blockId)

        var config = PHPickerConfiguration()
        config.filter = (kind == .photo) ? .images : .videos
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        delegate?.sceneEditModule(self, presentPHPicker: picker)
    }

    /// Returns and clears the stored pending picker request key.
    @discardableResult
    func consumePendingPickerRequest() -> IngestSlotKey? {
        let key = pendingPickerRequest
        pendingPickerRequest = nil
        return key
    }

    /// Presents variant picker as action sheet.
    func presentVariantPicker(blockId: String) {
        guard let rt = runtime else { return }

        let ctx = rt.mediaActionBarContext(blockId: blockId)
        let variants = ctx.availableVariants
        guard !variants.isEmpty else { return }

        let currentVariantId = ctx.selectedVariantId

        let alert = UIAlertController(title: "Animation", message: nil, preferredStyle: .actionSheet)

        for variant in variants {
            let action = UIAlertAction(title: variant.id, style: .default) { [weak self] _ in
                self?.applyVariant(blockId: blockId, variantId: variant.id)
            }
            if variant.id == currentVariantId {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController,
           let sourceView = delegate?.sceneEditPopoverSourceView {
            popover.sourceView = sourceView
            popover.sourceRect = CGRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        delegate?.sceneEditModule(self, presentAlert: alert)
    }

    /// Applies variant selection to runtime and persists to store.
    func applyVariant(blockId: String, variantId: String) {
        runtime?.setSelectedVariant(blockId: blockId, variantId: variantId)
        delegate?.sceneEditModuleNeedsRedraw()
        interactionController?.updateOverlay()

        assertSceneEditTargetMatchesRuntimeIfPossible()
        guard let instanceId = sceneEditTargetInstanceId else { return }
        session.dispatch(.setBlockVariant(
            sceneInstanceId: instanceId,
            blockId: blockId,
            variantId: variantId
        ))
    }
}
