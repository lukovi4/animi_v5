import Foundation
import TVECore

// MARK: - Editor Store (Release v1)

/// Centralized store for editor state.
/// All model mutations must go through dispatch(action).
/// Manages undo/redo stack and notifies observers of state changes.
@MainActor
public final class EditorStore {

    // MARK: - State

    /// Current editor state.
    public private(set) var state: EditorState

    /// Undo/redo stack.
    private var undoStack: UndoStack

    /// Pending gesture baseline snapshot (for correct undo on gesture commit).
    /// Saved on .began, used on .ended/.cancelled, cleared after use.
    private var pendingGestureSnapshot: EditorSnapshot?

    /// Previous playhead position (for detecting playhead-only changes).
    private var previousPlayheadCompressedFrame: Int = 0

    // MARK: - Callbacks (Split for Performance)

    /// Called when playhead position changes (compressed frame).
    /// Use for lightweight UI updates (playhead indicator, current frame).
    public var onPlayheadChanged: ((Int) -> Void)?

    /// Called when selection changes.
    /// Use for lightweight UI updates (highlight, handles).
    public var onSelectionChanged: ((TimelineSelection?) -> Void)?

    /// Called when timeline structure changes (scenes, durations, order).
    /// Use for heavier UI updates (rebuilding scene clips, layout).
    public var onTimelineChanged: ((EditorState) -> Void)?

    /// Called during live-trim preview (phase .began/.changed).
    /// Use for lightweight UI updates only (no playback coordinator, no persistence).
    public var onTimelinePreviewChanged: ((EditorState) -> Void)?

    /// Called when undo/redo availability changes.
    public var onUndoRedoChanged: ((Bool, Bool) -> Void)?

    // MARK: - Scene Edit Mode Callbacks (PR-A)

    /// Called when UI mode changes (timeline ↔ sceneEdit).
    public var onUIModeChanged: ((EditorUIMode) -> Void)?

    /// Called when selected block changes in Scene Edit.
    public var onSelectedBlockChanged: ((String?) -> Void)?

    /// Called after undo/redo restores snapshot.
    /// Needed because runtime (ScenePlayer/UserMediaService) uses write-through
    /// and must be explicitly re-applied for the active scene instance.
    public var onStateRestoredFromUndoRedo: (() -> Void)?

    /// PR-F: Called when a scene instance state changes (but not timeline structure).
    /// Use for incremental engine sync instead of full setTimeline().
    public var onSceneStateChanged: ((UUID, SceneState) -> Void)?

    /// Called when video selection is committed for a block.
    /// Parameters: (sceneInstanceId, blockId, selection)
    public var onVideoSelectionChanged: ((UUID, String, PersistedVideoSelection) -> Void)?

    /// PR2: Called when a media slot changes (insert/replace/remove).
    /// Parameters: (sceneInstanceId, blockId, slot or nil)
    public var onMediaSlotChanged: ((UUID, String, SceneMediaSlot?) -> Void)?

    /// PR2: Called when media placement changes (pan/zoom/rotate committed).
    /// Parameters: (sceneInstanceId, blockId, placement)
    public var onMediaPlacementChanged: ((UUID, String, MediaPlacementState) -> Void)?

    /// PR2: Called when media visibility changes (hide/show).
    /// Parameters: (sceneInstanceId, blockId, visible)
    public var onMediaVisibilityChanged: ((UUID, String, Bool) -> Void)?

    /// Called when reducer emits notices (e.g., boundary transitions reset).
    /// Use for user-facing feedback like alerts.
    public var onNotice: ((EditorNotice) -> Void)?

    // MARK: - Initialization

    public init(initialState: EditorState = .empty()) {
        self.state = initialState
        self.undoStack = UndoStack()
    }

    // MARK: - Bookkeeping Mutation (non-dirtying)

