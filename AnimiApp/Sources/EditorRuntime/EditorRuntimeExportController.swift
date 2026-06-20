import Foundation
import MetalKit
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorRuntimeExport")

/// Owns export orchestration: preflight, render, delivery, and state cleanup.
@MainActor
internal final class EditorRuntimeExportController {
    unowned let runtime: EditorRuntime

    // MARK: - Active Export Request

    final class ActiveExportRequest {
        let id: UUID
        let exporter: VideoExporter
        let deliveryPolicy: ExportDeliveryPolicy
        #if DEBUG
        let debugStartNs: UInt64
        var debugRenderStartNs: UInt64?
        #endif

        var deliveryFlow: ExportDeliveryFlow?

        init(id: UUID, exporter: VideoExporter, deliveryPolicy: ExportDeliveryPolicy) {
            self.id = id
            self.exporter = exporter
            self.deliveryPolicy = deliveryPolicy
            #if DEBUG
            self.debugStartNs = DispatchTime.now().uptimeNanoseconds
            #endif
        }

        func isActive(for requestId: UUID) -> Bool {
            id == requestId
        }
    }

    // MARK: - Export Teardown State

    enum ExportTeardownState {
        case idle
        case entering
        case completed
    }

    // MARK: - Stored Properties

    var pendingDeliveryPolicy: ExportDeliveryPolicy = .photoLibraryOnly
    var activeExportRequest: ActiveExportRequest?
    var preExportState: EditorRuntimeState?
    var preflightContinuation: CheckedContinuation<EditorRuntime.ExportPreflightChoice, Never>?
    private(set) var exportTeardownState: ExportTeardownState = .idle
    private var cancelRequestedDuringEnter = false
    private(set) var isRestoringPreviewAfterExport = false
    var makeDeliverer: () -> ExportDelivering = { ExportDeliveryCoordinator() }

    /// Legacy compat: true when teardown has fully completed (used by restore path).
    var exportTeardownOccurred: Bool { exportTeardownState == .completed }

    /// Blocks preview presentation resolve during export enter/completed.
    var blocksPreviewPresentationDuringExport: Bool {
        exportTeardownState == .entering || exportTeardownState == .completed
    }

    var isExporting: Bool { activeExportRequest != nil }

    init(runtime: EditorRuntime) {
        self.runtime = runtime
    }

    // MARK: - Public API

    func startExport(policy: ExportDeliveryPolicy) {
        guard !isRestoringPreviewAfterExport else { return }
        guard runtime.state == .timelinePreview || {
            if case .sceneEdit = runtime.state { return true }
            return false
        }() else { return }

        if let summary = runtime.session.missingMediaSummary, summary.hasFailedMedia {
            runtime.onOutput?(.presentError("Export unavailable: some media files are missing."))
            return
        }

        pendingDeliveryPolicy = policy
        preExportState = runtime.state
        runtime.state = .exporting
        runtime.onOutput?(.exportStarted)
    }

    func cancelExport() {
        guard runtime.state == .exporting else { return }
        activeExportRequest?.exporter.cancel()
        preflightContinuation?.resume(returning: .cancel)
        preflightContinuation = nil
        clearActiveExportRequest()
        switch exportTeardownState {
        case .completed:
            Task { [weak self, weak runtime] in
                guard let self, let runtime else { return }
                await self.restorePreviewAfterExportTeardownIfNeeded(runtime: runtime)
                runtime.onOutput?(.exportCancelled)
            }
        case .entering:
            // Teardown is in-flight (suspended at await). Mark cancellation.
            // enterExportMode() will check this on resume and abort.
            cancelRequestedDuringEnter = true
        case .idle:
            restorePreExportState()
            runtime.onOutput?(.exportCancelled)
        }
    }

    func isActiveExportRequest(_ requestId: UUID) -> Bool {
        activeExportRequest?.isActive(for: requestId) ?? false
    }

    func clearExportRequestIfCurrent(_ requestId: UUID) {
        guard isActiveExportRequest(requestId) else { return }
        activeExportRequest = nil
    }

    func applyExportPreflightChoice(_ choice: EditorRuntime.ExportPreflightChoice) {
        preflightContinuation?.resume(returning: choice)
        preflightContinuation = nil
    }

    // MARK: - Export Route Resolution

    enum ExportRoute: Equatable {
        case timeline
        case singleScene
    }

    func resolveExportRoute() -> ExportRoute {
        runtime.timelineCompositionEngine != nil ? .timeline : .singleScene
    }

    func executeExport() async {
        guard !isRestoringPreviewAfterExport else { return }
        guard runtime.state == .exporting else { return }
        guard let ctx = runtime.metalContext else {
            abortExport(message: "No Metal context available")
            return
        }

        let route = resolveExportRoute()

        let entered = await enterExportMode()
        guard entered, runtime.state == .exporting else { return }

        switch route {
        case .timeline:
            await executeTimelineExport(ctx: ctx)
        case .singleScene:
            await executeSingleSceneExport(ctx: ctx)
        }
    }

    func confirmShareCompleted() {
        activeExportRequest?.deliveryFlow?.finalizeAfterShare()
    }

    // MARK: - Test Seams

    #if DEBUG
    func exportRouteForCurrentState() -> ExportRoute {
        resolveExportRoute()
    }

