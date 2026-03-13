import Foundation
import TVECore

// MARK: - Editor Render Contract

/// Pure rules for editor render mode selection.
/// Maps EditorUIMode to TemplateMode and defines playback permissions.
enum EditorRenderContract {

    /// Returns the appropriate TemplateMode for the given EditorUIMode.
    /// - `.timeline` -> `.preview` (real animation, real frame)
    /// - `.sceneEdit` -> `.edit` (no-anim, frame 0)
    static func templateMode(for uiMode: EditorUIMode) -> TemplateMode {
        switch uiMode {
        case .timeline:
            return .preview
        case .sceneEdit:
            return .edit
        }
    }

    /// Returns whether playback is allowed in the given EditorUIMode.
    /// - `.timeline`: playback allowed
    /// - `.sceneEdit`: playback not allowed
    static func isPlaybackAllowed(in uiMode: EditorUIMode) -> Bool {
        switch uiMode {
        case .timeline:
            return true
        case .sceneEdit:
            return false
        }
    }
}
