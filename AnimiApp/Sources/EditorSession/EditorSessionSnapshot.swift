import Foundation

/// Content-only snapshot for dirty comparison and undo.
/// Excludes interaction state (playhead, selection, UI mode) — only captures
/// the data the user would lose if the editor closed without saving.
struct EditorSessionSnapshot: Equatable, Sendable {
    let canonicalTimeline: CanonicalTimeline
    let sceneInstanceStates: [UUID: SceneState]
    let background: ProjectBackgroundOverride

    init(from state: EditorState) {
        self.canonicalTimeline = state.canonicalTimeline
        self.sceneInstanceStates = state.draft.sceneInstanceStates
        self.background = state.draft.background
    }

    init(canonicalTimeline: CanonicalTimeline, sceneInstanceStates: [UUID: SceneState], background: ProjectBackgroundOverride) {
        self.canonicalTimeline = canonicalTimeline
        self.sceneInstanceStates = sceneInstanceStates
        self.background = background
    }
}
