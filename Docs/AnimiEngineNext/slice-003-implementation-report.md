# Slice 003 — Implementation Report: Identities, Transport & Atomic Scheduler

- **Status:** Stages A–G COMPLETE. Closure/evidence pass.
- **Date context:** 2026-06-25.
- **Scope delivered:** the typed runtime identities (ADR-005 §1–§3), injected clock protocols +
  master-clock selection (ADR-006 §3), the transport state machine + pure reducer (ADR-006 §2,
  ADR-005 §4), complete-frame worksets + atomic publication gate (ADR-005 §5–§6, ADR-006 §6), admission
  + latest-wins scrub + exact settle (ADR-005 §4/§7, ADR-006 §6/§7), bounded queues + audio-range
  admission + the minimal serialized `EngineScheduler` owner (ADR-005 §8, ADR-006 §1/§9), and bounded
  typed diagnostics (ADR-005 §9, ADR-006 "Required diagnostics") — all inside
  `AnimiEngineNext/Sources/AnimiEngineCore/Runtime/`.
- **Plan of record:** `Docs/AnimiEngineNext/slice-003-implementation-plan.md`.
- **Normative contracts:** ADR-005, ADR-006 (pure/control portions), canonical-runtime-roadmap §4.
- **Tech-lead decision honored:** `CacheArtifactID` uses an opaque caller-supplied `CacheDependencyDigest`;
  no render-semantics/color concepts invented here.
- **Nothing staged or committed by this slice.**

---

## 1. What was built (stage by stage)

| Stage | Delivered | Net effect |
|---|---|---|
| **A** | `Identities.swift` (8 typed IDs + `RequestIdentity`/`ExportIdentity`), `CacheArtifactID.swift` (content-derived, opaque digest), `IdentityAllocators.swift` (deterministic monotonic). | Distinct non-interchangeable identities; cache identity epoch/request-independent. |
| **B** | `MasterClock.swift` (injected protocol + `MasterClockKind`), `MasterClockSelector.swift`. | Pure master-clock selection reusing `AudioEvaluator`; frozen per epoch by the caller. |
| **C** | `TransportState.swift` (8 states + `TransportFailure`), `TransportCommand.swift` (commands + `SchedulerEffect` + `InvalidationReason`), `TransportReducer.swift`. | Serialized transport; every discontinuity mints a fresh epoch and emits `.activateEpoch`; no auto-resume. |
| **D** | `FrameWorkset.swift` (+ `RequiredInput`), `PublishedFrame.swift` (+ `PublicationDecision`/`RejectionReason`), `PublicationGate.swift`, `FramePlanProvider.swift`, `RenderResultSource.swift` (+ `RenderAttempt`), `SchedulerSnapshot.swift`. | Required inputs derived from `FramePlan`; atomic publish gate enforcing the 6 §5 conditions + §6 forbidden cases (incl. quality). |
| **E** | `AdmissionController.swift`, `ScrubSettlePolicy.swift`. | Identity admission (stale/superseded/coverage/missing-dep); latest-wins scrub coalescing; exact settle barrier; global presentation. |
| **F** | `BoundedQueue.swift` (obsolete-first), `AudioRangeAdmission.swift` (no PCM), `EngineScheduler.swift` (serialized owner). | Bounded queues never exceed capacity; audio-range identity admission + old-epoch flush; one owner wires reducer+admission+gate+snapshot. |
| **G** | `SchedulerDiagnostics.swift` (typed events + bounded sink); `EngineScheduler` diagnostics emission (pure value additions). | Read-only lifecycle/identity/queue/skip evidence; purely observational. |

---

## 2. The cross-stage epoch contract (the key correctness invariant)

ADR-005 §4 requires a **fresh `PlaybackEpoch` before any new work is admitted** at *every* transport
discontinuity. Held states (`paused`/`interrupted`/`ended`/`failed`) carry no epoch, so the owner cannot
recover the new accepting epoch from the state alone. The canonical effect **`.activateEpoch(PlaybackEpoch)`**
closes this:

