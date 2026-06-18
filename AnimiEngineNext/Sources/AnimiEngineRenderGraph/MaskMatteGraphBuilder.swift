import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §7 (mask scopes, matte source/consumer links), §7.1 (authored order + explicit matte
/// relationships), §7.4 (unsupported mask/matte mode rejection) — the mask/matte scope builder for one
/// AnimIR layer (§17 step 9, corrective #5/#6).
///
/// Step 9 owns the **types, links, order and scope balance** of masks and mattes; the pixel realisation
/// is the Metal executor's. Corrective changes:
///   * **#5** masks carry the **sampled** path geometry (a `SampledBezier`), not only a path id; the
///     optional `pathID` is validated for identity/ownership against the program's path resources;
///   * **#6** a matte links a matte source that the compiler has **actually rendered** into an explicit
///     surface; the link carries that `sourceSurfaceID`.
public enum MaskMatteGraphBuilder {

    /// Rev-4 §2.7/§2.8/§5.2 — the authored-order list of mask operations for one masked layer
    /// contribution. Each operation samples the producer-flattened mesh through `PathResourceSampler`
    /// (a fill/mask mesh must be `closed`) and carries the exact path-local→target transform `world`.
    /// The order is the authored `RenderLayer.masks` order (semantically significant). Returns an empty
    /// list when the layer has no masks.
    public static func maskOperations(
        for layer: RenderLayer, at frame: RationalSourceTime,
        world: FixedAffineTransform2D, pathResourcesByID: [Int: RenderPathResource], field: String
    ) throws -> [SampledMaskOperation] {
        var operations: [SampledMaskOperation] = []
        for (i, mask) in layer.masks.enumerated() {
            let mf = "\(field).mask[\(i)]"
            guard let mode = RenderMaskMode(rawValue: mask.mode) else {
                throw RenderGraphError.unsupportedLayerMode(field: "\(mf).mode", value: mask.mode)
            }
            // A mask must reference a producer path resource (its flattened mesh + indices).
            guard let pid = mask.pathID else {
                throw RenderGraphError.missingPathResource(pathID: -1, field: "\(mf).pathID")
            }
            guard let resource = pathResourcesByID[pid] else {
                throw RenderGraphError.missingPathResource(pathID: pid, field: "\(mf).pathID")
            }
            // §3.2 — the closed flag is taken from the animated path and must be invariant across
            // keyframes; a mask mesh must be closed.
            let closed = try PathClosedResolver.invariantClosed(mask.path, pathID: pid, field: "\(mf).path")
            guard closed else {
                throw RenderGraphError.pathResourceMismatch(pathID: pid, field: "\(mf).path", detail: "mask path must be closed")
            }
            let mesh = try PathResourceSampler.sample(resource: resource, closed: closed, at: frame, field: "\(mf).mesh")
            operations.append(SampledMaskOperation(
                mode: mode, inverted: mask.inverted, opacity: mask.opacity, mesh: mesh, pathToTarget: world))
        }
        return operations
    }

    /// Validates a layer's matte relationship and returns the resolved source layer + mode, or `nil` if
    /// the layer carries no matte. The compiler renders the source into a surface and emits the link.
    /// Rejects an unsupported mode, a missing source, a source not flagged `isMatteSource`, and a
    /// self-referential (cyclic) link.
    public static func resolveMatte(
        for layer: RenderLayer, layersByID: [Int: RenderLayer], field: String
    ) throws -> (mode: RenderMatteMode, source: RenderLayer)? {
        guard let matte = layer.matte else { return nil }
        guard let mode = RenderMatteMode(rawValue: matte.mode) else {
            throw RenderGraphError.unsupportedLayerMode(field: "\(field).matte.mode", value: String(matte.mode))
        }
        guard matte.sourceLayerID != layer.id else {
            throw RenderGraphError.unsupportedLayerMode(
                field: "\(field).matte.sourceLayerID", value: "self-referential matte (cyclic) on layer \(layer.id)")
        }
        guard let source = layersByID[matte.sourceLayerID] else {
            throw RenderGraphError.unsupportedLayerMode(
                field: "\(field).matte.sourceLayerID", value: "missing source layer \(matte.sourceLayerID)")
        }
        guard source.isMatteSource else {
            throw RenderGraphError.unsupportedLayerMode(
                field: "\(field).matte.sourceLayerID",
                value: "layer \(matte.sourceLayerID) is not flagged isMatteSource")
        }
        return (mode, source)
    }
}
