# Slice 003 — Implementation Plan: Identities, Transport & Atomic Scheduler

- **Status:** PREFLIGHT — plan of record. No code written.
- **Date context:** 2026-06-25.
- **Normative contracts:** ADR-005 (identity, cancellation, atomic publication), ADR-006 (scheduler &
  master clock — *pure/control portions only*), canonical-runtime-roadmap §4.
- **Depends on (already landed):** Slice 001 (canonical audio schema v3) `6ba30cc8`,
  Slice 002 (pure `AudioEvaluator` + `AudioPlan`) `2121747e`.
- **Build home:** `AnimiEngineNext`, target `AnimiEngineCore`, tests `AnimiEngineCoreTests`.
- **Baseline (this preflight):** `swift test --filter AnimiEngineCoreTests` → **362 tests, 1 skipped, 0
  failures (0 unexpected)**.
- **Nothing staged or committed by this preflight.**

---

## 0. What this slice is — and is NOT

Slice 3 builds the **deterministic, synchronous, fully testable control core** of the canonical runtime:
the typed identities of ADR-005 and the pure/control portions of the ADR-006 scheduler. It is the
"brain" that decides *what is current, what may be admitted, and what may be published* — entirely from
injected inputs, with **no realtime audio, no AVFoundation, no GPU, no decode, no device, no `AnimiApp`**.

The scheduler in this slice owns transport state, epochs, admission, cancellation, complete-frame
worksets, latest-wins scrub and exact settle, and bounded queues. It drives evaluation through the
*existing* pure `TimelineEvaluator` / `AudioEvaluator`, but it does **not** perform the side effects those
real frames require — those land in later slices behind injected protocols.

### In scope (roadmap §4)

- typed `ProjectRevision`, `PlaybackEpoch`, `FrameRequestID`, `MediaRequestID`, `AudioRequestID`,
  `CacheArtifactID`, `ExportJobID`, `BenchmarkRunID` — distinct value types, never raw-int aliases in
  public APIs (ADR-005 §1);
- the identity tuple carried on async work + completions (ADR-005 §2);
- the transport state machine (ADR-006 §2): `paused / preparing / playing / scrubbing / settling /
  interrupted / ended / failed`;
- injected clock protocols (host monotonic + audio-sample master abstraction) — ADR-006 §3, control only;
- scheduler-owned admission / cancellation / publication of identities (ADR-005 §4–§7, ADR-006 §1, §6);
- complete-frame `FrameWorkset` model + atomic `PublishedFrame` token (ADR-005 §5, ADR-006 §6);
- latest-wins scrub coalescing + exact settle barrier (ADR-005 §7, ADR-006 §7);
- audio-buffer **admission** validation (ADR-005 §8) — identity/epoch gating only, no PCM, no device;
- bounded queues with deterministic fault injection + global frame skip keeping the previous complete
  composition (ADR-006 §9, §6, §10 control surface).

### Explicitly OUT of scope (hard boundaries)

- **No `AnimiApp`** — zero product/app files touched.
- **No AVFoundation / AVFAudio / `AVAudioEngine` / `AVAudioTime`** — the audio-master clock is an
  injected *protocol* returning canonical project ticks; the real `AVAudioTime` adapter is Slice 4.
- **No realtime audio adapter, no PCM decode, no mixing, no audio I/O** (Slice 4).
- **No GPU / Metal / RenderGraph / decode / upload** — rendering is an injected *result-returning*
  protocol; the real renderer is later.
- **No export execution** — `ExportJobID` identity exists and is proven *isolated*, but offline export
  enumeration/PCM is Slice 5/7.
- **No device tests** — all fault injection is deterministic and synchronous.
- **No proxy/cache/degradation-ladder tuning** — degradation *policy hooks* are modelled as a global
  decision surface; the evidence-selected fps tiers and thresholds (ADR-006 §10) are NOT chosen here
  (owner/device gate, later slice).
- **No code outside `AnimiEngineCore`**, no `Package.swift`/`*.xcodeproj`/`ReferenceData` changes, no
  `Float`/`Double`/`Decimal`, no commits/staging.

---

## 1. Architectural stance: synchronous, injected, deterministic

