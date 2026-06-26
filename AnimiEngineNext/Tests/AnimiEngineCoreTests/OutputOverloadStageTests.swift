import XCTest
@testable import AnimiEngineCore

/// Slice-004 Stage D — production `OutputOverloadStage` (D-213 Candidate A) tests.
///
/// Production implements **Candidate A only** (explicit deterministic hard saturation). These tests
/// pin bit-transparency below threshold, the clamp behavior, `-0.0` preservation, determinism, the
/// fail-closed non-finite policy, and parity with the committed D-213 evidence's representative
/// vectors. No AVFoundation, no device.
final class OutputOverloadStageTests: XCTestCase {

    // Quantization identical to the D-213 benchmark (`Quant.micros`): round-half-up |v| * 1e6.
    private func micros(_ v: Float32) -> Int64 {
        let m = v < 0 ? -v : v
        return Int64((m * 1_000_000 + 0.5).rounded(.down))
    }

    // MARK: - Algorithm identity

    func testAlgorithmIdentityIsStable() {
        XCTAssertEqual(OutputOverloadStage.algorithmIdentity, "d213.hardSaturation.v1")
    }

    // MARK: - Bit-transparency below / at threshold

    func testFiniteBelowThresholdSamplesAreBitIdentical() throws {
        for x: Float32 in [0.0, 0.1, -0.1, 0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 0.999, -0.999] {
            let out = try OutputOverloadStage.process(x)
            XCTAssertEqual(out.bitPattern, x.bitPattern, "\(x) must pass through bit-identically")
        }
    }

    func testPlusOneAndMinusOneUnchanged() throws {
        XCTAssertEqual(try OutputOverloadStage.process(1.0).bitPattern, Float32(1.0).bitPattern)
        XCTAssertEqual(try OutputOverloadStage.process(-1.0).bitPattern, Float32(-1.0).bitPattern)
    }

    func testNegativeZeroBitPatternPreserved() throws {
        let negZero: Float32 = -0.0
        let out = try OutputOverloadStage.process(negZero)
        XCTAssertEqual(out.bitPattern, negZero.bitPattern, "-0.0 bit pattern must be preserved")
        XCTAssertNotEqual(negZero.bitPattern, Float32(0.0).bitPattern, "sanity: -0.0 != +0.0 in bits")

        let posZero: Float32 = 0.0
        XCTAssertEqual(try OutputOverloadStage.process(posZero).bitPattern, posZero.bitPattern)
    }

    // MARK: - Clamp above / below full scale

    func testAboveOneClampsToPlusOne() throws {
        for x: Float32 in [1.0001, 1.25, 1.5, 2.0, 4.0, 8.0, 1_000.0] {
            XCTAssertEqual(try OutputOverloadStage.process(x), 1.0)
        }
    }

    func testBelowMinusOneClampsToMinusOne() throws {
        for x: Float32 in [-1.0001, -1.25, -1.5, -2.0, -4.0, -8.0, -1_000.0] {
            XCTAssertEqual(try OutputOverloadStage.process(x), -1.0)
        }
    }

    // MARK: - Determinism

    func testDeterministicRepeatGivesIdenticalOutput() throws {
        let inputs: [Float32] = [0.0, 0.5, -0.5, 1.0, -1.0, 3.0, -3.0, 0.999, -0.999]
        let first = try inputs.map { try OutputOverloadStage.process($0) }
        let second = try inputs.map { try OutputOverloadStage.process($0) }
        XCTAssertEqual(first.map { $0.bitPattern }, second.map { $0.bitPattern })
    }

    // MARK: - Parity with committed D-213 evidence (representative vectors)

    func testSilenceUnchanged() throws {
        for _ in 0..<16 {
            let out = try OutputOverloadStage.process(0.0)
            XCTAssertEqual(out.bitPattern, Float32(0.0).bitPattern)
            XCTAssertEqual(micros(out), 0)
        }
    }

    func testCorpusToneBelowThresholdUnchanged() throws {
        // corpus tone amplitude is 0.5 (TONE_AMPLITUDE); below full scale → bit-transparent, 500_000 µ.
        let tone: Float32 = 0.5
        let out = try OutputOverloadStage.process(tone)
        XCTAssertEqual(out.bitPattern, tone.bitPattern)
        XCTAssertEqual(micros(out), 500_000)
    }

    func testOverloadPeakClampsToOneMillionMicros() throws {
        // matches the D-213 evidence: Candidate A peakOutMicros == 1_000_000 on overload vectors.
        for x: Float32 in [1.25, -1.25, 2.0, -2.0, 3.0, -3.0, 8.0, -8.0] {
            let out = try OutputOverloadStage.process(x)
            XCTAssertEqual(micros(out), 1_000_000, "overload \(x) must clamp to full scale (1_000_000 µ)")
        }
    }

    func testEvidenceVectorsNeverExceedFullScale() throws {
        // every representative sample maps to |out| <= 1.0 (evidence: exceedsFullScale == false).
        let vectors: [Float32] = [
            0.0, 0.5, -0.5, 0.8, -0.8, 1.0, -1.0,            // below/at threshold
            1.25, -1.25, 1.9, -1.9, 2.7, -2.7, 3.0, 8.0, -8.0, // overload
        ]
        for x in vectors {
            let out = try OutputOverloadStage.process(x)
            XCTAssertLessThanOrEqual(micros(out), 1_000_000, "\(x) produced > full scale")
        }
    }

    // MARK: - Non-finite fail-closed policy

    func testNaNFailsClosed() {
        XCTAssertThrowsError(try OutputOverloadStage.process(Float32.nan)) { error in
            XCTAssertEqual(error as? OutputOverloadStageError, .nonFiniteSample)
        }
        XCTAssertThrowsError(try OutputOverloadStage.process(-Float32.nan)) { error in
            XCTAssertEqual(error as? OutputOverloadStageError, .nonFiniteSample)
        }
        // signaling NaN bit pattern
        XCTAssertThrowsError(try OutputOverloadStage.process(Float32(bitPattern: 0x7FA0_0000))) { error in
            XCTAssertEqual(error as? OutputOverloadStageError, .nonFiniteSample)
        }
    }

    func testPositiveInfinityFailsClosed() {
        XCTAssertThrowsError(try OutputOverloadStage.process(Float32.infinity)) { error in
            XCTAssertEqual(error as? OutputOverloadStageError, .nonFiniteSample)
        }
    }

    func testNegativeInfinityFailsClosed() {
        XCTAssertThrowsError(try OutputOverloadStage.process(-Float32.infinity)) { error in
            XCTAssertEqual(error as? OutputOverloadStageError, .nonFiniteSample)
        }
    }

    func testNonFiniteIsNotSilentlyMappedToFinite() throws {
        // explicit guard against a "map NaN to 0 / Inf to ±1" policy: it MUST throw, not return.
        XCTAssertThrowsError(try OutputOverloadStage.process(.nan))
        XCTAssertThrowsError(try OutputOverloadStage.process(.infinity))
        XCTAssertThrowsError(try OutputOverloadStage.process(-.infinity))
    }

    // MARK: - Sendable

    func testTypeIsSendable() {
        func requireSendable<T: Sendable>(_ type: T.Type) {}
        requireSendable(OutputOverloadStage.self)
        requireSendable(OutputOverloadStageError.self)
    }
}
