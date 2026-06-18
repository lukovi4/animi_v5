import Foundation
import AnimiEngineRenderModel

/// Task-003 / Step-13 — deterministic candidate↔reference comparison (D3: integer metrics only).
///
/// Comparison is byte-exact where valid and bounded otherwise, using ONLY deterministic integer metrics:
/// the maximum per-channel absolute delta and the count of differing pixels. There is no floating
/// perceptual metric. A comparison NEVER writes a reference (no self-blessing): it produces a verdict and
/// metrics that the recorder serializes.
public enum FrameComparator {

    public enum ComparisonError: Error, Equatable, Sendable {
        case dimensionMismatch(candidate: String, reference: String, detail: String)
        case formatMismatch(detail: String)
    }

    public enum Verdict: String, Sendable, Equatable {
        case exactMatch        // byte-identical (and equal rawOutputHash)
        case withinBounds      // not identical, but within the pinned integer tolerances
        case outOfBounds       // a real difference beyond tolerance (recorded, never blessed)
        case candidateOnly     // no reference present
    }

    /// The pinned integer tolerances for a bounded comparison (D3). `maxChannelDelta` is the largest
    /// per-channel absolute difference allowed for any pixel; `maxDifferingPixels` caps how many pixels may
    /// differ at all. Defaults are deliberately tight; callers may pin per-case.
    public struct Tolerances: Sendable, Equatable {
        public let maxChannelDelta: Int
        public let maxDifferingPixels: Int
        public init(maxChannelDelta: Int, maxDifferingPixels: Int) {
            self.maxChannelDelta = maxChannelDelta
            self.maxDifferingPixels = maxDifferingPixels
        }
        /// Exact-only (any difference is out of bounds).
        public static let exact = Tolerances(maxChannelDelta: 0, maxDifferingPixels: 0)
    }

    public struct Result: Sendable, Equatable {
        public let verdict: Verdict
        public let referencePresent: Bool
        public let candidateHash: String
        public let referenceHash: String?
        public let maxChannelDelta: Int       // 0 when exact / no reference
        public let differingPixelCount: Int   // 0 when exact / no reference
        public let tolerances: Tolerances
    }

    /// Compare a candidate against an optional reference. With no reference → `candidateOnly`. With a
    /// reference → byte-exact check first (→ exactMatch), else integer metrics vs tolerances
    /// (→ withinBounds / outOfBounds). Dimension/format mismatch is a typed error.
    public static func compare(
        candidate: RenderedFrame, reference: RenderedFrame?, tolerances: Tolerances
    ) throws -> Result {
        guard let reference else {
            return Result(verdict: .candidateOnly, referencePresent: false,
                          candidateHash: candidate.rawOutputHash, referenceHash: nil,
                          maxChannelDelta: 0, differingPixelCount: 0, tolerances: tolerances)
        }
        guard candidate.dimensions.width == reference.dimensions.width,
              candidate.dimensions.height == reference.dimensions.height else {
            throw ComparisonError.dimensionMismatch(
                candidate: "\(candidate.dimensions.width)x\(candidate.dimensions.height)",
                reference: "\(reference.dimensions.width)x\(reference.dimensions.height)",
                detail: "candidate vs reference dimensions differ")
        }
        guard candidate.dimensions.format == .bgra8, reference.dimensions.format == .bgra8 else {
            throw ComparisonError.formatMismatch(detail: "both frames must be bgra8")
        }

        // Byte-exact fast path.
        if candidate.bytes == reference.bytes {
            return Result(verdict: .exactMatch, referencePresent: true,
                          candidateHash: candidate.rawOutputHash, referenceHash: reference.rawOutputHash,
                          maxChannelDelta: 0, differingPixelCount: 0, tolerances: tolerances)
        }

        // Integer metrics over every channel of every pixel (deterministic).
        let (maxDelta, differing) = metrics(candidate: candidate, reference: reference)
        let within = maxDelta <= tolerances.maxChannelDelta && differing <= tolerances.maxDifferingPixels
        return Result(verdict: within ? .withinBounds : .outOfBounds, referencePresent: true,
                      candidateHash: candidate.rawOutputHash, referenceHash: reference.rawOutputHash,
                      maxChannelDelta: maxDelta, differingPixelCount: differing, tolerances: tolerances)
    }

    /// Max per-channel absolute delta and the number of differing pixels, over the tight BGRA8 pixel grid.
    static func metrics(candidate: RenderedFrame, reference: RenderedFrame) -> (maxChannelDelta: Int, differingPixels: Int) {
        let c = [UInt8](candidate.bytes), r = [UInt8](reference.bytes)
        let w = candidate.dimensions.width, h = candidate.dimensions.height
        let cStride = candidate.dimensions.bytesPerRow, rStride = reference.dimensions.bytesPerRow
        var maxDelta = 0, differing = 0
        for y in 0..<h {
            var x = 0
            while x < w {
                let cp = y * cStride + x * 4, rp = y * rStride + x * 4
                var pixelDiffers = false
                var ch = 0
                while ch < 4 {
                    let d = abs(Int(c[cp + ch]) - Int(r[rp + ch]))
                    if d > maxDelta { maxDelta = d }
                    if d != 0 { pixelDiffers = true }
                    ch += 1
                }
                if pixelDiffers { differing += 1 }
                x += 1
            }
        }
        return (maxDelta, differing)
    }
}
