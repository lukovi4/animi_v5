import Foundation

// MARK: - Timeline Events (PR1: Unified TimelineEvent + phases)

/// Interaction phase for gesture-based events.
/// Used to distinguish between start, ongoing, and end of interactions.
public enum InteractionPhase: Sendable {
    case began
    case changed
    case ended
    case cancelled
}

/// Which edge of a clip is being trimmed.
public enum TrimEdge: Sendable {
    case leading
    case trailing
}

/// Unified timeline event stream.
/// All timeline interactions flow through this single event type.
public enum TimelineEvent: Sendable {
    /// Scrub event: user is changing playhead position.
    /// - timeUs: Time in microseconds under playhead
    /// - quantize: Mode for frame quantization (.dragging for live, .ended for snap)
    /// - phase: Gesture phase (.began, .changed, .ended)
    case scrub(timeUs: TimeUs, quantize: QuantizeMode, phase: InteractionPhase)

    /// Scroll event: timeline offset or scale changed.
    /// Used for ruler synchronization.
    /// - offsetX: Current content offset X
    /// - pxPerSecond: Current pixels per second scale
    case scroll(offsetX: CGFloat, pxPerSecond: CGFloat)

    /// Selection event: user tapped to select/deselect track.
    /// - selection: New selection state
    case selection(TimelineSelection)

    /// Trim scene event: user is dragging a scene clip handle.
    /// - sceneId: ID of the scene being trimmed
    /// - newDurationUs: New duration for the scene in microseconds
    /// - edge: Which edge is being trimmed (.leading or .trailing)
    /// - phase: Gesture phase (.began, .changed, .ended)
    case trimScene(sceneId: UUID, newDurationUs: TimeUs, edge: TrimEdge, phase: InteractionPhase)

    /// Reorder scene event: user is dragging a scene to reorder (PR3).
    /// - sceneId: ID of the scene being moved
    /// - toIndex: Target index in scene sequence
    /// - phase: Gesture phase (.began for lift, .changed for drag, .ended for drop)
    case reorderScene(sceneId: UUID, toIndex: Int, phase: InteractionPhase)
}
