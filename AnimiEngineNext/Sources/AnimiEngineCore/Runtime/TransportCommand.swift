/// Slice-003 Stage C — transport commands and the scheduler effects the reducer emits (ADR-006 §2,
/// ADR-005 §4). Commands are serialized inputs; effects are the typed work-orders a later scheduler
/// stage will execute. This slice produces the effects but executes none of them (no worksets, no
/// queues, no publication).
public enum TransportCommand: Sendable, Equatable {
    /// User pressed play. From a held state this opens a fresh playback start barrier (ADR-006 §5).
    case play

    /// User paused. While playing, the held time is read from the injected master clock (no wall clock).
    case pause

    /// Seek to an exact project time. A discontinuity: mints a fresh epoch (ADR-005 §4).
    case seek(at: ProjectTime)

    /// Begin a silent scrub gesture (ADR-006 §7). Mints a fresh scrub epoch.
    case scrubBegin(at: ProjectTime)

    /// Update the scrub target. Latest target wins; intermediate targets are superseded.
    case scrubUpdate(target: ProjectTime)

    /// End the scrub gesture. Enters the settle barrier at the exact final target; stays paused after.
    case scrubEnd

    /// An audio interruption. Pauses at the last confirmed time; invalidates the epoch; never resumes.
    case interrupt(at: ProjectTime)

    /// A relevant audio route change. Same non-resuming discontinuity as `interrupt` (ADR-006 §11).
    case routeChange(at: ProjectTime)

    /// A semantic project edit produced a new immutable revision (ADR-005 §1). Invalidates in-flight
    /// work created from the old revision and returns to a safe held state.
    case projectEdit(ProjectRevision)

    /// The transport reached the end of the project at an exact time.
    case endReached(at: ProjectTime)

    /// A typed failure occurred.
    case fail(TransportFailure)

    // MARK: - Prepare-barrier completion signals (ADR-006 §5)
    //
    // These are the bounded outcomes of a prepare barrier. They are NOT scheduler/workset
    // implementation — only the signal that the (externally executed) barrier finished or timed out.

    /// The prepare barrier for `epoch` produced its anchor + first complete frame; enter playing only if
    /// `epoch` still matches the preparing state.
    case prepareCompleted(epoch: PlaybackEpoch)

    /// The prepare barrier for `epoch` exceeded its bounded timeout; enter a typed failure (no
    /// indefinite wait).
    case prepareTimedOut(epoch: PlaybackEpoch)
}

/// The typed work-orders a transport transition emits for a later scheduler stage to execute
/// (ADR-005 §4, ADR-006 §5–§7). Pure values; this slice executes none of them.
public enum SchedulerEffect: Sendable, Equatable {
    /// The fresh accepting epoch the scheduler must adopt before admitting any new work (ADR-005 §4).
    /// Emitted whenever a discontinuity mints a new epoch — INCLUDING discontinuities that land in a
    /// held state (`paused`/`interrupted`/`ended`) whose `TransportState` carries no epoch. The owner
    /// adopts this epoch before flushing queues / admitting completions, so the superseded epoch's work
    /// becomes inadmissible immediately.
    case activateEpoch(PlaybackEpoch)

    /// Stop accepting any completion tagged with the previous epoch (ADR-005 §4.1).
    case stopAcceptingEpoch(PlaybackEpoch)

    /// Cooperatively cancel queued work (ADR-005 §4.2). Cancellation is an optimization; correctness
    /// still comes from identity validation at a later stage.
    case cancelQueued

    /// Flush audio buffers from the old epoch that have not reached the hardware boundary (ADR-005 §4.3).
    case flushUnrenderedAudio(PlaybackEpoch)

    /// Request a complete frame workset for one exact project time (ADR-006 §6). No workset is built
    /// here — only the request order.
    case requestWorkset(ProjectTime)

    /// Keep displaying the previously published complete composition (ADR-005 §6, ADR-006 §6).
    case holdLastPublished

    /// Open the playback start barrier for `epoch` from `from` (ADR-006 §5).
    case beginPrepareBarrier(epoch: PlaybackEpoch, from: ProjectTime)

    /// Start the selected master clock and enter playing (ADR-006 §5.6).
    case enterPlaying(epoch: PlaybackEpoch)

    /// Settle to an exact held project time with no progressing clock.
    case enterPausedAt(ProjectTime)

    /// Record a discarded completion / invalidation as stale evidence (ADR-005 §4.5, §9). Diagnostics
    /// effect; bounded value.
    case recordInvalidation(InvalidationReason)
}

/// Why in-flight work was invalidated, for the stale-evidence diagnostics effect (ADR-005 §4.5, §9).
public enum InvalidationReason: Sendable, Equatable {
    case epochSuperseded(old: PlaybackEpoch, new: PlaybackEpoch)
    case projectRevisionChanged(ProjectRevision)
    case interrupted
    case routeChanged
}
