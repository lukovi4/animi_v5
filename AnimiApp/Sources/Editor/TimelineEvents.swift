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
    /// Quantize is applied at TimelineView before emitting this event.
    /// - compressedFrame: Frame index in compressed timeline
    /// - phase: Gesture phase (.began, .changed, .ended)
    case scrub(compressedFrame: Int, phase: InteractionPhase)

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

    /// Edit boundary transition event: user tapped a boundary control.
    /// - fromSceneId: ID of the outgoing scene
    /// - toSceneId: ID of the incoming scene
    /// - anchorRect: Rect for popover anchor (in TimelineView coordinates)
    case editBoundaryTransition(fromSceneId: UUID, toSceneId: UUID, anchorRect: CGRect)

    /// Focus scene event: user tapped a scene in timeline mode.
    /// Moves playhead to scene start and derives selection from playhead.
    /// - sceneId: ID of the scene to focus
    case focusScene(sceneId: UUID)

    /// Move overlay item event (PR9): user is dragging a text/sticker item on timeline.
    /// - itemId: ID of the overlay item being moved
    /// - newStartUs: New start time in microseconds
    /// - phase: Gesture phase (.began, .changed, .ended)
    case moveOverlayItem(itemId: UUID, newStartUs: TimeUs, phase: InteractionPhase)

    /// Trim overlay item event (PR9): user is dragging a trim handle on a text/sticker item.
    /// - itemId: ID of the overlay item being trimmed
    /// - newDurationUs: New duration in microseconds
    /// - edge: Which edge is being trimmed (.leading or .trailing)
    /// - phase: Gesture phase (.began, .changed, .ended)
    case trimOverlayItem(itemId: UUID, newDurationUs: TimeUs, edge: TrimEdge, phase: InteractionPhase)
}
