import UIKit
import MetalKit
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorBootstrap")

/// Owns session/runtime bootstrap, store wiring, and scene loading.
@MainActor
internal final class EditorBootstrapController {
    unowned let viewController: EditorViewController

    // MARK: - Stored State

    var hasDeferredMissingMediaNotice: Bool {
        get { viewController.hasDeferredMissingMediaNotice }
        set { viewController.hasDeferredMissingMediaNotice = newValue }
    }

    var preparingTask: Task<Void, Never>?
    var currentRequestId: UUID?

    #if DEBUG
    private var debugPrepareStartNs: UInt64 = 0
    private var debugPrepareSceneTypeId: String = ""
    #endif

    init(viewController: EditorViewController) {
        self.viewController = viewController
    }

    private func log(_ message: String) {
        logger.info("\(message)")
    }

    // MARK: - Session Output

    func handleSessionOutput(_ output: EditorSessionOutput) {
        let vc = viewController
        switch output {
        case .bootstrapSucceeded(let editor):
            vc.sceneLibrarySnapshot = editor.sceneLibrary
            loadSceneTypeFromBundle(sceneTypeId: editor.firstSceneTypeId)

        case .bootstrapFailed(let msg):
            vc.loadingState = .failed(message: msg)
            updateLoadingStateUI()

        case .missingMediaDetected:
            if vc.viewIfLoaded?.window != nil, vc.loadingState == .ready {
                flushMissingMediaNoticeIfNeeded()
            } else {
                hasDeferredMissingMediaNotice = true
            }
        }
    }

    // MARK: - Missing Media Notice