ADR-006 §1 mandates *one serialized scheduler owner*. The cheapest way to make "serialized" **testable
and deterministic** is to model the scheduler as a **synchronous state reducer over an explicit input
clock**, not as a live `actor` with wall-time concurrency. Concurrency is a *deployment* concern of later
slices; the *contract* is a deterministic function of (state, command, injected clock reading,
worker-completion events).

Therefore Slice 3 introduces **no `async`/`await`/`actor`** into `AnimiEngineCore` (consistent with the
current 0-async, 122×`Sendable`, value-semantics module). Everything is:

- `Sendable` value types for identities, tuples, tokens, worksets;
- pure functions / a single non-async `EngineScheduler` struct/class whose every mutation is a method
  returning typed outcomes;
- **injected protocols** for the three impure seams — clock, evaluation, and worker completion — so tests
  drive time and faults by hand.

This satisfies "pure/control portions of ADR-006" exactly: we build the decision logic and prove it; we
do not build the threads, the audio engine, or the renderer.

### The three injected seams

```text
ClockSource        — reads current canonical ProjectTime for the active master (host or audio).
FramePlanProvider  — given (EvaluationWindow, ProjectTime) returns a FramePlan. Default adapter wraps
                     the existing TimelineEvaluator; tests inject late/failed/garbage providers.
WorkerCompletionBus — deterministic in-test queue of completions (frame rendered, media decoded, audio
                     range decoded) carrying their ADR-005 identity tuple. No real worker exists here.
```

All three are protocols with synchronous, deterministic in-test fakes. The scheduler never reads a wall
clock, never spawns work, never touches a file.

---

## 2. Implementation stages (ordered, each green before the next)

Each stage builds and keeps `AnimiEngineCoreTests` green; contract tests land *with* the stage.

### Stage A — Typed identity layer (ADR-005 §1–§3)

The 8 identity value types + the identity tuples + the cache-identity separation. No behavior, just types
+ their construction/equality/`Sendable`/non-interchangeability invariants. This is the foundation every
later stage references.

- `ProjectRevision`, `PlaybackEpoch`, `FrameRequestID`, `MediaRequestID`, `AudioRequestID`,
  `CacheArtifactID`, `ExportJobID`, `BenchmarkRunID`.
- `RequestIdentity` (the preview tuple) and `ExportIdentity` (revision + job, **no epoch**).
- Allocation is via injected monotonic generators (a `RevisionAllocator` / `EpochAllocator` / per-kind
  `RequestIDAllocator`) so IDs are deterministic in tests and never use `Date()`/`Math.random()`.
- `CacheArtifactID` is content-derived (carries the dependency descriptor) and is provably **independent**
  of epoch/request/frame IDs (ADR-005 §3): equal content ⇒ equal cache ID across epochs.

**STOP** if ADR-005 §3's cache-identity dependency descriptor cannot be expressed without a concept this
slice is forbidden to define (e.g. render-semantics version / color config) — in that case model the
descriptor as an **opaque caller-supplied `CacheDependencyDigest`** value (string/bytes) rather than
inventing render semantics here, and record the deferral. (Recommended default: opaque digest.)

### Stage B — Injected clock protocols + master-clock selection (ADR-006 §3)

- `protocol MasterClock` returning the current canonical `ProjectTime` for the active epoch, plus an
  `anchorProjectTime`. Two conforming kinds modelled as injected fakes:
  `MonotonicHostClock` (no-audio projects) and `AudioSampleClock` (audio-bearing epochs — **abstract**,
  returns canonical ticks derived from an injected sample reading; the real `AVAudioTime` mapping is
  Slice 4).
- `MasterClockSelector` — pure decision from the manifest's audio presence over the remaining playback
  range: *any unmuted canonical audio in range ⇒ audio master, else host master* (ADR-006 §3). Selection
  happens once per epoch and is **frozen** for that epoch. Silent gaps / final-source end do not switch.
- Pause/scrub/settle hold an explicit `ProjectTime` (no progressing clock); export has no realtime clock.

The "any unmuted audio in remaining range" predicate reuses `AudioEvaluator` / `AudioEvaluationWindow`
(an empty-segment plan over the remaining range ⇒ no audio ⇒ host master). **No new audio math.**

### Stage C — Transport state machine (ADR-006 §2, ADR-005 §4)

- `TransportState` enum with the 8 ADR-006 states and their associated `ProjectTime`/`PlaybackEpoch`.
- `TransportCommand` (play / pause / seek / scrubBegin / scrubUpdate(target) / scrubEnd / interrupt /
  routeChange / projectEdit(revision) / fail(error) / endReached).
