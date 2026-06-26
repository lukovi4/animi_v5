/// Slice-004 Stage F — the canonical playback-start barrier (ADR-005 §4/§8, ADR-006 §3/§5/§9,
/// ADR-012 §2).
///
/// **No audible playback may begin before the first video frame for the epoch is ready.** The barrier
/// is the single gate that enforces that invariant together with the rest of the start contract: a
/// matching revision/epoch, the preview graph's output configured and anchor configured, and — only
/// for an audio-bearing epoch — the initial bounded audio mix/preroll scheduled. Until **every**
/// required gate is satisfied the barrier is not `ready`, so the session never schedules audio nor
/// declares playback started.
///
/// This is a **pure synchronous value state machine**. There is no async, no actor, no realtime thread,
/// no PCM storage, and no `AVAudioEngine` here (the only AV surface remains the existing
/// `PreviewAudioGraph` adapter, driven by `AudioMasterPreviewSession`). Time is an **injected,
/// monotonic, non-negative tick provider** (never `Date`/`DispatchTime`), and the timeout bound is an
/// **injected** runtime value (ADR-006 §9 — never a hardcoded deadline). Every failure is a typed,
/// fail-closed `PlaybackStartBarrierError`.

// MARK: - Typed errors

/// Fail-closed failures evaluating the playback-start barrier (Slice-004 Stage F). Distinct from the
/// graph's `PreviewAudioGraphError` and the device boundary's `RealtimeAudioBoundaryError`.
public enum PlaybackStartBarrierError: Error, Equatable, Sendable {
    /// A readiness signal carried a revision that is not the barrier's active revision (stale edit).
    case staleRevision(signal: ProjectRevision, active: ProjectRevision)
    /// A readiness signal carried an epoch that is not the barrier's active epoch (superseded transport).
    case staleEpoch(signal: PlaybackEpoch, active: PlaybackEpoch)
    /// The injected monotonic tick provider moved backwards or returned a negative tick.
    case nonMonotonicTime(previous: Int64, current: Int64)
    /// The barrier exceeded its injected timeout bound before all required gates were satisfied. The
    /// `missing` set names exactly which gates were still unmet, for honest diagnosis.
    case timedOut(elapsedTicks: Int64, timeoutTicks: Int64, missing: [PlaybackStartGate])
    /// A non-positive injected timeout bound (ADR-006 §9 — a bound must be a positive runtime value).
    case invalidTimeout(Int64)
    /// Attempted to mark the audio preroll satisfied for a no-audio epoch (the audio gate is not part of
    /// a host-clock epoch's required set — marking it would be a contract violation, not a no-op).
    case audioGateNotRequiredForHostEpoch
}

// MARK: - The required start gates

/// One named precondition for audible playback to begin (ADR-005 §4/§8, ADR-006 §3/§5). The required
/// *set* depends on the epoch's master clock: a `.monotonicHost` (no-audio / all-muted) epoch does not
/// require the audio preroll gate.
public enum PlaybackStartGate: String, Sendable, Equatable, CaseIterable {
    /// The first composed video frame for this epoch has resolved and is ready to present. Audible
    /// playback may NEVER start before this gate (the core Stage-F invariant).
    case firstFrameReady
    /// The preview graph's actual output format/route has been configured (post-activation).
    case outputConfigured
    /// The scheduler-controlled `PreviewAudioScheduleAnchor` for this epoch has been installed.
    case anchorConfigured
    /// The initial bounded audio mix/preroll has been scheduled through `PreviewAudioGraph.scheduleMix`.
    /// Required ONLY for an audio-bearing epoch; absent from a host-clock epoch's required set.
    case initialAudioScheduled
}

// MARK: - The barrier (pure value state machine)

/// Accumulates the start gates for one epoch and reports readiness only when **all required** gates are
/// satisfied, or a typed timeout/staleness failure. Immutable-by-replacement: each `marking…`/`tick`
/// call returns a fresh barrier; nothing mutates in place, so a caller can hold and compare snapshots.
///
/// The `audioBearing` flag (derived once per epoch from the existing `MasterClockSelector`, never
/// re-decided here) fixes the required gate set: audio-bearing ⇒ all four gates; host ⇒ all but
/// `initialAudioScheduled`. The barrier never *causes* audio scheduling; it only records that the
/// session already scheduled the bounded initial preroll (which the session does strictly after the
/// first frame is ready).
public struct PlaybackStartBarrier: Sendable, Equatable {

    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    /// Whether this epoch's master clock is the audio-sample clock (decided upstream by
    /// `MasterClockSelector`); fixes whether `initialAudioScheduled` is a required gate.
    public let audioBearing: Bool
    /// Injected positive timeout bound in monotonic ticks (runtime config, never hardcoded).
    public let timeoutTicks: Int64
    /// The monotonic tick at which the barrier started waiting (the first observed tick).
    public let startTick: Int64
    /// The most recently observed monotonic tick (for monotonicity checking).
    public let lastObservedTick: Int64
    /// The set of gates satisfied so far.
    public let satisfied: Set<PlaybackStartGate>

    /// The gates this epoch requires before audible playback may begin.
    public var requiredGates: Set<PlaybackStartGate> {
        var gates: Set<PlaybackStartGate> = [.firstFrameReady, .outputConfigured, .anchorConfigured]
        if audioBearing { gates.insert(.initialAudioScheduled) }
        return gates
    }

