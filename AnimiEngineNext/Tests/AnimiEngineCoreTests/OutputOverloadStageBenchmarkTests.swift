import XCTest
@testable import AnimiEngineCore

// MARK: - D-213 output-overload-stage benchmark (TEST-ONLY, NO production output stage)
//
// This file is **evidence**, not production. It does NOT add the canonical
// `OutputOverloadStage` (that is Slice-004 Stage D, gated on this very decision).
// It defines the two D-213 candidate algorithms *locally inside the test target*
// and produces deterministic, reproducible comparison evidence:
//
//   A) explicit deterministic HARD SATURATION  — clamp(x, -1, +1)
//   B) fixed deterministic SAFETY LIMITER       — fixed-parameter, lookahead-free,
//      stateless-per-sample soft gain reduction above a fixed threshold.
//
// Both candidates are pure, sample-by-sample, allocation-free, and contain NO
// platform transcendental (no exp/log/pow) so the bytes are identical on any
// machine. `Float`/`Double` are allowed HERE because this is the test target, not
// `Sources/AnimiEngineCore/*` (the production no-Float sweep covers Runtime/Audio
// sources only; Float32 is the DSP-boundary type per ADR-012 §1/§4).
//
// Evidence is committed under `Docs/AnimiEngineNext/evidence/d-213/`. Metrics are
// INTEGER-QUANTIZED (fixed 1e6 scale, round-half-up) before serialization so the
// committed JSON is byte-stable; output PCM is hashed with a test-local SHA-256.
//
// What this proves offline (no device):
//   * determinism: same input → identical output bytes, every run;
//   * preview/export equivalence: the *same* pure function on the *same* input is
//     byte-identical (the canonical stage is one shared function — §4 "identical in
//     preview and export");
//   * A is trivially stateless/branch-only; B is stateless-per-sample by
//     construction (no carried attack/release/lookahead state) — so B is also
//     exactly preview/export-equivalent. A *stateful* limiter would NOT be, and is
//     explicitly excluded by this benchmark (see the doc).
//
// What it CANNOT prove (device-only, deferred): audible quality of A vs B under
// sustained overload, true A/V sync, underrun behavior. Those belong to Slice 004.

// MARK: Candidate algorithms (test-local, deterministic, transcendental-free)

private enum OutputCandidate {

    /// A — explicit deterministic hard saturation. Branch-only clamp to [-1, +1].
    static func hardSaturation(_ x: Float32) -> Float32 {
        if x > 1 { return 1 }
        if x < -1 { return -1 }
        return x
    }

    /// B — fixed deterministic safety limiter (stateless per sample, no lookahead).
    ///
    /// Fixed, versioned parameters. Below `threshold` the signal is unchanged
    /// (unity, bit-transparent). Between `threshold` and the ceiling the *excess*
    /// magnitude is reduced by a fixed rational soft-knee ratio; the result can
    /// never exceed 1.0. This is a *static* curve — no time constants, no carried
    /// state — chosen precisely so the stage stays exactly preview/export-equivalent
    /// and transcendental-free (the limiter shape uses only +, −, ×, ÷).
    ///
    /// Curve (for |x| ≥ threshold, with t = threshold, ratio R):
    ///   excess  = |x| − t
    ///   reduced = excess / (1 + R · excess)        // rational soft knee, →(t + 1/R) asymptote
    ///   |out|   = min(t + reduced, ceiling)         // hard ceiling guarantees ≤ 1.0
    /// Parameters are fixed so the soft-knee ASYMPTOTE (threshold + 1/ratio) sits
    /// strictly below the 1.0 ceiling: 0.75 + 1/8 = 0.875 < 1.0. The limiter therefore
    /// approaches but never reaches full scale, and the hard ceiling is only a
    /// belt-and-braces guard that never actually engages — a genuine limiter, not a
    /// disguised hard clip. (An earlier 0.875/ratio-4 choice had asymptote 1.125 > 1.0,
    /// so its ceiling collapsed B back onto A under heavy overload — caught by the
    /// `testCandidatesDifferUnderOverloadDeterministically` gate.)
    static let limiterThreshold: Float32 = 0.75       // -2.5 dBFS-ish onset
    static let limiterRatio: Float32 = 8.0            // soft-knee strength (rational)
    static let limiterCeiling: Float32 = 1.0          // never reached: asymptote = 0.875

