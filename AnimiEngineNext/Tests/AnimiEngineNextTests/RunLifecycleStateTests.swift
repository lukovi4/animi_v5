import XCTest
@testable import AnimiEngineNext
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport

/// Amendment 4 — `sealed` and `failed` are distinct lifecycle states. After a failed close, calls
/// throw `runPreviouslyFailed` (NOT `runAlreadySealed`).
final class RunLifecycleStateTests: XCTestCase {

    private var parentDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimiEngineNextState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let parentDir { try? FileManager.default.removeItem(at: parentDir) }
        try super.tearDownWithError()
    }

    private func makeRun(fileSystem: RunFileSystem, runID: String) throws -> BenchmarkRun {
        try BenchmarkRun(
            parentDirectoryURL: parentDir,
            idGenerator: TestIDGenerator(ids: [runID]),
            wallClock: TestWallClock(dates: [Date(timeIntervalSince1970: 1_700_000_000)]),
            monotonicClock: TestMonotonicClock(values: [0, 1, 2]),
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

    func testSuccessfulCloseReachesSealedState() throws {
        let run = try makeRun(fileSystem: DefaultRunFileSystem(), runID: "state-sealed")
        try close(run)
        XCTAssertEqual(run.state, .sealed)
    }

    func testFailedCloseReachesFailedState() throws {
        let fs = FaultInjectingRunFileSystem(faults: [.init(.publish(finalPathSuffix: "state-failed"))])
        let run = try makeRun(fileSystem: fs, runID: "state-failed")
        XCTAssertThrowsError(try close(run))
        XCTAssertEqual(run.state, .failed)
    }

    func testCallsAfterFailureThrowRunPreviouslyFailedNotSealed() throws {
        let fs = FaultInjectingRunFileSystem(faults: [.init(.publish(finalPathSuffix: "state-after-fail"))])
        let run = try makeRun(fileSystem: fs, runID: "state-after-fail")
        XCTAssertThrowsError(try close(run))

        XCTAssertThrowsError(try run.appendEvent(DiagnosticEvent(
            runID: run.runID, elapsedNanoseconds: 0, subsystem: "x", eventType: "y", fields: [:]
        ))) { error in
            XCTAssertEqual(error as? BenchmarkRunError, .runPreviouslyFailed)
        }
        XCTAssertThrowsError(try close(run)) { error in
            XCTAssertEqual(error as? BenchmarkRunError, .runPreviouslyFailed)
        }
    }
}