    /// The still-unmet required gates, in a stable `CaseIterable` order (for honest diagnosis).
    public var missingGates: [PlaybackStartGate] {
        let req = requiredGates
        return PlaybackStartGate.allCases.filter { req.contains($0) && !satisfied.contains($0) }
    }

    /// `true` only when every required gate is satisfied. The session consults this — and only this —
    /// before declaring playback started / before the clock begins delivering audible time.
    public var isReady: Bool { missingGates.isEmpty }

    /// Begin waiting at an initial monotonic tick. Fail-closed: a non-positive timeout or a negative
    /// start tick is rejected (no silent clamp).
    public init(
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        audioBearing: Bool,
        timeoutTicks: Int64,
        startTick: Int64
    ) throws {
        guard timeoutTicks > 0 else { throw PlaybackStartBarrierError.invalidTimeout(timeoutTicks) }
        guard startTick >= 0 else {
            throw PlaybackStartBarrierError.nonMonotonicTime(previous: 0, current: startTick)
        }
        self.revision = revision
        self.epoch = epoch
        self.audioBearing = audioBearing
        self.timeoutTicks = timeoutTicks
        self.startTick = startTick
        self.lastObservedTick = startTick
        self.satisfied = []
    }

    /// Internal full-field initializer for the pure `with…` transitions.
    private init(
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        audioBearing: Bool,
        timeoutTicks: Int64,
        startTick: Int64,
        lastObservedTick: Int64,
        satisfied: Set<PlaybackStartGate>
    ) {
        self.revision = revision
        self.epoch = epoch
        self.audioBearing = audioBearing
        self.timeoutTicks = timeoutTicks
        self.startTick = startTick
        self.lastObservedTick = lastObservedTick
        self.satisfied = satisfied
    }

    /// Reject any readiness signal whose identity does not match the active revision/epoch (ADR-005 §6).
    private func requireMatchingIdentity(
        revision: ProjectRevision, epoch: PlaybackEpoch
    ) throws {
        guard revision == self.revision else {
            throw PlaybackStartBarrierError.staleRevision(signal: revision, active: self.revision)
        }
        guard epoch == self.epoch else {
            throw PlaybackStartBarrierError.staleEpoch(signal: epoch, active: self.epoch)
        }
    }

    private func satisfying(_ gate: PlaybackStartGate) -> PlaybackStartBarrier {
        var next = satisfied
        next.insert(gate)
        return PlaybackStartBarrier(
            revision: revision, epoch: epoch, audioBearing: audioBearing,
            timeoutTicks: timeoutTicks, startTick: startTick,
            lastObservedTick: lastObservedTick, satisfied: next)
    }

    /// Mark the first composed video frame ready for this epoch (identity-checked).
    public func markingFirstFrameReady(
        revision: ProjectRevision, epoch: PlaybackEpoch
    ) throws -> PlaybackStartBarrier {
        try requireMatchingIdentity(revision: revision, epoch: epoch)
        return satisfying(.firstFrameReady)
    }

    /// Mark the preview graph output configured (identity-checked).
    public func markingOutputConfigured(
        revision: ProjectRevision, epoch: PlaybackEpoch
    ) throws -> PlaybackStartBarrier {
        try requireMatchingIdentity(revision: revision, epoch: epoch)
        return satisfying(.outputConfigured)
    }

    /// Mark the schedule anchor configured (identity-checked).
    public func markingAnchorConfigured(
        revision: ProjectRevision, epoch: PlaybackEpoch
    ) throws -> PlaybackStartBarrier {
        try requireMatchingIdentity(revision: revision, epoch: epoch)
        return satisfying(.anchorConfigured)
    }

    /// Mark the bounded initial audio mix/preroll scheduled (identity-checked). The session may call
    /// this ONLY after the first frame is ready and ONLY for an audio-bearing epoch; marking it for a
    /// host-clock epoch is a typed contract violation (fail-closed), not a silent no-op.
    public func markingInitialAudioScheduled(
        revision: ProjectRevision, epoch: PlaybackEpoch
    ) throws -> PlaybackStartBarrier {
        try requireMatchingIdentity(revision: revision, epoch: epoch)
        guard audioBearing else { throw PlaybackStartBarrierError.audioGateNotRequiredForHostEpoch }
        return satisfying(.initialAudioScheduled)
    }

    /// Advance the observed monotonic time and fail closed if the injected timeout elapsed before all
    /// required gates were met. Returns a barrier with the new observed tick when still within budget.
    /// Monotonicity is enforced (the provider must never go backwards).
    public func ticking(toMonotonicTick now: Int64) throws -> PlaybackStartBarrier {
        guard now >= lastObservedTick else {
            throw PlaybackStartBarrierError.nonMonotonicTime(previous: lastObservedTick, current: now)
        }
        // Checked elapsed since start; the provider is non-negative and monotonic so this never wraps.
        let elapsed = try CheckedInt64.subtract(now, startTick, "PlaybackStartBarrier.elapsed")
        if !isReady && elapsed > timeoutTicks {
            throw PlaybackStartBarrierError.timedOut(
                elapsedTicks: elapsed, timeoutTicks: timeoutTicks, missing: missingGates)
        }
        return PlaybackStartBarrier(
            revision: revision, epoch: epoch, audioBearing: audioBearing,
            timeoutTicks: timeoutTicks, startTick: startTick,
            lastObservedTick: now, satisfied: satisfied)
    }
}
