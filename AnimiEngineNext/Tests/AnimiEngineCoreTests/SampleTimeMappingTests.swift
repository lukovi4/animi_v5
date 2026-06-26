import XCTest
@testable import AnimiEngineCore

/// Slice-004 Stage B — exact 48 kHz sample-time → canonical project-time mapping tests.
///
/// Pure integer math: sample `N` is exactly tick `5N` (ADR-006 §4), anchored to an epoch project
/// start. Fail-closed on negative sample time and on overflow. No device, no AVFoundation.
final class SampleTimeMappingTests: XCTestCase {

    // MARK: - The canonical constant

    func testFiveTicksPerSampleMatchesGrid() {
        XCTAssertEqual(SampleTimeMapping.ticksPerSample, 5)
        XCTAssertEqual(SampleTimeMapping.ticksPerSample, AudioSampleGrid.ticksPerSample)
    }

    // MARK: - sample → tick duration

    func testZeroSamplesIsZeroTicks() throws {
        let d = try SampleTimeMapping.ticks(forSampleCount: 0)
        XCTAssertEqual(d.ticks, 0)
    }

    func testSampleCountMapsToFiveTimesTicks() throws {
        XCTAssertEqual(try SampleTimeMapping.ticks(forSampleCount: 1).ticks, 5)
        XCTAssertEqual(try SampleTimeMapping.ticks(forSampleCount: 48_000).ticks, 240_000) // 1 second
        XCTAssertEqual(try SampleTimeMapping.ticks(forSampleCount: 7).ticks, 35)
    }

    func testNegativeSampleCountRejectedTyped() {
        XCTAssertThrowsError(try SampleTimeMapping.ticks(forSampleCount: -1)) { error in
            XCTAssertEqual(
                error as? TimeError,
                .negativeValue(domain: "SampleTimeMapping.sampleCount", value: -1))
        }
    }

    func testTickProductOverflowRejectedTyped() {
        // sampleCount * 5 overflows Int64.
        let huge = Int64.max / 5 + 1
        XCTAssertThrowsError(try SampleTimeMapping.ticks(forSampleCount: huge)) { error in
            XCTAssertEqual(error as? TimeError, .integerOverflow(operation: "SampleTimeMapping.ticks"))
        }
    }

    // MARK: - anchored projectTime mapping

    func testSampleZeroMapsToAnchor() throws {
        let anchor = try ProjectTime(ticks: 0)
        let t = try SampleTimeMapping.projectTime(anchor: anchor, sampleTime: 0)
        XCTAssertEqual(t.ticks, 0)
    }

    func testSampleNMapsToAnchorPlusFiveN() throws {
        let anchor = try ProjectTime(ticks: 0)
        let t = try SampleTimeMapping.projectTime(anchor: anchor, sampleTime: 100)
        XCTAssertEqual(t.ticks, 500)
    }

    func testNonZeroAnchorWorks() throws {
        let anchor = try ProjectTime(ticks: 1_000)
        let atZero = try SampleTimeMapping.projectTime(anchor: anchor, sampleTime: 0)
        XCTAssertEqual(atZero.ticks, 1_000, "sample 0 maps to the anchor exactly")

        let atN = try SampleTimeMapping.projectTime(anchor: anchor, sampleTime: 200)
        XCTAssertEqual(atN.ticks, 1_000 + 200 * 5)
    }

    func testNegativeSampleTimeRejectedTyped() throws {
        let anchor = try ProjectTime(ticks: 0)
        XCTAssertThrowsError(try SampleTimeMapping.projectTime(anchor: anchor, sampleTime: -5)) { error in
            XCTAssertEqual(
                error as? TimeError,
                .negativeValue(domain: "SampleTimeMapping.sampleCount", value: -5))
        }
    }

    func testLargeSafeSampleMapsCorrectly() throws {
        let anchor = try ProjectTime(ticks: 0)
        // a large but safe sample count: 1 hour at 48 kHz = 172_800_000 samples → 864_000_000 ticks.
        let oneHourSamples: Int64 = 48_000 * 60 * 60
        let t = try SampleTimeMapping.projectTime(anchor: anchor, sampleTime: oneHourSamples)
        XCTAssertEqual(t.ticks, oneHourSamples * 5)
        XCTAssertEqual(t.ticks, 864_000_000)
    }

    func testAnchorAddOverflowRejectedTyped() throws {
        // product is fine, but anchor + product overflows.
        let anchor = try ProjectTime(ticks: Int64.max - 4)
        XCTAssertThrowsError(try SampleTimeMapping.projectTime(anchor: anchor, sampleTime: 1)) { error in
            // 1 sample = 5 ticks; (Int64.max - 4) + 5 overflows.
            XCTAssertEqual(error as? TimeError, .integerOverflow(operation: "ProjectTime.add"))
        }
    }
}
