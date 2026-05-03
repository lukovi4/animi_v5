import XCTest
import UIKit
import PhotosUI
import TVECore
@testable import AnimiApp

// MARK: - Mock Runtime

@MainActor
final class MockSceneEditRuntime: SceneEditToolRuntimeControlling {
    var isPlaying = false
    var bestLocalFrame = 0
    var canCommitVideoTrim = true
    var queryCanvasSize: SizeD = .zero
    var currentActiveSceneInstanceId: UUID?
    var currentSceneEditReadyInstanceId: UUID?

    /// Callback fired on clearMediaSlot — tests inject to observe ordering.
    var onClearMediaSlot: ((String) -> Void)?
    /// Callback fired on reloadSceneEditState — tests inject to observe ordering.
    var onReloadSceneEditState: ((UUID) -> Void)?

    var activatedInstanceIds: [UUID] = []
    var deactivatedCount = 0
    var stopPlaybackCount = 0
    var reloadedInstanceIds: [UUID] = []
    var clearedMediaSlots: [String] = []
    var placementChanges: [(UUID, String, MediaPlacementState)] = []
    var visibilityChanges: [(UUID, String, Bool)] = []
    var slotChanges: [(UUID, String, SceneMediaSlot?)] = []
    var variantChanges: [(String, String)] = []
    var syncedVideoStillFrames: [Int] = []
    var syncedUndoRedoStates: [EditorState] = []
    var appliedVideoSelections: [(PersistedVideoSelection, String, UUID)] = []

    func activateSceneEditTarget(instanceId: UUID) { activatedInstanceIds.append(instanceId) }
    func deactivateSceneEdit() { deactivatedCount += 1 }
    func stopPlayback() { stopPlaybackCount += 1 }

    func reloadSceneEditState(instanceId: UUID) async {
        reloadedInstanceIds.append(instanceId)
        onReloadSceneEditState?(instanceId)
    }

    func sceneEditOverlayProvider() -> SceneEditOverlayProviding? { nil }
    func mediaActionBarContext(blockId: String) -> MediaActionBarContext {
        MediaActionBarContext(allowedMedia: nil, availableVariants: [], selectedVariantId: nil, canTrimVideo: false)
    }
    func videoTrimContext(blockId: String) -> VideoTrimContext? { nil }
    func currentVideoTime(blockId: String, sceneFrameIndex: Int) -> Double { 0 }

    @discardableResult
    func applyMediaPlacementChange(instanceId: UUID, blockId: String, placement: MediaPlacementState) -> Bool {
        placementChanges.append((instanceId, blockId, placement))
        return true
    }

    @discardableResult
    func applyMediaVisibilityChange(instanceId: UUID, blockId: String, visible: Bool) -> Bool {
        visibilityChanges.append((instanceId, blockId, visible))
        return true
    }

    func applyMediaSlotChange(instanceId: UUID, blockId: String, slot: SceneMediaSlot?) {
        slotChanges.append((instanceId, blockId, slot))
    }

    func clearMediaSlot(blockId: String) {
        clearedMediaSlots.append(blockId)
        onClearMediaSlot?(blockId)
    }

    func updateInteractiveTrimPreview(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double) {}
    func endInteractiveTrimPreview(blockId: String) {}
    func previewExactVideoTrimFrame(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double) {}
    func applyPersistedVideoSelection(blockId: String, _ selection: PersistedVideoSelection) throws {}

    func syncVideoStillFrames(sceneFrameIndex: Int) { syncedVideoStillFrames.append(sceneFrameIndex) }
    func syncEngineAfterUndoRedo(state: EditorState) { syncedUndoRedoStates.append(state) }
    func applyVideoSelectionToEngine(selection: PersistedVideoSelection, blockId: String, instanceId: UUID) {
        appliedVideoSelections.append((selection, blockId, instanceId))
    }

    func setSelectedVariant(blockId: String, variantId: String) {
        variantChanges.append((blockId, variantId))
    }
}

// MARK: - Mock Delegate

@MainActor
final class MockSceneEditModuleDelegate: NSObject, SceneEditToolModuleDelegate {
    var needsRedrawCount = 0
    var presentedAlerts: [UIAlertController] = []
    var presentedPickers: [UIViewController] = []
    var backgroundRequestCount = 0

