/// Slice-003 Stage C — the pure transport reducer (ADR-006 §2, ADR-005 §4).
///
/// `reduce` is a pure function of (current state, command, injected clock, current revision) and a
/// monotonic epoch allocator. It returns the next `TransportState` and the ordered `SchedulerEffect`s a
/// later scheduler stage executes. It never reads a wall clock (time comes from the injected
/// `MasterClock`), never builds worksets/queues, and never publishes.
///
/// Invariant (ADR-005 §4): every discontinuity that can invalidate in-flight work mints a **fresh
/// `PlaybackEpoch` before any new work is admitted**, and emits the invalidation effects for the
/// superseded epoch *before* the request for new work.
public enum TransportReducer {

    public static func reduce(
        _ state: TransportState,
        _ command: TransportCommand,
        clock: MasterClock?,
        currentRevision: ProjectRevision,
        epochs: inout some EpochAllocator
    ) throws -> (TransportState, [SchedulerEffect]) {
        switch command {

        // MARK: play — open a fresh prepare barrier from a held state (no auto-resume elsewhere)

        case .play:
            switch state {
            case let .paused(at), let .interrupted(at), let .ended(at):
                return prepareBarrier(from: at, superseding: nil, epochs: &epochs)
            case let .settling(target, epoch):
                // Settle holds paused; an explicit play opens a new barrier from the settled target,
                // superseding the settle epoch.
                return prepareBarrier(from: target, superseding: epoch, epochs: &epochs)
            case .preparing, .playing, .scrubbing, .failed:
                // Already live or barriered, or failed: play is a no-op (no second barrier, no resume).
                return (state, [])
            }

        // MARK: pause — hold at exact time; while playing, read the injected clock (no wall clock)

        case .pause:
            switch state {
            case let .playing(epoch):
                // Pause is a discontinuity: mint a fresh quiescent epoch so the OLD playing epoch is no
                // longer admissible, even though `paused` carries no epoch (ADR-005 §4).
                let at = try currentTime(clock)
                return (.paused(at: at), invalidateAndActivateFresh(superseding: epoch, epochs: &epochs) + [.enterPausedAt(at)])
            case let .preparing(from, epoch):
                // Abort the barrier; it has not started a clock yet, so hold EXACTLY at its known start
                // time `from`. No clock is read here (the barrier never advanced time).
                return (.paused(at: from), invalidateAndActivateFresh(superseding: epoch, epochs: &epochs) + [.enterPausedAt(from)])
            case let .scrubbing(target, epoch), let .settling(target, epoch):
                return (.paused(at: target), invalidateAndActivateFresh(superseding: epoch, epochs: &epochs) + [.enterPausedAt(target)])
            case let .paused(at):
                return (.paused(at: at), [])
            case let .interrupted(at), let .ended(at):
                return (.paused(at: at), [.enterPausedAt(at)])
            case .failed:
                return (state, [])
            }

        // MARK: seek — discontinuity: fresh epoch, request exact target work

        case let .seek(at):
            let old = activeEpoch(of: state)
            // Mint a fresh epoch so any old-epoch completion is sealed off before the new request, even
            // though seek lands in a held (paused) state that carries no epoch.
            let (_, effects) = mintWithInvalidation(superseding: old, epochs: &epochs)
            return (.paused(at: at), effects + [.holdLastPublished, .requestWorkset(at)])

        // MARK: scrub — silent, held, latest-target-wins

        case let .scrubBegin(at):
            let old = activeEpoch(of: state)
            let (epoch, effects) = mintWithInvalidation(superseding: old, epochs: &epochs)
            return (.scrubbing(target: at, epoch: epoch), effects + [.holdLastPublished, .requestWorkset(at)])

        case let .scrubUpdate(target):
            switch state {
            case let .scrubbing(_, epoch):
                // Latest target wins at the state level; the old target is superseded WITHIN the same
                // scrub epoch (no new epoch — same uninterrupted gesture), older target work is
                // cancelled and the new exact target is requested.
                return (.scrubbing(target: target, epoch: epoch),
                        [.cancelQueued, .holdLastPublished, .requestWorkset(target)])
            default:
                // A scrub update without an active scrub is ignored (no gesture in progress).
                return (state, [])
            }

        case .scrubEnd:
            switch state {
            case let .scrubbing(target, epoch):
                // Enter the settle barrier at the EXACT final target; stay paused after settle (no
                // auto-play). The settle keeps the same epoch (still one uninterrupted interpretation
                // until resolved) and requests the exact final frame.
                return (.settling(target: target, epoch: epoch),
                        [.holdLastPublished, .requestWorkset(target)])
            default:
                return (state, [])
            }

        // MARK: interrupt / routeChange — pause-only, never resume (ADR-006 §11)

        case let .interrupt(at):
            // A discontinuity into a held state: mint a fresh quiescent epoch so the OLD epoch is no
            // longer admissible (ADR-005 §4), even though `interrupted` carries no epoch.
            let old = activeEpoch(of: state)
            var effects = invalidateAndActivateFresh(superseding: old, epochs: &epochs)
            effects.append(.recordInvalidation(.interrupted))
            effects.append(.enterPausedAt(at))
            return (.interrupted(at: at), effects)

        case let .routeChange(at):
            let old = activeEpoch(of: state)
            var effects = invalidateAndActivateFresh(superseding: old, epochs: &epochs)
            effects.append(.recordInvalidation(.routeChanged))
            effects.append(.enterPausedAt(at))
            return (.interrupted(at: at), effects)

        // MARK: projectEdit — invalidate old-revision work, return to a safe held state

        case let .projectEdit(revision):
            let old = activeEpoch(of: state)
            // Mint a fresh quiescent epoch so old-revision/old-epoch work is immediately inadmissible.
            var effects = invalidateAndActivateFresh(superseding: old, epochs: &epochs)
            effects.append(.recordInvalidation(.projectRevisionChanged(revision)))
            // Return to a safe held state at the current held/last time. No new work is admitted from the
            // old revision; a subsequent play/seek mints a barrier from the NEW revision.
            let at = heldTime(of: state, clock: clock)
            effects.append(.holdLastPublished)
            return (.paused(at: at), effects)

        // MARK: endReached / fail

        case let .endReached(at):
            let old = activeEpoch(of: state)
            return (.ended(at: at), invalidateAndActivateFresh(superseding: old, epochs: &epochs) + [.enterPausedAt(at)])

        case let .fail(failure):
            let old = activeEpoch(of: state)
            return (.failed(failure), invalidateAndActivateFresh(superseding: old, epochs: &epochs))

        // MARK: prepare-barrier completion (ADR-006 §5)

        case let .prepareCompleted(epoch):
            // Enter playing ONLY from a matching preparing epoch; a completion for any other epoch is a
            // stale barrier signal and is recorded, not applied.
            if case let .preparing(_, preparing) = state, preparing == epoch {
                return (.playing(epoch: epoch), [.enterPlaying(epoch: epoch)])
            }
            return (state, [.recordInvalidation(.epochSuperseded(old: epoch, new: activeEpoch(of: state) ?? epoch))])

        case let .prepareTimedOut(epoch):
            // Bounded timeout ⇒ typed failure; never an indefinite wait. Only the currently-preparing
            // epoch's timeout fails the transport. The barrier's epoch is sealed off AND a fresh quiescent
            // accepting epoch is minted, so the timed-out epoch's in-flight work is immediately
            // inadmissible even though `failed` carries no epoch (ADR-005 §4).
            if case let .preparing(from, preparing) = state, preparing == epoch {
                return (.failed(.prepareTimedOut(epoch: epoch, from: from)),
                        invalidateAndActivateFresh(superseding: epoch, epochs: &epochs))
            }
            return (state, [.recordInvalidation(.epochSuperseded(old: epoch, new: activeEpoch(of: state) ?? epoch))])
        }
    }

