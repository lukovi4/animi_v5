/// An exact rational output frame rate (Task-002 plan, §1.1, §4.1).
///
/// `FrameRate` is separate from timeline time. Its sole timeline-relevant capability is the exact
/// integer ticks-per-frame for the eight supported rates; an unsupported rate (one whose
/// ticks-per-frame is not an exact integer at 240,000 ticks/second) throws.
public struct FrameRate: Hashable, Sendable {
    public let numerator: Int64
    public let denominator: Int64

    public init(numerator: Int64, denominator: Int64) throws {
        guard denominator > 0 else {
            throw TimeError.nonPositiveDenominator(field: "FrameRate.denominator", value: denominator)
        }
        guard numerator > 0 else {
            throw TimeError.unsupportedFrameRate(numerator: numerator, denominator: denominator)
        }
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Exact ticks per frame at 240,000 ticks/second: `ticksPerSecond * denominator / numerator`.
    ///
    /// Throws ``TimeError/unsupportedFrameRate(numerator:denominator:)`` if the division is not
    /// exact. All eight supported rates divide exactly.
    public var exactTicksPerFrame: Int64 {
        get throws {
            let scaled = try CheckedInt64.multiply(TickClock.ticksPerSecond, denominator, "FrameRate.ticksPerFrame")
            guard scaled % numerator == 0 else {
                throw TimeError.unsupportedFrameRate(numerator: numerator, denominator: denominator)
            }
            return scaled / numerator
        }
    }

    // MARK: - Supported rates (Task-002 plan, §1.1)

    public static let fps23_976 = FrameRate(uncheckedNumerator: 24_000, denominator: 1_001)
    public static let fps24 = FrameRate(uncheckedNumerator: 24, denominator: 1)
    public static let fps25 = FrameRate(uncheckedNumerator: 25, denominator: 1)
    public static let fps29_97 = FrameRate(uncheckedNumerator: 30_000, denominator: 1_001)
    public static let fps30 = FrameRate(uncheckedNumerator: 30, denominator: 1)
    public static let fps50 = FrameRate(uncheckedNumerator: 50, denominator: 1)
    public static let fps59_94 = FrameRate(uncheckedNumerator: 60_000, denominator: 1_001)
    public static let fps60 = FrameRate(uncheckedNumerator: 60, denominator: 1)

    private init(uncheckedNumerator numerator: Int64, denominator: Int64) {
        self.numerator = numerator
        self.denominator = denominator
    }
}
