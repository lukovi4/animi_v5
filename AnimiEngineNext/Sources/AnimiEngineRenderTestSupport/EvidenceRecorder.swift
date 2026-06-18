import Foundation
import AnimiEngineRenderModel
import AnimiEngineDiagnostics
import AnimiEngineNext

/// Task-003 / Step-13 — orchestrates candidate evidence recording on top of the transactional run system.
///
/// For each candidate it: encodes a deterministic candidate PNG; reads an approved reference (READ-ONLY,
/// if present); compares (exact/bounded); when a reference is present, snapshots the reference PNG into the
/// run and produces a deterministic diff PNG; writes the per-candidate comparison JSON; and accumulates a
/// contact-sheet row. After all candidates it writes one deterministic contact-sheet PNG and the canonical
/// `render-manifest.json`. **Every write goes through `BenchmarkRun.writeSupplementalArtifact`** (the
/// exclusive, write-once, manifest-last, atomically-published path), then the run is closed.
///
/// It NEVER writes or updates an approved reference (no self-blessing). `outOfBounds` records the verdict
/// only and does NOT auto-fail the run (D4). Typed errors only; no fallback, no force-unwrap, no `try?`.
public struct EvidenceRecorder: Sendable {

    public enum RecorderError: Error, Equatable, Sendable {
        case noCandidates
        case duplicateCandidateID(String)
    }

    /// Comparison configuration per recording.
    public struct Policy: Sendable {
        public let tolerances: FrameComparator.Tolerances
        public let diffAmplification: Int
        public init(tolerances: FrameComparator.Tolerances, diffAmplification: Int) {
            self.tolerances = tolerances; self.diffAmplification = diffAmplification
        }
    }

    public init() {}

    /// Record a candidate set into `run`, then close it. `referenceStore` is optional (no-reference mode
    /// when nil). Returns the `RenderEvidenceManifest` that was written (for test assertions). The run is
    /// closed with `status: .success` (D4: comparison verdicts are recorded, not gated).
    public func record(
        candidates: [CandidateFrame],
        referenceStore: ReferenceStore?,
        policy: Policy,
        into run: BenchmarkRun,
        engineConfiguration: EngineConfiguration,
        deviceInfo: DeviceInfo
    ) throws -> RenderEvidenceManifest {
        // Single-group convenience (Step-13): record into the run root and close it.
        let manifest = try recordGroup(
            group: "", candidates: candidates, referenceStore: referenceStore, policy: policy,
            into: run, engineConfiguration: engineConfiguration, deviceInfo: deviceInfo)
        try run.close(engineConfiguration: engineConfiguration, deviceInfo: deviceInfo, status: .success)
        return manifest
    }