    // MARK: - Helpers

    /// Open a prepare barrier: mint a fresh epoch (superseding `superseding` if present, emitting its
    /// invalidation effects first), then `beginPrepareBarrier`. Enters `preparing`.
    private static func prepareBarrier(
        from: ProjectTime,
        superseding: PlaybackEpoch?,
        epochs: inout some EpochAllocator
    ) -> (TransportState, [SchedulerEffect]) {
        let (epoch, effects) = mintWithInvalidation(superseding: superseding, epochs: &epochs)
        return (.preparing(from: from, epoch: epoch),
                effects + [.beginPrepareBarrier(epoch: epoch, from: from)])
    }

    /// Mint a fresh epoch and, when an old epoch is being superseded, emit its invalidation effects
    /// BEFORE any new-work effect (ADR-005 §4): stop accepting, cancel queued, flush old audio, record.
    private static func mintWithInvalidation(
        superseding old: PlaybackEpoch?,
        epochs: inout some EpochAllocator
    ) -> (PlaybackEpoch, [SchedulerEffect]) {
        // Invalidation of the OLD epoch is computed first so the fresh epoch is minted only after the old
        // one is sealed off in the effect order.
        var effects: [SchedulerEffect] = []
        if let old {
            effects.append(.stopAcceptingEpoch(old))
            effects.append(.cancelQueued)
            effects.append(.flushUnrenderedAudio(old))
        }
        let epoch = epochs.next()
        if let old {
            effects.append(.recordInvalidation(.epochSuperseded(old: old, new: epoch)))
        }
        // The fresh epoch is the new accepting epoch. Emit it explicitly so the owner adopts it even when
        // the resulting state (a held paused/interrupted/ended) carries no epoch (ADR-005 §4).
        effects.append(.activateEpoch(epoch))
        return (epoch, effects)
    }