    /// Non-dirtying draft mutation for pure bookkeeping operations like
    /// `ProjectAssetRegistry.register` / `unregister`.
    ///
    /// Contract:
    /// - Mutates `state.draft` in place via the given closure.
    /// - Does NOT push an undo snapshot.
    /// - Does NOT emit any store callbacks (`onTimelineChanged`,
    ///   `onSceneStateChanged`, `onMediaSlotChanged`, etc.).
    /// - Does NOT mark the dirty baseline as mutated — the next semantic
    ///   dispatch is what writes the draft (including the updated registry)
    ///   to disk.
    ///
    /// Used exclusively by `EditorSession.registerAssetBookkeeping(_:)` /
    /// `unregisterAssetBookkeeping(_:)`. Do not widen access — reducer-level
    /// mutations must always go through `dispatch(_:)`.
    internal func mutateCurrentDraftForBookkeeping(_ block: (inout ProjectDraft) -> Void) {
        var draft = state.draft
        block(&draft)
        state.draft = draft
    }

    // MARK: - Dispatch

    /// Dispatches an action to update state.
    /// This is the ONLY way to mutate editor state.
    /// - Parameter action: The action to dispatch
    public func dispatch(_ action: EditorAction) {
        // Handle undo/redo specially (they operate on the stack, not the reducer)
        switch action {
        case .undo:
            performUndo()
            return
        case .redo:
            performRedo()
            return
        default:
            break
        }

        // Handle gesture baseline for trim and transform gestures (PR9, PR2)
        let gesturePhase: InteractionPhase?
        switch action {
        case .trimScene(_, let phase, _, _):
            gesturePhase = phase
        case .setMediaPlacement(_, _, _, let phase):
            gesturePhase = phase
        default:
            gesturePhase = nil
        }

        if let phase = gesturePhase {
            switch phase {
            case .began:
                // Save baseline snapshot before any mutations
                pendingGestureSnapshot = EditorSnapshot(from: state)
            case .cancelled:
                // Restore content baseline and clear (interaction state preserved)
                if let baseline = pendingGestureSnapshot {
                    state.restore(from: baseline)
                    pendingGestureSnapshot = nil
                    // P1 fix: Notify all observers after cancel restore
                    notifyTimelineChanged()
                    notifySelectionChanged()
                    notifyUndoRedoChanged()
                    #if DEBUG
                    print("[EditorStore] Gesture cancelled, restored baseline")
                    #endif
                }
                return
            case .ended:
                // Will use baseline for undo below
                break
            case .changed:
                // Live preview, continue to reducer
                break
            }
        }

        // Take snapshot before action (for undo)
        // For gesture .ended, use baseline snapshot instead
        let snapshotForUndo: EditorSnapshot
        let isGestureEnded: Bool
        switch action {
        case .trimScene(_, .ended, _, _):
            isGestureEnded = true
        case .setMediaPlacement(_, _, _, .ended):
            isGestureEnded = true
        default:
            isGestureEnded = false
        }

        if isGestureEnded, let baseline = pendingGestureSnapshot {
            snapshotForUndo = baseline
            pendingGestureSnapshot = nil
        } else {
            snapshotForUndo = EditorSnapshot(from: state)
        }

        // Remember previous state for change detection
        let oldPlayhead = state.playheadCompressedFrame
        let oldTimeline = state.canonicalTimeline
        let oldSelection = state.selection
        let oldUIMode = state.uiMode
        let oldSelectedBlockId = state.selectedBlockId

        // Reduce
        let result = EditorReducer.reduce(state: state, action: action)

        // Update state
        state = result.state

        // Push undo snapshot if needed
        if result.shouldPushSnapshot {
            undoStack.push(snapshotForUndo)
            notifyUndoRedoChanged()
        }

        // Notify observers (split for performance)
        let playheadChanged = state.playheadCompressedFrame != oldPlayhead
        let selectionChanged = state.selection != oldSelection
        let structureChanged = state.canonicalTimeline != oldTimeline

        // Determine if this is a trim preview action (.began/.changed)
        let isTrimPreview: Bool = {
            if case .trimScene(_, let phase, _, _) = action {
                return phase == .began || phase == .changed
            }
            return false
        }()

        // PR-F: Determine if this is a scene-state-only change (not structural)
        let sceneStateChangeInfo = extractSceneStateChange(action: action)

        if playheadChanged {
            onPlayheadChanged?(state.playheadCompressedFrame)
        }

        if selectionChanged {
            notifySelectionChanged()
        }

        // PR-A: UI mode change detection
        if state.uiMode != oldUIMode {
            onUIModeChanged?(state.uiMode)
        }

        // PR-A: Selected block change detection
        if state.selectedBlockId != oldSelectedBlockId {
            onSelectedBlockChanged?(state.selectedBlockId)
        }

        // Extract video selection change info before routing
        let videoSelectionChange = extractVideoSelectionChange(action: action)

        // PR2: Extract specific media change info for dedicated callbacks
        let mediaSlotChange = extractMediaSlotChange(action: action)
        let mediaPlacementChange = extractMediaPlacementChange(action: action)
        let mediaVisibilityChange = extractMediaVisibilityChange(action: action)

        // PR-F: Route to appropriate callback based on change type
        if structureChanged {
            // Timeline structure changed - full sync
            if isTrimPreview {
                notifyTimelinePreviewChanged()
            } else {
                notifyTimelineChanged()
            }
        } else if let (instanceId, blockId, selection) = videoSelectionChange, result.shouldPushSnapshot {
            // Video selection committed - dedicated fast path
            onVideoSelectionChanged?(instanceId, blockId, selection)
        } else if let (instanceId, blockId, slot) = mediaSlotChange, result.shouldPushSnapshot {
            // PR2: Media slot changed (insert/replace/remove) - dedicated callback
            onMediaSlotChanged?(instanceId, blockId, slot)
            // Also fire generic scene state changed for full sync consumers
            if let sceneState = state.draft.sceneInstanceStates[instanceId] {
                onSceneStateChanged?(instanceId, sceneState)
            }
        } else if let (instanceId, blockId, placement) = mediaPlacementChange, result.shouldPushSnapshot {
            // PR2: Media placement committed - dedicated callback
            onMediaPlacementChanged?(instanceId, blockId, placement)
            if let sceneState = state.draft.sceneInstanceStates[instanceId] {
                onSceneStateChanged?(instanceId, sceneState)
            }
        } else if let (instanceId, blockId, visible) = mediaVisibilityChange, result.shouldPushSnapshot {
            // PR2: Media visibility changed - dedicated callback
            onMediaVisibilityChanged?(instanceId, blockId, visible)
            if let sceneState = state.draft.sceneInstanceStates[instanceId] {
                onSceneStateChanged?(instanceId, sceneState)
            }
        } else if let (instanceId, _) = sceneStateChangeInfo, result.shouldPushSnapshot {
            // Scene state changed (not structure) - incremental sync
            if let sceneState = state.draft.sceneInstanceStates[instanceId] {
                onSceneStateChanged?(instanceId, sceneState)
            }
        } else if result.shouldPushSnapshot {
            // Other undo-able change - fall back to full sync
            notifyTimelineChanged()
        }

        // Emit notices after UI has been updated
        for notice in result.notices {
            onNotice?(notice)
        }

        #if DEBUG
        logAction(action, shouldPush: result.shouldPushSnapshot)
        #endif
    }

