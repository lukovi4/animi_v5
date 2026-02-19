import Foundation

/// 2D point for persistence models.
/// Decoupled from TVECore.Vec2D to avoid dependency in persistence layer.
public struct Point2: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2(x: 0, y: 0)
}