    func simulateHandleExportCompletion(result: Result<URL, Error>) {
        let exporter = VideoExporter(mediaLocator: runtime.session.mediaLocator)
        let request = ActiveExportRequest(id: UUID(), exporter: exporter, deliveryPolicy: pendingDeliveryPolicy)
        activeExportRequest = request
        handleExportCompletion(result: result, requestId: request.id)
    }

    func setRestoringForTesting(_ value: Bool) {
        isRestoringPreviewAfterExport = value
    }

    func setExportTeardownStateForTesting(_ state: ExportTeardownState) {
        exportTeardownState = state
    }
    #endif

    // MARK: - Export Mode Management

    /// Performs export teardown: stops playback, drains preview resources, clears textures.
    /// Returns `true` if teardown completed successfully, `false` if cancelled during drain.
    @discardableResult
    func enterExportMode() async -> Bool {
        exportTeardownState = .entering
        cancelRequestedDuringEnter = false
        #if DEBUG
        MemoryDiagnostics.checkpoint("export.enter.before", metal: runtime.metalContext?.device)
        MemoryDiagnostics.event("export.enter")
        MemoryDiagnostics.signpostEvent("export.enter")
        #endif
        runtime.stopPlayback()
        runtime.cancelPendingPlayheadResolve()
        // Export does its own immediate heavy release below; cancel the warm-pause
        // idle reclaim so it cannot fire mid-export.
        runtime.cancelIdleResourceReclaim()
        runtime.previewAudio.teardownForExport()
        // Clear background textures early (before await window opens)
        runtime.background.backgroundTextureService?.clearAllTrackedTextures()
        await runtime.userMediaService?.releasePreviewResources()
        await runtime.timelineCompositionEngine?.releasePreviewResources(evictTypeCache: false)

        // Check if export was cancelled during async drain
        guard !cancelRequestedDuringEnter else {
            // Resources were released during drain — must restore them
            exportTeardownState = .completed
            cancelRequestedDuringEnter = false
            await restorePreviewAfterExportTeardownIfNeeded(runtime: runtime)
            runtime.onOutput?(.exportCancelled)
            return false
        }

        // Clear background textures after async drain to prevent re-entrancy reload
        runtime.background.backgroundTextureService?.clearAllTrackedTextures()
        exportTeardownState = .completed
        #if DEBUG
        MemoryDiagnostics.checkpoint("export.enter.after", metal: runtime.metalContext?.device)
        #endif
        return true
    }

    func exitExportModeToIdle() async {
        #if DEBUG
        MemoryDiagnostics.event("export.exit")
        #endif
        await restorePreviewAfterExportTeardownIfNeeded(runtime: runtime)
    }

    private func restorePreviewAfterExportTeardownIfNeeded(runtime: EditorRuntime) async {
        guard exportTeardownOccurred else {
            restorePreExportState()
            return
        }
        let needsBackgroundReload = runtime.background.hasImageBackgroundRegions
        restorePreExportState()
        isRestoringPreviewAfterExport = true
        defer { isRestoringPreviewAfterExport = false }

        if needsBackgroundReload {
            await runtime.background.reloadBackgroundTextures()
        }
        await runtime.restorePreviewResourcesAfterExport()
        runtime.previewAudio.prepareForTimelinePreview()
        #if DEBUG
        MemoryDiagnostics.event("export.previewRestored")
        MemoryDiagnostics.signpostEvent("preview.restore")
        MemoryDiagnostics.checkpoint("preview.restore.after", metal: runtime.metalContext?.device)
        #endif
    }

    func restorePreExportState() {
        runtime.state = preExportState ?? .timelinePreview
        preExportState = nil
        exportTeardownState = .idle
    }

    func clearActiveExportRequest() {
        activeExportRequest = nil
    }

    // MARK: - Abort Helpers

    private func abortExport(message: String) {
        logger.error("[Export] Aborted: \(message)")
        preflightContinuation?.resume(returning: .cancel)
        preflightContinuation = nil
        clearActiveExportRequest()
        restorePreExportState()
        runtime.onOutput?(.exportRenderFailed(ExportAbortError(message: message)))
    }

    private func abortExportAfterTeardown(message: String) async {
        logger.error("[Export] Aborted: \(message)")
        preflightContinuation?.resume(returning: .cancel)
        preflightContinuation = nil
        clearActiveExportRequest()
        await exitExportModeToIdle()
        runtime.onOutput?(.exportRenderFailed(ExportAbortError(message: message)))
    }

    // MARK: - Single Scene Export

