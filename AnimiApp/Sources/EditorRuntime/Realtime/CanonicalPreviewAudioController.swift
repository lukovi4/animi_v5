import Foundation
import AnimiEngineCore

/// Slice-005 Stage C — the canonical realtime preview-audio controller.
///
/// Conforms to the EXISTING `PreviewAudioControlling` protocol so it drops into the existing
/// `EditorRuntimePreviewAudioCoordinator` / `EditorRuntime` call graph **unchanged** — when the
/// `DebugPreviewAudioWithNextEngine` toggle is OFF the legacy `EnginePreviewAudioPlaybackController`
/// is used verbatim; when ON, the coordinator installs THIS controller instead. Selection is the only
/// behavioural fork.
///
/// On explicit play it runs the canonical Slice-004 start sequence in TWO phases:
///   play:        configureOutput → configureAnchor(from playhead) → scheduleInitialAudioPreroll
///   first frame: markFirstFrameReady → start   (the barrier is crossed ONLY here)
/// driving `PreviewAudioGraph` + `AudioMasterPreviewSession`. The barrier does NOT cross until a REAL
/// first-frame-ready signal arrives (`signalFirstFrameReady()`), wired from the preview render path — the
/// controller never assumes the first frame. The PCM that becomes each `PreviewMixSource` is produced by
/// an **injected** preroll renderer/cache boundary; live `AVAssetReader` decoding is not part of this path.
///
/// The schedule anchor is derived from the actual playhead (`fromSeconds`) with checked integer
/// arithmetic — never a hardcoded `ProjectTime.zero`/`projectSample 0`.
///
/// Canonical constraints honoured: audio is scheduled ONLY on explicit play and ONLY after the first
/// frame; scrub schedules nothing; pause/stop stops the session; route/interruption are pause-only (no
/// auto-resume). No `loopToFit`, no transition ramps, no export, no legacy `AVMutableComposition`.
@MainActor
final class CanonicalPreviewAudioController: PreviewAudioControlling {

    // MARK: - Injected canonical pipeline construction

    /// Everything the controller needs to build one preview epoch from current editor state, injected so
    /// the lifecycle is fully unit-testable without a device. The closures are called on explicit play.
    struct Dependencies {
        /// Evaluate the current project into a canonical `AudioPlan` (Stage B bridge in production; a
        /// fixture in tests). Returns `nil` when there is no resolvable audio (→ silent epoch).
        var evaluatePlan: () throws -> AudioPlan?
        /// Build the bounded initial-preroll `PreviewMixSource`s ASYNCHRONOUSLY for the given plan +
        /// identity + range. Production must provide these samples through a background/prewarmed PCM
        /// renderer/cache, not live compressed-media reads during `startPlayback`. Empty → silent epoch.
        /// Cooperatively cancellable.
        var buildInitialPrerollAsync: (_ plan: AudioPlan, _ revision: ProjectRevision, _ epoch: PlaybackEpoch,
                                       _ anchor: PreviewAudioScheduleAnchor, _ range: AudioSampleRange,
                                       _ onDiagnostic: (@MainActor (_ event: String, _ detail: String) -> Void)?)
            async throws -> [PreviewMixSource]
        /// The app audio-session adapter (AVAudioSession-backed in production; fake in tests).
        var sessionAdapter: AudioSessionAdapter
        /// The output sink (one `AVAudioEnginePreviewSink` in production; recording fake in tests).
        var sink: PreviewAudioOutputSink
        /// The audio-sample master clock for an audio-bearing epoch.
        var makeAudioClock: (_ anchorProjectTime: ProjectTime) -> any MasterClock
        /// Injected bounded runtime config.
        var maxChunkSamples: Int64
        var startTimeoutTicks: Int64
        /// Whether the project actually HAS audio the legacy path could play (imported/bundled music or
        /// video-original audio). Used ONLY by the silent-epoch guard: if the canonical evaluator returns
        /// no plan but the project genuinely has audio, that is a canonical miss → fall back to legacy
        /// rather than strand the user in silence. A genuinely audio-free project stays a silent epoch.
        /// Defaults to `{ false }` so tests that don't exercise the fallback keep the legitimate silent epoch.
        var projectHasAudio: () -> Bool = { false }
    }

    private let deps: Dependencies
    /// Canonical deterministic identity allocators (the public mint API; raw inits are engine-internal).
    private var epochAllocator = MonotonicEpochAllocator(start: 1)
    private var revisionAllocator = MonotonicRevisionAllocator(start: 1)
    private var requestAllocator = MonotonicRequestIDAllocator()

    /// The currently live session, or `nil` when paused/stopped. Sole owner.
    private(set) var activeSession: AudioMasterPreviewSession?
    private(set) var activeGraph: PreviewAudioGraph?

    // MARK: - PreviewAudioControlling state

