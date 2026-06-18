import UIKit
import MetalKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import TVECore
import os.log
#if DEBUG
import MetalPerformanceShaders
#endif

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

    // MARK: - Internal Owners (PR11)
    private(set) lazy var bootstrapController = EditorBootstrapController(viewController: self)
    private(set) lazy var timelineController = EditorTimelineController(viewController: self)
    private(set) lazy var exportFlowController = EditorExportFlowController(viewController: self)
    private(set) lazy var backgroundFlowController = EditorBackgroundFlowController(viewController: self)
    private(set) lazy var mediaFlowController = EditorMediaFlowController(viewController: self)
    private(set) lazy var presentationController_ = EditorPresentationController(viewController: self)

    // MARK: - Runtime

    internal(set) var runtime: EditorRuntime?

    // MARK: - Session

    let session: EditorSession
    /// True when session emitted a missing-media notice that hasn't been presented yet.
    var hasDeferredMissingMediaNotice = false

    init(session: EditorSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        #if DEBUG
        MemoryDiagnostics.event("EditorViewController.deinit", "obj=\(ObjectIdentifier(self).hashValue)")
        MemoryDiagnostics.signpostEvent("editor.close")
        #endif
        autosaveCoordinator?.stopFromDeinit()
        NotificationCenter.default.removeObserver(self, name: .appDidEnterBackground, object: nil)
        _mediaIngestCoordinator?.cancelAllFromDeinit()
        #if DEBUG
        MemoryDiagnostics.checkpoint("editor.close.after")
        #endif
    }

    @objc private func appDidEnterBackground() {
        if !userMadeExplicitCloseChoice {
            autosaveCoordinator?.handleBackgrounding()
        }
    }

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

    private lazy var _commandQueue: MTLCommandQueue? = { metalView.device?.makeCommandQueue() }()
    private var renderer: MetalRenderer?
    #if DEBUG
    var debugRenderer: MetalRenderer? { renderer }

    // CP2/CP3 Next-bridge (DEBUG only) transient state.
    var nextBridgeErrorLogged = false
    var nextBridgeErrorLabel: UILabel?
    /// CP3: cached preview context + bounded frame cache + async scheduler.
    var nextPreviewController: NextPreviewController?
    /// CP3: an async render failure to surface inside the next valid `draw(in:)` cycle.
    var pendingNextBridgeError: Error?
    /// assetId.rawValue -> resolved absolute file URL (async-populated cache).
    var nextBridgeMediaURLCache: [String: URL] = [:]
    var nextBridgeMediaResolveInFlight: Set<String> = []
    #endif

    // MARK: - Scrub Render Throttle (A/B Testing)
    var isScrubDragging = false
    var lastScrubRenderAt: CFTimeInterval = 0
    var pendingScrubRender = false
    var renderErrorLogged = false

    // MARK: - Release v1: Scene Library
    var sceneLibrarySnapshot: SceneLibrarySnapshot?

    // MARK: - PR2: Visual Editor Timeline
    var userMadeExplicitCloseChoice = false
    var autosaveCoordinator: EditorAutosaveCoordinator?
    lazy var editorLayoutContainer = EditorLayoutContainerView()
    weak var fullScreenPreviewVC: FullScreenPreviewViewController?

    // MARK: - User Media (PR-32)
    lazy var overlayView = EditorOverlayView()
    lazy var overlayPositionDrag = OverlayPositionDragView()

    // MARK: - Scene Edit Mode (PR-D)
    var sceneEditModule: SceneEditToolModule?

    // MARK: - Media Ingest
    lazy var ingestStatusOverlayView = MediaIngestStatusOverlayView()

    // MARK: - PR5 Phase E: Asset Registry Bookkeeping Helper

    private func selfHealedRegistry() -> ProjectAssetRegistry {
        guard let draft = session.state?.draft else { return ProjectAssetRegistry() }
        return draft.assetRegistry.selfHealed(for: draft)
    }

    var _mediaIngestCoordinator: MediaIngestCoordinator?

    var mediaIngestCoordinator: MediaIngestCoordinator {
        if let coordinator = _mediaIngestCoordinator {
            return coordinator
        }
        let assetStore = MediaAssetStore(mediaWriter: self.session.mediaWriter)
        let coordinator = MediaIngestCoordinator(assetStore: assetStore)
        coordinator.onAssetPersisted = { [weak self] descriptor in
            self?.session.registerAssetBookkeeping(descriptor)
        }
        coordinator.onIngestComplete = { [weak self] result in
            guard let self else {
                try? FileManager.default.removeItem(at: result.persistedURL)
                return
            }
            Task { @MainActor [self] in
                await self.mediaFlowController.handleIngestComplete(result)
            }
        }
        coordinator.onStatusChanged = { [weak self] key, status in
            self?.sceneEditModule?.handleIngestStatusChanged(key: key, status: status)
        }
        _mediaIngestCoordinator = coordinator
        return coordinator
    }

    // In-flight frame limiting (must match MetalRendererOptions.maxFramesInFlight)
    private static let maxFramesInFlight = 3
    private let inFlightSemaphore = DispatchSemaphore(value: maxFramesInFlight)

    // MARK: - PR-D: Async Template Loading
    var loadingState: TemplateLoadingState = .idle
    lazy var preparingOverlay = PreparingOverlayView()

    // PR1.3: Performance logging (DEBUG only)
    #if DEBUG
    private let perfLogger = PerfLogger(intervalSeconds: 2.0)
    #endif

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        #if DEBUG
        MemoryDiagnostics.checkpoint("editor.boot.before")
        #endif
        view.backgroundColor = .systemBackground
        setupRenderer()
        setupEditorLayout()
        let deviceName = metalView.device?.name ?? "N/A"
        log("AnimiApp initialized, TVECore: \(TVECore.version), Metal: \(deviceName)")

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: .appDidEnterBackground, object: nil
        )

        let coordinator = EditorAutosaveCoordinator(session: session)
        coordinator.start(interval: 30)
        autosaveCoordinator = coordinator

        session.onOutput = { [weak self] output in
            self?.bootstrapController.handleSessionOutput(output)
        }
        Task { @MainActor in
            await session.bootstrap()
        }
    }

    // MARK: - PR2: Editor Layout Setup

    private func setupEditorLayout() {
        navigationController?.setNavigationBarHidden(true, animated: false)
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

        editorLayoutContainer.embedMetalView(metalView)
        editorLayoutContainer.embedOverlayView(overlayView)
        editorLayoutContainer.embedOverlayPositionDrag(overlayPositionDrag)
        editorLayoutContainer.embedStatusOverlayView(ingestStatusOverlayView)

        preparingOverlay.translatesAutoresizingMaskIntoConstraints = false
        editorLayoutContainer.addSubview(preparingOverlay)
        NSLayoutConstraint.activate([
            preparingOverlay.topAnchor.constraint(equalTo: editorLayoutContainer.topAnchor),
            preparingOverlay.leadingAnchor.constraint(equalTo: editorLayoutContainer.leadingAnchor),
            preparingOverlay.trailingAnchor.constraint(equalTo: editorLayoutContainer.trailingAnchor),
            preparingOverlay.bottomAnchor.constraint(equalTo: editorLayoutContainer.bottomAnchor),
        ])

        setupOverlayGestureRecognizers()
        wireEditorLayoutCallbacks()
    }

    private func setupOverlayGestureRecognizers() {
        // Double tap opens the existing text editor (confirmed product decision);
        // single tap must wait for it to fail so selection doesn't fight editing.
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(overlayViewDoubleTapped(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        overlayView.addGestureRecognizer(doubleTapGesture)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(overlayViewTapped(_:)))
        tapGesture.require(toFail: doubleTapGesture)
        overlayView.addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))

        panGesture.delegate = self
        pinchGesture.delegate = self
        rotationGesture.delegate = self

        overlayView.addGestureRecognizer(panGesture)
        overlayView.addGestureRecognizer(pinchGesture)
        overlayView.addGestureRecognizer(rotationGesture)
    }

    /// Wires callbacks from EditorLayoutContainerView (Step 8: thin dispatcher)
    private func wireEditorLayoutCallbacks() {
        editorLayoutContainer.onClose = { [weak self] in self?.presentationController_.handleEditorClose() }
        editorLayoutContainer.onExport = { [weak self] in self?.exportFlowController.exportTapped() }
        editorLayoutContainer.onUndo = { [weak self] in self?.session.dispatch(.undo) }
        editorLayoutContainer.onRedo = { [weak self] in self?.session.dispatch(.redo) }
        editorLayoutContainer.onPlayPause = { [weak self] in self?.playPauseTapped() }
        editorLayoutContainer.onFullScreenPreview = { [weak self] in self?.presentationController_.handleFullScreenPreview() }
        editorLayoutContainer.onTimelineEvent = { [weak self] event in self?.timelineController.handleTimelineEvent(event) }

        editorLayoutContainer.onDuplicateScene = { [weak self] sceneId in
            self?.session.dispatch(.duplicateScene(sceneItemId: sceneId))
        }
        editorLayoutContainer.onDeleteScene = { [weak self] sceneId in
            self?.mediaIngestCoordinator.cancelAll(for: sceneId)
            self?.session.dispatch(.deleteScene(sceneId: sceneId))
        }
        editorLayoutContainer.onAddScene = { [weak self] in self?.presentationController_.presentSceneCatalog() }

        editorLayoutContainer.onMusic = { [weak self] in self?.presentationController_.presentMusicPicker() }
        editorLayoutContainer.onRemoveMusic = { [weak self] in self?.session.dispatch(.removeProjectMusic) }
        editorLayoutContainer.onMusicVolume = { [weak self] itemId in self?.presentationController_.presentMusicVolumeSlider(itemId: itemId) }
        editorLayoutContainer.onMusicTrim = { [weak self] itemId in self?.presentationController_.presentMusicTrimEditor(itemId: itemId) }

        editorLayoutContainer.onAddText = { [weak self] in self?.presentationController_.presentTextEditor(existingPayload: nil, itemId: nil) }
        editorLayoutContainer.onEditText = { [weak self] itemId in
            guard let payload = self?.session.state?.canonicalTimeline.textPayload(for: itemId) else { return }
            self?.presentationController_.presentTextEditor(existingPayload: payload, itemId: itemId)
        }
        editorLayoutContainer.onDeleteText = { [weak self] itemId in self?.session.dispatch(.deleteItem(itemId: itemId)) }

        editorLayoutContainer.onSticker = { [weak self] in self?.presentationController_.presentStickerPicker(changingItemId: nil) }
        editorLayoutContainer.onChangeSticker = { [weak self] itemId in self?.presentationController_.presentStickerPicker(changingItemId: itemId) }
        editorLayoutContainer.onDeleteSticker = { [weak self] itemId in self?.session.dispatch(.deleteItem(itemId: itemId)) }

        overlayPositionDrag.onDragPosition = { [weak self] itemId, centerX, centerY, phase in
            self?.session.dispatch(.dragOverlayPosition(itemId: itemId, centerX: centerX, centerY: centerY, phase: phase))
        }

        overlayPositionDrag.onTransform = { [weak self] itemId, centerX, centerY, boxWidth, fontSize, rotation, phase in
            guard let self else { return }
            switch phase {
            case .began:
                // Hide the committed Metal copy with one scoped refresh; the live
                // layer (owned by the drag view) renders the text during the
                // gesture. No store mutation on begin.
                self.runtime?.beginHidingOverlay(itemId)
            case .changed:
                // Transient only: the live layer already updated inside the drag
                // view. Nothing routes through the store/engine/render here.
                break
            case .ended:
                // Stop hiding the committed copy FIRST so the commit's own
                // render sync already includes the text — one combined refresh,
                // not two. Then commit exactly once; the commit sync re-seeds the
                // selection box, tearing down the live layer with the Metal copy
                // already back (no ghost, no flicker).
                self.runtime?.endHidingOverlay(itemId)
                self.session.dispatch(.transformTextBox(
                    itemId: itemId,
                    centerX: centerX,
                    centerY: centerY,
                    boxWidth: boxWidth,
                    fontSize: fontSize,
                    rotation: rotation,
                    phase: .ended
                ))
            case .cancelled:
                // No model mutation. Restore the committed render; the live layer
                // is torn down when the baseline selection is re-applied.
                self.runtime?.endHidingOverlay(itemId)
                self.timelineController.updateOverlayPositionDrag(selection: self.session.state?.selection ?? .none)
            }
        }

        // While a text box is selected the drag overlay owns the surface, so its
        // taps drive selection/edit routing (single tap re-selects, double tap edits).
        overlayPositionDrag.onSingleTap = { [weak self] point in
            self?.handleTimelineOverlayTap(viewPoint: point)
        }
        overlayPositionDrag.onDoubleTap = { [weak self] point in
            self?.handleTimelineDoubleTap(viewPoint: point)
        }

        editorLayoutContainer.onEditScene = { [weak self] sceneId in self?.session.dispatch(.enterSceneEdit(sceneId: sceneId)) }
        editorLayoutContainer.onDone = { [weak self] in self?.session.dispatch(.exitSceneEdit) }
    }

    // MARK: - TT-08: Internal Test Seams

    static func makeTransitionPicker(
        currentType: TransitionType,
        onSelect: @escaping (SceneTransition) -> Void
    ) -> TransitionPickerViewController {
        let picker = TransitionPickerViewController(currentType: currentType)
        picker.onSelectTransition = onSelect
        return picker
    }

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

    static func makeBoundaryTransitionsResetAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: "Transitions Removed",
            message: "Some transitions were removed because scene boundaries changed or adjacent scenes are too short.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }

    // MARK: - TT-10: Scene Edit Isolation

    static func isolateTimelineActivityForSceneEdit(
        cancelPendingTimelineResolve: () -> Void,
        stopPlayback: () -> Void
    ) {
        cancelPendingTimelineResolve()
        stopPlayback()
    }

    // MARK: - Bootstrap Invariant

    #if DEBUG
    static func validateBootstrapOrder(
        runtimeIsNil: Bool,
        sceneEditModuleIsNil: Bool
    ) -> Bool {
        if !sceneEditModuleIsNil && runtimeIsNil { return false }
        return true
    }

    func assertBootstrapInvariant_runtimeBeforeModule() {
        let valid = Self.validateBootstrapOrder(
            runtimeIsNil: runtime == nil,
            sceneEditModuleIsNil: sceneEditModule == nil
        )
        assert(valid, "[PR9] Bootstrap invariant violated: sceneEditModule exists but runtime is nil")
    }
    #endif

    // MARK: - Overlay Lane Items (Test Seam)

    internal static func extractOverlayLaneItems(
        from timeline: CanonicalTimeline
    ) -> (
        textItems: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)],
        stickerItems: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)]
    ) {
        let textItems: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)] =
            timeline.textItems.compactMap { item in
                guard let payload = timeline.textPayload(for: item.id) else { return nil }
                let label = payload.text.isEmpty ? "Text" : String(payload.text.prefix(20))
                return (id: item.id, startUs: item.startUs ?? 0, durationUs: item.durationUs, label: label)
            }
        let stickerItems: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)] =
            timeline.stickerItems.compactMap { item in
                guard let payload = timeline.stickerPayload(for: item.id) else { return nil }
                return (id: item.id, startUs: item.startUs ?? 0, durationUs: item.durationUs, label: payload.stickerId)
            }
        return (textItems, stickerItems)
    }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        perfLogger.start()
        #endif
        if loadingState == .ready {
            bootstrapController.flushMissingMediaNoticeIfNeeded()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            mediaIngestCoordinator.cancelAll()
        }
        if (isMovingFromParent || isBeingDismissed) && !userMadeExplicitCloseChoice {
            autosaveCoordinator?.handleDisappear()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if DEBUG
        perfLogger.stop()
        #endif
        if Self.shouldCleanupOnDisappear(isMovingFromParent: isMovingFromParent, isBeingDismissed: isBeingDismissed) {
            #if DEBUG
            MemoryDiagnostics.checkpoint("editor.close.before")
            #endif
            // Synchronous: stop playback immediately (cancels displayLink + playbackStartTask)
            runtime?.stopPlayback()
            trimRendererTransientResources(policy: .editorClose)
            // Async teardown: drain in-flight setup tasks then release resources
            let runtime = self.runtime
            let device = metalView.device
            Task { @MainActor in
                await runtime?.releasePreviewResourcesForClose()
                runtime?.clearAllBackgroundTextures()
                #if DEBUG
                MemoryDiagnostics.checkpoint("editor.close.afterTeardown", metal: device)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    guard MemoryDiagnostics.isEnabled else { return }
                    MemoryDiagnostics.checkpoint("editor.close.after.2s", metal: device)
                }
                #endif
            }
        }
    }

    func trimRendererTransientResources(policy: TrimPolicy) {
        renderer?.trimTransientResources(policy: policy)
    }

    static func shouldCleanupOnDisappear(isMovingFromParent: Bool, isBeingDismissed: Bool) -> Bool {
        isMovingFromParent || isBeingDismissed
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sceneEditModule?.interactionController?.mapper.canvasSize = runtime?.queryCanvasSize ?? .zero
        sceneEditModule?.interactionController?.mapper.viewSize = metalView.bounds.size

        let canvasSize = runtime?.queryCanvasSize ?? .zero
        let viewSize = metalView.bounds.size
        var textMapper = EditorCanvasMapper()
        textMapper.canvasSize = canvasSize
        textMapper.viewSize = viewSize
        overlayPositionDrag.canvasSize = CGSize(width: canvasSize.width, height: canvasSize.height)
        overlayPositionDrag.canvasToView = textMapper.canvasToViewTransform()

        if case .sceneEdit = session.state?.uiMode {
            sceneEditModule?.interactionController?.updateOverlay()
        }
    }

    override var prefersStatusBarHidden: Bool {
        presentationController_.fullScreenPreviewVC != nil
    }

    // MARK: - Renderer Setup

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
                    maxFramesInFlight: Self.maxFramesInFlight
                )
            )
            log("MetalRenderer initialized (maxFramesInFlight=\(Self.maxFramesInFlight))")
        } catch { log("ERROR: MetalRenderer failed: \(error)") }
    }

    // MARK: - Playback

    @objc func playPauseTapped() {
        if runtime?.isPlaying == true {
            runtime?.stopPlayback()
        } else {
            runtime?.startPlayback()
        }
    }

    // MARK: - Gesture Handlers

    @objc private func overlayViewTapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: overlayView)
        switch session.state?.uiMode {
        case .sceneEdit:
            sceneEditModule?.handleTap(viewPoint: point)
        case .timeline:
            handleTimelineOverlayTap(viewPoint: point)
        default:
            break
        }
    }

    /// Timeline-mode preview tap: selects a visible text/sticker overlay item via
    /// the existing selection dispatch path. No-op on empty space; does not move
    /// the playhead or change playback. (Preview Overlay Tap Selection)
    private func handleTimelineOverlayTap(viewPoint: CGPoint) {
        guard let selection = hitTestTimelineOverlay(viewPoint: viewPoint) else { return }
        timelineController.handleTimelineSelectionChanged(selection)
    }

    /// Shared hit test: returns the topmost overlay selection at a preview point,
    /// or nil for empty space. Used by tap selection and double-tap-to-edit.
    private func hitTestTimelineOverlay(viewPoint: CGPoint) -> TimelineSelection? {
        guard let runtime = runtime,
              case .timeline(let payload) = runtime.currentRenderSource,
              !payload.overlayItems.isEmpty else { return nil }

        let canvasSize = runtime.queryCanvasSize
        let viewSize = metalView.bounds.size
        guard canvasSize.width > 0, viewSize.width > 0 else { return nil }

        let device = metalView.device
        let canvasPixelWidth = Int(metalView.drawableSize.width.rounded())
        let cache = runtime.overlayRenderCache

        let hit = OverlayPreviewHitTester.hitTest(
            viewPoint: viewPoint,
            items: payload.overlayItems,
            canvasSize: canvasSize,
            viewSize: viewSize,
            minTouchTargetPoints: Self.previewOverlayMinTouchTargetPoints,
            contentCanvasSize: { item in
                guard let device,
                      let cached = cache.texture(
                          for: item,
                          device: device,
                          canvasSize: canvasSize,
                          canvasPixelWidth: canvasPixelWidth
                      )
                else { return nil }
                return OverlayPreviewHitTester.contentCanvasSize(
                    kind: item.kind,
                    contentWidth: cached.contentWidth,
                    contentHeight: cached.contentHeight,
                    canvasSize: canvasSize,
                    canvasPixelWidth: canvasPixelWidth
                )
            }
        )

        switch hit {
        case .text(let itemId): return .text(itemId: itemId)
        case .sticker(let itemId): return .sticker(itemId: itemId)
        case .none: return nil
        }
    }

    /// Double tap on the preview (overlayView path, used when no text box is
    /// selected yet): if it lands on a visible text, open the existing editor.
    @objc private func overlayViewDoubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard case .timeline = session.state?.uiMode else { return }
        let point = recognizer.location(in: overlayView)
        handleTimelineDoubleTap(viewPoint: point)
    }

    /// Double-tap-to-edit routing shared by the overlayView path and the
    /// selected-box overlay path:
    /// - if the tap hits a text, open that text;
    /// - else if a text is already selected, open the selected text.
    func handleTimelineDoubleTap(viewPoint: CGPoint) {
        if case .text(let itemId)? = hitTestTimelineOverlay(viewPoint: viewPoint) {
            openTextEditor(for: itemId)
            return
        }
        if case .text(let itemId)? = session.state?.selection {
            openTextEditor(for: itemId)
        }
    }

    /// Opens the existing modal text editor for the given text item.
    private func openTextEditor(for itemId: UUID) {
        guard let payload = session.state?.canonicalTimeline.textPayload(for: itemId) else { return }
        presentationController_.presentTextEditor(existingPayload: payload, itemId: itemId)
    }

    /// Minimum preview overlay touch target edge length in view points, used to
    /// expand small rendered overlay bounds without changing the drawn overlay.
    private static let previewOverlayMinTouchTargetPoints: CGFloat = 44

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard case .sceneEdit = session.state?.uiMode else { return }
        sceneEditModule?.handlePan(recognizer)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard case .sceneEdit = session.state?.uiMode else { return }
        sceneEditModule?.handlePinch(recognizer)
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard case .sceneEdit = session.state?.uiMode else { return }
        sceneEditModule?.handleRotation(recognizer)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        logger.info("\(message)")
    }

    // MARK: - Scrub Render Throttle (A/B Testing)

    func requestMetalRender() {
        #if DEBUG
        guard isScrubDragging else {
            metalView.setNeedsDisplay()
            return
        }

        if ScrubDebugToggles.skipMetalRender {
            pendingScrubRender = true
            return
        }

        if ScrubDebugToggles.throttleRender30Hz {
            let now = CACurrentMediaTime()
            let minInterval = 1.0 / 30.0
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

    // MARK: - Internal Helpers (PR11: metalView access for owners)

    func requestRender() {
        #if DEBUG
        requestRenderCallCountForTesting += 1
        #endif
        metalView.setNeedsDisplay()
    }
    func setMetalViewPaused(_ paused: Bool) { metalView.isPaused = paused }

    #if DEBUG
    var isMetalViewPausedForTesting: Bool { metalView.isPaused }
    private(set) var requestRenderCallCountForTesting = 0
    #endif
    var metalDevice: MTLDevice? { metalView.device }
    var metalColorPixelFormat: MTLPixelFormat { metalView.colorPixelFormat }
    var commandQueue: MTLCommandQueue? { _commandQueue }
    var metalViewBoundsSize: CGSize { metalView.bounds.size }

    func transferMetalViewToFullscreen(_ fullScreenVC: FullScreenPreviewViewController) {
        metalView.removeFromSuperview()
        fullScreenVC.embedMetalView(metalView)
    }

    func returnMetalViewFromFullscreen() {
        metalView.removeFromSuperview()
        editorLayoutContainer.embedMetalView(metalView)
    }
}

// MARK: - MTKViewDelegate

extension EditorViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

    func draw(in view: MTKView) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard loadingState == .ready else { return }
        guard let runtime = runtime else { return }

        #if DEBUG
        // CP2: experimental AnimiEngineNext single-scene path. Default OFF; production
        // path below is untouched unless a developer opts in at runtime. Fail-closed:
        // a Next-path failure shows a visible debug error and does NOT fall back silently.
        if NextEngineBridgeToggles.renderWithNextEngine {
            renderWithNextEngineBridge(in: view)
            return
        }
        #endif

        switch runtime.currentRenderSource {
        case .timeline(let payload):
            renderTimeline(in: view, payload: payload)
        case .sceneEdit(let payload):
            renderSceneEdit(in: view, payload: payload)
        case .none:
            return
        }
    }

    #if DEBUG
    /// CP3 DEBUG preview: serve the current frame from the cached Next preview context. The heavy
    /// decode/convert/asset/session work is prepared once per template identity; per-frame work is
    /// rendered async off the main thread and cached. A cached frame is presented synchronously
    /// (smooth scrub); a miss schedules an async render and presents when ready. Fail-closed:
    /// errors show the visible red debug error and never fall back to the old renderer.
    private func renderWithNextEngineBridge(in view: MTKView) {
        guard let device = metalView.device else { return }
        let inputs: NextBridgeInputs
        do { inputs = try makeNextBridgeInputs() }
        catch { presentNextBridgeError(error, in: view); return }

        if nextPreviewController == nil {
            nextPreviewController = NextPreviewController(device: device)
        }
        guard let controller = nextPreviewController else { return }

        // CRITICAL: `currentDrawable` is ONLY valid inside this `draw(in:)` call. So presentation
        // happens here and nowhere else. The async completion must NOT present — it only caches the
        // frame and requests another draw, which re-enters here and presents from the cache.
        let cached = controller.requestFrame(inputs) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .frame:
                // Frame is now cached by the controller; ask MTKView to redraw → presents from cache.
                // Keep the prerender window small (< cache size) so it never thrashes eviction.
                self.nextPreviewController?.prerenderSequence(from: inputs.frameIndex + 1, count: 5)
                self.requestRender()
            case .failure(let error):
                self.pendingNextBridgeError = error
                self.requestRender()
            }
        }
        if let cached {
            presentNextFrame(cached, in: view)
            clearNextBridgeError()
        } else if let err = pendingNextBridgeError {
            // An async render failed earlier; surface it inside the valid draw cycle.
            pendingNextBridgeError = nil
            presentNextBridgeError(err, in: view)
        } else if let latest = controller.latestFrame {
            // Cache MISS (e.g. a live gesture where each tick is a new placement key): present the
            // most recent rendered frame NOW. Without this the frame was rendered but never shown
            // until the gesture stopped, because the next key arrived before draw caught the cache.
            presentNextFrame(latest, in: view)
            clearNextBridgeError()
        }
        // First-ever frame (no latest yet): leave the drawable as-is; the async completion triggers
        // another draw once the first frame is ready.
    }

    /// Assemble Next-bridge inputs from existing app state. Throws `NextBridgeError` on
    /// missing scene/media (fail closed).
    private func makeNextBridgeInputs() throws -> NextBridgeInputs {
        guard let state = session.state else { throw NextBridgeError.noScene }
        let timeline = state.draft.canonicalTimeline

        // Fix 1: exact single-scene instance resolution. Dictionary order is not semantic, so
        // resolve the scene strictly from the timeline's single scene item, not values.first.
        let sceneItems = timeline.sceneItems
        guard sceneItems.count == 1 else {
            throw NextBridgeError.multiSceneUnsupported(sceneItemCount: sceneItems.count)
        }
        let sceneItem = sceneItems[0]
        guard sceneItem.kind == .scene,
              case let .scene(scenePayload)? = timeline.payloads[sceneItem.payloadId] else {
            throw NextBridgeError.notASceneItem
        }
        let sceneTypeId = scenePayload.sceneTypeId

        guard let folderURL = sceneLibrarySnapshot?.scene(byId: sceneTypeId)?.folderURL else {
            throw NextBridgeError.sceneFolderMissing(sceneTypeId: sceneTypeId)
        }

        // Scene state is keyed by the scene ITEM id (the scene instance), not values.first.
        let sceneState = state.draft.sceneInstanceStates[sceneItem.id] ?? .empty
        let variantOverrides = sceneState.variantOverrides

        // Single media block. Select the one photo slot; fail closed otherwise.
        let photoSlots = (sceneState.mediaSlotsByBlockId ?? [:]).filter { $0.value.mediaRef.mediaKind == .photo }
        guard photoSlots.count == 1, let (blockID, slot) = photoSlots.first else {
            // No bound photo (or more than one) — CP2 single-block scope: fail closed.
            throw NextBridgeError.noMediaBound(blockID: photoSlots.first?.key ?? "(none)")
        }

        // Fix 2: respect visibility. A hidden block must NOT render silently.
        guard slot.visibility else {
            throw NextBridgeError.blockHidden(blockID: blockID)
        }

        // Resolve the bound photo URL via the async locator (cached). On a cache miss, kick off
        // resolution and throw a typed "resolving" error so the next frame succeeds once warm.
        let key = slot.mediaRef.assetId.rawValue.uuidString
        guard let mediaURL = nextBridgeMediaURLCache[key] else {
            resolveNextBridgeMediaURL(slot.mediaRef, registry: state.draft.assetRegistry)
            throw NextBridgeError.mediaResolveFailed("resolving media URL… (retry)")
        }

        // Fix 3: pass the REAL app placement (converted to fixed-point inside the bridge).
        let p = slot.placement
        let placement = NextBridgePlacement(
            fitModeRaw: p.fitMode.rawValue,
            offsetX: p.offsetX,
            offsetY: p.offsetY,
            userScale: p.userScale,
            rotationDegrees: p.rotationDegrees)

        return NextBridgeInputs(
            sceneTypeId: sceneTypeId,
            sceneFolderURL: folderURL,
            variantOverrides: variantOverrides,
            mediaBlockID: blockID,
            mediaURL: mediaURL,
            placement: placement,
            frameIndex: state.playheadCompressedFrame)
    }

    /// Aspect-fit the BGRA8 frame into the drawable and present. Deterministic Metal path:
    /// upload bytes verbatim → MPS bilinear scale (no CoreImage colour management). MUST be called
    /// only from inside `draw(in:)` — `currentDrawable` is invalid outside the draw cycle.
    private func presentNextFrame(_ frame: NextBridgeBGRAFrame, in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let cmdQueue = commandQueue,
              let device = metalView.device,
              let cmdBuf = cmdQueue.makeCommandBuffer() else { return }

        let w = frame.width
        let h = frame.height
        let target = drawable.texture

        // Guard against a degenerate frame (empty/zero-size bytes) — force-unwrapping a nil
        // baseAddress would trap. Fail closed visibly instead of crashing.
        let expectedBytes = frame.bytesPerRow * h
        guard w > 0, h > 0, frame.bytesPerRow >= w * 4, frame.bytes.count >= expectedBytes, expectedBytes > 0 else {
            presentNextBridgeError(NextBridgeError.engine("degenerate frame \(w)x\(h) bytes=\(frame.bytes.count)/\(expectedBytes)"), in: view)
            return
        }

        // Deterministic presentation: upload the BGRA8 bytes verbatim into a source texture
        // (no colour interpretation), then bilinear-scale (aspect-fit) into the drawable via MPS.
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        srcDesc.usage = [.shaderRead]
        srcDesc.storageMode = .shared
        guard let srcTex = device.makeTexture(descriptor: srcDesc) else { return }
        frame.bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            srcTex.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: frame.bytesPerRow)
        }

        // Clear the drawable first (letterbox background), then scale the frame into it.
        if let pass = view.currentRenderPassDescriptor {
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            cmdBuf.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }

        let scale = min(Double(target.width) / Double(w), Double(target.height) / Double(h))
        let scaledW = Double(w) * scale
        let scaledH = Double(h) * scale
        let tx = (Double(target.width) - scaledW) / 2.0
        let ty = (Double(target.height) - scaledH) / 2.0
        var transform = MPSScaleTransform(scaleX: scale, scaleY: scale, translateX: tx, translateY: ty)
        withUnsafePointer(to: &transform) { ptr in
            let scaler = MPSImageBilinearScale(device: device)
            scaler.scaleTransform = ptr
            scaler.encode(commandBuffer: cmdBuf, sourceTexture: srcTex, destinationTexture: target)
        }

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    private func presentNextBridgeError(_ error: Error, in view: MTKView) {
        let message = (error as? NextBridgeError)?.description ?? "\(error)"
        if !nextBridgeErrorLogged {
            nextBridgeErrorLogged = true
            log("[CP2 NextBridge] FAIL-CLOSED: \(message)")
        }
        // Visible signal: paint the drawable red so the failure is unmistakable on device.
        view.clearColor = MTLClearColor(red: 0.6, green: 0.0, blue: 0.0, alpha: 1.0)
        if let drawable = view.currentDrawable,
           let cmdQueue = commandQueue,
           let cmdBuf = cmdQueue.makeCommandBuffer(),
           let pass = view.currentRenderPassDescriptor {
            pass.colorAttachments[0].clearColor = view.clearColor
            pass.colorAttachments[0].loadAction = .clear
            cmdBuf.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            cmdBuf.present(drawable)
            cmdBuf.commit()
        }
        // DEBUG-only: also show the exact error text on-device (no log access needed to diagnose).
        showNextBridgeErrorLabel(message, over: view)
    }

    private func showNextBridgeErrorLabel(_ message: String, over view: MTKView) {
        let label: UILabel
        if let existing = nextBridgeErrorLabel {
            label = existing
        } else {
            label = UILabel()
            label.numberOfLines = 0
            label.textColor = .white
            label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            nextBridgeErrorLabel = label
        }
        label.text = "CP2 NextBridge FAIL-CLOSED\n\(message)"
        label.isHidden = false
        view.bringSubviewToFront(label)
    }

    private func clearNextBridgeError() {
        if nextBridgeErrorLogged {
            nextBridgeErrorLogged = false
            metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
        }
        nextBridgeErrorLabel?.isHidden = true
    }

    /// Resolve a photo `MediaRef` to an absolute file URL via the async locator and cache it.
    /// Triggers a redraw once warm so the next bridge frame can proceed.
    private func resolveNextBridgeMediaURL(_ mediaRef: MediaRef, registry: ProjectAssetRegistry) {
        let key = mediaRef.assetId.rawValue.uuidString
        guard !nextBridgeMediaResolveInFlight.contains(key) else { return }
        nextBridgeMediaResolveInFlight.insert(key)
        let locator = session.mediaLocator
        Task { [weak self] in
            let resolved = try? await locator.absoluteURL(for: mediaRef, registry: registry)
            await MainActor.run {
                guard let self else { return }
                self.nextBridgeMediaResolveInFlight.remove(key)
                if let resolved {
                    self.nextBridgeMediaURLCache[key] = resolved
                    self.requestRender()
                }
            }
        }
    }
    #endif

    private func renderTimeline(in view: MTKView, payload: TimelineRenderSourcePayload) {
        switch payload.resolvedFrame {
        case .single(let ctx):
            renderTimelineSingleScene(in: view, context: ctx, payload: payload)
        case .transition:
            renderTimelineTransition(in: view, payload: payload)
        }
    }

    private func renderTimelineSingleScene(in view: MTKView, context ctx: SceneRenderContext, payload: TimelineRenderSourcePayload) {
        guard ctx.canvasSize.width > 0 else { return }
        guard let renderer = renderer,
              let cmdQueue = commandQueue else { return }

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
            overlayItems: payload.overlayItems
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

    private func renderTimelineTransition(in view: MTKView, payload: TimelineRenderSourcePayload) {
        guard case .transition(let transCtx) = payload.resolvedFrame else { return }
        guard let renderer = renderer,
              let cmdQueue = commandQueue,
              runtime?.hasTransitionCompositor == true else {
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
            overlayItems: payload.overlayItems
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

        #if DEBUG
        let tSemStart = CACurrentMediaTime()
        #endif

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
        let isPinchOrRotation = gestureRecognizer is UIPinchGestureRecognizer ||
                                gestureRecognizer is UIRotationGestureRecognizer
        let otherIsPinchOrRotation = otherGestureRecognizer is UIPinchGestureRecognizer ||
                                     otherGestureRecognizer is UIRotationGestureRecognizer
        if isPinchOrRotation && otherIsPinchOrRotation {
            return true
        }
        if otherGestureRecognizer.view is UIScrollView {
            return true
        }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer ||
           gestureRecognizer is UIPinchGestureRecognizer ||
           gestureRecognizer is UIRotationGestureRecognizer {
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
            sceneEditModule?.consumePendingPickerRequest()
            return
        }

        // Background image picker path
        if backgroundFlowController.handlePickerResultIfBackground(picker, result) {
            return
        }

        // Scene-media path
        mediaFlowController.handleSceneMediaPicked(result)
    }
}

// MARK: - SceneEditToolModuleDelegate

extension EditorViewController: SceneEditToolModuleDelegate {
    func sceneEditModuleNeedsRedraw() {
        metalView.setNeedsDisplay()
    }

    func sceneEditModule(_ module: SceneEditToolModule, presentAlert alert: UIAlertController) {
        present(alert, animated: true)
    }

    func sceneEditModule(_ module: SceneEditToolModule, presentPHPicker picker: PHPickerViewController) {
        picker.delegate = self
        present(picker, animated: true)
    }

    func sceneEditModuleRequestBackgroundEditor() {
        backgroundFlowController.backgroundTapped()
    }

    var sceneEditLayoutContainer: EditorLayoutContainerView {
        editorLayoutContainer
    }

    var sceneEditPopoverSourceView: UIView {
        view
    }
}

// MARK: - BackgroundEditorDelegate (PR3)

extension EditorViewController: BackgroundEditorDelegate {

    func backgroundEditorDidUpdateOverride(_ override: ProjectBackgroundOverride) {
        backgroundFlowController.handleDidUpdateOverride(override)
    }

    func backgroundEditorDidRequestImagePicker(for regionId: String) {
        backgroundFlowController.handleDidRequestImagePicker(for: regionId)
    }

    func backgroundEditorDidChangePreset(oldPresetId: String, newPresetId: String) {
        backgroundFlowController.handleDidChangePreset(oldPresetId: oldPresetId, newPresetId: newPresetId)
    }

    func backgroundEditorWillDismiss(override: ProjectBackgroundOverride, presetId: String) {
        backgroundFlowController.handleWillDismiss(override: override, presetId: presetId)
    }
}

// MARK: - UIDocumentPickerDelegate (PR8: Music Import)

extension EditorViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        mediaFlowController.handleDocumentPicked(urls: urls)
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