- `TransportReducer` — pure `(state, command, clock, currentRevision) -> (newState, [SchedulerEffect])`.
  Every discontinuity (ADR-005 §4) mints a **fresh `PlaybackEpoch` before any new work is admitted** and
  emits invalidation effects (stop accepting old-epoch completions, cancel queued, flush-not-yet-rendered
  marker, record stale evidence). No auto-resume after interrupt/route change (ADR-006 §11).
- The playback **start barrier** (ADR-006 §5) is modelled as `preparing` → (anchor resolved + first
  complete frame ready + bounded audio preroll marker) → `playing`; bounded timeout ⇒ typed failure, never
  indefinite wait.

### Stage D — Complete-frame worksets + atomic publication (ADR-005 §5–§6, ADR-006 §6)

- `FrameWorkset` — one exact `ProjectTime`, the `RequestIdentity`, and the set of required inputs (every
  video layer / transition input / overlay derived from the `FramePlan`). Built from the existing
  `TimelineEvaluator` output via the injected `FramePlanProvider`.
- `PublishedFrame` token (ADR-005 §5): `ProjectRevision + PlaybackEpoch + FrameRequestID + ProjectTime +
  QualityProfileID + complete composed output handle`.
- `PublicationGate` — the atomic promote: a workset is publishable **only** when all 6 ADR-005 §5
  conditions hold (complete plan, every source resolved for *that* plan+time, all identities match active
  revision+epoch, render succeeded, **post-render** re-validation, atomic front-buffer promote). The
  renderer returns a value to the scheduler; it never publishes. The "render" here is the injected
  result-returning provider — Slice 3 proves the *gate*, not pixels.
- Forbidden-output enforcement (ADR-005 §6): no per-layer `lastGood`, no mixed-revision/mixed-epoch
  composition, no temporal substitution, no late-after-newer publish, no publish from a worker callback.
  These are encoded as gate rejections with typed reasons and asserted by tests.

### Stage E — Admission, cancellation, latest-wins scrub, exact settle (ADR-005 §4, §7; ADR-006 §6–§7)

- `AdmissionController` — validates a completion's identity tuple against current state; admits or rejects
  with a typed reason (`staleRevision / staleEpoch / supersededTarget / missingDependency /
  outsideCoverage`). Cancellation is an *optimization*; correctness is identity validation (ADR-005 §4),
  so a stale completion that *was* submitted is still rejected at the gate.
- Scrub coalescing (ADR-005 §7, ADR-006 §7): during `scrubbing`, only the latest target is publishable;
  intermediate targets become inadmissible by identity. Until the exact complete target frame exists, the
  previously published complete composition is kept.
- Settle barrier: `settling` requires the exact final target be evaluated and published *exactly* —
  cannot be replaced by a nearby target; engine stays paused there (no auto-resume).
- Playback latest-wins (ADR-006 §6): obsolete late frame discarded; on deadline miss, keep the previous
  complete composition, cancel obsolete work, advance to the newest eligible *global* frame-grid target,
  request one new complete workset for it. **Global only — never per-layer drift** (ADR-006 §10).

### Stage F — Bounded queues + audio admission + deterministic fault injection (ADR-005 §8, ADR-006 §9)

- `BoundedQueue<Element>` value model with an explicit capacity and an **eviction/rejection policy that
  drops obsolete speculative work first** (ADR-006 §9). Queues modelled: admitted worksets, per-source
  media decode requests, decoded-surface handles, audio chunks, export work. Depths are **injected runtime
  configuration**, never hardcoded constants (ADR-006 §9).
- Audio-buffer admission (ADR-005 §8): a decoded PCM range descriptor carries
  `ProjectRevision + PlaybackEpoch + AudioRequestID + AudioSourceID + exact sample range`; the scheduler
  validates it before it enters a preview source buffer; a discontinuity flushes all not-yet-rendered
  old-epoch ranges. **No actual PCM, no device** — the "buffer" is a bounded queue of validated range
  descriptors; the realtime callback is Slice 4.
- Deterministic fault injection harness (test-only): inject *late* completions, *failed* layers, *stale*
  completions, *duplicate* completions, *out-of-order* completions, *over-capacity* bursts. Assert: no
  mixed-time publication, bounded depth never exceeded, global skip keeps the previous complete frame,
  export identities survive a preview-epoch flush (ADR-005 §9 isolation).

