import UIKit
import MetalKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import TVECore
import os.log

private let logger = Logger(subsystem: "com.animi.app", category: "EditorViewController")

// MARK: - PR-D: Template Loading State

/// State machine for template loading (PR-D: async load + "Preparing" UI).
enum TemplateLoadingState: Equatable {
    case idle
    case preparing(requestId: UUID)
    case ready
    case failed(message: String)

    static func == (lhs: TemplateLoadingState, rhs: TemplateLoadingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.ready, .ready):
            return true
        case (.preparing(let a), .preparing(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Main editor view controller with Metal rendering surface.
/// PR-E: Production-only editor mode (dev-UI removed).
final class EditorViewController: UIViewController {

    // MARK: - Runtime

    private var runtime: EditorRuntime?

    // MARK: - Session

    private let session: EditorSession
    /// True when session emitted a missing-media notice that hasn't been presented yet.
    /// At flush time we read the live `session.missingMediaSummary` to avoid stale counts.
    private var hasDeferredMissingMediaNotice = false

    init(session: EditorSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        autosaveCoordinator?.stopFromDeinit()
        NotificationCenter.default.removeObserver(self, name: .appDidEnterBackground, object: nil)
        // Defense-in-depth: cancel ingest tasks even if viewWillDisappear was somehow skipped.
        // Uses nonisolated helper since deinit cannot call @MainActor methods.
        //
        // IMPORTANT: Only cancel if the coordinator was already created. Touching
        // the lazy accessor from deinit would trigger first-time initialization,
        // which forms `[weak self]` closures against a deallocating instance and
        // crashes with "Cannot form weak reference to instance ... is in the
        // process of deallocation." Tests that construct a PVC and immediately
        // let it deinit (e.g. `AppCompositionRootTests`) hit exactly this path.
        _mediaIngestCoordinator?.cancelAllFromDeinit()
    }

    @objc private func appDidEnterBackground() {
        if !userMadeExplicitCloseChoice {
            autosaveCoordinator?.handleBackgrounding()
        }
    }

    // MARK: - Export State (owned by EditorRuntime)

    /// Convenience: delegates to runtime for request-scoped gating.
    private var isExporting: Bool { runtime?.isExporting ?? false }

    // MARK: - Metal View

    private lazy var metalView: MTKView = {
        let mtkView = MTKView()
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.layer.cornerRadius = 8
        mtkView.clipsToBounds = true
        mtkView.delegate = self
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        return mtkView
    }()

    // MARK: - Rendering

    private lazy var commandQueue: MTLCommandQueue? = { metalView.device?.makeCommandQueue() }()
    private var renderer: MetalRenderer?


    // MARK: - Scrub Render Throttle (A/B Testing)
    /// True when user is actively dragging the timeline scrubber
    private var isScrubDragging = false
    /// Last time we triggered a Metal render during scrub drag
    private var lastScrubRenderAt: CFTimeInterval = 0
    /// True if a render was skipped due to throttle and needs to be done on .ended
    private var pendingScrubRender = false
    private var renderErrorLogged = false
    private var deviceHeaderLogged = false

    // MARK: - Release v1: Scene Library
    private var sceneLibrarySnapshot: SceneLibrarySnapshot?
    private var defaultSceneSequence: [SceneTypeDefault] = []

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

    /// Write-target for scene-edit persistence: delegates to the static resolver.
    private var sceneEditTargetInstanceId: UUID? {
        guard let uiMode = session.state?.uiMode else { return nil }
        return Self.resolveWriteTargetForSceneEdit(
            uiMode: uiMode,
            activeSceneInstanceId: runtime?.currentActiveSceneInstanceId
        )
    }

    private func assertSceneEditTargetMatchesRuntimeIfPossible() {
        #if DEBUG
        // Activation in progress — divergence is expected
        guard runtime?.currentSceneEditReadyInstanceId != nil else { return }
        guard let target = sceneEditTargetInstanceId,
              let runtimeId = runtime?.currentActiveSceneInstanceId,
              target != runtimeId else { return }
        logger.debug("[BUG-GUARD] sceneEditTargetInstanceId (\(target)) != activeSceneInstanceId (\(runtimeId))")
        assertionFailure("[BUG-GUARD] Scene edit target diverged from runtime active scene")
        #endif
    }

    /// Inline video trim coordinator — owns trim state and methods.
    private lazy var videoTrimCoordinator: InlineVideoTrimCoordinator = {
        let coord = InlineVideoTrimCoordinator()
        coord.getRuntime = { [weak self] in self?.runtime }
        coord.getSession = { [weak self] in self?.session }
        coord.getSceneEditTargetInstanceId = { [weak self] in self?.sceneEditTargetInstanceId }
        coord.getEditorLayoutContainer = { [weak self] in self?.editorLayoutContainer }
        coord.onSyncPausedVideoStill = { [weak self] force in self?.syncPausedVideoStill(force: force) }
        coord.onUpdateSceneEditBottomBar = { [weak self] blockId in
            self?.editorLayoutContainer.updateSceneEditBottomBar(selectedBlockId: blockId)
        }
        coord.onUpdateMediaBlockActionBar = { [weak self] in self?.updateMediaBlockActionBarForSelectedBlock() }
        coord.onPresentAlert = { [weak self] alert in self?.present(alert, animated: true) }
        return coord
    }()

    // MARK: - PR2: Visual Editor Timeline
    /// Tracks whether user made explicit Save/Don't Save choice (prevents double-save in viewWillDisappear).
    private var userMadeExplicitCloseChoice = false
    /// Periodic autosave coordinator (crash recovery safety net).
    private var autosaveCoordinator: EditorAutosaveCoordinator?
    private lazy var editorLayoutContainer = EditorLayoutContainerView()
    private weak var fullScreenPreviewVC: FullScreenPreviewViewController?

    // MARK: - User Media (PR-32)
    private lazy var overlayView = EditorOverlayView()
    private lazy var overlayPositionDrag = OverlayPositionDragView()

    // MARK: - Scene Edit Mode (PR-D)
    private var sceneEditController: SceneEditInteractionController?

    // MARK: - Background (PR3)
    private var currentProjectId: UUID?
    private var currentTemplateId: String?
    private var pendingBackgroundRegionId: String?
    private weak var pendingBackgroundEditor: BackgroundEditorViewController?
    /// Media ingest coordinator — handles PHPicker → prepare → persist → bind pipeline.
    /// Initialized once on VC lifecycle, not lazily in delegate callback.
    private var showsMediaIngestStatusOverlay = true
    private var showsMediaIngestStatusInActionBar = true
    private lazy var ingestStatusOverlayView = MediaIngestStatusOverlayView()
    private var ingestFailureAlertedKeys: Set<IngestSlotKey> = []

    // MARK: - PR5 Phase E: Asset Registry Bookkeeping Helper

    /// Unregisters an asset ID from the draft's registry ONLY if the fresh
    /// draft no longer references it anywhere (scene slots + background
    /// regions). Safe to call after any dispatch that may have removed or
    /// replaced a reference — idempotent in the "still referenced" case.
    ///
    /// Reads a fresh `session.state?.draft` snapshot at call time — callers
    /// must call this AFTER the dispatch that updated the draft, not before.
    /// PR5 Phase G: returns a self-healed `ProjectAssetRegistry` snapshot for
    /// the current draft. Use this whenever PVC is about to pass a registry
    /// snapshot into downstream code (locator resolution, texture load, engine
    /// setTimeline, export). Closes the undo-registry asymmetry gap: if a
    /// prior `.unregisterAssetBookkeeping` removed a descriptor whose content
    /// reference later came back via undo, the missing descriptor is
    /// re-synthesized from the live `MediaRef` for the duration of this call.
    ///
    /// Does NOT write back to `session.state?.draft.assetRegistry`. Session
    /// state remains unchanged; the healed snapshot is pure per-call.
    private func selfHealedRegistry() -> ProjectAssetRegistry {
        guard let draft = session.state?.draft else { return ProjectAssetRegistry() }
        return draft.assetRegistry.selfHealed(for: draft)
    }


    /// Explicit backing storage for `mediaIngestCoordinator`. The computed
    /// accessor below lazily constructs and installs the coordinator on first
    /// access. The backing storage is kept nil until then so that `deinit`
    /// can check `_mediaIngestCoordinator != nil` without triggering a
    /// dangerous first-time initialization during deallocation.
    ///
    /// PR5 Phase G: switched away from `private lazy var` because
    /// Swift's lazy property initializer runs on first access — including
    /// first access from `deinit`. The init block captures `[weak self]` to
    /// set up ingest callbacks, and taking a weak reference to a
    /// deallocating instance is a runtime crash ("Cannot form weak reference
    /// to instance ... is in the process of deallocation"). Explicit backing
    /// makes the "was it ever created?" check safe.
    private var _mediaIngestCoordinator: MediaIngestCoordinator?

    private var mediaIngestCoordinator: MediaIngestCoordinator {
        if let coordinator = _mediaIngestCoordinator {
            return coordinator
        }
        let assetStore = MediaAssetStore(mediaWriter: self.session.mediaWriter)
        let coordinator = MediaIngestCoordinator(assetStore: assetStore)
        // PR5 Phase E: Register the freshly ingested descriptor in the draft's
        // asset registry BEFORE the reducer sees the slot dispatch. This
        // ensures that downstream apply/restore paths resolve via the
        // registry-backed locator without hitting the legacy fallback.
        coordinator.onAssetPersisted = { [weak self] descriptor in
            self?.session.registerAssetBookkeeping(descriptor)
        }
        coordinator.onIngestComplete = { [weak self] result in
            guard let self else {
                // VC deallocated — clean up orphaned persisted file immediately
                try? FileManager.default.removeItem(at: result.persistedURL)
                return
            }
            Task { @MainActor [self] in
                await self.handleIngestComplete(result)
            }
        }
        coordinator.onStatusChanged = { [weak self] key, status in
            self?.handleIngestStatusChanged(key: key, status: status)
        }
        _mediaIngestCoordinator = coordinator
        return coordinator
    }

    /// Pending picker request — captures (sceneInstanceId, blockId) at picker open time.
    /// Consumed in PHPickerDelegate. The sceneInstanceId is the source of truth for
    /// which scene this media belongs to, NOT the current sceneEditTargetInstanceId at callback time.
    private var pendingPickerRequest: IngestSlotKey?

    // In-flight frame limiting (must match MetalRendererOptions.maxFramesInFlight)
    private static let maxFramesInFlight = 3
    private let inFlightSemaphore = DispatchSemaphore(value: maxFramesInFlight)

    // PR-A: renderQueue removed — no longer needed after warmRender removal.
    // draw(in:) is protected by dispatchPrecondition(.onQueue(.main)).

    // MARK: - PR-D: Async Template Loading
    private var loadingState: TemplateLoadingState = .idle
    private var preparingTask: Task<Void, Never>?
    private var currentRequestId: UUID?
    private lazy var preparingOverlay = PreparingOverlayView()

    // PR1.3: Performance logging (DEBUG only)
    #if DEBUG
    private let perfLogger = PerfLogger(intervalSeconds: 2.0)
    #endif

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupRenderer()
        setupEditorLayout()
        let deviceName = metalView.device?.name ?? "N/A"
        log("AnimiApp initialized, TVECore: \(TVECore.version), Metal: \(deviceName)")

        // Lifecycle observers for background save
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: .appDidEnterBackground, object: nil
        )

        // Autosave coordinator (crash recovery safety net, 30s interval)
        let coordinator = EditorAutosaveCoordinator(session: session)
        coordinator.start(interval: 30)
        autosaveCoordinator = coordinator

        // Wire session output and start bootstrap
        session.onOutput = { [weak self] output in
            self?.handleSessionOutput(output)
        }
        Task { @MainActor in
            await session.bootstrap()
        }
    }

    // MARK: - Session Output

    private func handleSessionOutput(_ output: EditorSessionOutput) {
        switch output {
        case .bootstrapSucceeded(let editor):
            currentTemplateId = editor.templateId
            currentProjectId = editor.draft.id
            sceneLibrarySnapshot = editor.sceneLibrary
            defaultSceneSequence = editor.defaultSceneSequence
            loadSceneTypeFromBundle(sceneTypeId: editor.firstSceneTypeId)

        case .bootstrapFailed(let msg):
            loadingState = .failed(message: msg)
            updateLoadingStateUI()

        case .missingMediaDetected:
            if viewIfLoaded?.window != nil, loadingState == .ready {
                flushMissingMediaNoticeIfNeeded()
            } else {
                hasDeferredMissingMediaNotice = true
            }
        }
    }

    // MARK: - PR2: Editor Layout Setup

    /// Sets up the editor layout container (PR-E: production editor only)
    private func setupEditorLayout() {
        // PR-E: Hide system navigation bar - we use EditorNavBar
        navigationController?.setNavigationBarHidden(true, animated: false)
        // Add editorLayoutContainer to view if not already added
        if editorLayoutContainer.superview == nil {
            editorLayoutContainer.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(editorLayoutContainer)
            NSLayoutConstraint.activate([
                editorLayoutContainer.topAnchor.constraint(equalTo: view.topAnchor),
                editorLayoutContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                editorLayoutContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                editorLayoutContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        // Embed metalView in editor layout
        editorLayoutContainer.embedMetalView(metalView)

        // PR-E: Embed overlayView for gesture handling in Scene Edit
        editorLayoutContainer.embedOverlayView(overlayView)

        // PR9: Embed text position overlay for canvas drag
        editorLayoutContainer.embedOverlayPositionDrag(overlayPositionDrag)

        // Phase 6: Embed ingest status overlay (above outline overlay, below menuStrip)
        editorLayoutContainer.embedStatusOverlayView(ingestStatusOverlayView)

        // PR-E: Add preparingOverlay for loading states
        preparingOverlay.translatesAutoresizingMaskIntoConstraints = false
        editorLayoutContainer.addSubview(preparingOverlay)
        NSLayoutConstraint.activate([
            preparingOverlay.topAnchor.constraint(equalTo: editorLayoutContainer.topAnchor),
            preparingOverlay.leadingAnchor.constraint(equalTo: editorLayoutContainer.leadingAnchor),
            preparingOverlay.trailingAnchor.constraint(equalTo: editorLayoutContainer.trailingAnchor),
            preparingOverlay.bottomAnchor.constraint(equalTo: editorLayoutContainer.bottomAnchor),
        ])

        // PR-E: Setup gesture recognizers on overlayView for Scene Edit interaction
        setupOverlayGestureRecognizers()

        // Wire callbacks
        wireEditorLayoutCallbacks()
    }

    /// Sets up gesture recognizers on overlayView for Scene Edit mode
    private func setupOverlayGestureRecognizers() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(overlayViewTapped(_:)))
        overlayView.addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))

        // PR-E: Assign delegate for gesture gating (sceneEdit + selectedBlock) and simultaneous pinch+rotate
        panGesture.delegate = self
        pinchGesture.delegate = self
        rotationGesture.delegate = self

        overlayView.addGestureRecognizer(panGesture)
        overlayView.addGestureRecognizer(pinchGesture)
        overlayView.addGestureRecognizer(rotationGesture)
    }