    private(set) var readiness: PreviewAudioReadiness = .idle
    var onReady: (@MainActor () -> Void)?
    var onFailure: (@MainActor (PreviewAudioFailureReason) -> Void)?
    var onPrepareFinished: (@MainActor (PreviewAudioPrepareResult) -> Void)?

    /// The canonical controller owns no legacy pipeline; "active" means it can start an epoch.
    var hasActivePipeline: Bool { readiness != .idle && readiness != .failed }

    /// DEBUG diagnostic sink — the coordinator wires this to `MemoryDiagnostics` so the canonical audio
    /// start is observable on device (toggle/controller/plan/render/schedule counts + typed errors).
    var onDiagnostic: (@MainActor (_ event: String, _ detail: String) -> Void)?

    /// SAFETY FALLBACK — invoked on a typed canonical startup/render/sink failure so the coordinator can
    /// fall back to the legacy preview-audio path rather than leave the user in silence. Canonical never
    /// silently replaces working legacy audio with nothing.
    var onCanonicalUnavailable: (@MainActor (_ reason: String) -> Void)?

    /// The session prepared by `startPlayback` but not yet started — its preroll is scheduled and barrier
    /// crossed only when the real first-frame signal arrives (canonical order: markFirstFrameReady →
    /// scheduleInitialAudioPreroll → start). `nil` until play; moved to `activeSession` on first frame.
    private var pendingSession: AudioMasterPreviewSession?
    private var pendingGraph: PreviewAudioGraph?
    /// The deferred preroll inputs captured at play. The `sources` are filled ASYNCHRONOUSLY by the preroll
    /// render task; scheduling happens only when BOTH the prepared sources AND the first frame are ready.
    private var pendingPreroll: (anchor: PreviewAudioScheduleAnchor, range: AudioSampleRange,
                                 snapshot: SchedulerSnapshot)?

    /// Whether the prepared epoch is audio-bearing (a session was built) vs a silent epoch.
    private var pendingIsAudioBearing = false

    // MARK: - Async preroll-render barrier state

    /// A monotonically increasing token minted on EACH `prepareCanonicalEpoch`. Captured at render kick-off
    /// and re-checked when the async preroll render completes: a late completion whose token != the current
    /// `pendingGeneration` (because pause/stop/teardown/dropPending or a fresh play moved on) schedules
    /// NOTHING. This is the cancellation + late-completion-drop guard.
    private var pendingGeneration: UInt64 = 0
    /// The in-flight async preroll-render task for the current pending epoch. Cancelled by
    /// pause/stop/teardown/dropPending and by a fresh `startPlayback`.
    private var prerollTask: Task<Void, Never>?
    /// Barrier side A: the real first-frame signal arrived for the pending epoch.
    private var pendingFirstFrameMarked = false
    /// Barrier side B: the async preroll render completed and produced these sources for the pending epoch.
    private var pendingPreparedSources: [PreviewMixSource]?
    /// The evaluated plan for the pending epoch (captured at play), so continuous scheduling can compute the
    /// post-preroll chunk ranges against the SAME plan the preroll used.
    private var pendingPlan: AudioPlan?

    #if DEBUG
    /// Test introspection: whether the last `startPlayback` scheduled an initial audio preroll.
    private(set) var lastStartScheduledPreroll = false
    /// Test introspection: count of started epochs (barrier crossed).
    private(set) var startedEpochCount = 0
    /// Test introspection: whether a session is prepared awaiting the first-frame signal.
    var hasPendingSessionAwaitingFirstFrame: Bool { pendingSession != nil }
    /// Test introspection: whether an async preroll render is currently in flight for the pending epoch.
    var hasInFlightPrerollTask: Bool { prerollTask != nil }
    /// Test introspection: whether the async preroll render has completed and is holding sources for the barrier.
    var hasPendingPreparedSources: Bool { pendingPreparedSources != nil }
    /// Test introspection: how many continuous (post-preroll) chunks were scheduled in the live epoch.
    private(set) var continuousChunksScheduled = 0
    #endif

    // MARK: - Continuous playback (Stage 6) — schedule successive bounded chunks while playback advances

    /// Named bounded lookahead. Stage 6 is STABILITY-FIRST SEQUENTIAL: at most ONE continuous chunk render
    /// in flight at a time (no two parallel AVAssetReader/render tasks for adjacent chunks). The next chunk is
    /// only requested after the previous one has been scheduled (or failed). Lookahead optimization (a deeper
    /// pipeline buffered ahead of playback) is DEFERRED until sequential canonical playback passes on device.
    static let continuousLookaheadDepth = 1

