import AnimiEngineCore

/// Task-003 plan D3-05, §6 — the immutable media transform/clip instruction for one media layer. Per
/// D3-05 the executor "receives final immutable transform and crop instructions [and] does not
/// interpret a product-level fit policy". Here `transform` is the source-pixel → binding-baseline-local
/// stage (step 9 composes it into the final canvas-space transform); `clip` is already in
/// destination (canvas) space.
///
/// §17 step 8 computes this completely:
///   * the explicit `fitMode` the resolver was asked to honour (recorded for evidence/identity);
///   * the `transform` (`FixedAffineTransform2D`) — fit-scale + centering + user transform, as a
///     genuine matrix composition (D3-05);
///   * a ready destination-space `clip` instruction derived from the template's container-clip policy.
///
/// ## Transform contract (step-8 corrective, issue #7)
///
/// `transform` maps **source-pixel space → binding-baseline local space**. It is *not* a full
/// source→canvas transform: it places the user media inside the block's binding baseline only. **Step 9
/// composes it** with the sampled binding-world transform and the block/canvas transform to reach final
/// canvas space; this resolver performs none of that downstream composition. `clip`, by contrast, is
/// already a **destination (canvas) space** instruction (the block canvas rect for `slotRect`), carried
/// verbatim into the graph.
///
/// `cover` is **not** turned into a fixed source crop: an over-covering image is expressed entirely by
/// the transform and bounded by the `clip` instruction. There is no provider, closure or lazy
/// resolution here, and `RenderGraph` compilation (§17 step 9) carries `clip` into the graph and only
/// *composes* (never recomputes) the transform — it performs no fit/clip mathematics.

// The fit mode is the canonical `AnimiEngineCore.MediaFitMode` (step-8 corrective, issue #1): the
// authored input type, not a render-local duplicate. `RenderModel.FitMode` has been removed.

/// A ready destination-space clip instruction (D3-05 "final immutable … crop instructions"). It is
/// computed once in §17 step 8 from the template `containerClip` policy and carried verbatim into the
/// RenderGraph in §17 step 9. `.none` means the media layer is not clipped.
public enum ResolvedClip: Hashable, Sendable {
    /// No clip — the layer composes unclipped.
    case none
    /// Clip to a rectangle in **destination (canvas) space**, fixed point.
    case rect(FixedRect)
}

/// The final, immutable transform + clip instruction for one media layer. Pure fixed-point values;
/// no provider, closure or lazy resolution.
public struct ResolvedMediaPlacement: Hashable, Sendable {
    /// The canonical fit mode that produced this transform (recorded for evidence/identity).
    public let fitMode: MediaFitMode
    /// The affine transform mapping **source-pixel space → binding-baseline local space** (issue #7):
    /// fit + centering + user transform. Step 9 composes it with binding-world and block/canvas
    /// transforms to reach canvas space.
    public let transform: FixedAffineTransform2D
    /// The ready destination-space clip instruction derived from the container-clip policy.
    public let clip: ResolvedClip

    public init(fitMode: MediaFitMode, transform: FixedAffineTransform2D, clip: ResolvedClip) {
        self.fitMode = fitMode
        self.transform = transform
        self.clip = clip
    }

    // MARK: - Canonical encoding (D3-11)

    public func canonicalValue() throws -> RenderCanonicalEncoding.Value {
        let clipValue: RenderCanonicalEncoding.Value
        switch clip {
        case .none:
            clipValue = .object([("kind", .string("none"))])
        case .rect(let rect):
            clipValue = try RenderCanonicalEncoding.object([
                ("height", .int(rect.height.rawValue)),
                ("kind", .string("rect")),
                ("width", .int(rect.width.rawValue)),
                ("x", .int(rect.x.rawValue)),
                ("y", .int(rect.y.rawValue))
            ])
        }
        return try RenderCanonicalEncoding.object([
            ("clip", clipValue),
            ("fitMode", .string(fitMode.rawValue)),
            ("transform", try transform.canonicalValue())
        ])
    }
}
