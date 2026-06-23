#if DEBUG
import Foundation

// MARK: - CP7.9 Phase 3A: async video prewarm scheduler (skeleton, DEBUG only)
//
// Moves cold AVAssetReader decode/seek OFF the preview render queue. This is the Phase 3A SKELETON: the
// scheduler type + threading + state machine + coalescing/cancel/epoch + a thread-safe ready snapshot.
// It is NOT yet wired into NextPreviewController / the bridges / the render or export paths (Phase 3B+).
//
// THREADING (critical — design correction):
//   * `readyFrame(...)` reads ONLY the lock-protected ready SNAPSHOT and returns immediately. It NEVER
//     calls `provider.resolveExact` and NEVER touches an AVAssetReader. On a miss/last-good it (re)schedules
//     the exact target (async), then returns the snapshot's current best.
//   * The per-video `NextVideoFrameProvider` (e.g. `NextVideoTextureResolver`) is stateful + forward-only,
//     so `resolveExact` runs ONLY on that ref's serial executor — never concurrently into one provider,
//     never on the render/main thread.
//   * A global concurrency cap (non-blocking admission-counting on the control queue — NO semaphore /
//     no blocking wait) limits how many refs decode at once, so N videos never spawn N concurrent reader
//     rebuilds (the original 6-video stall). Refs that arrive at the cap park in a ref-only waiting set
//     and, when a slot frees, the pump re-reads the ref's CURRENT desired target (never a stale snapshot).
//   * Scheduler bookkeeping (desired target, in-flight, epoch, snapshot) is serialized on a control queue;
//     the snapshot is additionally lock-guarded so `readyFrame` can read it synchronously off any thread.
//   * Decode completion updates the snapshot on the control queue ONLY IF the epoch and the desired target
//     are still current; a stale/superseded result is discarded (never becomes visible).

/// What `readyFrame` returns — never blocks, never decodes.
enum NextVideoFrameAvailability {
    case exact(NextVideoFrame)      // the requested target is decoded & ready
    case lastGood(NextVideoFrame)   // an older realized frame for this ref (approximate; decode scheduled)
    case missing                    // nothing realized yet for this ref (decode scheduled)
}

/// Preview scheduling mode (set by the controller from play/scrub/settle state). Phase 3A stores it for
/// priority/lookahead decisions; integration that acts on it is Phase 3D.
enum NextVideoPrewarmMode {
    case scrub      // active gesture: last-good acceptable, exact scheduled in background
    case settled    // gesture stopped: exact required ASAP for visible refs
    case playback   // exact + near-future lookahead prewarm
}

/// Decode priority within the global gate. Newest scrub/playback target preempts older work.
enum NextVideoPrewarmPriority: Int, Comparable {
    case low = 0           // older / superseded — effectively droppable
    case nearFuture = 1    // lookahead prewarm
    case currentPlayhead = 2  // the just-requested target
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A scheduled decode's identity. A result is only adopted if `(ref, target, epoch)` still matches the
/// ref's desired target + current epoch at completion time (coalescing + epoch invalidation).
struct NextVideoPrewarmRequest: Equatable {
    let ref: String
    let targetSeconds: Double
    let epoch: UInt64
}

/// CP7.9-CORR fix 4: a STABLE quantized target key. Two numerically near-equivalent seconds that map to
/// the same 600-timescale tick (matching the video resolver's `CMTimeScale 600`) share one key, so the
/// snapshot/desired maps never split on float noise. The original seconds are kept separately as the
/// payload passed to `provider.resolveExact` (the resolver does its own trim/hold-last selection).
struct NextVideoTargetKey: Hashable {
    let ticks: Int64
    init(seconds: Double) { self.ticks = Int64((seconds * 600.0).rounded()) }
}

/// DEBUG-only async prewarm scheduler skeleton. Wraps one `NextVideoFrameProvider` per video ref.
final class NextVideoPrewarmScheduler {

