/// Slice-003 Stage F — the minimal serialized scheduler owner (ADR-006 §1).
///
/// One `EngineScheduler` owns the transport state, the active project revision and playback epoch, the
/// bounded queues, the last published complete frame, and the selected master-clock kind. It is the ONLY
/// place these mutate, and every mutation goes through an explicit method. It does no work itself — it
/// routes commands through the existing pure `TransportReducer`, validates completions through
/// `AdmissionController`, and decides publication through `PublicationGate`. It is synchronous: no
/// `async`/`actor`, no realtime workers, no app integration.
///
/// This is intentionally minimal — exactly the wiring the plan (§3.6) calls for so queues + admission +
/// snapshot compose under one owner — and nothing more (no fps tiers, no decode, no device).
public struct EngineScheduler {

    // MARK: - Owned state (mutated only through methods)

    public private(set) var transport: TransportState
    public private(set) var revision: ProjectRevision
    public private(set) var activeEpoch: PlaybackEpoch
    public private(set) var coverage: ProjectTimeRange
    public private(set) var currentTarget: CurrentTarget
    public private(set) var lastPublished: PublishedIdentitySummary?
    public private(set) var masterClockKind: MasterClockKind?

    public private(set) var worksetQueue: BoundedQueue<FrameWorkset>
    public private(set) var audioRangeQueue: BoundedQueue<DecodedAudioRangeDescriptor>

    /// Optional bounded diagnostics. Purely observational — recording events never changes any decision
    /// (ADR-005 §9). `nil` disables diagnostics entirely.
    public private(set) var diagnostics: BoundedDiagnosticsSink?

    private var epochs: MonotonicEpochAllocator
    private let clock: MasterClock?

    public init(
        transport: TransportState,
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        coverage: ProjectTimeRange,
        currentTarget: CurrentTarget,
        masterClockKind: MasterClockKind?,
        epochs: MonotonicEpochAllocator,
        clock: MasterClock?,
        worksetQueueCapacity: Int,
        audioRangeQueueCapacity: Int,
        diagnostics: BoundedDiagnosticsSink? = nil
    ) throws {
        self.transport = transport
        self.revision = revision
        self.activeEpoch = epoch
        self.coverage = coverage
        self.currentTarget = currentTarget
        self.lastPublished = nil
        self.masterClockKind = masterClockKind
        self.epochs = epochs
        self.clock = clock
        self.worksetQueue = try BoundedQueue<FrameWorkset>(capacity: worksetQueueCapacity)
        self.audioRangeQueue = try BoundedQueue<DecodedAudioRangeDescriptor>(capacity: audioRangeQueueCapacity)
        self.diagnostics = diagnostics
    }

    /// Append a diagnostic event when a sink is attached. No-op when diagnostics are disabled. Purely
    /// observational; never influences a decision.
    private mutating func emit(_ event: SchedulerDiagnosticEvent) {
        diagnostics?.record(event)
    }

    // MARK: - Immutable view

    /// The immutable snapshot gates and admission validate against.
    public var snapshot: SchedulerSnapshot {
        SchedulerSnapshot(
            revision: revision, epoch: activeEpoch, coverage: coverage,
            currentTarget: currentTarget, lastPublished: lastPublished
        )
    }

    // MARK: - Transport commands

    /// Accept a transport command: route it through the pure reducer, then adopt the resulting state and
    /// the active epoch it carries. A discontinuity therefore mints a fresh epoch (in the reducer) BEFORE
    /// any completion can be admitted against the new snapshot. Old-epoch audio ranges are flushed.
    @discardableResult
    public mutating func accept(_ command: TransportCommand) throws -> [SchedulerEffect] {
        let (newState, effects) = try TransportReducer.reduce(
            transport, command, clock: clock, currentRevision: revision, epochs: &epochs
        )
        transport = newState
        // Adopt the fresh accepting epoch from the canonical `.activateEpoch` effect BEFORE flushing
        // queues or admitting any completion. This is the ONLY reliable source of the new accepting epoch
        // for discontinuities that land in a held state (paused/interrupted/ended) carrying no epoch — it
        // is what makes the superseded epoch's work inadmissible (ADR-005 §4). A state that does carry an
        // epoch (preparing/playing/scrubbing/settling) agrees with the activated epoch.
        let previousEpoch = activeEpoch
        for effect in effects {
            if case let .activateEpoch(epoch) = effect { activeEpoch = epoch }
        }
        if case let .projectEdit(newRevision) = command {
            revision = newRevision
        }
        if activeEpoch != previousEpoch {
            emit(.epochTransition(from: previousEpoch, to: activeEpoch))
        }
        // Flush not-yet-rendered audio ranges from any superseded epoch (ADR-005 §8, §4.3).
        let flushed = audioRangeQueue.removeAll { $0.epoch != activeEpoch }
        if flushed > 0 {
            emit(.audioFlushed(count: flushed, supersededInto: activeEpoch))
        }
        return effects
    }

