import XCTest
@testable import AnimiEngineNext
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport

/// Evidence-artifact content tests (Task-001 acceptance #5, #6, correction #3).
final class EvidenceArtifactTests: XCTestCase {

    private var parentDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimiEngineNextRun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let parentDir { try? FileManager.default.removeItem(at: parentDir) }
        try super.tearDownWithError()
    }

    /// Builds a run whose generated runID is deterministic. Returns the run; the final run dir is
    /// `parentDir/<runID>` and the staging dir is `parentDir/.<runID>.staging`.
    private func makeRun(runID: String = "run-fixed-001") throws -> BenchmarkRun {
        try BenchmarkRun(
            parentDirectoryURL: parentDir,
            idGenerator: TestIDGenerator(ids: [runID]),
            wallClock: TestWallClock(dates: [
                Date(timeIntervalSince1970: 1_700_000_000),
                Date(timeIntervalSince1970: 1_700_000_005)
            ]),
            monotonicClock: TestMonotonicClock(values: [1_000, 1_500, 2_250])
        )
    }

    private func close(_ run: BenchmarkRun) throws {
        try run.close(
            engineConfiguration: ConfigurationTests.referenceConfiguration(),
            deviceInfo: DeviceInfo(model: "TestModel", systemName: "iOS", systemVersion: "18.0"),
            status: .success
        )
    }

    func testEventsStagingIsPresentMidRunAndFinalRunAbsentUntilPublish() throws {
        let run = try makeRun()
        let stagingEventsURL = run.stagingDirectoryURL.appendingPathComponent(RunArtifact.eventsStaging)
        let finalEventsURL = run.directoryURL.appendingPathComponent(RunArtifact.events.rawValue)

        try run.appendEvent(DiagnosticEvent(
            runID: run.runID,
            elapsedNanoseconds: run.elapsedNanoseconds(),
            subsystem: "test",
            eventType: "started",
            fields: ["k": "v"]
        ))

        // Mid-run: staging events file exists; the FINAL run directory does not exist at all yet.
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingEventsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directoryURL.path),
                       "final run directory must not exist while the run is open")
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalEventsURL.path))

        try close(run)

        // After publish: final run dir present, staging gone.
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalEventsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.stagingDirectoryURL.path),
                       "staging directory must be gone after publish")
    }

    func testAllSixArtifactsWrittenAndManifestCarriesWallClockStatusAndConfigHash() throws {
        let run = try makeRun()
        try run.appendEvent(DiagnosticEvent(
            runID: run.runID,
            elapsedNanoseconds: run.elapsedNanoseconds(),
            subsystem: "decode",
            eventType: "frame",
            fields: ["index": "0"]
        ))
        try close(run)

        for artifact in RunArtifact.allCases {
            let url = run.directoryURL.appendingPathComponent(artifact.rawValue)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "missing artifact \(artifact.rawValue)")
        }

        let manifest = try String(
            contentsOf: run.directoryURL.appendingPathComponent(RunArtifact.runManifest.rawValue),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains("\"status\":\"success\""))
        XCTAssertTrue(manifest.contains("\"startWallClock\""))
        XCTAssertTrue(manifest.contains("\"endWallClock\""))
        XCTAssertTrue(manifest.contains("\"engineConfigSHA256\""))
        XCTAssertTrue(manifest.contains("2023-11-14T22:13:20.000Z"), "manifest: \(manifest)")
    }

    func testEventsAreValidNDJSONWithElapsedMonotonicAndRequiredFields() throws {
        let run = try makeRun()
        try run.appendEvent(DiagnosticEvent(
            runID: run.runID,
            elapsedNanoseconds: run.elapsedNanoseconds(),  // 1_500 - 1_000 = 500
            subsystem: "decode",
            eventType: "frame",
            fields: ["b": "2", "a": "1"]
        ))
        try run.appendEvent(DiagnosticEvent(
            runID: run.runID,
            elapsedNanoseconds: run.elapsedNanoseconds(),  // 2_250 - 1_000 = 1_250
            subsystem: "render",
            eventType: "frame",
            fields: [:]
        ))
        try close(run)

        let text = try String(
            contentsOf: run.directoryURL.appendingPathComponent(RunArtifact.events.rawValue),
            encoding: .utf8
        )
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 2)

        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertNotNil(object?["runID"])
            XCTAssertNotNil(object?["elapsedNanoseconds"])
            XCTAssertNotNil(object?["subsystem"])
            XCTAssertNotNil(object?["eventType"])
            XCTAssertNotNil(object?["fields"])
        }

        XCTAssertTrue(lines[0].contains("\"elapsedNanoseconds\":500"))
        XCTAssertTrue(lines[1].contains("\"elapsedNanoseconds\":1250"))
        XCTAssertTrue(lines[0].contains("\"fields\":{\"a\":\"1\",\"b\":\"2\"}"))
    }
}
