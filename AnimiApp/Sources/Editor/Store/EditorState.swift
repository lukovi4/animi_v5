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

    /// Current playhead position in compressed frames.
    /// This is the single source of truth for timeline mode playhead.
    public var playheadCompressedFrame: Int

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

    /// Saved playhead position (compressed frame) for returning from scene edit.
    /// Set when entering scene edit, restored when exiting.
    public var sceneEditReturnCompressedFrame: Int?

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

    // MARK: - Timeline Math Helpers

    /// Creates TimelineTransitionMath from current state.
    /// Pure computation, no engine dependency.
    public func makeTransitionMath() -> TimelineTransitionMath {
        TimelineTransitionMath(
            sceneItems: canonicalTimeline.sceneItems,
            boundaryTransitions: canonicalTimeline.boundaryTransitions,
            fps: templateFPS
        )
    }

    /// Creates TimelinePlayheadMapper from current state.
    /// Pure computation, no engine dependency.
    public func makePlayheadMapper() -> TimelinePlayheadMapper {
        TimelinePlayheadMapper(math: makeTransitionMath())
    }

    /// Returns nominal time in microseconds for current playhead position.
    /// Uses the provided mapper for conversion.
    public func playheadNominalTimeUs(mapper: TimelinePlayheadMapper) -> TimeUs {
        mapper.nominalTimeUs(forCompressedFrame: playheadCompressedFrame)
    }

    /// Total compressed duration in frames.
    public var compressedDurationFrames: Int {
        makeTransitionMath().compressedDurationFrames
    }

    // MARK: - Initialization

    public init(
        draft: ProjectDraft,
        playheadCompressedFrame: Int = 0,
        selection: TimelineSelection = .none,
        templateFPS: Int = 30
    ) {
        self.draft = draft
        self.playheadCompressedFrame = playheadCompressedFrame
        self.selection = selection
        self.templateFPS = templateFPS
    }

    /// Creates an empty state for initialization.
    public static func empty() -> EditorState {
        EditorState(
            draft: ProjectDraft.create(for: ""),
            playheadCompressedFrame: 0,
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

    /// Playhead position at snapshot time (compressed frame).
    public let playheadCompressedFrame: Int

    /// Selection at snapshot time.
    public let selection: TimelineSelection

    /// Per-instance scene states at snapshot time.
    public let sceneInstanceStates: [UUID: SceneState]

    /// Saved scene edit return position (compressed frame).
    public let sceneEditReturnCompressedFrame: Int?

    public init(
        canonicalTimeline: CanonicalTimeline,
        playheadCompressedFrame: Int,
        selection: TimelineSelection,
        sceneInstanceStates: [UUID: SceneState] = [:],
        sceneEditReturnCompressedFrame: Int? = nil
    ) {
        self.canonicalTimeline = canonicalTimeline
        self.playheadCompressedFrame = playheadCompressedFrame
        self.selection = selection
        self.sceneInstanceStates = sceneInstanceStates
        self.sceneEditReturnCompressedFrame = sceneEditReturnCompressedFrame
    }

    /// Creates snapshot from current state.
    public init(from state: EditorState) {
        self.canonicalTimeline = state.canonicalTimeline
        self.playheadCompressedFrame = state.playheadCompressedFrame
        self.selection = state.selection
        self.sceneInstanceStates = state.draft.sceneInstanceStates
        self.sceneEditReturnCompressedFrame = state.sceneEditReturnCompressedFrame
    }
}

// MARK: - State Restoration

public extension EditorState {

    /// Restores state from snapshot.
    /// Preserves template configuration (FPS).
    mutating func restore(from snapshot: EditorSnapshot) {
        draft.canonicalTimeline = snapshot.canonicalTimeline
        draft.sceneInstanceStates = snapshot.sceneInstanceStates
        playheadCompressedFrame = snapshot.playheadCompressedFrame
        selection = snapshot.selection
        sceneEditReturnCompressedFrame = snapshot.sceneEditReturnCompressedFrame
    }
}
