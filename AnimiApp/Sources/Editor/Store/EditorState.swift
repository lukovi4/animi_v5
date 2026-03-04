import Foundation

// MARK: - Editor UI Mode (PR-A: Scene Edit)

/// UI mode for the editor.
/// Controls whether timeline or scene edit UI is shown.
public enum EditorUIMode: Equatable, Sendable {
    /// Normal timeline editing mode.
    case timeline
    /// Scene edit mode for editing media blocks within a scene.
    case sceneEdit(sceneInstanceId: UUID)
}

// MARK: - Editor State (Release v1)

/// Centralized state for the editor.
/// Separates Model (timeline data) from UI essentials (playhead, selection).
public struct EditorState: Equatable, Sendable {

    // MARK: - Model (persisted)

    /// The project draft containing canonical timeline.
    /// This is the single source of truth for timeline data.
    public var draft: ProjectDraft

    // MARK: - UI Essentials (part of undo snapshot)

    /// Current playhead position in microseconds.
    public var playheadTimeUs: TimeUs

    /// Current timeline selection.
    public var selection: TimelineSelection

    // MARK: - Template Configuration (immutable after loadProject)

    /// Template frame rate for quantization.
    public var templateFPS: Int

    // MARK: - Scene Edit Mode (PR-A)
    // Note: These fields are NOT included in EditorSnapshot.
    // Undo/redo should restore content, not teleport user between UI modes.

    /// Current UI mode (timeline vs scene edit).
    public var uiMode: EditorUIMode = .timeline

    /// Selected block ID in scene edit mode.
    /// Only relevant when `uiMode == .sceneEdit`.
    public var selectedBlockId: String?

    /// Saved playhead position for returning from scene edit.
    /// Set when entering scene edit, restored when exiting.
    public var sceneEditReturnPlayheadUs: TimeUs?

    // MARK: - Derived Properties

    /// Returns canonical timeline (convenience accessor).
    public var canonicalTimeline: CanonicalTimeline {
        get { draft.canonicalTimeline }
        set { draft.canonicalTimeline = newValue }
    }

    /// Total project duration from scene sequence.
    public var projectDurationUs: TimeUs {
        canonicalTimeline.totalDurationUs
    }

    /// Scene items from canonical timeline.
    public var sceneItems: [TimelineItem] {
        canonicalTimeline.sceneItems
    }

    // MARK: - Initialization

    public init(
        draft: ProjectDraft,
        playheadTimeUs: TimeUs = 0,
        selection: TimelineSelection = .none,
        templateFPS: Int = 30
    ) {
        self.draft = draft
        self.playheadTimeUs = playheadTimeUs
        self.selection = selection
        self.templateFPS = templateFPS
    }

    /// Creates an empty state for initialization.
    public static func empty() -> EditorState {
        EditorState(
            draft: ProjectDraft.create(for: ""),
            playheadTimeUs: 0,
            selection: .none,
            templateFPS: 30
        )
    }
}

// MARK: - Undo Snapshot

/// Snapshot of editor state for undo/redo.
/// Contains only the data that should be restored on undo.
public struct EditorSnapshot: Equatable, Sendable {

    /// Canonical timeline (tracks + items + payloads).
    public let canonicalTimeline: CanonicalTimeline

    /// Playhead position at snapshot time.
    public let playheadTimeUs: TimeUs

    /// Selection at snapshot time.
    public let selection: TimelineSelection

    /// Per-instance scene states at snapshot time.
    public let sceneInstanceStates: [UUID: SceneState]

    public init(
        canonicalTimeline: CanonicalTimeline,
        playheadTimeUs: TimeUs,
        selection: TimelineSelection,
        sceneInstanceStates: [UUID: SceneState] = [:]
    ) {
        self.canonicalTimeline = canonicalTimeline
        self.playheadTimeUs = playheadTimeUs
        self.selection = selection
        self.sceneInstanceStates = sceneInstanceStates
    }

    /// Creates snapshot from current state.
    public init(from state: EditorState) {
        self.canonicalTimeline = state.canonicalTimeline
        self.playheadTimeUs = state.playheadTimeUs
        self.selection = state.selection
        self.sceneInstanceStates = state.draft.sceneInstanceStates
    }
}

// MARK: - State Restoration

public extension EditorState {

    /// Restores state from snapshot.
    /// Preserves template configuration (FPS).
    mutating func restore(from snapshot: EditorSnapshot) {
        draft.canonicalTimeline = snapshot.canonicalTimeline
        draft.sceneInstanceStates = snapshot.sceneInstanceStates
        playheadTimeUs = snapshot.playheadTimeUs
        selection = snapshot.selection
    }
}