    /// The live epoch's continuous-scheduling context (set when the barrier crosses; cleared on stop). All
    /// continuous scheduling is anchored to the SAME `PreviewAudioScheduleAnchor` as the initial preroll, so
    /// every chunk's output sample time is `anchor.outputSampleTime + (chunkStart - anchor.projectSample)`.
    private struct ContinuousContext {
        let plan: AudioPlan
        let revision: ProjectRevision
        let epoch: PlaybackEpoch
        let anchor: PreviewAudioScheduleAnchor
        let snapshot: SchedulerSnapshot
    }
    private var continuousContext: ContinuousContext?
    /// The next project sample to schedule (cursor); advances by each scheduled chunk's length.
    private var nextChunkStart: Int64 = 0
    /// Monotonic token for the live continuous epoch. Bumped on every stop/drop so a late chunk completion
    /// (render finished after pause/stop/new-epoch) schedules NOTHING.
    private var continuousGeneration: UInt64 = 0
    /// In-flight continuous chunk render tasks (kept for cancellation on stop).
    private var continuousTasks: [Task<Void, Never>] = []
    /// Number of continuous chunk renders currently in flight (gates the bounded lookahead window).
    private var continuousInFlight = 0
    /// Whether the live epoch has reached the end of the plan (no more chunks to schedule).
    private var continuousReachedEnd = false

    init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    // MARK: - Pipeline lifecycle (canonical controller does not use the legacy AVComposition pipeline)

    /// The legacy pipeline value is irrelevant to the canonical path — it evaluates its own plan. This
    /// only flips readiness so the coordinator's `.ready/.primed` gating is satisfied. No rendering here.
    func replacePipeline(_ pipeline: BuiltAudioPipeline) {
        readiness = .ready
        let cb = onReady
        onReady = nil
        cb?()
    }

    func prepareForImmediatePlayback() {
        guard readiness == .ready else { return }
        readiness = .primed
        let cb = onPrepareFinished
        onPrepareFinished = nil
        cb?(.primed)
    }

    // MARK: - Explicit play (PHASE 1: prepare + schedule preroll; does NOT cross the barrier)

    /// Build a fresh canonical epoch from the actual playhead, schedule the bounded initial preroll, and
    /// hold the session PENDING. The start barrier is crossed only when the real first-frame signal
    /// arrives (`signalFirstFrameReady`). Fail-closed: any canonical error drops the half-built session
    /// and reports failure (caller decides fallback/stop) — never a silent/partial audible state.
    func startPlayback(fromSeconds: Double, hostTime: CFTimeInterval) {
        do {
            try prepareCanonicalEpoch(fromSeconds: fromSeconds)
        } catch {
            dropPending()
            activeSession = nil
            activeGraph = nil
            readiness = .failed
            onDiagnostic?("preview.audio.canonical.startFailed", "error=\(String(describing: error))")
            onFailure?(.playerFailed(error: String(describing: error)))
            // SAFETY: a typed canonical failure must hand back to legacy, never leave silence.
            onCanonicalUnavailable?(String(describing: error))
        }
    }

