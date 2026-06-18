import Foundation
import AnimiEngineRenderModel
import AnimiEngineNext

/// Task-003 / Step-17 — the GUARDED, AUDITABLE, git-reversible reference promoter.
///
/// Promotes the candidate PNGs of ONE approved sealed run into the committed approved-reference root
/// (`<root>/references/<candidateID>.png` + `<root>/approval-manifest.json`). It is the single sanctioned
/// way to create approved references; it NEVER renders, never blesses current engine output, and never
/// touches the sealed run (read-only). Promotion is transactional (staging → atomic publish); on ANY failure
/// the approved root is left byte-identical. It does NOT git-commit — it writes files and reports them for
/// the owner to commit (so a `git revert`/`checkout` fully reverses a promotion).
///
/// Guards (ALL must pass before any write): source status success; aggregate == artifacts-manifest;
/// candidate count == expected (64); no references/diffs in the source run; source runID == the approved
/// runID; every candidate verdict == candidateOnly; per-file integrity (PNG SHA == artifacts-manifest, decoded
/// rawOutputHash == render-manifest); no dirty approved refs; no overwrite unless bytes identical.
public struct ReferencePromoter: Sendable {

    public enum PromotionError: Error, Equatable, Sendable {
        case sourceRunNotFound(path: String)
        case runManifestUnreadable(detail: String)
        case statusNotSuccess(found: String)
        case aggregateMismatch(runManifest: String, computed: String)
        case runIDMismatch(approved: String, found: String)          // STOP: wrong/obsolete run
        case candidateCountMismatch(expected: Int, found: Int)
        case sourceContainsReferencesOrDiffs(path: String)
        case nonCandidateOnlyVerdict(candidateID: String, verdict: String)
        case missingCandidatePNG(candidateID: String, path: String)
        case integrityMismatch(candidateID: String, detail: String)
        case dirtyApprovedReference(candidateID: String, detail: String)   // existing ref differs; no overwrite
        case ioFailure(reason: String)
        case malformedManifest(detail: String)
    }

    /// Inputs that fully determine a promotion.
    public struct Request: Sendable {
        public let sourceRunURL: URL            // the sealed run directory (read-only)
        public let approvedRunID: String        // the owner-approved runID; source must match
        public let approvedReferenceRootURL: URL // destination root (committed)
        public let expectedCandidateCount: Int  // 64
        public let groups: [String]             // group dir names under the run
        public let approvedAtISO8601: String?   // D4 attribution (optional)
        public let approvedBy: String?          // D4 attribution (optional)
        public let allowIdenticalOverwrite: Bool // idempotent re-promotion onto an existing root
        public init(sourceRunURL: URL, approvedRunID: String, approvedReferenceRootURL: URL,
                    expectedCandidateCount: Int, groups: [String],
                    approvedAtISO8601: String?, approvedBy: String?, allowIdenticalOverwrite: Bool) {
            self.sourceRunURL = sourceRunURL; self.approvedRunID = approvedRunID
            self.approvedReferenceRootURL = approvedReferenceRootURL
            self.expectedCandidateCount = expectedCandidateCount; self.groups = groups
            self.approvedAtISO8601 = approvedAtISO8601; self.approvedBy = approvedBy
            self.allowIdenticalOverwrite = allowIdenticalOverwrite
        }
    }

    /// One validated, ready-to-write reference (collected during the guard pass).
    struct PlannedReference {
        let candidateID: String
        let sourcePNGURL: URL
        let pngBytes: Data
        let pngSHA256: String
        let rawOutputHash: String
        let graphHash: String
        let configHash: String
        let catalogID: String
        let blockID: String
        let variantID: String
        let projectTimeTicks: Int64
    }

