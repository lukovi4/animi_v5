import Foundation

/// Defines how the container clips its content
public enum ContainerClip: String, Codable, Equatable, Sendable {
    /// Clip to the slot rectangle immediately
    case slotRect

    /// Clip to the slot rectangle after animation settles
    case slotRectAfterSettle

    /// No clipping applied
    case none
}
