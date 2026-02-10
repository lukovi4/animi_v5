import Foundation

/// Represents a rectangle with position and size
public struct Rect: Codable, Equatable, Sendable {
    /// X coordinate of the rectangle origin
    public let x: Double

    /// Y coordinate of the rectangle origin
    public let y: Double

    /// Width of the rectangle
    public let width: Double

    /// Height of the rectangle
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - CGRect Conversion

#if canImport(CoreGraphics)
import CoreGraphics

extension Rect {
    /// Converts to CGRect for use with CoreGraphics/UIKit
    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Creates a Rect from CGRect
    public init(cgRect: CGRect) {
        self.x = Double(cgRect.origin.x)
        self.y = Double(cgRect.origin.y)
        self.width = Double(cgRect.size.width)
        self.height = Double(cgRect.size.height)
    }
}
#endif
