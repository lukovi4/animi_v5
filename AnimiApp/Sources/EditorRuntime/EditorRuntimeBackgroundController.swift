import Foundation
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorRuntimeBackground")

/// Owns background texture lifecycle, editor sessions, and effective-background resolution.
@MainActor
internal final class EditorRuntimeBackgroundController {
    unowned let runtime: EditorRuntime

    // MARK: - Stored Properties

    var backgroundTextureService: BackgroundTextureService?
    var backgroundTextureProvider: InMemoryTextureProvider?
    var effectiveBackgroundState: EffectiveBackgroundState?
    var backgroundImportGeneration: UInt = 0
    var hasActiveBackgroundEditor: Bool = false
    var backgroundEditScope: EditorRuntime.BackgroundEditScope = .project
    var lastBackgroundPresetId: String?
    var backgroundEditorTrackedAssetIds: Set<ProjectAssetID> = []

    init(runtime: EditorRuntime) {
        self.runtime = runtime
    }

    // MARK: - Setup

    func setupBackground(compiled: CompiledScene) {
        guard let ctx = runtime.metalContext else {
            logger.info("[EditorRuntime] setupBackground skipped: no metal context")
            return
        }

        let bgProvider = InMemoryTextureProvider()
        self.backgroundTextureProvider = bgProvider

        let bgService = BackgroundTextureService(
            textureProvider: bgProvider,
            device: ctx.device,
            commandQueue: ctx.commandQueue,
            mediaLocator: runtime.session.mediaLocator,
            mediaWriter: runtime.session.mediaWriter
        )
        self.backgroundTextureService = bgService

        let bgOverride = runtime.session.state?.draft.background
        let sceneOverride = currentSceneBackgroundOverride()
        let templateBackground = compiled.runtime.scene.background
        let effState = EffectiveBackgroundBuilder.build(
            templateBackground: templateBackground,
            projectOverride: bgOverride,
            sceneOverride: sceneOverride,
            presetLibrary: runtime.session.backgroundPresetProvider
        )
        self.effectiveBackgroundState = effState

        if let state = effState {
            logger.info("[EditorRuntime] Background preset '\(state.preset.presetId)' with \(state.regionStates.count) regions")

            if let override = bgOverride {
                let registry = runtime.selfHealedRegistry()
                Task { [weak runtime] in
                    guard let runtime else { return }
                    let loadedKeys = await bgService.preloadTextures(
                        from: override,
                        presetId: state.preset.presetId,
                        assetRegistry: registry
                    )
                    if !loadedKeys.isEmpty {
                        logger.info("[EditorRuntime] Preloaded \(loadedKeys.count) background textures")
                    }
                    runtime.onOutput?(.renderSourceUpdated)
                }
            }
        }

        // Refresh render source with new background
        switch runtime.state {
        case .timelinePreview:
            runtime.refreshCurrentTimelineFrame()
        case .sceneEdit:
            runtime.sceneEdit.updateSceneEditRenderSource()
        default:
            break
        }
    }

    // MARK: - Per-Scene Preview Background

    func backgroundOwnerInstanceId(
        at compressedFrame: Int,
        engine: TimelineCompositionEngine
    ) -> UUID? {
        guard let math = engine.transitionMath else { return nil }
        guard let mode = math.renderMode(for: compressedFrame) else { return nil }
        let ownerIndex: Int = switch mode {
        case .single(let sceneIndex, _): sceneIndex
        case .transition(let sceneAIndex, _, _, _, _, _): sceneAIndex
        }
        guard ownerIndex < math.sceneItems.count else { return nil }
        return math.sceneItems[ownerIndex].id
    }

    func buildPreviewBackgroundState(for instanceId: UUID) -> EffectiveBackgroundState? {
        let sceneOverride = runtime.session.state?.draft.sceneInstanceStates[instanceId]?.backgroundOverride
        let projectOverride = runtime.session.state?.draft.background
        let templateBg = runtime.timelineCompositionEngine?.runtime(for: instanceId)?
            .resources.compiled.runtime.scene.background

        return EffectiveBackgroundBuilder.build(
            templateBackground: templateBg,
            projectOverride: projectOverride,
            sceneOverride: sceneOverride,
            presetLibrary: runtime.session.backgroundPresetProvider
        )
    }