- `TransportReducer` emits `.activateEpoch(new)` whenever it mints a fresh epoch — via `mintWithInvalidation`
  (seek / scrubBegin / play-from-held / settling→play) **and** `invalidateAndActivateFresh` (pause /
  interrupt / routeChange / projectEdit / endReached / fail / **prepareTimedOut**). Order is always
  `stopAcceptingEpoch(old)` → `cancelQueued` → `flushUnrenderedAudio(old)` → `recordInvalidation` →
  `activateEpoch(new)` (old sealed off **before** new activated).
- `EngineScheduler.accept` adopts `activeEpoch` from `.activateEpoch` **before** flushing the audio queue
  or admitting any completion. This is what makes the superseded epoch's in-flight work immediately
  inadmissible even when the resulting state is held.

This contract was the subject of two Stage-F corrective passes (held-state leak, then the
`prepareTimedOut` leak); both are now closed and regression-tested.

---

## 3. Diagnostics API shape (Stage G)

```swift
public enum SchedulerDiagnosticEvent: Sendable, Equatable {
    case requested(RequestIdentity)
    case admitted(RequestIdentity)
    case rejected(reason: RejectionReason, time: ProjectTime, epoch: PlaybackEpoch)
    case published(previous: PublishedIdentitySummary?, new: PublishedIdentitySummary)
    case keptPrevious(reason: RejectionReason)
    case epochTransition(from: PlaybackEpoch?, to: PlaybackEpoch)
    case queueOccupancy(queue: DiagnosticQueue, count: Int, capacity: Int)
    case audioRange(reason: RejectionReason?, epoch: PlaybackEpoch, request: AudioRequestID)
    case audioFlushed(count: Int, supersededInto: PlaybackEpoch)
}
public enum DiagnosticQueue: Sendable, Equatable { case workset; case audioRange }

public protocol SchedulerDiagnosticsSink: Sendable {
    mutating func record(_ event: SchedulerDiagnosticEvent)
}

public struct BoundedDiagnosticsSink: SchedulerDiagnosticsSink {
    public let capacity: Int                    // > 0, fail-closed
    public private(set) var events: [SchedulerDiagnosticEvent]   // bounded ring (oldest dropped)
    public private(set) var recordedCount: Int  // total ever recorded (drop detection)
    public init(capacity: Int) throws
    public mutating func record(_ event: SchedulerDiagnosticEvent)
}
public enum SchedulerDiagnosticsError: Error, Equatable, Sendable { case invalidCapacity(Int) }
```

`EngineScheduler` gained an optional `diagnostics: BoundedDiagnosticsSink?` (defaulted `nil`) and a private
`emit(_:)`. The full request lifecycle is recorded: `enqueueWorkset` emits `.requested` +
`.queueOccupancy(.workset)`; `admit` (now `mutating` solely to append an event — the decision is unchanged)
emits `.admitted` on success / `.rejected(reason,time,epoch)` on failure; `enqueueAudioRange` emits
`.audioRange` + `.queueOccupancy(.audioRange)`; `accept` emits `.epochTransition` and `.audioFlushed`;
`publish` emits `.published(previous,new)` / `.keptPrevious(reason)`. **Diagnostics are purely
observational**: a scheduler with no sink produces identical effects, state, AND completion/enqueue/publish
decisions (proven by `testDiagnosticsDoNotChangeBehavior`). No event is emitted from any realtime path
(there is none in this slice); the sink is bounded; no `Date`/`UUID`.

---

## 4. Cross-stage consistency verdict (A–G)

The control core composes as one coherent pipeline:

```
TransportReducer  →  SchedulerSnapshot  →  AdmissionController  →  PublicationGate
   (state+effects)     (immutable view)      (identity admit)        (atomic publish)
```

- **TransportReducer → SchedulerSnapshot:** the reducer's `.activateEpoch`/state drive
  `EngineScheduler.activeEpoch`/`transport`, which `snapshot` exposes immutably. ✔
- **SchedulerSnapshot → AdmissionController:** admission validates `RequestIdentity`/`RenderAttempt`/
  `PublishedFrame` against the snapshot using the SAME identity coordinates (revision, epoch, coverage,
  `currentTarget`) the reducer maintains. ✔
