import Foundation

/// State machine for the editor runtime lifecycle.
///
/// Drives render source selection and gates operations like export.
enum EditorRuntimeState: Equatable {
    case idle
    case booting
    case timelinePreview
    case sceneEdit(instanceId: UUID)
    case exporting
    case error(String)
}