    /// Per-video state machine (Phase 3A: tracked for tests + Phase 3C cancel/coalesce).
    enum RefState: Equatable {
        case idle
        case scheduled(key: NextVideoTargetKey, epoch: UInt64)
        case decoding(key: NextVideoTargetKey, epoch: UInt64)
        case ready(key: NextVideoTargetKey, epoch: UInt64)
        case failed
    }

    // MARK: - Config
    let maxConcurrentDecodes: Int
    /// CP7.9-CORR fix 5: per-ref snapshot MRU cap (bounded, not unbounded). Default aligned with the
    /// resolver's per-video LRU (`NextVideoTextureResolver.defaultMaxCachedFrames`).
    let maxSnapshotFramesPerRef: Int

    // MARK: - Per-video providers + serial executors (decode confinement)
    private let providers: [String: NextVideoFrameProvider]
    private var refQueues: [String: DispatchQueue] = [:]

    // MARK: - Control queue (serializes all bookkeeping) + global decode admission
    // CP7.9-CORR2 fix 3: `.userInitiated` QoS on the control queue AND the per-ref decode queues. The
    // control queue is sync'd from the render/main path (`readyFrame` schedules via it) and the decode
    // queues are driven from it, so giving both the same elevated QoS avoids the priority inversion the
    // Thread Performance Checker flagged. The global concurrency cap is enforced WITHOUT a blocking
    // `DispatchSemaphore.wait()` on a decode queue (which would not propagate QoS and would re-introduce
    // the inversion): admission is a non-blocking counter on the control queue, with a small FIFO of
    // refs parked when at cap and released on completion. No queue ever blocks on a lock/semaphore.
    private let controlQueue = DispatchQueue(label: "com.animi.next-prewarm.control", qos: .userInitiated)
    private var liveGlobalDecodes = 0                       // control-queue-only: refs currently decoding
    // CP7.9-CORR3 fix 1: park REFS ONLY (FIFO order + a dedup set), never a captured (key/seconds/epoch)
    // tuple. When a slot frees, the pump re-reads `desired[ref]` so it always admits the ref's CURRENT
    // target — a parked request can never carry a stale key/seconds/epoch. A ref appears at most once.
    private var waitingRefsOrder: [String] = []            // control-queue-only: FIFO of parked refs
    private var waitingRefs: Set<String> = []              // control-queue-only: membership (dedup)

    // MARK: - Snapshot (lock-guarded; readyFrame reads this synchronously off any thread)
    private let snapshotLock = NSLock()
    /// One snapshot entry: a realized frame + the epoch it was decoded under (CP7.9-CORR fix 1: epoch-safe).
    private struct SnapshotFrame { let frame: NextVideoFrame; let epoch: UInt64 }
    /// Per-ref: exact decoded frames keyed by the STABLE tick key (bounded MRU), plus the most-recent
    /// (last-good). `mru` is tick keys, MRU-first, capped at `maxSnapshotFramesPerRef`.
    private struct RefSnapshot {
        var byKey: [NextVideoTargetKey: SnapshotFrame] = [:]
        var mru: [NextVideoTargetKey] = []
        var lastGood: SnapshotFrame?
    }
    private var snapshot: [String: RefSnapshot] = [:]   // guarded by snapshotLock

    // MARK: - Control-queue-only bookkeeping
    private var epoch: UInt64 = 0
    /// Latest desired target per ref WITH its priority (CP7.9-CORR fix 3): a lower-priority nearFuture must
    /// not supersede a currentPlayhead/settled target; currentPlayhead may supersede nearFuture.
    private struct Desired { let key: NextVideoTargetKey; let seconds: Double; let priority: NextVideoPrewarmPriority }
    private var desired: [String: Desired] = [:]
    private var stateByRef: [String: RefState] = [:]
    private var inFlight: Set<String> = []                 // refs currently decoding (per-video serial guard)