    func flushMissingMediaNoticeIfNeeded() {
        let vc = viewController
        guard hasDeferredMissingMediaNotice || vc.session.hasPendingMissingMediaNotice else { return }
        hasDeferredMissingMediaNotice = false
        guard let summary = vc.session.missingMediaSummary, summary.hasFailedMedia else { return }
        let count = summary.failedSlots.count
        let message = count == 1
            ? "1 media file could not be restored. The affected slot will appear empty."
            : "\(count) media files could not be restored. Affected slots will appear empty."
        let alert = UIAlertController(
            title: "Missing Media",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        vc.present(alert, animated: true) { [weak vc] in
            vc?.session.markMissingMediaNoticePresented()
        }
    }

    // MARK: - Editor Timeline Configuration

    func configureEditorTimeline(
        loadResult: EditorRuntime.InitialSceneLoadResult
    ) {
        let vc = viewController
        let fps = vc.sceneLibrarySnapshot?.fps ?? Int(loadResult.compiled.runtime.fps)

        guard let state = vc.session.state else {
            log("[Release v1] configureEditorTimeline: session state is nil")
            return
        }

        wireStoreCallbacks()
        configureTimelineUI(state: state, fps: fps)
        bootRuntime(loadResult: loadResult, state: state)
        setupSceneEditModule(loadResult: loadResult)

        #if DEBUG
        vc.assertBootstrapInvariant_runtimeBeforeModule()
        #endif
    }

    /// Configures timeline UI from current editor state.
    func configureTimelineUI(state: EditorState, fps: Int) {
        let vc = viewController
        log("[Release v1] Timeline configured: \(state.sceneItems.count) scenes, duration=\(state.projectDurationUs)us")

        let scenes = state.canonicalTimeline.toSceneDrafts()
        let boundaries = state.canonicalTimeline.toSceneBoundaryDrafts()
        vc.editorLayoutContainer.configure(
            scenes: scenes,
            boundaries: boundaries,
            templateFPS: fps,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )
        vc.timelineController.syncTimelineSupplementalUI(state: state)
    }

    // MARK: - Store Callbacks

    func wireStoreCallbacks() {
        let vc = viewController
        var callbacks = EditorStoreCallbacks()
        callbacks.onPlayheadChanged = { [weak vc] cf in
            guard let vc else { return }
            if vc.runtime?.isPlaying != true {
                vc.runtime?.handlePlayheadChanged(cf)
            }
            if let mapper = vc.session.state?.makePlayheadMapper() {
                vc.editorLayoutContainer.setCurrentCompressedFrame(cf, mapper: mapper)
            }
        }
        callbacks.onSelectionChanged = { [weak vc] sel in vc?.timelineController.handleSelectionChanged(sel) }
        callbacks.onTimelineChanged = { [weak vc] st in
            vc?.timelineController.handleTimelineChanged(st)
            vc?.runtime?.setupTimelineCompositionEngine(state: st)
        }
        callbacks.onTimelinePreviewChanged = { [weak vc] st in vc?.timelineController.handleTimelinePreviewChanged(st) }
        callbacks.onUndoRedoChanged = { [weak vc] canUndo, canRedo in vc?.timelineController.handleUndoRedoChanged(canUndo: canUndo, canRedo: canRedo) }
        callbacks.onUIModeChanged = { [weak vc] mode in vc?.sceneEditModule?.handleUIModeChanged(mode) }
        callbacks.onSelectedBlockChanged = { [weak vc] blockId in vc?.sceneEditModule?.handleSelectedBlockChanged(blockId) }
        callbacks.onStateRestoredFromUndoRedo = { [weak vc] in
            vc?.sceneEditModule?.handleStateRestoredFromUndoRedo(
                cancelIngests: { vc?.mediaIngestCoordinator.cancelAll() }
            )
        }
        callbacks.onSceneStateChanged = { [weak vc] instanceId, sceneState in vc?.timelineController.handleSceneStateChanged(instanceId: instanceId, sceneState: sceneState) }
        callbacks.onVideoSelectionChanged = { [weak vc] instanceId, blockId, selection in
            vc?.sceneEditModule?.handleVideoSelectionChanged(instanceId: instanceId, blockId: blockId, selection: selection)
        }
        callbacks.onMediaPlacementChanged = { [weak vc] instanceId, blockId, placement in
            vc?.sceneEditModule?.handleMediaPlacementChanged(instanceId: instanceId, blockId: blockId, placement: placement)
        }
        callbacks.onMediaVisibilityChanged = { [weak vc] instanceId, blockId, visible in
            vc?.sceneEditModule?.handleMediaVisibilityChanged(instanceId: instanceId, blockId: blockId, visible: visible)
        }
        callbacks.onMediaSlotChanged = { [weak vc] instanceId, blockId, slot in
            vc?.sceneEditModule?.handleMediaSlotChanged(instanceId: instanceId, blockId: blockId, slot: slot)
        }
        callbacks.onNotice = { [weak vc] notice in vc?.presentationController_.handleEditorNotice(notice) }
        vc.session.setStoreCallbacks(callbacks)
    }

    // MARK: - Scene Edit Module Setup

    func setupSceneEditModule(loadResult: EditorRuntime.InitialSceneLoadResult) {
        let vc = viewController
        guard let rt = vc.runtime else {
            assertionFailure("[PR9] setupSceneEditModule called before runtime was created")
            return
        }
        let module = SceneEditToolModule(
            runtime: rt,
            session: vc.session,
            overlayView: vc.overlayView,
            ingestStatusOverlayView: vc.ingestStatusOverlayView
        )
        module.delegate = vc
        module.getRawIngestStatus = { [weak vc] in vc?.mediaIngestCoordinator.slotStatus ?? [:] }
        module.cancelIngestForSlot = { [weak vc] key in vc?.mediaIngestCoordinator.cancelIngest(for: key) }
        module.cancelAllIngestsForScene = { [weak vc] id in vc?.mediaIngestCoordinator.cancelAll(for: id) }
        module.setupInteractionController(loadResult: loadResult)
        module.wireLayoutCallbacks(container: vc.editorLayoutContainer)
        vc.sceneEditModule = module
    }

    // MARK: - Boot Runtime

    func bootRuntime(loadResult: EditorRuntime.InitialSceneLoadResult, state: EditorState) {
        #if DEBUG
        let bootStartNs = DispatchTime.now().uptimeNanoseconds
        #endif
        let vc = viewController
        let library = vc.sceneLibrarySnapshot!
        let rt = EditorRuntime(session: vc.session)
        let audioManager = AudioSessionManager()
        rt.audioSessionManager = audioManager
        rt.bindAudioSessionEvents(audioManager)
        rt.onOutput = { [weak vc] output in vc?.bootstrapController.handleRuntimeOutput(output) }
        rt.rendererResourceTrimmer = { [weak vc] policy in
            vc?.trimRendererTransientResources(policy: policy)
        }
        vc.runtime = rt

        if let device = vc.metalDevice, let queue = vc.commandQueue {
            let metalCtx = EditorRuntimeMetalContext(device: device, commandQueue: queue, colorPixelFormat: vc.metalColorPixelFormat)
            rt.configureAndBoot(
                metalContext: metalCtx,
                library: library,
                loadResult: loadResult,
                editorState: state
            )
        }

        #if DEBUG
        rt.debugTexturePoolSnapshotProvider = { [weak vc] in
            vc?.debugRenderer?.debugTexturePoolSnapshot()
        }
        #endif

        let mapper = state.makePlayheadMapper()
        vc.editorLayoutContainer.setMapper(mapper)

        #if DEBUG
        let bootSec = Double(DispatchTime.now().uptimeNanoseconds - bootStartNs) / 1_000_000_000.0
        MemoryDiagnostics.event("bootstrap.boot.summary", String(format: "duration=%.2fs", bootSec))
        rt.assertBootInvariants(uiMode: state.uiMode)
        MemoryDiagnostics.checkpoint("editor.boot.after", metal: vc.metalDevice)
        #endif
    }

    // MARK: - Runtime Output Handling

    func handleRuntimeOutput(_ output: EditorRuntimeOutput) {
        let vc = viewController
        switch output {
        case .renderSourceUpdated:
            vc.requestRender()

        case .playbackStateChanged(let isPlaying):
            vc.presentationController_.handlePlaybackStateChanged(isPlaying)

        case .sceneEditActivated:
            vc.sceneEditModule?.handleSceneEditActivated()
            vc.requestMetalRender()

        case .sceneEditDeactivated:
            break

        case .exportStarted:
            vc.exportFlowController.handleExportStarted()

        case .exportPreflightRecommendation(let result):
            vc.exportFlowController.handleExportPreflightRecommendation(result)

        case .exportProgress(let p):
            vc.exportFlowController.handleExportProgress(p)

        case .exportFinishing:
            vc.exportFlowController.handleExportFinishing()

        case .exportRenderSucceeded(let url):
            vc.exportFlowController.handleExportRenderSucceeded(url)

        case .exportRenderFailed(let error):
            vc.exportFlowController.handleExportRenderFailed(error)

        case .exportCancelled:
            vc.exportFlowController.handleExportCancelled()

        case .exportDeliveryShareHandoff(let fileURL):
            vc.exportFlowController.handleExportDeliveryShareHandoff(fileURL)

        case .exportDeliveryCompleted(let outcome):
            vc.exportFlowController.handleExportDeliveryCompleted(outcome)

        case .runtimeReady:
            break

        case .runtimeFailed(let msg):
            vc.presentationController_.presentRuntimeFailedAlert(msg)

        case .presentError(let msg):
            vc.presentationController_.presentGenericErrorAlert(msg)
        }
    }

    // MARK: - Loading State UI

    func updateLoadingStateUI() {
        let vc = viewController
        switch vc.loadingState {
        case .idle:
            vc.preparingOverlay.hide()
        case .preparing:
            vc.preparingOverlay.reset()
            vc.preparingOverlay.show(text: "Loading template...")
        case .ready:
            vc.preparingOverlay.hide()
        case .failed(let message):
            vc.preparingOverlay.showError(message)
        }
    }

    // MARK: - Scene Type Loading

    func loadSceneTypeFromBundle(sceneTypeId: String) {
        let vc = viewController
        vc.runtime?.stopPlayback()
        vc.renderErrorLogged = false
        log("---\n[Release v1] Loading scene type '\(sceneTypeId)'...")

        guard let device = vc.metalDevice else {
            log("ERROR: No Metal device")
            vc.loadingState = .failed(message: "No Metal device")
            updateLoadingStateUI()
            return
        }

        guard let sceneDescriptor = vc.sceneLibrarySnapshot?.scene(byId: sceneTypeId),
              let sceneURL = sceneDescriptor.folderURL else {
            log("ERROR: Scene type '\(sceneTypeId)' not found in library")
            vc.loadingState = .failed(message: "Scene not found")
            updateLoadingStateUI()
            return
        }

        preparingTask?.cancel()

        let requestId = UUID()
        currentRequestId = requestId
        vc.loadingState = .preparing(requestId: requestId)
        updateLoadingStateUI()

        #if DEBUG
        MemoryDiagnostics.event("bootstrap.prepare.start", "requestId=\(requestId) sceneTypeId=\(sceneTypeId) obj=\(ObjectIdentifier(vc).hashValue)")
        vc.bootstrapController.debugPrepareStartNs = DispatchTime.now().uptimeNanoseconds
        vc.bootstrapController.debugPrepareSceneTypeId = sceneTypeId
        #endif

        preparingTask = Task { [weak vc] in
            guard let vc = vc else { return }

            do {
                try Task.checkCancellation()

                guard let queue = await MainActor.run(body: { vc.commandQueue }) else { return }

                #if DEBUG
                let loadStartNs = DispatchTime.now().uptimeNanoseconds
                #endif
                let loadResult = try await EditorRuntime.loadInitialScene(
                    sceneTypeId: sceneTypeId,
                    sceneURL: sceneURL,
                    device: device,
                    commandQueue: queue,
                    onStatus: { [weak vc] status in
                        vc?.preparingOverlay.setStatus(status)
                    }
                )
                #if DEBUG
                let loadEndNs = DispatchTime.now().uptimeNanoseconds
                let loadSec = Double(loadEndNs - loadStartNs) / 1_000_000_000.0
                await MainActor.run {
                    MemoryDiagnostics.event(
                        "bootstrap.load.summary",
                        String(format: "sceneTypeId=%@ duration=%.2fs", sceneTypeId, loadSec)
                    )
                }
                #endif

                guard !Task.isCancelled, vc.bootstrapController.currentRequestId == requestId else {
                    #if DEBUG
                    await MainActor.run {
                        MemoryDiagnostics.event("bootstrap.prepare.discardStale", "requestId=\(requestId)")
                    }
                    #endif
                    return
                }

                #if DEBUG
                await MainActor.run {
                    MemoryDiagnostics.event("bootstrap.prepare.loaded", "requestId=\(requestId)")
                }
                #endif

                await MainActor.run {
                    vc.bootstrapController.applyLoadedSceneType(
                        loadResult: loadResult,
                        requestId: requestId
                    )
                }

            } catch is CancellationError {
                #if DEBUG
                await MainActor.run {
                    MemoryDiagnostics.event("bootstrap.prepare.cancel", "requestId=\(requestId)")
                }
                #endif
                await MainActor.run { logger.info("Scene load cancelled") }
            } catch {
                guard vc.bootstrapController.currentRequestId == requestId else {
                    #if DEBUG
                    await MainActor.run {
                        MemoryDiagnostics.event("bootstrap.prepare.discardStale", "requestId=\(requestId) (error: \(error.localizedDescription))")
                    }
                    #endif
                    return
                }
                await MainActor.run {
                    logger.info("ERROR: Failed to load scene: \(error)")
                    vc.loadingState = .failed(message: "Failed to load scene")
                    vc.bootstrapController.updateLoadingStateUI()
                }
            }
        }
    }

    func applyLoadedSceneType(
        loadResult: EditorRuntime.InitialSceneLoadResult,
        requestId: UUID
    ) {
        #if DEBUG
        let applyStartNs = DispatchTime.now().uptimeNanoseconds
        #endif
        let vc = viewController
        guard currentRequestId == requestId else {
            #if DEBUG
            MemoryDiagnostics.event("bootstrap.prepare.discardStale", "requestId=\(requestId) (apply)")
            #endif
            log("Scene load result discarded")
            return
        }
        #if DEBUG
        MemoryDiagnostics.event("bootstrap.prepare.apply", "requestId=\(requestId) obj=\(ObjectIdentifier(vc).hashValue)")
        #endif

        if let stats = loadResult.preloadStats {
            log(String(format: "[Preload] loaded: %d, missing: %d, skipped: %d, duration: %.1fms",
                       stats.loadedCount, stats.missingCount, stats.skippedBindingCount, stats.durationMs))
        }

        let sceneRuntime = loadResult.compiled.runtime
        let canvasSize = sceneRuntime.canvasSize
        let canvasSizeStr = "\(Int(canvasSize.width))x\(Int(canvasSize.height))"
        log("[Release v1] Scene loaded: \(canvasSizeStr) @ \(sceneRuntime.fps)fps, \(sceneRuntime.durationFrames) frames")

        configureEditorTimeline(loadResult: loadResult)

        vc.loadingState = .ready
        updateLoadingStateUI()

        if vc.viewIfLoaded?.window != nil {
            flushMissingMediaNoticeIfNeeded()
        }

        vc.requestRender()

        #if DEBUG
        let applySec = Double(DispatchTime.now().uptimeNanoseconds - applyStartNs) / 1_000_000_000.0
        MemoryDiagnostics.event("bootstrap.apply.summary", String(format: "duration=%.2fs", applySec))
        let prepareTotalSec = Double(DispatchTime.now().uptimeNanoseconds - debugPrepareStartNs) / 1_000_000_000.0
        MemoryDiagnostics.event(
            "bootstrap.prepare.summary",
            String(format: "sceneTypeId=%@ duration=%.2fs outcome=success",
                   debugPrepareSceneTypeId, prepareTotalSec)
        )
        #endif
    }
}