### Stage G — Closure: diagnostics surface + evidence

- A **bounded, allocation-light diagnostics event model** (ADR-005 §9, ADR-006 "Required diagnostics"):
  typed lifecycle events (requested / admitted / decoded / rendered / rejected(reason) / cancelled /
  published(prev,new) / queue-occupancy / global-skip / epoch-transition). Pure value events appended to
  an injected sink; **no logging from any realtime path** (there is none in this slice).
- Implementation report `slice-003-implementation-report.md`: full file list, test matrix results, the
  `AnimiEngineCoreTests` count, render-matrix + ReferenceData hash unchanged proof (this slice touches no
  render path), forbidden-import sweep, scoped git status.

**Internal ordering rule:** A→B→C→D→E→F are sequential (each green before next); G closes. Do not advance
while the scoped suite is red (roadmap §1). If any stage requires AVFoundation, GPU, async device work, an
app file, or a degradation-tier numeric decision, **STOP and escalate** rather than implement.

---

## 3. Public / internal API shape (proposed)

> New subdirectory: `Sources/AnimiEngineCore/Runtime/`. All types `Sendable`; identity types
> non-interchangeable; no `Float`/`Double`/`Decimal`; no AVFoundation.

### 3.1 Identities (Stage A)

```swift
public struct ProjectRevision: Hashable, Sendable { public let raw: Int64; /* allocator-minted */ }
public struct PlaybackEpoch: Hashable, Sendable { public let raw: Int64 }
public struct FrameRequestID: Hashable, Sendable { public let raw: Int64 }
public struct MediaRequestID: Hashable, Sendable { public let raw: Int64 }
public struct AudioRequestID: Hashable, Sendable { public let raw: Int64 }
public struct ExportJobID: Hashable, Sendable { public let raw: Int64 }
public struct BenchmarkRunID: Hashable, Sendable { public let raw: String } // ADR-014 reproducible run
public struct QualityProfileID: Hashable, Sendable { public let raw: String }

public struct CacheDependencyDigest: Hashable, Sendable { public let raw: String } // opaque, caller-supplied
public struct CacheArtifactID: Hashable, Sendable {
    public let dependencyDigest: CacheDependencyDigest
    public let timeRange: ProjectTimeRange
    public let quality: QualityProfileID
    // content-derived ONLY; never carries epoch/request/frame IDs (ADR-005 §3)
}

public struct RequestIdentity: Hashable, Sendable {   // preview async work (ADR-005 §2)
    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    public let frameRequest: FrameRequestID
    public let time: ProjectTime
    public let quality: QualityProfileID
}
public struct ExportIdentity: Hashable, Sendable {    // export work — NO epoch (ADR-005 §2)
    public let revision: ProjectRevision
    public let job: ExportJobID
}
```

Monotonic, injected allocators (deterministic, no wall clock):

```swift
public protocol RevisionAllocator { mutating func next() -> ProjectRevision }
public protocol EpochAllocator    { mutating func next() -> PlaybackEpoch }
public protocol RequestIDAllocator { mutating func nextFrame() -> FrameRequestID; /* media/audio … */ }
```

### 3.2 Clocks (Stage B)

```swift
public protocol MasterClock: Sendable {
    var anchorProjectTime: ProjectTime { get }
    func currentProjectTime() throws -> ProjectTime     // injected; deterministic in tests
}
public enum MasterClockKind: Sendable { case monotonicHost; case audioSample }

public enum MasterClockSelector {
    // pure: audio present in remaining range ⇒ .audioSample, else .monotonicHost (ADR-006 §3)
    public static func select(window: AudioEvaluationWindow,
                              remaining: ProjectTimeRange) throws -> MasterClockKind
}
```

### 3.3 Transport (Stage C)

