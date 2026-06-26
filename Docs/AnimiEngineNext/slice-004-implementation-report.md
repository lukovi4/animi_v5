# Slice 004 — Implementation Report (unit/offline closure)

**Status: Stage H complete — Slice 004 unit/offline closure complete.**
Physical-device evidence gate (§6 of the plan) remains an obligatory, *separate* close condition and is **not** part of this unit closure. No `AnimiApp`, no device/integration code, no commit performed.

Date: 2026-06-26. Scope: `AnimiEngineNext/Sources/AnimiEngineCore/Realtime/` + its `AnimiEngineCoreTests`.

See `slice-004-implementation-plan.md` for the authoritative contract; this report records the per-stage evidence that the plan's Stages A–H are implemented and unit/offline-proven.

---

## Start preconditions (B1/B2/B3)

- **B1 / D-213** — CLOSED / ACCEPTED OFFLINE-PROVEN. Canonical output-overload stage = Candidate **A** hard saturation `clamp(x, -1, +1)` (`d213.hardSaturation.v1`); Candidate **B** stateless safety limiter = documented fallback. Determinism, preview/export sample-equivalence, ≤ full-scale bound, below-threshold transparency, and non-finite fail-closed are proven by committed evidence + device-free tests. **Physical-device audible-quality confirmation is PENDING** (Slice-004 device gate).
- **B2 / Slice 3.5 corpus** — CLOSED / COMMITTED (`01e89e2bfb4e6dc7f5d22022462ea99e26398db8`).
- **B3** — was the Stage B deliverable (audio-sample → ProjectTime adapter); implemented. Remains a hard gate only for **device A/V-sync evidence**.

---

## Per-stage evidence (A–H)

| Stage | Deliverable | Files | Proof (unit/offline) |
|------|-------------|-------|----------------------|
| **A** | Device-format & session adapter boundary (protocol/value only, no AVFoundation) | `Realtime/AudioOutputFormat.swift`, `Realtime/AudioSessionAdapter.swift` | `AudioSessionAdapterContractTests` (15) — activation-before-query ordering, fail-closed inactive state, value invariants, **scoped sweep** (no AV import / no `Float`/`Double`/`Decimal` outside the two narrowed boundary files). |
| **B** | Audio-sample master clock + monotonic host clock + exact 5-ticks/sample mapping | `Realtime/SampleTimeMapping.swift`, `Realtime/AudioSampleMasterClock.swift`, `Realtime/MonotonicHostMasterClock.swift` | `SampleTimeMappingTests`, `AudioMasterClockTests` — integer-only inverse mapping, fail-closed on negative/overflow, injected sample/tick providers (no `Date`/`DispatchTime`). |
| **C** | Bounded PCM preparation model (metadata + opaque payload, no raw sample arrays) | `Realtime/PreparedAudioBuffer.swift`, `Realtime/AudioChunkPreparer.swift` | Throwing init validates self-contained invariants (non-inverted/non-empty range, `sourceSampleRate > 0`); `AudioChunkBounds.validate` enforces destination containment + injected max (ADR-005 §8, ADR-006 §9). |
| **D** | Deterministic output-overload stage (D-213 accepted Candidate A) | `Realtime/OutputOverloadStage.swift` | `OutputOverloadStageTests` + benchmark vectors — stateless `clamp(x,-1,+1)`, identical preview/export, non-finite → `OutputOverloadStageError.nonFiniteSample`. |
| **E** | Realtime preview audio graph (bounded software mix; the only AVFoundation boundary) | `Realtime/PreviewAudioGraph.swift`, `Realtime/RealtimeSafeState.swift` | `PreviewAudioGraphContractTests` — canonical order **per-source gain/mute → sum → OutputOverloadStage (post-mix) → ONE mixed mono buffer at explicit anchor-derived `AVAudioTime`**; no `at: nil`; bounded admission; immutable `RealtimeSafeState` snapshot; structural realtime-callback purity. |
| **F** | Playback-start barrier + master-preview session | `Realtime/PlaybackStartBarrier.swift`, `Realtime/AudioMasterPreviewSession.swift` | `PlaybackStartBarrierTests` (14) + `AudioMasterPreviewSessionTests` (16) — no audible audio before first frame; required-gate set per clock kind; injected timeout fail-closed; canonical anchor contract (identity-checked `configureAnchor`, `preroll.anchor == graph.scheduleAnchor`); preroll only via `PreviewAudioGraph.scheduleMix`; host epoch schedules no audio. |
| **G** | Interruption / route-change **pause-only** (OD-1 default) | `Realtime/RealtimeAudioSessionEvent.swift` (+ `AudioMasterPreviewSession`) | `InterruptionRouteChangePauseOnlyTests` (13) — every relevant event invalidates + refuses further scheduling + stays paused; last confirmed time captured from injected clock (fail-closed `clockReadFailedDuringPause`); `interruptionEnded` does NOT auto-resume; **`newDeviceAvailable` is pause-only, legacy reprepare+restart NOT ported**; output re-query is prep-only (no auto-start); explicit play requires a NEW epoch/session. |
| **H** | Silent-scrub guarantee + closure report | (no new production; guard already in place) | `SilentScrubAudioTests` (7) — scrub schedules **no** audio (behavioural, 25 iterations); `scrubSettlePreview(true)` → typed `scrubMustNotStartAudio` with no scheduling; settle leaves session not-started/no-preroll; **structural proof** the `scrubSettlePreview` body references none of `AudioChunkPreparer`/`PreviewAudioGraph`/`scheduleMix`/`scheduleInitialAudioPreroll`/`graph.`; explicit play preroll still works after scrub; Stage G pause-only unchanged. |

