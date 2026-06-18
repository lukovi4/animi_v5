import Foundation
import AnimiEngineRenderModel
import AnimiEngineNext

/// Task-003 / Step-17 — the canonical, auditable approval record written when an approved sealed run is
/// promoted into the approved-reference root (`AnimiEngineNext/ReferenceData/approval-manifest.json`).
///
/// The manifest pairs each promoted reference with the source-run evidence that justifies it (candidateID,
/// rawOutputHash, graph/config/material identity, the source runID, and the SHA-256 of the promoted PNG
/// bytes). It carries a self-integrity hash (`approvalManifestSHA256`) computed over the canonical bytes of
/// the manifest **body**, written as the outer wrapper's last field (mirroring the run's manifest-last
/// commit-marker discipline).
///
/// D4: approval attribution (`approvedAtISO8601`, `approvedBy`) lives ONLY in the body and never affects the
/// per-reference PNG bytes; those two fields are the only non-deterministic content. The reference PNGs and
/// every per-entry hash are fully deterministic.
public struct ApprovalManifest: Sendable, Equatable {

    public struct Entry: Sendable, Equatable {
        public let candidateID: String
        public let rawOutputHash: String
        public let graphHash: String
        public let configHash: String
        public let catalogID: String
        public let blockID: String
        public let variantID: String
        public let projectTimeTicks: Int64
        public let referencePath: String      // references/<candidateID>.png
        public let referenceSHA256: String    // sha256 of the promoted PNG bytes

        public init(candidateID: String, rawOutputHash: String, graphHash: String, configHash: String,
                    catalogID: String, blockID: String, variantID: String, projectTimeTicks: Int64,
                    referencePath: String, referenceSHA256: String) {
            self.candidateID = candidateID; self.rawOutputHash = rawOutputHash
            self.graphHash = graphHash; self.configHash = configHash
            self.catalogID = catalogID; self.blockID = blockID; self.variantID = variantID
            self.projectTimeTicks = projectTimeTicks
            self.referencePath = referencePath; self.referenceSHA256 = referenceSHA256
        }

        func canonicalValue() -> RenderCanonicalEncoding.Value {
            .object([
                ("blockID", .string(blockID)),
                ("candidateID", .string(candidateID)),
                ("catalogID", .string(catalogID)),
                ("configHash", .string(configHash)),
                ("graphHash", .string(graphHash)),
                ("projectTimeTicks", .int(projectTimeTicks)),
                ("rawOutputHash", .string(rawOutputHash)),
                ("referencePath", .string(referencePath)),
                ("referenceSHA256", .string(referenceSHA256)),
                ("variantID", .string(variantID)),
            ])
        }
    }

    public let approvalManifestVersion: Int
    public let sourceRunID: String
    public let sourceSupplementalArtifactsSHA256: String
    public let sourceEngineConfigSHA256: String
    public let approvedAtISO8601: String?      // D4 — attribution only; nil ⇒ fully deterministic manifest
    public let approvedBy: String?             // D4 — attribution only
    public let candidateCount: Int
    public let entries: [Entry]                // sorted by candidateID

    public init(approvalManifestVersion: Int = 1, sourceRunID: String,
                sourceSupplementalArtifactsSHA256: String, sourceEngineConfigSHA256: String,
                approvedAtISO8601: String?, approvedBy: String?, candidateCount: Int, entries: [Entry]) {
        self.approvalManifestVersion = approvalManifestVersion
        self.sourceRunID = sourceRunID
        self.sourceSupplementalArtifactsSHA256 = sourceSupplementalArtifactsSHA256
        self.sourceEngineConfigSHA256 = sourceEngineConfigSHA256
        self.approvedAtISO8601 = approvedAtISO8601
        self.approvedBy = approvedBy
        self.candidateCount = candidateCount
        self.entries = entries.sorted { $0.candidateID < $1.candidateID }
    }

    /// The canonical body value (everything EXCEPT the self-hash wrapper). Sorted keys, byte-stable.
    private func bodyValue() throws -> RenderCanonicalEncoding.Value {
        var fields: [(String, RenderCanonicalEncoding.Value)] = [
            ("approvalManifestVersion", .int(Int64(approvalManifestVersion))),
            ("candidateCount", .int(Int64(candidateCount))),
            ("references", .array(entries.map { $0.canonicalValue() })),
            ("sourceEngineConfigSHA256", .string(sourceEngineConfigSHA256)),
            ("sourceRunID", .string(sourceRunID)),
            ("sourceSupplementalArtifactsSHA256", .string(sourceSupplementalArtifactsSHA256)),
        ]
        // D4 attribution fields, included only when present.
        if let approvedAtISO8601 { fields.append(("approvedAtISO8601", .string(approvedAtISO8601))) }
        if let approvedBy { fields.append(("approvedBy", .string(approvedBy))) }
        return try RenderCanonicalEncoding.object(fields)
    }

    /// The canonical bytes of the body (used to compute the self-hash).
    public func bodyCanonicalBytes() throws -> Data {
        var out = String()
        try RenderCanonicalEncoding.write(try bodyValue(), into: &out)
        guard let data = out.data(using: .utf8) else {
            throw RenderModelError.unsupportedValue(field: "approvalManifest.body", value: "non-utf8")
        }
        return data
    }

    /// The self-integrity hash over the canonical body bytes.
    public func approvalManifestSHA256() throws -> String {
        ConfigurationHash.sha256Hex(ofCanonicalBytes: try bodyCanonicalBytes())
    }

    /// The final on-disk bytes: `{ "approvalManifest": <body>, "approvalManifestSHA256": <hash> }`, canonical.
    /// The self-hash is the LAST field written (manifest-last discipline).
    public func canonicalBytes() throws -> Data {
        let body = try bodyValue()
        let hash = try approvalManifestSHA256()
        let wrapper = try RenderCanonicalEncoding.object([
            ("approvalManifest", body),
            ("approvalManifestSHA256", .string(hash)),
        ])
        var out = String()
        try RenderCanonicalEncoding.write(wrapper, into: &out)
        guard let data = out.data(using: .utf8) else {
            throw RenderModelError.unsupportedValue(field: "approvalManifest", value: "non-utf8")
        }
        return data
    }
}