    // MARK: - Undo/Redo

    /// Returns true if undo is available.
    public var canUndo: Bool {
        undoStack.canUndo
    }

    /// Returns true if redo is available.
    public var canRedo: Bool {
        undoStack.canRedo
    }

    private func performUndo() {
        let currentSnapshot = EditorSnapshot(from: state)

        guard let snapshot = undoStack.undo(currentSnapshot: currentSnapshot) else {
            #if DEBUG
            print("[EditorStore] Undo: nothing to undo")
            #endif
            return
        }

        restoreNormalizedSnapshot(snapshot)

        #if DEBUG
        print("[EditorStore] Undo performed. Stack: \(undoStack.debugDescription)")
        #endif
    }

    private func performRedo() {
        let currentSnapshot = EditorSnapshot(from: state)

        guard let snapshot = undoStack.redo(currentSnapshot: currentSnapshot) else {
            #if DEBUG
            print("[EditorStore] Redo: nothing to redo")
            #endif
            return
        }

        restoreNormalizedSnapshot(snapshot)

        #if DEBUG
        print("[EditorStore] Redo performed. Stack: \(undoStack.debugDescription)")
        #endif
    }

    /// Restores state from snapshot with normalization.
    /// Applies invariants, clamps playhead, and emits notices.
    @discardableResult
    func restoreNormalizedSnapshot(_ snapshot: EditorSnapshot) -> [EditorNotice] {
        state.restore(from: snapshot)
        let notices = EditorReducer.applyInvariantsAndBuildNotices(state: &state)
        // Only re-derive selection if follow mode is active
        EditorReducer.rebindSelectionIfFollowing(state: &state)
        notifyTimelineChanged()
        notifySelectionChanged()
        onPlayheadChanged?(state.playheadCompressedFrame)
        notifyUndoRedoChanged()
        onStateRestoredFromUndoRedo?()
        for notice in notices { onNotice?(notice) }
        return notices
    }

