/// Slice-003 Stage D — the render seam (ADR-005 §5.4). The renderer/worker RETURNS a value to the
/// scheduler; it never publishes. Publication is decided only by `PublicationGate`.
///
/// `render(_:)` returns a `PublishedFrame` token (the complete composed output). It cannot change
/// visible state — there is no publish side effect anywhere in this protocol — so a worker callback
/// physically cannot publish (ADR-005 §6). This slice performs no real rendering: in tests a fake
/// returns a token, and a richer `RenderAttempt` (below) carries the receipts the gate validates.
public protocol RenderResultSource: Sendable {
    /// Render the workset and return the complete composed frame token. Throws on render failure.
    func render(_ workset: FrameWorkset) throws -> PublishedFrame
}

/// A render attempt's full result: the produced `PublishedFrame` plus the receipts the publication gate
/// needs to validate completeness and single-time/single-epoch coherence (ADR-005 §5).
///
/// This is what the scheduler hands to `PublicationGate.evaluate`. It binds the candidate token to the
/// exact workset it came from, the set of inputs that actually RESOLVED during rendering, the epochs
/// those resolved inputs were produced under (for the mixed-epoch check), and whether the scheduler's
/// post-render re-validation still matched the active snapshot.
public struct RenderAttempt: Sendable, Equatable {
    /// The workset that was rendered (carries the single-time plan + derived required inputs).
    public let workset: FrameWorkset
    /// The complete composed-frame token the renderer returned.
    public let published: PublishedFrame
    /// The required inputs that actually resolved for this render, each tagged with the playback epoch
    /// it was produced under. Completeness = these cover every `workset.requiredInputs`; coherence =
    /// every resolved input shares the candidate's epoch.
    public let resolvedInputs: [ResolvedInputReceipt]
    /// Whether the scheduler re-validated identities AFTER rendering and they still matched the active
    /// snapshot (ADR-005 §5.5). The renderer cannot set this true on its own behalf; the scheduler does.
    public let postRenderRevalidated: Bool

    public init(
        workset: FrameWorkset,
        published: PublishedFrame,
        resolvedInputs: [ResolvedInputReceipt],
        postRenderRevalidated: Bool
    ) {
        self.workset = workset
        self.published = published
        self.resolvedInputs = resolvedInputs
        self.postRenderRevalidated = postRenderRevalidated
    }
}

/// One resolved required input plus the epoch it was produced under (ADR-005 §6 mixed-epoch check).
public struct ResolvedInputReceipt: Sendable, Equatable, Hashable {
    public let input: RequiredInput
    public let producedUnderEpoch: PlaybackEpoch

    public init(input: RequiredInput, producedUnderEpoch: PlaybackEpoch) {
        self.input = input
        self.producedUnderEpoch = producedUnderEpoch
    }
}