    /// Wires callbacks from EditorLayoutContainerView
    private func wireEditorLayoutCallbacks() {
        editorLayoutContainer.onClose = { [weak self] in
            self?.handleEditorClose()
        }

        editorLayoutContainer.onExport = { [weak self] in
            self?.exportTapped()
        }

        // PR-F: Undo/Redo
        editorLayoutContainer.onUndo = { [weak self] in
            self?.session.dispatch(.undo)
        }

        editorLayoutContainer.onRedo = { [weak self] in
            self?.session.dispatch(.redo)
        }

        editorLayoutContainer.onPlayPause = { [weak self] in
            self?.playPauseTapped()
        }

        editorLayoutContainer.onFullScreenPreview = { [weak self] in
            self?.handleFullScreenPreview()
        }

        // PR1: Unified timeline event handling
        editorLayoutContainer.onTimelineEvent = { [weak self] event in
            self?.handleTimelineEvent(event)
        }

        // PR9: Scene context actions
        editorLayoutContainer.onDuplicateScene = { [weak self] sceneId in
            self?.session.dispatch(.duplicateScene(sceneItemId: sceneId))
        }

        editorLayoutContainer.onDeleteScene = { [weak self] sceneId in
            // Cancel all in-flight ingests for the scene being deleted
            self?.mediaIngestCoordinator.cancelAll(for: sceneId)
            self?.session.dispatch(.deleteScene(sceneId: sceneId))
        }

        editorLayoutContainer.onAddScene = { [weak self] in
            self?.presentSceneCatalog()
        }

        // PR8: Music callbacks
        editorLayoutContainer.onMusic = { [weak self] in
            self?.presentMusicPicker()
        }

        editorLayoutContainer.onRemoveMusic = { [weak self] in
            self?.session.dispatch(.removeProjectMusic)
        }

        editorLayoutContainer.onMusicVolume = { [weak self] itemId in
            self?.presentMusicVolumeSlider(itemId: itemId)
        }

        editorLayoutContainer.onMusicTrim = { [weak self] itemId in
            self?.presentMusicTrimEditor(itemId: itemId)
        }

        // PR9: Text overlay callbacks
        editorLayoutContainer.onAddText = { [weak self] in
            self?.presentTextEditor(existingPayload: nil, itemId: nil)
        }
        editorLayoutContainer.onEditText = { [weak self] itemId in
            guard let payload = self?.session.state?.canonicalTimeline.textPayload(for: itemId) else { return }
            self?.presentTextEditor(existingPayload: payload, itemId: itemId)
        }
        editorLayoutContainer.onDeleteText = { [weak self] itemId in
            self?.session.dispatch(.deleteItem(itemId: itemId))
        }

        // PR10: Sticker overlay callbacks
        editorLayoutContainer.onSticker = { [weak self] in
            self?.presentStickerPicker(changingItemId: nil)
        }
        editorLayoutContainer.onChangeSticker = { [weak self] itemId in
            self?.presentStickerPicker(changingItemId: itemId)
        }
        editorLayoutContainer.onDeleteSticker = { [weak self] itemId in
            self?.session.dispatch(.deleteItem(itemId: itemId))
        }

        // PR9+PR10: Overlay position drag callback (text + sticker)
        overlayPositionDrag.onDragPosition = { [weak self] itemId, centerX, centerY, phase in
            self?.session.dispatch(.dragOverlayPosition(itemId: itemId, centerX: centerX, centerY: centerY, phase: phase))
        }

        // PR-D: Scene Edit Mode callbacks
        editorLayoutContainer.onEditScene = { [weak self] sceneId in
            self?.session.dispatch(.enterSceneEdit(sceneId: sceneId))
        }

        editorLayoutContainer.onDone = { [weak self] in
            self?.session.dispatch(.exitSceneEdit)
        }

        // PR-E: SceneEditBar callbacks
        editorLayoutContainer.onBackground = { [weak self] in
            self?.backgroundTapped()
        }

        editorLayoutContainer.onResetScene = { [weak self] in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId else { return }

            // PR-F: Show confirmation only if scene has state to reset
            let sceneState = self.session.state?.draft.sceneInstanceStates[instanceId]
            guard sceneState != nil && sceneState != .empty else { return }

            let alert = UIAlertController(
                title: "Reset Scene",
                message: "This will reset all changes to this scene. This action can be undone.",
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                // Cancel all in-flight ingests for this scene before resetting
                self.mediaIngestCoordinator.cancelAll(for: instanceId)
                self.session.dispatch(.resetSceneState(sceneInstanceId: instanceId))
                // Phase D: reloadRuntimeState is async — refresh bars after reload completes.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.reloadRuntimeState(for: instanceId)
                    self.refreshSceneEditBars()
                }
            })

