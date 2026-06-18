/// A non-negative output frame index (Task-002 plan, §4.1).
///
/// `FrameIndex -> ProjectTime` is exact for supported rates. The reverse conversion requires an
/// explicit rounding policy and is intentionally absent here — it is never used implicitly in
/// timeline math.
public struct FrameIndex: Hashable, Comparable, Sendable {
    public let value: Int64                 // >= 0

    public init(value: Int64) throws {
        guard value >= 0 else { throw TimeError.negativeValue(domain: "FrameIndex", value: value) }
        self.value = value
    }

    public static func < (lhs: FrameIndex, rhs: FrameIndex) -> Bool {
        lhs.value < rhs.value
    }

    /// Exact `FrameIndex -> ProjectTime` at `rate`: `value * exactTicksPerFrame`.
    ///
    /// No rounding occurs; the multiplication and the resulting instant are both checked.
    public func projectTime(at rate: FrameRate) throws -> ProjectTime {
        let ticksPerFrame = try rate.exactTicksPerFrame
        let ticks = try CheckedInt64.multiply(value, ticksPerFrame, "FrameIndex.projectTime")
        return try ProjectTime(ticks: ticks)
    }
}
