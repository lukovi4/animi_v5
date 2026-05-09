import Foundation
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorRuntimeSceneEdit")

/// Owns scene-edit activation, media mutations, trim, overlay queries.
@MainActor
internal final class EditorRuntimeSceneEditController {
    unowned let runtime: EditorRuntime

    // MARK: - Stored Properties

    var activeSceneInstanceId: UUID?
    var sceneEditReadyInstanceId: UUID?
    var sceneEditActivationTask: Task<Void, Never>?

    init(runtime: EditorRuntime) {
        self.runtime = runtime
    }

    // MARK: - Activation

    func activateSceneEditTarget(instanceId: UUID) {
        sceneEditActivationTask?.cancel()
        sceneEditReadyInstanceId = nil

        sceneEditActivationTask = Task { @MainActor [weak self] in
            guard let self, let coordinator = self.runtime.playbackCoordinator else { return }

            guard let (_, localFrame) = await coordinator.activateSceneByInstanceId(instanceId) else {
                return
            }
            guard !Task.isCancelled else { return }

            self.activeSceneInstanceId = instanceId
            self.runtime.currentFrameIndex = localFrame
            self.resetRuntimeForSceneInstanceChange()
            await self.runtime.applySceneInstanceState(instanceId: instanceId)

            self.runtime.state = .sceneEdit(instanceId: instanceId)
            self.sceneEditReadyInstanceId = instanceId

            self.updateSceneEditRenderSource()
            self.runtime.onOutput?(.sceneEditActivated(instanceId: instanceId))

            if !self.runtime.isPlaying {
                self.runtime.userMediaService?.updateVideoStillFrames(sceneFrameIndex: localFrame, mediaFrameIndex: localFrame)
                self.runtime.lastStillSyncFrame = localFrame
            }
        }
    }

    func deactivateSceneEdit() {
        sceneEditActivationTask?.cancel()
        sceneEditReadyInstanceId = nil
        runtime.state = .timelinePreview
        runtime.onOutput?(.sceneEditDeactivated)
        runtime.refreshCurrentTimelineFrame()
    }

    // MARK: - Scene Instance State

    func resetRuntimeForSceneInstanceChange() {
        runtime.scenePlayer?.resetForNewInstance()
        runtime.userMediaService?.clearAll()
        runtime.lastStillSyncFrame = -1
    }

    func applySceneInstanceState(instanceId: UUID) async {
        guard let sceneState = runtime.session.state?.draft.sceneInstanceStates[instanceId],
              let player = runtime.scenePlayer,
              let service = runtime.userMediaService else {
            return
        }

        let registry = runtime.selfHealedRegistry()
        let resolved = await ResolvedMediaMapBuilder.build(
            slots: sceneState.mediaSlotsByBlockId,
            locator: runtime.session.mediaLocator,
            registry: registry
        )

        let deps = SceneRuntimeStateApplier.RestoreDependencies(
            scenePlayer: player,
            userMediaService: service,
            resolvedMedia: resolved
        )
        let _ = SceneRuntimeStateApplier.apply(sceneState, deps: deps)

        runtime.session.updateMissingMedia(for: instanceId, failures: service.currentRestoreFailedBlockIds)
    }

    // MARK: - Render Source

    func refreshSceneEditIfActive() {
        if case .sceneEdit = runtime.state {
            runtime.lastRefreshTrigger = .sceneEditMutation
            updateSceneEditRenderSource()
        } else {
            runtime.onOutput?(.renderSourceUpdated)
        }
    }

    func updateSceneEditRenderSource() {
        guard case .sceneEdit(let targetId) = runtime.state else { return }
        guard sceneEditReadyInstanceId == targetId else { return }

        let coordinator = runtime.playbackCoordinator
        let player = runtime.scenePlayer
        let frameIndex = runtime.currentFrameIndex

        guard let resolved = EditorRenderCommandResolver.resolve(
            uiMode: .sceneEdit(sceneInstanceId: targetId),
            coordinatorLocalFrame: coordinator?.currentLocalFrame,
            currentFrameIndex: frameIndex,
            coordinatorCommands: { mode in
                coordinator?.currentRenderCommands(mode: mode)
            },
            scenePlayerCommands: { mode, frame in
                player?.renderCommands(mode: mode, sceneFrameIndex: frame)
            }
        ) else { return }

        guard let compiled = runtime.compiledScene,
              let provider = runtime.textureProvider else { return }

        runtime.currentRenderSource = .sceneEdit(SceneEditRenderSourcePayload(
            commands: resolved.commands,
            textureProvider: provider,
            pathRegistry: compiled.pathRegistry,
            assetSizes: runtime.mergedAssetSizes,
            canvasSize: runtime.canvasSize,
            backgroundState: runtime.background.effectiveBackgroundState,
            backgroundTextureProvider: runtime.background.backgroundTextureProvider
        ))
        runtime.onOutput?(.renderSourceUpdated)
    }

