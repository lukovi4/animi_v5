import Foundation

// MARK: - Timeline Selection (PR2)

/// Represents the currently selected item on the timeline.
/// Used to switch between GlobalActionBar and ContextBar.
public enum TimelineSelection: Equatable, Sendable {
    /// No item selected - show GlobalActionBar
    case none

    /// Scene track selected - show ContextBar
    case scene

    /// Audio track selected - show ContextBar (placeholder for future)
    case audio

    // Future: case layer(id: String)
}