```swift
public enum TransportState: Sendable, Equatable {
    case paused(at: ProjectTime)
    case preparing(from: ProjectTime, epoch: PlaybackEpoch)
    case playing(epoch: PlaybackEpoch)
    case scrubbing(target: ProjectTime, epoch: PlaybackEpoch)
    case settling(target: ProjectTime, epoch: PlaybackEpoch)
    case interrupted(at: ProjectTime)
    case ended(at: ProjectTime)
    case failed(TransportFailure)
}
public enum TransportCommand: Sendable { /* play, pause, seek(at:), scrubBegin, scrubUpdate(target:),
    scrubEnd, interrupt, routeChange, projectEdit(ProjectRevision), endReached, fail(TransportFailure) */ }

public enum SchedulerEffect: Sendable, Equatable { /* mintEpoch, stopAcceptingEpoch(PlaybackEpoch),
    cancelQueued, flushUnrenderedAudio(PlaybackEpoch), requestWorkset(ProjectTime), holdLastPublished,
    recordStale(...) , beginPrepareBarrier(...), enterPlaying, enterPausedAt(ProjectTime) */ }

public enum TransportReducer {
    public static func reduce(_ state: TransportState, _ command: TransportCommand,
                              clock: MasterClock?, currentRevision: ProjectRevision,
                              epochs: inout some EpochAllocator)
        throws -> (TransportState, [SchedulerEffect])
}
```

### 3.4 Worksets, publication, admission (Stages D–E)

```swift
public struct FrameWorkset: Sendable, Equatable {
    public let identity: RequestIdentity
    public let plan: FramePlan            // from injected FramePlanProvider over the existing evaluator
    // required-input set is derived from `plan` (layers/transition/overlays)
}
public struct PublishedFrame: Sendable, Equatable {
    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    public let frameRequest: FrameRequestID
    public let time: ProjectTime
    public let quality: QualityProfileID
    // opaque complete-composition handle (no pixels in this slice)
}
public enum PublicationDecision: Sendable, Equatable { case publish(PublishedFrame); case keepPrevious(reason: RejectionReason) }
public enum RejectionReason: Sendable, Equatable {
    case staleRevision, staleEpoch, supersededTarget, missingDependency, outsideCoverage,
         incompleteComposition, postRenderRevalidationFailed, lateAfterNewer
}

public protocol FramePlanProvider: Sendable {                      // injected evaluation seam
    func plan(window: EvaluationWindow, at time: ProjectTime) throws -> FramePlan
}

public protocol RenderResultSource: Sendable {                     // injected render seam (returns a value)
    func render(_ workset: FrameWorkset) throws -> PublishedFrame   // tests inject late/failed/garbage
}

public enum PublicationGate {
    public static func evaluate(candidate: PublishedFrame, against current: SchedulerSnapshot)
        -> PublicationDecision                                     // enforces ADR-005 §5/§6
}

public enum AdmissionController {
    public static func admit<I>(identity: I, against current: SchedulerSnapshot)
        -> Result<Void, RejectionReason>                           // ADR-005 §4, §7
}
```

### 3.5 Bounded queues + audio admission (Stage F)

```swift
public struct BoundedQueue<Element: Sendable>: Sendable {
    public init(capacity: Int) throws                              // capacity > 0
    public mutating func admit(_ e: Element, isObsolete: (Element) -> Bool)
        -> Result<Void, BackpressureOutcome>                       // drops obsolete-first, else reject
}
public enum BackpressureOutcome: Sendable, Equatable { case rejectedFull; case evictedObsolete }

public struct DecodedAudioRangeDescriptor: Sendable, Equatable {   // ADR-005 §8 — NO PCM bytes
    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    public let request: AudioRequestID
    public let source: AudioSourceID
    public let sampleRange: AudioSampleRange
}
public enum AudioRangeAdmission {
    public static func admit(_ d: DecodedAudioRangeDescriptor, against current: SchedulerSnapshot)
        -> Result<Void, RejectionReason>                           // validates before buffering
}
```

### 3.6 The owner type

```swift
public struct EngineScheduler {                  // serialized owner (ADR-006 §1) — synchronous control core
    // owns: TransportState, current ProjectRevision, active PlaybackEpoch, bounded queues,
    //       last PublishedFrame, MasterClockKind. Mutated only via accept(_:) returning typed outcomes.
    public init(/* injected allocators, clock, FramePlanProvider, RenderResultSource, diagnostics sink */)
    public mutating func accept(_ command: TransportCommand) throws -> [SchedulerEffect]
    public mutating func accept(_ completion: WorkerCompletion) throws -> PublicationDecision
    public var snapshot: SchedulerSnapshot { get }   // immutable view used by gates + diagnostics
}
```

