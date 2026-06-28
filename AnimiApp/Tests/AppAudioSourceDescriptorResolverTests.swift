import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage A — `AppAudioSourceDescriptorResolver`: exactly-one descriptor per referenced source.
final class AppAudioSourceDescriptorResolverTests: XCTestCase {

    // MARK: - Fake probe

    private final class FakeProbe: AppAudioSourceDescriptorResolver.Probe {
        var bySource: [String: [AppAudioSourceDescriptorResolver.ProbeResult]] = [:]
        func probe(sourceID: AudioSourceID) throws -> [AppAudioSourceDescriptorResolver.ProbeResult] {
            bySource[sourceID.raw] ?? []
        }
    }

    private func result(
        sampleRate: Int64 = 48_000, channels: Int = 2, durNum: Int64 = 10, durDen: Int64 = 1,
        stream: String = "stream-A"
    ) -> AppAudioSourceDescriptorResolver.ProbeResult {
        .init(sampleRate: sampleRate, channelCount: channels,
              durationNumerator: durNum, durationDenominator: durDen, streamIdentityRaw: stream)
    }

    /// A one-clip manifest referencing exactly one source (built via the bridge so the id is canonical).
    private func oneSourceManifest(asset: AudioAssetRef = .bundled(id: "A")) throws -> AudioManifest {
        try AppAudioManifestBridge.buildManifest(
            items: [.init(index: 0, startUs: 0, durationUs: 1_000_000,
                          payload: AudioPayload(assetRef: asset, sourceDurationUs: 1_000_000,
                                                trimStartUs: 0, trimEndUs: 1_000_000, volume: 1.0, role: .music))],
            includeOriginalFromVideoSlots: false)
    }

    private func soleSourceRaw(_ manifest: AudioManifest) -> String {
        manifest.sources.first!.id.raw
    }

    // MARK: - exactly one accepted

    func testExactlyOneDescriptorAccepted() throws {
        let manifest = try oneSourceManifest()
        let probe = FakeProbe()
        probe.bySource[soleSourceRaw(manifest)] = [result()]
        let descriptors = try AppAudioSourceDescriptorResolver.resolve(manifest: manifest, probe: probe)
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.sourceID.raw, soleSourceRaw(manifest))
    }

    // MARK: - missing rejected

    func testMissingDescriptorRejected() throws {
        let manifest = try oneSourceManifest()
        let probe = FakeProbe() // no entries → empty
        XCTAssertThrowsError(try AppAudioSourceDescriptorResolver.resolve(manifest: manifest, probe: probe)) { error in
            guard case .missingSourceDescriptor? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected missingSourceDescriptor, got \(error)")
            }
        }
    }

    // MARK: - duplicate rejected

    func testDuplicateDescriptorRejected() throws {
        let manifest = try oneSourceManifest()
        let probe = FakeProbe()
        probe.bySource[soleSourceRaw(manifest)] = [result(stream: "s1"), result(stream: "s2")]
        XCTAssertThrowsError(try AppAudioSourceDescriptorResolver.resolve(manifest: manifest, probe: probe)) { error in
            guard case .duplicateSourceDescriptor? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected duplicateSourceDescriptor, got \(error)")
            }
        }
    }

    // MARK: - facts preserved exactly

    func testDescriptorFactsPreservedExactly() throws {
        let manifest = try oneSourceManifest()
        let probe = FakeProbe()
        probe.bySource[soleSourceRaw(manifest)] = [
            result(sampleRate: 44_100, channels: 1, durNum: 7, durDen: 2, stream: "exact-stream")
        ]
        let d = try AppAudioSourceDescriptorResolver.resolve(manifest: manifest, probe: probe).first!
        XCTAssertEqual(d.sampleRate, 44_100)
        XCTAssertEqual(d.channelLayout, .mono)
        XCTAssertEqual(d.streamIdentity.raw, "exact-stream")
        XCTAssertEqual(d.sourceDuration.numerator, 7)
        XCTAssertEqual(d.sourceDuration.denominator, 2)
    }

    func testChannelLayoutMapping() throws {
        XCTAssertEqual(try AppAudioSourceDescriptorResolver.channelLayout(count: 1), .mono)
        XCTAssertEqual(try AppAudioSourceDescriptorResolver.channelLayout(count: 2), .stereo)
        let six = try AppAudioSourceDescriptorResolver.channelLayout(count: 6)
        XCTAssertEqual(six.kind, .discrete)
        XCTAssertEqual(six.channelCount, 6)
        XCTAssertThrowsError(try AppAudioSourceDescriptorResolver.channelLayout(count: 0))
    }

    // MARK: - deterministic order over multiple sources

    func testDescriptorOrderDeterministicBySourceID() throws {
        // Two clips → two distinct sources; resolver returns them sorted by sourceID.
        let manifest = try AppAudioManifestBridge.buildManifest(
            items: [
                .init(index: 0, startUs: 0, durationUs: 1_000_000,
                      payload: AudioPayload(assetRef: .bundled(id: "zzz"), sourceDurationUs: 1_000_000,
                                            trimStartUs: 0, trimEndUs: 1_000_000, volume: 1.0, role: .music)),
                .init(index: 1, startUs: 1_000_000, durationUs: 1_000_000,
                      payload: AudioPayload(assetRef: .bundled(id: "aaa"), sourceDurationUs: 1_000_000,
                                            trimStartUs: 0, trimEndUs: 1_000_000, volume: 1.0, role: .music)),
            ],
            includeOriginalFromVideoSlots: false)
        let probe = FakeProbe()
        for s in manifest.sources { probe.bySource[s.id.raw] = [result(stream: "stream-\(s.id.raw)")] }
        let descriptors = try AppAudioSourceDescriptorResolver.resolve(manifest: manifest, probe: probe)
        let ids = descriptors.map(\.sourceID)
        XCTAssertEqual(ids, ids.sorted(), "descriptors must be ordered by sourceID")
    }
}
