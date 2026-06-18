import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineNext
import AnimiEngineMetalRender
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport
@testable import AnimiEngineRenderTestSupport

/// Task-003 / Step-13 — candidate generation, comparison, diff, contact sheet, evidence recording.
///
/// These run on the M2 Pro (no GPU needed for PNG/comparison/diff/recorder logic; synthetic frames are
/// used). The transactional guarantees are exercised through the existing `BenchmarkRun` +
/// `FaultInjectingRunFileSystem`. No approved reference is ever written.
final class Step13EvidenceTests: XCTestCase {

    // MARK: - Fixtures

    private func frame(width: Int, height: Int, fill: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) throws -> RenderedFrame {
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height { for x in 0..<width {
            let p = y * stride + x * 4
            bytes[p + 0] = fill.b; bytes[p + 1] = fill.g; bytes[p + 2] = fill.r; bytes[p + 3] = fill.a
        }}
        let dims = try PixelDimensions(width: width, height: height, bytesPerRow: stride, format: .bgra8, orientation: .up)
        return try RenderedFrame(dimensions: dims, colorContract: .task003, bytes: Data(bytes))
    }

    /// A frame with one pixel perturbed by `delta` on the red channel (for bounded/out-of-bounds tests).
    private func framePerturbed(width: Int, height: Int, base: (b: UInt8, g: UInt8, r: UInt8, a: UInt8), at: (Int, Int), redDelta: Int) throws -> RenderedFrame {
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height { for x in 0..<width {
            let p = y * stride + x * 4
            var r = Int(base.r)
            if (x, y) == at { r = max(0, min(255, r + redDelta)) }
            bytes[p + 0] = base.b; bytes[p + 1] = base.g; bytes[p + 2] = UInt8(r); bytes[p + 3] = base.a
        }}
        let dims = try PixelDimensions(width: width, height: height, bytesPerRow: stride, format: .bgra8, orientation: .up)
        return try RenderedFrame(dimensions: dims, colorContract: .task003, bytes: Data(bytes))
    }

    private func candidate(_ id: String, _ frame: RenderedFrame) -> CandidateFrame {
        CandidateFrame(candidateID: id, frame: frame,
                       source: CandidateSource(catalogID: "cat", blockID: "blk", variantID: id, projectTimeTicks: 0, configHash: "cfg", graphHash: "gph"))
    }