    // MARK: - Convenience Accessors

    /// Returns the current draft (for persistence).
    public var currentDraft: ProjectDraft {
        state.draft
    }

    /// Returns canonical timeline.
    public var canonicalTimeline: CanonicalTimeline {
        state.canonicalTimeline
    }

    /// Returns current playhead position (compressed frame).
    public var playheadCompressedFrame: Int {
        state.playheadCompressedFrame
    }

    /// Returns current selection.
    public var selection: TimelineSelection {
        state.selection
    }

    /// Returns project duration.
    public var projectDurationUs: TimeUs {
        state.projectDurationUs
    }

    /// Returns scene items.
    public var sceneItems: [TimelineItem] {
        state.sceneItems
    }

    /// Returns scenes as SceneDraft array (for UI compatibility).
    public var sceneDrafts: [SceneDraft] {
        state.canonicalTimeline.toSceneDrafts()
    }

    // MARK: - Private

    private func notifyTimelineChanged() {
        onTimelineChanged?(state)
    }

    private func notifyTimelinePreviewChanged() {
        onTimelinePreviewChanged?(state)
    }

    private func notifySelectionChanged() {
        let selection: TimelineSelection? = state.selection == .none ? nil : state.selection
        onSelectionChanged?(selection)
    }

    private func notifyUndoRedoChanged() {
        onUndoRedoChanged?(canUndo, canRedo)
    }

    /// PR-F: Extracts scene instance ID from scene-state-only actions.
    /// Returns nil for structural timeline changes or non-scene-state actions.
    private func extractSceneStateChange(action: EditorAction) -> (UUID, String)? {
        switch action {
        case .setBlockVariant(let instanceId, let blockId, _):
            return (instanceId, blockId)
        case .setBlockToggle(let instanceId, let blockId, _, _):
            return (instanceId, blockId)
        case .setMediaSlot(let instanceId, let blockId, _):
            return (instanceId, blockId)
        case .setBlockMediaPresent(let instanceId, let blockId, _):
            return (instanceId, blockId)
        case .setMediaPlacement(let instanceId, let blockId, _, .ended):
            return (instanceId, blockId)
        case .setMediaFitMode(let instanceId, let blockId, _):
            return (instanceId, blockId)
        case .resetMediaPlacement(let instanceId, let blockId):
            return (instanceId, blockId)
        case .resetSceneState(let instanceId):
            return (instanceId, "")
        default:
            return nil
        }
    }

