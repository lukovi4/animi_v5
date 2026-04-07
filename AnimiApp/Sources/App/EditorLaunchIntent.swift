import Foundation

/// Canonical intent describing why the editor is being opened.
/// Used by `AppCompositionRoot` to create the editor with the correct entry context.
enum EditorLaunchIntent {
    /// User selected a template from the catalog.
    case template(templateId: String)
    /// User tapped a saved project in My Projects.
    case savedProject(projectId: UUID)
    /// Recovery flow: user chose "Continue" on the recovery prompt.
    case resumeDraft
    /// User chose to start a blank project (PR 7 UI entry point).
    case blankProject
}
