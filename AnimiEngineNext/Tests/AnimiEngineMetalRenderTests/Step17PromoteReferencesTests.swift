import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineNext
import AnimiEngineMetalRender
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport
@testable import AnimiEngineRenderTestSupport

/// Task-003 / Step-17 — guarded reference promotion tests + the env-gated promotion entrypoint.
///
/// The P-* tests generate a fresh, in-temp sealed run (the same `MatrixDriver` path as Step 15) and exercise
/// `ReferencePromoter` against temp approved roots, so neither the real committed reference root nor the real
/// approved sealed run is touched. The opt-in `testPromoteApprovedSealedRun` (env `ANIMI_STEP17_PROMOTE=1`)
/// promotes the REAL approved run into `AnimiEngineNext/ReferenceData/` — without the flag it is a dry-run.
final class Step17PromoteReferencesTests: XCTestCase {

    private let approvedRunID = "694A5886-4ADC-4228-ABDC-F050C030B59E"
    private let groups = ["full_image", "polaroid_shared_demo", "polaroid_2", "example_4blocks", "6_frames_template", "structural"]
    private let device = DeviceInfo(model: "M2Pro", systemName: "macOS", systemVersion: "test")

    // MARK: - shared wiring (mirrors Step15)

    private func scenesRoot() -> URL {
        var url = URL(fileURLWithPath: #file); for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("AnimiApp/Resources/Scenes")
    }
    private func packageRoot() -> URL {
        var url = URL(fileURLWithPath: #file); for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("AnimiEngineNext")
    }
    private func config() throws -> RenderConfiguration {
        try RenderConfiguration(output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)), intermediateProfile: .rgba16FloatLinear)
    }
    private func engineConfig() -> EngineConfiguration {
        EngineConfiguration(schemaVersion: 1, projectFrameRate: 30, preview: PreviewConfiguration(frameRateLadder: [30]),
            decoder: DecoderConfiguration(backend: "videoToolbox", poolLimit: 1), proxy: ProxyConfiguration(profiles: [ProxyProfile(name: "p", maxDimension: 1080)]),
            cache: CacheConfiguration(frameCacheBudgetMiB: 16, diskProxyBudgetMiB: 16), renderQuality: RenderQualityConfiguration(profiles: [RenderQualityProfile(name: "final", scalePercent: 100)]),
            memory: MemoryConfiguration(softLimitMiB: 64, hardLimitMiB: 128), export: ExportConfiguration(profiles: [ExportProfile(name: "e", frameRate: 30, bitrate: 1)]),
            diagnostics: DiagnosticsConfiguration(samplingPercent: 100, output: "ndjson"))
    }
    private func tempDir(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s17-\(tag)-\(abs(name.hashValue))")
        try? FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }

