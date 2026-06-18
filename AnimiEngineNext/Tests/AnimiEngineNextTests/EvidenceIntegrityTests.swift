import XCTest
@testable import AnimiEngineNext
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport

/// C-1 — configuration-hash integrity: the manifest records the config SHA-256 and it is verified
/// against the bytes actually written to `engine-config.json` (Revision-5 §2.2/§2.4).
final class EvidenceIntegrityTests: XCTestCase {

    private var parentDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimiEngineNextIntegrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let parentDir { try? FileManager.default.removeItem(at: parentDir) }
        try super.tearDownWithError()
    }

    private func makeRun(fileSystem: RunFileSystem, runID: String = "integrity-001") throws -> BenchmarkRun {
        try BenchmarkRun(
            parentDirectoryURL: parentDir,
            idGenerator: TestIDGenerator(ids: [runID]),
            wallClock: TestWallClock(dates: [Date(timeIntervalSince1970: 1_700_000_000)]),
            monotonicClock: TestMonotonicClock(values: [0, 1]),
            fileSystem: fileSystem
        )
    }

    private func close(_ run: BenchmarkRun) throws {
        try run.close(
            engineConfiguration: ConfigurationTests.referenceConfiguration(),
            deviceInfo: DeviceInfo(model: "M", systemName: "iOS", systemVersion: "18.0"),
            status: .success
        )
    }

    /// T-C1a — read `engine-config.json` back and confirm it re-hashes to the manifest field.
    func testManifestHashMatchesOnDiskEngineConfig() throws {
        let run = try makeRun(fileSystem: DefaultRunFileSystem())
        try close(run)

        let configBytes = try Data(contentsOf: run.directoryURL.appendingPathComponent(RunArtifact.engineConfig.rawValue))
        let onDiskHash = ConfigurationHash.sha256Hex(ofCanonicalBytes: configBytes)

        let manifestData = try Data(contentsOf: run.directoryURL.appendingPathComponent(RunArtifact.runManifest.rawValue))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["engineConfigSHA256"] as? String, onDiskHash)
    }

    /// T-C1b — manifest field equals the canonical hash of the reference configuration.
    func testManifestHashEqualsReferenceConfigHash() throws {
        let run = try makeRun(fileSystem: DefaultRunFileSystem())
        try close(run)

        let manifestData = try Data(contentsOf: run.directoryURL.appendingPathComponent(RunArtifact.runManifest.rawValue))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(
            manifest["engineConfigSHA256"] as? String,
            ConfigurationHash.sha256Hex(of: ConfigurationTests.referenceConfiguration())
        )
    }

    /// T-C1c — a corrupted read-back fails the integrity check; nothing is published.
    func testCorruptedReadBackFailsIntegrityAndPublishesNothing() throws {
        let fs = FaultInjectingRunFileSystem(faults: [
            .init(.corruptReadBack(artifactFileName: RunArtifact.engineConfig.rawValue))
        ])
        let run = try makeRun(fileSystem: fs)

        XCTAssertThrowsError(try close(run)) { error in
            guard case .evidenceIntegrityFailure? = error as? BenchmarkRunError else {
                return XCTFail("expected evidenceIntegrityFailure, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directoryURL.path),
                       "final run must not be published on integrity failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.stagingDirectoryURL.path),
                       "staging must be cleaned up on failure")
        XCTAssertEqual(run.state, .failed)
    }
}
