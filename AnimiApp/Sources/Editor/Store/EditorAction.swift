import Foundation
import TVECore

// MARK: - Editor Actions (Release v1)

/// Unified enum of all editor actions.
/// All model mutations must go through EditorStore.dispatch(action).
public enum EditorAction: Sendable {

    // MARK: - Project Lifecycle

    /// Initializes store state with project data from a template recipe.
    /// If draft timeline is empty, populates it from defaultSceneSequence.
    /// Called once when opening a project.
    /// - Parameters:
    ///   - draft: The ProjectDraft to load
    ///   - templateFPS: Template frame rate
    ///   - defaultSceneSequence: Scene defaults from recipe (used if timeline is empty)
    case loadProject(draft: ProjectDraft, templateFPS: Int, defaultSceneSequence: [SceneTypeDefault])

    // MARK: - Playhead

    /// Sets playhead position.
    /// Does NOT push undo snapshot.
    /// - Parameters:
    ///   - timeUs: Time in microseconds
    ///   - quantize: Quantize mode for frame calculation
    case setPlayhead(timeUs: TimeUs, quantize: QuantizeMode)

    // MARK: - Selection

    /// Sets timeline selection.
    /// Does NOT push undo snapshot.
    case select(selection: TimelineSelection)

    // MARK: - Scene Operations

    /// Trims a scene's duration.
    /// - Only `.ended` phase pushes undo snapshot.
    /// - Only `TrimEdge.trailing` is supported for sceneSequence.
    /// - No upper limit on duration (scenes can be as long as needed).
    /// - Parameters:
    ///   - sceneId: ID of the scene to trim
    ///   - phase: Gesture phase (.began/.changed/.ended/.cancelled)
    ///   - newDurationUs: New duration in microseconds
    ///   - edge: Which edge is being trimmed (only .trailing supported)
    case trimScene(sceneId: UUID, phase: InteractionPhase, newDurationUs: TimeUs, edge: TrimEdge)

    /// Reorders a scene to a new index.
    /// Pushes undo snapshot.
    /// Playhead follows the moved scene (preserves relative offset).
    /// - Parameters:
    ///   - sceneId: ID of the scene to move
    ///   - toIndex: Destination index in scene sequence
    case reorderScene(sceneId: UUID, toIndex: Int)

    /// Adds a new scene from the scene library.
    /// Pushes undo snapshot.
    /// - Parameters:
    ///   - sceneTypeId: Scene type identifier from SceneLibrary
    ///   - durationUs: Duration for the new scene (typically baseDurationUs from library)
    case addScene(sceneTypeId: String, durationUs: TimeUs)

    /// Duplicates an existing scene.
    /// Creates a new instance with copied SceneState.
    /// Pushes undo snapshot.
    /// - Parameter sceneItemId: ID of the scene item to duplicate
    case duplicateScene(sceneItemId: UUID)

    /// Deletes a scene from the timeline.
    /// Cannot delete the last scene (at least one must remain).
    /// Pushes undo snapshot.
    /// - Parameter sceneId: ID of the scene to delete
    case deleteScene(sceneId: UUID)

    // MARK: - Scene Instance State (PR9)

    /// Sets a block transform for a scene instance.
    /// - Only `.ended` phase pushes undo snapshot (baseline stored on `.began`).
    /// - Parameters:
    ///   - sceneInstanceId: ID of the scene instance
    ///   - blockId: ID of the media block
    ///   - transform: Combined pan/zoom/rotate as Matrix2D
    ///   - phase: Gesture phase (.began/.changed/.ended/.cancelled)
    case setBlockTransform(sceneInstanceId: UUID, blockId: String, transform: Matrix2D, phase: InteractionPhase)

    /// Sets a block variant selection for a scene instance.
    /// Pushes undo snapshot.
    /// - Parameters:
    ///   - sceneInstanceId: ID of the scene instance
    ///   - blockId: ID of the media block
    ///   - variantId: ID of the selected variant
    case setBlockVariant(sceneInstanceId: UUID, blockId: String, variantId: String)

    /// Sets a layer toggle state for a scene instance.
    /// Pushes undo snapshot.
    /// - Parameters:
    ///   - sceneInstanceId: ID of the scene instance
    ///   - blockId: ID of the media block
    ///   - toggleId: ID of the toggle
    ///   - enabled: Whether the toggle is enabled
    case setBlockToggle(sceneInstanceId: UUID, blockId: String, toggleId: String, enabled: Bool)

    /// Sets a media assignment for a scene instance.
    /// Pushes undo snapshot.
    /// - Parameters:
    ///   - sceneInstanceId: ID of the scene instance
    ///   - blockId: ID of the media block
    ///   - media: MediaRef to assigned media, or nil to clear
    case setBlockMedia(sceneInstanceId: UUID, blockId: String, media: MediaRef?)

    // MARK: - Undo/Redo

    /// Undoes the last model-changing operation.
    case undo

    /// Redoes the last undone operation.
    case redo

    // MARK: - Future Actions (API reserved, not implemented yet)

    /// Moves an item to a new start time (for audio/overlay, future).
    case moveItem(itemId: UUID, newStartUs: TimeUs)

    /// Trims an item's duration (for audio/overlay, future).
    case trimItem(itemId: UUID, newDurationUs: TimeUs)

    /// Deletes an item (future).
    case deleteItem(itemId: UUID)

    /// Adds a new track (future).
    case addTrack(kind: TrackKind)

    /// Adds a new item to a track (future).
    case addItem(kind: ItemKind, trackId: UUID, payloadId: UUID, startUs: TimeUs, durationUs: TimeUs)
}