    private func prepareCanonicalEpoch(fromSeconds: Double) throws {
        // Any previously pending (un-started) epoch is replaced by this explicit play.
        dropPending()

        // Each explicit play mints a NEW epoch/revision (no resume of any invalidated session).
        let revision = revisionAllocator.next()
        let epoch = epochAllocator.next()

        // Convert the playhead to a canonical project sample/tick anchor — checked, fail-closed.
        let anchorProjectSample = try projectSample(forSeconds: fromSeconds)
        let anchorTicks = try CheckedInt64.multiply(
            anchorProjectSample, AudioSampleGrid.ticksPerSample, "anchorTicks")
        let anchorProjectTime = try ProjectTime(ticks: anchorTicks)

        // Evaluate the canonical plan. No resolvable audio → silent epoch (no graph, nothing scheduled).
        // A NON-EMPTY plan must NOT silently become nil/[]; non-empty audio is honoured or fails closed.
        let plan = try deps.evaluatePlan()
        onDiagnostic?("preview.audio.canonical.plan",
                      "segments=\(plan?.segments.count ?? -1) fromSeconds=\(fromSeconds)")
        guard let plan, !plan.segments.isEmpty else {
            // SAFETY: a canonical silent epoch is legitimate ONLY when the project genuinely has no audio.
            // If the project DOES have audio (imported/bundled music or video-original) but the canonical
            // evaluator produced nothing, that is a canonical miss — hand back to legacy rather than play
            // silence over real audio. `throw` here routes through `startPlayback`'s catch →
            // `onCanonicalUnavailable` (the one-shot legacy fallback), never a silent replacement.
            if deps.projectHasAudio() {
                onDiagnostic?("preview.audio.canonical.silentEpochWithAudio", "fallback=1")
                throw AppRealtimeAudioIntegrationError.audioAssetUnresolvable(
                    detail: "canonical produced no plan but project has audio (silent epoch with audio)")
            }
            pendingIsAudioBearing = false
            readiness = .primed
            #if DEBUG
            lastStartScheduledPreroll = false
            #endif
            onDiagnostic?("preview.audio.canonical.silentEpoch", "reason=noResolvableAudio")
            return
        }

        // Build the graph + audio-bearing session for this epoch.
        let graph = try PreviewAudioGraph(
            session: deps.sessionAdapter, sink: deps.sink,
            epoch: epoch, revision: revision, maxChunkSamples: deps.maxChunkSamples)
        try deps.sessionAdapter.activate()

        let clock = deps.makeAudioClock(anchorProjectTime)
        let session = try AudioMasterPreviewSession(
            revision: revision, epoch: epoch, graph: graph,
            selectedClock: SelectedMasterClock(kind: .audioSample, clock: clock),
            timeoutTicks: deps.startTimeoutTicks, startTick: 0)

        // Canonical start sequence — PHASE 1: output + anchor only. The first frame, the preroll
        // scheduling, and the barrier cross all happen in `signalFirstFrameReady` (canonical order
        // requires markFirstFrameReady BEFORE scheduleInitialAudioPreroll).
        try session.configureOutput()
        let anchor = PreviewAudioScheduleAnchor(
            revision: revision, epoch: epoch,
            projectSample: anchorProjectSample, outputSampleTime: 0)
        try session.configureAnchor(anchor)

        // Compute the bounded preroll range now (pure, MainActor, no rendering). The actual PCM preroll must
        // come from the injected async renderer/cache — `startPlayback` must NOT synchronously render.
        let prerollRange = try boundedPrerollRange(plan: plan, anchorSample: anchorProjectSample)
        let snapshot = try makeSnapshot(revision: revision, epoch: epoch, plan: plan)

        // Hold PENDING — nothing is scheduled and the barrier is NOT crossed until BOTH the async preroll render
        // and the first frame are ready. Mint a fresh generation token for the late-completion guard.
        pendingGeneration &+= 1
        let generation = pendingGeneration
        pendingSession = session
        pendingGraph = graph
        pendingPreroll = (anchor: anchor, range: prerollRange, snapshot: snapshot)
        pendingPlan = plan
        pendingIsAudioBearing = true
        pendingFirstFrameMarked = false
        pendingPreparedSources = nil
        readiness = .primed

        // Kick off the async preroll render on a Task this controller OWNS. On completion it re-checks
        // the generation token before storing/scheduling, so a
        // LATE completion after pause/stop/new-epoch schedules NOTHING (cancellation + drop guard).
        onDiagnostic?("preview.audio.canonical.preroll.build.begin",
                      "planSegments=\(plan.segments.count) range=\(prerollRange.start)..<\(prerollRange.end) gen=\(generation)")
        prerollTask = Task { [weak self] in
            await self?.runPrerollPrepare(
                plan: plan, revision: revision, epoch: epoch,
                anchor: anchor, range: prerollRange, generation: generation)
        }
    }

    /// Await the async preroll render, then hop back here (MainActor-isolated method) to store the sources
    /// and try to cross the barrier. The generation token
    /// guards against a late completion: if the pending epoch moved on, nothing is stored or scheduled.
    private func runPrerollPrepare(
        plan: AudioPlan, revision: ProjectRevision, epoch: PlaybackEpoch,
        anchor: PreviewAudioScheduleAnchor, range: AudioSampleRange, generation: UInt64
    ) async {
        do {
            let sources = try await deps.buildInitialPrerollAsync(
                plan, revision, epoch, anchor, range, onDiagnostic)
            // LATE-COMPLETION DROP: a render that finished after pause/stop/new-epoch schedules NOTHING.
            guard generation == pendingGeneration, pendingSession != nil else {
                onDiagnostic?("preview.audio.canonical.preroll.build.dropped",
                              "gen=\(generation) current=\(pendingGeneration) reason=staleOrStopped")
                return
            }
            onDiagnostic?("preview.audio.canonical.preroll.build.end",
                          "sourceCount=\(sources.count) bufferCount=\(sources.count)")
            // A NON-EMPTY plan must produce sources or fail closed (never silent).
            guard !sources.isEmpty else {
                prerollPrepareFailed(AppRealtimeAudioIntegrationError.audioRenderPipelineUnavailable(
                    reason: "non-empty AudioPlan produced no PreviewMixSource"))
                return
            }
            prerollTask = nil
            pendingPreparedSources = sources
            tryCrossBarrier()
        } catch is CancellationError {
            // A cancelled preroll render (pause/stop/new-epoch) schedules nothing and reports no failure.
            onDiagnostic?("preview.audio.canonical.preroll.build.cancelled", "gen=\(generation)")
        } catch {
            // A preroll-render error for the CURRENT pending epoch is a typed canonical failure.
            guard generation == pendingGeneration, pendingSession != nil else { return }
            prerollPrepareFailed(error)
        }
    }

