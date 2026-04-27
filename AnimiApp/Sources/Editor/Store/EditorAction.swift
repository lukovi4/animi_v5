import Foundation
import TVECore

// MARK: - Editor Actions (Release v1)

/// Unified enum of all editor actions.
/// All model mutations must go through EditorStore.dispatch(action).
public enum EditorAction: Sendable {

    // MARK: - Project Lifecycle

    /// Initializes store state with project data from a template.
    /// If draft timeline is empty, populates it from defaultSceneSequence.
    /// Called once when opening a project.
    /// - Parameters:
    ///   - draft: The ProjectDraft to load
    ///   - templateFPS: Template frame rate
    ///   - defaultSceneSequence: Scene defaults from template (used if timeline is empty)
    case loadProject(draft: ProjectDraft, templateFPS: Int, defaultSceneSequence: [SceneTypeDefault])

    // MARK: - Playhead

    /// Sets playhead position in compressed frames.
    /// Does NOT push undo snapshot.
    /// Quantize is applied at the call site (TimelineView) before dispatch.
    /// - Parameter compressedFrame: Frame index in compressed timeline
    case setPlayhead(compressedFrame: Int)

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

    /// Sets a boundary transition between two adjacent scenes.
    /// Pushes undo snapshot.
    /// - When transition.type == .none, removes the transition (instant cut).
    /// - Otherwise, sets the transition for the boundary.
    /// - Parameters:
    ///   - fromSceneId: ID of the outgoing scene (scene A)
    ///   - toSceneId: ID of the incoming scene (scene B)
    ///   - transition: The transition to apply
    case setBoundaryTransition(fromSceneId: UUID, toSceneId: UUID, transition: SceneTransition)

    // MARK: - Scene Instance State (PR9)

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

    /// Sets a unified media slot for a scene instance.
    /// Pushes undo snapshot.
    /// Replaces old setBlockMedia — now writes full SceneMediaSlot (mediaRef + visibility + videoWindow).
    /// Pass nil to clear the slot.
    /// - Parameters:
    ///   - sceneInstanceId: ID of the scene instance
    ///   - blockId: ID of the media block
    ///   - slot: SceneMediaSlot to assign, or nil to clear
    case setMediaSlot(sceneInstanceId: UUID, blockId: String, slot: SceneMediaSlot?)

    /// Commits video selection parameters (trim/audio) for a block.
    /// Pushes undo snapshot when selection actually changed.
    /// Updates the videoWindow field of the existing SceneMediaSlot.
    case setVideoSelection(sceneInstanceId: UUID, blockId: String, selection: PersistedVideoSelection)

    // MARK: - Scene Focus (Playhead as Source of Truth)

    /// Moves playhead to the start of a specific scene and derives selection.
    /// UI navigation action — does NOT push undo snapshot.
    /// Used when user taps a scene in timeline mode.
    /// - Parameter sceneId: ID of the scene to focus
    case focusScene(sceneId: UUID)

    // MARK: - Scene Edit Mode (PR-A)

    /// Enters scene edit mode for a specific scene.
    /// Saves current playhead for return, moves playhead to scene start.
    /// Does NOT push undo snapshot (UI transition).
    /// - Parameter sceneId: ID of the scene to edit
    case enterSceneEdit(sceneId: UUID)

    /// Exits scene edit mode.
    /// Restores playhead to saved position.
    /// Does NOT push undo snapshot (UI transition).
    case exitSceneEdit

    /// Selects a block in scene edit mode.
    /// Does NOT push undo snapshot (UI operation).
    /// - Parameter blockId: ID of the block to select, or nil to deselect
    case selectBlock(blockId: String?)

    /// Resets SceneState for an instance to .empty.
    /// Pushes undo snapshot (model change).
    /// - Parameter sceneInstanceId: ID of the scene instance to reset
    case resetSceneState(sceneInstanceId: UUID)

    /// Sets userMediaPresent for a block (disable/enable asset visibility).
    /// Pushes undo snapshot (model change).
    /// - Parameters:
    ///   - sceneInstanceId: ID of the scene instance
    ///   - blockId: ID of the media block
    ///   - present: Whether the binding layer should be rendered
    case setBlockMediaPresent(sceneInstanceId: UUID, blockId: String, present: Bool)

    // MARK: - Media Placement (PR2)

