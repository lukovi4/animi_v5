import Foundation
import AnimiEngineRenderModel
import AnimiEngineMetalRender

/// Task-003 / Step-13 — candidate-frame generation from the completed Metal executor.
///
/// The generator is deliberately thin: it consumes an already-compiled, immutable `RenderGraph` plus the
/// provenance, executes it on the supplied `MetalRenderSession`, and captures the resulting
/// `RenderedFrame` as a `CandidateFrame` with a deterministic id. It does NOT change the render pipeline
/// or re-derive any graph; the heavy decode→convert→evaluate→resolve→compile chain stays with the caller
/// (the tests reuse the existing real-template path). Generation is a pure function of (graph, provenance)
/// on a given device: identical inputs → byte-identical frame + identical id.
public enum CandidateGenerator {

    public enum GenerationError: Error, Equatable, Sendable {
        case graphHashUnavailable(detail: String)
    }

    /// Render `graph` on `session`, returning a candidate with a deterministic id. `graphHash` is read
    /// from the immutable graph (not recomputed elsewhere) and folded into the provenance.
    public static func generate(
        graph: RenderGraph, session: MetalRenderSession,
        catalogID: String, blockID: String, variantID: String,
        projectTimeTicks: Int64, configHash: String
    ) throws -> CandidateFrame {
        let graphHash: String
        do { graphHash = try graph.graphHash() }
        catch { throw GenerationError.graphHashUnavailable(detail: "\(error)") }

        let frame = try session.execute(graph)
        let source = CandidateSource(
            catalogID: catalogID, blockID: blockID, variantID: variantID,
            projectTimeTicks: projectTimeTicks, configHash: configHash, graphHash: graphHash)
        let id = CandidateIdentity.candidateID(for: source)
        return CandidateFrame(candidateID: id, frame: frame, source: source)
    }
}
