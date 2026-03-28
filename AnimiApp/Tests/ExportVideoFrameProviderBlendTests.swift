import XCTest
@testable import AnimiApp

final class ExportVideoFrameProviderBlendTests: XCTestCase {

    private let dummyURL = URL(fileURLWithPath: "/dev/null")

    private func makeSelection(
        trimStart: Double = 0,
        trimEnd: Double = 10,
        offset: Double = 0
    ) -> VideoSelection {
        VideoSelection(url: dummyURL, trimStart: trimStart, trimEnd: trimEnd, offset: offset)
    }

    // MARK: - Config Default Policy

    func test_config_defaultPolicy_isBlend() {
        let config = ExportVideoFrameProvider.Config(selection: makeSelection())
        XCTAssertEqual(config.resamplingPolicy, .blend)
    }

    func test_config_explicitNearest() {
        let config = ExportVideoFrameProvider.Config(
            selection: makeSelection(),
            resamplingPolicy: .nearest
        )
        XCTAssertEqual(config.resamplingPolicy, .nearest)
    }

    func test_config_explicitBlend() {
        let config = ExportVideoFrameProvider.Config(
            selection: makeSelection(),
            resamplingPolicy: .blend
        )
        XCTAssertEqual(config.resamplingPolicy, .blend)
    }

    // MARK: - ResamplingDecision: .nearest policy

    func test_nearest_alwaysReturnsPrev() {
        let decision = ResamplingDecision.decide(
            policy: .nearest,
            targetSeconds: 0.5,
            lastPTSSeconds: 0.0,
            nextPTSSeconds: 1.0
        )
        XCTAssertEqual(decision, .usePrev)
    }

    // MARK: - ResamplingDecision: exact-prev branch

    func test_blend_exactPrev_withinEpsilon() {
        let epsilon = 1.0 / 600.0
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: 1.0 + epsilon * 0.5,
            lastPTSSeconds: 1.0,
            nextPTSSeconds: 1.0 + 1.0 / 24.0
        )
        XCTAssertEqual(decision, .usePrev)
    }

    func test_blend_exactPrev_atExactTime() {
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: 2.0,
            lastPTSSeconds: 2.0,
            nextPTSSeconds: 2.0 + 1.0 / 24.0
        )
        XCTAssertEqual(decision, .usePrev)
    }

    // MARK: - ResamplingDecision: exact-next branch

    func test_blend_exactNext_withinEpsilon() {
        let epsilon = 1.0 / 600.0
        let nextPTS = 1.0 + 1.0 / 24.0
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: nextPTS - epsilon * 0.5,
            lastPTSSeconds: 1.0,
            nextPTSSeconds: nextPTS
        )
        XCTAssertEqual(decision, .useNext)
    }

    // MARK: - ResamplingDecision: blend branch (upsampling 24→30)

    func test_blend_midpoint_returnsBlendHalf() {
        // 24fps source: samples at 0.0 and 1/24 ≈ 0.04167
        // 30fps output: target at 1/30 ≈ 0.03333 (between samples)
        let lastPTS = 0.0
        let nextPTS = 1.0 / 24.0
        let target = 1.0 / 30.0

        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: target,
            lastPTSSeconds: lastPTS,
            nextPTSSeconds: nextPTS
        )

        // alpha = (1/30 - 0) / (1/24 - 0) = 24/30 = 0.8
        let expectedAlpha = Float(target / nextPTS)
        if case .blend(let alpha) = decision {
            XCTAssertEqual(alpha, expectedAlpha, accuracy: 0.001)
        } else {
            XCTFail("Expected .blend, got \(decision)")
        }
    }

    func test_blend_quarterPoint_returnsCorrectAlpha() {
        let lastPTS = 1.0
        let nextPTS = 2.0
        let target = 1.25

        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: target,
            lastPTSSeconds: lastPTS,
            nextPTSSeconds: nextPTS
        )

        if case .blend(let alpha) = decision {
            XCTAssertEqual(alpha, 0.25, accuracy: 0.001)
        } else {
            XCTFail("Expected .blend, got \(decision)")
        }
    }

    // MARK: - ResamplingDecision: fallback cases

    func test_blend_noLastPTS_returnsPrev() {
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: 0.5,
            lastPTSSeconds: nil,
            nextPTSSeconds: 1.0
        )
        XCTAssertEqual(decision, .usePrev)
    }

    func test_blend_noNextPTS_returnsPrev() {
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: 0.5,
            lastPTSSeconds: 0.0,
            nextPTSSeconds: nil
        )
        XCTAssertEqual(decision, .usePrev)
    }

    func test_blend_zeroSpan_returnsPrev() {
        // lastPTS == nextPTS (degenerate case)
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: 1.0,
            lastPTSSeconds: 1.0,
            nextPTSSeconds: 1.0
        )
        // Both are within epsilon of target → exact prev wins
        XCTAssertEqual(decision, .usePrev)
    }

    // MARK: - ResamplingDecision: 60→30 downsampling scenario

    func test_60to30_exactHit_noBlend() {
        // 60fps source, 30fps output: every output frame matches a source sample exactly
        let sourceFPS = 60.0
        let outputFPS = 30.0

        for i in 0..<30 {
            let outputTime = Double(i) / outputFPS
            let lastPTS = Double(i * 2) / sourceFPS  // every other source frame
            let nextPTS = Double(i * 2 + 1) / sourceFPS

            let decision = ResamplingDecision.decide(
                policy: .blend,
                targetSeconds: outputTime,
                lastPTSSeconds: lastPTS,
                nextPTSSeconds: nextPTS
            )

            // outputTime == lastPTS exactly (i/30 == 2i/60), so should be exact prev
            XCTAssertEqual(decision, .usePrev, "Frame \(i): expected .usePrev for 60→30 exact hit")
        }
    }
}
