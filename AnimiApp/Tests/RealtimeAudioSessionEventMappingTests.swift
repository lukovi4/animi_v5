import XCTest
import AVFoundation
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage A — `RealtimeAudioSessionEventMapping`: app `AudioSessionEvent` → canonical
/// `RealtimeAudioSessionEvent`, pause-only (no auto-resume / restart).
final class RealtimeAudioSessionEventMappingTests: XCTestCase {

    func testInterruptionBeganMapping() throws {
        XCTAssertEqual(try RealtimeAudioSessionEventMapping.map(.interruptionBegan), .interruptionBegan)
    }

    func testInterruptionEndedMappingDropsResumeHint() throws {
        XCTAssertEqual(
            try RealtimeAudioSessionEventMapping.map(.interruptionEnded(shouldResume: true)),
            .interruptionEnded)
        XCTAssertEqual(
            try RealtimeAudioSessionEventMapping.map(.interruptionEnded(shouldResume: false)),
            .interruptionEnded)
    }

    func testOldDeviceUnavailableMapping() throws {
        let event = try RealtimeAudioSessionEventMapping.map(
            .routeChanged(reason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue))
        XCTAssertEqual(event, .routeChanged(.oldDeviceUnavailable))
    }

    // MARK: - newDeviceAvailable → pause-only (NOT restart/resume)

    func testNewDeviceAvailableMapsToPauseOnlyEvent() throws {
        let event = try RealtimeAudioSessionEventMapping.map(
            .routeChanged(reason: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue))
        XCTAssertEqual(event, .newDeviceAvailable)
        // Canonical semantics: this event invalidates audible playback (pause-only), never resumes.
        XCTAssertTrue(event.invalidatesAudiblePlayback)
    }

    func testAllRouteReasonsMapToCanonical() throws {
        let cases: [(AVAudioSession.RouteChangeReason, RealtimeAudioSessionEvent)] = [
            (.newDeviceAvailable, .newDeviceAvailable),
            (.oldDeviceUnavailable, .routeChanged(.oldDeviceUnavailable)),
            (.categoryChange, .routeChanged(.categoryChange)),
            (.override, .routeChanged(.override)),
            (.wakeFromSleep, .routeChanged(.wakeFromSleep)),
            (.noSuitableRouteForCategory, .routeChanged(.noSuitableRouteForCategory)),
            (.routeConfigurationChange, .routeChanged(.routeConfigurationChange)),
            (.unknown, .routeChanged(.unknown)),
        ]
        for (reason, expected) in cases {
            XCTAssertEqual(
                try RealtimeAudioSessionEventMapping.map(.routeChanged(reason: reason.rawValue)),
                expected, "route reason \(reason.rawValue)")
        }
    }

    func testUnrecognisedRawRouteReasonMapsToUnknown() {
        XCTAssertEqual(RealtimeAudioSessionEventMapping.mapRouteChange(99_999), .routeChanged(.unknown))
    }

    func testMediaServicesResetMapsToOutputFormatOrRouteChanged() throws {
        XCTAssertEqual(
            try RealtimeAudioSessionEventMapping.map(.mediaServicesReset), .outputFormatOrRouteChanged)
    }

    func testActivationFailedIsUnmappable() {
        let err = NSError(domain: "test", code: 1)
        XCTAssertThrowsError(try RealtimeAudioSessionEventMapping.map(.activationFailed(err))) { error in
            guard case .unmappableSessionEvent? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected unmappableSessionEvent")
            }
        }
    }

    // MARK: - Structural: no auto-resume / restart symbols introduced

    func testMappingSourceHasNoAutoResumeOrRestartSymbols() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EditorRuntime/Realtime/RealtimeAudioSessionEventMapping.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        // Strip line comments — the doc comment legitimately *documents the absence* of these paths
        // (e.g. "the legacy reprepare+restart is NOT ported"); only executable code is checked.
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
        for banned in ["autoResume", "reprepare", "restartPlayback", "resumeAfterInterruption", "startPlayback"] {
            XCTAssertFalse(code.contains(banned),
                "event mapping code must introduce no \(banned) symbol (pause-only)")
        }
    }
}
