import XCTest
@testable import AnimiEngineNext
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport

/// C-4 — `runID` comes from the injected `IDGenerator`; unsafe runIDs are rejected (amendment 2).
final class RunIDGenerationTests: XCTestCase {

    private var parentDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimiEngineNextGen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let parentDir { try? FileManager.default.removeItem(at: parentDir) }
        try super.tearDownWithError()
    }

    private func run(ids: [String]) -> TestIDGenerator { TestIDGenerator(ids: ids) }

    private func makeRun(generator: IDGenerator) throws -> BenchmarkRun {
        try BenchmarkRun(
            parentDirectoryURL: parentDir,
            idGenerator: generator,
            wallClock: TestWallClock(dates: [Date(timeIntervalSince1970: 1_700_000_000)]),
            monotonicClock: TestMonotonicClock(values: [0, 1, 2])
        )
    }

    func testRunIDComesFromInjectedGenerator() throws {
        let r = try makeRun(generator: run(ids: ["run-A", "run-B"]))
        XCTAssertEqual(r.runID.rawValue, "run-A")
        XCTAssertEqual(r.directoryURL.lastPathComponent, "run-A")
        XCTAssertEqual(r.stagingDirectoryURL.lastPathComponent, ".run-A.staging")
    }

    func testSequentialRunsConsumeSuccessiveScriptedIDs() throws {
        let generator = run(ids: ["run-A", "run-B"])
        let first = try makeRun(generator: generator)
        let second = try makeRun(generator: generator)
        XCTAssertEqual(first.runID.rawValue, "run-A")
        XCTAssertEqual(second.runID.rawValue, "run-B")
    }

    func testGeneratedIDAppearsInPublishedArtifacts() throws {
        let r = try makeRun(generator: run(ids: ["run-evidence"]))
        try r.appendEvent(DiagnosticEvent(
            runID: r.runID, elapsedNanoseconds: r.elapsedNanoseconds(),
            subsystem: "s", eventType: "e", fields: [:]
        ))
        try r.close(
            engineConfiguration: ConfigurationTests.referenceConfiguration(),
            deviceInfo: DeviceInfo(model: "M", systemName: "iOS", systemVersion: "18.0"),
            status: .success
        )
        let manifest = try String(contentsOf: r.directoryURL.appendingPathComponent(RunArtifact.runManifest.rawValue), encoding: .utf8)
        let summary = try String(contentsOf: r.directoryURL.appendingPathComponent(RunArtifact.summary.rawValue), encoding: .utf8)
        let events = try String(contentsOf: r.directoryURL.appendingPathComponent(RunArtifact.events.rawValue), encoding: .utf8)
        XCTAssertTrue(manifest.contains("\"runID\":\"run-evidence\""))
        XCTAssertTrue(summary.contains("\"runID\":\"run-evidence\""))
        XCTAssertTrue(events.contains("\"runID\":\"run-evidence\""))
    }

    func testUnsafeRunIDsAreRejectedAndNothingIsCreated() throws {
        let unsafe = ["", "..", ".", "a/b", ".hidden", "a\\b", "has space", "tab\tinside"]
        for value in unsafe {
            XCTAssertThrowsError(try makeRun(generator: run(ids: [value]))) { error in
                guard case .unsafeRunID? = error as? BenchmarkRunError else {
                    return XCTFail("expected unsafeRunID for \(value.debugDescription), got \(error)")
                }
            }
        }
        // Parent dir should contain no staging/final dirs from the rejected attempts.
        let contents = try FileManager.default.contentsOfDirectory(atPath: parentDir.path)
        XCTAssertTrue(contents.isEmpty, "no directories should be created for unsafe runIDs; found \(contents)")
    }

    func testRunIDAtMaxLengthIsAccepted() throws {
        let maxID = String(repeating: "a", count: 128)
        let r = try makeRun(generator: run(ids: [maxID]))
        XCTAssertEqual(r.runID.rawValue.count, 128)
    }

    func testRunIDOverMaxLengthIsRejected() throws {
        let tooLong = String(repeating: "a", count: 129)
        XCTAssertThrowsError(try makeRun(generator: run(ids: [tooLong]))) { error in
            guard case .unsafeRunID? = error as? BenchmarkRunError else {
                return XCTFail("expected unsafeRunID, got \(error)")
            }
        }
    }
}