            self.present(alert, animated: true)
        }

        // PR-E: MediaBlockActionBar callbacks
        editorLayoutContainer.onAddPhoto = { [weak self] blockId in
            self?.presentMediaPicker(for: blockId, kind: .photo)
        }

        editorLayoutContainer.onAddVideo = { [weak self] blockId in
            self?.presentMediaPicker(for: blockId, kind: .video)
        }

        editorLayoutContainer.onTrimVideo = { [weak self] blockId in
            self?.enterVideoTrim(for: blockId)
        }

        editorLayoutContainer.onTrimCancel = { [weak self] in
            self?.cancelVideoTrim()
        }

        editorLayoutContainer.onTrimDone = { [weak self] in
            self?.commitVideoTrim()
        }

        // VideoTrimBar handle/cursor callbacks
        editorLayoutContainer.videoTrimBar.onTrimStartChanged = { [weak self] fraction in
            self?.handleTrimStartDrag(fraction)
        }
        editorLayoutContainer.videoTrimBar.onTrimEndChanged = { [weak self] fraction in
            self?.handleTrimEndDrag(fraction)
        }
        editorLayoutContainer.videoTrimBar.onCursorChanged = { [weak self] fraction in
            self?.handleTrimCursorDrag(fraction)
        }
        editorLayoutContainer.videoTrimBar.onDragEnded = { [weak self] in
            self?.handleTrimDragEnded()
        }

        editorLayoutContainer.onAnimation = { [weak self] blockId in
            self?.presentVariantPicker(blockId: blockId)
        }

        editorLayoutContainer.onToggleEnabled = { [weak self] blockId in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId else { return }
            // Toggle current state
            let currentPresent = self.session.state?.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId]?.visibility ?? true
            self.session.dispatch(.setBlockMediaPresent(
                sceneInstanceId: instanceId,
                blockId: blockId,
                present: !currentPresent
            ))
            // Update runtime via visibility fast-path
            self.runtime?.applyMediaVisibilityChange(instanceId: instanceId, blockId: blockId, visible: !currentPresent)
            // Refresh MediaBlockActionBar to update Disable/Enable button state
            self.updateMediaBlockActionBarForSelectedBlock()
        }

        editorLayoutContainer.onRemove = { [weak self] blockId in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId else { return }
            // Cancel any in-flight ingest for this slot
            self.mediaIngestCoordinator.cancelIngest(
                for: IngestSlotKey(sceneInstanceId: instanceId, blockId: blockId)
            )
            // PR5 Phase E: Pre-capture the asset ID before dispatch so we can
            // check if it is still referenced after the slot is cleared.
            let oldAssetId = self.session.state?.draft
                .sceneInstanceStates[instanceId]?
                .mediaSlotsByBlockId?[blockId]?.mediaRef.assetId
            // Clear runtime
            self.runtime?.clearMediaSlot(blockId: blockId)
            // Dispatch to store (removes slot)
            self.session.dispatch(.setMediaSlot(
                sceneInstanceId: instanceId,
                blockId: blockId,
                slot: nil
            ))
            // PR5 Phase E: Post-dispatch bookkeeping — re-read the fresh draft
            // and unregister the old asset ID only if nothing else references it.
            if let oldAssetId {
                self.session.unregisterAssetIfUnreferenced(oldAssetId)
            }
            self.metalView.setNeedsDisplay()
            // Refresh MediaBlockActionBar
            self.updateMediaBlockActionBarForSelectedBlock()
        }

        editorLayoutContainer.onResetTransform = { [weak self] blockId in
            guard let self, let instanceId = self.sceneEditTargetInstanceId else { return }
            self.session.dispatch(.resetMediaPlacement(sceneInstanceId: instanceId, blockId: blockId))
            self.updateMediaBlockActionBarForSelectedBlock()
        }
    }

    // MARK: - PR1 + PR2: Unified Timeline Event Handling

    /// Routes timeline events from EditorLayoutContainerView.
    /// Scroll events are handled by the container (ruler sync).
    private func handleTimelineEvent(_ event: TimelineEvent) {
        switch event {
        case .scrub(let compressedFrame, let phase):
            handleTimelineScrub(compressedFrame: compressedFrame, phase: phase)

        case .selection(let selection):
            handleTimelineSelectionChanged(selection)

        case .scroll:
            // Handled by container (ruler sync), nothing to do here
            break

        case .trimScene(let sceneId, let newDurationUs, let edge, let phase):
            handleTrimScene(sceneId: sceneId, newDurationUs: newDurationUs, edge: edge, phase: phase)

        case .reorderScene(let sceneId, let toIndex, let phase):
            handleReorderScene(sceneId: sceneId, toIndex: toIndex, phase: phase)

        case .editBoundaryTransition(let fromId, let toId, let anchorRect):
            presentTransitionPicker(fromSceneId: fromId, toSceneId: toId, anchorRect: anchorRect)

        case .focusScene(let sceneId):
            session.dispatch(.focusScene(sceneId: sceneId))

        case .moveOverlayItem(let itemId, let newStartUs, let phase):
            session.dispatch(.moveItem(itemId: itemId, newStartUs: newStartUs, phase: phase))

        case .trimOverlayItem(let itemId, let newDurationUs, _, let phase):
            session.dispatch(.trimItem(itemId: itemId, newDurationUs: newDurationUs, phase: phase))
        }
    }

    // MARK: - PR2: Trim Scene Handling

    /// Handles trim scene events from timeline.
    /// PR2: Dispatches to EditorStore instead of direct mutation.
    /// - Parameters:
    ///   - sceneId: ID of the scene being trimmed
    ///   - newDurationUs: New duration in microseconds
    ///   - edge: Which edge is being trimmed
    ///   - phase: Gesture phase
    private func handleTrimScene(sceneId: UUID, newDurationUs: TimeUs, edge: TrimEdge, phase: InteractionPhase) {
        // Stop playback on trim start to avoid coordinator/UI desync during preview
        if phase == .began && (runtime?.isPlaying ?? false) {
            runtime?.stopPlayback()
        }

        // PR2: Dispatch trim action to store
        // PR3.1: All UI updates happen via handleStoreStateChanged callback
        session.dispatch(.trimScene(sceneId: sceneId, phase: phase, newDurationUs: newDurationUs, edge: edge))
    }

    // MARK: - PR3: Reorder Scene Handling

    /// Handles reorder scene events from timeline.
    /// PR3: Dispatches to EditorStore on .ended phase only.
    /// PR3.2: Converts UI insertion index (0...count) to reducer destination index (0...count-1).
    /// - Parameters:
    ///   - sceneId: ID of the scene being moved
    ///   - toIndex: Insertion index from UI (0...count, where count means "insert at end")
    ///   - phase: Gesture phase
    private func handleReorderScene(sceneId: UUID, toIndex: Int, phase: InteractionPhase) {
        // Only commit reorder on .ended phase
        guard phase == .ended else { return }
        guard toIndex >= 0 else { return } // -1 means cancelled

        // PR3.2: Convert insertion index to destination index
        // UI emits insertion index (0...count), reducer expects destination index (0...count-1)
        guard let sceneItems = session.state?.sceneItems else { return }
        guard let fromIndex = sceneItems.firstIndex(where: { $0.id == sceneId }) else {
            log("[PR3.2] handleReorderScene: scene not found")
            return
        }

        let count = sceneItems.count
        var destIndex = toIndex

        // If inserting after current position, adjust for removal
        if toIndex > fromIndex {
            destIndex -= 1
        }

        // Clamp to valid destination range
        destIndex = max(0, min(destIndex, count - 1))

        // Skip if no actual move
        guard destIndex != fromIndex else { return }

        // PR3: Dispatch reorder action to store
        // PR3.1: All UI updates happen via handleStoreStateChanged callback
        session.dispatch(.reorderScene(sceneId: sceneId, toIndex: destIndex))
    }

    // MARK: - PR-G: Transition Picker

    /// Presents transition picker for a scene boundary.
    /// - Parameters:
    ///   - fromSceneId: ID of the outgoing scene
    ///   - toSceneId: ID of the incoming scene
    ///   - anchorRect: Rect for popover anchor (in TimelineView coordinates)
    private func presentTransitionPicker(fromSceneId: UUID, toSceneId: UUID, anchorRect: CGRect) {
        let key = SceneBoundaryKey(fromSceneId, toSceneId)
        let current = session.state?.canonicalTimeline.boundaryTransitions[key] ?? .none

        let handler = EditorViewController.makeBoundaryTransitionDispatchHandler(
            fromSceneId: fromSceneId,
            toSceneId: toSceneId
        ) { [weak self] action in
            self?.session.dispatch(action)
        }

        let picker = EditorViewController.makeTransitionPicker(
            currentType: current.type,
            onSelect: handler
        )

        // Wrap in navigation controller for title/cancel button
        let nav = UINavigationController(rootViewController: picker)

        // iPad: popover, iPhone: sheet
        if traitCollection.userInterfaceIdiom == .pad {
            nav.modalPresentationStyle = .popover
            if let popover = nav.popoverPresentationController {
                popover.sourceView = editorLayoutContainer.timelineView
                popover.sourceRect = anchorRect
            }
        } else {
            nav.modalPresentationStyle = .pageSheet
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.medium()]
                sheet.prefersGrabberVisible = true
            }
        }

        present(nav, animated: true)
    }

    /// Handles editor notices (e.g., transition reset alerts).
    private func handleEditorNotice(_ notice: EditorNotice) {
        switch notice {
        case .boundaryTransitionsReset:
            let alert = EditorViewController.makeBoundaryTransitionsResetAlert()
            present(alert, animated: true)
        }
    }

    // MARK: - TT-08: Internal Test Seams

    /// Creates a configured transition picker.
    /// - Parameters:
    ///   - currentType: Current transition type for checkmark display.
    ///   - onSelect: Called with selected transition after dismiss.
    /// - Returns: Configured `TransitionPickerViewController`.
    static func makeTransitionPicker(
        currentType: TransitionType,
        onSelect: @escaping (SceneTransition) -> Void
    ) -> TransitionPickerViewController {
        let picker = TransitionPickerViewController(currentType: currentType)
        picker.onSelectTransition = onSelect
        return picker
    }

    /// Creates a dispatch handler that maps a selected transition to a `.setBoundaryTransition` action.
    /// - Parameters:
    ///   - fromSceneId: ID of the outgoing scene.
    ///   - toSceneId: ID of the incoming scene.
    ///   - dispatch: Action dispatch closure.
    /// - Returns: Closure suitable for `onSelectTransition`.
    static func makeBoundaryTransitionDispatchHandler(
        fromSceneId: UUID,
        toSceneId: UUID,
        dispatch: @escaping (EditorAction) -> Void
    ) -> (SceneTransition) -> Void {
        { transition in
            dispatch(.setBoundaryTransition(
                fromSceneId: fromSceneId,
                toSceneId: toSceneId,
                transition: transition
            ))
        }
    }

    /// Creates the alert shown when boundary transitions are auto-reset.
    /// - Returns: Configured `UIAlertController`.
    static func makeBoundaryTransitionsResetAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: "Transitions Removed",
            message: "Some transitions were removed because scene boundaries changed or adjacent scenes are too short.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }

    /// Reads live session state and presents the missing-media notice if still relevant.
    /// No-ops if notice was already delivered or failures have been resolved.
    private func flushMissingMediaNoticeIfNeeded() {
        guard hasDeferredMissingMediaNotice || session.hasPendingMissingMediaNotice else { return }
        hasDeferredMissingMediaNotice = false
        guard let summary = session.missingMediaSummary, summary.hasFailedMedia else { return }
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
        present(alert, animated: true) { [weak self] in
            self?.session.markMissingMediaNoticePresented()
        }
    }

    // MARK: - TT-10: Scene Edit Isolation

    /// Isolates timeline activity when entering scene edit mode.
    /// Contract: cancel pending timeline resolve first, then stop playback.
    /// Order matters — stale resolve must not complete after lifecycle stop.
    static func isolateTimelineActivityForSceneEdit(
        cancelPendingTimelineResolve: () -> Void,
        stopPlayback: () -> Void
    ) {
        cancelPendingTimelineResolve()
        stopPlayback()
    }

    // MARK: - PR2: Editor Callbacks

    private func handleEditorClose() {
        runtime?.stopPlayback()
        let action = session.requestClose()
        switch action {
        case .safeToClose:
            userMadeExplicitCloseChoice = true
            navigationController?.popViewController(animated: true)
        case .needsUserDecision:
            presentCloseAlert()
        }
    }

    private func presentCloseAlert() {
        let alert = UIAlertController(title: nil, message: "Save changes?", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            self?.saveAndClose()
        })
        alert.addAction(UIAlertAction(title: "Don't Save", style: .destructive) { [weak self] _ in
            self?.discardAndClose()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    private func saveAndClose() {
        userMadeExplicitCloseChoice = true
        Task {
            do {
                try await session.executeSaveAndClose()
            } catch {
                log("[Close] Save failed: \(error)")
                presentSaveError(error)
                return
            }
            navigationController?.popViewController(animated: true)
        }
    }

    private func discardAndClose() {
        userMadeExplicitCloseChoice = true
        Task {
            try? await session.executeDiscardAndClose()
            navigationController?.popViewController(animated: true)
        }
    }

    private func presentSaveError(_ error: Error) {
        let alert = UIAlertController(
            title: "Save Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func handleFullScreenPreview() {
        // PR-F: Fullscreen preview only allowed in timeline mode
        let uiMode = session.state?.uiMode ?? .timeline
        guard case .timeline = uiMode else {
            assertionFailure("handleFullScreenPreview called outside timeline mode")
            return
        }

        let fullScreenVC = FullScreenPreviewViewController()
        fullScreenVC.modalPresentationStyle = .fullScreen
        fullScreenPreviewVC = fullScreenVC

        // Phase 2.1: Use compressed frame from store (not currentFrameIndex)
        let compressedFrame = session.state?.playheadCompressedFrame ?? 0
        fullScreenVC.configure(compressedFrame: compressedFrame, isPlaying: runtime?.isPlaying ?? false)

        // Move metalView to fullscreen VC
        metalView.removeFromSuperview()
        fullScreenVC.embedMetalView(metalView)

        // Wire callbacks
        fullScreenVC.onClose = { [weak self] returnedCompressedFrame in
            guard let self = self else { return }

            // Clear reference
            self.fullScreenPreviewVC = nil

            // Return metalView to editor layout before dismissing
            self.metalView.removeFromSuperview()
            self.editorLayoutContainer.embedMetalView(self.metalView)

            self.dismiss(animated: true) {
                // Phase 2.1: Dispatch compressed frame directly (no frameToUs conversion)
                self.session.dispatch(.setPlayhead(compressedFrame: returnedCompressedFrame))
                self.metalView.setNeedsDisplay()
            }
        }

        fullScreenVC.onPlayPause = { [weak self] in
            self?.playPauseTapped()
        }

        present(fullScreenVC, animated: true)
    }

    /// Handles timeline scrub events.
    /// Release v1: Routes through EditorStore for single source of truth.
    /// Phase 2.1: Uses compressed frame directly.
    /// - Parameters:
    ///   - compressedFrame: Compressed frame index (quantize applied at TimelineView)
    ///   - phase: Gesture phase for scrub drag state tracking
    private func handleTimelineScrub(compressedFrame: Int, phase: InteractionPhase) {
        // Track scrub drag state for render throttling (A/B testing)
        switch phase {
        case .began:
            isScrubDragging = true
        case .ended, .cancelled:
            isScrubDragging = false
            // Force final render if any was skipped due to throttle
            if pendingScrubRender {
                metalView.setNeedsDisplay()
                pendingScrubRender = false
            }
        case .changed:
            break
        }

        // Stop playback on scrub
        if runtime?.isPlaying ?? false {
            runtime?.stopPlayback()
        }

        // Dispatch to store - onPlayheadChanged callback handles coordinator + redraw + currentFrameIndex
        session.dispatch(.setPlayhead(compressedFrame: compressedFrame))
    }

    private func handleTimelineSelectionChanged(_ selection: TimelineSelection) {
        // In timeline mode, scene selection comes from playhead via focusScene.
        // Only allow .audio and .none through direct .select dispatch.
        if session.state?.uiMode == .timeline, case .scene = selection {
            return
        }
        // PR3: Only dispatch to store. UI updates happen in handleStoreStateChanged.
        session.dispatch(.select(selection: selection))
    }

    /// Configures timeline after scene is loaded.
    /// Top-level coordinator calling focused helpers for each responsibility.
    private func configureEditorTimeline(
        loadResult: EditorRuntime.InitialSceneLoadResult
    ) {
        let fps = sceneLibrarySnapshot?.fps ?? Int(loadResult.compiled.runtime.fps)

        guard let state = session.state else {
            log("[Release v1] configureEditorTimeline: session state is nil")
            return
        }

        wireStoreCallbacks()
        setupSceneEditController(loadResult: loadResult)
        configureTimelineUI(state: state, fps: fps)
        bootRuntime(loadResult: loadResult, state: state)
    }

    /// Wires all store callbacks via EditorStoreCallbacks.
    private func wireStoreCallbacks() {
        var callbacks = EditorStoreCallbacks()
        callbacks.onPlayheadChanged = { [weak self] cf in
            self?.runtime?.handlePlayheadChanged(cf)
            if let mapper = self?.session.state?.makePlayheadMapper() {
                self?.editorLayoutContainer.setCurrentCompressedFrame(cf, mapper: mapper)
            }
        }
        callbacks.onSelectionChanged = { [weak self] sel in self?.handleSelectionChanged(sel) }
        callbacks.onTimelineChanged = { [weak self] st in
            self?.handleTimelineChanged(st)
            self?.runtime?.setupTimelineCompositionEngine(state: st)
        }
        callbacks.onTimelinePreviewChanged = { [weak self] st in self?.handleTimelinePreviewChanged(st) }
        callbacks.onUndoRedoChanged = { [weak self] canUndo, canRedo in self?.handleUndoRedoChanged(canUndo: canUndo, canRedo: canRedo) }
        callbacks.onUIModeChanged = { [weak self] mode in self?.handleUIModeChanged(mode) }
        callbacks.onSelectedBlockChanged = { [weak self] blockId in self?.handleSelectedBlockChanged(blockId) }
        callbacks.onStateRestoredFromUndoRedo = { [weak self] in self?.handleStateRestoredFromUndoRedo() }
        callbacks.onSceneStateChanged = { [weak self] instanceId, sceneState in self?.handleSceneStateChanged(instanceId: instanceId, sceneState: sceneState) }
        callbacks.onVideoSelectionChanged = { [weak self] instanceId, blockId, selection in self?.handleVideoSelectionChanged(instanceId: instanceId, blockId: blockId, selection: selection) }
        callbacks.onMediaPlacementChanged = { [weak self] instanceId, blockId, placement in self?.handleMediaPlacementChanged(instanceId: instanceId, blockId: blockId, placement: placement) }
        callbacks.onMediaVisibilityChanged = { [weak self] instanceId, blockId, visible in self?.handleMediaVisibilityChanged(instanceId: instanceId, blockId: blockId, visible: visible) }
        callbacks.onMediaSlotChanged = { [weak self] instanceId, blockId, slot in self?.handleMediaSlotChanged(instanceId: instanceId, blockId: blockId, slot: slot) }
        callbacks.onNotice = { [weak self] notice in self?.handleEditorNotice(notice) }
        session.setStoreCallbacks(callbacks)
    }

    /// Assembles the SceneEditInteractionController with all closure bindings.
    private func setupSceneEditController(loadResult: EditorRuntime.InitialSceneLoadResult) {
        let sceneEditCtrl = SceneEditInteractionController()
        sceneEditCtrl.overlayView = overlayView
        sceneEditCtrl.getOverlayProvider = { [weak self] in self?.runtime?.sceneEditOverlayProvider() }
        sceneEditCtrl.getUIMode = { [weak self] in self?.session.state?.uiMode ?? .timeline }
        sceneEditCtrl.getSelectedBlockId = { [weak self] in self?.session.state?.selectedBlockId }

        sceneEditCtrl.onSelectBlock = { [weak self] blockId in
            self?.session.dispatch(.selectBlock(blockId: blockId))
        }

        sceneEditCtrl.getBaselinePlacement = { [weak self] blockId in
            guard let self = self,
                  let instanceId = self.sceneEditTargetInstanceId,
                  let slot = self.session.state?.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId] else {
                return .defaultCover
            }
            return slot.asset.placement
        }

        sceneEditCtrl.onPlacementChanged = { [weak self] blockId, placement, phase in
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

        sceneEditCtrl.ingestStatusOverlayView = ingestStatusOverlayView
        sceneEditCtrl.showsIngestStatusOverlay = showsMediaIngestStatusOverlay
        sceneEditCtrl.getIngestStatusesByBlockId = { [weak self] in
            self?.currentIngestStatusesByBlockId() ?? [:]
        }

        self.sceneEditController = sceneEditCtrl
    }

    /// Configures timeline UI from current editor state.
    private func configureTimelineUI(state: EditorState, fps: Int) {
        log("[Release v1] Timeline configured: \(state.sceneItems.count) scenes, duration=\(state.projectDurationUs)us")

        let scenes = state.canonicalTimeline.toSceneDrafts()
        let boundaries = state.canonicalTimeline.toSceneBoundaryDrafts()
        editorLayoutContainer.configure(
            scenes: scenes,
            boundaries: boundaries,
            templateFPS: fps,
            minSceneDurationUs: ProjectDraft.minSceneDurationUs
        )
        syncTimelineSupplementalUI(state: state)
    }

    /// Creates EditorRuntime, configures Metal context, and boots the render engine.
    private func bootRuntime(loadResult: EditorRuntime.InitialSceneLoadResult, state: EditorState) {
        let library = sceneLibrarySnapshot!
        let rt = EditorRuntime(session: session)
        rt.onOutput = { [weak self] output in self?.handleRuntimeOutput(output) }
        self.runtime = rt

        if let device = metalView.device, let queue = commandQueue {
            let metalCtx = EditorRuntimeMetalContext(device: device, commandQueue: queue, colorPixelFormat: metalView.colorPixelFormat)
            rt.configureAndBoot(
                metalContext: metalCtx,
                library: library,
                loadResult: loadResult,
                editorState: state
            )
        }

        let mapper = state.makePlayheadMapper()
        editorLayoutContainer.setMapper(mapper)

        #if DEBUG
        rt.assertBootInvariants(uiMode: state.uiMode)
        #endif
    }

    // MARK: - Runtime Output Handling

    private weak var exportProgressVC: ExportProgressViewController?

    private func handleRuntimeOutput(_ output: EditorRuntimeOutput) {
        switch output {
        case .renderSourceUpdated:
            metalView.setNeedsDisplay()

        case .playbackStateChanged(let isPlaying):
            editorLayoutContainer.setPlaying(isPlaying)
            fullScreenPreviewVC?.setPlaying(isPlaying)

        case .sceneEditActivated:
            refreshSceneEditBars()
            sceneEditController?.updateOverlay()
            requestMetalRender()

        case .sceneEditDeactivated:
            break // UI already handled in handleUIModeChanged

        case .exportStarted:
            let progressVC = ExportProgressViewController()
            progressVC.modalPresentationStyle = .overFullScreen
            progressVC.modalTransitionStyle = .crossDissolve
            progressVC.onCancel = { [weak self] in self?.runtime?.cancelExport() }
            self.exportProgressVC = progressVC
            present(progressVC, animated: true) { progressVC.updateState(.preparing) }
            metalView.isPaused = true

        case .exportPreflightRecommendation(let result):
            guard case .recommendLowerPreset(_, let preset, let sizePx) = result else { return }
            Task {
                let choice = await showLowerPresetAlert(suggestedPreset: preset, suggestedSizePx: sizePx)
                runtime?.applyExportPreflightChoice(choice)
            }

        case .exportProgress(let p):
            exportProgressVC?.updateState(.rendering(progress: Double(p)))

        case .exportFinishing:
            exportProgressVC?.updateState(.finishing)

        case .exportCompleted(let result):
            metalView.isPaused = false
            metalView.setNeedsDisplay()
            switch result {
            case .success:
                exportProgressVC?.updateState(.savingToPhotos)
            case .failure(let e as VideoExportError) where e.isCancelled:
                dismiss(animated: true)
            case .failure(let e):
                dismiss(animated: true) { self.presentExportError(e) }
            }

        case .exportCancelled:
            metalView.isPaused = false
            metalView.setNeedsDisplay()
            dismiss(animated: true)

        case .exportDeliveryCompleted(let outcome):
            switch outcome {
            case .savedToPhotos:
                dismiss(animated: true) { self.presentSavedToPhotosAlert() }
            case .showPermissionSettings:
                dismiss(animated: true) { self.presentPhotoLibraryPermissionAlert() }
            case .showError(let e):
                dismiss(animated: true) { self.presentExportError(e) }
            case .ignoredStale:
                break
            }

        case .runtimeReady:
            break // informational

        case .runtimeFailed(let msg):
            let alert = UIAlertController(title: "Runtime Error", message: msg, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)

        case .presentError(let msg):
            let alert = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    // MARK: - (Old methods deleted — now in EditorRuntime)

    /// Called when selection changes (lightweight, frequent).
    /// Used for tap/drag selection updates.
    private func handleSelectionChanged(_ selection: TimelineSelection?) {
        let sel = selection ?? .none
        let sceneCount = session.state?.sceneItems.count ?? 1
        editorLayoutContainer.setTimelineSelection(sel, sceneCount: sceneCount)
        updateOverlayPositionDrag(selection: sel)
    }

    /// PR9+PR10: Updates overlay position drag visibility and state based on selection.
    private func updateOverlayPositionDrag(selection: TimelineSelection) {
        guard session.state?.uiMode == .timeline else {
            overlayPositionDrag.clearSelection()
            overlayPositionDrag.isHidden = true
            return
        }

        switch selection {
        case .text(let itemId):
            if let payload = session.state?.canonicalTimeline.textPayload(for: itemId) {
                overlayPositionDrag.isHidden = false
                overlayPositionDrag.setSelectedItem(itemId: itemId, centerX: payload.centerX, centerY: payload.centerY)
            } else {
                overlayPositionDrag.clearSelection()
                overlayPositionDrag.isHidden = true
            }
        case .sticker(let itemId):
            if let payload = session.state?.canonicalTimeline.stickerPayload(for: itemId) {
                overlayPositionDrag.isHidden = false
                overlayPositionDrag.setSelectedItem(itemId: itemId, centerX: payload.centerX, centerY: payload.centerY)
            } else {
                overlayPositionDrag.clearSelection()
                overlayPositionDrag.isHidden = true
            }
        default:
            overlayPositionDrag.clearSelection()
            overlayPositionDrag.isHidden = true
        }
    }

    /// Called when timeline structure changes (heavier, less frequent).
    /// Used for scene add/remove/trim commits.
    private func handleTimelineChanged(_ state: EditorState) {
        // Update scene clips UI (PR-G: includes boundaries)
        let scenes = state.canonicalTimeline.toSceneDrafts()
        let boundaries = state.canonicalTimeline.toSceneBoundaryDrafts()
        editorLayoutContainer.updateScenes(scenes, boundaries: boundaries)

        syncTimelineSupplementalUI(state: state)

        // Update coordinator timeline (legacy path for Scene Edit)
        runtime?.syncCoordinatorTimeline(from: state)

        // PR-F: Refresh bottom bars if in Scene Edit mode
        refreshSceneEditBars()

        // PR-G: Refresh current frame to reflect timeline changes
        runtime?.refreshCurrentTimelineFrame()
    }

    /// PR9+PR10: Updates the overlay lanes in the timeline UI from current state.
    private func updateOverlayTrack(state: EditorState) {
        let textItems: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)] =
            state.canonicalTimeline.textItems.compactMap { item in
                guard let payload = state.canonicalTimeline.textPayload(for: item.id) else { return nil }
                let label = payload.text.isEmpty ? "Text" : String(payload.text.prefix(20))
                return (id: item.id, startUs: item.startUs ?? 0, durationUs: item.durationUs, label: label)
            }
        let stickerItems: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)] =
            state.canonicalTimeline.stickerItems.compactMap { item in
                guard let payload = state.canonicalTimeline.stickerPayload(for: item.id) else { return nil }
                return (id: item.id, startUs: item.startUs ?? 0, durationUs: item.durationUs, label: payload.stickerId)
            }

        let selectedTextId: UUID? = if case .text(let id) = state.selection { id } else { nil }
        let selectedStickerId: UUID? = if case .sticker(let id) = state.selection { id } else { nil }

        editorLayoutContainer.timelineView.setTextOverlayItems(textItems, selectedItemId: selectedTextId)
        editorLayoutContainer.timelineView.setStickerOverlayItems(stickerItems, selectedItemId: selectedStickerId)
    }

    /// Keeps music/overlay lanes, selection, and mapper in sync for both initial bootstrap and later timeline updates.
    private func syncTimelineSupplementalUI(state: EditorState) {
        editorLayoutContainer.timelineView.setMusicItem(
            state.canonicalTimeline.musicItem,
            payload: state.canonicalTimeline.musicPayload()
        )
        updateOverlayTrack(state: state)
        editorLayoutContainer.setMapper(state.makePlayheadMapper())
        handleSelectionChanged(state.selection)
    }

    /// PR-F: Called when scene state changes (but not timeline structure).
    /// Routes to engine for incremental sync instead of full setTimeline().
    private func handleSceneStateChanged(instanceId: UUID, sceneState: SceneState) {
        runtime?.applySceneStateChange(instanceId: instanceId, sceneState: sceneState)

        #if DEBUG
        logger.debug("[PR-F] Scene state changed: instanceId=\(instanceId)")
        #endif
    }

    // MARK: - PR4: Fast-Path Handlers

    /// Fast-path: placement committed — apply to active scene without full reload.
    private func handleMediaPlacementChanged(instanceId: UUID, blockId: String, placement: MediaPlacementState) {
        let resolvedInstanceId = sceneEditTargetInstanceId ?? instanceId
        runtime?.applyMediaPlacementChange(instanceId: resolvedInstanceId, blockId: blockId, placement: placement)
    }

    /// Fast-path: visibility toggled — apply to active scene without full reload.
    private func handleMediaVisibilityChanged(instanceId: UUID, blockId: String, visible: Bool) {
        let resolvedInstanceId = sceneEditTargetInstanceId ?? instanceId
        runtime?.applyMediaVisibilityChange(instanceId: resolvedInstanceId, blockId: blockId, visible: visible)
        refreshSceneEditBars()
    }

    /// Fast-path: slot changed (insert/replace/remove) — apply to active scene.
    /// Slot changes use full engine update (media needs restore).
    private func handleMediaSlotChanged(instanceId: UUID, blockId: String, slot: SceneMediaSlot?) {
        let resolvedInstanceId = sceneEditTargetInstanceId ?? instanceId
        runtime?.applyMediaSlotChange(instanceId: resolvedInstanceId, blockId: blockId, slot: slot)
        refreshSceneEditBars()
    }

    /// Called during live-trim preview (lightweight, frequent).
    /// Only updates UI, skips playback coordinator and persistence.
    /// Phase 2.1: Must update mapper for live trim scrub to work correctly.
    private func handleTimelinePreviewChanged(_ state: EditorState) {
        // Update scene clips UI only (PR-G: includes boundaries)
        let scenes = state.canonicalTimeline.toSceneDrafts()
        let boundaries = state.canonicalTimeline.toSceneBoundaryDrafts()
        editorLayoutContainer.updateScenes(scenes, boundaries: boundaries)

        // Phase 2.1: Update mapper in timeline UI for live trim preview
        // This is required for scrub/layout to use correct mapping during trim drag
        let mapper = state.makePlayheadMapper()
        editorLayoutContainer.setMapper(mapper)

        // NOTE: Intentionally NOT updating:
        // - playbackCoordinator (expensive O(n) rebuild)
        // - persistence is handled by EditorSession (dirty tracking via dual-baseline)
    }

    /// Called when undo/redo availability changes.
    /// PR-F: Updates navbar button enabled states.
    private func handleUndoRedoChanged(canUndo: Bool, canRedo: Bool) {
        editorLayoutContainer.navBar.setUndoEnabled(canUndo)
        editorLayoutContainer.navBar.setRedoEnabled(canRedo)

        #if DEBUG
        log("[PR-F] Undo/Redo changed: canUndo=\(canUndo), canRedo=\(canRedo)")
        #endif
    }

    // MARK: - PR-D: Scene Edit Mode Handlers

    /// Handles UI mode changes (timeline ↔ sceneEdit).
    /// PR-D: Wires store.onUIModeChanged to layout and interaction controller.
    private func handleUIModeChanged(_ mode: EditorUIMode) {
        switch mode {
        case .timeline:
            // Exit Scene Edit: restore timeline UI via runtime
            runtime?.deactivateSceneEdit()
            editorLayoutContainer.setSceneEditMode(false, animated: true)
            editorLayoutContainer.navBar.setMode(.timeline)
            sceneEditController?.updateOverlay()

        case .sceneEdit(let sceneId):
            // TT-10: Isolate timeline activity unconditionally on scene edit entry.
            // Stop playback via runtime
            runtime?.stopPlayback()
            editorLayoutContainer.setSceneEditMode(true, animated: true)
            editorLayoutContainer.navBar.setMode(.sceneEdit)
            sceneEditController?.updateOverlay()

            // PR-F: Configure bottom bars state
            refreshSceneEditBars()

            // Activate target scene by instance ID via runtime (async, render-gated)
            runtime?.activateSceneEditTarget(instanceId: sceneId)

            #if DEBUG
            log("[PR-D] Entered Scene Edit for scene: \(sceneId)")
            #endif
        }
    }

    /// Handles selected block changes in Scene Edit mode.
    /// PR-D: Updates bottom bar and overlay when block selection changes.
    /// PR-F: Uses refreshSceneEditBars() for consistent bar updates.
    private func handleSelectedBlockChanged(_ blockId: String?) {
        editorLayoutContainer.updateSceneEditBottomBar(selectedBlockId: blockId)
        sceneEditController?.updateOverlay()

        // PR-F: Refresh bottom bars state
        refreshSceneEditBars()

        #if DEBUG
        log("[PR-D] Selected block changed: \(blockId ?? "nil")")
        #endif
    }

    /// Updates MediaBlockActionBar configuration for currently selected block (PR-E).
    private func updateMediaBlockActionBarForSelectedBlock() {
        guard let blockId = session.state?.selectedBlockId,
              let rt = runtime,
              let instanceId = sceneEditTargetInstanceId else { return }

        // Get sealed block capabilities from runtime
        let ctx = rt.mediaActionBarContext(blockId: blockId)
        let hasVariants = ctx.availableVariants.count > 1

        // Check if block has media assigned (unified slots)
        let sceneState = session.state?.draft.sceneInstanceStates[instanceId]
        let slot = sceneState?.mediaSlotsByBlockId?[blockId]
        var hasMedia = slot != nil

        // Check if block is enabled (slot visibility)
        let isEnabled = slot?.visibility ?? true

        // Determine media kind and trim capability
        var mediaKind = slot?.mediaRef.mediaKind
        var canTrimVideo = ctx.canTrimVideo

        // Phase 6: Restore-failed blocks treated as empty in scene-edit UI
        if let instanceId = sceneEditTargetInstanceId,
           session.missingMediaSummary?.isBlockFailed(sceneInstanceId: instanceId, blockId: blockId) == true {
            hasMedia = false
            mediaKind = nil
            canTrimVideo = false
        }

        // Phase 6: Get ingest status for this block
        let ingestKey = IngestSlotKey(sceneInstanceId: instanceId, blockId: blockId)
        let ingestStatus = mediaIngestCoordinator.status(for: ingestKey)

        // Check if placement is at default (for reset button visibility)
        let isPlacementDefault = slot?.asset.placement.isNearDefault ?? true

        editorLayoutContainer.configureMediaBlockActionBar(
            blockId: blockId,
            allowedMedia: ctx.allowedMedia,
            hasVariants: hasVariants,
            hasMedia: hasMedia,
            isEnabled: isEnabled,
            mediaKind: mediaKind,
            canTrimVideo: canTrimVideo,
            ingestStatus: ingestStatus,
            showsIngestStatus: showsMediaIngestStatusInActionBar,
            isPlacementDefault: isPlacementDefault
        )
    }

    /// Refreshes SceneEditBar and MediaBlockActionBar states.
    /// PR-F: Called after state changes to keep bottom bars in sync.
    private func refreshSceneEditBars() {
        guard let instanceId = sceneEditTargetInstanceId else { return }

        // 1. Update SceneEditBar reset button state
        let sceneState = session.state?.draft.sceneInstanceStates[instanceId]
        let canReset = sceneState != nil && sceneState != .empty
        editorLayoutContainer.configureSceneEditBar(canReset: canReset)

        // 2. Update MediaBlockActionBar if block is selected
        if session.state?.selectedBlockId != nil {
            updateMediaBlockActionBarForSelectedBlock()
        }
    }

    // MARK: - Phase 6: Ingest Status

    /// Returns current ingest statuses keyed by blockId for the active scene-edit scene.
    private func currentIngestStatusesByBlockId() -> [String: IngestSlotStatus] {
        guard let instanceId = sceneEditTargetInstanceId else { return [:] }
        var result: [String: IngestSlotStatus] = [:]
        for (key, status) in mediaIngestCoordinator.slotStatus
            where key.sceneInstanceId == instanceId {
            result[key.blockId] = status
        }
        return result
    }

    /// Handles ingest status changes: updates overlay, action bar, and shows failure alerts.
    private func handleIngestStatusChanged(key: IngestSlotKey, status: IngestSlotStatus) {
        // Only update UI if this status change is for the active scene-edit scene
        guard key.sceneInstanceId == sceneEditTargetInstanceId else { return }

        // Update ingest status overlay
        sceneEditController?.updateOverlay()

        // Update action bar if this block is selected
        if session.state?.selectedBlockId == key.blockId {
            updateMediaBlockActionBarForSelectedBlock()
        }

        // Alert dedupe
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
            present(alert, animated: true)

        case .ready:
            break // Transient, no action
        }
    }

    // MARK: - Inline Video Trim (PR 3+4) — delegated to InlineVideoTrimCoordinator

    private func enterVideoTrim(for blockId: String) {
        videoTrimCoordinator.enterVideoTrim(for: blockId)
    }

    private func handleTrimStartDrag(_ fraction: Double) {
        videoTrimCoordinator.handleTrimStartDrag(fraction)
    }

    private func handleTrimEndDrag(_ fraction: Double) {
        videoTrimCoordinator.handleTrimEndDrag(fraction)
    }

    private func handleTrimCursorDrag(_ fraction: Double) {
        videoTrimCoordinator.handleTrimCursorDrag(fraction)
    }

    private func handleTrimDragEnded() {
        videoTrimCoordinator.handleTrimDragEnded()
    }

    private func commitVideoTrim() {
        videoTrimCoordinator.commitVideoTrim()
    }

    private func cancelVideoTrim() {
        videoTrimCoordinator.cancelVideoTrim()
    }

    private func exitVideoTrim() {
        videoTrimCoordinator.exitVideoTrim()
    }

    /// Handles committed video selection change from store callback.
    private func handleVideoSelectionChanged(instanceId: UUID, blockId: String, selection: PersistedVideoSelection) {
        runtime?.applyVideoSelectionToEngine(selection: selection, blockId: blockId, instanceId: instanceId)
        refreshSceneEditBars()
    }

    /// Reloads runtime state for a given scene instance.
    /// PR-F: Single sync-point for runtime reload after undo/redo or Reset Scene.
    /// Order: resetForNewInstance -> clearAll -> applySceneInstanceState -> overlay/redraw -> video sync
    ///
    /// Phase D: async because `applySceneInstanceState` is async (pre-resolves
    /// media URLs off the caller). Steps 5 and 6 run after the awaited apply
    /// so overlay/redraw/video-still reflect restored state.
    private func reloadRuntimeState(for instanceId: UUID) async {
        // Delegate to runtime for reset + re-apply
        runtime?.resetRuntimeForSceneInstanceChange()
        await runtime?.applySceneInstanceState(instanceId: instanceId)

        // Refresh overlay and redraw
        sceneEditController?.updateOverlay()
        metalView.setNeedsDisplay()

        // Force video frame sync for already-ready providers
        syncPausedVideoStill(force: true)

        #if DEBUG
        log("[PR-F] Runtime state reloaded for instance: \(instanceId)")
        #endif
    }

    /// Syncs video frames to current playhead when paused.
    /// PR-F: Used after runtime reload and when video providers become ready.
    /// Suppressed during active trim session to prevent onNeedsDisplay events from
    /// overwriting the trim preview with scene-frame stills.
    /// - Parameter force: If true, bypasses lastStillSyncFrame gate
    private func syncPausedVideoStill(force: Bool) {
        guard !(runtime?.isPlaying ?? false) else { return }
        // During active trim, preview is driven by previewExactVideoTrimFrame — don't stomp it
        guard videoTrimCoordinator.videoTrimSession == nil else { return }

        let localFrame = runtime?.bestLocalFrame ?? 0
        runtime?.syncVideoStillFrames(sceneFrameIndex: localFrame)
    }

    /// Handles state restoration after undo/redo.
    /// PR-D: Re-applies runtime state for active scene instance to sync with restored snapshot.
    /// PR-F: Also refreshes bottom bars and syncs TimelineCompositionEngine.
    ///
    /// Phase D: `reloadRuntimeState` is now async, so the sequence runs inside
    /// a single MainActor Task to preserve ordering:
    ///   1. cancel ingests (sync)
    ///   2. await reload of active instance
    ///   3. refresh bars
    ///   4. sync engine timeline (with asset registry) and re-apply scene states
    private func handleStateRestoredFromUndoRedo() {
        // Conservatively cancel all in-flight ingests before reloading restored state.
        // Undo/redo may have reverted the scene structure, making ongoing ingests stale.
        mediaIngestCoordinator.cancelAll()

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

            // PR-F: Sync TimelineCompositionEngine with restored state.
            if let state = self.session.state {
                self.runtime?.syncEngineAfterUndoRedo(state: state)
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // PR-E: Hide system navigation bar (we use EditorNavBar)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        perfLogger.start()
        #endif

        // Flush deferred missing-media notice now that VC is visible
        if loadingState == .ready {
            flushMissingMediaNoticeIfNeeded()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Cancel all in-flight ingests on permanent leave
        if isMovingFromParent || isBeingDismissed {
            mediaIngestCoordinator.cancelAll()
        }

        // Safety net: save to active slot when leaving editor without explicit choice
        if (isMovingFromParent || isBeingDismissed) && !userMadeExplicitCloseChoice {
            autosaveCoordinator?.handleDisappear()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if DEBUG
        perfLogger.stop()
        #endif

        // PR4: Cleanup background textures when VC disappears
        runtime?.clearAllBackgroundTextures()
    }

    // MARK: - Draft Persistence

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // PR-E: Update Scene Edit mapper with current canvas/view sizes
        sceneEditController?.mapper.canvasSize = runtime?.queryCanvasSize ?? .zero
        sceneEditController?.mapper.viewSize = metalView.bounds.size

        // PR9: Update text position overlay canvas mapper
        let canvasSize = runtime?.queryCanvasSize ?? .zero
        let viewSize = metalView.bounds.size
        var textMapper = EditorCanvasMapper()
        textMapper.canvasSize = canvasSize
        textMapper.viewSize = viewSize
        overlayPositionDrag.canvasSize = CGSize(width: canvasSize.width, height: canvasSize.height)
        overlayPositionDrag.canvasToView = textMapper.canvasToViewTransform()

        // P1-2: Refresh Scene Edit overlay after layout change
        if case .sceneEdit = session.state?.uiMode {
            sceneEditController?.updateOverlay()
        }
    }

    private func setupRenderer() {
        guard let device = metalView.device else { log("ERROR: No Metal device"); return }
        do {
            let clearCol = ClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
            renderer = try MetalRenderer(
                device: device,
                colorPixelFormat: metalView.colorPixelFormat,
                options: MetalRendererOptions(
                    clearColor: clearCol,
                    enableDiagnostics: true,
                    maxFramesInFlight: Self.maxFramesInFlight  // Must match inFlightSemaphore
                )
            )
            log("MetalRenderer initialized (maxFramesInFlight=\(Self.maxFramesInFlight))")
        } catch { log("ERROR: MetalRenderer failed: \(error)") }
    }

    // MARK: - Export

    @objc private func exportTapped() {
        guard !(runtime?.isExporting ?? false) else {
            log("[Export] Export already in progress")
            return
        }
        guard loadingState == .ready else {
            log("[Export] ERROR: Template not ready")
            return
        }
        guard let rt = runtime else { return }
        rt.startExport()
        guard rt.state == .exporting else { return } // gate rejected (missing media)
        Task { await rt.executeExport() }
    }

    // MARK: - Background Editor (PR3)

    @objc private func backgroundTapped() {
        guard loadingState == .ready else {
            log("[Background] Template not ready")
            return
        }

        let templateBackground = runtime?.templateBackground
        let editor = BackgroundEditorViewController(
            presetLibrary: session.backgroundPresetProvider,
            templateBackground: templateBackground,
            currentOverride: session.state?.draft.background ?? .empty
        )
        editor.delegate = self
        pendingBackgroundEditor = editor

        let nav = UINavigationController(rootViewController: editor)
        nav.isModalInPresentation = true

        // Runtime owns background editor session state
        runtime?.beginBackgroundEditorSession()

        present(nav, animated: true)
    }

    /// Handles background image selection from PHPicker.
    private func handleBackgroundImagePicked(result: PHPickerResult, regionId: String) {
        pendingBackgroundEditor?.isImportInFlight = true
        Task { @MainActor in
            defer { pendingBackgroundEditor?.isImportInFlight = false }
            do {
                let picked = try await PickerAssetAdapter.extractPhoto(from: result)
                guard case .photo(let tempURL) = picked else { return }
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await saveAndSetBackgroundImage(from: tempURL, for: regionId)
            } catch {
                log("[Background] Failed to handle picked image: \(error.localizedDescription)")
            }
        }
    }

    /// Forwards background image import to runtime (which owns all bookkeeping).
    private func saveAndSetBackgroundImage(from sourceFileURL: URL, for regionId: String) async throws {
        guard let rt = runtime else { return }

        let editor = pendingBackgroundEditor
        do {
            try await rt.importBackgroundImage(
                sourceFileURL: sourceFileURL,
                regionId: regionId,
                setEditorImage: { [weak editor] regionId, ref in editor?.setImage(for: regionId, mediaRef: ref) }
            )
        } catch is BackgroundImportStaleError {
            log("[Background] Import stale — cleaned up by runtime")
            return
        }

        if !rt.hasActiveBackgroundEditor {
            pendingBackgroundEditor = nil
        }

        metalView.setNeedsDisplay()
    }

    // MARK: - Export UI

    /// Shows alert recommending lower quality when memory is constrained.
    private func showLowerPresetAlert(
        suggestedPreset: VideoQualityPreset,
        suggestedSizePx: (width: Int, height: Int)
    ) async -> EditorRuntime.ExportPreflightChoice {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Memory Warning",
                message: "This project may be too large to export at the current quality. We recommend reducing the quality to \(suggestedSizePx.width)x\(suggestedSizePx.height) for a stable export.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Reduce Quality", style: .default) { _ in
                continuation.resume(returning: .useRecommended(
                    preset: suggestedPreset,
                    sizePx: suggestedSizePx
                ))
            })
            alert.addAction(UIAlertAction(title: "Continue as-is", style: .default) { _ in
                continuation.resume(returning: .continueOriginal)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: .cancel)
            })
            self.present(alert, animated: true)
        }
    }

    private func presentSavedToPhotosAlert() {
        let alert = UIAlertController(title: "Saved to Photos",
            message: "Your video has been saved to the Photos library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentPhotoLibraryPermissionAlert() {
        let alert = UIAlertController(title: "Photos Access Required",
            message: "Animi needs permission to save videos to your Photos library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func presentExportError(_ error: Error) {
        let alert = UIAlertController(
            title: "Export Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.addAction(UIAlertAction(title: "Copy Error Details", style: .default) { _ in
            UIPasteboard.general.string = error.localizedDescription
        })
        present(alert, animated: true)
    }

    @objc private func playPauseTapped() {
        // PR-G: Check both isPlaying AND pending prewarm task via runtime
        if runtime?.isPlaying == true {
            runtime?.stopPlayback()
        } else {
            runtime?.startPlayback()
        }
    }

    // PR-D: Tap handler for Scene Edit mode (on overlayView)
    @objc private func overlayViewTapped(_ recognizer: UITapGestureRecognizer) {
        guard case .sceneEdit = session.state?.uiMode else { return }
        let point = recognizer.location(in: overlayView)
        sceneEditController?.handleTap(viewPoint: point)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard case .sceneEdit = session.state?.uiMode else { return }
        sceneEditController?.handlePan(recognizer)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard case .sceneEdit = session.state?.uiMode else { return }
        sceneEditController?.handlePinch(recognizer)
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard case .sceneEdit = session.state?.uiMode else { return }
        sceneEditController?.handleRotation(recognizer)
    }

    // MARK: - User Media Actions (PR-32)

    @objc private func addPhotoTapped() {
        guard session.state?.selectedBlockId != nil else { return }
        presentPhotoPicker(for: .images)
    }

    /// Handles ingest completion from MediaIngestCoordinator.
    ///
    /// Identity contract:
    /// 1. Check target scene still exists in timeline (prevent resurrection of deleted scene).
    /// 2. Persist slot to store for result.sceneInstanceId (always, if scene exists).
    /// 3. Runtime apply ONLY if activeSceneInstanceId == result.sceneInstanceId.
    /// 4. If target scene was deleted, delete the persisted file (orphan cleanup).
    @MainActor
    private func handleIngestComplete(_ result: IngestResult) async {
        let timeline = session.state?.canonicalTimeline

        // Guard: target scene must still exist in the timeline
        guard let sceneItem = timeline?.sceneItems.first(where: { $0.id == result.sceneInstanceId }) else {
            // Scene was deleted while ingest was in-flight — clean up persisted file.
            // PR5 Phase E: `onAssetPersisted` already registered the descriptor
            // BEFORE we got here. The slot was never dispatched, so the asset
            // is not referenced by any content — safe to unregister directly.
            session.unregisterAssetBookkeeping(result.mediaRef.assetId)
            try? FileManager.default.removeItem(at: result.persistedURL)
            log("[UserMedia] Ingest completed for deleted scene \(result.sceneInstanceId), cleaned up orphan")
            return
        }

        // Resolve defaultFit from template metadata of the target scene
        let defaultFit: FitMode = await resolveDefaultFitAsync(
            sceneItem: sceneItem,
            timeline: timeline,
            blockId: result.blockId
        )

        // Re-validate: scene may have been deleted during async defaultFit resolution
        let currentTimeline = session.state?.canonicalTimeline
        guard currentTimeline?.sceneItems.contains(where: { $0.id == result.sceneInstanceId }) == true else {
            // PR5 Phase E: unregister pre-emptively registered descriptor.
            session.unregisterAssetBookkeeping(result.mediaRef.assetId)
            try? FileManager.default.removeItem(at: result.persistedURL)
            log("[UserMedia] Scene \(result.sceneInstanceId) deleted during defaultFit resolution, cleaned up orphan")
            return
        }

        let placement = MediaPlacementState.default(fitMode: defaultFit)

        // Build final slot with non-nil placement
        let slot: SceneMediaSlot
        switch result.mediaKind {
        case .photo:
            slot = .photo(mediaRef: result.mediaRef, placement: placement)
        case .video:
            guard let videoWindow = result.videoWindow else {
                assertionFailure("[UserMedia] Video ingest missing videoWindow")
                // PR5 Phase E: unregister pre-emptively registered descriptor.
                session.unregisterAssetBookkeeping(result.mediaRef.assetId)
                try? FileManager.default.removeItem(at: result.persistedURL)
                log("[UserMedia] Video ingest missing videoWindow, cleaned up orphan")
                return
            }
            slot = .video(mediaRef: result.mediaRef, placement: placement, videoWindow: videoWindow)
        }

        // PR5 Phase E: Pre-capture the currently bound asset ID (if any) so
        // we can unregister it after the replace lands in the draft — only
        // if the old ID is no longer referenced anywhere else.
        let oldAssetId = session.state?.draft
            .sceneInstanceStates[result.sceneInstanceId]?
            .mediaSlotsByBlockId?[result.blockId]?.mediaRef.assetId

        // Persist slot to store
        session.dispatch(.setMediaSlot(
            sceneInstanceId: result.sceneInstanceId,
            blockId: result.blockId,
            slot: slot
        ))

        // PR5 Phase E: Unregister the old descriptor if it was replaced and
        // is no longer referenced anywhere in the draft.
        if let oldAssetId, oldAssetId != result.mediaRef.assetId {
            session.unregisterAssetIfUnreferenced(oldAssetId)
        }

        log("[UserMedia] Ingest complete for block '\(result.blockId)'@\(result.sceneInstanceId): \(result.mediaRef.storagePath)")
    }

    /// Resolves defaultFit from template metadata via scene-type resources cache.
    /// For cold/inactive scenes, preloads metadata asynchronously before retry.
    private func resolveDefaultFitAsync(
        sceneItem: TimelineItem,
        timeline: CanonicalTimeline?,
        blockId: String
    ) async -> FitMode {
        guard let payload = timeline?.payloads[sceneItem.payloadId],
              case .scene(let scenePayload) = payload,
              let rt = runtime else {
            return .cover
        }
        return await rt.resolveDefaultFitMode(sceneTypeId: scenePayload.sceneTypeId, blockId: blockId)
    }

    private func presentPhotoPicker(for filter: PHPickerFilter) {
        var config = PHPickerConfiguration()
        config.filter = filter
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: - PR-E: Scene Edit Media Picker

    /// Presents media picker for Scene Edit with deterministic blockId tracking.
    /// - Parameters:
    ///   - blockId: The block ID for which media is being picked
    ///   - kind: Whether to pick photo or video
    private func presentMediaPicker(for blockId: String, kind: MediaKind) {
        // Capture identity at picker-open time (not at callback time)
        assertSceneEditTargetMatchesRuntimeIfPossible()
        guard let instanceId = sceneEditTargetInstanceId else {
            log("[UserMedia] No scene edit target, cannot open picker")
            return
        }
        pendingPickerRequest = IngestSlotKey(sceneInstanceId: instanceId, blockId: blockId)

        var config = PHPickerConfiguration()
        config.filter = (kind == .photo) ? .images : .videos
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Presents variant picker as action sheet for Scene Edit (PR-E).
    /// - Parameter blockId: The block ID for which to show variants
    private func presentVariantPicker(blockId: String) {
        guard let rt = runtime else { return }

        let ctx = rt.mediaActionBarContext(blockId: blockId)
        let variants = ctx.availableVariants
        guard !variants.isEmpty else { return }

        // Get current variant for checkmark
        let currentVariantId = ctx.selectedVariantId

        let alert = UIAlertController(title: "Animation", message: nil, preferredStyle: .actionSheet)

        for variant in variants {
            let action = UIAlertAction(title: variant.id, style: .default) { [weak self] _ in
                self?.applyVariant(blockId: blockId, variantId: variant.id)
            }
            // Show checkmark for current variant
            if variant.id == currentVariantId {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad support: configure popover
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        present(alert, animated: true)
    }

    /// Applies variant selection to runtime and persists to store (PR-E).
    private func applyVariant(blockId: String, variantId: String) {
        // 1. Apply to runtime
        runtime?.setSelectedVariant(blockId: blockId, variantId: variantId)
        metalView.setNeedsDisplay()

        // 2. Update overlay
        sceneEditController?.updateOverlay()

        // 3. Persist to store
        assertSceneEditTargetMatchesRuntimeIfPossible()
        guard let instanceId = sceneEditTargetInstanceId else { return }
        session.dispatch(.setBlockVariant(
            sceneInstanceId: instanceId,
            blockId: blockId,
            variantId: variantId
        ))
    }

    // MARK: - Scene Catalog

    /// Presents the scene catalog for adding a new scene.
    private func presentSceneCatalog() {
        guard let library = sceneLibrarySnapshot else {
            log("[SceneCatalog] presentSceneCatalog: sceneLibrarySnapshot is nil")
            let alert = UIAlertController(
                title: "Scenes Unavailable",
                message: "Scene library could not be loaded. Please try again.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let catalogVC = SceneCatalogViewController(sceneLibrary: library)
        catalogVC.onSelectScene = { [weak self] sceneTypeId, baseDurationUs in
            self?.handleAddScene(sceneTypeId: sceneTypeId, baseDurationUs: baseDurationUs)
        }

        let navController = UINavigationController(rootViewController: catalogVC)
        present(navController, animated: true)
    }

    /// Handles scene selection from catalog.
    private func handleAddScene(sceneTypeId: String, baseDurationUs: TimeUs) {
        // Dispatch addScene action to store
        session.dispatch(.addScene(sceneTypeId: sceneTypeId, durationUs: baseDurationUs))
        log("[SceneCatalog] Added scene: \(sceneTypeId) duration=\(baseDurationUs)us")
    }

    override var prefersStatusBarHidden: Bool {
        fullScreenPreviewVC != nil
    }

    // MARK: - Project Music (PR8)

    private lazy var musicImportCoordinator = ProjectMusicImportCoordinator(session: session)

    // MARK: - PR9: Text Editor

    /// Presents the text editor modal for adding or editing a text overlay.
    private func presentTextEditor(existingPayload: TextPayload?, itemId: UUID?) {
        let editor = TextEditorViewController(payload: existingPayload)
        editor.onCommit = { [weak self] payload in
            guard let self = self else { return }
            if let itemId = itemId {
                // Edit existing
                self.session.dispatch(.updateTextPayload(itemId: itemId, payload: payload))
            } else {
                // Add new: place at playhead position
                let playheadFrame = self.session.state?.playheadCompressedFrame ?? 0
                let mapper = self.session.state?.makePlayheadMapper()
                let startUs = mapper?.nominalTimeUs(forCompressedFrame: playheadFrame) ?? 0
                let defaultDuration: TimeUs = 3_000_000 // 3 seconds
                self.session.dispatch(.addTextOverlay(
                    text: payload.text,
                    fontSize: payload.fontSize ?? 32,
                    colorHex: payload.colorHex ?? "#FFFFFF",
                    fontFamily: payload.fontFamily,
                    startUs: startUs,
                    durationUs: defaultDuration
                ))
            }
        }
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    /// PR10: Presents the sticker picker. If changingItemId is set, replaces the sticker on that item.
    private func presentStickerPicker(changingItemId: UUID?) {
        let picker = StickerPickerViewController(stickerProvider: session.stickerProvider)
        picker.onStickerSelected = { [weak self] stickerId in
            guard let self = self else { return }
            if let itemId = changingItemId {
                // Change existing sticker
                var payload = self.session.state?.canonicalTimeline.stickerPayload(for: itemId) ?? StickerPayload(stickerId: stickerId)
                payload.stickerId = stickerId
                self.session.dispatch(.updateStickerPayload(itemId: itemId, payload: payload))
            } else {
                // Add new sticker at playhead
                let playheadFrame = self.session.state?.playheadCompressedFrame ?? 0
                let mapper = self.session.state?.makePlayheadMapper()
                let startUs = mapper?.nominalTimeUs(forCompressedFrame: playheadFrame) ?? 0
                let defaultDuration: TimeUs = 3_000_000 // 3 seconds
                self.session.dispatch(.addStickerOverlay(
                    stickerId: stickerId,
                    startUs: startUs,
                    durationUs: defaultDuration
                ))
            }
        }
        present(picker, animated: true)
    }

    /// Presents a document picker for importing audio files.
    private func presentMusicPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    /// Forwards music import to the dedicated coordinator.
    private func importProjectMusic(tempURL: URL, originalExtension: String) {
        musicImportCoordinator.importProjectMusic(tempURL: tempURL, originalExtension: originalExtension)
    }

    /// Presents a volume slider alert for the music track.
    private func presentMusicVolumeSlider(itemId: UUID) {
        guard let payload = session.state?.canonicalTimeline.musicPayload() else { return }

        let alert = UIAlertController(
            title: "Music Volume",
            message: "\n\n",
            preferredStyle: .alert
        )

        let slider = UISlider()
        slider.minimumValue = 0.0
        slider.maximumValue = 1.0
        slider.value = payload.volume
        slider.translatesAutoresizingMaskIntoConstraints = false

        alert.view.addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: alert.view.trailingAnchor, constant: -20),
            slider.topAnchor.constraint(equalTo: alert.view.topAnchor, constant: 60),
        ])

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self] _ in
            self?.session.dispatch(.setProjectMusicVolume(itemId: itemId, volume: slider.value))
        })

        present(alert, animated: true)
    }

    /// Presents a modal trim editor for the music track.
    /// Shows current trim start/end as text fields clamped to source duration.
    private func presentMusicTrimEditor(itemId: UUID) {
        guard let payload = session.state?.canonicalTimeline.musicPayload() else { return }

        let sourceDurationSec = usToSeconds(payload.sourceDurationUs)
        let currentStartSec = usToSeconds(payload.trimStartUs)
        let currentEndSec = usToSeconds(payload.trimEndUs)

        let alert = UIAlertController(
            title: "Trim Music",
            message: String(format: "Source duration: %.1fs", sourceDurationSec),
            preferredStyle: .alert
        )

        alert.addTextField { field in
            field.placeholder = "Start (seconds)"
            field.text = String(format: "%.1f", currentStartSec)
            field.keyboardType = .decimalPad
        }

        alert.addTextField { field in
            field.placeholder = "End (seconds)"
            field.text = String(format: "%.1f", currentEndSec)
            field.keyboardType = .decimalPad
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self] _ in
            guard let self,
                  let startText = alert.textFields?[0].text,
                  let endText = alert.textFields?[1].text,
                  let startSec = Double(startText),
                  let endSec = Double(endText) else { return }

            let clampedStartSec = max(0, min(startSec, sourceDurationSec))
            let clampedEndSec = max(clampedStartSec, min(endSec, sourceDurationSec))
            let trimStartUs = secondsToUs(clampedStartSec)
            let trimEndUs = secondsToUs(clampedEndSec)

            self.session.dispatch(.setProjectMusicTrim(
                itemId: itemId,
                trimStartUs: trimStartUs,
                trimEndUs: trimEndUs
            ))
        })

        present(alert, animated: true)
    }

    // MARK: - Load Pre-Compiled Template (Release Path - PR2)

    /// PR-D: Updates UI based on loading state.
    private func updateLoadingStateUI() {
        switch loadingState {
        case .idle:
            preparingOverlay.hide()

        case .preparing:
            preparingOverlay.reset()
            preparingOverlay.show(text: "Loading template...")

        case .ready:
            preparingOverlay.hide()

        case .failed(let message):
            preparingOverlay.showError(message)
        }
    }

    // MARK: - Release v1: Scene Type Loading

    /// Loads a scene type from the SceneLibrary.
    /// Uses sceneLibrarySnapshot.folderURL for scene resolution.
    private func loadSceneTypeFromBundle(sceneTypeId: String) {
        runtime?.stopPlayback()
        renderErrorLogged = false
        log("---\n[Release v1] Loading scene type '\(sceneTypeId)'...")

        guard let device = metalView.device else {
            log("ERROR: No Metal device")
            loadingState = .failed(message: "No Metal device")
            updateLoadingStateUI()
            return
        }

        // Get scene folder URL from SceneLibrary
        guard let sceneDescriptor = sceneLibrarySnapshot?.scene(byId: sceneTypeId),
              let sceneURL = sceneDescriptor.folderURL else {
            log("ERROR: Scene type '\(sceneTypeId)' not found in library")
            loadingState = .failed(message: "Scene not found")
            updateLoadingStateUI()
            return
        }

        // PR-D: Cancel previous loading task if any
        preparingTask?.cancel()

        // PR-D: Generate new request ID for cancellation check
        let requestId = UUID()
        currentRequestId = requestId
        loadingState = .preparing(requestId: requestId)
        updateLoadingStateUI()

        // Async loading pipeline — runtime owns scene/texture construction
        preparingTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                try Task.checkCancellation()

                guard let queue = await MainActor.run(body: { self.commandQueue }) else { return }

                let loadResult = try await EditorRuntime.loadInitialScene(
                    sceneTypeId: sceneTypeId,
                    sceneURL: sceneURL,
                    device: device,
                    commandQueue: queue,
                    onStatus: { [weak self] status in
                        self?.preparingOverlay.setStatus(status)
                    }
                )

                guard !Task.isCancelled, self.currentRequestId == requestId else { return }

                await MainActor.run {
                    self.applyLoadedSceneType(
                        loadResult: loadResult,
                        requestId: requestId
                    )
                }

            } catch is CancellationError {
                await MainActor.run { self.log("Scene load cancelled") }
            } catch {
                guard self.currentRequestId == requestId else { return }
                await MainActor.run {
                    self.log("ERROR: Failed to load scene: \(error)")
                    self.loadingState = .failed(message: "Failed to load scene")
                    self.updateLoadingStateUI()
                }
            }
        }
    }

    /// Release v1: Applies loaded scene type to UI.
    private func applyLoadedSceneType(
        loadResult: EditorRuntime.InitialSceneLoadResult,
        requestId: UUID
    ) {
        guard currentRequestId == requestId else {
            log("Scene load result discarded")
            return
        }

        // Log preload stats
        if let stats = loadResult.preloadStats {
            log(String(format: "[Preload] loaded: %d, missing: %d, skipped: %d, duration: %.1fms",
                       stats.loadedCount, stats.missingCount, stats.skippedBindingCount, stats.durationMs))
        }

        let sceneRuntime = loadResult.compiled.runtime
        let canvasSize = sceneRuntime.canvasSize
        let canvasSizeStr = "\(Int(canvasSize.width))x\(Int(canvasSize.height))"
        log("[Release v1] Scene loaded: \(canvasSizeStr) @ \(sceneRuntime.fps)fps, \(sceneRuntime.durationFrames) frames")

        // Configure editor timeline — runtime handles scene boot + background internally
        configureEditorTimeline(loadResult: loadResult)

        // Transition to ready state
        loadingState = .ready
        updateLoadingStateUI()

        // Flush deferred missing-media notice if VC is already visible
        if viewIfLoaded?.window != nil {
            flushMissingMediaNoticeIfNeeded()
        }

        // Trigger first frame render
        metalView.setNeedsDisplay()
    }

    // MARK: - Playback (delegated to EditorRuntime)

    // MARK: - Logging

    private func log(_ message: String) {
        logger.info("\(message)")
    }

    // MARK: - Scrub Render Throttle (A/B Testing)

    /// Requests Metal render with optional throttling during scrub drag.
    /// Used for A/B testing render pipeline bottleneck hypothesis.
    /// - Only applies throttle/skip when `isScrubDragging == true`
    /// - Otherwise passes through to `metalView.setNeedsDisplay()` immediately
    private func requestMetalRender() {
        #if DEBUG
        // Only apply throttle/skip during active scrub drag
        guard isScrubDragging else {
            metalView.setNeedsDisplay()
            return
        }

        // H3: Skip render entirely during drag (test if render is the bottleneck)
        if ScrubDebugToggles.skipMetalRender {
            pendingScrubRender = true
            return
        }

        // H3-throttle: Limit render to 30Hz during drag
        if ScrubDebugToggles.throttleRender30Hz {
            let now = CACurrentMediaTime()
            let minInterval = 1.0 / 30.0  // 33.3ms
            if now - lastScrubRenderAt < minInterval {
                pendingScrubRender = true
                return
            }
            lastScrubRenderAt = now
            pendingScrubRender = false
        }
        #endif

        metalView.setNeedsDisplay()
    }
}

