import Foundation

/// Task-003 / Step-17 (D6, minimal): a typed, READ-ONLY model for the on-disk `approval-manifest.json` that
/// an approved promotion writes. It exists ONLY to let production/test code load and integrity-check the
/// audit record — it carries NO promotion workflow, NO approval-state machine, and NO UI. Promotion itself is
/// performed by `ReferencePromoter`; this type only reads back what was written.
public enum ReferenceApproval {

    public enum LoadError: Error, Equatable, Sendable {
        case unreadable(detail: String)
        case malformed(detail: String)
    }

    /// The contents of an `approval-manifest.json` (the fields a reader needs; not the full record).
    public struct Record: Sendable, Equatable {
        public let sourceRunID: String
        public let candidateCount: Int
        public let approvalManifestSHA256: String
        public let referenceCandidateIDs: [String]
        public let approvedAtISO8601: String?
        public let approvedBy: String?
    }

    /// Load `<root>/approval-manifest.json` into a typed record. Read-only; no writes, no promotion.
    public static func load(rootURL: URL) throws -> Record {
        let url = rootURL.appendingPathComponent("approval-manifest.json")
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw LoadError.unreadable(detail: "\(error)") }
        guard let wrapper = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let body = wrapper["approvalManifest"] as? [String: Any],
              let storedHash = wrapper["approvalManifestSHA256"] as? String else {
            throw LoadError.malformed(detail: "missing approvalManifest/approvalManifestSHA256")
        }
        guard let sourceRunID = body["sourceRunID"] as? String,
              let count = (body["candidateCount"] as? NSNumber)?.intValue,
              let refs = body["references"] as? [[String: Any]] else {
            throw LoadError.malformed(detail: "missing required body fields")
        }
        let ids = refs.compactMap { $0["candidateID"] as? String }.sorted()
        return Record(sourceRunID: sourceRunID, candidateCount: count, approvalManifestSHA256: storedHash,
                      referenceCandidateIDs: ids,
                      approvedAtISO8601: body["approvedAtISO8601"] as? String,
                      approvedBy: body["approvedBy"] as? String)
    }
}
