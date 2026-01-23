import Foundation

/// Scene represents the root structure of a scene.json file
public struct Scene: Decodable, Equatable, Sendable {
    /// Schema version for compatibility checking
    public let schemaVersion: String

    /// Unique identifier for this scene
    public let sceneId: String?

    /// Canvas configuration (dimensions, fps, duration)
    public let canvas: Canvas

    /// Optional background configuration
    public let background: Background?

    /// Media blocks in this scene
    public let mediaBlocks: [MediaBlock]

    public init(
        schemaVersion: String,
        sceneId: String? = nil,
        canvas: Canvas,
        background: Background? = nil,
        mediaBlocks: [MediaBlock]
    ) {
        self.schemaVersion = schemaVersion
        self.sceneId = sceneId
        self.canvas = canvas
        self.background = background
        self.mediaBlocks = mediaBlocks
    }
}
