/// Slice-004 Stage F — the canonical preview playback-start session (ADR-005 §4/§8, ADR-006 §3/§5/§9,
/// ADR-012 §2).
///
/// `AudioMasterPreviewSession` is the small, pure orchestrator that ties together — for one epoch —
/// the start contract the rest of Slice 004 already implements piecewise:
///
///   * the `TransportReducer`/`EngineScheduler` epoch+revision identity (carried in, never invented),
///   * the **already-decided** `MasterClockKind` from `MasterClockSelector` (audio-sample vs host —
///     never re-evaluated here),
///   * the chosen master clock instance (`AudioSampleMasterClock` / `MonotonicHostMasterClock`),
///   * the `PreviewAudioGraph` AV boundary (the ONLY `AVAudioEngine` surface — this file imports no
///     audio framework and stores no PCM beyond the graph's own bounded sample arrays),
///   * first-frame readiness, and the bounded initial audio preroll,
///   * via the `PlaybackStartBarrier`.
///
/// ## The two paths (ADR-006 §3)
///
///   * **Audio-bearing epoch** (`.audioSample`): the audio render clock is master. The session
///     configures the graph output + the schedule anchor, then — strictly **after** the first frame is
///     ready — schedules **one bounded initial preroll** through `PreviewAudioGraph.scheduleMix` (the
///     post-mix-output-stage path; never the removed per-source schedule), marks the barrier's audio
///     gate, and starts only when the barrier is ready.
///   * **No-audio / all-muted epoch** (`.monotonicHost`): an injected monotonic host clock is master and
///     **no audio is ever scheduled** — the audio gate is not even part of the required set.
///
/// ## What it deliberately does not do
///
///   * No `AnimiApp` integration, no device tests, no route/interruption/new-device auto-resume (a
///     later slice). A discontinuity mints a new epoch upstream and a fresh session; this type never
///     resumes itself.
///   * **No scrub audio.** The scrub/settle entrypoint advances readiness/diagnostics only and is
///     statically incapable of scheduling audio (it never touches the graph mix).
///   * No async, no actor, no realtime thread, no unbounded queue. Every bound/timeout is injected
///     (ADR-006 §9). Every failure is a typed, fail-closed error.

// MARK: - Typed errors

/// Fail-closed failures starting a preview playback session (Slice-004 Stage F).
public enum AudioMasterPreviewSessionError: Error, Equatable, Sendable {
    /// `start` was reached but the barrier was not ready (a required start gate is still unmet). The
    /// missing gates are reported for honest diagnosis.
    case notReadyToStart(missing: [PlaybackStartGate])
    /// The audio path was requested to schedule the initial preroll before the first frame was ready —
    /// the core Stage-F invariant (no audible playback before the first video frame).
    case audioScheduledBeforeFirstFrame
    /// The chosen master clock kind disagrees with the session's audio-bearing decision (an audio epoch
    /// paired with a host clock, or vice-versa) — a wiring fault, fail closed.
    case clockKindMismatch(expected: MasterClockKind, got: MasterClockKind)
    /// `configureAnchor` was offered an anchor whose revision/epoch is not the session's own — the
    /// canonical anchor contract requires the anchor to be minted for this exact epoch/revision.
    case anchorIdentityMismatch(
        anchorRevision: ProjectRevision, anchorEpoch: PlaybackEpoch,
        sessionRevision: ProjectRevision, sessionEpoch: PlaybackEpoch)
    /// The initial preroll's anchor is not exactly the anchor configured on the graph (a divergent
    /// project↔output sample binding) — fail closed, nothing is scheduled.
    case prerollAnchorMismatch(preroll: PreviewAudioScheduleAnchor, configured: PreviewAudioScheduleAnchor?)
    /// The graph rejected the initial preroll mix (e.g. stale identity) instead of scheduling it.
    case initialPrerollRejected(RejectionReason)
    /// A scrub/settle entrypoint was asked to start audible playback — scrub must never start audio.
    case scrubMustNotStartAudio
}

// MARK: - The chosen master clock for an epoch

/// The master clock selected for an epoch, paired with the kind it represents so the session can
/// fail closed if the wiring ever disagrees with the audio-bearing decision. A pure value boundary —
/// the concrete clock is one of the existing Stage-B clocks, injected, never built here.
public struct SelectedMasterClock: Sendable {
    public let kind: MasterClockKind
    public let clock: any MasterClock
    public init(kind: MasterClockKind, clock: any MasterClock) {
        self.kind = kind
        self.clock = clock
    }
}

// MARK: - The bounded initial preroll for an audio epoch

