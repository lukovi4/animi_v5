import XCTest
@testable import AnimiEngineCore

/// Slice-004 Stage A — contract tests for the device-format & session-adapter boundary.
///
/// Pure protocol/value layer: no AVFoundation, no realtime playback. A deterministic in-test fake
/// conforms to `AudioSessionAdapter` and exercises the activation-before-query ordering and the
/// fail-closed inactive state. A scoped sweep asserts the new `Realtime/` Stage-A sources import no
/// audio framework and use no floating-point for canonical values.
final class AudioSessionAdapterContractTests: XCTestCase {

    // MARK: - Deterministic fake adapter (no AVFoundation)

    /// A class so `activate()`/`deactivate()`/state mutation are simple and `Sendable`-checked via the
    /// protocol. Holds a fixed `AudioOutputQuery` it returns only while active.
    private final class FakeSessionAdapter: AudioSessionAdapter, @unchecked Sendable {
        private(set) var isActive: Bool = false
        private let queryResult: AudioOutputQuery
        var activateCallCount = 0
        var deactivateCallCount = 0

        init(queryResult: AudioOutputQuery) {
            self.queryResult = queryResult
        }

        func activate() throws {
            activateCallCount += 1
            isActive = true
        }

        func deactivate() throws {
            deactivateCallCount += 1
            isActive = false
        }

        func queryActualOutput() throws -> AudioOutputQuery {
            guard isActive else {
                // Distinguish never-activated from deactivated for honest fail-closed semantics.
                if activateCallCount == 0 {
                    throw RealtimeAudioBoundaryError.queryBeforeActivation
                }
                throw RealtimeAudioBoundaryError.queryWhileInactive
            }
            return queryResult
        }
    }

    private func makeQuery(
        sampleRate: Int64 = 48_000,
        layout: AudioChannelLayoutDescriptor = .stereo,
        route: String = "built-in-speaker"
    ) throws -> AudioOutputQuery {
        let format = try AudioOutputFormat(sampleRate: sampleRate, channelLayout: layout)
        let r = try AudioOutputRoute(identifier: route)
        return AudioOutputQuery(format: format, route: r)
    }

    // MARK: - AudioOutputFormat value contract