    private func executeSingleSceneExport(ctx: EditorRuntimeMetalContext) async {
        guard runtime.state == .exporting, exportTeardownState == .completed else { return }
        guard let compiled = runtime.compiledScene,
              let player = runtime.scenePlayer,
              let resolver = runtime.assetResolver else {
            await abortExportAfterTeardown(message: "Missing dependencies for single-scene export")
            return
        }

        let exporter = VideoExporter(mediaLocator: runtime.session.mediaLocator)
        let request = ActiveExportRequest(id: UUID(), exporter: exporter, deliveryPolicy: pendingDeliveryPolicy)
        activeExportRequest = request
        let requestId = request.id

        let exportTP = ExportTextureProvider(
            device: ctx.device,
            assetIndex: compiled.mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: compiled.bindingAssetIds
        )

        let sceneRuntime = compiled.runtime
        let canvasSize = sceneRuntime.canvasSize

        let outputURL = makeExportOutputURL(prefix: "export_\(sceneRuntime.scene.sceneId ?? "scene")")

        let audioPlan = await runtime.buildAudioExportPlan(
            includeOriginalFromVideoSlots: true, originalDefaultVolume: 1.0
        )

        let instanceId = runtime.sceneEdit.activeSceneInstanceId
        let mediaSlots: [String: SceneMediaSlot] = instanceId.flatMap {
            runtime.session.state?.draft.sceneInstanceStates[$0]?.mediaSlotsByBlockId
        } ?? [:]
        let videoSlotCount = mediaSlots.values.filter { $0.mediaRef.mediaKind == .video }.count
        let backgroundRegionCount = runtime.session.state?.draft.background.regions.count ?? 0

        let preflightResult = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: (width: Int(canvasSize.width), height: Int(canvasSize.height)),
            videoSlotCount: videoSlotCount,
            backgroundRegionCount: backgroundRegionCount,
            currentPreset: .high,
            fps: sceneRuntime.fps
        )

        let originalSizePx = (width: Int(canvasSize.width), height: Int(canvasSize.height))
        let exportSizePx: (width: Int, height: Int)
        let exportPreset: VideoQualityPreset

        switch preflightResult {
        case .recommendLowerPreset(_, let suggestedPreset, let suggestedSizePx):
            runtime.onOutput?(.exportPreflightRecommendation(preflightResult))
            let choice = await withCheckedContinuation { (cont: CheckedContinuation<EditorRuntime.ExportPreflightChoice, Never>) in
                self.preflightContinuation = cont
            }
            guard isActiveExportRequest(requestId) else {
                return
            }
            switch choice {
            case .cancel:
                await exitExportModeToIdle()
                clearActiveExportRequest()
                runtime.onOutput?(.exportCancelled)
                return
            case .continueOriginal:
                exportSizePx = originalSizePx
                exportPreset = .high
            case .useRecommended(let preset, let sizePx):
                exportSizePx = sizePx
                exportPreset = preset
                logger.info("[Export] User chose reduced quality: \(sizePx.width)x\(sizePx.height) preset=\(String(describing: preset))")
            }
        case .safe:
            exportSizePx = originalSizePx
            exportPreset = .high
        }