    public struct Outcome: Sendable, Equatable {
        public let dryRun: Bool
        public let validatedCount: Int          // candidates that passed all guards
        public let writtenCount: Int            // PNGs actually written (0 on dry-run / idempotent no-op)
        public let idempotentNoOp: Bool         // true if an existing root already matched byte-for-byte
        public let approvalManifestSHA256: String
        public let approvedReferenceRootPath: String
    }

    public init() {}

    // MARK: - Public entrypoints

    /// Validate everything and report WITHOUT writing (P-1). Throws on any guard failure.
    public func dryRun(_ request: Request) throws -> Outcome {
        let planned = try validateAndPlan(request)
        let manifest = try buildManifest(request, planned)
        return Outcome(dryRun: true, validatedCount: planned.count, writtenCount: 0, idempotentNoOp: false,
                       approvalManifestSHA256: try manifest.approvalManifestSHA256(),
                       approvedReferenceRootPath: request.approvedReferenceRootURL.path)
    }

    /// Validate, then transactionally write the references + approval manifest (opt-in). On any failure the
    /// approved root is left byte-identical (staging removed). Idempotent: a re-promotion whose every file is
    /// byte-identical to the existing root is a no-op success.
    public func promote(_ request: Request) throws -> Outcome {
        let planned = try validateAndPlan(request)
        let manifest = try buildManifest(request, planned)
        let manifestBytes = try manifest.canonicalBytes()

        let fm = FileManager.default
        let root = request.approvedReferenceRootURL
        let refsDir = root.appendingPathComponent("references", isDirectory: true)
        let manifestURL = root.appendingPathComponent("approval-manifest.json")

        // Idempotency / dirty-root guard (G8/G9): if the root already exists, compare byte-for-byte.
        if fm.fileExists(atPath: root.path) {
            var allIdentical = fm.fileExists(atPath: manifestURL.path)
                && ((try? Data(contentsOf: manifestURL)) == manifestBytes)
            for p in planned {
                let existing = refsDir.appendingPathComponent("\(p.candidateID).png")
                if fm.fileExists(atPath: existing.path) {
                    let existingBytes = (try? Data(contentsOf: existing)) ?? Data()
                    if existingBytes != p.pngBytes {
                        throw PromotionError.dirtyApprovedReference(
                            candidateID: p.candidateID, detail: "existing approved reference bytes differ")
                    }
                } else {
                    allIdentical = false
                }
            }
            if allIdentical {
                return Outcome(dryRun: false, validatedCount: planned.count, writtenCount: 0,
                               idempotentNoOp: true, approvalManifestSHA256: try manifest.approvalManifestSHA256(),
                               approvedReferenceRootPath: root.path)
            }
            if !request.allowIdenticalOverwrite {
                // Root exists but is not a complete byte-identical match and overwrite not explicitly allowed.
                throw PromotionError.dirtyApprovedReference(
                    candidateID: "<root>", detail: "approved root exists and differs; overwrite not allowed")
            }
        }

        // Transactional write: staging dir → atomic rename to final.
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent(".promote-\(request.approvedRunID).staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging.appendingPathComponent("references"), withIntermediateDirectories: true)
            for p in planned {
                let dst = staging.appendingPathComponent("references").appendingPathComponent("\(p.candidateID).png")
                try p.pngBytes.write(to: dst, options: .atomic)
            }
            // Manifest written LAST inside staging.
            try manifestBytes.write(to: staging.appendingPathComponent("approval-manifest.json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: staging)
            throw PromotionError.ioFailure(reason: "staging write failed: \(error)")
        }

        // Atomic publish. If a root already exists (overwrite-allowed path), replace it atomically.
        do {
            if fm.fileExists(atPath: root.path) {
                _ = try fm.replaceItemAt(root, withItemAt: staging)
            } else {
                try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staging, to: root)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw PromotionError.ioFailure(reason: "atomic publish failed (approved root unchanged): \(error)")
        }

        return Outcome(dryRun: false, validatedCount: planned.count, writtenCount: planned.count,
                       idempotentNoOp: false, approvalManifestSHA256: try manifest.approvalManifestSHA256(),
                       approvedReferenceRootPath: root.path)
    }

    // MARK: - Guard pass

    func validateAndPlan(_ request: Request) throws -> [PlannedReference] {
        let fm = FileManager.default
        let run = request.sourceRunURL
        guard fm.fileExists(atPath: run.path) else { throw PromotionError.sourceRunNotFound(path: run.path) }

        // --- run-manifest.json: status, runID, aggregate ---
        let runManifestURL = run.appendingPathComponent("run-manifest.json")
        guard let rmData = try? Data(contentsOf: runManifestURL),
              let rm = (try? JSONSerialization.jsonObject(with: rmData)) as? [String: Any] else {
            throw PromotionError.runManifestUnreadable(detail: runManifestURL.path)
        }
        // G1 status success
        guard let status = rm["status"] as? String, status == "success" else {
            throw PromotionError.statusNotSuccess(found: (rm["status"] as? String) ?? "<none>")
        }
        // G5 runID == approved (rejects the obsolete run)
        guard let runID = rm["runID"] as? String, runID == request.approvedRunID else {
            throw PromotionError.runIDMismatch(approved: request.approvedRunID, found: (rm["runID"] as? String) ?? "<none>")
        }
        // G2 aggregate == SHA256(artifacts-manifest.json)
        let artifactsManifestURL = run.appendingPathComponent("artifacts-manifest.json")
        guard let amData = try? Data(contentsOf: artifactsManifestURL) else {
            throw PromotionError.malformedManifest(detail: "artifacts-manifest.json unreadable")
        }
        let computedAggregate = ConfigurationHash.sha256Hex(ofCanonicalBytes: amData)
        guard let declaredAggregate = rm["supplementalArtifactsSHA256"] as? String,
              declaredAggregate == computedAggregate else {
            throw PromotionError.aggregateMismatch(
                runManifest: (rm["supplementalArtifactsSHA256"] as? String) ?? "<none>", computed: computedAggregate)
        }
        // artifacts-manifest entries → path→sha256 map (G7).
        let amSHAByPath = try parseArtifactsManifest(amData)

        // --- G4: no references/ or diffs/ anywhere in the source run ---
        if let enumerator = fm.enumerator(at: run, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if url.hasDirectoryPath, name == "references" || name == "diffs" {
                    throw PromotionError.sourceContainsReferencesOrDiffs(path: url.path)
                }
            }
        }

        // --- per-group render manifests → candidate metadata + integrity ---
        var planned: [PlannedReference] = []
        var seenIDs = Set<String>()
        for group in request.groups {
            let groupManifestURL = run.appendingPathComponent(group).appendingPathComponent("render-manifest.json")
            guard let gmData = try? Data(contentsOf: groupManifestURL),
                  let gm = (try? JSONSerialization.jsonObject(with: gmData)) as? [String: Any],
                  let candidates = gm["candidates"] as? [[String: Any]] else {
                throw PromotionError.malformedManifest(detail: "\(group)/render-manifest.json")
            }
            for c in candidates {
                guard let cid = c["candidateID"] as? String,
                      let verdict = c["verdict"] as? String,
                      let rawHash = c["rawOutputHash"] as? String,
                      let candidateArtifact = c["candidateArtifact"] as? String,
                      let source = c["source"] as? [String: Any] else {
                    throw PromotionError.malformedManifest(detail: "\(group) candidate entry")
                }
                // G6 candidateOnly
                guard verdict == "candidateOnly" else {
                    throw PromotionError.nonCandidateOnlyVerdict(candidateID: cid, verdict: verdict)
                }
                // candidate PNG present
                let pngURL = run.appendingPathComponent(candidateArtifact)
                guard let pngBytes = try? Data(contentsOf: pngURL) else {
                    throw PromotionError.missingCandidatePNG(candidateID: cid, path: pngURL.path)
                }
                // G7a per-file integrity vs artifacts-manifest
                let pngSHA = ConfigurationHash.sha256Hex(ofCanonicalBytes: pngBytes)
                guard let declared = amSHAByPath[candidateArtifact] else {
                    throw PromotionError.integrityMismatch(candidateID: cid, detail: "no artifacts-manifest entry for \(candidateArtifact)")
                }
                guard declared == pngSHA else {
                    throw PromotionError.integrityMismatch(candidateID: cid, detail: "PNG sha \(pngSHA) != artifacts-manifest \(declared)")
                }
                // G7b decoded rawOutputHash matches the manifest
                let store = ReferenceStore(rootURL: run)   // reuse its deterministic PNG decoder
                let decoded = try store.decodeForPromotion(png: pngBytes, candidateID: cid)
                guard decoded.rawOutputHash == rawHash else {
                    throw PromotionError.integrityMismatch(candidateID: cid, detail: "decoded rawOutputHash \(decoded.rawOutputHash) != manifest \(rawHash)")
                }
                guard seenIDs.insert(cid).inserted else {
                    throw PromotionError.malformedManifest(detail: "duplicate candidateID \(cid)")
                }
                planned.append(PlannedReference(
                    candidateID: cid, sourcePNGURL: pngURL, pngBytes: pngBytes, pngSHA256: pngSHA,
                    rawOutputHash: rawHash, graphHash: (source["graphHash"] as? String) ?? "",
                    configHash: (source["configHash"] as? String) ?? "",
                    catalogID: (source["catalogID"] as? String) ?? "",
                    blockID: (source["blockID"] as? String) ?? "",
                    variantID: (source["variantID"] as? String) ?? "",
                    projectTimeTicks: (source["projectTimeTicks"] as? NSNumber)?.int64Value ?? 0))
            }
        }
        // G3 candidate count
        guard planned.count == request.expectedCandidateCount else {
            throw PromotionError.candidateCountMismatch(expected: request.expectedCandidateCount, found: planned.count)
        }
        return planned.sorted { $0.candidateID < $1.candidateID }
    }

    private func parseArtifactsManifest(_ data: Data) throws -> [String: String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PromotionError.malformedManifest(detail: "artifacts-manifest not an object")
        }
        // Entries carry { path, byteSize, sha256 } (Task-003 §10.2).
        guard let entries = obj["entries"] as? [[String: Any]] else {
            throw PromotionError.malformedManifest(detail: "artifacts-manifest has no entries")
        }
        var map: [String: String] = [:]
        for e in entries {
            if let p = e["path"] as? String, let s = e["sha256"] as? String { map[p] = s }
        }
        return map
    }

    private func buildManifest(_ request: Request, _ planned: [PlannedReference]) throws -> ApprovalManifest {
        // Re-read the source run-level hashes for the audit record.
        let rm = (try? JSONSerialization.jsonObject(with: try Data(contentsOf: request.sourceRunURL.appendingPathComponent("run-manifest.json")))) as? [String: Any] ?? [:]
        let entries = planned.map { p in
            ApprovalManifest.Entry(
                candidateID: p.candidateID, rawOutputHash: p.rawOutputHash, graphHash: p.graphHash,
                configHash: p.configHash, catalogID: p.catalogID, blockID: p.blockID, variantID: p.variantID,
                projectTimeTicks: p.projectTimeTicks, referencePath: "references/\(p.candidateID).png",
                referenceSHA256: p.pngSHA256)
        }
        return ApprovalManifest(
            sourceRunID: request.approvedRunID,
            sourceSupplementalArtifactsSHA256: (rm["supplementalArtifactsSHA256"] as? String) ?? "",
            sourceEngineConfigSHA256: (rm["engineConfigSHA256"] as? String) ?? "",
            approvedAtISO8601: request.approvedAtISO8601, approvedBy: request.approvedBy,
            candidateCount: planned.count, entries: entries)
    }
}
