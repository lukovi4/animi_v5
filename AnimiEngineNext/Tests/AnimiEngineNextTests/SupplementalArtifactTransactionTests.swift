import XCTest
@testable import AnimiEngineNext
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport

/// Task-003 corrective pass §10.1/§10.4, §13 "Transactional evidence" — a filesystem failure during
/// supplemental creation **poisons** the run (state `failed`, events handle closed, whole staging
/// removed, final dir never appears, subsequent calls throw `runPreviouslyFailed`). The exclusive
/// descriptor-relative shim rejects parent/leaf symlinks and overwrite with no validate-then-write
/// window. Pre-write caller faults (duplicate, invalid path) leave the run open.
final class SupplementalArtifactTransactionTests: XCTestCase {

    private var parentDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimiEngineNextSuppTxn-\(UUID().uuidString)", isDirectory: true)
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
            wallClock: TestWallClock(dates: [Date(timeIntervalSince1970: 1_700_000_000),
                                             Date(timeIntervalSince1970: 1_700_000_005)]),
            monotonicClock: TestMonotonicClock(values: [0, 1, 2, 3]),
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

    private func assertPoisoned(_ run: BenchmarkRun) {
        XCTAssertEqual(run.state, .failed, "run must be poisoned to .failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directoryURL.path),
                       "final run dir must be absent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.stagingDirectoryURL.path),
                       "staging dir must be removed")
    }

    // MARK: - Poison on write fault (correction 1)