    /// Invalidation effects for an old epoch (no new epoch minted), prepended to `tail`.
    private static func invalidate(_ old: PlaybackEpoch?, _ tail: [SchedulerEffect]) -> [SchedulerEffect] {
        guard let old else { return tail }
        return [.stopAcceptingEpoch(old), .cancelQueued, .flushUnrenderedAudio(old)] + tail
    }

    /// For a discontinuity that lands in a held state (paused/interrupted/ended/failed): seal off the old
    /// epoch AND mint a fresh quiescent accepting epoch, emitting `.activateEpoch`. The held state itself
    /// carries no epoch, so this effect is the only way the owner learns the new accepting epoch — and
    /// thus the only thing that makes the old epoch's in-flight work inadmissible (ADR-005 §4).
    private static func invalidateAndActivateFresh(
        superseding old: PlaybackEpoch?,
        epochs: inout some EpochAllocator
    ) -> [SchedulerEffect] {
        var effects: [SchedulerEffect] = []
        if let old {
            effects.append(.stopAcceptingEpoch(old))
            effects.append(.cancelQueued)
            effects.append(.flushUnrenderedAudio(old))
        }
        let epoch = epochs.next()
        if let old {
            effects.append(.recordInvalidation(.epochSuperseded(old: old, new: epoch)))
        }
        effects.append(.activateEpoch(epoch))
        return effects
    }

    /// The epoch a state is actively running/preparing/scrubbing/settling under, if any. Held/ended
    /// states have no active epoch.
    private static func activeEpoch(of state: TransportState) -> PlaybackEpoch? {
        switch state {
        case let .preparing(_, epoch), let .playing(epoch),
             let .scrubbing(_, epoch), let .settling(_, epoch):
            return epoch
        case .paused, .interrupted, .ended, .failed:
            return nil
        }
    }

    /// The exact held project time of a state. For `playing`/`preparing` (no explicit held time) the
    /// injected clock supplies the current time; `zero` only if no clock was injected.
    private static func heldTime(of state: TransportState, clock: MasterClock?) -> ProjectTime {
        switch state {
        case let .paused(at), let .interrupted(at), let .ended(at):
            return at
        case let .preparing(from, _):
            return from
        case let .scrubbing(target, _), let .settling(target, _):
            return target
        case .playing:
            return (try? clock?.currentProjectTime()) ?? ProjectTime.zero
        case .failed:
            return ProjectTime.zero
        }
    }

    /// Read the injected master clock; a `pause` while playing requires a clock to read the held time.
    private static func currentTime(_ clock: MasterClock?) throws -> ProjectTime {
        guard let clock else { throw TransportReducerError.missingClockForPause }
        return try clock.currentProjectTime()
    }
}

public enum TransportReducerError: Error, Equatable, Sendable {
    /// `pause` while `playing` needs the injected master clock to read the held project time.
    case missingClockForPause
}