    #if DEBUG
    /// Test seams. Touched on the control queue (read via `controlSync` in tests).
    private(set) var resolveCallCount = 0                  // total provider.resolveExact invocations
    private(set) var maxObservedConcurrentDecodes = 0
    private var liveDecodes = 0
    private(set) var discardedStaleCompletions = 0
    #endif

    init(providers: [String: NextVideoFrameProvider], maxConcurrentDecodes: Int = 2,
         maxSnapshotFramesPerRef: Int = NextVideoTextureResolver.defaultMaxCachedFrames) {
        self.providers = providers
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
        self.maxSnapshotFramesPerRef = max(1, maxSnapshotFramesPerRef)
    }

    // MARK: - Public API

    /// Non-blocking. Returns the best frame currently in the snapshot for `(ref, target)` and (re)schedules
    /// the exact target if not ready. NEVER calls `provider.resolveExact`, NEVER touches an AVAssetReader.
    func readyFrame(ref: String, target: Double, epoch reqEpoch: UInt64, mode: NextVideoPrewarmMode)
        -> NextVideoFrameAvailability {
        let key = NextVideoTargetKey(seconds: target)
        // 1. Synchronous snapshot read (lock-guarded, fast). CP7.9-CORR fix 1: a snapshot frame is visible
        //    ONLY if its decoded epoch == the requested epoch — an old-epoch frame is NEVER returned.
        let availability: NextVideoFrameAvailability = snapshotLock.withLockReturning {
            guard let s = snapshot[ref] else { return .missing }
            if let exact = s.byKey[key], exact.epoch == reqEpoch { return .exact(exact.frame) }
            if let lg = s.lastGood, lg.epoch == reqEpoch { return .lastGood(lg.frame) }
            return .missing
        }
        // 2. On anything but exact, schedule the exact target. CP7.9-CORR2 fix 1: the CURRENT target a frame
        //    is requested for is always `currentPlayhead` — even in `.playback`. Lookahead/near-future
        //    prewarm uses `.nearFuture` only via `notifyPlayback`, never via the current-target read here.
        if case .exact = availability {} else {
            schedule(ref: ref, target: target, epoch: reqEpoch, priority: .currentPlayhead)
        }
        return availability
    }

    /// Enqueue (or raise priority of) a decode for `(ref, target, epoch)`. Coalescing + priority
    /// (CP7.9-CORR fix 3): a request supersedes the ref's desired target ONLY if it is newer at an
    /// equal-or-higher priority — a lower-priority `nearFuture` request must NOT replace a pending
    /// `currentPlayhead`/`settled` target; `currentPlayhead` MAY replace a `nearFuture` one. Decode runs on
    /// the ref's serial executor under the global gate; the result is adopted only if still current.
    func schedule(ref: String, target: Double, epoch reqEpoch: UInt64, priority: NextVideoPrewarmPriority) {
        let key = NextVideoTargetKey(seconds: target)
        controlQueue.async { [weak self] in
            guard let self else { return }
            guard reqEpoch == self.epoch else { return }           // epoch-stale request → drop
            guard self.providers[ref] != nil else { return }       // unknown ref → ignore
            // Priority-aware coalescing: keep the existing desired target unless this one is at least as
            // important. (Same key just refreshes priority to the max.)
            if let cur = self.desired[ref] {
                if cur.key == key {
                    if priority > cur.priority {
                        self.desired[ref] = Desired(key: key, seconds: target, priority: priority)
                    }
                } else if priority >= cur.priority {
                    self.desired[ref] = Desired(key: key, seconds: target, priority: priority)
                } else {
                    return   // lower-priority different target must NOT supersede a higher-priority pending one
                }
            } else {
                self.desired[ref] = Desired(key: key, seconds: target, priority: priority)
            }
            // Start the current desired target (no-op if already in-flight / already ready for this epoch).
            self.startCurrentDesiredIfNeededLocked(ref: ref)
        }
    }