    func updatePreviewBackgroundForScene(_ instanceId: UUID) {
        let newState = buildPreviewBackgroundState(for: instanceId)
        if newState != effectiveBackgroundState {
            effectiveBackgroundState = newState
        }
    }

    func resolvePreviewBackgroundState(for resolved: ResolvedTimelineFrame) -> EffectiveBackgroundState? {
        let ownerId: UUID? = switch resolved {
        case .single(let ctx): ctx.sceneInstanceId
        case .transition(let ctx): ctx.sceneA.sceneInstanceId
        }
        guard let ownerId else { return nil }
        return buildPreviewBackgroundState(for: ownerId)
    }

    // MARK: - Scene Background Override

    func currentSceneBackgroundOverride() -> ProjectBackgroundOverride? {
        guard let instanceId = runtime.sceneEdit.activeSceneInstanceId else { return nil }
        return runtime.session.state?.draft.sceneInstanceStates[instanceId]?.backgroundOverride
    }

    // MARK: - Texture Management

    func persistBackgroundImage(
        sourceFileURL: URL,
        generation: UInt,
        sessionPresetId: String
    ) async throws -> MediaRef {
        guard let service = backgroundTextureService else {
            throw ExportAbortError(message: "Background texture service not available")
        }

        let (mediaRef, _) = try await service.persistImage(from: sourceFileURL)
        logger.info("[Background] Persisted image: \(mediaRef.storagePath)")

        guard backgroundImportGeneration == generation,
              effectiveBackgroundState?.preset.presetId == sessionPresetId else {
            logger.info("[Background] Import generation stale after persist — cleaning up orphan")
            try? await service.deleteMediaFile(mediaRef)
            throw BackgroundImportStaleError()
        }

        return mediaRef
    }

    func loadBackgroundTexture(
        mediaRef: MediaRef,
        regionId: String,
        generation: UInt,
        sessionPresetId: String
    ) async throws -> String {
        guard let service = backgroundTextureService else {
            throw ExportAbortError(message: "Background texture service not available")
        }

        let slotKey = EffectiveBackgroundBuilder.makeSlotKey(
            presetId: sessionPresetId,
            regionId: regionId
        )

        let freshRegistry = runtime.selfHealedRegistry()
        do {
            try await service.loadTexture(slotKey: slotKey, mediaRef: mediaRef, assetRegistry: freshRegistry)
        } catch {
            try? await service.deleteMediaFile(mediaRef)
            throw error
        }

        guard backgroundImportGeneration == generation,
              effectiveBackgroundState?.preset.presetId == sessionPresetId else {
            logger.info("[Background] Import generation stale after texture load — clearing stale texture")
            service.clearTexture(slotKey: slotKey)
            try? await service.deleteMediaFile(mediaRef)
            throw BackgroundImportStaleError()
        }

        return slotKey
    }

    func deleteBackgroundMediaFile(_ mediaRef: MediaRef) async throws {
        try await backgroundTextureService?.deleteMediaFile(mediaRef)
    }

    func clearBackgroundTexture(slotKey: String) {
        backgroundTextureService?.clearTexture(slotKey: slotKey)
    }

    func clearAllBackgroundTextures() {
        backgroundTextureService?.clearAllTrackedTextures()
    }

    func clearBackgroundTextures(prefix: String) {
        backgroundTextureService?.clearTextures(prefix: prefix)
    }

    var hasImageBackgroundRegions: Bool {
        guard let effState = effectiveBackgroundState else { return false }
        return effState.regionStates.values.contains(where: {
            if case .image = $0.source { return true }
            return false
        })
    }

    func reloadBackgroundTextures() async {
        let proj = runtime.session.state?.draft.background
        let scene = currentSceneBackgroundOverride()
        guard let effState = effectiveBackgroundState else { return }
        await preloadBackgroundTexturesScoped(
            projectOverride: proj, sceneOverride: scene, effectiveState: effState
        )
    }