    /// Record a candidate set under a deterministic `group` prefix WITHOUT closing the run (Step-14, D1).
    /// Multiple groups may be recorded into one `BenchmarkRun`; the caller closes the run once after the
    /// last group. An empty `group` records at the run root (the Step-13 layout). Each group writes its own
    /// `<group>/contact-sheet.png` and `<group>/render-manifest.json` as supplemental artifacts. The run's
    /// own `run-manifest.json` remains the manifest-last commit marker over the whole aggregate.
    public func recordGroup(
        group: String,
        candidates: [CandidateFrame],
        referenceStore: ReferenceStore?,
        policy: Policy,
        into run: BenchmarkRun,
        engineConfiguration: EngineConfiguration,
        deviceInfo: DeviceInfo
    ) throws -> RenderEvidenceManifest {
        guard !candidates.isEmpty else { throw RecorderError.noCandidates }
        let prefix = group.isEmpty ? "" : "\(group)/"

        // Reject duplicate candidate ids within this group (deterministic ids must be unique).
        var seen = Set<String>()
        for c in candidates where !seen.insert(c.candidateID).inserted {
            throw RecorderError.duplicateCandidateID(c.candidateID)
        }

        var entries: [RenderEvidenceManifest.CandidateEntry] = []
        var sheetRows: [ContactSheet.Row] = []

        for candidate in candidates {
            let id = candidate.candidateID
            let candidatePath = "\(prefix)candidates/\(id).png"
            let comparisonPath = "\(prefix)comparison/\(id).json"

            // 1) Candidate PNG (deterministic) → supplemental.
            let candidatePNG = try DeterministicPNGEncoder.encode(candidate.frame)
            try run.writeSupplementalArtifact(data: candidatePNG, at: try SupplementalArtifactPath(candidatePath))

            // 2) Reference (READ-ONLY) + comparison.
            let reference = try referenceStore?.reference(for: id)
            let result = try FrameComparator.compare(
                candidate: candidate.frame, reference: reference, tolerances: policy.tolerances)

            // 3) When a reference is present: snapshot it (read-only copy into the run) + diff PNG.
            var referencePath: String? = nil
            var diffPath: String? = nil
            var diffBGRA8: Data? = nil
            if let reference {
                referencePath = "\(prefix)references/\(id).png"
                let refPNG = try DeterministicPNGEncoder.encode(reference)   // re-encode deterministically
                try run.writeSupplementalArtifact(data: refPNG, at: try SupplementalArtifactPath(referencePath!))

                if result.verdict != .exactMatch {
                    let diff = try DiffImage.diff(candidate: candidate.frame, reference: reference, amplification: policy.diffAmplification)
                    let diffPNG = try DiffImage.encodePNG(diff)
                    diffPath = "\(prefix)diffs/\(id).diff.png"
                    try run.writeSupplementalArtifact(data: diffPNG, at: try SupplementalArtifactPath(diffPath!))
                    diffBGRA8 = diff.bgra8
                }
            }

            // 4) Comparison JSON (canonical) → supplemental.
            let comparisonJSON = try comparisonCanonicalBytes(id: id, result: result, amplification: policy.diffAmplification, diffArtifact: diffPath)
            try run.writeSupplementalArtifact(data: comparisonJSON, at: try SupplementalArtifactPath(comparisonPath))

            entries.append(RenderEvidenceManifest.CandidateEntry(
                candidateID: id, source: candidate.source, rawOutputHash: candidate.frame.rawOutputHash,
                candidateArtifact: candidatePath, referenceArtifact: referencePath, diffArtifact: diffPath,
                comparisonArtifact: comparisonPath, verdict: result.verdict.rawValue,
                maxChannelDelta: result.maxChannelDelta, differingPixelCount: result.differingPixelCount))
            sheetRows.append(ContactSheet.Row(candidate: candidate.frame, reference: reference, diffBGRA8: diffBGRA8))
        }

        // 5) One deterministic contact sheet per group → supplemental.
        let contactSheetPNG = try ContactSheet.encodePNG(rows: sheetRows)
        let contactSheetPath = "\(prefix)contact-sheet.png"
        try run.writeSupplementalArtifact(data: contactSheetPNG, at: try SupplementalArtifactPath(contactSheetPath))

        // 6) <group>/render-manifest.json (canonical) → supplemental. One more supplemental file per group;
        //    the run's own run-manifest.json remains the manifest-last commit marker over the aggregate.
        let manifest = RenderEvidenceManifest(
            device: deviceInfo.canonicalJSON(),
            engineConfigHash: ConfigurationHash.sha256Hex(of: engineConfiguration),
            contactSheetArtifact: contactSheetPath, candidates: entries)
        try run.writeSupplementalArtifact(data: try manifest.canonicalBytes(), at: try SupplementalArtifactPath("\(prefix)render-manifest.json"))

        // The group record does NOT close the run (the caller closes once after the last group, D1).
        return manifest
    }

    /// Canonical comparison JSON bytes (sorted keys, deterministic).
    private func comparisonCanonicalBytes(
        id: String, result: FrameComparator.Result, amplification: Int, diffArtifact: String?
    ) throws -> Data {
        var fields: [(String, RenderCanonicalEncoding.Value)] = [
            ("candidateHash", .string(result.candidateHash)),
            ("candidateID", .string(id)),
            ("diffAmplification", .int(Int64(amplification))),
            ("diffArtifact", diffArtifact.map { .string($0) } ?? .string("none")),
            ("differingPixelCount", .int(Int64(result.differingPixelCount))),
            ("maxChannelDelta", .int(Int64(result.maxChannelDelta))),
            ("referenceHash", result.referenceHash.map { .string($0) } ?? .string("none")),
            ("referencePresent", .bool(result.referencePresent)),
            ("toleranceMaxChannelDelta", .int(Int64(result.tolerances.maxChannelDelta))),
            ("toleranceMaxDifferingPixels", .int(Int64(result.tolerances.maxDifferingPixels))),
            ("verdict", .string(result.verdict.rawValue))
        ]
        fields.sort { $0.0 < $1.0 }
        let value = try RenderCanonicalEncoding.object(fields)
        var out = String()
        try RenderCanonicalEncoding.write(value, into: &out)
        guard let data = out.data(using: .utf8) else {
            throw RenderModelError.unsupportedValue(field: "comparisonJSON", value: "non-utf8 canonical")
        }
        return data
    }
}