    // MARK: - Trim

    func updateInteractiveTrimPreview(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double) {
        runtime.userMediaService?.updateInteractiveTrimPreview(blockId: blockId, draftSelection: draftSelection, previewTime: previewTime)
    }

    func endInteractiveTrimPreview(blockId: String) {
        runtime.userMediaService?.endInteractiveTrimPreview(blockId: blockId)
    }

    func previewExactVideoTrimFrame(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double) {
        runtime.userMediaService?.previewExactVideoTrimFrame(blockId: blockId, draftSelection: draftSelection, previewTime: previewTime)
    }

    func applyPersistedVideoSelection(blockId: String, _ selection: PersistedVideoSelection) throws {
        try runtime.userMediaService?.applyPersistedVideoSelection(blockId: blockId, selection)
    }

    // MARK: - Media Mutations

    func applyMediaPlacementChange(instanceId: UUID, blockId: String, placement: MediaPlacementState) -> Bool {
        var localApplied = false

        if let player = runtime.scenePlayer, let service = runtime.userMediaService,
           activeSceneInstanceId == instanceId {
            let deps = SceneRuntimeStateApplier.FastPathDependencies(scenePlayer: player, userMediaService: service)
            SceneRuntimeStateApplier.applyPlacementChange(blockId: blockId, placement: placement, deps: deps)
            refreshSceneEditIfActive()
            localApplied = true
        }

        runtime.timelineCompositionEngine?.applyPlacementChange(blockId: blockId, placement: placement, for: instanceId)
        runtime.refreshCurrentTimelineFrame()

        return localApplied
    }

    func applyMediaVisibilityChange(instanceId: UUID, blockId: String, visible: Bool) -> Bool {
        var localApplied = false

        if let player = runtime.scenePlayer, activeSceneInstanceId == instanceId {
            SceneRuntimeStateApplier.applyVisibilityChange(blockId: blockId, visible: visible, player: player)
            refreshSceneEditIfActive()
            localApplied = true
        }

        runtime.timelineCompositionEngine?.applyVisibilityChange(blockId: blockId, visible: visible, for: instanceId)
        runtime.refreshCurrentTimelineFrame()

        return localApplied
    }

    func applyMediaSlotChange(instanceId: UUID, blockId: String, slot: SceneMediaSlot?) {
        let isActiveScene = activeSceneInstanceId == instanceId

        if isActiveScene, let player = runtime.scenePlayer, let service = runtime.userMediaService {
            if slot == nil {
                let deps = SceneRuntimeStateApplier.RestoreDependencies(
                    scenePlayer: player,
                    userMediaService: service,
                    resolvedMedia: .empty
                )
                SceneRuntimeStateApplier.applySlotChange(blockId: blockId, slot: slot, deps: deps)
                refreshSceneEditIfActive()
                runtime.session.updateMissingMedia(for: instanceId, failures: service.currentRestoreFailedBlockIds)
            } else {
                let registry = runtime.selfHealedRegistry()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let singleMap: [String: SceneMediaSlot] = [blockId: slot!]
                    let resolved = await ResolvedMediaMapBuilder.build(
                        slots: singleMap,
                        locator: self.runtime.session.mediaLocator,
                        registry: registry
                    )
                    let deps = SceneRuntimeStateApplier.RestoreDependencies(
                        scenePlayer: player,
                        userMediaService: service,
                        resolvedMedia: resolved
                    )
                    SceneRuntimeStateApplier.applySlotChange(blockId: blockId, slot: slot, deps: deps)
                    self.refreshSceneEditIfActive()
                    self.runtime.session.updateMissingMedia(for: instanceId, failures: service.currentRestoreFailedBlockIds)
                }
            }
        }