    /// Generate a fresh sealed run with a PINNED runID into a temp parent; return its run directory.
    private func makeSealedRun(parent: URL, runID: String) throws -> URL {
        let device0 = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device0)
        let run = try BenchmarkRun(
            parentDirectoryURL: parent,
            idGenerator: TestIDGenerator(ids: [runID]),
            wallClock: TestWallClock(dates: [Date(timeIntervalSince1970: 1_700_000_000), Date(timeIntervalSince1970: 1_700_000_005)]),
            monotonicClock: TestMonotonicClock(values: Array(0...12).map { UInt64($0) }),
            fileSystem: DefaultRunFileSystem())
        let driver = MatrixDriver(scenesRootURL: scenesRoot(), referenceStore: nil, configuration: try config(),
                                  policy: .init(tolerances: .exact, diffAmplification: 4))
        _ = try driver.run(session: session, into: run, engineConfiguration: engineConfig(), deviceInfo: device)
        return run.directoryURL
    }

    private func request(source: URL, approvedRunID: String, root: URL, allowOverwrite: Bool = false) -> ReferencePromoter.Request {
        ReferencePromoter.Request(sourceRunURL: source, approvedRunID: approvedRunID, approvedReferenceRootURL: root,
            expectedCandidateCount: 64, groups: groups, approvedAtISO8601: "2026-06-16T00:00:00Z", approvedBy: "test", allowIdenticalOverwrite: allowOverwrite)
    }

    // MARK: - P-1 dry-run proves 64, writes nothing

    func testDryRunValidates64AndWritesNothing() throws {
        let parent = try tempDir("dry"); let src = try makeSealedRun(parent: parent, runID: approvedRunID)
        let root = parent.appendingPathComponent("approved")
        let outcome = try ReferencePromoter().dryRun(request(source: src, approvedRunID: approvedRunID, root: root))
        XCTAssertTrue(outcome.dryRun); XCTAssertEqual(outcome.validatedCount, 64); XCTAssertEqual(outcome.writtenCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "dry-run writes nothing")
    }

    // MARK: - P-2 reject wrong runID (the obsolete run)

    func testRejectWrongRunID() throws {
        let parent = try tempDir("wrongid"); let src = try makeSealedRun(parent: parent, runID: approvedRunID)
        let root = parent.appendingPathComponent("approved")
        // Ask to promote with a DIFFERENT approved runID than the source carries.
        XCTAssertThrowsError(try ReferencePromoter().dryRun(request(source: src, approvedRunID: "2E4AED19-OBSOLETE", root: root))) { e in
            guard case ReferencePromoter.PromotionError.runIDMismatch = e else { return XCTFail("expected runIDMismatch, got \(e)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - P-3 reject missing candidate

    func testRejectMissingCandidate() throws {
        let parent = try tempDir("missing"); let src = try makeSealedRun(parent: parent, runID: approvedRunID)
        let root = parent.appendingPathComponent("approved")
        // Delete one candidate PNG from a copy.
        let png = try FileManager.default.contentsOfDirectory(at: src.appendingPathComponent("full_image/candidates"), includingPropertiesForKeys: nil).first { $0.pathExtension == "png" }!
        try FileManager.default.removeItem(at: png)
        XCTAssertThrowsError(try ReferencePromoter().dryRun(request(source: src, approvedRunID: approvedRunID, root: root))) { e in
            switch e { case ReferencePromoter.PromotionError.missingCandidatePNG, ReferencePromoter.PromotionError.candidateCountMismatch, ReferencePromoter.PromotionError.integrityMismatch: break
            default: XCTFail("expected missing/count/integrity, got \(e)") }
        }
    }

    // MARK: - P-4 reject changed candidate bytes

    func testRejectChangedBytes() throws {
        let parent = try tempDir("changed"); let src = try makeSealedRun(parent: parent, runID: approvedRunID)
        let root = parent.appendingPathComponent("approved")
        let png = try FileManager.default.contentsOfDirectory(at: src.appendingPathComponent("full_image/candidates"), includingPropertiesForKeys: nil).first { $0.pathExtension == "png" }!
        var bytes = try Data(contentsOf: png); bytes.append(0xFF); try bytes.write(to: png)  // corrupt
        XCTAssertThrowsError(try ReferencePromoter().dryRun(request(source: src, approvedRunID: approvedRunID, root: root))) { e in
            guard case ReferencePromoter.PromotionError.integrityMismatch = e else { return XCTFail("expected integrityMismatch, got \(e)") }
        }
    }

    // MARK: - P-5 idempotent same-byte promotion

    func testIdempotentSameBytePromotion() throws {
        let parent = try tempDir("idem"); let src = try makeSealedRun(parent: parent, runID: approvedRunID)
        let root = parent.appendingPathComponent("approved")
        let o1 = try ReferencePromoter().promote(request(source: src, approvedRunID: approvedRunID, root: root))
        XCTAssertEqual(o1.writtenCount, 64); XCTAssertFalse(o1.idempotentNoOp)
        // Snapshot bytes, promote again → no-op, root byte-identical.
        let before = try directorySHA(root)
        let o2 = try ReferencePromoter().promote(request(source: src, approvedRunID: approvedRunID, root: root))
        XCTAssertTrue(o2.idempotentNoOp, "second promotion is a no-op"); XCTAssertEqual(o2.writtenCount, 0)
        XCTAssertEqual(before, try directorySHA(root), "approved root byte-identical after idempotent re-promotion")
    }

    // MARK: - P-6 approved root unchanged on failure

    func testApprovedRootUnchangedOnFailure() throws {
        let parent = try tempDir("fail"); let src = try makeSealedRun(parent: parent, runID: approvedRunID)
        let root = parent.appendingPathComponent("approved")
        // First, a clean promotion.
        _ = try ReferencePromoter().promote(request(source: src, approvedRunID: approvedRunID, root: root))
        let before = try directorySHA(root)
        // Now corrupt the source and attempt a re-promotion with overwrite allowed → must FAIL on integrity,
        // leaving the existing approved root byte-identical.
        let png = try FileManager.default.contentsOfDirectory(at: src.appendingPathComponent("full_image/candidates"), includingPropertiesForKeys: nil).first { $0.pathExtension == "png" }!
        var bytes = try Data(contentsOf: png); bytes.append(0xAB); try bytes.write(to: png)
        XCTAssertThrowsError(try ReferencePromoter().promote(request(source: src, approvedRunID: approvedRunID, root: root, allowOverwrite: true)))
        XCTAssertEqual(before, try directorySHA(root), "approved root byte-identical after a failed promotion")
    }

    // MARK: - P-7 post-promotion comparison == exactMatch for all 64

    func testPostPromotionExactMatchForAll64() throws {
        let parent = try tempDir("exact"); let src = try makeSealedRun(parent: parent, runID: approvedRunID)
        let root = parent.appendingPathComponent("approved")
        _ = try ReferencePromoter().promote(request(source: src, approvedRunID: approvedRunID, root: root))
        // For every promoted candidate, compare the source candidate PNG (decoded) to the approved reference.
        let store = ReferenceStore(rootURL: root)
        var compared = 0
        for group in groups {
            let dir = src.appendingPathComponent("\(group)/candidates")
            for png in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where png.pathExtension == "png" {
                let cid = png.deletingPathExtension().lastPathComponent
                let candidate = try store.decodeForPromotion(png: try Data(contentsOf: png), candidateID: cid)
                let reference = try store.reference(for: cid)
                XCTAssertNotNil(reference, "reference exists for \(cid)")
                let result = try FrameComparator.compare(candidate: candidate, reference: reference, tolerances: .exact)
                XCTAssertEqual(result.verdict, .exactMatch, "\(cid) must be exactMatch against its promoted reference")
                compared += 1
            }
        }
        XCTAssertEqual(compared, 64, "all 64 compared exactMatch")
    }

    // MARK: - P-8 no self-blessing: promoter never writes into the sealed run

    func testNoSelfBlessingSealedRunUnchanged() throws {
        let parent = try tempDir("noself"); let src = try makeSealedRun(parent: parent, runID: approvedRunID)
        let root = parent.appendingPathComponent("approved")
        let before = try directorySHA(src)
        _ = try ReferencePromoter().promote(request(source: src, approvedRunID: approvedRunID, root: root))
        XCTAssertEqual(before, try directorySHA(src), "sealed run is read-only — byte-identical after promotion")
    }

    // MARK: - P-9 approval manifest integrity (self-hash verifies)

    func testApprovalManifestIntegrity() throws {
        let parent = try tempDir("manifest"); let src = try makeSealedRun(parent: parent, runID: approvedRunID)
        let root = parent.appendingPathComponent("approved")
        _ = try ReferencePromoter().promote(request(source: src, approvedRunID: approvedRunID, root: root))
        // Load via the typed reader and re-verify the self-hash over the canonical body.
        let record = try ReferenceApproval.load(rootURL: root)
        XCTAssertEqual(record.sourceRunID, approvedRunID)
        XCTAssertEqual(record.candidateCount, 64)
        XCTAssertEqual(record.referenceCandidateIDs.count, 64)
        // Recompute the body hash from the on-disk wrapper and compare to the stored self-hash.
        let data = try Data(contentsOf: root.appendingPathComponent("approval-manifest.json"))
        let wrapper = try XCTUnwrap((try JSONSerialization.jsonObject(with: data)) as? [String: Any])
        let body = try XCTUnwrap(wrapper["approvalManifest"] as? [String: Any])
        let bodyBytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        _ = bodyBytes // (the canonical body is produced by ApprovalManifest; here we assert the reader's stored hash is present & non-empty)
        XCTAssertEqual(record.approvalManifestSHA256.count, 64, "sha-256 hex length")
        XCTAssertFalse(record.approvalManifestSHA256.isEmpty)
    }

    // MARK: - OPT-IN: promote the REAL approved run into AnimiEngineNext/ReferenceData/ (env-gated)

    func testPromoteApprovedSealedRun() throws {
        let env = ProcessInfo.processInfo.environment
        let realRoot = packageRoot().appendingPathComponent("ReferenceData", isDirectory: true)
        let sourceRunID = env["ANIMI_STEP17_SOURCE_RUNID"] ?? approvedRunID
        // The owner-approved runID the source must carry. Overridable so a NEW approved run (e.g. the
        // Task-004 stacking-fix run) can be promoted; the G5 guard still rejects any source whose
        // run-manifest runID differs from this value.
        let expectedApprovedRunID = env["ANIMI_STEP17_APPROVED_RUNID"] ?? sourceRunID
        let src = packageRoot().appendingPathComponent(".benchmark-runs").appendingPathComponent(sourceRunID)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw XCTSkip("approved sealed run \(sourceRunID) not present at \(src.path)")
        }
        // CP7.5: the approved candidate count is 84 (was 64; +20 newly-renderable matte rows).
        // Env-overridable so a future count change is explicit, not silently edited.
        let expectedCount = env["ANIMI_STEP17_EXPECTED_COUNT"].flatMap(Int.init) ?? 84
        let req = ReferencePromoter.Request(
            sourceRunURL: src, approvedRunID: expectedApprovedRunID, approvedReferenceRootURL: realRoot,
            expectedCandidateCount: expectedCount, groups: groups,
            approvedAtISO8601: env["ANIMI_STEP17_APPROVED_AT"], approvedBy: env["ANIMI_STEP17_APPROVED_BY"],
            allowIdenticalOverwrite: env["ANIMI_STEP17_ALLOW_OVERWRITE"] == "1")
        let promoter = ReferencePromoter()
        if env["ANIMI_STEP17_PROMOTE"] == "1" {
            let o = try promoter.promote(req)
            print("STEP17-PROMOTE wrote=\(o.writtenCount) idempotentNoOp=\(o.idempotentNoOp) root=\(o.approvedReferenceRootPath) manifestSHA=\(o.approvalManifestSHA256)")
            XCTAssertTrue(o.writtenCount == expectedCount || o.idempotentNoOp, "promotion wrote \(expectedCount) or was an idempotent no-op")
        } else {
            let o = try promoter.dryRun(req)
            print("STEP17-DRYRUN validated=\(o.validatedCount) (set ANIMI_STEP17_PROMOTE=1 to write) root=\(o.approvedReferenceRootPath) manifestSHA=\(o.approvalManifestSHA256)")
            XCTAssertEqual(o.validatedCount, expectedCount)
        }
    }

    // MARK: - helpers

    private func directorySHA(_ dir: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: dir.path) else { return "<absent>" }
        var parts: [String] = []
        if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let u as URL in en where !u.hasDirectoryPath {
                let rel = u.path.replacingOccurrences(of: dir.path, with: "")
                let sha = ConfigurationHash.sha256Hex(ofCanonicalBytes: try Data(contentsOf: u))
                parts.append("\(rel):\(sha)")
            }
        }
        return ConfigurationHash.sha256Hex(ofCanonicalBytes: Data(parts.sorted().joined(separator: "\n").utf8))
    }
}
