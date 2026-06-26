# Slice 004 — Implementation Plan: Realtime Audio & Audio-Master Preview

- **Status:** PREFLIGHT / AUDIT. Planning only — **no production code, no tests, no commit**.
- **Date context:** 2026-06-25.
- **Scope of record:** ADR-006 §3/§5/§8/§9/§11 (realtime portions), ADR-012 §4/§5/§6/§7/§9/§10/§11, roadmap §6.
- **Builds on:** Slice 001 (canonical audio schema v3), Slice 002 (`AudioEvaluator` + `AudioPlan` + `SceneMediaClock`), Slice 003 (Runtime scheduler core: transport/revision/epoch/admission/publication/diagnostics — committed `df5922c3`).
- **Owner product rules fixed (ADR-012 "Approved product behavior"):**
  1. Scrub audio is **silent** (no scrub-audio path at all).
  2. Audio **always mixes** — every temporally active, unmuted source plays; a visual transition never replaces a source.
  3. **All videos play**; the user controls volume/mute per source.
  4. Music **never loops** (`.once` only).
  5. Route change / interruption / new device → **pause only, no auto-resume**; the user presses play.

---

## 0. Readiness verdict

> **BLOCKED.**

Slice 004 is the first **realtime / AVFoundation / device** slice. It remains **BLOCKED**: **B1 / D-213** (the audio overload/output stage) is still **not closed**, **B2 / Slice 3.5 corpus** is **closed in the working tree** (real deterministic fixtures + device-free test) but **must be committed** in the same changeset before any device/runtime gate runs, and **B3** (the canonical realtime drive coordinate from sample time) is still a structural implementation precondition that does not yet exist. Slice 004 cannot start a green implementation stage until B1 is closed and B3 is built (and B2 committed). The pure/control foundation it consumes (Slices 001–003) **is** ready and correct.

### Blockers (must clear before Stage A of Slice 004)

| # | Blocker | Evidence | Type |
|---|---|---|---|
| **B1** | **D-213 (audio overload/output stage) is not closed.** ADR-012 §4 + roadmap §5 both require D-213 *accepted before Slice 4 begins*; the output stage must be "identical in preview and export". | `Docs/AnimiEngineNext/decision-register.md:76` → status `BENCHMARK DECISION` (not `APPROVED`); `AnimiEngineNext/Docs/ADR-012-canonical-audio-architecture.md:358`; `Docs/AnimiEngineNext/canonical-runtime-roadmap.md:151`. | Decision/benchmark gate. Owner+benchmark. |
| **B2** | **RESOLVED (2026-06-26).** Slice 3.5 deterministic media corpus is implemented: real committed, byte-stable, deterministically-regenerable fixtures (44.1/48/96 kHz tones + silence, real silent-video / known-audio-video PPM frame sequences + committed 48 kHz PCM, corrupt/missing, 6/10/20-video stress + transition-overlap project descriptors) under `Docs/AnimiEngineNext/media-corpus/`, hash-verified by a device-free test. *(Files created, not yet git-committed, per the no-commit policy — they must be committed in the same changeset before the Slice-4 device gate runs.)* | `Docs/AnimiEngineNext/slice-003.5-deterministic-media-corpus.md`; `media-corpus/corpus-manifest.json` (26 assets). | CLOSED. |
| **B3** | **No canonical realtime drive coordinate from sample time.** ADR-006 §3 requires deriving `ProjectTime` from `AVAudioTime` sample time anchored to the epoch's project start, and §4 fixes the exact 48 kHz↔tick mapping. `MasterClock` is currently an injected protocol with no audio-sample implementation (`MasterClock.swift:9-16`), and there is no `audioSampleTime → ProjectTime` adapter. This is core Slice-004 work, but it is also a hard precondition for *any* device A/V-sync evidence, so it is called out as a structural blocker, not just a stage. | `AnimiEngineNext/Sources/AnimiEngineCore/Runtime/MasterClock.swift:1-28`. | Implementation precondition (Stage B of this slice). |

### Owner product-behavior decisions still required (not technical questions)