`SchedulerSnapshot` is the immutable `Sendable` view (current revision/epoch/state/last-published/queue
occupancy) that gates and the diagnostics surface read.

---

## 4. Production / test file list (proposed)

### New production — `Sources/AnimiEngineCore/Runtime/`

| File | Stage | Contents |
|---|---|---|
| `Identities.swift` | A | 8 identity types + `QualityProfileID` + `RequestIdentity`/`ExportIdentity` |
| `CacheArtifactID.swift` | A | content-derived cache identity + `CacheDependencyDigest` |
| `IdentityAllocators.swift` | A | monotonic injected allocator protocols + deterministic default impls |
| `MasterClock.swift` | B | `MasterClock` protocol, `MasterClockKind`, host/audio fakes |
| `MasterClockSelector.swift` | B | pure audio-presence master selection |
| `TransportState.swift` | C | states + `TransportFailure` |
| `TransportCommand.swift` | C | commands + `SchedulerEffect` |
| `TransportReducer.swift` | C | pure reduce + epoch minting + prepare barrier |
| `FrameWorkset.swift` | D | workset + required-input derivation from `FramePlan` |
| `PublishedFrame.swift` | D | publication token + `PublicationDecision`/`RejectionReason` |
| `PublicationGate.swift` | D | atomic publish gate (ADR-005 §5/§6) |
| `FramePlanProvider.swift` | D | evaluation seam protocol + default `TimelineEvaluator` adapter |
| `RenderResultSource.swift` | D | render seam protocol (value-returning) |
| `AdmissionController.swift` | E | identity admission + rejection reasons |
| `ScrubSettlePolicy.swift` | E | latest-wins coalescing + exact-settle barrier helpers |
| `BoundedQueue.swift` | F | bounded queue + obsolete-first backpressure |
| `AudioRangeAdmission.swift` | F | decoded-range descriptor admission (no PCM) |
| `EngineScheduler.swift` | D–F | the serialized owner + `SchedulerSnapshot` + `WorkerCompletion` |
| `SchedulerDiagnostics.swift` | G | bounded typed lifecycle event model + sink protocol |

### New tests — `Tests/AnimiEngineCoreTests/`

| File | Covers |
|---|---|
| `IdentityTests.swift` | non-interchangeability, equality, monotonic allocation, cache-ID epoch independence |
| `MasterClockSelectorTests.swift` | audio-present⇒audio, no-audio⇒host, post-gap audio still audio, frozen per epoch |
| `TransportReducerTests.swift` | all 8 states, every discontinuity mints fresh epoch *before* admission, no auto-resume, prepare barrier + bounded-timeout failure |
| `PublicationGateTests.swift` | 6-condition publish; rejects incomplete/stale/mixed/late-after-newer; no per-layer lastGood; no callback publish |
| `AdmissionStaleTests.swift` | stale revision/epoch/superseded/missing-dependency rejected even if work already "submitted" |
| `ScrubSettleTests.swift` | latest-wins coalescing keeps previous complete frame; exact settle publishes the exact target, stays paused |
| `WorksetMixedTimeTests.swift` | six-layer workset publishes one synchronized frame or nothing; transition never mixes epochs/targets |
| `BoundedQueueFaultTests.swift` | depth never exceeded; obsolete-first eviction; over-capacity burst; global skip keeps previous complete composition |
| `AudioAdmissionTests.swift` | old-epoch range rejected after seek/interrupt; discontinuity flushes not-yet-rendered ranges |
| `ExportIsolationTests.swift` | export identities survive a preview-epoch flush (ADR-005 §9) |
| `SchedulerDiagnosticsTests.swift` | lifecycle events emitted with identities + reasons; bounded; nothing logged from a (non-existent) realtime path |
| `RuntimeNoFloatNoAVTests.swift` | sweep `Runtime/*.swift`: ban `Float`/`Double`/`Decimal`/`import AVFoundation`/`import AVFAudio` (mirrors the Slice-002 sweep) |

### Docs

- `slice-003-implementation-plan.md` (this file).
- `slice-003-implementation-report.md` (Stage G closure).

---

## 5. Test matrix (maps every gate to a proof)

