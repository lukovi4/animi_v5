import Foundation
import TVECore

/// Sealed protocol exposing only the EditorRuntime surface needed by SceneEditToolModule.
/// Class-bound so the module can hold a `weak var runtime`.
@MainActor protocol SceneEditToolRuntimeControlling: AnyObject {

    // MARK: - State Queries

    var isPlaying: Bool { get }
    var bestLocalFrame: Int { get }
    var canCommitVideoTrim: Bool { get }
    var queryCanvasSize: SizeD { get }
    var currentActiveSceneInstanceId: UUID? { get }
    var currentSceneEditReadyInstanceId: UUID? { get }

    // MARK: - Lifecycle

    func activateSceneEditTarget(instanceId: UUID)
    func deactivateSceneEdit()
    func stopPlayback()

    // MARK: - Composite Reload

    func reloadSceneEditState(instanceId: UUID) async

    // MARK: - Overlay / Query

    func sceneEditOverlayProvider() -> SceneEditOverlayProviding?
    func mediaActionBarContext(blockId: String) -> MediaActionBarContext
    func videoTrimContext(blockId: String) -> VideoTrimContext?
    func currentVideoTime(blockId: String, sceneFrameIndex: Int) -> Double

    // MARK: - Fast-Path Mutations

    @discardableResult
    func applyMediaPlacementChange(instanceId: UUID, blockId: String, placement: MediaPlacementState) -> Bool
    @discardableResult
    func applyMediaVisibilityChange(instanceId: UUID, blockId: String, visible: Bool) -> Bool
    func applyMediaSlotChange(instanceId: UUID, blockId: String, slot: SceneMediaSlot?)
    func clearMediaSlot(blockId: String)

    // MARK: - Video Trim

    func updateInteractiveTrimPreview(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double)
    func endInteractiveTrimPreview(blockId: String)
    func previewExactVideoTrimFrame(blockId: String, draftSelection: PersistedVideoSelection, previewTime: Double)
    func applyPersistedVideoSelection(blockId: String, _ selection: PersistedVideoSelection) throws

    // MARK: - Sync

    func syncVideoStillFrames(sceneFrameIndex: Int)
    func syncEngineAfterUndoRedo(state: EditorState)
    func applyVideoSelectionToEngine(selection: PersistedVideoSelection, blockId: String, instanceId: UUID)

    // MARK: - Variant

    func setSelectedVariant(blockId: String, variantId: String)
}