    static func safetyLimiter(_ x: Float32) -> Float32 {
        let sign: Float32 = x < 0 ? -1 : 1
        let mag = x < 0 ? -x : x
        if mag <= limiterThreshold { return x }
        let excess = mag - limiterThreshold
        let reduced = excess / (1 + limiterRatio * excess)
        var outMag = limiterThreshold + reduced
        if outMag > limiterCeiling { outMag = limiterCeiling }
        return sign * outMag
    }
}

// MARK: Deterministic input vectors (corpus-aligned + edge cases)

private struct BenchVector {
    let name: String
    let samples: [Float32]
}

private enum BenchVectors {

    // A fixed 1 kHz-style ramp/tone is unnecessary: the output stage is memoryless,
    // so a representative *amplitude sweep* exercises every branch exactly. We use
    // deterministic, hand-listed sample sets covering the §4 contract surface.

    static func all() -> [BenchVector] {
        [
            // exactly representative magnitudes around the contract boundaries
            BenchVector(name: "below_threshold", samples: [
                0.0, 0.1, -0.1, 0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 0.8, -0.8,
            ]),
            BenchVector(name: "at_unity_exact", samples: [
                1.0, -1.0, 1.0, -1.0,
            ]),
            BenchVector(name: "above_unity_overload", samples: [
                1.25, -1.25, 1.5, -1.5, 2.0, -2.0, 4.0, -4.0, 8.0, -8.0,
            ]),
            BenchVector(name: "repeated_peaks", samples: [
                0.0, 2.0, 0.0, -2.0, 0.0, 2.0, 0.0, -2.0, 0.0, 2.0, 0.0, -2.0,
            ]),
            BenchVector(name: "long_constant_overload", samples:
                Array(repeating: 3.0 as Float32, count: 64)
            ),
            BenchVector(name: "mixed_signs_summed_overload", samples: [
                // emulates multi-source summation (corpus 6/10/20-video stress):
                // several unity tones summed can exceed full scale
                1.4, -1.9, 0.6, -0.3, 2.7, -2.7, 0.95, -0.95, 1.05, -1.05,
            ]),
            BenchVector(name: "transition_overlap_sum", samples: [
                // two overlapping scene tones summed during a transition window
                0.5, 0.9, 1.3, 1.7, 1.9, 1.7, 1.3, 0.9, 0.5, 0.0,
                -0.5, -0.9, -1.3, -1.7, -1.9, -1.7, -1.3, -0.9, -0.5, 0.0,
            ]),
            BenchVector(name: "silence", samples:
                Array(repeating: 0.0 as Float32, count: 16)
            ),
            // corpus tone amplitudes at 44.1/48/96 kHz are all 0.5 (TONE_AMPLITUDE):
            // below threshold → both candidates MUST be bit-transparent.
            BenchVector(name: "corpus_tone_amplitude", samples:
                Array(repeating: 0.5 as Float32, count: 16)
            ),
        ]
    }
}

// MARK: Deterministic integer-quantized metrics

private struct CandidateMetrics: Equatable {
    let name: String
    let outputSHA256: String
    // all magnitudes quantized to fixed 1e6 scale, round-half-up, as Int64
    let peakOutMicros: Int64        // max |out|
    let maxAbsErrorMicros: Int64    // max |out − in| (distortion vs passthrough)
    let clampedSampleCount: Int     // samples whose magnitude was reduced (|out| < |in|)
    let bitTransparentBelow: Bool   // every |in| ≤ threshold passed through unchanged
    let exceedsFullScale: Bool      // any |out| > 1.0 (must be false)
}

private enum Quant {
    static let scale: Float32 = 1_000_000

    /// Round-half-up to integer micros. Deterministic, transcendental-free.
    static func micros(_ v: Float32) -> Int64 {
        let m = v < 0 ? -v : v
        let scaled = m * scale
        // round half up
        return Int64((scaled + 0.5).rounded(.down))
    }
}

// MARK: Test-local SHA-256 (matches the corpus tests' hand-rolled hasher)

private enum SHA256Local {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    static func hex(_ message: [UInt8]) -> String {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var msg = message
        let bitLen = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }

        var chunkStart = 0
        while chunkStart < msg.count {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = chunkStart + i * 4
                w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16)
                    | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            chunkStart += 64
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}

// MARK: Evidence generation

