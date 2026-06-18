/// The original asset's native timescale (units per second), retained separately from the exact
/// rational target (Task-002 plan, §4.2).
///
/// This is metadata only. Task 002 never rounds a ``RationalSourceTime`` onto this grid; the
/// timescale is preserved so a later media-boundary layer can perform sample-table lookup.
public struct SourceTimescale: Hashable, Sendable {
    public let unitsPerSecond: Int64          // > 0, original asset metadata

    public init(unitsPerSecond: Int64) throws {
        guard unitsPerSecond > 0 else {
            throw TimeError.nonPositiveDenominator(field: "SourceTimescale.unitsPerSecond", value: unitsPerSecond)
        }
        self.unitsPerSecond = unitsPerSecond
    }
}
