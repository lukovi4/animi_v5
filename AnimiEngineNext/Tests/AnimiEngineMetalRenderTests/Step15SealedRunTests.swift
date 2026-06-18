import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineNext
import AnimiEngineMetalRender
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport
@testable import AnimiEngineRenderTestSupport

/// Task-003 / Step-15 — **produce a sealed candidate-reference benchmark run** (plan
/// `claude-task-003-step-15-plan.md`, owner-approved D1–D7).
///
/// This is the runnable producer seam (D1: a producer XCTest in the existing target — no new target, no
/// `Package.swift` change). It drives the **accepted** Step-14 `MatrixDriver` + Step-13 `EvidenceRecorder`
/// into ONE `BenchmarkRun`, wired with the **production** seams (`UUIDRunIDGenerator` D2, `SystemWallClock`,
/// `SystemMonotonicClock`, `DefaultRunFileSystem` via the public `BenchmarkRun` initializer), `referenceStore:
/// nil` (D4 — no approved reference root exists), the Step-14 minimal engine config + 1080×1920 / 30-1 /
/// rgba16FloatLinear render config (D5), and honest host `DeviceInfo` (D6). Step 15 adds NO new evidence
/// primitive and changes NO RenderGraph/canonical/payload contract.
///
/// Two entry points:
///   * `testProduceSealedCandidateReferenceRun` — the ordinary `swift test` path: writes to a **temp** output
///     root and asserts the full §6 validation (V-1…V-10), candidate count == 64 (a mismatch FAILs the test
///     with the per-scene breakdown — STOP #2), no staging dir, no references/diffs, no approved-root write.
///   * The **explicit production command** writes to the durable root `AnimiEngineNext/.benchmark-runs/`
///     (D3, git-ignored): set `ANIMI_STEP15_DURABLE_ROOT=1` (the same test then targets the durable root and
///     prints the exact sealed run path + runID).
///
/// No reference is promoted; no approved-reference root is written; no self-blessing; no Step-16 work.
final class Step15SealedRunTests: XCTestCase {

    // MARK: - Wiring (mirrors the accepted Step14MatrixTests, with PRODUCTION seams)

