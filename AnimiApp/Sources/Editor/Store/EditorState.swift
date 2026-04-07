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

// MARK: - Timeline Scene Selection Mode

/// Controls how scene selection behaves relative to playhead movement.
public enum TimelineSceneSelectionMode: Equatable, Sendable {
    /// No automatic selection — user must explicitly tap a scene.
    case inactive
    /// Selection follows playhead across scenes (activated by focusScene).
    case followPlayhead
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

    /// Timeline scene selection mode (follows playhead or inactive).
    public var timelineSceneSelectionMode: TimelineSceneSelectionMode = .inactive

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

    // MARK: - Playhead-Derived Helpers (Timeline Mode)

    /// Returns the scene instance ID at the current playhead position.
    /// Uses frameMapping from TimelineTransitionMath (primary scene by 50% rule).
    /// Returns nil if playhead is out of range or no scenes exist.
    public func sceneIdAtPlayhead() -> UUID? {
        let math = makeTransitionMath()
        guard let mapping = math.frameMapping(for: playheadCompressedFrame) else { return nil }
        let items = sceneItems
        guard mapping.sceneIndex >= 0 && mapping.sceneIndex < items.count else { return nil }
        return items[mapping.sceneIndex].id
    }

    // MARK: - Initialization

    public init(
        draft: ProjectDraft,
        playheadCompressedFrame: Int = 0,
        selection: TimelineSelection = .none,
        timelineSceneSelectionMode: TimelineSceneSelectionMode = .inactive,
        templateFPS: Int = 30
    ) {
        self.draft = draft
        self.playheadCompressedFrame = playheadCompressedFrame
        self.selection = selection
        self.timelineSceneSelectionMode = timelineSceneSelectionMode
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

/// Content-only snapshot of editor state for undo/redo.
/// Contains only content fields — interaction state (playhead, selection, UI mode)
/// is preserved across undo/redo so the user isn't teleported.
public struct EditorSnapshot: Equatable, Sendable {

    /// Canonical timeline (tracks + items + payloads).
    public let canonicalTimeline: CanonicalTimeline

    /// Per-instance scene states at snapshot time.
    public let sceneInstanceStates: [UUID: SceneState]

    /// Background override at snapshot time.
    public let background: ProjectBackgroundOverride

    public init(
        canonicalTimeline: CanonicalTimeline,
        sceneInstanceStates: [UUID: SceneState] = [:],
        background: ProjectBackgroundOverride = .empty
    ) {
        self.canonicalTimeline = canonicalTimeline
        self.sceneInstanceStates = sceneInstanceStates
        self.background = background
    }

    /// Creates content-only snapshot from current state.
    public init(from state: EditorState) {
        self.canonicalTimeline = state.canonicalTimeline
        self.sceneInstanceStates = state.draft.sceneInstanceStates
        self.background = state.draft.background
    }
}

// MARK: - State Restoration

public extension EditorState {

    /// Restores content from snapshot.
    /// Preserves template configuration (FPS) and interaction state (playhead, selection, UI mode).
    mutating func restore(from snapshot: EditorSnapshot) {
        draft.canonicalTimeline = snapshot.canonicalTimeline
        draft.sceneInstanceStates = snapshot.sceneInstanceStates
        draft.background = snapshot.background
    }
}