    /// MUST be called on `controlQueue`. Starts a decode for the ref's CURRENT desired target under the
    /// CURRENT scheduler epoch, unless one is already in flight or the target is already ready for that
    /// epoch/key. Single source of truth for "should we decode now?" — used by both `schedule` and the
    /// completion handler so a post-`invalidate` desired reliably starts once the old decode clears.
    private func startCurrentDesiredIfNeededLocked(ref: String) {
        guard let want = desired[ref] else { return }            // nothing wanted → idle
        if inFlight.contains(ref) { return }                     // running decode will chase on completion
        if case .ready(let k, let e) = stateByRef[ref], k == want.key, e == epoch { return }  // already ready
        startDecodeLocked(ref: ref, key: want.key, seconds: want.seconds, epoch: epoch)
    }

    /// Playback advanced: prewarm the next near-future target per visible ref (Phase 3A: schedules them).
    func notifyPlayback(visibleRefs: [String], target: Double, epoch: UInt64) {
        for ref in visibleRefs { schedule(ref: ref, target: target, epoch: epoch, priority: .nearFuture) }
    }

    /// Scrub settled: raise priority to exact for the visible refs at `target`.
    func notifyScrubSettled(visibleRefs: [String], target: Double, epoch: UInt64) {
        for ref in visibleRefs { schedule(ref: ref, target: target, epoch: epoch, priority: .currentPlayhead) }
    }