    /// The repository `AnimiApp/Resources/Scenes` directory (read-only template source). Mirrors
    /// `Step14MatrixTests.scenesRoot()`: Tests/AnimiEngineMetalRenderTests/<file> → 4 up → repo root.
    private func scenesRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("AnimiApp/Resources/Scenes")
    }

    /// The repository `AnimiEngineNext` directory (the package root), derived the same way as `scenesRoot()`.
    private func packageRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }   // → repo root
        return url.appendingPathComponent("AnimiEngineNext")
    }

    /// D5: reuse the exact Step-14 render configuration (1080×1920, 30/1, rgba16FloatLinear).
    private func config() throws -> RenderConfiguration {
        try RenderConfiguration(
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)),
            intermediateProfile: .rgba16FloatLinear)
    }

    /// D5: reuse the exact Step-14 minimal engine configuration.
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

    /// D6: honest host `DeviceInfo` for the M2 Pro sealed run (NOT the Step-14 test placeholder `"test"`).
    private func hostDeviceInfo() -> DeviceInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceInfo(
            model: "M2Pro",
            systemName: "macOS",
            systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    /// The Step-14 default policy (exact tolerances, diff amplification 4).
    private func policy() -> EvidenceRecorder.Policy { .init(tolerances: .exact, diffAmplification: 4) }

    /// The owner-pinned expected candidate count (plan §6.1). A mismatch is a STOP (#2): the test FAILs and
    /// prints the per-scene frame-time/skip breakdown rather than silently changing this number.
    private let expectedCandidateCount = 64

    // MARK: - The producer

    func testProduceSealedCandidateReferenceRun() throws {
        let device0 = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device0)

        // D3: the ordinary `swift test` run writes to a temp root; the explicit production command writes to
        // the durable git-ignored root `AnimiEngineNext/.benchmark-runs/`.
        let durable = ProcessInfo.processInfo.environment["ANIMI_STEP15_DURABLE_ROOT"] == "1"
        let outputRoot: URL
        if durable {
            outputRoot = packageRoot().appendingPathComponent(".benchmark-runs", isDirectory: true)
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        } else {
            outputRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("s15-sealed-\(abs(name.hashValue))", isDirectory: true)
            try? FileManager.default.removeItem(at: outputRoot)
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        }

        // Production seams: UUID run-ID (D2), system clocks, DefaultRunFileSystem (via the public initializer).
        let run = try BenchmarkRun(
            parentDirectoryURL: outputRoot,
            idGenerator: UUIDRunIDGenerator(),
            wallClock: SystemWallClock(),
            monotonicClock: SystemMonotonicClock())
        let runID = run.runID.rawValue

        // Drive the ACCEPTED Step-14 matrix; D4: no reference store → candidateOnly everywhere.
        let driver = MatrixDriver(
            scenesRootURL: scenesRoot(), referenceStore: nil,
            configuration: try config(), policy: policy())
        let result = try driver.run(
            session: session, into: run,
            engineConfiguration: minimalEngineConfig(), deviceInfo: hostDeviceInfo())

        let sealedRunPath = result.runDirectoryURL.path

        // ---- V-3 / STOP #2: candidate count must be EXACTLY 64. -------------------------------------------
        if result.candidateCount != expectedCandidateCount {
            let breakdown = try Self.frameTimeBreakdown(scenesRootURL: scenesRoot(), configuration: try config())
            XCTFail("""
                STOP #2 — candidate count \(result.candidateCount) != expected \(expectedCandidateCount). \
                real=\(result.realRowCount) skipped=\(result.skippedRowCount) structural=\(result.structuralRowCount) \
                enumerated=\(result.enumeratedRowCount). Per-scene frame-time breakdown:
                \(breakdown)
                The matrix changed; the owner must reconcile. NOT silently editing 64.
                """)
            return
        }
        XCTAssertEqual(result.candidateCount, expectedCandidateCount, "exactly 64 candidates")
        XCTAssertEqual(result.structuralRowCount, 9, "nine structural fixtures")
        XCTAssertEqual(result.realRowCount + result.structuralRowCount, result.candidateCount, "no duplicate candidate IDs")
        XCTAssertEqual(result.realRowCount + result.skippedRowCount, result.enumeratedRowCount, "every enumerated row rendered or deterministically skipped")

        let dir = result.runDirectoryURL
        let fm = FileManager.default

        // ---- V-1: run sealed; no staging dir remains. ---------------------------------------------------
        XCTAssertTrue(fm.fileExists(atPath: dir.path), "final sealed run directory exists")
        let parentContents = try fm.contentsOfDirectory(atPath: outputRoot.path)
        let stagingLeftovers = parentContents.filter { $0.hasPrefix(".") && $0.hasSuffix(".staging") }
        XCTAssertTrue(stagingLeftovers.isEmpty, "no .<runID>.staging directory remains after success: \(stagingLeftovers)")

        // ---- V-2: run-manifest.json present and last; aggregate covers all supplemental artifacts. -------
        let runManifestURL = dir.appendingPathComponent(RunArtifact.runManifest.rawValue)
        let artifactsManifestURL = dir.appendingPathComponent(RunArtifact.supplementalManifest)
        XCTAssertTrue(fm.fileExists(atPath: runManifestURL.path), "run-manifest.json (commit marker) present")
        XCTAssertTrue(fm.fileExists(atPath: artifactsManifestURL.path), "artifacts-manifest.json (supplemental aggregate) present")
        let runManifestText = try String(contentsOf: runManifestURL, encoding: .utf8)
        let artifactsManifestBytes = try Data(contentsOf: artifactsManifestURL)
        let aggregateHash = ConfigurationHash.sha256Hex(ofCanonicalBytes: artifactsManifestBytes)
        XCTAssertTrue(runManifestText.contains("\"supplementalArtifactsSHA256\":\"\(aggregateHash)\""),
                      "run-manifest.json's supplementalArtifactsSHA256 == SHA-256(artifacts-manifest.json) — aggregate covers all matrix artifacts")

        // ---- V-4 / V-5: every group has render-manifest.json + contact-sheet.png. ------------------------
        for group in RealTemplateMatrix.catalogs + ["structural"] {
            XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("\(group)/render-manifest.json").path), "\(group) render-manifest.json")
            XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("\(group)/contact-sheet.png").path), "\(group) contact-sheet.png")
        }

        // ---- V-6 / V-7 / V-8 / V-9: per-candidate PNG + comparison JSON; candidateOnly; no refs/diffs. ---
        var perGroupCandidatePNGs: [String: Int] = [:]
        var perGroupComparisonJSON: [String: Int] = [:]
        var totalCandidates = 0
        for (group, manifest) in result.groupManifests {
            XCTAssertFalse(manifest.candidates.isEmpty, "\(group) has candidates")
            for entry in manifest.candidates {
                totalCandidates += 1
                // V-6: candidate PNG.
                XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(entry.candidateArtifact).path), "\(group) candidate PNG \(entry.candidateID)")
                perGroupCandidatePNGs[group, default: 0] += 1
                // V-7: comparison JSON + candidateOnly verdict.
                XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(entry.comparisonArtifact).path), "\(group) comparison JSON \(entry.candidateID)")
                perGroupComparisonJSON[group, default: 0] += 1
                XCTAssertEqual(entry.verdict, "candidateOnly", "\(group) verdict candidateOnly")
                // V-8: no reference snapshot / diff produced without an approved reference.
                XCTAssertNil(entry.referenceArtifact, "\(group) no reference snapshot without approved refs")
                XCTAssertNil(entry.diffArtifact, "\(group) no diff without approved refs")
            }
        }
        XCTAssertEqual(totalCandidates, expectedCandidateCount, "manifest entries total 64")

        // V-8 (filesystem): NO references/ or diffs/ directory under any group.
        for group in RealTemplateMatrix.catalogs + ["structural"] {
            XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("\(group)/references").path), "\(group) has NO references/ dir")
            XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("\(group)/diffs").path), "\(group) has NO diffs/ dir")
        }

        // ---- Print the sealed-run facts (required report fields) -----------------------------------------
        let groupCounts = (RealTemplateMatrix.catalogs + ["structural"])
            .map { "\($0)=\(perGroupCandidatePNGs[$0] ?? 0)png/\(perGroupComparisonJSON[$0] ?? 0)json" }
            .joined(separator: " ")
        print("""
            STEP15-SEALED-RUN
            sealedRunPath: \(sealedRunPath)
            runID: \(runID)
            durableRoot: \(durable)
            candidateCount: \(result.candidateCount)
            realRowCount: \(result.realRowCount)
            skippedRowCount: \(result.skippedRowCount)
            structuralRowCount: \(result.structuralRowCount)
            enumeratedRowCount: \(result.enumeratedRowCount)
            perGroupArtifacts: \(groupCounts)
            supplementalAggregateSHA256: \(aggregateHash)
            stagingLeftovers: \(stagingLeftovers.count)
            END-STEP15-SEALED-RUN
            """)
    }

    // MARK: - V-3 STOP breakdown helper (only used when the count differs)

    /// Per-scene frame-time + skip breakdown — printed ONLY on a count mismatch (STOP #2) so the owner can
    /// reconcile. Pure read of the same accepted enumeration/compile path the driver uses.
    static func frameTimeBreakdown(scenesRootURL: URL, configuration: RenderConfiguration) throws -> String {
        let rows = try RealTemplateMatrix.enumerateRows(scenesRootURL: scenesRootURL)
        var lines: [String] = []
        for catalogID in RealTemplateMatrix.catalogs {
            let catalogRows = rows.filter { $0.catalogID == catalogID }
            var renderable = 0, skipped = 0
            for row in catalogRows {
                switch try RealTemplateMatrix.compileOutcome(row: row, scenesRootURL: scenesRootURL, configuration: configuration) {
                case .renderable: renderable += 1
                case .skippedInactive: skipped += 1
                }
            }
            let kinds = Set(catalogRows.map { $0.frameKind }).sorted().joined(separator: ",")
            lines.append("  \(catalogID): enumerated=\(catalogRows.count) renderable=\(renderable) skipped=\(skipped) frameKinds=[\(kinds)]")
        }
        return lines.joined(separator: "\n")
    }
}