    private let _layoutContainer = EditorLayoutContainerView()
    var sceneEditLayoutContainer: EditorLayoutContainerView { _layoutContainer }
    var sceneEditPopoverSourceView: UIView { _layoutContainer }

    func sceneEditModuleNeedsRedraw() { needsRedrawCount += 1 }
    func sceneEditModule(_ module: SceneEditToolModule, presentAlert alert: UIAlertController) {
        presentedAlerts.append(alert)
    }
    func sceneEditModule(_ module: SceneEditToolModule, presentPHPicker picker: PHPickerViewController) {
        presentedPickers.append(picker)
    }
    func sceneEditModuleRequestBackgroundEditor() { backgroundRequestCount += 1 }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {}
}

// MARK: - Stubs

private struct StubMediaLocator: ProjectMediaLocator {
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        URL(fileURLWithPath: "/tmp/stub")
    }
}

private struct StubMediaWriter: ProjectMediaWriteGateway {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func deleteMediaFile(_ mediaRef: MediaRef) async throws {}
    func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft { sourceDraft }
}

private struct StubPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    func preset(for presetId: String) -> BackgroundPreset? { nil }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? { nil }
    var allPresets: [BackgroundPreset] { [] }
    var count: Int { 0 }
}

// MARK: - Tests

@MainActor
final class SceneEditToolModuleTests: XCTestCase {