        if let sceneState = runtime.session.state?.draft.sceneInstanceStates[instanceId] {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runtime.timelineCompositionEngine?.updateSceneState(sceneState, for: instanceId, assetRegistry: self.runtime.selfHealedRegistry())
                self.runtime.refreshCurrentTimelineFrame()
            }
        }
    }

    func reapplyPlacementAfterMediaReady(instanceId: UUID?, blockId: String, placement: MediaPlacementState) -> Bool {
        guard let player = runtime.scenePlayer, let service = runtime.userMediaService else { return false }
        let deps = SceneRuntimeStateApplier.FastPathDependencies(scenePlayer: player, userMediaService: service)
        SceneRuntimeStateApplier.applyPlacementChange(blockId: blockId, placement: placement, deps: deps)
        refreshSceneEditIfActive()
        return true
    }

    func clearMediaSlot(blockId: String) {
        runtime.userMediaService?.clear(blockId: blockId)
    }

    func setSelectedVariant(blockId: String, variantId: String) {
        runtime.scenePlayer?.setSelectedVariant(blockId: blockId, variantId: variantId)
    }

    func applySceneStateChange(instanceId: UUID, sceneState: SceneState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runtime.timelineCompositionEngine?.updateSceneState(sceneState, for: instanceId, assetRegistry: self.runtime.selfHealedRegistry())
            self.runtime.refreshCurrentTimelineFrame()
        }
    }

    func applyVideoSelectionToEngine(selection: PersistedVideoSelection, blockId: String, instanceId: UUID) {
        runtime.timelineCompositionEngine?.applyPersistedVideoSelection(selection, blockId: blockId, for: instanceId)
    }

    func syncEngineAfterUndoRedo(state: EditorState) {
        guard let engine = runtime.timelineCompositionEngine else { return }
        engine.setTimeline(
            state.canonicalTimeline,
            sceneStates: state.draft.sceneInstanceStates,
            assetRegistry: state.draft.assetRegistry.selfHealed(for: state.draft)
        )
        Task { @MainActor in
            let registry = state.draft.assetRegistry.selfHealed(for: state.draft)
            for (instanceId, sceneState) in state.draft.sceneInstanceStates {
                await engine.updateSceneState(sceneState, for: instanceId, assetRegistry: registry)
            }
        }
    }

    func syncVideoStillFrames(sceneFrameIndex: Int) {
        guard !runtime.isPlaying else { return }
        runtime.userMediaService?.updateVideoStillFrames(sceneFrameIndex: sceneFrameIndex, mediaFrameIndex: sceneFrameIndex)
        runtime.lastStillSyncFrame = sceneFrameIndex
    }

    // MARK: - Queries

    func videoTrimContext(blockId: String) -> VideoTrimContext? {
        runtime.userMediaService?.videoTrimContext(blockId: blockId)
    }

    func currentVideoTime(blockId: String, sceneFrameIndex: Int) -> Double {
        runtime.userMediaService?.currentVideoTime(blockId: blockId, sceneFrameIndex: sceneFrameIndex) ?? 0
    }

    func mediaActionBarContext(blockId: String) -> MediaActionBarContext {
        MediaActionBarContext(
            allowedMedia: runtime.scenePlayer?.allowedMedia(blockId: blockId),
            availableVariants: runtime.scenePlayer?.availableVariants(blockId: blockId) ?? [],
            selectedVariantId: runtime.scenePlayer?.selectedVariantId(blockId: blockId),
            canTrimVideo: runtime.userMediaService?.videoTrimContext(blockId: blockId) != nil
        )
    }

    func sceneEditOverlayProvider() -> SceneEditOverlayProviding? {
        runtime.scenePlayer
    }

    // MARK: - Media Ready Handler

    func handleMediaReadyForPlacement(blockId: String) {
        guard let instanceId = activeSceneInstanceId,
              let slot = runtime.session.state?.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId] else {
            runtime.onOutput?(.renderSourceUpdated)
            return
        }
        let _ = reapplyPlacementAfterMediaReady(instanceId: instanceId, blockId: blockId, placement: slot.asset.placement)
    }
}
