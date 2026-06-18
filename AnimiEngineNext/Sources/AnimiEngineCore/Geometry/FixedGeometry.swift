/// A fixed-point canvas point (Task-002 plan, §5).
public struct FixedPoint: Hashable, Sendable {
    public let x: CanvasScalar
    public let y: CanvasScalar

    public init(x: CanvasScalar, y: CanvasScalar) {
        self.x = x
        self.y = y
    }
}

/// A fixed-point canvas rectangle (Task-002 plan, §5).
///
/// Width and height must be strictly positive — a degenerate or negative-extent rectangle is
/// rejected at construction.
public struct FixedRect: Hashable, Sendable {
    public let x: CanvasScalar
    public let y: CanvasScalar
    public let width: CanvasScalar
    public let height: CanvasScalar

    public init(x: CanvasScalar, y: CanvasScalar, width: CanvasScalar, height: CanvasScalar) throws {
        guard width.rawValue > 0 else {
            throw TimeError.negativeValue(domain: "FixedRect.width", value: width.rawValue)
        }
        guard height.rawValue > 0 else {
            throw TimeError.negativeValue(domain: "FixedRect.height", value: height.rawValue)
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
