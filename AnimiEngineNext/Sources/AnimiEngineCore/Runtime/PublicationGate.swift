/// Slice-003 Stage D — the atomic publication gate (ADR-005 §5, §6).
///
/// `evaluate` is the ONLY place a frame becomes publishable. It takes a render attempt (`RenderAttempt`)
/// and the immutable active `SchedulerSnapshot`, and returns `.publish` only when EVERY ADR-005 §5
/// condition holds; otherwise `.keepPrevious(reason:)` — the previously published COMPLETE composition
/// is kept (never a per-layer or temporal substitution, ADR-005 §6). The renderer returns a value; this
/// gate (called by the scheduler, not by any worker callback) decides publication.
///
/// The six §5 conditions, mapped to checks below:
/// 1. one complete `FramePlan` for one `ProjectTime`  → workset internal consistency (single-time).
/// 2. every required input for that exact plan/time resolved → completeness over `requiredInputs`.
/// 3. all identities match active revision + epoch → revision/epoch checks (+ no mixed-epoch inputs).
/// 4. render succeeded and returned a complete value → the candidate token exists (caller passed one).
/// 5. identities revalidated AFTER render → `postRenderRevalidated`.
/// 6. atomic promote → returning `.publish` (the caller performs the single front-buffer swap).
public enum PublicationGate {

    public static func evaluate(
        candidate: RenderAttempt,
        against snapshot: SchedulerSnapshot
    ) -> PublicationDecision {
        let published = candidate.published
        let workset = candidate.workset

        // §6 — no mixed-time / mixed-identity composition: the workset's plan time must equal its
        // request-identity time, and the published token must agree with the workset's full identity
        // tuple (ADR-005 §2/§5) — revision, epoch, frame request, time AND quality. A FramePlan is
        // single-time by construction, so a disagreement means the candidate was assembled from a
        // different request identity (e.g. a different quality profile) than the workset it claims.
        guard workset.isInternallyConsistent,
              published.time == workset.projectTime,
              published.time == workset.identity.time,
              published.revision == workset.identity.revision,
              published.epoch == workset.identity.epoch,
              published.frameRequest == workset.identity.frameRequest,
              published.quality == workset.identity.quality else {
            return .keepPrevious(reason: .incompleteComposition)
        }

        // §5.3 — identity matches the active revision/epoch (stale work cannot publish, ADR-005 §6).
        guard published.revision == snapshot.revision else {
            return .keepPrevious(reason: .staleRevision)
        }
        guard published.epoch == snapshot.epoch else {
            return .keepPrevious(reason: .staleEpoch)
        }

        // Out of coverage: the candidate's time is not within the current coverage.
        guard snapshot.coverage.contains(published.time) else {
            return .keepPrevious(reason: .outsideCoverage)
        }

        // §7 — supersession: the candidate must be the scheduler's latest explicit target (both the
        // exact time and the owning frame request must match the current target).
        guard published.time == snapshot.currentTarget.time,
              published.frameRequest == snapshot.currentTarget.frameRequest else {
            return .keepPrevious(reason: .supersededTarget)
        }

        // §5.2 — completeness: every required input derived from the plan must have resolved, and §6
        // mixed-epoch: every resolved input must share the candidate's epoch.
        let resolvedByInput = Dictionary(
            candidate.resolvedInputs.map { ($0.input, $0.producedUnderEpoch) },
            uniquingKeysWith: { first, _ in first }
        )
        for required in workset.requiredInputs {
            guard let producedEpoch = resolvedByInput[required] else {
                return .keepPrevious(reason: .missingDependency)
            }
            // A resolved input produced under a different epoch would make this a mixed-epoch
            // composition (e.g. a per-layer leftover from a previous epoch) — forbidden.
            guard producedEpoch == published.epoch else {
                return .keepPrevious(reason: .incompleteComposition)
            }
        }

        // §5.5 — post-render re-validation must still match the active snapshot.
        guard candidate.postRenderRevalidated else {
            return .keepPrevious(reason: .postRenderRevalidationFailed)
        }

        // §6 — late-after-newer: a frame older than an already-published newer frame for the same epoch
        // is discarded.
        if let last = snapshot.lastPublished, last.epoch == published.epoch, published.time < last.time {
            return .keepPrevious(reason: .lateAfterNewer)
        }

        // §5.6 — atomic promote: every condition holds; the caller performs the single front-buffer swap.
        return .publish(published)
    }
}
