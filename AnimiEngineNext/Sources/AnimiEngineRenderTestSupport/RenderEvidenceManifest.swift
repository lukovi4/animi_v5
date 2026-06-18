import Foundation
import AnimiEngineRenderModel

/// Task-003 / Step-13 — the canonical Step-13 render manifest (`render-manifest.json`).
///
/// Written as a SUPPLEMENTAL artifact (not the run's own `run-manifest.json`), so the run's manifest-last
/// commit is unchanged: this manifest is just one more supplemental file covered by the existing aggregate
/// hash. It is byte-stable canonical JSON (sorted keys), and every field is deterministic — no UUID, no
/// wall-clock — so identical inputs produce identical manifest bytes.
public struct RenderEvidenceManifest: Sendable, Equatable {

    public struct CandidateEntry: Sendable, Equatable {
        public let candidateID: String
        public let source: CandidateSource
        public let rawOutputHash: String
        public let candidateArtifact: String          // candidates/<id>.png
        public let referenceArtifact: String?         // references/<id>.png (snapshot) when present
        public let diffArtifact: String?              // diffs/<id>.diff.png when produced
        public let comparisonArtifact: String         // comparison/<id>.json
        public let verdict: String                    // FrameComparator.Verdict.rawValue
        public let maxChannelDelta: Int
        public let differingPixelCount: Int

        func canonicalValue() -> RenderCanonicalEncoding.Value {
            .object([
                ("candidateArtifact", .string(candidateArtifact)),
                ("candidateID", .string(candidateID)),
                ("comparisonArtifact", .string(comparisonArtifact)),
                ("diffArtifact", diffArtifact.map { .string($0) } ?? .string("none")),
                ("differingPixelCount", .int(Int64(differingPixelCount))),
                ("maxChannelDelta", .int(Int64(maxChannelDelta))),
                ("rawOutputHash", .string(rawOutputHash)),
                ("referenceArtifact", referenceArtifact.map { .string($0) } ?? .string("none")),
                ("source", source.canonicalValue()),
                ("verdict", .string(verdict))
            ])
        }
    }

    public let device: String                 // canonical DeviceInfo summary (model/system/version)
    public let engineConfigHash: String
    public let contactSheetArtifact: String?   // contact-sheet.png (when >= 1 candidate)
    public let candidates: [CandidateEntry]    // candidate order preserved (semantic)

    public init(device: String, engineConfigHash: String, contactSheetArtifact: String?, candidates: [CandidateEntry]) {
        self.device = device; self.engineConfigHash = engineConfigHash
        self.contactSheetArtifact = contactSheetArtifact; self.candidates = candidates
    }

    /// Byte-stable canonical JSON bytes.
    public func canonicalBytes() throws -> Data {
        let value = try RenderCanonicalEncoding.object([
            ("candidates", .array(candidates.map { $0.canonicalValue() })),
            ("contactSheetArtifact", contactSheetArtifact.map { .string($0) } ?? .string("none")),
            ("device", .string(device)),
            ("engineConfigHash", .string(engineConfigHash))
        ])
        var out = String()
        try RenderCanonicalEncoding.write(value, into: &out)
        guard let data = out.data(using: .utf8) else {
            throw RenderModelError.unsupportedValue(field: "RenderEvidenceManifest", value: "non-utf8 canonical")
        }
        return data
    }
}