/// The one bounded initial audio mix the session schedules for an audio-bearing epoch, strictly after
/// the first frame is ready. Pure value: the bounded mix range, the anchor binding project↔output
/// sample coordinates, and the admitted per-source contributions — exactly the inputs
/// `PreviewAudioGraph.scheduleMix` consumes. No PCM beyond the graph's own sample arrays is stored here.
public struct InitialAudioPreroll: Sendable {
    public let anchor: PreviewAudioScheduleAnchor
    public let range: AudioSampleRange
    public let sources: [PreviewMixSource]
    public init(
        anchor: PreviewAudioScheduleAnchor,
        range: AudioSampleRange,
        sources: [PreviewMixSource]
    ) {
        self.anchor = anchor
        self.range = range
        self.sources = sources
    }
}

// MARK: - The started session result

/// The result of a successful start: the selected master clock that now governs the epoch and the
/// final barrier snapshot (ready). For a host epoch `scheduledInitialPreroll` is `false`; for an audio
/// epoch it is `true` and the graph has one bounded buffer scheduled at the exact anchor-derived time.
public struct StartedPreviewSession: Sendable {
    public let clock: SelectedMasterClock
    public let barrier: PlaybackStartBarrier
    public let scheduledInitialPreroll: Bool
}

// MARK: - The session

/// Orchestrates the start of one preview epoch. A `final class` only because it threads the evolving
/// `PlaybackStartBarrier` snapshot and owns the injected `PreviewAudioGraph` reference; it holds no
/// realtime state, no PCM, and no AV type directly. Every transition is an explicit, synchronous,
/// fail-closed step.
public final class AudioMasterPreviewSession {

    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    private let graph: PreviewAudioGraph
    private let selectedClock: SelectedMasterClock
    /// The barrier snapshot, advanced by each readiness signal. The session is the sole writer.
    public private(set) var barrier: PlaybackStartBarrier
    private var firstFrameReady = false
    private var scheduledInitialPreroll = false

    /// Build a session for one epoch. `clockKind` is the value `MasterClockSelector.select` already
    /// produced for this epoch (carried in, never re-decided). The barrier's audio-bearing flag is
    /// derived from it, and the chosen clock must agree with it (fail closed otherwise).
    public init(
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        graph: PreviewAudioGraph,
        selectedClock: SelectedMasterClock,
        timeoutTicks: Int64,
        startTick: Int64
    ) throws {
        let audioBearing = (selectedClock.kind == .audioSample)
        // If the concrete clock is one of the two canonical Stage-B clocks, it must agree with the
        // declared kind; an unrecognised test clock (`expectedKind == nil`) imposes no constraint.
        if let concreteKind = selectedClock.clock.expectedKind, concreteKind != selectedClock.kind {
            throw AudioMasterPreviewSessionError.clockKindMismatch(
                expected: selectedClock.kind, got: concreteKind)
        }
        self.revision = revision
        self.epoch = epoch
        self.graph = graph
        self.selectedClock = selectedClock
        self.barrier = try PlaybackStartBarrier(
            revision: revision, epoch: epoch, audioBearing: audioBearing,
            timeoutTicks: timeoutTicks, startTick: startTick)
    }

    /// Whether this epoch is audio-bearing (audio-sample master clock).
    public var isAudioBearing: Bool { selectedClock.kind == .audioSample }

    // MARK: Readiness signals (each advances the barrier; none can start audio on its own)

    /// Configure the graph output from the actual session route/format and mark the gate. Identity is
    /// the session's own epoch/revision.
    public func configureOutput() throws {
        try graph.configureOutput()
        barrier = try barrier.markingOutputConfigured(revision: revision, epoch: epoch)
    }

    /// Install the schedule anchor on the graph and mark the gate. The anchor binds the canonical 48 kHz
    /// `projectSample` to the explicit `outputSampleTime` for this epoch/revision (ADR-006 §3/§5).
    ///
    /// Fail-closed identity (canonical anchor contract): the anchor MUST be minted for this exact
    /// session epoch/revision. On mismatch the graph is NOT configured and the `anchorConfigured` gate
    /// is NOT marked — a typed error is thrown.
    ///
    /// Validation order:
    ///   1. `anchor.revision == session.revision`;
    ///   2. `anchor.epoch == session.epoch`;
    ///   3. `graph.configureAnchor(anchor)`;
    ///   4. mark `anchorConfigured`.
    public func configureAnchor(_ anchor: PreviewAudioScheduleAnchor) throws {
        guard anchor.revision == revision, anchor.epoch == epoch else {
            throw AudioMasterPreviewSessionError.anchorIdentityMismatch(
                anchorRevision: anchor.revision, anchorEpoch: anchor.epoch,
                sessionRevision: revision, sessionEpoch: epoch)
        }
        graph.configureAnchor(anchor)
        barrier = try barrier.markingAnchorConfigured(revision: revision, epoch: epoch)
    }

