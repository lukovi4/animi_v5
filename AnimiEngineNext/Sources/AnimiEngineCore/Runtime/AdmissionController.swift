/// Slice-003 Stage E — scheduler-owned admission (ADR-005 §4, §7).
///
/// Workers may produce values but never decide that a value is current. `AdmissionController` validates
/// an asynchronous request/completion's identity tuple against the immutable active `SchedulerSnapshot`
/// and admits it only when revision, epoch, and the latest explicit target still match, and the target
/// lies within coverage. Cancellation (Stage C effects) is an OPTIMIZATION; correctness comes from this
/// identity validation — a stale completion that was already submitted (and not cancelled in time) is
/// still rejected here (ADR-005 §4). This slice builds no scheduler owner; admission is a pure decision.
///
/// `RejectionReason` (defined in Stage D) is the failure type of the admission `Result`; the retroactive
/// `Error` conformance below lets it sit in `Result<Void, RejectionReason>` without changing its Stage-D
/// definition.
extension RejectionReason: Error {}

public enum AdmissionController {

    /// Admit a preview request/completion identity against the active snapshot, or reject with a typed
    /// reason. Pure; no side effects, no publication.
    public static func admit(
        _ identity: RequestIdentity,
        against snapshot: SchedulerSnapshot
    ) -> Result<Void, RejectionReason> {
        // §4/§6 — identity must match the active revision and epoch (stale work cannot be admitted).
        guard identity.revision == snapshot.revision else { return .failure(.staleRevision) }
        guard identity.epoch == snapshot.epoch else { return .failure(.staleEpoch) }

        // Out of coverage: the requested time is not within the current coverage.
        guard snapshot.coverage.contains(identity.time) else { return .failure(.outsideCoverage) }

        // §7 — supersession: only the latest explicit target (exact time AND owning frame request) is
        // admissible. An intermediate/older target is superseded.
        guard identity.time == snapshot.currentTarget.time,
              identity.frameRequest == snapshot.currentTarget.frameRequest else {
            return .failure(.supersededTarget)
        }

        return .success(())
    }

    /// Admit a completion that ALSO carries resolved dependencies (a render attempt). In addition to the
    /// identity-tuple checks, every required input derived from the workset must have resolved under the
    /// candidate's epoch; a missing or wrong-epoch dependency is rejected. Quality must match the
    /// workset's requested quality (ADR-005 §2/§5). This mirrors the completeness portion of the
    /// publication gate WITHOUT performing publication.
    public static func admit(
        _ attempt: RenderAttempt,
        against snapshot: SchedulerSnapshot
    ) -> Result<Void, RejectionReason> {
        let published = attempt.published
        let workset = attempt.workset

        // The published token must agree with the workset's full request identity (no mixed identity).
        guard workset.isInternallyConsistent,
              published.time == workset.identity.time,
              published.revision == workset.identity.revision,
              published.epoch == workset.identity.epoch,
              published.frameRequest == workset.identity.frameRequest,
              published.quality == workset.identity.quality else {
            return .failure(.missingDependency)
        }

        // Identity-tuple admission against the active snapshot.
        if case let .failure(reason) = admit(workset.identity, against: snapshot) {
            return .failure(reason)
        }

        // Completeness + single-epoch: every required input resolved under the candidate's epoch.
        let resolvedByInput = Dictionary(
            attempt.resolvedInputs.map { ($0.input, $0.producedUnderEpoch) },
            uniquingKeysWith: { first, _ in first }
        )
        for required in workset.requiredInputs {
            guard let producedEpoch = resolvedByInput[required] else { return .failure(.missingDependency) }
            guard producedEpoch == published.epoch else { return .failure(.staleEpoch) }
        }

        return .success(())
    }

    /// Admit a bare `PublishedFrame` token against the snapshot by its identity coordinates (revision,
    /// epoch, target time + frame request, coverage). Convenience over the `RequestIdentity` form.
    public static func admit(
        _ published: PublishedFrame,
        against snapshot: SchedulerSnapshot
    ) -> Result<Void, RejectionReason> {
        guard published.revision == snapshot.revision else { return .failure(.staleRevision) }
        guard published.epoch == snapshot.epoch else { return .failure(.staleEpoch) }
        guard snapshot.coverage.contains(published.time) else { return .failure(.outsideCoverage) }
        guard published.time == snapshot.currentTarget.time,
              published.frameRequest == snapshot.currentTarget.frameRequest else {
            return .failure(.supersededTarget)
        }
        return .success(())
    }
}