    /// A typed async preroll-render failure (CURRENT epoch): drop the half-built epoch and route to the legacy
    /// fallback — never a silent/partial audible state.
    private func prerollPrepareFailed(_ error: Error) {
        prerollTask = nil
        dropPending()
        activeSession = nil
        activeGraph = nil
        readiness = .failed
        onDiagnostic?("preview.audio.canonical.preroll.build.failed", "error=\(String(describing: error))")
        onFailure?(.playerFailed(error: String(describing: error)))
        // SAFETY: a typed canonical failure must hand back to legacy, never leave silence.
        onCanonicalUnavailable?(String(describing: error))
    }

    // MARK: - First-frame gate (PHASE 2: mark frame → schedule preroll → cross barrier)

    /// The real first-frame-ready signal from the preview render path. It records the first-frame side of
    /// the barrier and attempts to cross it. Crossing (schedule + start) happens ONLY when BOTH the
    /// first-frame signal AND the async preroll render are ready — whichever arrives second triggers the
    /// actual schedule. Before this arrives, NOTHING is scheduled. A silent epoch (no pending session) is a
    /// no-op. Fail-closed on any canonical error.
    func signalFirstFrameReady() {
        guard pendingSession != nil else { return }
        pendingFirstFrameMarked = true
        tryCrossBarrier()
    }

    /// Cross the Stage C.6 barrier: run the canonical `markFirstFrameReady → scheduleInitialAudioPreroll →
    /// start` sequence ONLY when BOTH barrier sides are set (first frame AND prepared sources) for the
    /// CURRENT pending epoch. Idempotent — a no-op until both sides are present. Fail-closed on any error.
    private func tryCrossBarrier() {
        guard pendingFirstFrameMarked,
              let sources = pendingPreparedSources,
              let session = pendingSession, let graph = pendingGraph,
              let preroll = pendingPreroll else { return }
        do {
            // Canonical order MUST be preserved: markFirstFrameReady BEFORE scheduleInitialAudioPreroll.
            try session.markFirstFrameReady()
            onDiagnostic?("preview.audio.canonical.graph.schedule.begin", "sources=\(sources.count)")
            let scheduled = try session.scheduleInitialAudioPreroll(
                InitialAudioPreroll(anchor: preroll.anchor, range: preroll.range, sources: sources),
                against: preroll.snapshot)
            onDiagnostic?("preview.audio.canonical.graph.schedule.end", "scheduled=\(scheduled ? 1 : 0)")
            #if DEBUG
            lastStartScheduledPreroll = scheduled
            #endif
            // `session.start()` starts the AVAudioEngine AND plays the output player node (the sink wires
            // both). The engine/player marker pair brackets that single canonical start so the device
            // marker chain proves where the audible start happens.
            onDiagnostic?("preview.audio.canonical.engine.start.begin", "")
            onDiagnostic?("preview.audio.canonical.player.play.begin", "")
            _ = try session.start()
            onDiagnostic?("preview.audio.canonical.player.play.end", "")
            onDiagnostic?("preview.audio.canonical.engine.start.end", "")
            activeSession = session
            activeGraph = graph
            pendingSession = nil
            pendingGraph = nil
            pendingPreroll = nil
            pendingPreparedSources = nil
            pendingFirstFrameMarked = false
            readiness = .primed
            #if DEBUG
            startedEpochCount += 1
            #endif
            onDiagnostic?("preview.audio.canonical.scheduled",
                          "scheduled=\(scheduled ? 1 : 0) sources=\(sources.count) started=1")

            // STAGE 6: begin continuous scheduling of the chunks AFTER the initial preroll, anchored to the
            // SAME anchor/snapshot. The initial preroll covered `preroll.range`; the cursor continues at its
            // end. All subsequent chunks go through the same render pipeline + `graph.scheduleMix`.
            if let plan = pendingPlan {
                startContinuousScheduling(
                    plan: plan,
                    revision: preroll.anchor.revision, epoch: preroll.anchor.epoch,
                    anchor: preroll.anchor, snapshot: preroll.snapshot,
                    fromSample: preroll.range.end)
            }
            pendingPlan = nil
        } catch {
            dropPending()
            activeSession = nil
            activeGraph = nil
            readiness = .failed
            onDiagnostic?("preview.audio.canonical.firstFrameFailed", "error=\(String(describing: error))")
            onFailure?(.playerFailed(error: String(describing: error)))
            // SAFETY: fail back to legacy rather than leave silence.
            onCanonicalUnavailable?(String(describing: error))
        }
    }

    // MARK: - Continuous scheduling (Stage 6)

