import Foundation
import CoreGraphics

// MARK: - Timeline Selection (PR2: Multi-scene support)

/// Represents the currently selected item on the timeline.
/// Used to switch between GlobalActionBar and ContextBar.
public enum TimelineSelection: Equatable, Sendable {
    /// No item selected - show GlobalActionBar
    case none

    /// Scene clip selected by ID - show ContextBar with trim handles
    case scene(id: UUID)

    /// Audio clip selected by item ID - show ContextBar with audio actions
    case audio(itemId: UUID)

    /// Text overlay item selected by item ID - show ContextBar with text actions (PR9)
    case text(itemId: UUID)

    /// Sticker overlay item selected by item ID - show ContextBar with sticker actions (PR10)
    case sticker(itemId: UUID)

    /// Returns true if any scene is selected (regardless of ID)
    var isSceneSelected: Bool {
        if case .scene = self { return true }
        return false
    }

    /// Returns true if an audio item is selected
    var isAudioSelected: Bool {
        if case .audio = self { return true }
        return false
    }

    /// Returns true if a text overlay item is selected (PR9)
    var isTextSelected: Bool {
        if case .text = self { return true }
        return false
    }

    /// Returns true if a sticker overlay item is selected (PR10)
    var isStickerSelected: Bool {
        if case .sticker = self { return true }
        return false
    }
}

// MARK: - Timeline State (PR2, Time Refactor, Phase 2.1)

/// Snapshot of timeline state for preserve/restore during re-configure.
/// Used to maintain time position, zoom level, and selection when duration changes.
/// Phase 2.1: Uses playheadCompressedFrame as source of truth (not nominal timeUs).
public struct TimelineState: Equatable, Sendable {
    /// Compressed frame under playhead (source of truth).
    /// Phase 2.1: Replaces timeUnderPlayheadUs.
    public let playheadCompressedFrame: Int

    /// Current zoom level (1.0 = 100%)
    public let zoom: CGFloat

    /// Current selection state
    public let selection: TimelineSelection

    public init(playheadCompressedFrame: Int, zoom: CGFloat, selection: TimelineSelection) {
        self.playheadCompressedFrame = playheadCompressedFrame
        self.zoom = zoom
        self.selection = selection
    }
}
