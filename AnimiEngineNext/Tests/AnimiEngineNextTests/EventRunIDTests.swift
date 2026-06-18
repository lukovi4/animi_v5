import XCTest
@testable import AnimiEngineNext
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport

/// C-3 — `appendEvent` rejects events whose `runID` differs from the run's `runID`.
final class EventRunIDTests: XCTestCase {

    private var parentDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimiEngineNextRunID-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let parentDir { try? FileManager.default.removeItem(at: parentDir) }
        try super.tearDownWithError()
    }

    private func makeRun(runID: String = "evt-001") throws -> BenchmarkRun {
        try BenchmarkRun(
            parentDirectoryURL: parentDir,
            idGenerator: TestIDGenerator(ids: [runID]),
            wallClock: TestWallClock(dates: [Date(timeIntervalSince1970: 1_700_000_000)]),
            monotonicClock: TestMonotonicClock(values: [0, 1, 2])
        )
    }

    func testForeignRunIDIsRejectedAndNotCounted() throws {
        let run = try makeRun()
        let stagingEvents = run.stagingDirectoryURL.appendingPathComponent(RunArtifact.eventsStaging)
        let before = try Data(contentsOf: stagingEvents)

        XCTAssertThrowsError(try run.appendEvent(DiagnosticEvent(
            runID: BenchmarkRunID(rawValue: "some-other-run"),
            elapsedNanoseconds: 0,
            subsystem: "x",
            eventType: "y",
            fields: [:]
        ))) { error in
            XCTAssertEqual(
                error as? BenchmarkRunError,
                .foreignRunID(expected: "evt-001", found: "some-other-run")
            )
        }

        // Nothing was written for the rejected event.
        let after = try Data(contentsOf: stagingEvents)
        XCTAssertEqual(before, after, "staging events file must be unchanged after a rejected event")
    }

    func testMatchingRunIDIsAppended() throws {
        let run = try makeRun()
        try run.appendEvent(DiagnosticEvent(
            runID: run.runID,
            elapsedNanoseconds: run.elapsedNanoseconds(),
            subsystem: "decode",
            eventType: "frame",
            fields: ["i": "0"]
        ))
        let stagingEvents = run.stagingDirectoryURL.appendingPathComponent(RunArtifact.eventsStaging)
        let text = try String(contentsOf: stagingEvents, encoding: .utf8)
        XCTAssertTrue(text.contains("\"runID\":\"evt-001\""))
    }
}