// MARK: - MTKViewDelegate

extension EditorViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

    func draw(in view: MTKView) {
        // Model A contract: draw must execute on main thread
        dispatchPrecondition(condition: .onQueue(.main))

        // PR-D.1: No draw while template is loading (prevents race with background preload)
        guard loadingState == .ready else { return }
        guard let runtime = runtime else { return }

        switch runtime.currentRenderSource {
        case .timeline(let payload):
            renderTimeline(in: view, payload: payload)
        case .sceneEdit(let payload):
            renderSceneEdit(in: view, payload: payload)
        case .none:
            return
        }
    }

    /// Renders timeline mode from runtime payload.
    private func renderTimeline(in view: MTKView, payload: TimelineRenderSourcePayload) {
        switch payload.resolvedFrame {
        case .single(let ctx):
            renderTimelineSingleScene(in: view, context: ctx, payload: payload)
        case .transition:
            renderTimelineTransition(in: view, payload: payload)
        }
    }

    /// Renders single scene in timeline mode via runtime render executor.
    private func renderTimelineSingleScene(in view: MTKView, context ctx: SceneRenderContext, payload: TimelineRenderSourcePayload) {
        guard ctx.canvasSize.width > 0 else { return }
        guard let renderer = renderer,
              let cmdQueue = commandQueue else { return }

        // PR-A: Non-blocking wait for in-flight frame slot
        let semResult = inFlightSemaphore.wait(timeout: .now())
        if semResult == .timedOut {
            #if DEBUG
            perfLogger.recordDroppedFrame()
            #endif
            return
        }

        guard let drawable = view.currentDrawable else {
            inFlightSemaphore.signal()
            return
        }

        #if DEBUG
        perfLogger.recordFrame()
        #endif

        let request = TimelineRenderRequest(
            resolved: .single(ctx),
            targetTexture: drawable.texture,
            drawableScale: Double(view.contentScaleFactor),
            timelineCanvasSize: ctx.canvasSize,
            backgroundState: payload.backgroundState,
            backgroundTextureProvider: payload.backgroundTextureProvider,
            clearColorOverride: nil,
            presentationDrawable: drawable,
            waitUntilCompleted: false,
            diagnosticFrameTag: payload.diagnosticFrameTag,
            textOverlays: payload.textOverlays,
            stickerOverlays: payload.stickerOverlays
        )

        do {
            try runtime?.executeTimelineRender(
                request, renderer: renderer,
                commandQueue: cmdQueue,
                needsTransitionCompositor: false,
                completionQueue: nil,
                onCommandBufferCompleted: { [weak self] _ in self?.inFlightSemaphore.signal() }
            )
        } catch {
            inFlightSemaphore.signal()
            if !renderErrorLogged {
                renderErrorLogged = true
                log("Render error: \(error)")
            }
        }
    }

    /// Renders transition between two scenes via runtime render executor.
    /// Fallback: render scene B only if compositor unavailable (instant cut behavior).
    private func renderTimelineTransition(in view: MTKView, payload: TimelineRenderSourcePayload) {
        guard case .transition(let transCtx) = payload.resolvedFrame else { return }
        guard let renderer = renderer,
              let cmdQueue = commandQueue,
              runtime?.hasTransitionCompositor == true else {
            // Fallback: render scene B only (instant cut behavior)
            drawWithParams(
                in: view,
                commands: transCtx.sceneB.commands,
                textureProvider: transCtx.sceneB.textureProvider,
                pathRegistry: transCtx.sceneB.pathRegistry,
                assetSizes: transCtx.sceneB.assetSizes,
                animSize: transCtx.sceneB.canvasSize,
                backgroundState: payload.backgroundState,
                backgroundTextureProvider: payload.backgroundTextureProvider
            )
            return
        }

        // PR-A: Non-blocking wait for in-flight frame slot
        let semResult = inFlightSemaphore.wait(timeout: .now())
        if semResult == .timedOut {
            #if DEBUG
            perfLogger.recordDroppedFrame()
            #endif
            return
        }

        guard let drawable = view.currentDrawable else {
            inFlightSemaphore.signal()
            return
        }

        #if DEBUG
        perfLogger.recordFrame()
        #endif

        let request = TimelineRenderRequest(
            resolved: payload.resolvedFrame,
            targetTexture: drawable.texture,
            drawableScale: Double(view.contentScaleFactor),
            timelineCanvasSize: transCtx.sceneA.canvasSize,
            backgroundState: payload.backgroundState,
            backgroundTextureProvider: payload.backgroundTextureProvider,
            clearColorOverride: nil,
            presentationDrawable: drawable,
            waitUntilCompleted: false,
            diagnosticFrameTag: payload.diagnosticFrameTag,
            textOverlays: payload.textOverlays,
            stickerOverlays: payload.stickerOverlays
        )

        do {
            try runtime?.executeTimelineRender(
                request, renderer: renderer,
                commandQueue: cmdQueue,
                needsTransitionCompositor: true,
                completionQueue: .main,
                onCommandBufferCompleted: { [weak self] _ in self?.inFlightSemaphore.signal() }
            )
        } catch {
            inFlightSemaphore.signal()
            if !renderErrorLogged {
                renderErrorLogged = true
                log("[TT-06] Transition render error: \(error)")
            }
        }
    }

    /// Renders Scene Edit mode from runtime payload.
    private func renderSceneEdit(in view: MTKView, payload: SceneEditRenderSourcePayload) {
        drawWithParams(
            in: view,
            commands: payload.commands,
            textureProvider: payload.textureProvider,
            pathRegistry: payload.pathRegistry,
            assetSizes: payload.assetSizes,
            animSize: payload.canvasSize,
            backgroundState: payload.backgroundState,
            backgroundTextureProvider: payload.backgroundTextureProvider
        )
    }

    /// PR-F: Common render path with resolved parameters.
    private func drawWithParams(
        in view: MTKView,
        commands: [RenderCommand],
        textureProvider provider: TextureProvider,
        pathRegistry: PathRegistry,
        assetSizes: [String: AssetSize],
        animSize: SizeD,
        backgroundState: EffectiveBackgroundState? = nil,
        backgroundTextureProvider: (any TextureProvider)? = nil
    ) {
        guard animSize.width > 0 else { return }

        // PR1.5: Split timing - start
        #if DEBUG
        let tSemStart = CACurrentMediaTime()
        #endif

        // PR-A: Non-blocking wait for in-flight frame slot
        let semResult = inFlightSemaphore.wait(timeout: .now())
        if semResult == .timedOut {
            #if DEBUG
            perfLogger.recordDroppedFrame()
            #endif
            return
        }

        #if DEBUG
        let tSemEnd = CACurrentMediaTime()
        #endif

        guard let drawable = view.currentDrawable,
              let cmdQueue = commandQueue,
              let cmdBuf = cmdQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        cmdBuf.addCompletedHandler { [weak self] cb in
            self?.inFlightSemaphore.signal()
            #if DEBUG
            if let s = GPUFrameTime.fromCompleted(commandBuffer: cb) {
                self?.perfLogger.recordGPUSample(s.gpuMs)
            }
            #endif
        }

        #if DEBUG
        perfLogger.recordFrame()
        let drawT0 = CACurrentMediaTime()
        var tEncodeEnd: CFAbsoluteTime = tSemEnd
        #endif

        if let renderer = renderer {
            let target = RenderTarget(
                texture: drawable.texture,
                drawableScale: Double(view.contentScaleFactor),
                animSize: animSize
            )

            do {
                // PR-G: Split-pass architecture (same as timeline single-scene path)
                // Pass 1: Background pre-pass with backgroundTextureProvider
                let bgProvider: TextureProvider = backgroundTextureProvider ?? InMemoryTextureProvider()
                try renderer.draw(
                    commands: [],
                    target: target,
                    textureProvider: bgProvider,
                    commandBuffer: cmdBuf,
                    assetSizes: [:],
                    pathRegistry: PathRegistry(),
                    backgroundState: backgroundState,
                    initialLoadAction: .clear
                )

                // Pass 2: Scene pass (preserves background)
                try renderer.draw(
                    commands: commands,
                    target: target,
                    textureProvider: provider,
                    commandBuffer: cmdBuf,
                    assetSizes: assetSizes,
                    pathRegistry: pathRegistry,
                    backgroundState: nil,
                    initialLoadAction: .load
                )
                #if DEBUG
                tEncodeEnd = CACurrentMediaTime()
                #endif
            } catch {
                if !renderErrorLogged {
                    renderErrorLogged = true
                    log("Render error: \(error)")
                }
            }
        } else if let desc = view.currentRenderPassDescriptor,
                  let enc = cmdBuf.makeRenderCommandEncoder(descriptor: desc) {
            enc.endEncoding()
        }

        cmdBuf.present(drawable)

        #if DEBUG
        let drawDtMs = (CACurrentMediaTime() - drawT0) * 1000.0
        perfLogger.recordDrawCPU(ms: drawDtMs)
        let semMs = (tSemEnd - tSemStart) * 1000.0
        let encodeMs = (tEncodeEnd - tSemEnd) * 1000.0
        perfLogger.recordSplitTiming(semaphoreMs: semMs, commandsMs: 0, encodeMs: encodeMs)
        #endif

        cmdBuf.commit()
    }
}

