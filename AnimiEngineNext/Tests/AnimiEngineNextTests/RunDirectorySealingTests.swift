import XCTest
@testable import AnimiEngineNext
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport

/// Run-directory lifecycle tests: exclusive staging reservation, sealing, publish no-overwrite
/// (Task-001 acceptance #4, #5; Revision-5 §2.1/§2.2).
final class RunDirectorySealingTests: XCTestCase {

    private var parentDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimiEngineNextSeal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let parentDir { try? FileManager.default.removeItem(at: parentDir) }
        try super.tearDownWithError()
    }

    private func makeRun(runID: String = "seal-001") throws -> BenchmarkRun {
        try BenchmarkRun(
            parentDirectoryURL: parentDir,
            idGenerator: TestIDGenerator(ids: [runID]),
            wallClock: TestWallClock(dates: [Date(timeIntervalSince1970: 1_700_000_000)]),
            monotonicClock: TestMonotonicClock(values: [0, 1, 2])
        )
    }

    private func close(_ run: BenchmarkRun) throws {
        try run.close(
            engineConfiguration: ConfigurationTests.referenceConfiguration(),
            deviceInfo: DeviceInfo(model: "M", systemName: "iOS", systemVersion: "18.0"),
            status: .success
        )
    }

    func testRunExclusivelyReservesStagingAndFinalIsAbsentUntilPublish() throws {
        let run = try makeRun()
        // The staging directory is the reservation; the final run directory does not yet exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.stagingDirectoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directoryURL.path))

        try close(run)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.directoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.stagingDirectoryURL.path))
    }

    func testStagingReservationCollisionIsRejected() throws {
        // Pre-create the staging directory so the exclusive reservation collides.
        let staging = parentDir.appendingPathComponent(".dup.staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        XCTAssertThrowsError(try makeRun(runID: "dup")) { error in
            guard case .runDirectoryAlreadyExists? = error as? BenchmarkRunError else {
                return XCTFail("expected runDirectoryAlreadyExists, got \(error)")
            }
        }
    }

    func testAppendAfterSuccessfulCloseIsRejectedAsSealed() throws {
        let run = try makeRun()
        try close(run)
        XCTAssertThrowsError(try run.appendEvent(DiagnosticEvent(
            runID: run.runID, elapsedNanoseconds: 0, subsystem: "x", eventType: "y", fields: [:]
        ))) { error in
            XCTAssertEqual(error as? BenchmarkRunError, .runAlreadySealed)
        }
    }

    func testCloseAfterSuccessfulCloseIsRejectedAsSealed() throws {
        let run = try makeRun()
        try close(run)
        XCTAssertThrowsError(try close(run)) { error in
            XCTAssertEqual(error as? BenchmarkRunError, .runAlreadySealed)
        }
    }
}