    /// Signal that the first composed video frame for this epoch is ready. Audible playback may never
    /// begin before this (enforced by the barrier's required set and by the audio-scheduling guard).
    public func markFirstFrameReady() throws {
        barrier = try barrier.markingFirstFrameReady(revision: revision, epoch: epoch)
        firstFrameReady = true
    }

    /// Advance the injected monotonic clock; fail closed (typed `timedOut`) if the budget elapsed before
    /// the barrier is ready.
    public func tick(toMonotonicTick now: Int64) throws {
        barrier = try barrier.ticking(toMonotonicTick: now)
    }

    /// Schedule the **one bounded initial audio preroll** for an audio-bearing epoch through
    /// `PreviewAudioGraph.scheduleMix` (post-mix output-stage path) and mark the barrier's audio gate.
    ///
    /// Fail-closed ordering: this is rejected unless the first frame is already ready (no audible audio
    /// before the first frame). For a host epoch it is a no-op returning `false` (the audio gate is not
    /// required and `markingInitialAudioScheduled` would itself throw) — scheduling audio for a silent
    /// epoch is simply never attempted. Returns whether audio was scheduled.
    @discardableResult
    public func scheduleInitialAudioPreroll(
        _ preroll: InitialAudioPreroll,
        against snapshot: SchedulerSnapshot
    ) throws -> Bool {
        guard isAudioBearing else { return false }
        guard firstFrameReady else {
            throw AudioMasterPreviewSessionError.audioScheduledBeforeFirstFrame
        }
        // Canonical anchor contract (fail-closed, before any scheduling):
        //   a. the graph anchor must already be installed by `configureAnchor`;
        //   b. the preroll's anchor must be EXACTLY that configured graph anchor (no divergent binding);
        //   c. the preroll's anchor must carry this session's revision/epoch.
        let configuredAnchor = graph.scheduleAnchor
        guard let configuredAnchor, preroll.anchor == configuredAnchor else {
            throw AudioMasterPreviewSessionError.prerollAnchorMismatch(
                preroll: preroll.anchor, configured: configuredAnchor)
        }
        guard preroll.anchor.revision == revision, preroll.anchor.epoch == epoch else {
            throw AudioMasterPreviewSessionError.anchorIdentityMismatch(
                anchorRevision: preroll.anchor.revision, anchorEpoch: preroll.anchor.epoch,
                sessionRevision: revision, sessionEpoch: epoch)
        }
        let outcome = try graph.scheduleMix(
            range: preroll.range, sources: preroll.sources, against: snapshot)
        switch outcome {
        case .scheduled:
            scheduledInitialPreroll = true
            barrier = try barrier.markingInitialAudioScheduled(revision: revision, epoch: epoch)
            return true
        case .rejected(let reason):
            throw AudioMasterPreviewSessionError.initialPrerollRejected(reason)
        }
    }

    // MARK: Start

    /// Cross the barrier and start the epoch. Fail-closed: throws `notReadyToStart` (naming the missing
    /// gates) unless every required gate is satisfied. Returns the master clock that now governs the
    /// epoch; for an audio epoch the graph already holds the bounded initial preroll.
    public func start() throws -> StartedPreviewSession {
        guard barrier.isReady else {
            throw AudioMasterPreviewSessionError.notReadyToStart(missing: barrier.missingGates)
        }
        return StartedPreviewSession(
            clock: selectedClock, barrier: barrier,
            scheduledInitialPreroll: scheduledInitialPreroll)
    }

    // MARK: Scrub / settle (must NEVER start audio)

    /// The scrub/settle entrypoint. Scrub and scrub-settle preview a single target frame; they advance
    /// readiness/diagnostics only and are **statically incapable** of scheduling audio — this method
    /// never touches the graph mix and never marks the audio gate. Asking it to start audible playback
    /// is a typed contract violation.
    public func scrubSettlePreview(startAudibleAudio: Bool) throws {
        guard !startAudibleAudio else {
            throw AudioMasterPreviewSessionError.scrubMustNotStartAudio
        }
        // No audio scheduling here by construction — scrub never reaches `graph.scheduleMix`.
    }
}

// MARK: - Clock-kind agreement helper

private extension MasterClock {
    /// The kind a concrete clock represents, when it is one of the two canonical Stage-B clocks. Used
    /// only to fail closed on a wiring mismatch; an unrecognised conforming clock returns `nil` (no
    /// constraint), since custom test clocks may stand in for either kind.
    var expectedKind: MasterClockKind? {
        if self is AudioSampleMasterClock { return .audioSample }
        if self is MonotonicHostMasterClock { return .monotonicHost }
        return nil
    }
}