| # | Decision needed | Safe canonical default chosen | Justification |
|---|---|---|---|
| **OD-1** | On `newDeviceAvailable` route change while a *current* play session exists, the legacy app **reprepares + restarts** playback (`AnimiApp/Sources/EditorRuntime/EditorRuntime.swift:1406-1407`). ADR-006 §11 / ADR-012 §7 say the engine **never auto-resumes** — *any* route change pauses and waits for explicit play. | **DEFAULT: treat `newDeviceAvailable` as pause-only too.** The canonical engine pauses + invalidates epoch on every relevant route change and does **not** restart on new-device. The legacy reprepare+restart is non-canonical and is **not** ported. | Strict reading of ADR-006 §11 ("relevant route change pauses … never auto-resumes") and ADR-012 §7 (item 5 "remains paused until the user presses play"). Restart-on-new-device is the single observed auto-resume path and the new contract forbids it. Owner may override to keep restart-on-new-device, but that contradicts the accepted ADR. |
| **OD-2** | Preroll/lookahead/PCM-chunk/timeout/queue-depth concrete values. | **DEFAULT: leave as injected runtime configuration with no hardcoded constants; device-class evidence selects them in the Slice-004 device gate / Slice 6.** | ADR-006 §9 and ADR-012 §11 forbid hardcoding these. They are *config*, not architecture — so the *plan* needs no number; the *device gate* picks them. Not an architecture blocker. |
| **OD-3** | Bounded-preparation timeout failure UX (preview pause vs typed failure surface) when required audio cannot be prepared. | **DEFAULT: bounded rebuffer → typed `preparationTimedOut` failure → transport `failed`/`paused` per ADR-006 §5/§8; surface as a typed engine error, no silent advance.** | ADR-006 §5 ("bounded timeout … typed failure") + §8 ("must not continue advancing the audio master while silently dropping required audio"). |

OD-1 is the only one that changes *behavior*; OD-2/OD-3 have safe canonical defaults and do not block.

---

## 1. Current-state evidence (with file paths)

All paths relative to repo root. Captured read-only; nothing modified.

### 1.1 Preview audio — legacy whole-project pre-render (migration input, do NOT port)
- `AnimiApp/Sources/EditorRuntime/EnginePreviewAudioPlaybackController.swift:1-537` — owns `AVAudioEngine` + `AVAudioPlayerNode`; **offline-renders the whole composition to a temporary CAF before playback** (`:363-429`, `renderToFile()` via `AVAssetReader` + `AVAudioFile`). **Forbidden by ADR-012 §5** ("must not pre-render the whole project into a temporary audio file before playback").
- `EnginePreviewAudioPlaybackController.swift:40` — `renderSampleRate = 44100.0`. **Forbidden** as canonical: canonical mix is 48 kHz / Float32 (ADR-012 §4); 44.1k is a legacy temp-CAF artifact.
- `AnimiApp/Sources/EditorRuntime/EditorRuntimePreviewAudioCoordinator.swift:9-389` — lifecycle owner (build/install/teardown) of the legacy preview audio pipeline.