    /// Begin scheduling successive bounded chunks for the live epoch, anchored to the same anchor/snapshot as
    /// the initial preroll. Mints a fresh continuous generation; the cursor starts at `fromSample` (the end
    /// of the initial preroll range). Bounded lookahead — at most `continuousLookaheadDepth` renders in flight.
    private func startContinuousScheduling(
        plan: AudioPlan, revision: ProjectRevision, epoch: PlaybackEpoch,
        anchor: PreviewAudioScheduleAnchor, snapshot: SchedulerSnapshot, fromSample: Int64
    ) {
        continuousContext = ContinuousContext(
            plan: plan, revision: revision, epoch: epoch, anchor: anchor, snapshot: snapshot)
        nextChunkStart = fromSample
        continuousReachedEnd = false
        continuousGeneration &+= 1
        continuousTasks.removeAll()
        continuousInFlight = 0
        #if DEBUG
        continuousChunksScheduled = 0
        #endif
        pumpContinuous()
    }

    /// Fill the bounded lookahead window: while there is plan remaining, the epoch is live, and fewer than
    /// `continuousLookaheadDepth` renders are in flight, kick off the next chunk render. Each chunk advances
    /// the cursor at REQUEST time (so concurrent in-flight chunks cover distinct, non-overlapping ranges).
    private func pumpContinuous() {
        guard let ctx = continuousContext, activeSession != nil else { return }
        let planEnd = ctx.plan.sampleInterval.end
        while !continuousReachedEnd,
              continuousInFlight < Self.continuousLookaheadDepth,
              nextChunkStart < planEnd {
            let start = nextChunkStart
            let count = min(deps.maxChunkSamples, planEnd - start)
            guard count > 0 else { break }
            let end = start + count
            nextChunkStart = end                       // advance cursor at request time (no overlap)
            let generation = continuousGeneration
            let range: AudioSampleRange
            do {
                range = try Self.sampleRange(start: start, end: end)
            } catch {
                continuousFailed(error); return
            }
            continuousInFlight += 1
            onDiagnostic?("preview.audio.canonical.nextChunk.requested",
                          "range=\(start)..<\(end) gen=\(generation) inFlight=\(continuousInFlight)")
            let task = Task { [weak self] () -> Void in
                await self?.renderAndScheduleChunk(range: range, context: ctx, generation: generation)
            }
            continuousTasks.append(task)
        }
        // End-of-plan ONLY once the cursor is past the end AND nothing is still in flight (so the last chunk
        // has actually been scheduled, not merely requested).
        if nextChunkStart >= planEnd, continuousInFlight == 0, !continuousReachedEnd {
            continuousReachedEnd = true
            onDiagnostic?("preview.audio.canonical.nextChunk.endOfPlan", "planEnd=\(planEnd)")
        }
    }

    /// Render one continuous chunk through the SAME pipeline as the initial preroll, then schedule it onto the
    /// live graph at the anchor-relative output sample time. Generation/token-guarded against late completion.
    private func renderAndScheduleChunk(
        range: AudioSampleRange, context ctx: ContinuousContext, generation: UInt64
    ) async {
        onDiagnostic?("preview.audio.canonical.nextChunk.render.begin",
                      "range=\(range.start)..<\(range.end) gen=\(generation)")
        do {
            let sources = try await deps.buildInitialPrerollAsync(
                ctx.plan, ctx.revision, ctx.epoch, ctx.anchor, range, onDiagnostic)
            // LATE-COMPLETION DROP: a render that finished after pause/stop/new-epoch schedules NOTHING.
            guard generation == continuousGeneration, let graph = activeGraph, activeSession != nil else {
                onDiagnostic?("preview.audio.canonical.nextChunk.dropped",
                              "gen=\(generation) current=\(continuousGeneration) reason=staleOrStopped")
                return
            }
            onDiagnostic?("preview.audio.canonical.nextChunk.render.end",
                          "range=\(range.start)..<\(range.end) sourceCount=\(sources.count)")
            // A NON-EMPTY plan range must produce sources or fail closed (never silent).
            guard !sources.isEmpty else {
                continuousFailed(AppRealtimeAudioIntegrationError.audioRenderPipelineUnavailable(
                    reason: "continuous chunk \(range.start)..<\(range.end) produced no PreviewMixSource"))
                return
            }
            onDiagnostic?("preview.audio.canonical.nextChunk.schedule.begin",
                          "range=\(range.start)..<\(range.end) sources=\(sources.count)")
            let outcome = try graph.scheduleMix(range: range, sources: sources, against: ctx.snapshot)
            switch outcome {
            case .scheduled:
                onDiagnostic?("preview.audio.canonical.nextChunk.schedule.end",
                              "range=\(range.start)..<\(range.end) scheduled=1")
                #if DEBUG
                continuousChunksScheduled += 1
                #endif
            case .rejected(let reason):
                continuousFailed(AppRealtimeAudioIntegrationError.pcmRenderFailed(
                    reason: "continuous chunk rejected: \(String(describing: reason))"))
                return
            }
            // This task is done; free its lookahead slot and pump the next chunk.
            finishContinuousTask(generation: generation)
            pumpContinuous()
        } catch is CancellationError {
            onDiagnostic?("preview.audio.canonical.nextChunk.dropped",
                          "gen=\(generation) reason=cancelled")
        } catch {
            guard generation == continuousGeneration, activeSession != nil else { return }
            continuousFailed(error)
        }
    }