| ADR / roadmap gate | Proof test(s) |
|---|---|
| ADR-005 §1 distinct typed identities, not raw-int aliases | `IdentityTests` (compile-level non-interchangeability) |
| ADR-005 §3 cache ID independent of epoch/request | `IdentityTests.cacheReusableAcrossEpochs` |
| ADR-005 §4 fresh epoch before admission; cancellation is optimization | `TransportReducerTests`, `AdmissionStaleTests` |
| ADR-005 §5 6-condition atomic publish | `PublicationGateTests` |
| ADR-005 §6 no partial/mixed/temporal/late/callback publish | `PublicationGateTests`, `WorksetMixedTimeTests` |
| ADR-005 §7 latest-wins scrub + exact settle | `ScrubSettleTests` |
| ADR-005 §8 audio-range admission + epoch flush | `AudioAdmissionTests` |
| ADR-005 §9 / diagnostics | `SchedulerDiagnosticsTests` |
| ADR-005 §9 export isolation | `ExportIsolationTests` |
| ADR-006 §2 transport state machine, no auto-resume | `TransportReducerTests` |
| ADR-006 §3 master-clock selection frozen per epoch | `MasterClockSelectorTests` |
| ADR-006 §5 playback start barrier + bounded timeout | `TransportReducerTests` |
| ADR-006 §6 complete worksets + global late-frame skip | `WorksetMixedTimeTests`, `BoundedQueueFaultTests` |
| ADR-006 §7 silent scrub / exact settle | `ScrubSettleTests` |
| ADR-006 §9 bounded queues, injected depths, obsolete-first | `BoundedQueueFaultTests` |
| ADR-006 §10 global degradation, never per-layer drift | `WorksetMixedTimeTests`, `BoundedQueueFaultTests` |
| roadmap §4 stale completions cannot publish | `AdmissionStaleTests`, `PublicationGateTests` |
| roadmap §4 bounded queues under deterministic fault injection | `BoundedQueueFaultTests` |
| no Float / no AVFoundation | `RuntimeNoFloatNoAVTests` |
| no render regression (this slice touches no render path) | full `AnimiEngineCoreTests` green + ReferenceData hash unchanged |

---

## 6. Reused vs NOT reused

### Reused as-is (consumed, never modified)

- `TimelineEvaluator.evaluate(_:at:)` / `evaluate(_:atFrame:)` → wrapped by `FramePlanProvider`.
- `AudioEvaluator.evaluate(window:range:)` → drives `MasterClockSelector`'s audio-presence predicate.
- `EvaluationWindow` / `EvaluationWindowRequirement` / `EvaluationWindowBuilder`,
  `AudioEvaluationWindow` / `AudioEvaluationWindowBuilder`.
- `FramePlan` + tree (`FrameBody`, `SceneSubplan`, `ActiveLayer`, `TransitionPlan`, `ActiveOverlay`) →
  the required-input set of a `FrameWorkset` is *derived* from these, not redefined.
- `AudioPlan` / `AudioSegmentPlan` / `AudioSampleRange`.
- Time primitives: `ProjectTime`, `ProjectTimeRange`, `TickDuration`, `TickClock` (240,000),
  `RationalSourceTime`, `SourceTimeMapping`.
- `SceneMediaClock` (unchanged — the clock seams are *new* runtime clocks, not this media-math helper).
- Structural/audio typed IDs (`SceneInstanceID`, `LayerID`, `AudioSourceID`, …).
- `CanonicalProjectManifest` / `OutputContext` / `ResolvedScenePayload`.

### NOT reused / explicitly created fresh

- **No existing scheduler / transport / state / clock-service / generation type exists** — *all* of
  Slice 3 is greenfield in a new `Runtime/` directory.
- No reuse of any `AnimiApp` CP7.9 scheduler code (see §7).
- No `actor`/`async` from the module (none exists; none added).

---

## 7. Explicitly forbidden from the CP7.9 legacy scheduler

The app-level CP7.9 prototype scheduler is evidence only (ADR-006 Migration note; roadmap §9). The
following CP7.9 behaviors are **forbidden** from Slice 3 and must not be ported, referenced, or imitated:

- **per-layer / per-provider `lastGood` temporal fallback** — the single most-named anti-pattern
  (ADR-005 §6, ADR-006 §6/§10, roadmap §4/§9). The canonical engine keeps the *previous complete
  composition* or globally skips; it never composes a fresh layer with a stale layer.
