import XCTest
@testable import AnimiEngineCore

/// Slice 001 Stage B — exact 48 kHz tick↔sample mapping tests (plan §3.6, §8, §9). No `Float`/`Double`.
final class AudioSampleMappingTests: XCTestCase {

    private func range(_ startTick: Int64, _ endTick: Int64) throws -> ProjectTimeRange {
        try ProjectTimeRange(start: try ProjectTime(ticks: startTick), end: try ProjectTime(ticks: endTick))
    }

    func testFiveTicksPerSample() {
        XCTAssertEqual(TickClock.ticksPerSecond / AudioSampleGrid.samplesPerSecond, 5)
        XCTAssertEqual(AudioSampleGrid.ticksPerSample, 5)
        XCTAssertEqual(AudioSampleGrid.samplesPerSecond, 48_000)
    }

    func testExactBoundariesMultiplesOfFive() throws {
        // [0, 240000) ticks → [0, 48000) samples (one second).
        let r = try AudioSampleRange.from(projectTicks: try range(0, 240_000))
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, 48_000)
        XCTAssertEqual(r.sampleCount, 48_000)
        XCTAssertFalse(r.isEmpty)
    }

    func testNonMultipleOfFiveCeil() throws {
        // ceilDiv5(1) == 1, ceilDiv5(7) == 2  → [1, 7) → [1, 2).
        let r = try AudioSampleRange.from(projectTicks: try range(1, 7))
        XCTAssertEqual(r.start, 1)
        XCTAssertEqual(r.end, 2)
        XCTAssertEqual(r.sampleCount, 1)
    }

    func testEmptySampleRangeAccepted() throws {
        // [1, 4) ticks: ceilDiv5(1) == 1, ceilDiv5(4) == 1 → empty [1, 1), zero samples, no throw.
        let r = try AudioSampleRange.from(projectTicks: try range(1, 4))
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.start, r.end)
        XCTAssertEqual(r.sampleCount, 0)
    }

    func testCeilDiv5DirectValues() throws {
        XCTAssertEqual(try AudioSampleGrid.ceilDiv5(0), 0)
        XCTAssertEqual(try AudioSampleGrid.ceilDiv5(5), 1)
        XCTAssertEqual(try AudioSampleGrid.ceilDiv5(6), 2)
        XCTAssertEqual(try AudioSampleGrid.ceilDiv5(9), 2)
        XCTAssertEqual(try AudioSampleGrid.ceilDiv5(10), 2)
    }

    func testNegativeTickRejected() {
        XCTAssertThrowsError(try AudioSampleGrid.ceilDiv5(-1)) { error in
            guard case TimeError.negativeValue(let domain, let value) = error else {
                return XCTFail("expected negativeValue, got \(error)")
            }
            XCTAssertEqual(domain, "AudioSampleGrid.ceilDiv5")
            XCTAssertEqual(value, -1)
        }
    }

    func testInt64MaxExactSafeResult() throws {
        // ceilDiv5(Int64.max): Int64.max == 9_223_372_036_854_775_807, % 5 == 2 (not 0), so +1.
        // floor(Int64.max/5) == 1_844_674_407_370_955_161; +1 == 1_844_674_407_370_955_162 < Int64.max.
        // The +1 cannot overflow; the result is exact and the call must NOT throw.
        let result = try AudioSampleGrid.ceilDiv5(Int64.max)
        XCTAssertEqual(result, 1_844_674_407_370_955_162)
    }

    func testEndBeforeStartRejectedUpstream() {
        // An inverted range can never reach `from(projectTicks:)`: `ProjectTimeRange` forbids
        // `end <= start` at construction, and `ceilDiv5` is monotonic, so a valid range always yields
        // `end >= start`. The inverted case is therefore blocked upstream — assert that gate here.
        XCTAssertThrowsError(try ProjectTimeRange(
            start: try ProjectTime(ticks: 10), end: try ProjectTime(ticks: 5)
        )) { error in
            guard case TimeError.invalidRange = error else {
                return XCTFail("expected invalidRange, got \(error)")
            }
        }
    }

    func testForwardRangeNeverInverts() throws {
        // The half-open mapping never produces end < start for any forward input (monotonic ceilDiv5).
        for (s, e) in [(0, 5), (1, 4), (2, 13), (7, 240_000), (3, 8)] {
            let r = try AudioSampleRange.from(projectTicks: try range(Int64(s), Int64(e)))
            XCTAssertGreaterThanOrEqual(r.end, r.start, "[\(s),\(e)) inverted")
            XCTAssertGreaterThanOrEqual(r.sampleCount, 0)
        }
    }
}
