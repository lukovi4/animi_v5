import Foundation

/// MediaBlock defines a replaceable animated container in the scene
public struct MediaBlock: Decodable, Equatable, Sendable {
    /// Unique identifier for this block
    public let id: String

    /// Z-index for render ordering (higher values render on top)
    public let zIndex: Int

    /// Block container rectangle on canvas (scene coordinates)
    public let rect: Rect

    /// Clip mode for the block container
    public let containerClip: ContainerClip

    /// Timing configuration for block visibility
    public let timing: Timing?

    /// Input slot configuration
    public let input: MediaInput

    /// Available animation variants
    public let variants: [Variant]

    public init(
        id: String,
        zIndex: Int,
        rect: Rect,
        containerClip: ContainerClip,
        timing: Timing? = nil,
        input: MediaInput,
        variants: [Variant]
    ) {
        self.id = id
        self.zIndex = zIndex
        self.rect = rect
        self.containerClip = containerClip
        self.timing = timing
        self.input = input
        self.variants = variants
    }

    private enum CodingKeys: String, CodingKey {
        case id = "blockId"
        case zIndex
        case rect
        case containerClip
        case timing
        case input
        case variants
    }
}
