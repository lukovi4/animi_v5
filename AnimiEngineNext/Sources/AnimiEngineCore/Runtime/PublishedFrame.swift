/// Slice-003 Stage D — the atomic publication token + the gate's decision/rejection vocabulary
/// (ADR-005 §5, §6).
///
/// A preview frame becomes visible only as one immutable `PublishedFrame`. It carries the complete
/// identity tuple and an OPAQUE complete-composition handle — never pixels, never per-layer surfaces.
/// The handle is a value the renderer returns; this slice does not render, so it is an opaque token.

/// An opaque handle to a complete composed frame produced by the renderer (ADR-005 §5). No pixels; this
/// slice never inspects its contents. Non-empty.
public struct ComposedFrameHandle: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw RuntimeIdentityError.emptyComposedFrameHandle }
        self.raw = raw
    }
}

/// The immutable publication token (ADR-005 §5). The visible output changes only by promoting one of
/// these atomically; nothing partial or per-layer is ever published.
public struct PublishedFrame: Sendable, Equatable {
    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    public let frameRequest: FrameRequestID
    public let time: ProjectTime
    public let quality: QualityProfileID
    /// The complete composed output handle. Opaque; no pixels.
    public let composition: ComposedFrameHandle

    public init(
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        frameRequest: FrameRequestID,
        time: ProjectTime,
        quality: QualityProfileID,
        composition: ComposedFrameHandle
    ) {
        self.revision = revision
        self.epoch = epoch
        self.frameRequest = frameRequest
        self.time = time
        self.quality = quality
        self.composition = composition
    }

    /// The candidate's temporal supersession key (revision, epoch, frame request, time). Quality is
    /// deliberately EXCLUDED here — it is a spatial-substitution axis, not a supersession axis. Quality
    /// is validated separately by the gate's identity-tuple check (`published.quality ==
    /// workset.identity.quality`).
    var identityKey: PublishedIdentityKey {
        PublishedIdentityKey(revision: revision, epoch: epoch, frameRequest: frameRequest, time: time)
    }
}

/// The identity coordinates the gate compares (revision, epoch, frameRequest, time). Quality is a
/// spatial-substitution axis, not a temporal/identity axis, so it is not part of supersession.
struct PublishedIdentityKey: Hashable, Sendable {
    let revision: ProjectRevision
    let epoch: PlaybackEpoch
    let frameRequest: FrameRequestID
    let time: ProjectTime
}

/// The gate's verdict (ADR-005 §5, §6). Either promote one complete frame, or keep the previously
/// published complete composition with a typed reason.
public enum PublicationDecision: Sendable, Equatable {
    case publish(PublishedFrame)
    case keepPrevious(reason: RejectionReason)
}

/// Why a candidate was not published (ADR-005 §5/§6). Every rejection keeps the previous COMPLETE
/// composition — never a per-layer or temporal substitution.
public enum RejectionReason: Sendable, Equatable {
    /// Candidate's project revision is not the active revision (ADR-005 §6).
    case staleRevision
    /// Candidate's playback epoch is not the active epoch (ADR-005 §6).
    case staleEpoch
    /// A newer target for this epoch supersedes the candidate's frame/time (ADR-005 §7).
    case supersededTarget
    /// A required input for the exact plan/time did not resolve (ADR-005 §5.2).
    case missingDependency
    /// Candidate's time lies outside the current coverage.
    case outsideCoverage
    /// The composition is not complete (not every required input present, or the workset is
    /// internally a mixed-time/mixed-epoch composition) (ADR-005 §5.1/§5.2, §6).
    case incompleteComposition
    /// After rendering, re-validation against the (possibly advanced) snapshot no longer matches
    /// (ADR-005 §5.5).
    case postRenderRevalidationFailed
    /// A late frame older than an already-published newer frame for the same epoch (ADR-005 §6).
    case lateAfterNewer
}
