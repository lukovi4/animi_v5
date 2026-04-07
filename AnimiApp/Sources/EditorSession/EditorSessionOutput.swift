import Foundation

/// Events emitted from session to UI layer.
enum EditorSessionOutput {
    case bootstrapSucceeded(BootstrappedEditor)
    case bootstrapFailed(String)
}

/// Result of requesting close — tells the UI whether to prompt or just pop.
enum EditorCloseAction {
    /// Dirty — show Save/Don't Save/Cancel alert.
    case needsUserDecision
    /// Clean — just pop the view controller.
    case safeToClose
}
