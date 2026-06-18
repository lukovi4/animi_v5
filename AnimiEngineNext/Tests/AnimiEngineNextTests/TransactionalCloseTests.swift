import XCTest
@testable import AnimiEngineNext
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport

/// C-2/C-5 — transactional publication: an interrupted `close()` publishes nothing; publication is
/// atomic and no-overwrite; init failures clean up (Revision-5 §2.2, amendments 2/4/7).
final class TransactionalCloseTests: XCTestCase {

    private var parentDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimiEngineNextTxn-\(UUID().uuidString)", isDirectory: true)
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

    private func assertNothingPublished(_ run: BenchmarkRun) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directoryURL.path),
                       "final run dir must be absent after a failed close")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.stagingDirectoryURL.path),
                       "staging dir must be removed after a failed close")
        XCTAssertEqual(run.state, .failed)
    }

    // MARK: - Interrupted close (C-2/C-5)

    func testPublishFaultLeavesNoFinalRun() throws {
        let fs = FaultInjectingRunFileSystem(faults: [.init(.publish(finalPathSuffix: "txn-publish"))])
        let run = try makeRun(fileSystem: fs, runID: "txn-publish")
        XCTAssertThrowsError(try close(run))
        assertNothingPublished(run)
    }

    func testManifestWriteFaultLeavesNoFinalRunAndNoFinalEvents() throws {
        let fs = FaultInjectingRunFileSystem(faults: [
            .init(.artifact(operation: .write, artifactFileName: RunArtifact.runManifest.rawValue))
        ])
        let run = try makeRun(fileSystem: fs, runID: "txn-manifest")
        XCTAssertThrowsError(try close(run))
        assertNothingPublished(run)
        let finalEvents = run.directoryURL.appendingPathComponent(RunArtifact.events.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalEvents.path))
    }

    func testDeviceWriteFaultLeavesNoFinalRun() throws {
        let fs = FaultInjectingRunFileSystem(faults: [
            .init(.artifact(operation: .write, artifactFileName: RunArtifact.device.rawValue))
        ])
        let run = try makeRun(fileSystem: fs, runID: "txn-device")
        XCTAssertThrowsError(try close(run))
        assertNothingPublished(run)
    }

    func testEventsRenameFaultLeavesNoFinalRun() throws {
        let fs = FaultInjectingRunFileSystem(faults: [
            .init(.artifact(operation: .renameWithinDirectory, artifactFileName: RunArtifact.events.rawValue))
        ])
        let run = try makeRun(fileSystem: fs, runID: "txn-events")
        XCTAssertThrowsError(try close(run))
        assertNothingPublished(run)
    }

    // MARK: - Atomic no-overwrite publication (amendment 2)

    func testPublishIsRejectedWhenFinalAlreadyExistsAndDoesNotOverwrite() throws {
        // T-PUB1: pre-create the final path with a sentinel; publish must not overwrite it.
        let runID = "txn-pub1"
        let finalDir = parentDir.appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        let sentinel = finalDir.appendingPathComponent("PRE_EXISTING.txt")
        try Data("keep-me".utf8).write(to: sentinel)

        let run = try makeRun(fileSystem: DefaultRunFileSystem(), runID: runID)
        XCTAssertThrowsError(try close(run)) { error in
            guard case .runDirectoryAlreadyExists? = error as? BenchmarkRunError else {
                return XCTFail("expected runDirectoryAlreadyExists, got \(error)")
            }
        }
        // Existing final directory remains unchanged; BenchmarkRun never modifies it.
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep-me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.stagingDirectoryURL.path))
        XCTAssertEqual(run.state, .failed)
    }

    func testSuccessfulClosePublishesAllArtifactsAndRemovesStaging() throws {
        // T-PUB2.
        let run = try makeRun(fileSystem: DefaultRunFileSystem(), runID: "txn-pub2")
        try close(run)
        for artifact in RunArtifact.allCases {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: run.directoryURL.appendingPathComponent(artifact.rawValue).path),
                "missing \(artifact.rawValue)"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.stagingDirectoryURL.path))
        XCTAssertEqual(run.state, .sealed)
    }

    /// T-PUB3 — two **genuinely concurrent** publishers race to publish to the SAME final path.
    /// Both threads are released together by a barrier; results are collected thread-safely. Exactly
    /// one succeeds, one collides, and the winner's content is never overwritten.
    func testConcurrentPublicationToSameFinalPathExactlyOneWins() throws {
        let finalRunID = "txn-pub3"
        let finalDir = parentDir.appendingPathComponent(finalRunID, isDirectory: true)
        let fs = DefaultRunFileSystem()

        // Two complete staging directories, each ready to publish to `finalDir`.
        func buildStaging(tag: String) throws -> URL {
            let staging = parentDir.appendingPathComponent(".\(finalRunID)-\(tag).staging", isDirectory: true)
            try fs.createDirectoryExclusively(at: staging)
            try fs.write(Data(tag.utf8), to: staging.appendingPathComponent("marker.txt"))
            return staging
        }
        let stagings = ["A": try buildStaging(tag: "A"), "B": try buildStaging(tag: "B")]

        // Thread-safe result collector.
        final class Results: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var successes: [String] = []
            private(set) var collisions: [String] = []
            func recordSuccess(_ tag: String) { lock.lock(); successes.append(tag); lock.unlock() }
            func recordCollision(_ tag: String) { lock.lock(); collisions.append(tag); lock.unlock() }
        }
        let results = Results()

        // Barrier: both workers wait here, then are released as close to simultaneously as possible.
        let startGate = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "txn.race", attributes: .concurrent)

        for (tag, staging) in stagings {
            group.enter()
            queue.async {
                startGate.wait()            // hold until released
                do {
                    try fs.publishDirectoryExclusively(from: staging, to: finalDir)
                    results.recordSuccess(tag)
                } catch BenchmarkRunError.runDirectoryAlreadyExists {
                    results.recordCollision(tag)
                } catch {
                    XCTFail("unexpected error: \(error)")
                }
                group.leave()
            }
        }

        startGate.signal()                  // release worker 1
        startGate.signal()                  // release worker 2
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success, "publishers did not finish in time")

        XCTAssertEqual(results.successes.count, 1, "exactly one publish must succeed")
        XCTAssertEqual(results.collisions.count, 1, "exactly one publish must collide")

        // The winner's content is intact and was never overwritten by the loser.
        let winnerTag = try XCTUnwrap(results.successes.first)
        let marker = try String(contentsOf: finalDir.appendingPathComponent("marker.txt"), encoding: .utf8)
        XCTAssertEqual(marker, winnerTag, "winning publisher's content must remain intact")
    }

    /// Concurrent staging reservation: two initializers race to reserve the SAME staging path via
    /// the atomic `createDirectoryExclusively` (mkdir). Exactly one succeeds; the other collides.
    func testConcurrentStagingReservationExactlyOneSucceeds() throws {
        let fs = DefaultRunFileSystem()
        let staging = parentDir.appendingPathComponent(".reserve-race.staging", isDirectory: true)

        final class Results: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var successes = 0
            private(set) var collisions = 0
            func ok() { lock.lock(); successes += 1; lock.unlock() }
            func collide() { lock.lock(); collisions += 1; lock.unlock() }
        }
        let results = Results()

        let startGate = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "txn.race", attributes: .concurrent)

        for _ in 0..<2 {
            group.enter()
            queue.async {
                startGate.wait()
                do {
                    try fs.createDirectoryExclusively(at: staging)
                    results.ok()
                } catch BenchmarkRunError.runDirectoryAlreadyExists {
                    results.collide()
                } catch {
                    XCTFail("unexpected error: \(error)")
                }
                group.leave()
            }
        }
        startGate.signal(); startGate.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(results.successes, 1, "exactly one reservation must succeed")
        XCTAssertEqual(results.collisions, 1, "exactly one reservation must collide")
    }

    // MARK: - Init-failure cleanup (amendment 7)

    func testInitCreateFileFaultCleansUpStaging() throws {
        // T-IN1: the events-staging file creation fails during init → staging removed, no final dir.
        let fs = FaultInjectingRunFileSystem(faults: [
            .init(.artifact(operation: .createFile, artifactFileName: RunArtifact.eventsStaging))
        ])
        XCTAssertThrowsError(try makeRun(fileSystem: fs, runID: "txn-in1"))
        let staging = parentDir.appendingPathComponent(".txn-in1.staging", isDirectory: true)
        let finalDir = parentDir.appendingPathComponent("txn-in1", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path),
                       "staging must be removed after init failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalDir.path))
    }

    func testInitStagingCollisionThrowsAndCreatesNoFinal() throws {
        // T-IN2: staging already exists → reservation collision, nothing created wrongly.
        let runID = "txn-in2"
        let staging = parentDir.appendingPathComponent(".\(runID).staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        XCTAssertThrowsError(try makeRun(fileSystem: DefaultRunFileSystem(), runID: runID)) { error in
            guard case .runDirectoryAlreadyExists? = error as? BenchmarkRunError else {
                return XCTFail("expected runDirectoryAlreadyExists, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parentDir.appendingPathComponent(runID).path))
    }
}
