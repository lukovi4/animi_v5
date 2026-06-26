import XCTest
@testable import AnimiEngineCore

/// Slice-004 Stage B — `AudioSampleMasterClock` and `MonotonicHostMasterClock` contract tests.
///
/// Both conform to the Slice-3 `MasterClock` protocol, derive canonical `ProjectTime` from an injected
/// deterministic source, freeze the anchor per epoch (no switching inside an epoch), and fail closed.
/// No device, no AVFoundation, no `Date`/`DispatchTime`.
final class AudioMasterClockTests: XCTestCase {

    /// A test-only mutable `Int64` source the `@Sendable` clock closures can capture **by reference**.
    /// Capturing this object (instead of a mutable local `var`) avoids the Swift 6
    /// "reference to captured var … in concurrently-executing code" / "mutated after capture" warnings,
    /// while keeping the tests' meaning: the closure reads the latest `value` on each call.
    private final class TestInt64Provider: @unchecked Sendable {
        var value: Int64
        init(_ value: Int64) { self.value = value }
        func current() -> Int64 { value }
    }

    // MARK: - AudioSampleMasterClock

    func testAudioClockConformsToMasterClock() throws {
        let anchor = try ProjectTime(ticks: 0)
        let clock: MasterClock = AudioSampleMasterClock(anchorProjectTime: anchor) { 0 }
        XCTAssertEqual(clock.anchorProjectTime.ticks, 0)
        XCTAssertEqual(try clock.currentProjectTime().ticks, 0)
    }

    func testAudioClockReturnsAnchorAtSampleZero() throws {
        let anchor = try ProjectTime(ticks: 12_000)
        let clock = AudioSampleMasterClock(anchorProjectTime: anchor) { 0 }
        XCTAssertEqual(try clock.currentProjectTime().ticks, 12_000)
    }

    func testAudioClockDerivesExactProjectTimeFromSampleProvider() throws {
        let anchor = try ProjectTime(ticks: 1_000)
        let provider = TestInt64Provider(0)
        let clock = AudioSampleMasterClock(anchorProjectTime: anchor) { provider.current() }

        provider.value = 48_000 // one second
        XCTAssertEqual(try clock.currentProjectTime().ticks, 1_000 + 240_000)

        provider.value = 100
        XCTAssertEqual(try clock.currentProjectTime().ticks, 1_000 + 500)
    }

    func testAudioClockAnchorIsFrozenPerEpoch() throws {
        // No API mutates the anchor — it is a `let` set once at construction (no clock switch).
        let anchor = try ProjectTime(ticks: 7)
        let clock = AudioSampleMasterClock(anchorProjectTime: anchor) { 999 }
        XCTAssertEqual(clock.anchorProjectTime.ticks, 7)
        XCTAssertEqual(try clock.currentProjectTime().ticks, 7 + 999 * 5)
        // a second read with the same provider value is identical (deterministic, frozen anchor).
        XCTAssertEqual(try clock.currentProjectTime().ticks, 7 + 999 * 5)
    }

    func testAudioClockFailsClosedOnNegativeSampleTime() throws {
        let anchor = try ProjectTime(ticks: 0)
        let clock = AudioSampleMasterClock(anchorProjectTime: anchor) { -1 }
        XCTAssertThrowsError(try clock.currentProjectTime()) { error in
            XCTAssertEqual(
                error as? TimeError,
                .negativeValue(domain: "SampleTimeMapping.sampleCount", value: -1))
        }
    }

    func testAudioClockFailsClosedOnOverflow() throws {
        let anchor = try ProjectTime(ticks: 0)
        let clock = AudioSampleMasterClock(anchorProjectTime: anchor) { Int64.max / 5 + 1 }
        XCTAssertThrowsError(try clock.currentProjectTime()) { error in
            XCTAssertEqual(error as? TimeError, .integerOverflow(operation: "SampleTimeMapping.ticks"))
        }
    }

    // MARK: - MonotonicHostMasterClock

    func testHostClockConformsToMasterClock() throws {
        let anchor = try ProjectTime(ticks: 0)
        let clock: MasterClock = MonotonicHostMasterClock(anchorProjectTime: anchor) { 0 }
        XCTAssertEqual(clock.anchorProjectTime.ticks, 0)
        XCTAssertEqual(try clock.currentProjectTime().ticks, 0)
    }

    func testHostClockReturnsExactInjectedMonotonicProjectTime() throws {
        let anchor = try ProjectTime(ticks: 500)
        let provider = TestInt64Provider(0)
        let clock = MonotonicHostMasterClock(anchorProjectTime: anchor) { provider.current() }

        XCTAssertEqual(try clock.currentProjectTime().ticks, 500)

        provider.value = 240_000 // one second of project ticks
        XCTAssertEqual(try clock.currentProjectTime().ticks, 500 + 240_000)
    }

    func testHostClockAnchorFrozenPerEpoch() throws {
        let anchor = try ProjectTime(ticks: 42)
        let clock = MonotonicHostMasterClock(anchorProjectTime: anchor) { 1_000 }
        XCTAssertEqual(clock.anchorProjectTime.ticks, 42)
        XCTAssertEqual(try clock.currentProjectTime().ticks, 1_042)
    }

    func testHostClockFailsClosedOnNegativeDelta() throws {
        let anchor = try ProjectTime(ticks: 0)
        let clock = MonotonicHostMasterClock(anchorProjectTime: anchor) { -3 }
        XCTAssertThrowsError(try clock.currentProjectTime()) { error in
            XCTAssertEqual(
                error as? TimeError,
                .negativeValue(domain: "MonotonicHostMasterClock.advancedTicks", value: -3))
        }
    }

    func testHostClockFailsClosedOnOverflow() throws {
        let anchor = try ProjectTime(ticks: Int64.max - 1)
        let clock = MonotonicHostMasterClock(anchorProjectTime: anchor) { 5 }
        XCTAssertThrowsError(try clock.currentProjectTime()) { error in
            XCTAssertEqual(error as? TimeError, .integerOverflow(operation: "ProjectTime.add"))
        }
    }

    func testHostClockHasNoAudioDependency() throws {
        // The host clock takes only project ticks — it never references samples or device facts.
        // (Structural: this is a compile-level guarantee; the provider signature is `() -> Int64`.)
        let anchor = try ProjectTime(ticks: 0)
        let clock = MonotonicHostMasterClock(anchorProjectTime: anchor) { 5 }
        XCTAssertEqual(try clock.currentProjectTime().ticks, 5)
    }
}
