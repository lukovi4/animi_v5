import Foundation
import AnimiEngineCore

/// Slice-005 — the SINGLE shared app-side microsecond→canonical-tick projection policy. App `TimeUs` is
/// arbitrary `Int64` and need not land on the 240 kHz grid, so a half-open app interval `[startUs, endUs)`
/// is projected OUTWARD: `start = floor(us·6/25)`, `end = ceil(us·6/25)`. This guarantees the projected
/// canonical interval never SHRINKS the app interval.
///
/// Used consistently for the audio destination (`AppAudioManifestBridge`) AND the minimal scene/project
/// coverage (`RuntimeCanonicalAudioPlanSource`), so project coverage (ceil-end) can never be shorter than
/// an audio destination's ceil-end for the same `endUs`. Integer-only, checked, fail-closed on overflow.
enum Slice005TickProjection {

    /// 240000/1_000_000 reduced to 6/25 (so the intermediate `us·6` is 6× smaller than `us·240000`).
    private static let num: Int64 = 6
    private static let den: Int64 = 25

    /// `floor(us · 240000 / 1_000_000) = floor(us · 6 / 25)` for `us >= 0`. `nil` on overflow.
    static func floorTicks(_ us: Int64) -> Int64? {
        let scaled = us.multipliedReportingOverflow(by: num)
        guard !scaled.overflow else { return nil }
        return scaled.partialValue / den                       // floor for non-negative operands
    }

    /// `ceil(us · 240000 / 1_000_000) = floor((us·6 + 24)/25)` for `us >= 0`. `nil` on overflow.
    static func ceilTicks(_ us: Int64) -> Int64? {
        let scaled = us.multipliedReportingOverflow(by: num)
        guard !scaled.overflow else { return nil }
        let bumped = scaled.partialValue.addingReportingOverflow(den - 1)
        guard !bumped.overflow else { return nil }
        return bumped.partialValue / den
    }
}
