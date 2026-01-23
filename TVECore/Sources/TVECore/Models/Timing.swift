import Foundation

/// Timing defines the visibility window for a media block in scene frames
public struct Timing: Decodable, Equatable, Sendable {
    /// Frame number when the block becomes visible
    public let startFrame: Int

    /// Frame number when the block stops being visible
    public let endFrame: Int

    public init(startFrame: Int, endFrame: Int) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}