    func preloadBackgroundTexturesScoped(
        projectOverride: ProjectBackgroundOverride?,
        sceneOverride: ProjectBackgroundOverride?,
        effectiveState: EffectiveBackgroundState?
    ) async {
        guard let service = backgroundTextureService, let state = effectiveState else { return }
        let registry = runtime.selfHealedRegistry()
        for (regionId, regionState) in state.regionStates {
            if case .image(let imageSource) = regionState.source {
                let mediaRef = sceneOverride?.regions[regionId]?.imageMediaRef
                    ?? projectOverride?.regions[regionId]?.imageMediaRef
                guard let mediaRef else { continue }
                do {
                    try await service.loadTexture(
                        slotKey: imageSource.slotKey,
                        mediaRef: mediaRef,
                        assetRegistry: registry
                    )
                } catch {
                    logger.error("[Background] Failed to preload texture: \(error.localizedDescription)")
                }
            }
        }
        runtime.onOutput?(.renderSourceUpdated)
    }

    func incrementBackgroundImportGeneration() {
        backgroundImportGeneration &+= 1
    }

    // MARK: - Effective Background Resolution

    func resolveBackgroundInputs(
        previewOverride: ProjectBackgroundOverride? = nil
    ) -> (projectOverride: ProjectBackgroundOverride?, sceneOverride: ProjectBackgroundOverride?) {
        switch backgroundEditScope {
        case .project:
            return (
                projectOverride: previewOverride ?? runtime.session.state?.draft.background,
                sceneOverride: currentSceneBackgroundOverride()
            )
        case .scene(let instanceId):
            return (
                projectOverride: runtime.session.state?.draft.background,
                sceneOverride: previewOverride ?? runtime.session.state?.draft.sceneInstanceStates[instanceId]?.backgroundOverride
            )
        }
    }

    func rebuildEffectiveBackgroundScoped(
        projectOverride: ProjectBackgroundOverride?,
        sceneOverride: ProjectBackgroundOverride?
    ) {
        let effState = EffectiveBackgroundBuilder.build(
            templateBackground: runtime.compiledScene?.runtime.scene.background,
            projectOverride: projectOverride,
            sceneOverride: sceneOverride,
            presetLibrary: runtime.session.backgroundPresetProvider
        )
        setEffectiveBackgroundState(effState)
    }

    func setEffectiveBackgroundState(_ state: EffectiveBackgroundState?) {
        effectiveBackgroundState = state
        switch runtime.state {
        case .timelinePreview:
            runtime.refreshCurrentTimelineFrame()
        case .sceneEdit:
            runtime.sceneEdit.updateSceneEditRenderSource()
        default:
            break
        }
    }

    func applyBackgroundPreviewOverride(_ override: ProjectBackgroundOverride) {
        let (proj, scene) = resolveBackgroundInputs(previewOverride: override)
        rebuildEffectiveBackgroundScoped(projectOverride: proj, sceneOverride: scene)
        let effState = effectiveBackgroundState
        Task { @MainActor [weak self] in
            guard let self else { return }
            if scene != nil || proj != nil {
                await self.preloadBackgroundTexturesScoped(
                    projectOverride: proj, sceneOverride: scene, effectiveState: effState
                )
            }
        }
    }

    // MARK: - Background Editor Session

    func beginBackgroundEditorSession(scope: EditorRuntime.BackgroundEditScope = .project) {
        hasActiveBackgroundEditor = true
        backgroundEditScope = scope
        backgroundEditorTrackedAssetIds.removeAll()
    }

    func currentOverrideForEditScope() -> ProjectBackgroundOverride {
        switch backgroundEditScope {
        case .project:
            return runtime.session.state?.draft.background ?? .empty
        case .scene(let instanceId):
            return runtime.session.state?.draft.sceneInstanceStates[instanceId]?.backgroundOverride
                ?? runtime.session.state?.draft.background ?? .empty
        }
    }

    func handleBackgroundPresetChange(oldPresetId: String, newPresetId: String) {
        clearBackgroundTextures(prefix: "bg/\(oldPresetId)/")
        lastBackgroundPresetId = newPresetId
    }