        let budget = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: exportSizePx,
            videoSlotCount: videoSlotCount,
            backgroundRegionCount: backgroundRegionCount,
            currentPreset: exportPreset,
            fps: sceneRuntime.fps
        ).budget

        let settings = makeSingleSceneExportSettings(
            outputURL: outputURL,
            sizePx: exportSizePx,
            preset: exportPreset,
            fps: sceneRuntime.fps,
            audioPlan: audioPlan
        )

        let mediaSnapshot: ExportMediaSnapshot
        do {
            mediaSnapshot = try await ExportMediaSnapshot.build(
                compiledScene: compiled,
                mediaSlots: mediaSlots,
                mediaLocator: runtime.session.mediaLocator,
                assetRegistry: runtime.selfHealedRegistry(),
                runtime: sceneRuntime
            )
        } catch {
            logger.error("[Export] Media snapshot error: \(error.localizedDescription)")
            await exitExportModeToIdle()
            clearActiveExportRequest()
            runtime.onOutput?(.exportRenderFailed(error))
            return
        }

        let bgSnapshot = ExportBackgroundSnapshot.build(
            from: runtime.session.state?.draft.background,
            sceneOverride: runtime.background.currentSceneBackgroundOverride(),
            effectiveState: runtime.background.effectiveBackgroundState
        )

        guard isActiveExportRequest(requestId) else {
            logger.info("[Export] Cancelled during preflight (stale request)")
            return
        }

        #if DEBUG
        // CP6: opt-in AnimiEngineNext export. When ON, route through the Next bridge and RETURN
        // (no fallback). When OFF, fall through to the unchanged TVECore export below.
        if NextExportEngineToggles.exportWithNextEngine {
            await runNextSingleSceneExport(
                ctx: ctx, exporter: exporter, requestId: requestId,
                compiled: compiled, sceneRuntime: sceneRuntime,
                settings: settings, mediaSnapshot: mediaSnapshot, bgSnapshot: bgSnapshot,
                exportSizePx: exportSizePx, originalSizePx: originalSizePx,
                budget: budget)
            return
        }
        #endif

        #if DEBUG
        if let request = activeExportRequest, request.isActive(for: requestId) {
            let renderStartNs = DispatchTime.now().uptimeNanoseconds
            request.debugRenderStartNs = renderStartNs
            let prepareSec = Double(renderStartNs - request.debugStartNs) / 1_000_000_000.0
            MemoryDiagnostics.event(
                "export.prepare.summary",
                String(format: "mode=single duration=%.2fs outcome=success", prepareSec)
            )
        }
        #endif

        await exporter.exportVideo(
            compiledScene: compiled,
            scenePlayer: player,
            device: ctx.device,
            textureProvider: exportTP,
            pathRegistry: compiled.pathRegistry,
            assetSizes: compiled.mergedAssetIndex.sizeById,
            settings: settings,
            backgroundState: runtime.background.effectiveBackgroundState,
            overlaySnapshot: runtime.session.state.map { state in
                OverlayExportSnapshot.build(from: state.canonicalTimeline, stickerProvider: runtime.session.stickerProvider)
            },
            budget: budget,
            mediaSnapshot: mediaSnapshot,
            backgroundSnapshot: bgSnapshot,
            assetRegistry: runtime.selfHealedRegistry(),
            onFinishing: { [weak self] in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.runtime.onOutput?(.exportFinishing)
            },
            progress: { [weak self] progress in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.runtime.onOutput?(.exportProgress(Float(progress)))
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.handleExportCompletion(result: result, requestId: requestId)
            }
        )
    }

    // MARK: - Timeline Export

    private func executeTimelineExport(ctx: EditorRuntimeMetalContext) async {
        guard runtime.state == .exporting, exportTeardownState == .completed else { return }
        guard let engine = runtime.timelineCompositionEngine,
              let transitionMath = engine.transitionMath else {
            await abortExportAfterTeardown(message: "No timeline configured for timeline export")
            return
        }

        let canvasSize = engine.canvasSize
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            await abortExportAfterTeardown(message: "Invalid canvas size for timeline export")
            return
        }

        let exporter = VideoExporter(mediaLocator: runtime.session.mediaLocator)
        let request = ActiveExportRequest(id: UUID(), exporter: exporter, deliveryPolicy: pendingDeliveryPolicy)
        activeExportRequest = request
        let requestId = request.id

        let outputURL = makeExportOutputURL(prefix: "export_timeline")

        let audioPlan = await runtime.buildAudioExportPlan(
            includeOriginalFromVideoSlots: true, originalDefaultVolume: 1.0
        )

        let sceneCount = runtime.session.state?.sceneItems.count ?? 1
        let allStates = runtime.session.state?.draft.sceneInstanceStates ?? [:]
        let totalVideoSlots = allStates.values.reduce(0) { count, state in
            count + (state.mediaSlotsByBlockId ?? [:]).values.filter { $0.mediaRef.mediaKind == .video }.count
        }
        let backgroundRegionCount = runtime.session.state?.draft.background.regions.count ?? 0

        let preflightResult = ExportPreflightPlanner.plan(
            sceneCount: sceneCount,
            canvasSize: (width: Int(canvasSize.width), height: Int(canvasSize.height)),
            videoSlotCount: totalVideoSlots,
            backgroundRegionCount: backgroundRegionCount,
            currentPreset: .high,
            fps: engine.fps
        )

        let originalSizePx = (width: Int(canvasSize.width), height: Int(canvasSize.height))
        let exportSizePx: (width: Int, height: Int)
        let exportPreset: VideoQualityPreset

        switch preflightResult {
        case .recommendLowerPreset(_, let suggestedPreset, let suggestedSizePx):
            runtime.onOutput?(.exportPreflightRecommendation(preflightResult))
            let choice = await withCheckedContinuation { (cont: CheckedContinuation<EditorRuntime.ExportPreflightChoice, Never>) in
                self.preflightContinuation = cont
            }
            guard isActiveExportRequest(requestId) else {
                return
            }
            switch choice {
            case .cancel:
                await exitExportModeToIdle()
                clearActiveExportRequest()
                runtime.onOutput?(.exportCancelled)
                return
            case .continueOriginal:
                exportSizePx = originalSizePx
                exportPreset = .high
            case .useRecommended(let preset, let sizePx):
                exportSizePx = sizePx
                exportPreset = preset
                logger.info("[Export] User chose reduced quality: \(sizePx.width)x\(sizePx.height) preset=\(String(describing: preset))")
            }
        case .safe:
            exportSizePx = originalSizePx
            exportPreset = .high
        }

        let budget = ExportPreflightPlanner.plan(
            sceneCount: sceneCount,
            canvasSize: exportSizePx,
            videoSlotCount: totalVideoSlots,
            backgroundRegionCount: backgroundRegionCount,
            currentPreset: exportPreset,
            fps: engine.fps
        ).budget

        let settings = makeTimelineExportSettings(
            outputURL: outputURL,
            sizePx: exportSizePx,
            preset: exportPreset,
            fps: engine.fps,
            audioPlan: audioPlan
        )

        let tlSession: TimelineCompositionEngine.TimelineExportSession
        do {
            tlSession = try await engine.buildExportSession()
        } catch {
            await abortExportAfterTeardown(message: "Failed to build timeline export session: \(error.localizedDescription)")
            return
        }

        let sceneBackgrounds = buildPerSceneBackgrounds(from: tlSession)

        guard isActiveExportRequest(requestId) else {
            logger.info("[Export] Cancelled during preflight (stale request)")
            return
        }

        #if DEBUG
        // CP6: opt-in AnimiEngineNext timeline export. ON → Next bridge + RETURN (no fallback);
        // OFF → unchanged TVECore timeline export below.
        if NextExportEngineToggles.exportWithNextEngine {
            await runNextTimelineExport(
                ctx: ctx, exporter: exporter, requestId: requestId,
                tlSession: tlSession, settings: settings,
                exportSizePx: exportSizePx, originalSizePx: originalSizePx,
                backgroundRegionCount: backgroundRegionCount,
                budget: budget)
            return
        }
        #endif

        #if DEBUG
        MemoryDiagnostics.event(
            "export.timeline.config",
            String(format: "scenes=%d videoSlots=%d bgRegions=%d size=%dx%d fps=%d preset=%@ hasAudio=%d",
                   sceneCount,
                   totalVideoSlots,
                   backgroundRegionCount,
                   exportSizePx.width, exportSizePx.height,
                   engine.fps,
                   String(describing: exportPreset),
                   audioPlan.items.isEmpty ? 0 : 1)
        )
        if let request = activeExportRequest, request.isActive(for: requestId) {
            let renderStartNs = DispatchTime.now().uptimeNanoseconds
            request.debugRenderStartNs = renderStartNs
            let prepareSec = Double(renderStartNs - request.debugStartNs) / 1_000_000_000.0
            MemoryDiagnostics.event(
                "export.prepare.summary",
                String(format: "mode=timeline duration=%.2fs outcome=success", prepareSec)
            )
        }
        #endif

        exporter.exportTimeline(
            engine: engine,
            sceneBackgrounds: sceneBackgrounds,
            preBuiltSession: tlSession,
            settings: settings,
            budget: budget,
            assetRegistry: runtime.selfHealedRegistry(),
            onFinishing: { [weak self] in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.runtime.onOutput?(.exportFinishing)
            },
            progress: { [weak self] progress in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.runtime.onOutput?(.exportProgress(Float(progress)))
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.handleExportCompletion(result: result, requestId: requestId)
            }
        )
    }

    // MARK: - Completion

    func handleExportCompletion(result: Result<URL, Error>, requestId: UUID) {
        guard isActiveExportRequest(requestId) else {
            logger.info("[Export] Ignoring stale completion")
            return
        }
        Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }

            #if DEBUG
            let restoreStartNs = DispatchTime.now().uptimeNanoseconds
            #endif

            await self.restorePreviewAfterExportTeardownIfNeeded(runtime: runtime)

            #if DEBUG
            let restoreEndNs = DispatchTime.now().uptimeNanoseconds
            let restoreSec = Double(restoreEndNs - restoreStartNs) / 1_000_000_000.0
            let restoreOutcome = self.isActiveExportRequest(requestId) ? "success" : "stale"
            MemoryDiagnostics.event(
                "export.previewRestore.summary",
                String(format: "duration=%.2fs outcome=%@", restoreSec, restoreOutcome)
            )
            #endif

            guard self.isActiveExportRequest(requestId) else { return }
            self.emitExportCompletionOutput(result: result, requestId: requestId)
        }
    }

    private func emitExportCompletionOutput(result: Result<URL, Error>, requestId: UUID) {
        switch result {
        case .success(let url):
            logger.info("[Export] SUCCESS: \(url.lastPathComponent)")
            Task { [weak runtime] in await runtime?.session.commitAfterExportSuccess() }
            runtime.onOutput?(.exportRenderSucceeded(url))
            saveExportedVideoToPhotos(url, requestId: requestId)

        case .failure(let error as VideoExportError) where error.isCancelled:
            logger.info("[Export] Cancelled")
            #if DEBUG
            logExportTotalSummary(requestId: requestId, outcome: "cancelled")
            #endif
            clearActiveExportRequest()
            runtime.onOutput?(.exportCancelled)

        case .failure(let error):
            logger.error("[Export] ERROR: \(error.localizedDescription)")
            #if DEBUG
            logExportTotalSummary(requestId: requestId, outcome: "failure")
            #endif
            clearActiveExportRequest()
            runtime.onOutput?(.exportRenderFailed(error))
        }
    }

    private func saveExportedVideoToPhotos(_ url: URL, requestId: UUID) {
        let deliverer = makeDeliverer()
        let policy = activeExportRequest?.deliveryPolicy ?? .photoLibraryOnly
        #if DEBUG
        let debugStartNs = activeExportRequest?.debugStartNs
        #endif
        let shareHandoff: ((URL) -> Void)? = policy == .photoLibraryThenShare
            ? { [weak self] url in
                #if DEBUG
                if let debugStartNs {
                    let endNs = DispatchTime.now().uptimeNanoseconds
                    let elapsedSec = Double(endNs - debugStartNs) / 1_000_000_000.0
                    MemoryDiagnostics.event(
                        "export.total.summary",
                        String(format: "duration=%.2fs outcome=savedToPhotosShareReady", elapsedSec)
                    )
                }
                #endif
                self?.runtime.onOutput?(.exportDeliveryShareHandoff(url))
            }
            : nil
        let flow = ExportDeliveryFlow(
            requestId: requestId,
            deliverer: deliverer,
            policy: policy,
            isRequestActive: { [weak self] id in self?.isActiveExportRequest(id) ?? false },
            clearRequestIfCurrent: { [weak self] id in self?.clearExportRequestIfCurrent(id) },
            completion: { [weak self] outcome in
                #if DEBUG
                let shouldLogTotalInCompletion: Bool
                switch (policy, outcome) {
                case (.photoLibraryThenShare, .savedToPhotos):
                    shouldLogTotalInCompletion = false
                default:
                    shouldLogTotalInCompletion = true
                }
                if shouldLogTotalInCompletion, let debugStartNs {
                    let endNs = DispatchTime.now().uptimeNanoseconds
                    let elapsedSec = Double(endNs - debugStartNs) / 1_000_000_000.0
                    MemoryDiagnostics.event(
                        "export.total.summary",
                        String(format: "duration=%.2fs outcome=%@", elapsedSec, String(describing: outcome))
                    )
                }
                #endif
                self?.runtime.onOutput?(.exportDeliveryCompleted(outcome))
            },
            shareHandoff: shareHandoff
        )
        activeExportRequest?.deliveryFlow = flow
        flow.start(fileURL: url, destination: .photoLibrary)
    }

    #if DEBUG
    private func logExportTotalSummary(requestId: UUID, outcome: String) {
        guard let request = activeExportRequest,
              request.isActive(for: requestId) else { return }
        let endNs = DispatchTime.now().uptimeNanoseconds
        let elapsedSec = Double(endNs - request.debugStartNs) / 1_000_000_000.0
        MemoryDiagnostics.event(
            "export.total.summary",
            String(format: "duration=%.2fs outcome=%@", elapsedSec, outcome)
        )
    }
    #endif

    // MARK: - Per-Scene Background

    /// Builds per-scene export background data for every scene in the export session.
    private func buildPerSceneBackgrounds(
        from exportSession: TimelineCompositionEngine.TimelineExportSession
    ) -> [UUID: SceneExportBackgroundData] {
        let allStates = runtime.session.state?.draft.sceneInstanceStates ?? [:]
        let projectOverride = runtime.session.state?.draft.background
        var result: [UUID: SceneExportBackgroundData] = [:]
        for (instanceId, sceneSnapshot) in exportSession.scenesByInstanceId {
            let sceneOverride = allStates[instanceId]?.backgroundOverride
            let effState = EffectiveBackgroundBuilder.build(
                templateBackground: sceneSnapshot.templateBackground,
                projectOverride: projectOverride,
                sceneOverride: sceneOverride,
                presetLibrary: runtime.session.backgroundPresetProvider
            )
            let snapshot = ExportBackgroundSnapshot.build(
                from: projectOverride,
                sceneOverride: sceneOverride,
                effectiveState: effState
            )
            result[instanceId] = SceneExportBackgroundData(
                state: effState,
                snapshot: snapshot
            )
        }
        return result
    }

    // MARK: - Settings Helpers

    private func makeExportOutputURL(prefix: String) -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let uuid8 = UUID().uuidString.prefix(8)
        let filename = "\(prefix)_\(timestamp)_\(uuid8).mp4"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    private func makeSingleSceneExportSettings(
        outputURL: URL,
        sizePx: (width: Int, height: Int),
        preset: VideoQualityPreset,
        fps: Int,
        audioPlan: AudioExportPlan
    ) -> VideoExportSettings {
        let bitrate = preset.bitrate(for: sizePx)
        return VideoExportSettings(
            outputURL: outputURL,
            sizePx: sizePx,
            fps: fps,
            bitrate: bitrate,
            clearColor: .opaqueBlack,
            audioPlan: audioPlan
        )
    }

    private func makeTimelineExportSettings(
        outputURL: URL,
        sizePx: (width: Int, height: Int),
        preset: VideoQualityPreset,
        fps: Int,
        audioPlan: AudioExportPlan
    ) -> VideoExporter.TimelineExportSettings {
        let bitrate = preset.bitrate(for: sizePx)
        return VideoExporter.TimelineExportSettings(
            outputURL: outputURL,
            sizePx: sizePx,
            fps: fps,
            bitrate: bitrate,
            audioPlan: audioPlan
        )
    }

    #if DEBUG
    // MARK: - CP6: AnimiEngineNext export (DEBUG only)

    /// Fail closed with a typed, visible export error and exit export mode. NO fallback to the old
    /// renderer (the Next flag was explicitly ON).
    private func failClosedNextExport(_ error: Error) async {
        logger.error("[Export][Next] Fail closed: \(String(describing: error))")
        await exitExportModeToIdle()
        clearActiveExportRequest()
        runtime.onOutput?(.exportRenderFailed(error))
    }

    /// Single-scene export through AnimiEngineNext. Builds inputs from the resolved `ExportMediaSnapshot`
    /// + live scene state (single-scene has no immutable session), decodes/assembles the Next context,
    /// and hands frames to `VideoExporter.exportVideoNext`. Supports photo + user-video media; fails
    /// closed on reduced size, custom background regions, overlays, or any `NextBridgeError`.
    private func runNextSingleSceneExport(
        ctx: EditorRuntimeMetalContext,
        exporter: VideoExporter,
        requestId: UUID,
        compiled: CompiledScene,
        sceneRuntime: SceneRuntime,
        settings: VideoExportSettings,
        mediaSnapshot: ExportMediaSnapshot,
        bgSnapshot: ExportBackgroundSnapshot?,
        exportSizePx: (width: Int, height: Int),
        originalSizePx: (width: Int, height: Int),
        budget: ExportResourceBudget
    ) async {
        // Fail-closed guards (no silent omission).
        guard exportSizePx == originalSizePx else {
            await failClosedNextExport(NextBridgeError.engine("Next export has no downscale; preflight reduced size \(originalSizePx) → \(exportSizePx)"))
            return
        }
        // CP7: video media is now supported (resolved per-frame to BGRA8). No video fail-close here.
        guard (bgSnapshot?.regionRefs.isEmpty ?? true) else {
            await failClosedNextExport(NextBridgeError.engine("custom background regions unsupported by Next export"))
            return
        }

        guard let state = runtime.session.state else {
            await failClosedNextExport(NextBridgeError.noScene); return
        }
        let timeline = state.draft.canonicalTimeline
        // Overlays (text/sticker) are unsupported — fail closed if present.
        if let overlayItems = timeline.overlayTrack?.items, !overlayItems.isEmpty {
            await failClosedNextExport(NextBridgeError.engine("text/sticker overlays unsupported by Next export"))
            return
        }
        guard let sceneItem = timeline.sceneItems.first,
              case let .scene(scenePayload)? = timeline.payloads[sceneItem.payloadId] else {
            await failClosedNextExport(NextBridgeError.notASceneItem); return
        }
        let sceneTypeId = scenePayload.sceneTypeId
        guard let folderURL = runtime.nextSceneFolderURL(sceneTypeId: sceneTypeId) else {
            await failClosedNextExport(NextBridgeError.sceneFolderMissing(sceneTypeId: sceneTypeId)); return
        }
        let sceneState = state.draft.sceneInstanceStates[sceneItem.id] ?? .empty

        // Build inputs → session → decode → assemble (synchronous bridge calls).
        let preparedContext: NextPreparedContext
        let sessionBox: NextSessionBox
        do {
            // CP7 stretch guard: scene timeline span in frames (export fps == settings.fps).
            let timelineFrames = Int((sceneItem.durationUs &* Int64(settings.fps)) / 1_000_000)
            let inputs = try NextExportInputsBuilder.makeSingleScene(
                sceneTypeId: sceneTypeId, sceneFolderURL: folderURL,
                sceneState: sceneState, mediaSnapshot: mediaSnapshot, frameIndex: 0,
                timelineDurationFrames: timelineFrames)
            sessionBox = try NextSingleSceneBridge.makeSession(device: ctx.device)
            let decoded = try NextSingleSceneBridge.decodeMedia(inputs)
            let placementByBlockID = Dictionary(uniqueKeysWithValues: inputs.blocks.map { ($0.blockID, $0.placement) })
            preparedContext = try NextSingleSceneBridge.assemble(
                decoded: decoded, placementByBlockID: placementByBlockID, sessionBox: sessionBox)
        } catch {
            await failClosedNextExport(error)
            return
        }

        guard isActiveExportRequest(requestId) else { return }

        let nextSettings = NextExportVideoSettings(
            outputURL: settings.outputURL, sizePx: settings.sizePx, fps: settings.fps,
            bitrate: settings.bitrate, gopSeconds: settings.gopSeconds)

        // CP7: include user-video-slot audio (trim/volume/mute) from the resolved snapshot — matches
        // the OLD single-scene export's audio contract. Empty for photo-only scenes.
        let videoSelectionsByBlockId: [String: VideoSelection] = mediaSnapshot.videoRefs.reduce(into: [:]) {
            $0[$1.blockId] = $1.selection
        }

        exporter.exportVideoNext(
            preparedContext: preparedContext, sessionBox: sessionBox, sceneRuntime: sceneRuntime,
            settings: nextSettings, audioPlan: settings.audioPlan,
            totalFrames: sceneRuntime.durationFrames,
            videoSelectionsByBlockId: videoSelectionsByBlockId,
            budget: budget,
            onFinishing: { [weak self] in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.runtime.onOutput?(.exportFinishing)
            },
            progress: { [weak self] progress in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.runtime.onOutput?(.exportProgress(Float(progress)))
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.handleExportCompletion(result: result, requestId: requestId)
            })
    }

    /// Timeline export through AnimiEngineNext, sourced PURELY from the immutable `TimelineExportSession`
    /// (snapshot-stable; live state is not read here). Supports photo + user-video media; fails closed
    /// on reduced size, custom background regions, overlays, or any `NextBridgeError`/transition error.
    private func runNextTimelineExport(
        ctx: EditorRuntimeMetalContext,
        exporter: VideoExporter,
        requestId: UUID,
        tlSession: TimelineCompositionEngine.TimelineExportSession,
        settings: VideoExporter.TimelineExportSettings,
        exportSizePx: (width: Int, height: Int),
        originalSizePx: (width: Int, height: Int),
        backgroundRegionCount: Int,
        budget: ExportResourceBudget
    ) async {
        guard exportSizePx == originalSizePx else {
            await failClosedNextExport(NextBridgeError.engine("Next export has no downscale; preflight reduced size \(originalSizePx) → \(exportSizePx)"))
            return
        }
        guard backgroundRegionCount == 0 else {
            await failClosedNextExport(NextBridgeError.engine("custom background regions unsupported by Next export"))
            return
        }
        if !tlSession.overlaySnapshot.textItems.isEmpty || !tlSession.overlaySnapshot.stickerItems.isEmpty {
            await failClosedNextExport(NextBridgeError.engine("text/sticker overlays unsupported by Next export"))
            return
        }
        // CP7: per-scene video media is now supported (resolved per-frame to BGRA8). No video fail-close.

        // CP7 fix: a SINGLE-scene project still routes here (export route = timeline whenever the
        // timeline engine is active, regardless of scene count), but the Next TIMELINE bridge requires
        // >= 2 scenes (one scene must use the single-scene path — mirrors the preview contract in
        // `EditorViewController.makeNextBridgeInputs`). Route a 1-scene session to the single-scene Next
        // export instead of failing with `multiSceneUnsupported`.
        if tlSession.transitionMath.sceneItems.count < 2 {
            await runNextSingleSceneExportFromTimelineSession(
                ctx: ctx, exporter: exporter, requestId: requestId,
                tlSession: tlSession, settings: settings, budget: budget)
            return
        }

        let preparedContext: NextTimelinePreparedContext
        let sessionBox: NextSessionBox
        do {
            // Nominal start frame is irrelevant to a full export (the runner maps each compressed
            // frame to nominal itself); pass 0 as the inputs' nominal seed.
            let inputs = try NextExportInputsBuilder.makeTimeline(
                session: tlSession,
                sceneFolderURL: { [weak self] in self?.runtime.nextSceneFolderURL(sceneTypeId: $0) },
                nominalFrameIndex: 0)
            sessionBox = try NextSingleSceneBridge.makeSession(device: ctx.device)
            let decoded = try NextTimelineBridge.decodeTimeline(inputs)
            preparedContext = try NextTimelineBridge.assembleTimeline(
                decoded: decoded, inputs: inputs, sessionBox: sessionBox)
        } catch {
            await failClosedNextExport(error)
            return
        }

        guard isActiveExportRequest(requestId) else { return }

        let nextSettings = NextExportVideoSettings(
            outputURL: settings.outputURL, sizePx: settings.sizePx, fps: settings.fps,
            bitrate: settings.bitrate, gopSeconds: settings.gopSeconds)

        exporter.exportTimelineNext(
            preparedContext: preparedContext, sessionBox: sessionBox, tlSession: tlSession,
            settings: nextSettings, audioPlan: settings.audioPlan,
            budget: budget,
            onFinishing: { [weak self] in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.runtime.onOutput?(.exportFinishing)
            },
            progress: { [weak self] progress in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.runtime.onOutput?(.exportProgress(Float(progress)))
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.handleExportCompletion(result: result, requestId: requestId)
            })
    }

    /// CP7: single-scene Next export driven from the immutable 1-scene timeline session. The export
    /// route is "timeline" (the timeline engine is active) but a 1-scene project must use the
    /// single-scene Next path — the >= 2-scene timeline bridge rejects one scene. Snapshot-stable:
    /// inputs come from the lone `TimelineExportSceneSnapshot`, not live state.
    private func runNextSingleSceneExportFromTimelineSession(
        ctx: EditorRuntimeMetalContext,
        exporter: VideoExporter,
        requestId: UUID,
        tlSession: TimelineCompositionEngine.TimelineExportSession,
        settings: VideoExporter.TimelineExportSettings,
        budget: ExportResourceBudget
    ) async {
        guard let item = tlSession.transitionMath.sceneItems.first,
              let snap = tlSession.scenesByInstanceId[item.id] else {
            await failClosedNextExport(NextBridgeError.noScene); return
        }
        guard let folderURL = runtime.nextSceneFolderURL(sceneTypeId: snap.sceneTypeId) else {
            await failClosedNextExport(NextBridgeError.sceneFolderMissing(sceneTypeId: snap.sceneTypeId)); return
        }

        let preparedContext: NextPreparedContext
        let sessionBox: NextSessionBox
        do {
            // CP7 stretch guard: scene timeline span in frames (from the immutable session item).
            let timelineFrames = Int((item.durationUs &* Int64(settings.fps)) / 1_000_000)
            let inputs = try NextExportInputsBuilder.makeSingleScene(
                snapshot: snap, sceneFolderURL: folderURL, frameIndex: 0,
                timelineDurationFrames: timelineFrames)
            sessionBox = try NextSingleSceneBridge.makeSession(device: ctx.device)
            let decoded = try NextSingleSceneBridge.decodeMedia(inputs)
            let placementByBlockID = Dictionary(uniqueKeysWithValues: inputs.blocks.map { ($0.blockID, $0.placement) })
            preparedContext = try NextSingleSceneBridge.assemble(
                decoded: decoded, placementByBlockID: placementByBlockID, sessionBox: sessionBox)
        } catch {
            await failClosedNextExport(error)
            return
        }

        guard isActiveExportRequest(requestId) else { return }

        let nextSettings = NextExportVideoSettings(
            outputURL: settings.outputURL, sizePx: settings.sizePx, fps: settings.fps,
            bitrate: settings.bitrate, gopSeconds: settings.gopSeconds)

        exporter.exportVideoNext(
            preparedContext: preparedContext, sessionBox: sessionBox, sceneRuntime: snap.runtime,
            settings: nextSettings, audioPlan: settings.audioPlan,
            totalFrames: snap.runtime.durationFrames,
            videoSelectionsByBlockId: snap.videoSelections,
            budget: budget,
            onFinishing: { [weak self] in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.runtime.onOutput?(.exportFinishing)
            },
            progress: { [weak self] progress in
                guard let self, self.isActiveExportRequest(requestId) else { return }
                self.runtime.onOutput?(.exportProgress(Float(progress)))
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.handleExportCompletion(result: result, requestId: requestId)
            })
    }
    #endif
}