    private func makeBootstrappedSession() async -> EditorSession {
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { $0 },
            mediaLocator: StubMediaLocator(),
            mediaWriter: StubMediaWriter(),
            loadSceneLibrary: {
                SceneLibrarySnapshot(
                    fps: 30,
                    canvas: CanvasConfig(width: 1080, height: 1920),
                    scenes: [
                        SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
                    ]
                )
            },
            sceneTypeDefaults: { _, _ in
                [SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: 3_000_000)]
            },
            loadTemplateCatalog: {
                .success(TemplateCatalogSnapshot(categories: [], templates: []))
            },
            backgroundPresetProvider: StubPresetProvider()
        )
        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        await session.bootstrap()
        return session
    }

    private func makeModule(
        runtime: MockSceneEditRuntime? = nil
    ) async -> (SceneEditToolModule, MockSceneEditRuntime, MockSceneEditModuleDelegate, EditorSession) {
        let rt = runtime ?? MockSceneEditRuntime()
        let session = await makeBootstrappedSession()

        let module = SceneEditToolModule(
            runtime: rt,
            session: session,
            overlayView: EditorOverlayView(),
            ingestStatusOverlayView: MediaIngestStatusOverlayView()
        )
        let delegate = MockSceneEditModuleDelegate()
        module.delegate = delegate
        return (module, rt, delegate, session)
    }

    // MARK: - UI Mode

    func testHandleUIModeChanged_sceneEdit_stopsPlayback_activatesTarget() async {
        let (module, rt, delegate, _) = await makeModule()
        rt.isPlaying = true
        let sceneId = UUID()

        module.handleUIModeChanged(.sceneEdit(sceneInstanceId: sceneId))

        XCTAssertEqual(rt.stopPlaybackCount, 1, "Should stop playback on scene edit entry")
        XCTAssertEqual(rt.activatedInstanceIds, [sceneId], "Should activate scene target")
        withExtendedLifetime(delegate) {}
    }

    func testHandleUIModeChanged_timeline_deactivates() async {
        let (module, rt, delegate, _) = await makeModule()

        module.handleUIModeChanged(.timeline)

        XCTAssertEqual(rt.deactivatedCount, 1, "Should deactivate scene edit on timeline mode")
        withExtendedLifetime(delegate) {}
    }

    // MARK: - Media Placement

    func testHandleMediaPlacementChanged_resolvesInstanceId_forwardsToRuntime() async {
        let (module, rt, _, session) = await makeModule()
        let instanceId = session.state!.canonicalTimeline.sceneItems[0].id

        session.dispatch(.enterSceneEdit(sceneId: instanceId))

        let placement = MediaPlacementState.defaultCover
        module.handleMediaPlacementChanged(instanceId: UUID(), blockId: "b1", placement: placement)

        XCTAssertEqual(rt.placementChanges.count, 1, "Should forward to runtime")
        XCTAssertEqual(rt.placementChanges[0].0, instanceId, "Should use resolved instanceId")
    }

    // MARK: - Video Still Sync

    func testSyncPausedVideoStill_suppressedDuringTrim() async {
        let (module, rt, _, _) = await makeModule()

        module.videoTrimCoordinator.setVideoTrimSessionForTesting(VideoTrimSession(
            instanceId: UUID(), blockId: "b1",
            actualDuration: 5.0,
            selection: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0),
            currentVideoTime: 0
        ))

        module.syncPausedVideoStill(force: true)

        XCTAssertTrue(rt.syncedVideoStillFrames.isEmpty, "Should suppress sync during trim")
    }

    // MARK: - Target Instance Resolution

    func testSceneEditTargetInstanceId_resolvesFromUIMode() async {
        let (module, rt, _, session) = await makeModule()
        let instanceId = session.state!.canonicalTimeline.sceneItems[0].id
        rt.currentActiveSceneInstanceId = UUID()

        session.dispatch(.enterSceneEdit(sceneId: instanceId))

        XCTAssertEqual(module.sceneEditTargetInstanceId, instanceId,
                       "Should return uiMode scene, not runtime active scene")
    }

    // MARK: - Ingest Failure Alert Dedup

    func testIngestFailureAlert_deduped_secondCallSuppressed() async {
        let (module, _, delegate, session) = await makeModule()
        let instanceId = session.state!.canonicalTimeline.sceneItems[0].id
        session.dispatch(.enterSceneEdit(sceneId: instanceId))

        let key = IngestSlotKey(sceneInstanceId: instanceId, blockId: "b1")

        module.handleIngestStatusChanged(key: key, status: .failed(reason: "Error"))
        module.handleIngestStatusChanged(key: key, status: .failed(reason: "Error"))

        XCTAssertEqual(delegate.presentedAlerts.count, 1,
                       "Second failure for same key should be suppressed")
    }

    // MARK: - performRemoveMedia (order verification)

    /// Verifies the full remove sequence: cancel → clear → dispatch → redraw.
    /// Uses snapshot-in-closure to prove ordering boundaries.
    func testPerformRemoveMedia_fullSequenceOrder() async {
        let (module, rt, delegate, session) = await makeModule()
        let instanceId = session.state!.canonicalTimeline.sceneItems[0].id
        session.dispatch(.enterSceneEdit(sceneId: instanceId))

        // At cancel time: runtime must not have cleared yet
        var cancelCalled = false
        var runtimeClearCountAtCancel = 0
        module.cancelIngestForSlot = { [weak rt] _ in
            runtimeClearCountAtCancel = rt?.clearedMediaSlots.count ?? -1
            cancelCalled = true
        }

        // At clearMediaSlot time: cancel must have already happened
        var cancelCalledAtClear: Bool?
        rt.onClearMediaSlot = { _ in
            cancelCalledAtClear = cancelCalled
        }

        module.performRemoveMedia(blockId: "b1")

        // 1. Cancel happened, and runtime had NOT yet cleared at that point
        XCTAssertTrue(cancelCalled, "cancelIngestForSlot must be called")
        XCTAssertEqual(runtimeClearCountAtCancel, 0,
                       "runtime.clearMediaSlot must not have run before cancel")

        // 2. At clearMediaSlot time, cancel had already happened
        XCTAssertEqual(cancelCalledAtClear, true,
                       "Cancel must precede clearMediaSlot")

        // 3. Runtime clearMediaSlot was called
        XCTAssertEqual(rt.clearedMediaSlots, ["b1"], "Must clear media slot on runtime")

        // 4. After full sequence, slot is nil in draft (dispatch happened)
        let slotAfter = session.state?.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?["b1"]
        XCTAssertNil(slotAfter, "Slot must be nil after dispatch")

        // 5. Delegate asked to redraw
        XCTAssertEqual(delegate.needsRedrawCount, 1, "Must request redraw after remove")
    }

    // MARK: - performResetScene (order verification)

    /// Verifies: cancel → dispatch(reset) → async reload.
    /// Uses snapshot-in-closure to prove cancel precedes state reset.
    func testPerformResetScene_cancelPrecedesDispatch_reloadFollows() async {
        let (module, rt, _, session) = await makeModule()
        let instanceId = session.state!.canonicalTimeline.sceneItems[0].id
        session.dispatch(.enterSceneEdit(sceneId: instanceId))
        session.dispatch(.setBlockVariant(sceneInstanceId: instanceId, blockId: "b1", variantId: "v1"))

        // At cancel time: scene state must still have the variant (dispatch hasn't happened)
        var variantExistedAtCancel: Bool?
        module.cancelAllIngestsForScene = { [weak session] _ in
            variantExistedAtCancel = session?.state?.draft
                .sceneInstanceStates[instanceId]?
                .variantOverrides["b1"] != nil
        }

        // At reload time: scene state must already be reset (dispatch already happened)
        var variantExistedAtReload: Bool?
        rt.onReloadSceneEditState = { [weak session] _ in
            variantExistedAtReload = session?.state?.draft
                .sceneInstanceStates[instanceId]?
                .variantOverrides["b1"] != nil
        }

        module.performResetScene(instanceId: instanceId)

        // 1. Cancel happened while variant still existed
        XCTAssertEqual(variantExistedAtCancel, true,
                       "Variant must still exist at cancel time (before dispatch)")

        // 2. After synchronous part, state is reset
        let variantAfter = session.state?.draft.sceneInstanceStates[instanceId]?.variantOverrides["b1"]
        XCTAssertNil(variantAfter, "Variant must be cleared after reset dispatch")

        // 3. Wait for async reload Task
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(rt.reloadedInstanceIds, [instanceId],
                       "Must reload runtime state for the instance")
        // At reload time, dispatch had already happened
        XCTAssertEqual(variantExistedAtReload, false,
                       "Variant must be gone by reload time (dispatch preceded reload)")
    }

    // MARK: - onResetScene via layout callback (alert flow)

    func testOnResetScene_presentsConfirmationAlert() async {
        let (module, _, delegate, session) = await makeModule()
        let instanceId = session.state!.canonicalTimeline.sceneItems[0].id
        session.dispatch(.enterSceneEdit(sceneId: instanceId))
        session.dispatch(.setBlockVariant(sceneInstanceId: instanceId, blockId: "b1", variantId: "v1"))

        let container = EditorLayoutContainerView()
        module.wireLayoutCallbacks(container: container)
        container.onResetScene?()

        XCTAssertEqual(delegate.presentedAlerts.count, 1, "Should present reset confirmation")
        withExtendedLifetime(delegate) {}
    }

    // MARK: - Bootstrap order (contract regression)

    /// Validates the bootstrap invariant: if sceneEditModule exists, runtime must also exist.
    /// This is the static contract that prevents the runtime! crash fixed in PR9.
    func testBootstrapOrder_moduleWithoutRuntime_isInvalid() {
        // Module exists, runtime is nil → invariant violated
        XCTAssertFalse(
            EditorViewController.validateBootstrapOrder(runtimeIsNil: true, sceneEditModuleIsNil: false),
            "Module without runtime must be invalid"
        )
    }

    func testBootstrapOrder_moduleWithRuntime_isValid() {
        // Module exists, runtime exists → valid
        XCTAssertTrue(
            EditorViewController.validateBootstrapOrder(runtimeIsNil: false, sceneEditModuleIsNil: false),
            "Module with runtime must be valid"
        )
    }

    func testBootstrapOrder_neitherExists_isValid() {
        // Neither exists (pre-bootstrap) → valid
        XCTAssertTrue(
            EditorViewController.validateBootstrapOrder(runtimeIsNil: true, sceneEditModuleIsNil: true),
            "Pre-bootstrap state (both nil) must be valid"
        )
    }

    func testBootstrapOrder_runtimeWithoutModule_isValid() {
        // Runtime exists but module not yet created → valid (mid-bootstrap)
        XCTAssertTrue(
            EditorViewController.validateBootstrapOrder(runtimeIsNil: false, sceneEditModuleIsNil: true),
            "Runtime without module (mid-bootstrap) must be valid"
        )
    }
}