- **AdmissionController ↔ PublicationGate:** the gate's identity/coverage/supersession/completeness checks
  are a superset of admission's (gate adds the 6-condition publish + late-after-newer + post-render
  revalidation). The two share `RejectionReason` and the same snapshot semantics, so a completion the gate
  rejects, admission also rejects (and vice-versa for the overlapping reasons). ✔
- **Quality** is part of the preview identity tuple and is validated in BOTH admission and the gate
  (`published.quality == workset.identity.quality`). ✔
- **EngineScheduler owns all mutation:** `transport`, `revision`, `activeEpoch`, `coverage`,
  `currentTarget`, `lastPublished`, `masterClockKind`, both queues, and `diagnostics` are all
  `public private(set)` (or `private`), mutated ONLY through `accept`/`setCurrentTarget`/`enqueue*`/
  `publish`. Workers/gates/policies are pure and never mutate owner state or publish directly. ✔
- **No forbidden runtime semantics:** no per-layer `lastGood`, no mixed-time/mixed-epoch publication, no
  auto-resume, no hardcoded queue depths (all capacities injected), no `async`/`actor`, no realtime
  workers, no PCM, no AVFoundation. ✔

**Verdict: CONSISTENT A–G.**

---

## 5. Files (whole Slice 003)

New production (`Sources/AnimiEngineCore/Runtime/`, 20 files):
`Identities.swift`, `CacheArtifactID.swift`, `IdentityAllocators.swift`, `MasterClock.swift`,
`MasterClockSelector.swift`, `TransportState.swift`, `TransportCommand.swift`, `TransportReducer.swift`,
`FrameWorkset.swift`, `PublishedFrame.swift`, `PublicationGate.swift`, `FramePlanProvider.swift`,
`RenderResultSource.swift`, `SchedulerSnapshot.swift`, `AdmissionController.swift`, `ScrubSettlePolicy.swift`,
`BoundedQueue.swift`, `AudioRangeAdmission.swift`, `EngineScheduler.swift`, `SchedulerDiagnostics.swift`.

New tests (`Tests/AnimiEngineCoreTests/`): `IdentityTests`, `RuntimeNoFloatNoAVTests`,
`MasterClockSelectorTests`, `TransportReducerTests`, `PublicationGateTests`, `WorksetMixedTimeTests`,
`AdmissionStaleTests`, `ScrubSettleTests`, `BoundedQueueFaultTests`, `AudioAdmissionTests`,
`EngineSchedulerTests`, `SchedulerDiagnosticsTests`.

Docs: `slice-003-implementation-plan.md`, `slice-003-implementation-report.md` (this file).

No existing production file outside `Runtime/` was modified. `TimelineEvaluator`/`AudioEvaluator`/
`ProjectValidator` and the render modules are untouched.

---

## 6. Test results

```
swift test --filter AnimiEngineCoreTests
→ Executed 493 tests, with 1 test skipped and 0 failures (0 unexpected)
```

The 1 skip is a pre-existing skipped test unrelated to the runtime.

---

## 7. Forbidden-token sweeps (A–G)

Over `Sources/AnimiEngineCore/Runtime/*.swift`:

- **`Float` / `Double` / `Decimal` / `import AVFoundation` / `import AVFAudio`:** none (CLEAN).
- **`Date(` / `UUID(` / `.random` / `arc4random`:** no real calls — the only matches are doc comments in
  `Identities.swift`/`IdentityAllocators.swift` that ASSERT their absence.
- **`async` / `actor` / `await`:** none — the only match is a doc comment in `EngineScheduler.swift`
  asserting the synchronous, no-actor stance.
- **`lastGood`:** none.
- **hardcoded queue depths:** none — all capacities are injected init parameters.

`RuntimeNoFloatNoAVTests` additionally enforces the no-Float/no-AV sweep as a test, and requires all 20
`Runtime/*.swift` files by name.

---

## 8. Scope guarantees

No file changed under any forbidden path: `AnimiApp/`, `Package.swift`, `*.xcodeproj`, `ReferenceData/`,
`AnimiEngineMetalRender/`, `AnimiEngineRenderModel/`, AVFoundation/AVFAudio, export, preview integration.
The pre-existing `AnimiApp.xcscheme` modification is session-start snapshot state, never touched by this
slice. Nothing was staged or committed.