    /// Mark one in-flight continuous render as finished (frees a lookahead slot). Only affects the CURRENT
    /// generation — a stale completion must not decrement the live epoch's counter.
    private func finishContinuousTask(generation: UInt64) {
        guard generation == continuousGeneration else { return }
        if continuousInFlight > 0 { continuousInFlight -= 1 }
    }

    /// A typed continuous-chunk failure (CURRENT epoch): stop the epoch and route to the legacy fallback —
    /// never a silent/partial audible state.
    private func continuousFailed(_ error: Error) {
        onDiagnostic?("preview.audio.canonical.nextChunk.failed", "error=\(String(describing: error))")
        cancelContinuous()
        activeGraph?.stopOutputSink()
        activeSession = nil
        activeGraph = nil
        readiness = .failed
        onFailure?(.playerFailed(error: String(describing: error)))
        // SAFETY: a typed canonical failure must hand back to legacy, never leave silence.
        onCanonicalUnavailable?(String(describing: error))
    }

    /// Cancel all in-flight continuous renders and invalidate the generation so any late completion drops.
    /// Fully resets continuous runtime state (including `continuousInFlight`) so no stale slot/cursor remains.
    private func cancelContinuous() {
        continuousGeneration &+= 1
        for t in continuousTasks { t.cancel() }
        continuousTasks.removeAll()
        continuousInFlight = 0
        continuousContext = nil
        continuousReachedEnd = false
    }