    func importBackgroundImage(
        sourceFileURL: URL,
        regionId: String,
        setEditorImage: ((String, MediaRef) -> Void)?
    ) async throws {
        guard let bgState = effectiveBackgroundState else { return }

        let capturedGeneration = backgroundImportGeneration
        let sessionPresetId = bgState.preset.presetId

        let mediaRef = try await persistBackgroundImage(
            sourceFileURL: sourceFileURL,
            generation: capturedGeneration,
            sessionPresetId: sessionPresetId
        )

        runtime.session.registerAssetBookkeeping(ProjectAssetDescriptor(
            assetId: mediaRef.assetId,
            mediaKind: mediaRef.mediaKind,
            storagePath: mediaRef.storagePath
        ))
        if hasActiveBackgroundEditor {
            backgroundEditorTrackedAssetIds.insert(mediaRef.assetId)
        }

        do {
            _ = try await loadBackgroundTexture(
                mediaRef: mediaRef,
                regionId: regionId,
                generation: capturedGeneration,
                sessionPresetId: sessionPresetId
            )
        } catch is BackgroundImportStaleError {
            runtime.session.unregisterAssetBookkeeping(mediaRef.assetId)
            backgroundEditorTrackedAssetIds.remove(mediaRef.assetId)
            throw BackgroundImportStaleError()
        } catch {
            runtime.session.unregisterAssetBookkeeping(mediaRef.assetId)
            backgroundEditorTrackedAssetIds.remove(mediaRef.assetId)
            throw error
        }

        if hasActiveBackgroundEditor, let setImage = setEditorImage {
            setImage(regionId, mediaRef)
        } else {
            let oldBgAssetId = runtime.session.state?.draft.background.regions[regionId]?.imageMediaRef?.assetId
            var bg = runtime.session.state?.draft.background ?? .empty
            bg.regions[regionId] = RegionOverride(
                source: .image(ImageOverride(mediaRef: mediaRef, transform: .identity))
            )
            runtime.session.dispatch(.setBackground(bg))
            if let oldId = oldBgAssetId, oldId != mediaRef.assetId {
                runtime.session.unregisterAssetIfUnreferenced(oldId)
            }
            rebuildEffectiveBackgroundScoped(
                projectOverride: bg,
                sceneOverride: currentSceneBackgroundOverride()
            )
            hasActiveBackgroundEditor = false
        }
    }

    func commitBackgroundEditorDismiss(
        override: ProjectBackgroundOverride,
        presetId: String
    ) {
        let scope = backgroundEditScope
        hasActiveBackgroundEditor = false
        incrementBackgroundImportGeneration()

        if let oldPresetId = lastBackgroundPresetId, oldPresetId != presetId {
            clearBackgroundTextures(prefix: "bg/\(oldPresetId)/")
        }
        lastBackgroundPresetId = presetId

        switch scope {
        case .project:
            let oldBgAssetIds: Set<ProjectAssetID> = Set(
                (runtime.session.state?.draft.background.regions.values ?? [:].values)
                    .compactMap { $0.imageMediaRef?.assetId }
            )
            runtime.session.dispatch(.setBackground(override))
            for oldAssetId in oldBgAssetIds {
                runtime.session.unregisterAssetIfUnreferenced(oldAssetId)
            }

        case .scene(let instanceId):
            let oldBgAssetIds: Set<ProjectAssetID> = Set(
                (runtime.session.state?.draft.sceneInstanceStates[instanceId]?.backgroundOverride?.regions.values ?? [:].values)
                    .compactMap { $0.imageMediaRef?.assetId }
            )
            runtime.session.setSceneBackgroundOverride(override, for: instanceId)
            for oldAssetId in oldBgAssetIds {
                runtime.session.unregisterAssetIfUnreferenced(oldAssetId)
            }
        }

        for trackedAssetId in backgroundEditorTrackedAssetIds {
            runtime.session.unregisterAssetIfUnreferenced(trackedAssetId)
        }
        backgroundEditorTrackedAssetIds.removeAll()

        let projectOverride: ProjectBackgroundOverride?
        let sceneOverride: ProjectBackgroundOverride?
        switch scope {
        case .project:
            projectOverride = override
            sceneOverride = currentSceneBackgroundOverride()
        case .scene:
            projectOverride = runtime.session.state?.draft.background
            sceneOverride = override
        }
        rebuildEffectiveBackgroundScoped(projectOverride: projectOverride, sceneOverride: sceneOverride)
        let effState = effectiveBackgroundState
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.preloadBackgroundTexturesScoped(
                projectOverride: projectOverride, sceneOverride: sceneOverride, effectiveState: effState
            )
        }
    }
}