// MARK: - UIGestureRecognizerDelegate (PR-19)

extension EditorViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow pinch + rotation simultaneously (for edit mode transforms)
        let isPinchOrRotation = gestureRecognizer is UIPinchGestureRecognizer ||
                                gestureRecognizer is UIRotationGestureRecognizer
        let otherIsPinchOrRotation = otherGestureRecognizer is UIPinchGestureRecognizer ||
                                     otherGestureRecognizer is UIRotationGestureRecognizer
        if isPinchOrRotation && otherIsPinchOrRotation {
            return true
        }

        // Allow scroll view gestures to work simultaneously
        if otherGestureRecognizer.view is UIScrollView {
            return true
        }

        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // PR-E: Pan/pinch/rotation only work in Scene Edit mode WITH a selected block
        if gestureRecognizer is UIPanGestureRecognizer ||
           gestureRecognizer is UIPinchGestureRecognizer ||
           gestureRecognizer is UIRotationGestureRecognizer {
            // Only enable if in Scene Edit mode AND block is selected
            guard case .sceneEdit = session.state?.uiMode else { return false }
            return session.state?.selectedBlockId != nil
        }
        return true
    }
}

// MARK: - PHPickerViewControllerDelegate (PR-32, PR-E)

extension EditorViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let result = results.first else {
            // User cancelled - clear pending state
            pendingPickerRequest = nil
            return
        }

        // PR3: Check if this is a background image picker
        if picker.view.tag == 999, let regionId = pendingBackgroundRegionId {
            pendingBackgroundRegionId = nil
            handleBackgroundImagePicked(result: result, regionId: regionId)
            return
        }

        // Use the request captured at picker-open time — NOT current sceneEditTargetInstanceId.
        // This ensures the media is attributed to the scene that was active when the user opened the picker.
        guard let key = pendingPickerRequest else {
            log("[UserMedia] No pending picker request, skipping ingest")
            return
        }
        pendingPickerRequest = nil

        mediaIngestCoordinator.ingest(pickerResult: result, key: key)
    }

    /// Shows alert when picked media type doesn't match expected type.
    private func showMediaTypeMismatchAlert() {
        let alert = UIAlertController(
            title: "Wrong Media Type",
            message: "Please select the correct type of media.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - BackgroundEditorDelegate (PR3)

extension EditorViewController: BackgroundEditorDelegate {

    func backgroundEditorDidUpdateState(_ state: EffectiveBackgroundState) {
        runtime?.setEffectiveBackgroundState(state)
        metalView.setNeedsDisplay()
    }

    func backgroundEditorDidRequestImagePicker(for regionId: String) {
        // Invalidate any in-flight import from a previous picker request
        runtime?.incrementBackgroundImportGeneration()

        // Store regionId and editor ref for callback
        pendingBackgroundRegionId = regionId
        if let nav = presentedViewController as? UINavigationController,
           let editor = nav.viewControllers.first as? BackgroundEditorViewController {
            pendingBackgroundEditor = editor
        }

        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        // Use a tag to differentiate from user media picker
        picker.view.tag = 999  // Background image picker tag

        // Present from the editor if visible
        if let presented = presentedViewController {
            presented.present(picker, animated: true)
        } else {
            present(picker, animated: true)
        }
    }

    func backgroundEditorDidChangePreset(oldPresetId: String, newPresetId: String) {
        runtime?.handleBackgroundPresetChange(oldPresetId: oldPresetId, newPresetId: newPresetId)
        metalView.setNeedsDisplay()
    }

    func backgroundEditorWillDismiss(override: ProjectBackgroundOverride, presetId: String) {
        pendingBackgroundEditor = nil
        runtime?.commitBackgroundEditorDismiss(override: override, presetId: presetId)
        metalView.setNeedsDisplay()
    }
}

// MARK: - UIDocumentPickerDelegate (PR8: Music Import)

extension EditorViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // Start security-scoped access
        guard url.startAccessingSecurityScopedResource() else {
            log("[Music] Failed to access security-scoped resource")
            return
        }

        // Synchronous temp copy while security scope is open
        let ext = url.pathExtension
        let tempFilename = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(tempFilename)
        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.copyItem(at: url, to: tempURL)
        } catch {
            url.stopAccessingSecurityScopedResource()
            log("[Music] Failed to copy to temp: \(error)")
            return
        }

        // Security scope no longer needed — temp copy is local
        url.stopAccessingSecurityScopedResource()

        // Async persist from temp copy
        importProjectMusic(tempURL: tempURL, originalExtension: ext)
    }
}

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