---

## Canonical invariants held across the slice

1. **Silent scrub** — scrub never starts/prepares/schedules audio; settle stays paused; preroll only on explicit play (ADR-006 §7, ADR-012 §6).
2. **No audible audio before the first video frame** — enforced by the barrier's required gate set and the audio-scheduling guard (ADR-006 §5).
3. **Output stage is post-mix** — D-213 Candidate A applied to the summed accumulator, not per source (ADR-012 §4).
4. **Pause-only discontinuities** — interruption/route/new-device/output-format → invalidate + paused; no auto-resume, no restart-on-new-device (ADR-006 §11, ADR-012 §7; OD-1 default).
5. **Bounds are injected** — timeouts, max-chunk samples, anchors; no hardcoded queue depths/deadlines (ADR-006 §9; OD-2 deferred to device gate).
6. **Fail-closed typed errors** everywhere; no silent advance.

## Forbidden Stage-H/later types confirmed ABSENT in `Realtime/`

No realtime render callback / audio render tap / engine driver / interruption-resume coordinator / background-audio continuation type exists (structural `testStageHForbiddenTypesAbsent`).

---

## Remaining device gate (NOT part of this unit closure)

Per plan §6, the following require physical iPhone 13 Pro evidence and are **open**:

- **D-213 audible-quality confirmation** — Candidate A on device; B adopted only if A is rejected at the device gate. **PENDING.**
- Real A/V sync from audio-master clock (ADR-006 §3) on device.
- Realtime callback purity under true underrun/starvation.
- Real route events (headphones/BT connect+disconnect) → pause, no auto-resume, no restart (OD-1).
- Old-epoch PCM hardware-recall semantics after seek/interruption.
- 6/10/20-video-with-music bounded memory/queue under real memory/thermal (10/20 extends into Slice 6).
- OD-2 concrete preroll/lookahead/PCM-chunk/timeout/queue-depth values selected by device-class evidence.

**Build/run target for device evidence:** `AnimiApp.xcodeproj`, scheme `AnimiApp`, physical iPhone 13 Pro.

---

## Unit/offline test totals (device-free)

Full `AnimiEngineCoreTests`: **659 tests, 1 skipped, 0 failures** (deterministic across reruns). Slice-004 Realtime suites within it: `AudioSessionAdapterContractTests` 15, `PlaybackStartBarrierTests` 14, `AudioMasterPreviewSessionTests` 16, `InterruptionRouteChangePauseOnlyTests` 13, `SilentScrubAudioTests` 7 (+ Stage B/C/D/E suites).

**Slice 004 unit/offline closure: COMPLETE. Device gate + D-213 device confirmation: PENDING.**
