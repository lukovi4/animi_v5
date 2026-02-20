import Foundation

// MARK: - Timeline

/// Timeline container for layer items.
/// In P0, contains at most one `.sceneBase` layer (can be virtual/computed).
/// Designed to be extensible for future overlay layers (text, stickers, audio).
public struct Timeline: Codable, Equatable, Sendable {

    /// Ordered list of layer items (by zIndex/track).
    public var layers: [LayerItem]

    public init(layers: [LayerItem] = []) {
        self.layers = layers
    }

    /// Empty timeline with no layers.
    public static let empty = Timeline()
}

// MARK: - Layer Kind

/// Type of layer on the timeline.
public enum LayerKind: String, Codable, Sendable {
    /// Base scene layer (compiled template animation).
    /// Always starts at frame 0, ends at projectDurationFrames.
    case sceneBase

    /// Audio layer placeholder (for future implementation).
    case audio

    // Future: text, sticker, image, etc.
}

// MARK: - Layer Item

/// Single item on the timeline.
/// Represents a time range and type of content.
public struct LayerItem: Codable, Equatable, Sendable {

    /// Unique identifier (UUID string).
    public var id: String

    /// Type of layer content.
    public var kind: LayerKind

    /// Start frame (inclusive).
    public var startFrame: Int

    /// End frame (exclusive).
    public var endFrame: Int

    /// Z-order / track index for rendering order.
    public var zIndex: Int

    public init(
        id: String = UUID().uuidString,
        kind: LayerKind,
        startFrame: Int,
        endFrame: Int,
        zIndex: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.zIndex = zIndex
    }

    /// Duration in frames.
    public var durationFrames: Int {
        endFrame - startFrame
    }
}
