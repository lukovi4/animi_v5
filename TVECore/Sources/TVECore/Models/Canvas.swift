import Foundation

/// Canvas defines the scene dimensions, frame rate, and duration
public struct Canvas: Codable, Equatable, Sendable {
    /// Width of the canvas in pixels
    public let width: Int

    /// Height of the canvas in pixels
    public let height: Int

    /// Frame rate in frames per second
    public let fps: Int

    /// Total duration of the scene in frames
    public let durationFrames: Int

    public init(width: Int, height: Int, fps: Int, durationFrames: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.durationFrames = durationFrames
    }
}

/// Background configuration for the scene
public struct Background: Codable, Equatable, Sendable {
    /// Type of background (e.g., "solid")
    public let type: String

    /// Color value for solid backgrounds (e.g., "#0B0D1A")
    public let color: String?

    public init(type: String, color: String? = nil) {
        self.type = type
        self.color = color
    }
}