### 1.2 Transport / play / pause / seek / scrub (legacy CADisplayLink-master)
- `AnimiApp/Sources/EditorRuntime/PlaybackTransport.swift:26-84` — stateless host-time sampler; **CADisplayLink supplies the master host time**.
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift:173,1171` — `CADisplayLink` stored + created for timeline preview.
- `EditorRuntime.swift:1441-1485` — `displayLinkFired()`: **CADisplayLink is the driving/master clock** for the whole preview. **Non-canonical** for audio-bearing epochs: ADR-006 §3 makes the **audio render clock** master when unmuted audio exists; the monotonic host clock is master only for no-audio projects.
- `EditorRuntime.swift:1869-1873` — `DisplayLinkTarget` retain-cycle wrapper.

### 1.3 Route change / interruption / auto-resume
- `AnimiApp/Sources/App/AudioSessionManager.swift:130-201` — registers `interruptionNotification`, `routeChangeNotification`, `mediaServicesWereResetNotification` observers.
- `AudioSessionManager.swift:167-179` — `handleInterruption()`: **ignores `shouldResume`** (correct — matches ADR no-auto-resume).
- `EditorRuntime.swift:1381-1418` — `handleAudioSessionEvent()`:
  - `.interruptionBegan` → abort+stop (`:1385`) ✔ canonical pause-only.
  - `.interruptionEnded` → **does nothing** (`:1387 break`) ✔ no auto-resume.
  - `.routeChanged(oldDeviceUnavailable)` → `stopPlayback()` (`:1397`) ✔.
  - `.routeChanged(newDeviceAvailable)` → **`reprepareForRouteChange()` + `startForTimelinePlayback()`** (`:1406-1407`) → **AUTO-RESTART** ✖ — the one path that conflicts with ADR-006 §11 / ADR-012 §7. → **OD-1.**
  - `.mediaServicesReset` → abort+stop+invalidate (`:1413-1414`) ✔.

### 1.4 Forbidden / legacy markers
- `AnimiApp/Sources/Export/AudioExportPlan.swift:14,24,33,65` — `loopToFit` (export). **Forbidden** (ADR-012 §1 `.once` only). Not in this slice's path; removed at cutover (roadmap §9).
- `AnimiApp/Sources/Export/AudioCompositionBuilder.swift:356-419` — `applyTransitionRamps()` (implicit transition gain fade). **Forbidden** (ADR-012 §2 — no synthesized crossfade/duck/ramp).
- `AnimiApp/Sources/Player/NextVideoPrewarmScheduler.swift:29,113,158,297` — per-layer `lastGood` (video only). **Forbidden temporal fallback** (ADR-005 §6 / ADR-006 §6) — must never be promoted; not an audio path, but the same temporal-substitution rule governs audio admission.
- `AnimiApp/Sources/Export/AudioCompositionBuilder.swift:66-430` — `AVMutableComposition` + `AVAudioMix` as source of truth. **Migration input** (ADR-012 migration note), not canonical.
- `AnimiApp/Sources/Export/AudioWriterPump.swift:9-177` — composition-reader → writer pump (export). Reference only.

### 1.5 Canonical foundation already built — reuse inputs (READY)
- `AnimiEngineNext/Sources/AnimiEngineCore/Audio/AudioPlan.swift` — `AudioPlan` / `AudioSegmentPlan` (destination 48 kHz sample interval, audible source window, gain/mute, `sourceSampleRate`, `channelLayout`, `streamIdentity`, `sceneID`). **This is the realtime adapter's input.**
- `AnimiEngineNext/.../Audio/ResolvedAudioSourceDescriptor.swift` — `AudioStreamIdentity`, `AudioChannelLayoutDescriptor`, source rate/duration.
- `AnimiEngineNext/.../Audio/AudioEvaluator.swift` + `AudioEvaluationWindowBuilder.swift` — pure window→plan (reused verbatim).
- `AnimiEngineNext/.../Evaluator/SceneMediaClock.swift` — shared `sceneMediaTime` (audio inherits video mapping).
- `AnimiEngineNext/Sources/AnimiEngineCore/Runtime/` — `EngineScheduler`, `TransportReducer`/`TransportState`/`TransportCommand`, `MasterClock`(+`Kind`)/`MasterClockSelector`, `AudioRangeAdmission`/`DecodedAudioRangeDescriptor`, `BoundedQueue`, `PublicationGate`, `SchedulerDiagnostics`, identities. **The control core Slice 004 drives.**
- Baseline test gate: `cd AnimiEngineNext && swift test --filter AnimiEngineCoreTests` → **493 tests, 1 skipped, 0 failures** (re-run 2026-06-25).

---

## 2. Reuse / delete / do-not-port matrix

| Item | Verdict | Why |
|---|---|---|
| `AudioPlan` / `AudioSegmentPlan` (Slice 2) | **REUSE verbatim** | Canonical realtime + export input. |
| `AudioEvaluator` / `AudioEvaluationWindowBuilder` (Slice 2) | **REUSE verbatim** | Pure plan production; not modified. |
| `SceneMediaClock` (Slice 2) | **REUSE verbatim** | Shared video/audio mapping. |
| `EngineScheduler` + transport reducer/state/commands (Slice 3) | **REUSE; extend by injection only** | Slice 004 supplies the realtime `MasterClock` impl + audio-range producers, never edits the reducer. |
| `MasterClock` protocol + `MasterClockKind` + `MasterClockSelector` (Slice 3) | **REUSE; ADD conforming impls** | Add `AudioSampleMasterClock` + `MonotonicHostMasterClock` as NEW Runtime/Realtime types; do NOT change the protocol. |
| `AudioRangeAdmission` / `DecodedAudioRangeDescriptor` / `BoundedQueue` (Slice 3) | **REUSE verbatim** | Admission + bounded streaming already specified. |
| `EnginePreviewAudioPlaybackController` (whole-project CAF render) | **DO NOT PORT → delete at cutover** | ADR-012 §5 forbids whole-project temp-file pre-render; roadmap §9 deletion scope. |
| 44.1 kHz `renderSampleRate` | **DO NOT PORT** | Canonical mix 48 kHz (ADR-012 §4). |
| `AVMutableComposition` preview/export source-of-truth | **DO NOT PORT** | Migration input only (ADR-012 migration note). |
| `applyTransitionRamps()` | **DO NOT PORT** | ADR-012 §2 — no implicit transition automation. |
| `loopToFit` | **DO NOT PORT** | ADR-012 §1 — `.once` only. |
| Per-layer/per-provider `lastGood` (video) | **DO NOT PORT** | ADR-005 §6 / ADR-006 §6 temporal-fallback ban. |
| CADisplayLink-as-master | **DO NOT PORT for audio epochs** | ADR-006 §3 — audio render clock is master when unmuted audio exists. (Monotonic host clock remains master for no-audio epochs.) |
| `newDeviceAvailable` reprepare+restart | **DO NOT PORT (pending OD-1)** | ADR-006 §11 — no auto-resume. |
| `AudioWriterPump` / `AudioExportPlan` | **OUT OF SCOPE (Slice 5 export)** | Slice 004 is preview-only; export stays Slice 5. |

---

## 3. Stage plan (Slice 004 — realtime preview audio + audio-master)

> **All stages build inside `AnimiEngineNext` only** until a later product-integration gate (roadmap §1). No `AnimiApp` import. Realtime types may import AVFoundation/AVFAudio **only** behind the new `Realtime/` adapter boundary (see §5); the pure `Audio/`, `Evaluator/`, and existing `Runtime/` files stay AVFoundation-free (enforced by the existing `RuntimeNoFloatNoAVTests` sweep + a new equivalent `Audio/` sweep).

> **Hard precondition:** Stages A–H below are **not authorized to begin** until **B1 (D-213)** and **B2 (Slice 3.5 corpus)** are closed and committed. Stages are written so they are ready the moment the blockers clear.

| Stage | Goal | New production files (proposed) | New test files (proposed) |
|---|---|---|---|
| **A** | **Device-format & session adapter boundary (protocol only, no realtime yet).** Define the injected `AudioSessionAdapter` (activate/deactivate, query *actual* route + output format/sample rate **after** activation) and `AudioOutputFormat` value type. App owns the real session; engine consumes the adapter (ADR-006 §3, ADR-012 §5 last ¶). | `Realtime/AudioSessionAdapter.swift`, `Realtime/AudioOutputFormat.swift` | `AudioSessionAdapterContractTests` |
| **B** | **Audio-sample master clock.** `AudioSampleMasterClock: MasterClock` deriving `ProjectTime` from sample time anchored to the epoch project start, using the existing exact 5-ticks/sample mapping (ADR-006 §3/§4). `MonotonicHostMasterClock` for no-audio epochs. Pure mapping math is integer-only and unit-testable WITHOUT a device. | `Realtime/AudioSampleMasterClock.swift`, `Realtime/MonotonicHostMasterClock.swift`, `Realtime/SampleTimeMapping.swift` | `SampleTimeMappingTests`, `AudioMasterClockTests` |
| **C** | **Bounded PCM preparation model (no realtime callback yet).** A `PreparedAudioBuffer` immutable value + `AudioChunkPreparer` contract that turns `AudioSegmentPlan` ranges into bounded prepared chunks carrying the ADR-005 §8 identity tuple (revision/epoch/`AudioRequestID`/`AudioSourceID`/sample range). Decode/convert are injected; no whole-project render. | `Realtime/PreparedAudioBuffer.swift`, `Realtime/AudioChunkPreparer.swift` | `AudioChunkPreparationTests` |
| **D** | **Deterministic output-overload stage (D-213).** Implement the **accepted** D-213 stage (hard saturation vs fixed limiter — per B1) as a pure, versioned, deterministic function identical for preview+export (ADR-012 §4). Gated on B1. | `Realtime/OutputOverloadStage.swift` | `OutputOverloadStageTests` |
| **E** | **Realtime preview graph adapter.** Engine-owned `AVAudioEngine` graph (`AVAudioPlayerNode`/mixer/format converters) streaming bounded prepared chunks; one scheduler-controlled anchor; realtime-safe callback (no I/O/alloc/lock/log); immutable callback-visible state published outside the callback (ADR-012 §5, ADR-006 §8). **This is the AVFoundation boundary.** | `Realtime/PreviewAudioGraph.swift`, `Realtime/RealtimeSafeState.swift` | `PreviewAudioGraphContractTests` (graph wiring/format/anchor; realtime-callback purity asserted structurally) |
| **F** | **Playback start barrier + audio-master wiring.** Connect the graph + master clock to `EngineScheduler` per ADR-006 §5: resolve common anchor, prepare first complete frame + bounded preroll, schedule audio at the anchor, publish initial frame, start the master clock, enter `playing`. Audio must not become audible before the first video frame resolves. | `Realtime/PlaybackStartBarrier.swift`, `Realtime/AudioMasterPreviewSession.swift` | `PlaybackStartBarrierTests` |
| **G** | **Interruption / route-change pause-only.** Wire `AudioSessionAdapter` events → `EngineScheduler.accept(.interrupt/.routeChange)` → capture last confirmed time, invalidate epoch, flush realtime buffers, re-query route/format, **remain paused** (ADR-006 §11, ADR-012 §7). Implements OD-1 default (pause-only on every relevant route change incl. `newDeviceAvailable`). | (extends `AudioMasterPreviewSession`) | `InterruptionRouteChangePauseOnlyTests` |
| **H** | **Silent-scrub guarantee + report.** Assert scrub schedules **no** audio (ADR-006 §7, ADR-012 §6): the scrub path never calls the preparer/graph; settle leaves transport paused; preroll only on explicit play. Closure report + cross-stage evidence. | (no new prod; guard wiring) | `SilentScrubAudioTests`; `slice-004-implementation-report.md` |

`Realtime/` is a **new directory** under `Sources/AnimiEngineCore/` (the AVFoundation boundary). Existing `Runtime/`, `Audio/`, `Evaluator/`, `Project/` files are **not modified** by Slice 004 (only added to via new conforming types injected through existing protocols).

---

## 4. Test matrix (what proves each contract — simulator/unit vs device)

| Contract (ADR ref) | Test (sim/unit) | Device-only? |
|---|---|---|
| Exact tick↔sample↔frame mapping, non-frame-aligned seek (006 §4) | `SampleTimeMappingTests` (integer math, no device) | No |
| Audio-master derives ProjectTime from sample time (006 §3) | `AudioMasterClockTests` (injected sample counter) | No (math); **device for real A/V sync** |
| No-audio epoch → monotonic host master (006 §3) | `AudioMasterClockTests` | No |
| Bounded PCM chunk prep, no whole-project render (012 §5) | `AudioChunkPreparationTests` | No |
| D-213 output stage deterministic + preview/export-identical (012 §4) | `OutputOverloadStageTests` (PCM probe vectors) | No (determinism); device for audible quality |
| Realtime callback purity: no I/O/alloc/lock/log (006 §8, 012 §5) | `PreviewAudioGraphContractTests` (structural) | **Device** for true underrun/starvation |
| Playback start barrier: audio silent until 1st frame; bounded timeout (006 §5) | `PlaybackStartBarrierTests` (injected clock + fake graph) | No |
| Pause-only on interruption/route/new-device; no auto-resume (006 §11, 012 §7) | `InterruptionRouteChangePauseOnlyTests` (injected session events) | **Device** to confirm real route events |
| Silent scrub: no audio scheduled, settle paused (006 §7, 012 §6) | `SilentScrubAudioTests` | No |
| Old-epoch PCM never reaches buffer after seek/interruption (005 §8) | reuse Slice-3 `AudioAdmissionTests` + new flush test | **Device** for hardware-boundary recall semantics |
| 6/10/20-video-with-music bounded memory/queue (006 §9, 012 verification) | bounded-queue unit tests (counts) | **Device** for real memory/thermal |

Whole-suite gate per stage: `cd AnimiEngineNext && swift test --filter AnimiEngineCoreTests` stays green; render parity gate (`PostPromotionMatrixRegressionTests`, 84/84) re-run only if any render-adjacent file is touched (none expected).

---

## 5. AVFoundation boundary

- **Only** the new `Sources/AnimiEngineCore/Realtime/` directory may `import AVFoundation`/`import AVFAudio`. It owns: `AVAudioEngine`, `AVAudioPlayerNode`, format converters, the realtime callback, `AVAudioTime` sample-time reads, and the `AudioSessionAdapter` impl seam.
- `Audio/`, `Evaluator/`, `Runtime/`, `Project/` stay AVFoundation-free and Float/Double-free — enforced by the existing `RuntimeNoFloatNoAVTests` sweep (`Runtime/*.swift`) and the Slice-2 `Audio/*.swift` sweep; **add an equivalent guard test asserting `Realtime/` is the *only* AV-importing directory** and that canonical identity/time/gain inside it still never uses Float/Double for *canonical* values (Float32 allowed strictly at the DSP/processing boundary per ADR-012 §1, §4).
- The **app** owns `AVAudioSession` activation/category/mode lifecycle and passes it to the engine via `AudioSessionAdapter` (ADR-012 §5 last ¶). The engine never sets the app's session category directly.

### How audio master clock links to the Runtime scheduler
`AudioSampleMasterClock` conforms to the existing `MasterClock` protocol (`MasterClock.swift`). `MasterClockSelector.select(window:remaining:)` (Slice 3) already chooses `.audioSample` when the remaining range has unmuted audio, else `.monotonicHost`. Slice 004 supplies the conforming clock; `EngineScheduler` consumes `currentProjectTime()` exactly as today — **no scheduler edit**. The clock is selected once per epoch and frozen (ADR-006 §3).

### How `AudioPlan` becomes engine scheduling
`AudioEvaluator` (pure) → `AudioPlan` → `AudioChunkPreparer` cuts bounded `PreparedAudioBuffer`s per `AudioSegmentPlan`, each tagged with the ADR-005 §8 identity tuple → `DecodedAudioRangeDescriptor` admitted via existing `AudioRangeAdmission` into the existing bounded `audioRangeQueue` on `EngineScheduler` → `PreviewAudioGraph` consumes only admitted, prepared buffers at the scheduler anchor. A discontinuity flushes old-epoch ranges (already implemented in `EngineScheduler.accept`).

### Route/interruption → pause-only
`AudioSessionAdapter` route/interruption callback → `EngineScheduler.accept(.interrupt(at:))` / `.routeChange` (existing commands) → reducer mints fresh epoch, emits `stopAcceptingEpoch`/`cancelQueued`/`flushUnrenderedAudio`/`activateEpoch`, lands in a held state → graph stops; **no restart is issued** (OD-1 default). User `play()` starts a fresh preparation barrier + epoch.

### No loop / `.once`
Guaranteed upstream: `AudioEvaluator` already stops each segment at the first end (trim/`.once`), so no segment can request audio past its authored/source end; the realtime graph schedules only the prepared segments and never re-schedules a finished one.

---

## 6. Device evidence matrix

| Evidence | Metric / pass condition | Sim/unit possible? | Device required |
|---|---|---|---|
| A/V sync | measured audio-vs-video offset within tolerance across a play session | Partial (math only) | **Yes** |
| Audio underruns / starvation | underrun count == 0 under nominal load; bounded under stress | No | **Yes** |
| Frame pacing under audio-master | global cadence stable; no per-layer drift | No | **Yes** |
| 6-video preview **with audio** | smooth playback, one synchronized composition, audio mixed | No | **Yes** (also 10/20 in Slice 6) |
| Mute / gain | per-source mute silences only that source; gain scales only that source | Partial (plan-level) | **Yes** (audible) |
| Music once / no-loop | music stops at authored/source end; never repeats | Partial (plan-level) | **Yes** (audible) |
| Route change (headphones/BT connect+disconnect) | every relevant route change → **pause**, no auto-resume, no restart on new device (OD-1) | No (injected only) | **Yes** |
| Interruption (call/Siri) | pause + epoch invalidate; resume only on explicit play | No | **Yes** |
| No whole-project temp CAF | no 44.1k temp file written; bounded streaming only | Structural (assert no file render) | **Yes** (confirm at runtime) |
| Bounded memory / queues | memory + queue depth bounded under 6/10/20 sources | Counts only | **Yes** (real memory/thermal) |

**Build/run target for device evidence:** AnimiApp.xcodeproj, scheme AnimiApp, physical iPhone 13 Pro (per project device history). Device gate is a Slice-004 close condition; 10/20-video matrix extends into Slice 6.

---

## 7. Forbidden-path list (must NOT be touched by Slice 004 implementation)

- `AnimiApp/` (no production change until the product-integration gate; reference only).
- `Package.swift`, any `*.xcodeproj`, `AnimiApp.xcscheme`.
- `ReferenceData/` and pixel goldens.
- `AnimiEngineMetalRender/`, `AnimiEngineRenderModel/`, RenderGraph (no render-path change).
- Existing `Sources/AnimiEngineCore/Audio/*` , `Evaluator/*`, `Project/*`, and `Runtime/*` files (extend via NEW `Realtime/` types injected through existing protocols; do not edit `AudioEvaluator`/`AudioEvaluationWindowBuilder`/`TimelineEvaluator`/`AudioEvaluator`/`ProjectValidator`/`EngineScheduler`/`TransportReducer`).
- Export path (`AudioCompositionBuilder`, `AudioExportPlan`, `AudioWriterPump`) — Slice 5.
- Pre-existing dirty/deleted working-tree entries from prior sessions (`AnimiApp.xcscheme`, `6_frames_template/`, ADR-002/003/004 edits, `architecture-proposal.md`, `validation-contract.md`, deleted `.agents/`/`Docs/agents/`/`Scripts/`/`AGENTS.md`/`CLAUDE.md`, `.docx`, `deep-research*`, `SceneSources/`, `audits/`) — never staged by this work.
- No `loopToFit`, no `applyTransitionRamps`/implicit ramps, no per-layer `lastGood`, no whole-project CAF, no CADisplayLink-as-master for audio epochs, no auto-resume.
- No `Float`/`Double`/`Decimal` for canonical identity/time/gain anywhere (Float32 allowed strictly at the `Realtime/` DSP boundary).

---

## 8. STOP conditions

1. **STOP if B1 (D-213) is not closed/accepted** — do not start Stage D (or any output-stage code); the stage algorithm must be the *accepted* one and identical for preview/export.
2. **STOP if B2 (Slice 3.5 corpus) is not committed** — no device/runtime gate may run without the deterministic, legally-safe fixtures.
3. **STOP before any `AnimiApp` production edit** — Slice 004 builds in `AnimiEngineNext` only; product integration is a later gate (roadmap §9).
4. **STOP before staging/committing** — explicit owner authorization required, exactly as Slices 001–003.
5. **STOP on OD-1 if owner wants restart-on-new-device** — that contradicts the accepted ADR; needs an explicit ADR amendment before implementing anything other than pause-only.
6. **STOP if any realtime callback would do I/O / allocation / locking / logging / graph mutation** — ADR-006 §8 / ADR-012 §5 are hard.
7. **STOP if the scheduler core, pure evaluators, or render path would need editing** — that signals a boundary violation; re-design via injection instead.
8. **STOP if the whole-suite gate (`AnimiEngineCoreTests`) goes red** — do not advance a stage on a red gate (roadmap §1).

---

## 9. Explicit confirmation — nothing changed

- **No production code written.** No file under `Sources/` was created or modified.
- **No tests written or modified.**
- **No staging, no commit, no push.** This preflight produces exactly one new file: `Docs/AnimiEngineNext/slice-004-implementation-plan.md`.
- Baseline re-run for evidence only (built into `/tmp`): `cd AnimiEngineNext && swift test --build-path /tmp/animi-slice004-preflight --filter AnimiEngineCoreTests` → **493 tests, 1 skipped, 0 failures**.
- `git diff --cached --name-only` empty (index untouched).
