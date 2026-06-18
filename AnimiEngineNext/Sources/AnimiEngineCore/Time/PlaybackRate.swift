/// A positive rational source playback rate (Task-002 plan, §4.2).
///
/// v1 only uses `1/1`, but the type is rational so the source-time mapping is exact for any future
/// positive rate. Both components are strictly positive in v1.
public struct PlaybackRate: Hashable, Sendable {
    public let numerator: Int64               // > 0 in v1
    public let denominator: Int64             // > 0

    public init(numerator: Int64, denominator: Int64) throws {
        guard numerator > 0 else {
            throw TimeError.nonPositiveDenominator(field: "PlaybackRate.numerator", value: numerator)
        }
        guard denominator > 0 else {
            throw TimeError.nonPositiveDenominator(field: "PlaybackRate.denominator", value: denominator)
        }
        self.numerator = numerator
        self.denominator = denominator
    }

    private init(uncheckedNumerator numerator: Int64, denominator: Int64) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public static let oneToOne = PlaybackRate(uncheckedNumerator: 1, denominator: 1)
}
