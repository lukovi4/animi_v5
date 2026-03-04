import Foundation

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
    private var previousPlayheadTimeUs: TimeUs = 0

    // MARK: - Callbacks (Split for Performance)

    /// Called when playhead position changes.
    /// Use for lightweight UI updates (playhead indicator, current frame).
    public var onPlayheadChanged: ((TimeUs) -> Void)?

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

    // MARK: - Initialization

    public init(initialState: EditorState = .empty()) {
        self.state = initialState
        self.undoStack = UndoStack()
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

        // Handle gesture baseline for trim and transform gestures (PR9)
        let gesturePhase: InteractionPhase?
        switch action {
        case .trimScene(_, let phase, _, _):
            gesturePhase = phase
        case .setBlockTransform(_, _, _, let phase):
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
                // Restore baseline and clear
                if let baseline = pendingGestureSnapshot {
                    state.restore(from: baseline)
                    pendingGestureSnapshot = nil
                    // P1 fix: Notify all observers after cancel restore
                    notifyTimelineChanged()
                    notifySelectionChanged()
                    onPlayheadChanged?(state.playheadTimeUs)
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
        case .setBlockTransform(_, _, _, .ended):
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
        let oldPlayhead = state.playheadTimeUs
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
        let playheadChanged = state.playheadTimeUs != oldPlayhead
        let selectionChanged = state.selection != oldSelection
        let timelineChanged = state.canonicalTimeline != oldTimeline || result.shouldPushSnapshot

        // Determine if this is a trim preview action (.began/.changed)
        let isTrimPreview: Bool = {
            if case .trimScene(_, let phase, _, _) = action {
                return phase == .began || phase == .changed
            }
            return false
        }()

        if playheadChanged {
            onPlayheadChanged?(state.playheadTimeUs)
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

        if timelineChanged {
            if isTrimPreview {
                notifyTimelinePreviewChanged()
            } else {
                notifyTimelineChanged()
            }
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

        // Restore state from snapshot
        state.restore(from: snapshot)

        // Notify all observers
        notifyTimelineChanged()
        notifySelectionChanged()
        onPlayheadChanged?(state.playheadTimeUs)
        notifyUndoRedoChanged()

        // PR-A: Notify runtime to re-apply state for active scene instance
        onStateRestoredFromUndoRedo?()

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

        // Restore state from snapshot
        state.restore(from: snapshot)

        // Notify all observers
        notifyTimelineChanged()
        notifySelectionChanged()
        onPlayheadChanged?(state.playheadTimeUs)
        notifyUndoRedoChanged()

        // PR-A: Notify runtime to re-apply state for active scene instance
        onStateRestoredFromUndoRedo?()

        #if DEBUG
        print("[EditorStore] Redo performed. Stack: \(undoStack.debugDescription)")
        #endif
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

    /// Returns current playhead position.
    public var playheadTimeUs: TimeUs {
        state.playheadTimeUs
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
        case .setBlockTransform(_, _, _, let phase): actionName = "setBlockTransform(\(phase))"
        case .setBlockVariant: actionName = "setBlockVariant"
        case .setBlockToggle: actionName = "setBlockToggle"
        case .setBlockMedia: actionName = "setBlockMedia"
        case .enterSceneEdit: actionName = "enterSceneEdit"
        case .exitSceneEdit: actionName = "exitSceneEdit"
        case .selectBlock: actionName = "selectBlock"
        case .resetSceneState: actionName = "resetSceneState"
        case .setBlockMediaPresent: actionName = "setBlockMediaPresent"
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

    /// Creates a store initialized with a project and recipe defaults.
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
