/// The integer pixel canvas size of the project output (Task-002 plan, §6.5).
public struct CanvasSize: Hashable, Sendable {
    public let width: Int64                 // > 0
    public let height: Int64                // > 0

    public init(width: Int64, height: Int64) throws {
        guard width > 0 else { throw ProjectValidationError.invalidRange(field: "CanvasSize.width") }
        guard height > 0 else { throw ProjectValidationError.invalidRange(field: "CanvasSize.height") }
        self.width = width
        self.height = height
    }
}

/// The canvas and frame rate that define the project's output grid (Task-002 plan, §6.5).
public struct OutputContext: Equatable, Sendable {
    public let canvas: CanvasSize
    public let frameRate: FrameRate

    public init(canvas: CanvasSize, frameRate: FrameRate) {
        self.canvas = canvas
        self.frameRate = frameRate
    }
}
