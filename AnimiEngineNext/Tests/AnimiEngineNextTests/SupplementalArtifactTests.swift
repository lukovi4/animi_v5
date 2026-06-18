import XCTest
import CryptoKit
@testable import AnimiEngineNext
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport

/// Task-003 plan §10.1/§10.2, §13 row "Supplemental evidence" — safe paths, write-once, recorded
/// hashes, lifecycle gating, and the canonical supplemental manifest committed by the run manifest.
final class SupplementalArtifactTests: XCTestCase {

    private var parentDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimiEngineNextSupp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let parentDir { try? FileManager.default.removeItem(at: parentDir) }
        try super.tearDownWithError()
    }

    private func makeRun(fileSystem: RunFileSystem = DefaultRunFileSystem(), runID: String) throws -> BenchmarkRun {
        try BenchmarkRun(
            parentDirectoryURL: parentDir,
            idGenerator: TestIDGenerator(ids: [runID]),
            wallClock: TestWallClock(dates: [
                Date(timeIntervalSince1970: 1_700_000_000),
                Date(timeIntervalSince1970: 1_700_000_005)
            ]),
            monotonicClock: TestMonotonicClock(values: [0, 1, 2, 3, 4]),
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

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Path validation (§10.1)

    func testPathValidationRejectsUnsafeForms() {
        let unsafe = [
            "",                       // empty
            "/abs/path.json",         // absolute
            "a/../b.json",            // .. component
            "./a.json",               // . component
            "a//b.json",              // empty component
            "trailing/",              // trailing empty component
            "with\\backslash.json",   // platform separator
            "with\u{00}nul.json"      // NUL
        ]
        for raw in unsafe {
            XCTAssertThrowsError(try SupplementalArtifactPath(raw), "should reject '\(raw)'") { error in
                XCTAssertTrue(error is SupplementalArtifactError, "got \(error) for '\(raw)'")
            }
        }
    }

    func testPathValidationRejectsReservedCoreNames() {
        for reserved in [RunArtifact.runManifest.rawValue,
                         RunArtifact.engineConfig.rawValue,
                         RunArtifact.events.rawValue,
                         RunArtifact.supplementalManifest] {
            XCTAssertThrowsError(try SupplementalArtifactPath(reserved)) { error in
                guard case SupplementalArtifactError.reservedName? = error as? SupplementalArtifactError else {
                    return XCTFail("expected reservedName for \(reserved), got \(error)")
                }
            }
        }
    }

    func testPathValidationAcceptsNestedRelativePaths() throws {
        let p = try SupplementalArtifactPath("output/candidates/full_image-f0.png")
        XCTAssertEqual(p.normalized, "output/candidates/full_image-f0.png")
        XCTAssertEqual(p.components, ["output", "candidates", "full_image-f0.png"])
        // A reserved name is only reserved as a SINGLE component — nesting it is allowed.
        let nested = try SupplementalArtifactPath("output/\(RunArtifact.runManifest.rawValue)")
        XCTAssertEqual(nested.components.count, 2)
    }

    // MARK: - Write-once and lifecycle gating

    func testWriteOnceRejectsDuplicatePath() throws {
        let run = try makeRun(runID: "supp-dup")
        let path = try SupplementalArtifactPath("output/x.bin")
        try run.writeSupplementalArtifact(data: Data([1, 2, 3]), at: path)
        XCTAssertThrowsError(try run.writeSupplementalArtifact(data: Data([4, 5]), at: path)) { error in
            guard case SupplementalArtifactError.duplicatePath? = error as? SupplementalArtifactError else {
                return XCTFail("expected duplicatePath, got \(error)")
            }
        }
        try close(run)
    }

    func testWriteAfterSealedThrowsRunAlreadySealed() throws {
        let run = try makeRun(runID: "supp-sealed")
        try close(run)   // → sealed
        XCTAssertThrowsError(
            try run.writeSupplementalArtifact(data: Data([1]), at: try SupplementalArtifactPath("late.bin"))
        ) { error in
            guard case .runAlreadySealed? = error as? BenchmarkRunError else {
                return XCTFail("expected runAlreadySealed, got \(error)")
            }
        }
    }

    func testSupplementalFileNotVisibleUnderFinalRunBeforeClose() throws {
        let run = try makeRun(runID: "supp-staging")
        try run.writeSupplementalArtifact(data: Data("hello".utf8), at: try SupplementalArtifactPath("output/a.txt"))
        // Mid-run: present in staging, absent under the final run path.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: run.stagingDirectoryURL.appendingPathComponent("output/a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directoryURL.path))
    }

    // MARK: - Successful publication of core + supplemental set (§10.4)

    func testSuccessfulClosePublishesCoreAndSupplementalArtifacts() throws {
        let run = try makeRun(runID: "supp-publish")
        try run.writeSupplementalArtifact(data: Data("alpha".utf8), at: try SupplementalArtifactPath("output/diffs/a.txt"))
        try run.writeSupplementalArtifact(data: Data("beta".utf8), at: try SupplementalArtifactPath("render-manifest.json"))
        try close(run)

        // All core artifacts present.
        for artifact in RunArtifact.allCases {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: run.directoryURL.appendingPathComponent(artifact.rawValue).path),
                "missing core artifact \(artifact.rawValue)")
        }
        // Supplemental files present at their nested paths.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: run.directoryURL.appendingPathComponent("output/diffs/a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: run.directoryURL.appendingPathComponent("render-manifest.json").path))
        // The supplemental manifest is published.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: run.directoryURL.appendingPathComponent(RunArtifact.supplementalManifest).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.stagingDirectoryURL.path))
    }

    // MARK: - Manifest records path/size/sha256 and run manifest commits its hash (§10.2)

    func testSupplementalManifestRecordsSortedEntriesWithSizeAndHash() throws {
        let run = try makeRun(runID: "supp-manifest")
        // Write out of lexicographic order; the manifest must sort by path.
        let dataB = Data("bbbb".utf8)
        let dataA = Data("a".utf8)
        try run.writeSupplementalArtifact(data: dataB, at: try SupplementalArtifactPath("output/b.bin"))
        try run.writeSupplementalArtifact(data: dataA, at: try SupplementalArtifactPath("output/a.bin"))
        try close(run)

        let manifestData = try Data(contentsOf:
            run.directoryURL.appendingPathComponent(RunArtifact.supplementalManifest))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        // Sorted by path: a.bin before b.bin.
        XCTAssertEqual(entries[0]["path"] as? String, "output/a.bin")
        XCTAssertEqual(entries[1]["path"] as? String, "output/b.bin")
        XCTAssertEqual(entries[0]["size"] as? Int, dataA.count)
        XCTAssertEqual(entries[1]["size"] as? Int, dataB.count)
        XCTAssertEqual(entries[0]["sha256"] as? String, sha256Hex(dataA))
        XCTAssertEqual(entries[1]["sha256"] as? String, sha256Hex(dataB))

        // Run manifest commits the SHA-256 of the supplemental manifest bytes.
        let runManifestData = try Data(contentsOf:
            run.directoryURL.appendingPathComponent(RunArtifact.runManifest.rawValue))
        let runManifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: runManifestData) as? [String: Any])
        XCTAssertEqual(runManifest["supplementalArtifactsSHA256"] as? String, sha256Hex(manifestData))
    }

    func testEmptyRunRecordsCanonicalEmptyManifestHash() throws {
        let run = try makeRun(runID: "supp-empty")
        try close(run)
        let manifestData = try Data(contentsOf:
            run.directoryURL.appendingPathComponent(RunArtifact.supplementalManifest))
        XCTAssertEqual(String(data: manifestData, encoding: .utf8), "{\"entries\":[]}")

        let runManifestData = try Data(contentsOf:
            run.directoryURL.appendingPathComponent(RunArtifact.runManifest.rawValue))
        let runManifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: runManifestData) as? [String: Any])
        XCTAssertEqual(runManifest["supplementalArtifactsSHA256"] as? String, sha256Hex(manifestData))
    }

    // MARK: - Aggregate hash sensitivity (§10.4)

    func testAggregateHashChangesWhenAnySupplementalByteOrPathChanges() throws {
        func hashAfter(write: (BenchmarkRun) throws -> Void, runID: String) throws -> String {
            let run = try makeRun(runID: runID)
            try write(run)
            try close(run)
            let runManifestData = try Data(contentsOf:
                run.directoryURL.appendingPathComponent(RunArtifact.runManifest.rawValue))
            let runManifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: runManifestData) as? [String: Any])
            return try XCTUnwrap(runManifest["supplementalArtifactsSHA256"] as? String)
        }

        let base = try hashAfter(write: { run in
            try run.writeSupplementalArtifact(data: Data("x".utf8), at: try SupplementalArtifactPath("a.bin"))
        }, runID: "supp-h1")
        let differentBytes = try hashAfter(write: { run in
            try run.writeSupplementalArtifact(data: Data("y".utf8), at: try SupplementalArtifactPath("a.bin"))
        }, runID: "supp-h2")
        let differentPath = try hashAfter(write: { run in
            try run.writeSupplementalArtifact(data: Data("x".utf8), at: try SupplementalArtifactPath("b.bin"))
        }, runID: "supp-h3")

        XCTAssertNotEqual(base, differentBytes, "aggregate hash must change when a byte changes")
        XCTAssertNotEqual(base, differentPath, "aggregate hash must change when a path changes")
    }
}
