import Foundation
import CoreGraphics

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

// MARK: - Timeline State (PR2, Time Refactor)

/// Snapshot of timeline state for preserve/restore during re-configure.
/// Used to maintain time position, zoom level, and selection when duration changes.
public struct TimelineState: Equatable, Sendable {
    /// Time under playhead in microseconds (source of truth).
    public let timeUnderPlayheadUs: TimeUs

    /// Current zoom level (1.0 = 100%)
    public let zoom: CGFloat

    /// Current selection state
    public let selection: TimelineSelection

    public init(timeUnderPlayheadUs: TimeUs, zoom: CGFloat, selection: TimelineSelection) {
        self.timeUnderPlayheadUs = timeUnderPlayheadUs
        self.zoom = zoom
        self.selection = selection
    }
}