    /// Media identity changed (CP7.9-CORR fix 2): ATOMICALLY on the control queue — bump epoch, clear
    /// desired/state, AND clear the snapshot. Doing the snapshot clear here (not on a separate thread)
    /// removes the race where an old-epoch completion could republish a stale frame after invalidate: a
    /// completion's adopt is also on the control queue and re-checks `epoch == self.epoch`, so once this
    /// block runs no old-epoch result can land, and any that landed before is cleared here.
    func invalidate(newEpoch: UInt64) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.epoch = newEpoch
            self.desired.removeAll()
            self.stateByRef.removeAll()
            // Parked refs (fix 2: `inFlight` means "active OR parked decode work") have no running decode to
            // release their claim — drop both the parked set AND their `inFlight` entries here. Refs that are
            // ACTIVELY decoding keep their `inFlight` (their real completion removes it) and are NOT parked.
            for ref in self.waitingRefs { self.inFlight.remove(ref) }
            self.waitingRefsOrder.removeAll(); self.waitingRefs.removeAll()  // parked refs are stale → drop
            self.snapshotLock.withLock { self.snapshot.removeAll() }
            // In-flight decodes keep running (liveGlobalDecodes stays accurate); their completions see the
            // new epoch, discard the result, free the slot, and pump any new-epoch parked waiters.
        }
    }

    // MARK: - Control-queue internals

    /// MUST be called on `controlQueue`. Admission point for the global concurrency cap: if under cap,
    /// admit and dispatch the blocking decode to the ref's serial executor; otherwise PARK THE REF (only)
    /// in the FIFO so the pump re-reads its CURRENT desired target when a slot frees. NO blocking wait on
    /// any queue. `key`/`seconds` describe the desired target at call time (already recorded in `desired`).
    private func startDecodeLocked(ref: String, key: NextVideoTargetKey, seconds: Double, epoch: UInt64) {
        guard providers[ref] != nil else { return }
        inFlight.insert(ref)                               // "active or parked decode work" for this ref
        stateByRef[ref] = .scheduled(key: key, epoch: epoch)
        if liveGlobalDecodes >= maxConcurrentDecodes {
            // CP7.9-CORR3 fix 1+2: park the REF once. A supersede while parked just updates `desired`; the
            // ref stays parked (no remove/re-add of inFlight) and the pump admits the latest desired later.
            if waitingRefs.insert(ref).inserted { waitingRefsOrder.append(ref) }
            return
        }
        admitDecodeLocked(ref: ref, key: key, seconds: seconds, epoch: epoch)
    }

    /// MUST be called on `controlQueue`. Take a global slot and run the (possibly blocking) decode on the
    /// ref's serial queue; the completion hops back here to adopt/discard and free the slot.
    private func admitDecodeLocked(ref: String, key: NextVideoTargetKey, seconds: Double, epoch: UInt64) {
        guard let provider = providers[ref] else { return }
        liveGlobalDecodes += 1
        stateByRef[ref] = .decoding(key: key, epoch: epoch)
        #if DEBUG
        liveDecodes += 1
        maxObservedConcurrentDecodes = max(maxObservedConcurrentDecodes, liveDecodes)
        resolveCallCount += 1
        #endif
        let queue = refQueueLocked(ref)
        queue.async { [weak self] in
            guard let self else { return }
            // Decode (may block) — on the ref's SERIAL executor (userInitiated QoS), never concurrent into
            // one provider, never blocking on a semaphore (the cap is enforced by admission, not a wait()).
            let result = Result { try provider.resolveExact(scenePlaybackSeconds: seconds) }
            self.controlQueue.async {
                self.liveGlobalDecodes -= 1
                #if DEBUG
                self.liveDecodes -= 1
                #endif
                self.inFlight.remove(ref)
                // Adopt ONLY if still current: epoch unchanged AND this exact key is still the desired one.
                let stillCurrent = (epoch == self.epoch) && (self.desired[ref]?.key == key)
                switch result {
                case .success(let frame) where stillCurrent:
                    // CP7.9-CORR fix 1+5: stamp the snapshot frame with `epoch`; bounded MRU per ref.
                    self.snapshotLock.withLock {
                        var s = self.snapshot[ref] ?? RefSnapshot()
                        let stamped = SnapshotFrame(frame: frame, epoch: epoch)
                        if s.byKey[key] == nil { s.mru.insert(key, at: 0) }
                        else { if let i = s.mru.firstIndex(of: key) { s.mru.remove(at: i) }; s.mru.insert(key, at: 0) }
                        s.byKey[key] = stamped
                        s.lastGood = stamped
                        // Evict beyond the per-ref cap (drop handle references → IOSurfaces freed).
                        while s.mru.count > self.maxSnapshotFramesPerRef {
                            let evict = s.mru.removeLast(); s.byKey[evict] = nil
                        }
                        self.snapshot[ref] = s
                    }
                    self.stateByRef[ref] = .ready(key: key, epoch: epoch)
                case .success:
                    #if DEBUG
                    self.discardedStaleCompletions += 1   // decoded but superseded/epoch-changed → discard
                    #endif
                case .failure:
                    self.stateByRef[ref] = .failed
                }
                // CP7.9-CORR2 fix 2: after ANY completion (adopted, discarded-stale, or failed), chase the
                // CURRENT desired target under the CURRENT scheduler epoch — NOT the completing decode's
                // epoch. This is what lets a decode scheduled after an `invalidate` actually start: the old
                // decode held `inFlight`, so `schedule` only recorded `desired` and returned; now that
                // `inFlight` is cleared we kick it off here. Guarded so we don't re-decode something already
                // ready for the current epoch/key, and only when nothing else is in flight for the ref.
                // On a FAILURE of the exact key still desired under the current epoch we do NOT immediately
                // retry (would spin on a persistently-failing provider); a later `schedule`/readyFrame for
                // the same target re-arms it. We still chase when the desired target has since moved on.
                let failedCurrent: Bool = {
                    if case .failure = result, epoch == self.epoch, self.desired[ref]?.key == key { return true }
                    return false
                }()
                if !failedCurrent { self.startCurrentDesiredIfNeededLocked(ref: ref) }
                // A global slot just freed — admit parked waiters up to the cap (the chase above may have
                // taken the freed slot itself; `pumpAdmissionLocked` re-checks the cap so we never exceed it).
                self.pumpAdmissionLocked()
            }
        }
    }

    /// MUST be called on `controlQueue`. Admit parked REFS while under the global cap, in FIFO order.
    /// CP7.9-CORR3 fix 1: the waiter carries only the ref — we re-read `desired[ref]` HERE, so the admitted
    /// decode is always the ref's CURRENT target (a supersede while parked is honoured automatically) under
    /// the CURRENT scheduler epoch. A ref with no current desired (epoch invalidated / cancelled) is
    /// dropped and its `inFlight` claim released; a ref already ready for its desired is dropped too.
    private func pumpAdmissionLocked() {
        while liveGlobalDecodes < maxConcurrentDecodes, !waitingRefsOrder.isEmpty {
            let ref = waitingRefsOrder.removeFirst()
            waitingRefs.remove(ref)
            guard let want = desired[ref] else {
                inFlight.remove(ref)                       // no current target → release the parked claim
                continue
            }
            // Already ready for the current desired target/epoch → nothing to decode; release the claim.
            if case .ready(let k, let e) = stateByRef[ref], k == want.key, e == epoch {
                inFlight.remove(ref)
                continue
            }
            admitDecodeLocked(ref: ref, key: want.key, seconds: want.seconds, epoch: epoch)
        }
    }

    /// MUST be called on `controlQueue`. One serial executor per ref (lazily created).
    private func refQueueLocked(_ ref: String) -> DispatchQueue {
        if let q = refQueues[ref] { return q }
        // CP7.9-CORR2 fix 3: match the control queue's QoS (see note there) — avoids priority inversion.
        let q = DispatchQueue(label: "com.animi.next-prewarm.ref.\(ref)", qos: .userInitiated)
        refQueues[ref] = q
        return q
    }

    #if DEBUG
    // Test helpers: read control-queue state safely.
    func controlSyncStateForTesting(_ ref: String) -> RefState {
        controlQueue.sync { stateByRef[ref] ?? .idle }
    }
    func resolveCallCountForTesting() -> Int { controlQueue.sync { resolveCallCount } }
    func maxConcurrentForTesting() -> Int { controlQueue.sync { maxObservedConcurrentDecodes } }
    func discardedStaleForTesting() -> Int { controlQueue.sync { discardedStaleCompletions } }
    /// Number of times `ref` currently appears in the parked-waiter FIFO (must be 0 or 1 — dedup invariant).
    func waitingCountForTesting(_ ref: String) -> Int {
        controlQueue.sync { waitingRefsOrder.filter { $0 == ref }.count }
    }
    func isInFlightForTesting(_ ref: String) -> Bool { controlQueue.sync { inFlight.contains(ref) } }
    /// Barrier: returns only after all currently-queued control-queue work (e.g. an `invalidate` block)
    /// has run. Does NOT wait for in-flight decodes (use `drainForTesting` for quiescence).
    func syncControlForTesting() { controlQueue.sync {} }
    /// Drain to true QUIESCENCE: block until no ref is in-flight AND every desired target is ready (so a
    /// chased re-decode after a coalesced supersede is awaited too). Polls the control-queue state with a
    /// generous timeout (test convenience only). Returns once settled or on timeout.
    func drainForTesting(timeout: TimeInterval = 5.0) {
        let deadline = DispatchTime.now() + timeout
        while DispatchTime.now() < deadline {
            let quiescent: Bool = controlQueue.sync {
                if !inFlight.isEmpty { return false }
                // Every desired target must be exactly ready (chase complete).
                for (ref, want) in desired {
                    if case .ready(let k, let e) = stateByRef[ref], k == want.key, e == epoch { continue }
                    return false
                }
                return true
            }
            if quiescent {
                // One more control round-trip so any just-finished completion's snapshot write is visible.
                controlQueue.sync {}
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    #endif
}

// MARK: - Small lock conveniences (DEBUG)

private extension NSLock {
    func withLock(_ body: () -> Void) { lock(); defer { unlock() }; body() }
    func withLockReturning<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
#endif
