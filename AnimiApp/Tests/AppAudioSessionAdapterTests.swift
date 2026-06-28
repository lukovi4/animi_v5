import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage A — `AppAudioSessionAdapter`: activate → query actual output, fail-closed.
final class AppAudioSessionAdapterTests: XCTestCase {

    // MARK: - Fake probe

    private final class FakeProbe: AppAudioSessionAdapter.OutputProbe {
        var output: AppAudioSessionAdapter.RawOutput
        private(set) var isActive = false
        var activateError: Error?
        init(output: AppAudioSessionAdapter.RawOutput) { self.output = output }
        func activate() throws { if let e = activateError { throw e }; isActive = true }
        func deactivate() throws { isActive = false }
        func currentOutput() throws -> AppAudioSessionAdapter.RawOutput { output }
    }

    private func raw(sr: Double = 48_000, ch: Int = 2, route: String = "speaker")
        -> AppAudioSessionAdapter.RawOutput {
        .init(sampleRate: sr, channelCount: ch, routeIdentifier: route)
    }

    // MARK: - query before activation rejects

    func testQueryBeforeActivationRejects() {
        let adapter = AppAudioSessionAdapter(probe: FakeProbe(output: raw()))
        XCTAssertThrowsError(try adapter.queryActualOutput()) { error in
            XCTAssertEqual(error as? AppRealtimeAudioIntegrationError, .queryBeforeActivation)
        }
    }

    // MARK: - activate then query returns actual output

    func testActivateThenQueryReturnsActualOutput() throws {
        let adapter = AppAudioSessionAdapter(probe: FakeProbe(output: raw(sr: 48_000, ch: 2, route: "built-in-speaker")))
        try adapter.activate()
        let q = try adapter.queryActualOutput()
        XCTAssertEqual(q.format.sampleRate, 48_000)
        XCTAssertEqual(q.format.channelLayout, .stereo)
        XCTAssertEqual(q.route.identifier, "built-in-speaker")
    }

    // MARK: - deactivate then query rejects

    func testDeactivateThenQueryRejects() throws {
        let adapter = AppAudioSessionAdapter(probe: FakeProbe(output: raw()))
        try adapter.activate()
        try adapter.deactivate()
        XCTAssertThrowsError(try adapter.queryActualOutput()) { error in
            XCTAssertEqual(error as? AppRealtimeAudioIntegrationError, .queryBeforeActivation)
        }
    }

    // MARK: - invalid sample rate / route reject

    func testInvalidSampleRateRejects() throws {
        for badSR: Double in [0, -48_000, 48_000.5, .nan, .infinity] {
            let adapter = AppAudioSessionAdapter(probe: FakeProbe(output: raw(sr: badSR)))
            try adapter.activate()
            XCTAssertThrowsError(try adapter.queryActualOutput(), "sr \(badSR) must reject") { error in
                // Assert the case (NaN != NaN, so an equality check on the payload is unreliable).
                guard case .invalidOutputSampleRate? = error as? AppRealtimeAudioIntegrationError else {
                    return XCTFail("expected invalidOutputSampleRate for \(badSR), got \(error)")
                }
            }
        }
    }

    func testEmptyRouteRejects() throws {
        let adapter = AppAudioSessionAdapter(probe: FakeProbe(output: raw(route: "")))
        try adapter.activate()
        XCTAssertThrowsError(try adapter.queryActualOutput()) { error in
            XCTAssertEqual(error as? AppRealtimeAudioIntegrationError, .emptyOutputRoute)
        }
    }

    // MARK: - mono / stereo / discrete layout mapping

    func testChannelLayoutMappingMonoStereoDiscrete() throws {
        let mono = AppAudioSessionAdapter(probe: FakeProbe(output: raw(ch: 1)))
        try mono.activate()
        XCTAssertEqual(try mono.queryActualOutput().format.channelLayout, .mono)

        let stereo = AppAudioSessionAdapter(probe: FakeProbe(output: raw(ch: 2)))
        try stereo.activate()
        XCTAssertEqual(try stereo.queryActualOutput().format.channelLayout, .stereo)

        let discrete = AppAudioSessionAdapter(probe: FakeProbe(output: raw(ch: 6)))
        try discrete.activate()
        let layout = try discrete.queryActualOutput().format.channelLayout
        XCTAssertEqual(layout.kind, .discrete)
        XCTAssertEqual(layout.channelCount, 6)

        let zero = AppAudioSessionAdapter(probe: FakeProbe(output: raw(ch: 0)))
        try zero.activate()
        XCTAssertThrowsError(try zero.queryActualOutput()) { error in
            XCTAssertEqual(error as? AppRealtimeAudioIntegrationError, .invalidChannelCount(0))
        }
    }
}
