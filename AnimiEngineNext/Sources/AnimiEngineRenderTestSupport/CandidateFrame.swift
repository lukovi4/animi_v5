import Foundation
import AnimiEngineRenderModel

/// Task-003 / Step-13 — a captured candidate frame plus its deterministic provenance.
///
/// A candidate is rendered by the completed Metal executor for a specific (template, variant, project
/// time). Its identity is a pure function of that provenance — **never** a UUID or wall-clock value — so a
/// candidate set, its artifact paths, and the render manifest are fully reproducible (hard constraint 6).
public struct CandidateSource: Hashable, Sendable {
    public let catalogID: String
    public let blockID: String
    public let variantID: String
    public let projectTimeTicks: Int64
    public let configHash: String
    public let graphHash: String

    public init(catalogID: String, blockID: String, variantID: String,
                projectTimeTicks: Int64, configHash: String, graphHash: String) {
        self.catalogID = catalogID; self.blockID = blockID; self.variantID = variantID
        self.projectTimeTicks = projectTimeTicks; self.configHash = configHash; self.graphHash = graphHash
    }

    func canonicalValue() -> RenderCanonicalEncoding.Value {
        .object([
            ("blockID", .string(blockID)),
            ("catalogID", .string(catalogID)),
            ("configHash", .string(configHash)),
            ("graphHash", .string(graphHash)),
            ("projectTimeTicks", .int(projectTimeTicks)),
            ("variantID", .string(variantID))
        ])
    }
}

public struct CandidateFrame: Sendable {
    public let candidateID: String
    public let frame: RenderedFrame
    public let source: CandidateSource

    public init(candidateID: String, frame: RenderedFrame, source: CandidateSource) {
        self.candidateID = candidateID
        self.frame = frame
        self.source = source
    }
}

/// Deterministic candidate identity derivation.
public enum CandidateIdentity {
    /// A filesystem- and manifest-safe candidate id derived ONLY from provenance: a sanitized
    /// `catalog__block__variant__tNNN` slug. Deterministic, no UUID, no wall-clock. Distinct provenances
    /// never collide because every field is included; characters outside `[A-Za-z0-9._-]` are escaped to a
    /// fixed `_hexhex_` form so the id is a valid `SupplementalArtifactPath` component.
    public static func candidateID(for source: CandidateSource) -> String {
        let parts = [source.catalogID, source.blockID, source.variantID, "t\(source.projectTimeTicks)"]
        return parts.map(sanitize).joined(separator: "__")
    }

    private static func sanitize(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            let c = Character(scalar)
            // `_` `.` `-` and alphanumerics are filesystem-safe and valid path-component characters. Note
            // `_` is preserved (the `__` field separator is a DOUBLE underscore, so a single underscore in
            // a field never collides with the separator). Any other character escapes to a fixed `xNN`
            // form so the id stays a valid `SupplementalArtifactPath` component (no `/`, no `.`-only, no NUL).
            if c.isLetter || c.isNumber || c == "." || c == "-" || c == "_" {
                out.append(c)
            } else {
                out.append("x")
                out.append(String(format: "%02x", scalar.value & 0xFF))
            }
        }
        return out.isEmpty ? "xempty" : out
    }
}
