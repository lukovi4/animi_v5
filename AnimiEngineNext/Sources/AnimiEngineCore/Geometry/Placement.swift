/// The canonical fixed-point placement of a scene layer or global overlay (Task-002 plan, §5, §6.2).
///
/// `Placement` is render-complete and fully fixed-point: a frame within the canvas, a scale, and a
/// rotation. The renderer never needs to read mutable project state to interpret it.
public struct Placement: Hashable, Sendable {
    /// The layer/overlay frame in canvas space.
    public let frame: FixedRect
    /// Uniform scale applied about the frame.
    public let scale: ScaleScalar
    /// Rotation in fixed-point degrees.
    public let rotation: RotationScalar

    public init(frame: FixedRect, scale: ScaleScalar, rotation: RotationScalar) throws {
        guard scale.rawValue > 0 else {
            throw TimeError.negativeValue(domain: "Placement.scale", value: scale.rawValue)
        }
        self.frame = frame
        self.scale = scale
        self.rotation = rotation
    }
}