    /// Sets media placement for a block (pan/zoom/rotate on new placement contract).
    /// Only `.ended` pushes undo snapshot; `.began`/`.changed` are live preview.
    /// - Parameters:
    ///   - sceneInstanceId: ID of the scene instance
    ///   - blockId: ID of the media block
    ///   - placement: New placement state
    ///   - phase: Gesture phase (.began/.changed/.ended/.cancelled)
    case setMediaPlacement(sceneInstanceId: UUID, blockId: String, placement: MediaPlacementState, phase: InteractionPhase)

    /// Sets fit mode for a block's media placement.
    /// Resets offset/scale/rotation to defaults (preserves only the new fitMode).
    /// Pushes undo snapshot.
    case setMediaFitMode(sceneInstanceId: UUID, blockId: String, fitMode: FitMode)

    /// Resets media placement offset/scale/rotation to defaults, preserving current fitMode.
    /// Pushes undo snapshot.
    case resetMediaPlacement(sceneInstanceId: UUID, blockId: String)

    // MARK: - Background

    /// Sets the project background override.
    /// Pushes undo snapshot.
    /// - Parameter background: New background override
    case setBackground(ProjectBackgroundOverride)

    // MARK: - Undo/Redo

    /// Undoes the last model-changing operation.
    case undo

    /// Redoes the last undone operation.
    case redo

    // MARK: - Project Music (PR8)

    /// Sets (or replaces) the project music.
    /// Removes all existing `.music` role items across audio tracks, then appends a new one.
    /// Non-music audio items (voiceover, sfx) are preserved.
    /// Pushes undo snapshot.
    case setProjectMusic(assetRef: AudioAssetRef, sourceDurationUs: TimeUs)

    /// Removes all `.music` role audio items from the timeline.
    /// Non-music audio items (voiceover, sfx) are preserved. Empty audio tracks are pruned.
    /// Pushes undo snapshot.
    case removeProjectMusic

    /// Sets trim range for a `.music` audio item. No-op for non-music items.
    /// Pushes undo snapshot.
    case setProjectMusicTrim(itemId: UUID, trimStartUs: TimeUs, trimEndUs: TimeUs)

    /// Sets volume for a `.music` audio item. No-op for non-music items.
    /// Pushes undo snapshot.
    case setProjectMusicVolume(itemId: UUID, volume: Float)

    // MARK: - Generic Overlay Item Actions (PR9)

    /// Moves an overlay item to a new start time. Gesture-aware.
    /// Only `.ended` pushes undo snapshot.
    case moveItem(itemId: UUID, newStartUs: TimeUs, phase: InteractionPhase)

    /// Trims an overlay item's duration. Gesture-aware.
    /// Only `.ended` pushes undo snapshot.
    case trimItem(itemId: UUID, newDurationUs: TimeUs, phase: InteractionPhase)

    /// Deletes an overlay item and its payload. Pushes undo snapshot.
    case deleteItem(itemId: UUID)

    // MARK: - Text Overlay Actions (PR9)

    /// Atomically adds a text overlay: creates overlay track if needed,
    /// creates payload + item, selects it. Pushes undo snapshot.
    case addTextOverlay(text: String, fontSize: CGFloat, colorHex: String, fontFamily: String?, startUs: TimeUs, durationUs: TimeUs)

    /// Updates text payload content/style/position. Pushes undo snapshot.
    case updateTextPayload(itemId: UUID, payload: TextPayload)

    /// Drags overlay position on canvas (text or sticker). Gesture-aware.
    /// Only `.ended` pushes undo snapshot.
    case dragOverlayPosition(itemId: UUID, centerX: CGFloat, centerY: CGFloat, phase: InteractionPhase)

    // MARK: - Sticker Overlay Actions (PR10)

    /// Atomically adds a sticker overlay: creates overlay track if needed,
    /// creates payload + item, selects it. Pushes undo snapshot.
    case addStickerOverlay(stickerId: String, startUs: TimeUs, durationUs: TimeUs)

    /// Updates sticker payload (position). Pushes undo snapshot.
    case updateStickerPayload(itemId: UUID, payload: StickerPayload)

    // MARK: - Future Actions (API reserved, not implemented yet)

    /// Adds a new track (future).
    case addTrack(kind: TrackKind)

    /// Adds a new item to a track (future).
    case addItem(kind: ItemKind, trackId: UUID, payloadId: UUID, startUs: TimeUs, durationUs: TimeUs)
}