private func bigEndianBytes(_ bits: UInt32) -> [UInt8] {
    [UInt8((bits >> 24) & 0xff), UInt8((bits >> 16) & 0xff),
     UInt8((bits >> 8) & 0xff), UInt8(bits & 0xff)]
}

private func metrics(name: String, input: [Float32], output: [Float32], threshold: Float32) -> CandidateMetrics {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(output.count * 4)
    for s in output { bytes.append(contentsOf: bigEndianBytes(s.bitPattern)) }

    var peak: Int64 = 0
    var maxErr: Int64 = 0
    var clamped = 0
    var transparent = true
    var exceeds = false
    for i in 0..<output.count {
        let inMag = input[i] < 0 ? -input[i] : input[i]
        let outMag = output[i] < 0 ? -output[i] : output[i]
        peak = max(peak, Quant.micros(outMag))
        maxErr = max(maxErr, Quant.micros(output[i] - input[i]))
        if outMag + 1e-7 < inMag { clamped += 1 }
        if inMag <= threshold && output[i] != input[i] { transparent = false }
        if outMag > 1.0 + 1e-7 { exceeds = true }
    }
    return CandidateMetrics(
        name: name,
        outputSHA256: SHA256Local.hex(bytes),
        peakOutMicros: peak,
        maxAbsErrorMicros: maxErr,
        clampedSampleCount: clamped,
        bitTransparentBelow: transparent,
        exceedsFullScale: exceeds
    )
}

private func canonicalJSON(_ vectors: [(vector: String, a: CandidateMetrics, b: CandidateMetrics)]) -> String {
    func obj(_ m: CandidateMetrics) -> String {
        """
        {"bitTransparentBelow":\(m.bitTransparentBelow),"clampedSampleCount":\(m.clampedSampleCount),"exceedsFullScale":\(m.exceedsFullScale),"maxAbsErrorMicros":\(m.maxAbsErrorMicros),"name":"\(m.name)","outputSHA256":"\(m.outputSHA256)","peakOutMicros":\(m.peakOutMicros)}
        """
    }
    var lines: [String] = []
    lines.append("{")
    lines.append("  \"schema\": \"d-213-output-stage-benchmark/v1\",")
    lines.append("  \"candidateA\": \"explicitHardSaturation\",")
    lines.append("  \"candidateB\": \"fixedSafetyLimiter\",")
    lines.append("  \"limiterThresholdMicros\": \(Quant.micros(OutputCandidate.limiterThreshold)),")
    lines.append("  \"limiterRatioMicros\": \(Quant.micros(OutputCandidate.limiterRatio)),")
    lines.append("  \"limiterCeilingMicros\": \(Quant.micros(OutputCandidate.limiterCeiling)),")
    lines.append("  \"vectors\": [")
    for (i, row) in vectors.enumerated() {
        let comma = i == vectors.count - 1 ? "" : ","
        lines.append("    {\"vector\":\"\(row.vector)\",\"A\":\(obj(row.a)),\"B\":\(obj(row.b))}\(comma)")
    }
    lines.append("  ]")
    lines.append("}")
    return lines.joined(separator: "\n") + "\n"
}

// MARK: Tests

final class OutputOverloadStageBenchmarkTests: XCTestCase {

    private func evidenceURL() -> URL {
        // #filePath = .../AnimiEngineNext/Tests/AnimiEngineCoreTests/<thisFile>
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // AnimiEngineCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AnimiEngineNext
            .deletingLastPathComponent()   // repo root
        return repoRoot
            .appendingPathComponent("Docs/AnimiEngineNext/evidence/d-213", isDirectory: true)
            .appendingPathComponent("output-stage-evidence.json")
    }

    private func runAll() -> [(vector: String, a: CandidateMetrics, b: CandidateMetrics)] {
        BenchVectors.all().map { v in
            let outA = v.samples.map(OutputCandidate.hardSaturation)
            let outB = v.samples.map(OutputCandidate.safetyLimiter)
            return (
                vector: v.name,
                a: metrics(name: "A", input: v.samples, output: outA, threshold: 0.0),
                b: metrics(name: "B", input: v.samples, output: outB, threshold: OutputCandidate.limiterThreshold)
            )
        }
    }