    func testWriteFaultPoisonsRunAndCloseThrowsRunPreviouslyFailed() throws {
        let fs = FaultInjectingRunFileSystem(faults: [
            .init(.artifact(operation: .writeSupplementalFileExclusively, artifactFileName: "candidate.bin"))
        ])
        let run = try makeRun(fileSystem: fs, runID: "supp-txn-write")
        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data([0xAB]),
                                              at: try SupplementalArtifactPath("output/candidate.bin"))
        )
        assertPoisoned(run)
        // Subsequent close must report the prior failure, not silently succeed.
        XCTAssertThrowsError(try close(run)) { error in
            guard case .runPreviouslyFailed? = error as? BenchmarkRunError else {
                return XCTFail("expected runPreviouslyFailed, got \(error)")
            }
        }
        assertPoisoned(run)
    }

    /// Operation-failure lifecycle test (honest scope): the injected fault aborts the **entire**
    /// `writeSupplementalFileExclusively` semantic operation before it touches the filesystem, so this
    /// proves only that *any* failure of that operation poisons the run — it does NOT specifically
    /// exercise a `mkdirat` failure inside the shim. The dedicated `mkdirat`-failure path is covered
    /// by ``testRealMkdiratFailureInsideShimPoisonsRun`` below.
    func testSupplementalOperationFaultPoisonsRun() throws {
        let fs = FaultInjectingRunFileSystem(faults: [
            .init(.artifact(operation: .writeSupplementalFileExclusively, artifactFileName: "x.bin"))
        ])
        let run = try makeRun(fileSystem: fs, runID: "supp-txn-opfault")
        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data([1]),
                                              at: try SupplementalArtifactPath("a/b/c/x.bin"))
        )
        assertPoisoned(run)
        XCTAssertThrowsError(try close(run)) { error in
            guard case .runPreviouslyFailed? = error as? BenchmarkRunError else {
                return XCTFail("expected runPreviouslyFailed, got \(error)")
            }
        }
    }

    /// Real, deterministic `mkdirat` failure **inside the shim**: a parent directory is made
    /// read-only so the shim's `mkdirat` of a child fails with `EACCES`. This drives the shim's
    /// `AEN_OP_MKDIRAT` path → typed `ioFailure` → poisoned run. Skipped only if the platform runs
    /// the test as root (where mode bits do not deny access).
    func testRealMkdiratFailureInsideShimPoisonsRun() throws {
        try XCTSkipIf(getuid() == 0, "running as root bypasses directory mode bits")

        let run = try makeRun(fileSystem: DefaultRunFileSystem(), runID: "supp-txn-realmkdir")
        // Pre-create `locked/` inside staging and strip write permission.
        let locked = run.stagingDirectoryURL.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        // Writing `locked/child/x.bin` forces mkdirat("child") inside the read-only `locked` dir.
        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data([1]),
                                              at: try SupplementalArtifactPath("locked/child/x.bin"))
        ) { error in
            guard case .ioFailure(let reason)? = error as? BenchmarkRunError else {
                return XCTFail("expected ioFailure from mkdirat, got \(error)")
            }
            XCTAssertTrue(reason.contains("mkdirat"), "expected mkdirat step in reason, got: \(reason)")
        }
        assertPoisoned(run)
    }

    // MARK: - Write-after-failed / write-after-sealed lifecycle (correction 2)

    func testWriteAfterFailedThrowsRunPreviouslyFailed() throws {
        let fs = FaultInjectingRunFileSystem(faults: [
            .init(.artifact(operation: .writeSupplementalFileExclusively, artifactFileName: "first.bin"))
        ])
        let run = try makeRun(fileSystem: fs, runID: "supp-txn-after-failed")
        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data([1]), at: try SupplementalArtifactPath("first.bin")))
        assertPoisoned(run)
        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data([2]), at: try SupplementalArtifactPath("second.bin"))
        ) { error in
            guard case .runPreviouslyFailed? = error as? BenchmarkRunError else {
                return XCTFail("expected runPreviouslyFailed, got \(error)")
            }
        }
    }

    func testWriteAfterSealedThrowsRunAlreadySealed() throws {
        let run = try makeRun(fileSystem: DefaultRunFileSystem(), runID: "supp-txn-after-sealed")
        try close(run)
        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data([1]), at: try SupplementalArtifactPath("late.bin"))
        ) { error in
            guard case .runAlreadySealed? = error as? BenchmarkRunError else {
                return XCTFail("expected runAlreadySealed, got \(error)")
            }
        }
    }

    // MARK: - Exclusive create: overwrite rejected (correction 3)

    func testExistingTargetCannotBeOverwritten() throws {
        let run = try makeRun(fileSystem: DefaultRunFileSystem(), runID: "supp-txn-overwrite")
        // Pre-create the target inside staging so the exclusive O_EXCL create collides.
        let target = run.stagingDirectoryURL.appendingPathComponent("output/dup.bin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("pre".utf8).write(to: target)

        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data("new".utf8),
                                              at: try SupplementalArtifactPath("output/dup.bin"))
        ) { error in
            guard case .runDirectoryAlreadyExists? = error as? BenchmarkRunError else {
                return XCTFail("expected runDirectoryAlreadyExists (O_EXCL), got \(error)")
            }
        }
        // The exclusive create failed → poison; the pre-existing file is untouched.
        assertPoisoned(run)
        // (staging removed, so the pre-existing file is gone with it — that is correct poisoning.)
    }

    // MARK: - Symlink rejection (correction 3 + 4)

    func testParentComponentSymlinkIsRejected() throws {
        let run = try makeRun(fileSystem: DefaultRunFileSystem(), runID: "supp-txn-parent-symlink")
        // Make `output` a symlink pointing outside staging.
        let escapeTarget = parentDir.appendingPathComponent("ESCAPE_DIR", isDirectory: true)
        try FileManager.default.createDirectory(at: escapeTarget, withIntermediateDirectories: true)
        let symlink = run.stagingDirectoryURL.appendingPathComponent("output")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: escapeTarget)

        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data([1]),
                                              at: try SupplementalArtifactPath("output/x.bin"))
        ) { error in
            guard case .ioFailure? = error as? BenchmarkRunError else {
                return XCTFail("expected ioFailure (ELOOP via O_NOFOLLOW), got \(error)")
            }
        }
        assertPoisoned(run)
        // The escape target must NOT have received the file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapeTarget.appendingPathComponent("x.bin").path))
    }

    func testLeafComponentSymlinkIsRejected() throws {
        let run = try makeRun(fileSystem: DefaultRunFileSystem(), runID: "supp-txn-leaf-symlink")
        // Pre-create a symlink at the leaf path inside staging.
        let escapeFile = parentDir.appendingPathComponent("escape-target.txt")
        try Data("victim".utf8).write(to: escapeFile)
        let leaf = run.stagingDirectoryURL.appendingPathComponent("leaf.bin")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: escapeFile)

        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data("payload".utf8),
                                              at: try SupplementalArtifactPath("leaf.bin"))
        ) { error in
            // O_CREAT|O_EXCL|O_NOFOLLOW on a symlink leaf fails with EEXIST → mapped to collision.
            guard let e = error as? BenchmarkRunError else { return XCTFail("got \(error)") }
            switch e {
            case .runDirectoryAlreadyExists, .ioFailure: break
            default: XCTFail("expected collision/ioFailure, got \(e)")
            }
        }
        assertPoisoned(run)
        // The symlink target must be unchanged — never followed.
        XCTAssertEqual(try String(contentsOf: escapeFile, encoding: .utf8), "victim")
    }

    // MARK: - Deterministic swap-race protection (correction 4)

    /// Proves there is no validate-then-write window: the pre-leaf hook swaps a parent component to a
    /// symlink *after* the run decided to write, and the exclusive shim still rejects it via
    /// O_NOFOLLOW. This is the deterministic analogue of an attacker winning the TOCTOU race.
    func testComponentSwappedToSymlinkBetweenValidationAndWriteIsRejected() throws {
        let escapeTarget = parentDir.appendingPathComponent("RACE_ESCAPE", isDirectory: true)
        try FileManager.default.createDirectory(at: escapeTarget, withIntermediateDirectories: true)

        // The hook fires immediately before the shim's atomic walk. It deletes the real `output`
        // directory (if any) and replaces it with a symlink to the escape target.
        let fm = FileManager.default
        let hookParent = parentDir!
        let hook: @Sendable (URL) -> Void = { _ in
            // Reconstruct the staging `output` path deterministically from the known run id.
            let staging = hookParent.appendingPathComponent(".supp-txn-race.staging", isDirectory: true)
            let output = staging.appendingPathComponent("output")
            try? fm.removeItem(at: output)
            try? fm.createSymbolicLink(at: output, withDestinationURL: escapeTarget)
        }
        let base = DefaultRunFileSystem(supplementalPreWriteHook: hook)
        let run = try makeRun(fileSystem: base, runID: "supp-txn-race")

        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data("secret".utf8),
                                              at: try SupplementalArtifactPath("output/x.bin"))
        ) { error in
            guard case .ioFailure? = error as? BenchmarkRunError else {
                return XCTFail("expected ioFailure (O_NOFOLLOW rejects swapped symlink), got \(error)")
            }
        }
        assertPoisoned(run)
        // The swapped symlink must not have been followed: nothing written to the escape target.
        XCTAssertFalse(fm.fileExists(atPath: escapeTarget.appendingPathComponent("x.bin").path),
                       "O_NOFOLLOW must prevent the write from escaping through the swapped symlink")
    }

    // MARK: - Path validation occurs before any filesystem write (unchanged guarantee)

    func testInvalidPathRejectedBeforeAnyFilesystemWrite() throws {
        let fs = FaultInjectingRunFileSystem(faults: [])
        let run = try makeRun(fileSystem: fs, runID: "supp-txn-validate")
        XCTAssertThrowsError(try SupplementalArtifactPath("../escape.bin"))
        // No supplemental write op was attempted; the run is still open and closes cleanly.
        XCTAssertFalse(fs.attempted.contains { $0.operation == .writeSupplementalFileExclusively })
        try close(run)
        XCTAssertEqual(run.state, .sealed)
    }

    func testDuplicatePathRejectedWithoutPoisoningRun() throws {
        let run = try makeRun(fileSystem: DefaultRunFileSystem(), runID: "supp-txn-dup")
        try run.writeSupplementalArtifact(data: Data([1]), at: try SupplementalArtifactPath("a.bin"))
        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data([2]), at: try SupplementalArtifactPath("a.bin"))
        ) { error in
            guard case SupplementalArtifactError.duplicatePath? = error as? SupplementalArtifactError else {
                return XCTFail("expected duplicatePath, got \(error)")
            }
        }
        // No filesystem mutation occurred on the duplicate → run stays open and closes cleanly.
        XCTAssertEqual(run.state, .open)
        try close(run)
        XCTAssertEqual(run.state, .sealed)
    }
}
