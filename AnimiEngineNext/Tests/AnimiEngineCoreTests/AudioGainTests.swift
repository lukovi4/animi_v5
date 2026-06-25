import XCTest
@testable import AnimiEngineCore

/// Slice 001 Stage B — integer audio gain tests (plan §3.3, §9). No `Float`/`Double`; no clamp.
final class AudioGainTests: XCTestCase {

    func testBoundariesAccepted() throws {
        XCTAssertEqual(try AudioGain(raw: 0).raw, 0)
        XCTAssertEqual(try AudioGain(raw: 1_000_000).raw, 1_000_000)
        XCTAssertEqual(try AudioGain(raw: 500_000).raw, 500_000)
    }

    func testOutOfRangeRejectedNoClamp() {
        // -1 and 1_000_001 are rejected with the raw value preserved in the error (never coerced).
        XCTAssertThrowsError(try AudioGain(raw: -1)) {
            XCTAssertEqual($0 as? ProjectValidationError, .invalidAudioGain(value: -1))
        }
        XCTAssertThrowsError(try AudioGain(raw: 1_000_001)) {
            XCTAssertEqual($0 as? ProjectValidationError, .invalidAudioGain(value: 1_000_001))
        }
    }

    func testStaticConstants() {
        XCTAssertEqual(AudioGain.unity.raw, 1_000_000)
        XCTAssertEqual(AudioGain.silent.raw, 0)
        XCTAssertEqual(AudioGain.unityRaw, 1_000_000)
    }

    func testComparable() throws {
        XCTAssertTrue(try AudioGain(raw: 1) < AudioGain(raw: 2))
        XCTAssertEqual(AudioGain.silent < AudioGain.unity, true)
    }
}