    func testOutputFormatAcceptsValid48kStereoAndPreservesExactIntegers() throws {
        let format = try AudioOutputFormat(sampleRate: 48_000, channelLayout: .stereo)
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.channelLayout, .stereo)
        XCTAssertEqual(format.channelLayout.channelCount, 2)
    }

    func testOutputFormatPreservesNonDefaultDeviceRateExactly() throws {
        // device may report a non-48k rate; the value stores it verbatim, no Double, no rounding.
        let format = try AudioOutputFormat(sampleRate: 44_100, channelLayout: .stereo)
        XCTAssertEqual(format.sampleRate, 44_100)
    }

    func testOutputFormatRejectsZeroSampleRate() {
        XCTAssertThrowsError(try AudioOutputFormat(sampleRate: 0, channelLayout: .stereo)) { error in
            XCTAssertEqual(error as? RealtimeAudioBoundaryError, .invalidOutputSampleRate(0))
        }
    }

    func testOutputFormatRejectsNegativeSampleRate() {
        XCTAssertThrowsError(try AudioOutputFormat(sampleRate: -48_000, channelLayout: .stereo)) { error in
            XCTAssertEqual(error as? RealtimeAudioBoundaryError, .invalidOutputSampleRate(-48_000))
        }
    }

    func testOutputFormatSupportsMonoStereoAndDiscreteLayouts() throws {
        let mono = try AudioOutputFormat(sampleRate: 48_000, channelLayout: .mono)
        XCTAssertEqual(mono.channelLayout.channelCount, 1)

        let stereo = try AudioOutputFormat(sampleRate: 48_000, channelLayout: .stereo)
        XCTAssertEqual(stereo.channelLayout.channelCount, 2)

        let discrete = try AudioOutputFormat(
            sampleRate: 48_000, channelLayout: try .discrete(count: 6))
        XCTAssertEqual(discrete.channelLayout.channelCount, 6)
        XCTAssertEqual(discrete.channelLayout.kind, .discrete)
    }

    func testDiscreteLayoutStillRejectsNonPositiveCountThroughExistingDescriptor() {
        XCTAssertThrowsError(try AudioChannelLayoutDescriptor.discrete(count: 0))
    }

    // MARK: - AudioOutputRoute value contract

    func testOutputRouteRejectsEmptyIdentifier() {
        XCTAssertThrowsError(try AudioOutputRoute(identifier: "")) { error in
            XCTAssertEqual(error as? RealtimeAudioBoundaryError, .invalidOutputRoute)
        }
    }

    func testOutputRoutePreservesIdentifier() throws {
        let route = try AudioOutputRoute(identifier: "bluetooth-a2dp")
        XCTAssertEqual(route.identifier, "bluetooth-a2dp")
    }

    // MARK: - Equatable / Sendable value semantics

    func testValueTypesAreEquatable() throws {
        let a = try makeQuery()
        let b = try makeQuery()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.format, b.format)
        XCTAssertEqual(a.route, b.route)

        let differentRate = try AudioOutputFormat(sampleRate: 44_100, channelLayout: .stereo)
        XCTAssertNotEqual(a.format, differentRate)

        let differentRoute = try AudioOutputRoute(identifier: "headphones")
        XCTAssertNotEqual(a.route, differentRoute)
    }

    func testValueTypesAreSendable() {
        // Compile-time assertion: these would fail to build if the types were not `Sendable`.
        func requireSendable<T: Sendable>(_ type: T.Type) {}
        requireSendable(AudioOutputFormat.self)
        requireSendable(AudioOutputRoute.self)
        requireSendable(AudioOutputQuery.self)
        requireSendable(AudioChannelLayoutDescriptor.self)
    }

    // MARK: - Adapter activation-before-query ordering

    func testQueryBeforeActivationIsTypedFailure() throws {
        let adapter = FakeSessionAdapter(queryResult: try makeQuery())
        XCTAssertFalse(adapter.isActive)
        XCTAssertThrowsError(try adapter.queryActualOutput()) { error in
            XCTAssertEqual(error as? RealtimeAudioBoundaryError, .queryBeforeActivation)
        }
    }

    func testQueryAfterActivationReturnsActualOutput() throws {
        let expected = try makeQuery(sampleRate: 48_000, layout: .stereo, route: "built-in-speaker")
        let adapter = FakeSessionAdapter(queryResult: expected)
        try adapter.activate()
        XCTAssertTrue(adapter.isActive)
        let queried = try adapter.queryActualOutput()
        XCTAssertEqual(queried, expected)
        XCTAssertEqual(queried.format.sampleRate, 48_000)
        XCTAssertEqual(queried.route.identifier, "built-in-speaker")
    }

    // MARK: - Deactivate returns to inactive / fail-closed state

    func testDeactivateReturnsToInactiveFailClosedState() throws {
        let adapter = FakeSessionAdapter(queryResult: try makeQuery())
        try adapter.activate()
        XCTAssertNoThrow(try adapter.queryActualOutput())

        try adapter.deactivate()
        XCTAssertFalse(adapter.isActive)
        XCTAssertThrowsError(try adapter.queryActualOutput()) { error in
            XCTAssertEqual(error as? RealtimeAudioBoundaryError, .queryWhileInactive)
        }
    }

    func testReactivationAfterDeactivateRestoresQuery() throws {
        let adapter = FakeSessionAdapter(queryResult: try makeQuery())
        try adapter.activate()
        try adapter.deactivate()
        XCTAssertThrowsError(try adapter.queryActualOutput())

        try adapter.activate()
        XCTAssertTrue(adapter.isActive)
        XCTAssertNoThrow(try adapter.queryActualOutput())
        XCTAssertEqual(adapter.activateCallCount, 2)
        XCTAssertEqual(adapter.deactivateCallCount, 1)
    }

    // MARK: - Stage-A Realtime sweep: no AVFoundation, no Float/Double/Decimal

    func testStageARealtimeSourcesHaveNoAVFoundationOrFloatingPoint() throws {
        // #filePath = .../AnimiEngineNext/Tests/AnimiEngineCoreTests/AudioSessionAdapterContractTests.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile
            .deletingLastPathComponent()   // AnimiEngineCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AnimiEngineNext (package root)
        let realtimeDir = packageRoot
            .appendingPathComponent("Sources/AnimiEngineCore/Realtime", isDirectory: true)

        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: realtimeDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Realtime/*.swift found at \(realtimeDir.path)")

        // Stage-A…E files that MUST be covered by this sweep.
        let coveredNames = Set(files.map { $0.lastPathComponent })
        for required in [
            "AudioOutputFormat.swift", "AudioSessionAdapter.swift",          // Stage A
            "SampleTimeMapping.swift", "AudioSampleMasterClock.swift",        // Stage B
            "MonotonicHostMasterClock.swift",                                 // Stage B
            "PreparedAudioBuffer.swift", "AudioChunkPreparer.swift",          // Stage C
            "OutputOverloadStage.swift",                                      // Stage D (DSP boundary)
            "PreviewAudioGraph.swift", "RealtimeSafeState.swift",            // Stage E
        ] {
            XCTAssertTrue(coveredNames.contains(required), "sweep does not cover Realtime/\(required)")
        }

        // Narrow per-file allowances (everything else stays fully forbidden):
        //   • `OutputOverloadStage.swift` — the DSP boundary: `Float32` allowed.
        //   • `PreviewAudioGraph.swift`   — the AV boundary: AV imports, `Float32` (PCM bridge), and
        //     `Double` (local AVAudioFormat sample-rate bridge) allowed.
        //   • All other Realtime files    — no AV import, no `Float`/`Double`/`Decimal`.
        // In NO file is bare `Float`, `Float64`, or `Decimal` allowed.
        let dspBoundaryFile = "OutputOverloadStage.swift"
        let avBoundaryFile = "PreviewAudioGraph.swift"
        for file in files {
            let name = file.lastPathComponent
            let raw = try String(contentsOf: file, encoding: .utf8)
            let isDSPBoundary = name == dspBoundaryFile
            let isAVBoundary = name == avBoundaryFile
            let floatAllowed = isDSPBoundary || isAVBoundary   // Float32 only
            let doubleAllowed = isAVBoundary                   // AVAudioFormat sample-rate bridge only
            let avAllowed = isAVBoundary

            // `Decimal` and `Float64` are forbidden everywhere, no exceptions.
            for banned in ["Decimal", "Float64"] {
                XCTAssertFalse(raw.contains(banned), "\(name) must not reference \(banned)")
            }
            // AV imports allowed ONLY in the AV boundary file.
            if !avAllowed {
                for banned in ["import AVFoundation", "import AVFAudio"] {
                    XCTAssertFalse(raw.contains(banned), "\(name) must not \(banned)")
                }
            }
            // `Double` allowed ONLY in the AV boundary file (local sample-rate bridge).
            if !doubleAllowed {
                XCTAssertFalse(raw.contains("Double"), "\(name) must not reference Double")
            }
            // `Float` ban: only `Float32` may survive, and only in the DSP/AV boundary files. Strip
            // `Float32` where allowed, then ANY remaining `Float` (bare `Float`/`Float64`) is a fault.
            let floatScan = floatAllowed ? raw.replacingOccurrences(of: "Float32", with: "") : raw
            XCTAssertFalse(
                floatScan.contains("Float"),
                floatAllowed
                    ? "\(name) may use Float32 only — no bare Float / Float64"
                    : "\(name) must not reference Float (value/protocol only)")
        }
    }
}
