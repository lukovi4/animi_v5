import Foundation
import AnimiEngineRenderModel

/// Task-003 / Step-13 (D2) — a deterministic absolute-per-channel-delta diff image.
///
/// For each pixel, the diff RGB encodes `min(255, |candidate − reference| · amplification)` per channel
/// (so identical pixels are black and differences are visible), with alpha forced to 255. The
/// `amplification` factor is recorded alongside (in the comparison JSON). The result is a pure
/// deterministic function of its inputs — no random colour, no timestamp.
public enum DiffImage {

    public enum DiffError: Error, Equatable, Sendable {
        case dimensionMismatch(detail: String)
    }

    /// A diff frame (BGRA8, tightly packed) suitable for the deterministic PNG encoder.
    public struct DiffFrame: Sendable {
        public let bgra8: Data
        public let width: Int
        public let height: Int
        public let bytesPerRow: Int
        public let amplification: Int
    }

    /// Build the absolute-delta diff. `amplification` (>= 1) scales small deltas for visibility and is
    /// recorded in evidence. Channels are clamped to 255.
    public static func diff(candidate: RenderedFrame, reference: RenderedFrame, amplification: Int) throws -> DiffFrame {
        guard candidate.dimensions.width == reference.dimensions.width,
              candidate.dimensions.height == reference.dimensions.height else {
            throw DiffError.dimensionMismatch(detail: "candidate vs reference dimensions differ")
        }
        let amp = max(1, amplification)
        let w = candidate.dimensions.width, h = candidate.dimensions.height
        let cStride = candidate.dimensions.bytesPerRow, rStride = reference.dimensions.bytesPerRow
        let c = [UInt8](candidate.bytes), r = [UInt8](reference.bytes)
        let outStride = w * 4
        var out = [UInt8](repeating: 0, count: outStride * h)
        for y in 0..<h {
            var x = 0
            while x < w {
                let cp = y * cStride + x * 4, rp = y * rStride + x * 4, op = y * outStride + x * 4
                // BGRA channel order preserved (input + output are BGRA8). Alpha forced opaque.
                for ch in 0..<3 {
                    let d = abs(Int(c[cp + ch]) - Int(r[rp + ch]))
                    out[op + ch] = UInt8(min(255, d * amp))
                }
                out[op + 3] = 255
                x += 1
            }
        }
        return DiffFrame(bgra8: Data(out), width: w, height: h, bytesPerRow: outStride, amplification: amp)
    }

    /// Encode a diff frame to deterministic PNG bytes.
    public static func encodePNG(_ diff: DiffFrame) throws -> Data {
        try DeterministicPNGEncoder.encodeBGRA8(bytes: diff.bgra8, width: diff.width, height: diff.height, bytesPerRow: diff.bytesPerRow)
    }
}