    /// Extracts video selection change info from action.
    /// Returns nil for non-video-selection actions.
    private func extractVideoSelectionChange(action: EditorAction) -> (UUID, String, PersistedVideoSelection)? {
        if case .setVideoSelection(let instanceId, let blockId, let selection) = action {
            return (instanceId, blockId, selection)
        }
        return nil
    }

    /// PR2: Extracts media slot change info (insert/replace/remove).
    private func extractMediaSlotChange(action: EditorAction) -> (UUID, String, SceneMediaSlot?)? {
        if case .setMediaSlot(let instanceId, let blockId, let slot) = action {
            return (instanceId, blockId, slot)
        }
        return nil
    }

    /// PR2: Extracts media placement change info (committed placement).
    private func extractMediaPlacementChange(action: EditorAction) -> (UUID, String, MediaPlacementState)? {
        switch action {
        case .setMediaPlacement(let instanceId, let blockId, let placement, .ended):
            return (instanceId, blockId, placement)
        case .setMediaFitMode(let instanceId, let blockId, let fitMode):
            return (instanceId, blockId, .default(fitMode: fitMode))
        case .resetMediaPlacement(let instanceId, let blockId):
            // Look up current fitMode from state to build the reset placement
            if let slot = state.draft.sceneInstanceStates[instanceId]?.mediaSlotsByBlockId?[blockId] {
                return (instanceId, blockId, slot.asset.placement)
            }
            return nil
        default:
            return nil
        }
    }

    /// PR2: Extracts media visibility change info (hide/show).
    private func extractMediaVisibilityChange(action: EditorAction) -> (UUID, String, Bool)? {
        if case .setBlockMediaPresent(let instanceId, let blockId, let present) = action {
            return (instanceId, blockId, present)
        }
        return nil
    }

    #if DEBUG
    private func logAction(_ action: EditorAction, shouldPush: Bool) {
        let actionName: String
        switch action {
        case .loadProject: actionName = "loadProject"
        case .setPlayhead: actionName = "setPlayhead"
        case .select: actionName = "select"
        case .trimScene(_, let phase, _, _): actionName = "trimScene(\(phase))"
        case .reorderScene: actionName = "reorderScene"
        case .addScene: actionName = "addScene"
        case .duplicateScene: actionName = "duplicateScene"
        case .deleteScene: actionName = "deleteScene"
        case .setBlockVariant: actionName = "setBlockVariant"
        case .setBlockToggle: actionName = "setBlockToggle"
        case .setMediaSlot: actionName = "setMediaSlot"
        case .setVideoSelection: actionName = "setVideoSelection"
        case .focusScene: actionName = "focusScene"
        case .enterSceneEdit: actionName = "enterSceneEdit"
        case .exitSceneEdit: actionName = "exitSceneEdit"
        case .selectBlock: actionName = "selectBlock"
        case .resetSceneState: actionName = "resetSceneState"
        case .setBlockMediaPresent: actionName = "setBlockMediaPresent"
        case .setMediaPlacement(_, _, _, let phase): actionName = "setMediaPlacement(\(phase))"
        case .setMediaFitMode: actionName = "setMediaFitMode"
        case .resetMediaPlacement: actionName = "resetMediaPlacement"
        case .setBackground: actionName = "setBackground"
        case .undo: actionName = "undo"
        case .redo: actionName = "redo"
        default: actionName = "other"
        }

        print("[EditorStore] dispatch(\(actionName)) push=\(shouldPush) duration=\(state.projectDurationUs)us")
    }
    #endif
}

// MARK: - Factory

public extension EditorStore {

    /// Creates a store initialized with a project and template defaults.
    static func create(
        draft: ProjectDraft,
        templateFPS: Int,
        defaultSceneSequence: [SceneTypeDefault]
    ) -> EditorStore {
        let store = EditorStore()
        store.dispatch(.loadProject(
            draft: draft,
            templateFPS: templateFPS,
            defaultSceneSequence: defaultSceneSequence
        ))
        return store
    }
}