    /// Set the latest explicit target the scheduler wants published (e.g. after a seek/scrub request).
    public mutating func setCurrentTarget(_ target: CurrentTarget) {
        currentTarget = target
    }

    // MARK: - Queue admission

    /// Enqueue a frame workset under bounded backpressure; obsolete (wrong-epoch) worksets are evicted
    /// first. The workset is obsolete when its identity epoch is not the active epoch.
    @discardableResult
    public mutating func enqueueWorkset(_ workset: FrameWorkset) -> Result<AdmissionOutcome<FrameWorkset>, BackpressureError> {
        emit(.requested(workset.identity))
        let active = activeEpoch
        let result = worksetQueue.admit(workset) { $0.identity.epoch != active }
        emit(.queueOccupancy(queue: .workset, count: worksetQueue.count, capacity: worksetQueue.capacity))
        return result
    }

    /// Enqueue a decoded audio range. It is first admitted by identity (stale revision/epoch rejected),
    /// then placed under bounded backpressure; obsolete (wrong-epoch) ranges are evicted first.
    public mutating func enqueueAudioRange(
        _ descriptor: DecodedAudioRangeDescriptor
    ) -> Result<AdmissionOutcome<DecodedAudioRangeDescriptor>, AudioEnqueueError> {
        if case let .failure(reason) = AudioRangeAdmission.admit(descriptor, against: snapshot) {
            emit(.audioRange(reason: reason, epoch: descriptor.epoch, request: descriptor.request))
            return .failure(.rejected(reason))
        }
        emit(.audioRange(reason: nil, epoch: descriptor.epoch, request: descriptor.request))
        let active = activeEpoch
        let result = audioRangeQueue.admit(descriptor, isObsolete: { $0.epoch != active })
        emit(.queueOccupancy(queue: .audioRange, count: audioRangeQueue.count, capacity: audioRangeQueue.capacity))
        switch result {
        case let .success(outcome): return .success(outcome)
        case let .failure(backpressure): return .failure(.backpressure(backpressure))
        }
    }

    // MARK: - Completion admission + publication

    /// Validate a render attempt against the current snapshot WITHOUT publishing. `mutating` only so it
    /// can append a diagnostic event — the admission DECISION is unchanged (it is still
    /// `AdmissionController.admit` against the immutable snapshot); recording is purely observational.
    @discardableResult
    public mutating func admit(_ attempt: RenderAttempt) -> Result<Void, RejectionReason> {
        let result = AdmissionController.admit(attempt, against: snapshot)
        switch result {
        case .success:
            emit(.admitted(attempt.workset.identity))
        case let .failure(reason):
            emit(.rejected(reason: reason, time: attempt.workset.identity.time, epoch: attempt.workset.identity.epoch))
        }
        return result
    }

    /// Decide publication of a render attempt through the gate. On `.publish`, record it as the last
    /// published frame (atomic promote) and return the decision; on `.keepPrevious`, the previously
    /// published complete composition is kept unchanged.
    @discardableResult
    public mutating func publish(_ attempt: RenderAttempt) -> PublicationDecision {
        let decision = PublicationGate.evaluate(candidate: attempt, against: snapshot)
        switch decision {
        case let .publish(frame):
            let previous = lastPublished
            let new = PublishedIdentitySummary(epoch: frame.epoch, time: frame.time, frameRequest: frame.frameRequest)
            lastPublished = new
            emit(.published(previous: previous, new: new))
        case let .keepPrevious(reason):
            emit(.keptPrevious(reason: reason))
        }
        return decision
    }
}

/// Why an audio-range enqueue failed: rejected by identity, or rejected by bounded backpressure.
public enum AudioEnqueueError: Error, Equatable, Sendable {
    case rejected(RejectionReason)
    case backpressure(BackpressureError)
}
