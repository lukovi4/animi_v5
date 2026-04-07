import Foundation

/// Phase of the editor session lifecycle.
enum EditorSessionPhase: Equatable {
    case idle
    case bootstrapping
    case ready(BootstrappedEditor)
    case failed(String)

    static func == (lhs: EditorSessionPhase, rhs: EditorSessionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.bootstrapping, .bootstrapping):
            return true
        case (.ready(let a), .ready(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Snapshot of all data resolved during bootstrap, consumed by the view controller.
struct BootstrappedEditor: Equatable {
    let activeDraftSlot: ActiveDraftSlot
    let templateId: String
    let draft: ProjectDraft
    let sceneLibrary: SceneLibrarySnapshot
    let defaultSceneSequence: [SceneTypeDefault]
    let firstSceneTypeId: String

    static func == (lhs: BootstrappedEditor, rhs: BootstrappedEditor) -> Bool {
        lhs.templateId == rhs.templateId && lhs.firstSceneTypeId == rhs.firstSceneTypeId
    }
}