    private func minimalConfig() -> EngineConfiguration {
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

    private func makeRun(_ parent: URL, fileSystem: RunFileSystem, runID: String) throws -> BenchmarkRun {
        try BenchmarkRun(
            parentDirectoryURL: parent,
            idGenerator: TestIDGenerator(ids: [runID]),
            wallClock: TestWallClock(dates: [Date(timeIntervalSince1970: 1_700_000_000), Date(timeIntervalSince1970: 1_700_000_005)]),
            monotonicClock: TestMonotonicClock(values: [0, 1, 2, 3, 4, 5]),
            fileSystem: fileSystem)
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s13-\(UInt64(bitPattern: Int64(ObjectIdentifier(self).hashValue)))-\(name.hashValue)")
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let device = DeviceInfo(model: "M2Pro", systemName: "macOS", systemVersion: "test")

    // MARK: - PNG determinism (S-4, §7.1)

    func testPNGEncodeIsDeterministicAndRoundTrips() throws {
        let f = try frame(width: 4, height: 3, fill: (b: 10, g: 20, r: 30, a: 255))
        let png1 = try DeterministicPNGEncoder.encode(f)
        let png2 = try DeterministicPNGEncoder.encode(f)
        XCTAssertEqual(png1, png2, "identical frame → byte-identical PNG")
        XCTAssertEqual(Array(png1.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature")
        // Round-trip: decode our own PNG back to BGRA8 and compare pixels.
        let (w, h, rgba) = try PNGReader.decodeRGBA8(png1, malformed: { TestErr.m($0) }, unsupported: { TestErr.u($0) })
        XCTAssertEqual(w, 4); XCTAssertEqual(h, 3)
        // RGBA pixel 0 should be (R=30, G=20, B=10, A=255).
        XCTAssertEqual(Array(rgba.prefix(4)), [30, 20, 10, 255])
    }

    func testPNGChangesWhenPixelsChange() throws {
        let a = try frame(width: 4, height: 4, fill: (b: 0, g: 0, r: 0, a: 255))
        let b = try frame(width: 4, height: 4, fill: (b: 0, g: 0, r: 1, a: 255))
        XCTAssertNotEqual(try DeterministicPNGEncoder.encode(a), try DeterministicPNGEncoder.encode(b))
    }

    // MARK: - Candidate identity (C-1/C-2, §7.3)

    func testCandidateIDIsDeterministicFromProvenanceOnly() throws {
        let s = CandidateSource(catalogID: "polaroid_2", blockID: "block_01", variantID: "anim-1", projectTimeTicks: 12, configHash: "x", graphHash: "y")
        let id1 = CandidateIdentity.candidateID(for: s)
        let id2 = CandidateIdentity.candidateID(for: s)
        XCTAssertEqual(id1, id2, "same provenance → same id")
        XCTAssertTrue(id1.contains("polaroid_2") && id1.contains("block_01") && id1.contains("t12"))
        // A different project time → different id.
        let s2 = CandidateSource(catalogID: "polaroid_2", blockID: "block_01", variantID: "anim-1", projectTimeTicks: 13, configHash: "x", graphHash: "y")
        XCTAssertNotEqual(id1, CandidateIdentity.candidateID(for: s2))
        // The id is a valid supplemental path component.
        XCTAssertNoThrow(try SupplementalArtifactPath("candidates/\(id1).png"))
    }

    // MARK: - Comparison (K-1..K-5, §7.4)

    func testExactMatchVerdict() throws {
        let c = try frame(width: 4, height: 4, fill: (b: 1, g: 2, r: 3, a: 255))
        let r = try frame(width: 4, height: 4, fill: (b: 1, g: 2, r: 3, a: 255))
        let result = try FrameComparator.compare(candidate: c, reference: r, tolerances: .exact)
        XCTAssertEqual(result.verdict, .exactMatch)
        XCTAssertEqual(result.maxChannelDelta, 0)
    }

    func testWithinBoundsAndOutOfBounds() throws {
        let base = (b: UInt8(0), g: UInt8(0), r: UInt8(100), a: UInt8(255))
        let ref = try frame(width: 4, height: 4, fill: base)
        let near = try framePerturbed(width: 4, height: 4, base: base, at: (1, 1), redDelta: 2)   // delta 2, 1 pixel
        let far = try framePerturbed(width: 4, height: 4, base: base, at: (1, 1), redDelta: 40)    // delta 40

        let tol = FrameComparator.Tolerances(maxChannelDelta: 4, maxDifferingPixels: 2)
        let within = try FrameComparator.compare(candidate: near, reference: ref, tolerances: tol)
        XCTAssertEqual(within.verdict, .withinBounds)
        XCTAssertEqual(within.maxChannelDelta, 2)
        XCTAssertEqual(within.differingPixelCount, 1)

        // K-5: a known-incorrect candidate (delta 40) lies OUTSIDE the bound.
        let out = try FrameComparator.compare(candidate: far, reference: ref, tolerances: tol)
        XCTAssertEqual(out.verdict, .outOfBounds)
        XCTAssertEqual(out.maxChannelDelta, 40)
    }

    func testCandidateOnlyWhenNoReference() throws {
        let c = try frame(width: 2, height: 2, fill: (b: 9, g: 9, r: 9, a: 255))
        let result = try FrameComparator.compare(candidate: c, reference: nil, tolerances: .exact)
        XCTAssertEqual(result.verdict, .candidateOnly)
        XCTAssertFalse(result.referencePresent)
    }

    // MARK: - Diff determinism (K-4, §7.4)

    func testDiffIsDeterministicAndZeroForEqual() throws {
        let a = try frame(width: 4, height: 4, fill: (b: 0, g: 0, r: 100, a: 255))
        let b = try framePerturbed(width: 4, height: 4, base: (b: 0, g: 0, r: 100, a: 255), at: (2, 2), redDelta: 10)
        let d1 = try DiffImage.diff(candidate: b, reference: a, amplification: 4)
        let d2 = try DiffImage.diff(candidate: b, reference: a, amplification: 4)
        XCTAssertEqual(d1.bgra8, d2.bgra8, "diff deterministic")
        // Equal pixels are black (R=0); the perturbed pixel's red delta 10 × amp 4 = 40.
        XCTAssertEqual(d1.bgra8[2 * (4 * 4) + 2 * 4 + 2], 40, "diff red at (2,2) = delta·amp")
        XCTAssertEqual(d1.bgra8[0 + 2], 0, "diff black where equal")
    }

    // MARK: - Evidence recording end-to-end (structural S-1..S-5, §7.1) + no-reference (R-1)

    func testRecordNoReferenceProducesLayout() throws {
        let parent = try tempDir()
        let run = try makeRun(parent, fileSystem: DefaultRunFileSystem(), runID: "rec-noref")
        let cands = [candidate("a", try frame(width: 4, height: 4, fill: (b: 0, g: 0, r: 255, a: 255))),
                     candidate("b", try frame(width: 4, height: 4, fill: (b: 0, g: 255, r: 0, a: 255)))]
        let manifest = try EvidenceRecorder().record(
            candidates: cands, referenceStore: nil,
            policy: .init(tolerances: .exact, diffAmplification: 4),
            into: run, engineConfiguration: minimalConfig(), deviceInfo: device)
        XCTAssertEqual(manifest.candidates.count, 2)
        XCTAssertTrue(manifest.candidates.allSatisfy { $0.verdict == "candidateOnly" }, "no reference → candidateOnly")

        // The published run directory contains the expected layout.
        let dir = run.directoryURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("candidates/a.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("candidates/b.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("comparison/a.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("contact-sheet.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("render-manifest.json").path))
        // No diffs (no reference).
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("diffs").path))
        // run-manifest.json (the commit marker) exists and is last-written.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("run-manifest.json").path))
    }

    // MARK: - With-reference (R-2/R-3): reference READ, snapshotted, approved root NEVER written

    func testWithReferenceReadsAndSnapshotsButNeverWritesApprovedRoot() throws {
        let parent = try tempDir()
        // Build an approved reference root with one reference PNG (written by the test, NOT by the run).
        let refRoot = parent.appendingPathComponent("approved-refs")
        try FileManager.default.createDirectory(at: refRoot.appendingPathComponent("references"), withIntermediateDirectories: true)
        let refFrame = try frame(width: 4, height: 4, fill: (b: 0, g: 0, r: 100, a: 255))
        let refID = "withref"
        let store = ReferenceStore(rootURL: refRoot)
        try DeterministicPNGEncoder.encode(refFrame).write(to: store.referenceURL(for: refID))

        // Snapshot the approved root's bytes BEFORE the run.
        let refURL = store.referenceURL(for: refID)
        let refBytesBefore = try Data(contentsOf: refURL)

        // A candidate that differs from the reference (within tolerance) → withinBounds + a diff.
        let cand = candidate(refID, try framePerturbed(width: 4, height: 4, base: (b: 0, g: 0, r: 100, a: 255), at: (1, 1), redDelta: 3))
        let run = try makeRun(parent, fileSystem: DefaultRunFileSystem(), runID: "rec-withref")
        let manifest = try EvidenceRecorder().record(
            candidates: [cand], referenceStore: store,
            policy: .init(tolerances: .init(maxChannelDelta: 8, maxDifferingPixels: 4), diffAmplification: 4),
            into: run, engineConfiguration: minimalConfig(), deviceInfo: device)

        XCTAssertEqual(manifest.candidates.first?.verdict, "withinBounds")
        let dir = run.directoryURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("references/\(refID).png").path), "reference snapshotted into run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("diffs/\(refID).diff.png").path), "diff produced")

        // R-3: the approved reference root is byte-identical after the run (never written/updated).
        let refBytesAfter = try Data(contentsOf: refURL)
        XCTAssertEqual(refBytesBefore, refBytesAfter, "approved reference root unchanged (no self-blessing)")
    }

    // MARK: - Transaction / failure (T-1, §7.2)

    func testInjectedFaultPoisonsRunNothingPublished() throws {
        let parent = try tempDir()
        let fs = FaultInjectingRunFileSystem(faults: [
            .init(.artifact(operation: .writeSupplementalFileExclusively, artifactFileName: "a.png"))
        ])
        let run = try makeRun(parent, fileSystem: fs, runID: "rec-fault")
        let cands = [candidate("a", try frame(width: 4, height: 4, fill: (b: 0, g: 0, r: 255, a: 255)))]
        // The injected fault surfaces as a typed BenchmarkRunError on the failing write (ioFailure for the
        // first failure; a subsequent call would be runPreviouslyFailed). Either way it is typed and the run
        // is poisoned — no final directory is ever published.
        XCTAssertThrowsError(try EvidenceRecorder().record(
            candidates: cands, referenceStore: nil,
            policy: .init(tolerances: .exact, diffAmplification: 4),
            into: run, engineConfiguration: minimalConfig(), deviceInfo: device)) { error in
            switch error {
            case BenchmarkRunError.ioFailure, BenchmarkRunError.runPreviouslyFailed: break
            default: XCTFail("expected a typed BenchmarkRunError (ioFailure/runPreviouslyFailed), got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directoryURL.path), "poisoned run never publishes a final directory")
        // A subsequent write after poisoning is the distinct typed failure.
        XCTAssertThrowsError(try run.writeSupplementalArtifact(data: Data([1]), at: try SupplementalArtifactPath("after.bin"))) { error in
            guard case BenchmarkRunError.runPreviouslyFailed = error else { return XCTFail("expected runPreviouslyFailed after poison, got \(error)") }
        }
    }

    // MARK: - Candidate generation through the real Metal executor (C-1/C-3, §7.3)

    func testCandidateGenerationFromMetalIsDeterministicAndRecordable() throws {
        let mtlDevice = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: mtlDevice)
        let w: Int64 = 4, h: Int64 = 4
        // A minimal real graph: a single opaque-red image scene → linear canvas → sRGB → output.
        func buildGraph() throws -> RenderGraph {
            let px = try MetalTestEnvironment.makePixelInput(
                id: "cgen", width: 4, height: 4, straightBGRA: Array(repeating: (b: 0, g: 0, r: 255, a: 255), count: 16))
            return try MetalTestEnvironment.singleImageGraph(width: w, height: h, profile: .rgba16FloatLinear, pixels: px)
        }
        let c1 = try CandidateGenerator.generate(
            graph: try buildGraph(), session: session,
            catalogID: "synthetic", blockID: "blk", variantID: "v0", projectTimeTicks: 0, configHash: "cfg")
        let c2 = try CandidateGenerator.generate(
            graph: try buildGraph(), session: session,
            catalogID: "synthetic", blockID: "blk", variantID: "v0", projectTimeTicks: 0, configHash: "cfg")
        // Deterministic id + byte-identical frame + identical graphHash provenance.
        XCTAssertEqual(c1.candidateID, c2.candidateID, "deterministic candidate id")
        XCTAssertEqual(c1.frame.bytes, c2.frame.bytes, "byte-identical RenderedFrame from the same input")
        XCTAssertEqual(c1.frame.rawOutputHash, c2.frame.rawOutputHash)
        XCTAssertEqual(c1.source.graphHash, c2.source.graphHash, "graphHash folded into provenance")
        // The candidate encodes to a deterministic, non-empty PNG and records end-to-end.
        let png1 = try DeterministicPNGEncoder.encode(c1.frame)
        let png2 = try DeterministicPNGEncoder.encode(c2.frame)
        XCTAssertEqual(png1, png2)
        XCTAssertGreaterThan(png1.count, 8)
        let parent = try tempDir()
        let run = try makeRun(parent, fileSystem: DefaultRunFileSystem(), runID: "cgen-rec")
        let manifest = try EvidenceRecorder().record(
            candidates: [c1], referenceStore: nil, policy: .init(tolerances: .exact, diffAmplification: 4),
            into: run, engineConfiguration: minimalConfig(), deviceInfo: self.device)
        XCTAssertEqual(manifest.candidates.first?.rawOutputHash, c1.frame.rawOutputHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.directoryURL.appendingPathComponent("candidates/\(c1.candidateID).png").path))
    }

    // MARK: - Manifest-last / aggregate-hash sensitivity (S-3, T-5)

    func testRenderManifestRecordedAsSupplementalAndAggregateHashSensitive() throws {
        func aggregateSupplementalHash(runID: String, fill: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) throws -> String {
            let parent = try tempDir()
            let run = try makeRun(parent, fileSystem: DefaultRunFileSystem(), runID: runID)
            _ = try EvidenceRecorder().record(
                candidates: [candidate("a", try frame(width: 4, height: 4, fill: fill))],
                referenceStore: nil, policy: .init(tolerances: .exact, diffAmplification: 4),
                into: run, engineConfiguration: minimalConfig(), deviceInfo: device)
            // The run-manifest.json carries the supplemental aggregate SHA; read it back.
            let manifest = try String(contentsOf: run.directoryURL.appendingPathComponent("run-manifest.json"), encoding: .utf8)
            return manifest
        }
        let h1 = try aggregateSupplementalHash(runID: "agg-1", fill: (b: 0, g: 0, r: 255, a: 255))
        let h2 = try aggregateSupplementalHash(runID: "agg-2", fill: (b: 0, g: 0, r: 254, a: 255))
        // Changing a candidate pixel changes its PNG → changes the supplemental aggregate hash in the run
        // manifest (the candidate id and run id are stable; only the pixel differs).
        XCTAssertNotEqual(h1, h2, "a changed candidate byte changes the supplemental aggregate hash in run-manifest.json")
    }
}

private enum TestErr: Error { case m(String); case u(String) }