    /// Determinism: re-running the candidates on the same inputs yields byte-identical
    /// output hashes and identical metrics every time.
    func testCandidatesAreDeterministic() {
        let first = runAll()
        let second = runAll()
        XCTAssertEqual(first.map { $0.a }, second.map { $0.a })
        XCTAssertEqual(first.map { $0.b }, second.map { $0.b })
    }

    /// Preview/export equivalence (ADR-012 §4): the canonical stage is ONE shared pure
    /// function. We prove that applying the *same* candidate to the same input twice
    /// (the two consumers) is byte-identical — and that neither candidate carries any
    /// cross-call state that could diverge between preview and export.
    func testPreviewExportEquivalenceForBothCandidates() {
        for v in BenchVectors.all() {
            let previewA = v.samples.map(OutputCandidate.hardSaturation)
            let exportA = v.samples.map(OutputCandidate.hardSaturation)
            XCTAssertEqual(previewA, exportA, "A diverged across consumers for \(v.name)")

            let previewB = v.samples.map(OutputCandidate.safetyLimiter)
            let exportB = v.samples.map(OutputCandidate.safetyLimiter)
            XCTAssertEqual(previewB, exportB, "B diverged across consumers for \(v.name)")
        }
    }

    /// Safety contract (ADR-012 §4): neither candidate emits a peak above full scale,
    /// and both are bit-transparent on the corpus tone amplitude (0.5, below threshold).
    func testNeitherCandidateExceedsFullScaleAndBothTransparentBelowThreshold() {
        for row in runAll() {
            XCTAssertFalse(row.a.exceedsFullScale, "A exceeded full scale on \(row.vector)")
            XCTAssertFalse(row.b.exceedsFullScale, "B exceeded full scale on \(row.vector)")
            XCTAssertLessThanOrEqual(row.a.peakOutMicros, 1_000_000, "A peak > 1.0 on \(row.vector)")
            XCTAssertLessThanOrEqual(row.b.peakOutMicros, 1_000_000, "B peak > 1.0 on \(row.vector)")
        }
        // candidate B must be bit-transparent below its threshold (corpus tone @0.5)
        guard let tone = runAll().first(where: { $0.vector == "corpus_tone_amplitude" }) else {
            return XCTFail("missing corpus_tone_amplitude vector")
        }
        XCTAssertTrue(tone.b.bitTransparentBelow, "B not transparent at corpus tone amplitude")
        XCTAssertTrue(tone.a.bitTransparentBelow, "A not transparent at corpus tone amplitude")
        XCTAssertEqual(tone.a.maxAbsErrorMicros, 0, "A must not alter sub-unity samples")
        XCTAssertEqual(tone.b.maxAbsErrorMicros, 0, "B must not alter below-threshold samples")
    }

    /// Distinguishing evidence: under sustained overload, hard saturation distorts more
    /// (larger max error vs passthrough) than the soft limiter — the perceptual trade is
    /// exactly what device evidence must settle. This asserts the NUMERICAL difference
    /// exists and is deterministic, NOT which one "sounds better".
    func testCandidatesDifferUnderOverloadDeterministically() {
        let rows = runAll()
        guard let constant = rows.first(where: { $0.vector == "long_constant_overload" }) else {
            return XCTFail("missing long_constant_overload vector")
        }
        // both clamp every overloaded sample; A's clamped output == 1.0 (max error 2.0),
        // B reduces it below 1.0 (peak < full scale), so peaks differ measurably.
        XCTAssertEqual(constant.a.peakOutMicros, 1_000_000, "A should pin to full scale")
        XCTAssertLessThan(constant.b.peakOutMicros, 1_000_000, "B should sit below full scale")
        XCTAssertNotEqual(constant.a.outputSHA256, constant.b.outputSHA256)
    }

    /// Committed-evidence parity: the generated evidence JSON byte-matches the committed
    /// file. Set ANIMI_REGEN_D213=1 to (re)write it. This is the reproducibility gate —
    /// a clean checkout's committed evidence must equal a fresh deterministic run.
    func testEvidenceMatchesCommittedArtifact() throws {
        let json = canonicalJSON(runAll())
        let url = evidenceURL()

        if ProcessInfo.processInfo.environment["ANIMI_REGEN_D213"] == "1" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.data(using: .utf8)!.write(to: url)
        }

        let committed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(json, committed,
            "regenerated D-213 evidence != committed artifact (run with ANIMI_REGEN_D213=1 to refresh)")
    }
}