    /// Build a bounded `AudioSampleRange` from an explicit `[start, end)` sample pair (checked, fail-closed).
    private static func sampleRange(start: Int64, end: Int64) throws -> AudioSampleRange {
        let tps = AudioSampleGrid.ticksPerSample
        let startTicks: Int64
        let endTicks: Int64
        do {
            startTicks = try CheckedInt64.multiply(start, tps, "continuous.startTicks")
            endTicks = try CheckedInt64.multiply(end, tps, "continuous.endTicks")
        } catch {
            throw AppRealtimeAudioIntegrationError.anchorArithmeticOverflow(detail: "continuous.sampleRange")
        }
        return try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: try ProjectTime(ticks: startTicks), end: try ProjectTime(ticks: endTicks)))
    }

    private func dropPending() {
        // CRITICAL: cancel any in-flight async preroll render and INVALIDATE its generation, so
        // a late completion (which hops back to the MainActor after this) schedules NOTHING. Bumping the
        // generation makes the `runPrerollPrepare` guard fail even if the cancellation has not yet taken.
        prerollTask?.cancel()
        prerollTask = nil
        pendingGeneration &+= 1
        pendingFirstFrameMarked = false
        pendingPreparedSources = nil
        pendingPlan = nil
        // STAGE 6: a fresh play / drop also invalidates the previous epoch's continuous scheduling so its
        // in-flight chunk renders cannot schedule onto the superseded graph (idempotent — bumps generation).
        cancelContinuous()
        // Stop the pending graph's sink (AVAudioEngine/player) BEFORE releasing it. On a canonical failure
        // path (`startPlayback` catch → `dropPending`) the graph built in `prepareCanonicalEpoch` was
        // otherwise nil'd while its engine was still attached/prepared — an orphaned AVAudioEngine that
        // contests audio resources with the legacy fallback render. Stopping it first releases cleanly.
        pendingGraph?.stopOutputSink()
        pendingSession = nil
        pendingGraph = nil
        pendingPreroll = nil
        pendingIsAudioBearing = false
    }

    // MARK: - Anchor / range arithmetic (checked, fail-closed)

    /// Convert a playhead in seconds to a canonical 48 kHz project sample, fail-closed. The seconds→µs
    /// conversion is the single unavoidable float at the legacy API boundary (`fromSeconds: Double`); all
    /// downstream tick/sample math is checked integer. Negative/non-finite → typed failure.
    private func projectSample(forSeconds seconds: Double) throws -> Int64 {
        guard seconds.isFinite, seconds >= 0 else {
            throw AppRealtimeAudioIntegrationError.invalidPlayheadAnchor(fromSeconds: seconds)
        }
        let microsDouble = (seconds * 1_000_000).rounded()
        guard microsDouble <= Double(Int64.max) else {
            throw AppRealtimeAudioIntegrationError.invalidPlayheadAnchor(fromSeconds: seconds)
        }
        let micros = Int64(microsDouble)
        // ticks = micros * 240_000 / 1_000_000 = micros * 6 / 25 (reduced, checked).
        let scaled: Int64
        do { scaled = try CheckedInt64.multiply(micros, 6, "playhead.ticks") }
        catch { throw AppRealtimeAudioIntegrationError.invalidPlayheadAnchor(fromSeconds: seconds) }
        let ticks = scaled / 25                                   // floor onto the tick grid
        // sample = floor(ticks / ticksPerSample). Anchor is an instant, so floor is correct.
        return ticks / AudioSampleGrid.ticksPerSample
    }

    /// Bound the initial preroll to `maxChunkSamples`, anchored AT the playhead sample. Built via the only
    /// public constructor `AudioSampleRange.from(projectTicks:)`. All multiplications are checked.
    private func boundedPrerollRange(plan: AudioPlan, anchorSample: Int64) throws -> AudioSampleRange {
        // Clamp the anchor into the plan's covered sample interval (the plan defines what is audible).
        let planStart = plan.sampleInterval.start
        let planEnd = plan.sampleInterval.end
        let startSample = max(planStart, min(anchorSample, max(planStart, planEnd - 1)))
        let remaining = try CheckedInt64.subtract(planEnd, startSample, "preroll.remaining")
        let count = max(1, min(remaining, deps.maxChunkSamples))
        let tps = AudioSampleGrid.ticksPerSample
        let startTicks: Int64
        let endTicks: Int64
        do {
            startTicks = try CheckedInt64.multiply(startSample, tps, "preroll.startTicks")
            let endSample = try CheckedInt64.add(startSample, count, "preroll.endSample")
            endTicks = try CheckedInt64.multiply(endSample, tps, "preroll.endTicks")
        } catch {
            throw AppRealtimeAudioIntegrationError.anchorArithmeticOverflow(detail: "boundedPrerollRange")
        }
        return try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: try ProjectTime(ticks: startTicks), end: try ProjectTime(ticks: endTicks)))
    }

    /// A bounded, self-consistent admission snapshot. Coverage spans the plan's project tick span,
    /// computed with checked multiplication (no `try!`, no unchecked `*`).
    private func makeSnapshot(
        revision: ProjectRevision, epoch: PlaybackEpoch, plan: AudioPlan
    ) throws -> SchedulerSnapshot {
        let endTicks: Int64
        do {
            let raw = try CheckedInt64.multiply(
                plan.sampleInterval.end, AudioSampleGrid.ticksPerSample, "snapshot.coverageTicks")
            endTicks = max(1, raw)                                // coverage end must exceed start (0)
        } catch {
            throw AppRealtimeAudioIntegrationError.anchorArithmeticOverflow(detail: "makeSnapshot.coverage")
        }
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: endTicks))
        return SchedulerSnapshot(
            revision: revision, epoch: epoch, coverage: coverage,
            currentTarget: CurrentTarget(time: .zero, frameRequest: requestAllocator.nextFrameRequest()),
            lastPublished: nil)
    }

    // MARK: - Pause / stop (stop the session; never auto-resume)

    /// Warm interactive pause (user Pause / scrub `.began`): stop the canonical session. There is no warm
    /// "keep prepared" resume on the canonical path — the next explicit play mints a new epoch.
    func pausePlaybackImmediately() {
        stopSession()
    }

    /// Teardown-style pause (idle reclaim / interruption abort): stop the session.
    func pause() {
        stopSession()
    }

    func teardown() {
        stopSession()
        readiness = .idle
        onReady = nil
        onPrepareFinished = nil
        onFailure = nil
    }

    private func stopSession() {
        // STAGE 6: cancel any in-flight continuous chunk renders + invalidate their generation FIRST, so a
        // render that completes after this stop schedules NOTHING onto the (about-to-be-dropped) graph.
        cancelContinuous()
        // Stop the engine/player so audio actually ceases (scheduling onto a dropped graph would
        // otherwise keep the last buffers playing). Stop BOTH the live and pending graphs.
        activeGraph?.stopOutputSink()
        pendingGraph?.stopOutputSink()
        // CRITICAL: do NOT deactivate the shared `AVAudioSession` here. The app owns the session
        // (`AudioSessionManager.activateForPlayback`); deactivating it on every pause/scrub would silence
        // the WHOLE app (including video audio). The canonical adapter must be session-neutral on stop.
        activeSession = nil
        activeGraph = nil
        dropPending()
        // Readiness stays .primed so a subsequent explicit play can mint a new epoch (parity with legacy
        // warm pause where the next startPlayback re-starts).
        if readiness == .ready || readiness == .idle { /* keep */ } else { readiness = .primed }
    }

    // MARK: - Route change: PAUSE-ONLY (no reprepare+restart)

    /// On the canonical path a route change is pause-only: the session is already stopped by the
    /// coordinator's pause, and we do NOT rebuild+restart. This is intentionally a stop, NOT the legacy
    /// reprepare. The next explicit user play mints a new epoch and re-queries the output.
    func reprepareForRouteChange() {
        stopSession()
    }
}
