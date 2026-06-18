import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineNext
import AnimiEngineMetalRender
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport
@testable import AnimiEngineRenderTestSupport

/// Task-003 / Step-14 — the complete real-template/frame matrix + structural fixtures, recorded through
/// the Step-13 evidence system. Runs on the M2 Pro (the Metal executor runs on macOS).
final class Step14MatrixTests: XCTestCase {

    // MARK: - Fixtures

    private func scenesRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }   // Tests/AnimiEngineMetalRenderTests/<file> → repo
        return url.appendingPathComponent("AnimiApp/Resources/Scenes")
    }

    private func config() throws -> RenderConfiguration {
        try RenderConfiguration(
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)),
            intermediateProfile: .rgba16FloatLinear)
    }

    private func minimalEngineConfig() -> EngineConfiguration {
        EngineConfiguration(
            schemaVersion: 1, projectFrameRate: 30,
            preview: PreviewConfiguration(frameRateLadder: [30]),
            decoder: DecoderConfiguration(backend: "videoToolbox", poolLimit: 1),
            proxy: ProxyConfiguration(profiles: [ProxyProfile(name: "p", maxDimension: 1080)]),
            cache: CacheConfiguration(frameCacheBudgetMiB: 16, diskProxyBudgetMiB: 16),
            renderQuality: RenderQualityConfiguration(profiles: [RenderQualityProfile(name: "final", scalePercent: 100)]),
            memory: MemoryConfiguration(softLimitMiB: 64, hardLimitMiB: 128),
            export: ExportConfiguration(profiles: [ExportProfile(name: "e", frameRate: 30, bitrate: 1)]),
            diagnostics: DiagnosticsConfiguration(samplingPercent: 100, output: "ndjson"))
    }

    private let device = DeviceInfo(model: "M2Pro", systemName: "macOS", systemVersion: "test")

    private func makeRun(_ parent: URL, fileSystem: RunFileSystem, runID: String) throws -> BenchmarkRun {
        try BenchmarkRun(
            parentDirectoryURL: parent,
            idGenerator: TestIDGenerator(ids: [runID]),
            wallClock: TestWallClock(dates: [Date(timeIntervalSince1970: 1_700_000_000), Date(timeIntervalSince1970: 1_700_000_005)]),
            monotonicClock: TestMonotonicClock(values: [0, 1, 2, 3, 4, 5]),
            fileSystem: fileSystem)
    }

    private func tempDir(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s14-\(tag)-\(abs(name.hashValue))")
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func defaultPolicy() -> EvidenceRecorder.Policy {
        .init(tolerances: .exact, diffAmplification: 4)
    }

    // MARK: - M-1/M-2/M-3: enumeration determinism, no duplicate IDs, exact counts

    func testMatrixEnumerationIsDeterministic() throws {
        let rows1 = try RealTemplateMatrix.enumerateRows(scenesRootURL: scenesRoot())
        let rows2 = try RealTemplateMatrix.enumerateRows(scenesRootURL: scenesRoot())
        XCTAssertEqual(rows1, rows2, "enumeration is deterministic")
        XCTAssertFalse(rows1.isEmpty)
        // Every (block,variant) appears; 25 base pairs × per-template frame-time count.
        let pairs = Set(rows1.map { "\($0.catalogID)/\($0.blockID)/\($0.variantID)" })
        XCTAssertEqual(pairs.count, 25, "exactly 25 (catalog,block,variant) pairs (baseline)")
        // Row IDs are unique.
        XCTAssertEqual(Set(rows1.map { $0.rowID }).count, rows1.count, "row IDs unique")
    }

    func testInventoryBaselineEnforced() throws {
        // enumerateRows verifies 5/14/25 internally and throws inventoryMismatch otherwise; reaching here
        // without throwing proves the baseline holds.
        XCTAssertNoThrow(try RealTemplateMatrix.enumerateRows(scenesRootURL: scenesRoot()))
    }

    // MARK: - M-4/M-5/M-6: every row renders + records; default verdict candidateOnly

    func testFullMatrixRendersRecordsAndIsCandidateOnly() throws {
        let device0 = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device0)
        let parent = try tempDir("full")
        let run = try makeRun(parent, fileSystem: DefaultRunFileSystem(), runID: "matrix-full")
        // No reference store → candidateOnly everywhere.
        let driver = MatrixDriver(scenesRootURL: scenesRoot(), referenceStore: nil, configuration: try config(), policy: defaultPolicy())
        let result = try driver.run(session: session, into: run, engineConfiguration: minimalEngineConfig(), deviceInfo: device)

        // Counts: candidateCount == real + structural (unique); structural == 9 fixtures.
        XCTAssertEqual(result.candidateCount, result.realRowCount + result.structuralRowCount, "no duplicate candidate IDs across the matrix")
        XCTAssertEqual(result.structuralRowCount, 9, "nine structural fixtures")
        // Every enumerated row is accounted for: rendered + recorded, OR deterministically skipped because
        // authored layer timing makes its content inactive at that frame time.
        XCTAssertEqual(result.realRowCount + result.skippedRowCount, result.enumeratedRowCount, "every enumerated row rendered or was deterministically skipped")
        XCTAssertGreaterThan(result.realRowCount, 0, "at least one real row renders")

        // Every group manifest's candidates are all candidateOnly (no approved references).
        for (_, manifest) in result.groupManifests {
            XCTAssertTrue(manifest.candidates.allSatisfy { $0.verdict == "candidateOnly" }, "default verdict candidateOnly")
            for entry in manifest.candidates {
                XCTAssertNil(entry.diffArtifact, "no diff without a reference")
                XCTAssertNil(entry.referenceArtifact, "no reference snapshot without a reference")
            }
        }

        // Per-group layout: each catalog group + the structural group has candidates/, comparison/,
        // contact-sheet.png, render-manifest.json under the published run.
        let dir = result.runDirectoryURL
        for group in RealTemplateMatrix.catalogs + ["structural"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(group)/contact-sheet.png").path), "\(group) contact sheet")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(group)/render-manifest.json").path), "\(group) render manifest")
        }
        // Every candidate has a PNG + comparison JSON.
        for (group, manifest) in result.groupManifests {
            for entry in manifest.candidates {
                XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(entry.candidateArtifact).path), "\(group) candidate PNG \(entry.candidateID)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(entry.comparisonArtifact).path), "\(group) comparison JSON \(entry.candidateID)")
            }
        }
        // The run published its manifest-last commit marker.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("run-manifest.json").path), "run-manifest.json (commit marker)")
    }

    // MARK: - M-8/M-9/M-10/M-11: structural fixtures produce expected graph/metadata

    func testStructuralFixturesContainExpectedCommandCategories() throws {
        for fixture in try StructuralFixtures.all() {
            let categories = Set(fixture.graph.commands.map { $0.category })
            for expected in fixture.expectedCategories {
                XCTAssertTrue(categories.contains(expected), "[\(fixture.catalogID)] graph contains \(expected.rawValue)")
            }
            // Every structural graph ends with the final output (complete graph).
            XCTAssertEqual(fixture.graph.commands.last?.category, .finalOutput, "[\(fixture.catalogID)] complete graph")
            // Synthetic provenance prefix (D4).
            XCTAssertTrue(fixture.catalogID.hasPrefix("synthetic-"), "structural fixture uses a synthetic catalogID")
        }
    }

    func testVideoExactRationalFixtureUsesNTSCFrameRate() throws {
        let fx = try StructuralFixtures.videoExactRationalFixture()
        XCTAssertEqual(fx.graph.configuration.output.frameRate.numerator, 30000)
        XCTAssertEqual(fx.graph.configuration.output.frameRate.denominator, 1001)
        XCTAssertTrue(fx.graph.commands.contains { $0.category == .drawVideoFrame }, "video fixture emits drawVideoFrame")
    }

    func testPostRollHoldsLastFrameEqualsBoundaryFrame() throws {
        // The post-roll fixture and the boundary fixture render the SAME held image content; rendering both
        // yields byte-identical frames (holdLast holds the last authored frame past the authored end).
        let device0 = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device0)
        let post = try session.execute(try StructuralFixtures.postRollFixture().graph)
        let boundary = try session.execute(try StructuralFixtures.boundaryFixture().graph)
        XCTAssertEqual(post.bytes, boundary.bytes, "post-roll held frame equals the boundary (last-instant) frame")
    }

    // MARK: - M-7/M-14: with-reference path + approved root unchanged

    func testWithReferenceComparesButNeverWritesApprovedRoot() throws {
        let device0 = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device0)
        // Render one structural fixture to get a candidate, write an approved reference from it (by the
        // TEST), then run the recorder with the reference store and assert exact-match + root unchanged.
        let fx = try StructuralFixtures.maskFixture()
        let frame = try session.execute(fx.graph)
        let cand = CandidateFrame(candidateID: "ref-case", frame: frame,
                                  source: CandidateSource(catalogID: fx.catalogID, blockID: fx.blockID, variantID: fx.variantID, projectTimeTicks: 0, configHash: "c", graphHash: try fx.graph.graphHash()))
        let parent = try tempDir("withref")
        let refRoot = parent.appendingPathComponent("approved")
        try FileManager.default.createDirectory(at: refRoot.appendingPathComponent("references"), withIntermediateDirectories: true)
        let store = ReferenceStore(rootURL: refRoot)
        try DeterministicPNGEncoder.encode(frame).write(to: store.referenceURL(for: "ref-case"))
        let before = try Data(contentsOf: store.referenceURL(for: "ref-case"))

        let run = try makeRun(parent, fileSystem: DefaultRunFileSystem(), runID: "withref-run")
        let manifest = try EvidenceRecorder().record(
            candidates: [cand], referenceStore: store, policy: defaultPolicy(),
            into: run, engineConfiguration: minimalEngineConfig(), deviceInfo: device)
        XCTAssertEqual(manifest.candidates.first?.verdict, "exactMatch", "candidate equals its own reference")
        let after = try Data(contentsOf: store.referenceURL(for: "ref-case"))
        XCTAssertEqual(before, after, "approved reference root byte-identical (no self-blessing / no write)")
    }

    // MARK: - M-12: transactional fault poisons the run; nothing published

    func testInjectedFaultDuringMatrixPoisonsRun() throws {
        let device0 = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device0)
        let parent = try tempDir("fault")
        // The first written supplemental in the first group is a candidate PNG; fault its deterministic
        // leaf name (the first full_image candidate PNG).
        let firstRow = try RealTemplateMatrix.enumerateRows(scenesRootURL: scenesRoot()).first { $0.catalogID == "full_image" }!
        // The candidate id derives only from catalog/block/variant/projectTime (config/graph hashes do not
        // affect it), so dummy hashes here still reproduce the driver's id for the first row.
        let firstID = CandidateIdentity.candidateID(for: CandidateSource(
            catalogID: firstRow.catalogID, blockID: firstRow.blockID, variantID: "\(firstRow.variantID)-\(firstRow.frameKind)",
            projectTimeTicks: firstRow.projectTimeTicks, configHash: "x", graphHash: "y"))
        let faultFS = FaultInjectingRunFileSystem(faults: [
            .init(.artifact(operation: .writeSupplementalFileExclusively, artifactFileName: "\(firstID).png"))
        ])
        let run = try makeRun(parent, fileSystem: faultFS, runID: "fault-run")
        let driver = MatrixDriver(scenesRootURL: scenesRoot(), referenceStore: nil, configuration: try config(), policy: defaultPolicy())
        XCTAssertThrowsError(try driver.run(session: session, into: run, engineConfiguration: minimalEngineConfig(), deviceInfo: device)) { error in
            switch error {
            case BenchmarkRunError.ioFailure, BenchmarkRunError.runPreviouslyFailed: break
            default: XCTFail("expected a typed BenchmarkRunError, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directoryURL.path), "poisoned matrix run publishes nothing")
    }

    // MARK: - M-13: same-device matrix repeatability (candidate IDs + PNG bytes)

    func testMatrixCandidateIDsAndPNGsAreRepeatable() throws {
        let device0 = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device0)
        // Render the first full_image row twice → identical id + identical PNG bytes.
        let row = try RealTemplateMatrix.enumerateRows(scenesRootURL: scenesRoot()).first { $0.catalogID == "full_image" }!
        func gen() throws -> CandidateFrame {
            let c = try RealTemplateMatrix.compile(row: row, scenesRootURL: scenesRoot(), configuration: try config())
            return try CandidateGenerator.generate(graph: c.graph, session: session,
                catalogID: row.catalogID, blockID: row.blockID, variantID: row.variantID, projectTimeTicks: row.projectTimeTicks, configHash: c.configHash)
        }
        let a = try gen(), b = try gen()
        XCTAssertEqual(a.candidateID, b.candidateID, "deterministic candidate id")
        XCTAssertEqual(try DeterministicPNGEncoder.encode(a.frame), try DeterministicPNGEncoder.encode(b.frame), "deterministic candidate PNG")
    }
}