- **mixed-time / mixed-epoch publication** of any kind.
- **per-source independent play/pause/scrub state** (ADR-006 §2 — there is exactly one transport).
- **app-owned host-time transport + route auto-resume** (ADR-006 §11 — no auto-resume; user must press
  play, which mints a new epoch + prepare barrier).
- **publishing from decoder / renderer / cache / audio callbacks** (ADR-005 §6 — only the serialized
  scheduler publishes, and only by promoting a returned value).
- **hardcoded worker counts / queue depths / preroll / cadence tiers** in control logic (ADR-006 §9 —
  these are injected runtime configuration).
- **whole-project CAF / `AVMutableComposition` / `AudioExportPlan` / `loopToFit`** assumptions (Slice
  4/5/7 deletion scope) — none of this audio-engine machinery appears in Slice 3.
- borrowing realtime scheduler state, preview degradation, or the device clock into export (ADR-006 §12).

---

## 8. Owner / product decision needed?

**One decision is recommended before Stage A, two items are confirmed deferred (not blocking).**

1. **RECOMMENDED — `CacheArtifactID` dependency descriptor shape.** ADR-005 §3 says cache identity
   includes "dependency hash, time range, quality profile, render-semantics version and color
   configuration." *Render-semantics version* and *color configuration* are concepts this slice is
   forbidden to define (they belong to the render/color work in later slices). **Proposed default
   (proceed unless overridden):** model the descriptor as an **opaque caller-supplied
   `CacheDependencyDigest`** (the caller will later fold render-semantics/color into that digest), plus
   the explicit `timeRange` + `QualityProfileID` that *do* exist now. This keeps `CacheArtifactID`
   content-derived and epoch-independent without inventing render semantics here. Owner only needs to
   confirm/deny the opaque-digest approach.

2. **DEFERRED (not needed for Slice 3) — degradation cadence tiers (30/24/15 fps) and queue
   depths/preroll/timeout numerics.** ADR-006 §9/§10 explicitly make these *device-evidence* runtime
   configuration. Slice 3 models them as injected parameters and proves the *policy* (global, obsolete-
   first, never per-layer); the *values* are an owner/device gate in a later slice. No decision now.

3. **DEFERRED (confirmed by hard boundaries) — audio-master `AVAudioTime` mapping.** The audio-sample
   master clock is an injected protocol here; the real `AVAudioTime` anchoring is Slice 4. No decision now.

If the owner rejects the opaque-digest default in (1), Stage A pauses for an explicit descriptor spec;
nothing else in the plan blocks.

---

## 9. STOP conditions (must escalate, not implement-around)

1. Any task requires **AVFoundation / AVFAudio / `AVAudioEngine` / `AVAudioTime`** → STOP (Slice 4).
2. Any task requires **GPU / Metal / RenderGraph / real decode / upload / pixels** → STOP.
3. Any task requires **`async`/`await`/`actor`** to be added to `AnimiEngineCore` to express the contract
   → STOP and reconsider the synchronous-reducer stance with the owner (the plan asserts it is
   unnecessary).
4. Any task requires touching **`AnimiApp`**, `Package.swift`, `*.xcodeproj`, or `ReferenceData` → STOP.
5. Any task requires a **numeric degradation tier / queue depth / timeout** to be hardcoded in control
   logic → STOP (must be injected; values are a later device gate).
6. `CacheArtifactID` cannot be expressed without inventing **render-semantics/color** concepts AND the
   owner has not approved the opaque-digest default → STOP (decision §8.1).
7. Exact tick/sample/frame mapping needed by the scheduler cannot reuse existing `ProjectTime` /
   `AudioSampleRange` / frame-rate math and would need a **new `Float`/approximate** path → STOP
   (no approximation; the existing exact integer/rational APIs must suffice).
8. The scoped `AnimiEngineCoreTests` suite goes red and cannot be made green within the stage's scope
   without crossing a boundary above → STOP.

---

## 10. Readiness verdict

**READY.** All four inputs (ADR-005, ADR-006, roadmap §4, Slice-002 report) are consistent and present in
version control; the existing pure evaluation/timeline/window/time APIs are sufficient to build the
control core synchronously, with the three impure seams cleanly injectable. The single recommended owner
decision (§8.1, cache-dependency digest) has a safe default that lets Stage A proceed; the other two
items are confirmed deferred by the hard boundaries. Baseline `AnimiEngineCoreTests` is green
(362/1 skipped/0 fail). No code was written in this preflight.
