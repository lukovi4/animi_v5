# Slice 005 — App ↔ Slice-004 Realtime Audio Integration (PREFLIGHT PLAN)

**Readiness verdict: READY WITH CONDITIONS.**
The canonical Slice-004 realtime-audio layer can be wired into AnimiApp without
changing export semantics, because the app already builds the canonical **VIDEO**
model (`CanonicalProjectManifest` + `EvaluationWindowRequirement` + scene payloads)
for the Next video preview, and the canonical **audio** evaluator reuses that same
manifest/requirement/scene model.

**Critical caveat (corrected):** the app builds the canonical *video* model only — it
does **NOT** build a canonical **AUDIO manifest**. Both `CanonicalProjectManifest(...)`
calls in `NextTimelineBridge.swift` (`:200`, `:286`) omit the `audio:` argument, so
`manifest.audio == AudioManifest.empty` (default; `CanonicalProjectManifest.swift:33`).
With an empty audio manifest the `AudioEvaluator` receives **zero clips** and produces a
silent `AudioPlan`. Therefore the new domain bridge is **NOT** just a descriptor
resolver: Slice 005 requires an **app→canonical `AudioManifest` builder** that populates
`sources/tracks/clips` from the app audio model, **plus** a
`ResolvedAudioSourceDescriptor` resolver. Everything else is adapter + lifecycle glue.

**This is a preflight. NO production code, NO tests changed. Nothing staged/committed/pushed.**
HEAD under analysis: `13ec15abf83dad5d8ac5b2566e9448eea39241e6`.

---

## 0. Preconditions captured (read-only)

- `git diff --cached --name-only` → **empty**.
- `git status --short` scoped to `AnimiApp/**/*.swift`, `Realtime/`, `Docs/slice-00[45]` → **NONE in scope** (only this new doc will appear).
- App imports `AnimiEngineCore` already (`NextTimelineBridge.swift:5`, Next video bridge).
- App does **not** reference any Slice-004 Realtime symbol
  (`AudioMasterPreviewSession`, `PreviewAudioGraph`, `OutputOverloadStage`,
  `AudioSampleMasterClock`, `RealtimeAudioSessionEvent`) — confirmed by rg.

---

## 1. Exact current preview-audio call graph (legacy path)

App-side audio preview is owned by
`AnimiApp/Sources/EditorRuntime/EditorRuntimePreviewAudioCoordinator.swift`, driving
`EnginePreviewAudioPlaybackController` (`PreviewAudioControlling`).

| Transport event | Entry point | Effect |
|---|---|---|
| **play** | `EditorRuntime.swift:1189` → `previewAudio.startForTimelinePlayback()` | coordinator builds pipeline if dirty (`startBuild`), else resumes; `EnginePreviewAudioPlaybackController.startPlayback(fromSeconds:hostTime:)` (`:186`) |
| **markDirty / rebuild** | `EditorRuntime.swift:1730` → `previewAudio.markDirty()` (`coordinator :42`) | bumps generation; if playing → `startForTimelinePlayback`, else `scheduleIdlePrepare` |
| **build pipeline** | coordinator `buildPipeline()` (`:281`) | `runtime.buildAudioExportPlan` → `AudioCompositionBuilder.buildTimeline(sceneData:transitionMath:fps:plan:)` → `BuiltAudioPipeline{ composition: AVMutableComposition, audioMix: AVAudioMix? }` |
| **render** | `EnginePreviewAudioPlaybackController.renderToFile` (`:363`) | **whole-composition** offline render via `AVAssetReader` → a single temp `.caf`, then `AVAudioFile` + `AVAudioPlayerNode` |
| **pause (warm / scrub.began)** | `EditorRuntime.swift:1209` (inside `stopPlayback()`) → `controller.pausePlaybackImmediately()` (`:314`) | `playerNode.pause()` + `engine.pause()` (no teardown) |
| **pause (teardown/idle)** | `EditorRuntime.swift:1293`, `:1356` → `controller.pause()` (`:327`) | `playerNode.stop()` + `engine.stop()` |
| **scrub / settle** | `EditorTimelineController.handleTimelineScrub(compressedFrame:phase:)` (`:121`); `.began/.changed` → `setScrubInteractionActive(true)` + `stopPlayback()`; `.ended` → `setScrubInteractionActive(false)` | scrub only ever reaches audio via `stopPlayback()` → `pausePlaybackImmediately()`. **No scrub/settle path calls `startPlayback`/`startForTimelinePlayback`.** |
| **route change** | `EditorRuntime.handleAudioSessionEvent(_:)` (`:1381`) over app `AudioSessionEvent` (`AudioSessionManager.swift:8`) | `oldDeviceUnavailable` → `stopPlayback()` (`:1397`, pause-only ✔). **`newDeviceAvailable` → `controller.reprepareForRouteChange()` + `startForTimelinePlayback()` (`:1406-1407`) — LEGACY AUTO-RESTART ✘** |
| **interruption** | `:1383-1387` | `interruptionBegan` → `abortPlaybackStartupAndStop`; `interruptionEnded` → no-op (pause-only ✔) |
| **media services reset** | `:1409-1414` | abort + `previewAudio.invalidateForMediaServicesReset()` (`coordinator :83`) |

Scrub events originate in `AnimiApp/Sources/Editor/TimelineView.swift:775/758/803`
(`.began/.changed/.ended`).

---

## 2. Where the legacy path violates canonical Slice 004

| # | Canonical rule | Legacy violation | Evidence |
|---|---|---|---|
| V1 | Audio-**sample** master clock (ADR-006 §3) | **Host-time** master: `makePlaybackTiming` anchors to `CACurrentMediaTime()` / `AVAudioTime.hostTime(forSeconds:)` | `EnginePreviewAudioPlaybackController.swift:500-526, 224-240` |
| V2 | Bounded chunk scheduling, no whole-project buffering (ADR-005 §8, ADR-006 §9) | **Whole-composition** offline render to one temp `.caf` of the entire project | `:363-429 renderToFile`, `:99 renderTask` |
| V3 | Route/new-device = **pause-only**, never auto-resume/restart (ADR-006 §11, ADR-012 §7) | `newDeviceAvailable` rebuilds engine + restarts playback | `EditorRuntime.swift:1406-1407`; `reprepareForRouteChange` `:281-305` |
| V4 | Silent scrub (ADR-006 §7, ADR-012 §6) | **Not a real risk today** — scrub only pauses; but the legacy controller has no positive *silent-scrub guard* of its own (relies on call-site discipline) | `EditorTimelineController.swift:121-151` (no audio start on scrub) |
| V5 | Music never loops; no implicit ramp/extension (ADR-012 §1) | `loopToFit` flag exists but is **never consumed** (no loop today ✔; canonical model has no loop case — `AudioPlaybackPolicy.once` only); video-slot transition volume **ramps** exist (`setVolumeRamp` `:407/:416`) — the canonical graph applies only **static** per-segment gain/mute, so ramps **cannot be reproduced as-is** and are an **OPEN decision** (see blocker 2) | `AudioExportPlan.swift:14`; `AudioCompositionBuilder.swift:356,374-416`; `AudioManifest.swift:24` |
| V6 | Post-mix `OutputOverloadStage` (D-213 Candidate A) (ADR-012 §4) | No output-overload stage; raw sum into `mainMixerNode` | `EnginePreviewAudioPlaybackController.swift:165-168` |
| V7 | "audio always mixes" / single mixed mono output (ADR-012 §2) | Whole-project AVComposition + AVAudioMix, multi-track, not the canonical sum→stage→one-buffer | `AudioCompositionBuilder.buildTimeline` |

Note: export uses the **same** `AudioCompositionBuilder`/`AVAssetReader` path; the
integration must **leave export untouched** and introduce the canonical path for
**preview only** behind a toggle (see §3.7, Stage A).

---

## 3. Minimal integration seam (canonical, preview-only)

All canonical types are `public` in `AnimiEngineCore` and the app already links it.
The seam reuses what the **Next video** bridge already builds.

### 3.1 Canonical data — buildable, but the AUDIO manifest must be NEWLY POPULATED
`AudioEvaluator.evaluate(window:) -> AudioPlan` (`Audio/AudioEvaluator.swift:13`)
consumes `AudioEvaluationWindow`, produced by
`AudioEvaluationWindowBuilder.build(manifest:requirement:scenes:sourceDescriptors:)`
(`Audio/AudioEvaluationWindowBuilder.swift:13`), which reads `manifest.audio`
(`AudioEvaluationWindowBuilder.swift:19`). Of those four inputs:

- `CanonicalProjectManifest` — built by the app for video
  (`NextTimelineBridge.swift:200, 286`), **but with `audio:` omitted → `manifest.audio
  == AudioManifest.empty`** (`CanonicalProjectManifest.swift:33`,
  `AudioManifest.swift:127`). **An empty audio manifest yields zero clips and a silent
  plan.** This is the corrected critical fact — the existing manifest is NOT reusable
  as-is for audio; a populated `AudioManifest` must be constructed.
- `EvaluationWindowRequirement` — **already built** (`NextTimelineBridge.swift:435-436`),
  reusable.
- `[ResolvedScenePayload]` — **already built** (`document.scenePayloads`), reusable.
- `[ResolvedAudioSourceDescriptor]` — **NEW** (`Audio/ResolvedAudioSourceDescriptor.swift:50`);
  the app builds only *video* descriptors today. Built from the asset probe (see 3.1b).

**The new domain bridge = an `AudioManifest` builder + a `ResolvedAudioSourceDescriptor`
resolver** — NOT a descriptor resolver alone. Both are required before the evaluator
returns any audible segment.

#### 3.1a `AppAudioManifestBridge` — populate `AudioManifest` from the app audio model
Build a populated `AudioManifest(sources:tracks:clips:)` (`AudioManifest.swift:114`) from
the app timeline audio:
- **Inputs:** the timeline's audio items (`TimelineItemPayload.audio(AudioPayload)`,
  `Project/TimelinePayload.swift:38`) and their carrier `CanonicalTimeline.TimelineItem`
  (`startUs: TimeUs?`, `durationUs: TimeUs` — `Project/CanonicalTimeline.swift:184,187`);
  `AudioPayload` fields `assetRef, trimStartUs, trimEndUs, volume, role`
  (`TimelinePayload.swift:96`). For preview parity with the legacy path, also include
  video-layer original audio when `includeOriginalFromVideoSlots == true`
  (`EditorRuntime.buildAudioExportPlan`).
- **Per-clip mapping (exact):**
  - `destination` = `ProjectTimeRange` from `[item.startUs, item.startUs + item.durationUs)` via a
    **deterministic outward projection** onto the 240 kHz tick grid — `startTick =
    floor(startUs·240000/1e6)`, `endTick = ceil(endUs·240000/1e6)` (integer-only, reduced 6/25 factor).
    App `TimeUs` is an arbitrary `Int64` (import/trim derive it through `Double`), so **no exact 25 µs
    alignment is assumed**; the interval is covered outward, never rejected for non-alignment and never
    silently clamped. Widening is **bounded < 1 canonical tick per boundary** (≈ 4.17 µs). Still
    fail-closed on negative start, non-positive duration, overflow, or a degenerate final range.
  - `sourceTrim` = `RationalSourceRange` from `trimStartUs … trimEndUs`.
  - `gain` = `AudioGain` from `volume` **with fail-closed validation**: a finite app
    `volume` in `0.0...1.0` maps exactly onto the integer scale `0...1_000_000`
    (`AudioGain.unityRaw`); an out-of-range (`< 0` / `> 1`) or non-finite (NaN/Inf)
    `volume` is a **typed failure** — `AudioGain` must never carry an invalid value
    (`AudioGain.init(raw:)` itself rejects out-of-range, never clamps; the bridge must
    not feed it an invalid raw). **No clamp anywhere** — reject, not carry-invalid.
  - `playbackPolicy` = `.once` (the only v1 case; `AudioManifest.swift:24`). **No `loopToFit`.**
  - `isMuted` carried from the app model (muted clips kept, not dropped — lead decision).
  - global audio (music/voiceover/SFX) → `asset = .globalAudio(GlobalAudioAssetID)`
    (`AudioManifest.swift:33`); role → `AudioSourceRole.music/.voiceover/.soundEffect`.
  - video-layer original audio → `asset = .videoLayerMedia(MediaReference)`
    (`AudioManifest.swift:31`) + `videoLayer = SceneLayerReference(sceneID:layerID:)`
    (`AudioManifest.swift:39`); role = `.videoLayer`.
- **Tables:** one `AudioTrackEntry(id:role:)` per role-track; one `AudioSourceEntry(id:asset:)`
  per distinct source; clips reference both by id.
- **Empty audio → `AudioManifest.empty`** (legitimate silence, not an error).

#### 3.1b `AppAudioSourceDescriptorResolver` — `[ResolvedAudioSourceDescriptor]`
For **each** `AudioSourceID` referenced by a clip, resolve **exactly one**
`ResolvedAudioSourceDescriptor` (`ResolvedAudioSourceDescriptor.swift:50`) via a real asset
probe: `sampleRate` (`Int64`), `channelLayout`, `streamIdentity` from the decoded asset.
**0 descriptors or >1 per source → typed failure** (matches the evaluator's
"exactly one descriptor per referenced source" contract,
`AudioEvaluationWindowBuilder.swift:64-72`).

→ Bridge is feasible by reusing the existing requirement + scene payloads **and adding both
new builders (manifest + descriptors)**. This is the corrected feasibility basis for the
READY-WITH-CONDITIONS verdict.

### 3.2 `AudioSessionAdapter` (app implementation)
Protocol = three methods (`Realtime/AudioSessionAdapter.swift:28-38`):
`activate()`, `deactivate()`, `queryActualOutput() -> AudioOutputQuery`. Implement
over `AVAudioSession.sharedInstance()` (activate category/mode; map current route +
output format to `AudioOutputQuery{ AudioOutputFormat, AudioOutputRoute }`). Must
**query after activation** (fail-closed `queryBeforeActivation`).

### 3.3 `AudioChunkPreparer` (app implementation) — PCM bridge
Conform to `Realtime/AudioChunkPreparer.swift:79` `prepare(_ request:) throws ->
PreparedAudioBuffer`. Given an `AudioSegmentPlan` + bounded `chunkRange`, decode the
referenced source (AVAssetReader on the clip's asset, **per-segment**, hold-last like
the Next video resolver), convert to 48 kHz, return `PreparedAudioBuffer` metadata
referencing an opaque payload handle; the actual `[Float32]` is carried into the
`PreviewMixSource` for `scheduleMix`. Must use `AudioChunkBounds.validate` and fail
closed. **No whole-project render, no temp file, no loop.** (Replaces V2.)

### 3.4 `PreviewAudioGraph` ownership lifecycle
Construct one `PreviewAudioGraph(session:sink:epoch:revision:maxChunkSamples:)`
(`PreviewAudioGraph.swift:173`) per preview epoch, with:
- `session` = the app `AudioSessionAdapter` (3.2),
- `sink` = the **already-shipped** `AVAudioEnginePreviewSink`
  (`PreviewAudioGraph.swift:314`) — no new AV sink needed,
- `maxChunkSamples` = injected runtime config (OD-2; pick at device gate).
Owned by a new app coordinator (replacing the controller role). Output stage is
post-mix inside `scheduleMix` (V6 resolved for free).

### 3.5 `AudioMasterPreviewSession` lifecycle
Per play epoch construct `AudioMasterPreviewSession(revision:epoch:graph:selectedClock:
timeoutTicks:startTick:)` (`AudioMasterPreviewSession.swift:155`). Sequence per ADR-006 §5:
`configureOutput()` → `configureAnchor(_:)` (anchor minted for this epoch) →
`markFirstFrameReady()` (driven by the first **video** frame from the existing display
link / Next preview) → `scheduleInitialAudioPreroll(_:against:)` (only on explicit
play) → `start()`. `selectedClock = .audioSample` (`AudioSampleMasterClock`) for
audio-bearing; `.monotonicHost` otherwise. (Resolves V1, V4, V7.)

### 3.6 Route/interruption → `RealtimeAudioSessionEvent` mapping
App `AudioSessionEvent` (`AudioSessionManager.swift:8`) maps 1:1:
`interruptionBegan → .interruptionBegan`; `interruptionEnded(_) → .interruptionEnded`
(no resume); `routeChanged(oldDeviceUnavailable) → .routeChanged(.oldDeviceUnavailable)`;
`routeChanged(newDeviceAvailable) → .newDeviceAvailable` (**pause-only — delete the
legacy reprepare+restart at `EditorRuntime.swift:1406-1407`**); `mediaServicesReset`
→ invalidate. All call `session.handleSessionEvent(_:)`; next audible play requires a
new epoch. (Resolves V3.)

### 3.7 Debug toggle vs default path
Gate the canonical preview path behind a DEBUG/launch flag (mirror existing
`DebugExportWithNextEngine` style). Default = legacy path until the device gate
passes. The `PreviewAudioControlling` protocol stays; add a second conforming
coordinator (canonical) selected by the toggle, so **export and the legacy preview
are byte-for-byte unchanged**.

---

## 4. Exact files to MODIFY (production — only after approval)

1. `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift`
   - `handleAudioSessionEvent` (`:1381`): route `newDeviceAvailable` to pause-only;
     forward events to the canonical session (behind toggle).
   - play/pause/stop sites (`:1189, :1209, :1293, :1356`): branch to canonical
     coordinator when the toggle is on.
2. `AnimiApp/Sources/EditorRuntime/EditorRuntimePreviewAudioCoordinator.swift`
   - Select canonical vs legacy controller by toggle; wire markDirty→new-epoch.
3. `AnimiApp/Sources/EditorRuntime/PreviewAudioControlling.swift`
   - (Possibly) extend protocol minimally for first-frame-ready / explicit-play
     signalling — only if the canonical coordinator cannot fit the current shape.
4. `AnimiApp/project.yml` / xcodegen (add new files to the AnimiApp target).
   *(No `.xcodeproj` hand-edit; regenerate.)*

**Export files (`AudioCompositionBuilder.swift`, export controllers) — NOT modified.**

## 5. Exact files/tests to ADD

Production (app target):
- `AnimiApp/Sources/EditorRuntime/Realtime/AppAudioManifestBridge.swift` — **NEW (critical)**: builds a populated `AudioManifest` from app timeline audio items / `AudioPayload` (§3.1a).
- `AnimiApp/Sources/EditorRuntime/Realtime/AppAudioSourceDescriptorResolver.swift` — **NEW**: builds `[ResolvedAudioSourceDescriptor]` via asset probe, exactly-one-per-source (§3.1b).
- `AnimiApp/Sources/EditorRuntime/Realtime/AppAudioSessionAdapter.swift` — `AudioSessionAdapter` over `AVAudioSession`.
- `AnimiApp/Sources/EditorRuntime/Realtime/AppAudioChunkPreparer.swift` — `AudioChunkPreparer` (per-segment AVAssetReader → 48 kHz PCM, hold-last).
- `AnimiApp/Sources/EditorRuntime/Realtime/AppAudioEvaluationBridge.swift` — assembles `AudioEvaluationWindow` from the populated manifest + reused requirement/scene payloads + resolved descriptors, runs `AudioEvaluator`, maps `AudioSegmentPlan` → `PreviewMixSource`.
- `AnimiApp/Sources/EditorRuntime/Realtime/CanonicalPreviewAudioController.swift` — `PreviewAudioControlling`-shaped coordinator owning `PreviewAudioGraph` + `AudioMasterPreviewSession` + `AVAudioEnginePreviewSink`.
- `AnimiApp/Sources/EditorRuntime/Realtime/RealtimeAudioSessionEventMapping.swift` — app `AudioSessionEvent` → `RealtimeAudioSessionEvent`.

Tests (app target):
- `AnimiApp/Tests/AppAudioManifestBridgeTests.swift` — **NEW**: populated manifest from app audio tracks; empty audio → `.empty` (silent); global-audio clip round-trips into a non-empty `AudioPlan`; exact `destination`/`sourceTrim`/`gain` mapping; no `loopToFit`; video-layer original-audio mapping when included.
- `AnimiApp/Tests/AppAudioSourceDescriptorResolverTests.swift` — **NEW**: exactly-one descriptor per source; 0/multiple → typed failure; sampleRate/channelLayout/streamIdentity from probe.
- `AnimiApp/Tests/AppAudioSessionAdapterTests.swift` — activate-before-query, fail-closed.
- `AnimiApp/Tests/AppAudioChunkPreparerTests.swift` — boundedness, no whole-project, hold-last, 48 kHz.
- `AnimiApp/Tests/AppAudioEvaluationBridgeTests.swift` — window assembly from populated manifest; plan equivalence vs evaluator; gain/mute carried.
- `AnimiApp/Tests/CanonicalPreviewAudioControllerTests.swift` — start barrier order, silent scrub, route pause-only mapping, explicit-play preroll.
- `AnimiApp/Tests/RealtimeAudioSessionEventMappingTests.swift` — 1:1 mapping incl. `newDeviceAvailable` → pause-only.

**No Slice-004 engine source or test is modified** (the Realtime sweep must stay green;
new app files live in the app target, not under `Realtime/`).

---

## 6. Implementation stages

- **A — App adapter/protocol bridge.** `AppAudioManifestBridge` (populate `AudioManifest` from app audio — the corrected critical piece), `AppAudioSourceDescriptorResolver` (`[ResolvedAudioSourceDescriptor]`, exactly-one), `AppAudioSessionAdapter`; then `AppAudioChunkPreparer`, `AppAudioEvaluationBridge`, event mapping. DEBUG toggle scaffold. Export/legacy untouched. *Exit:* unit tests green; a **non-empty** canonical `AudioPlan` reproducible from app audio tracks (and empty-audio → silent), proving the empty-`manifest.audio` omission is fixed.
- **B — Canonical preview-audio pipeline construction.** `CanonicalPreviewAudioController` owning graph + session + `AVAudioEnginePreviewSink`; bounded chunk scheduling via `scheduleMix`. *Exit:* one bounded mixed buffer reaches the sink; no temp file; post-mix output stage applied.
- **C — Lifecycle integration play/pause/scrub.** Branch `EditorRuntime` play/pause/stop to the canonical controller behind the toggle; first-frame-ready from the Next video frame; explicit-play preroll only. *Exit:* play starts audio after first frame; scrub silent; pause warm.
- **D — Route/interruption pause-only.** Map app `AudioSessionEvent`; **remove legacy `newDeviceAvailable` restart**; every event → invalidate + paused + explicit play. *Exit:* no auto-resume anywhere on the canonical path.
- **E — Device evidence rerun.** Re-run the Slice-004 device gate (`slice-004-device-evidence.md` matrix) with the toggle ON so Slice-004 actually executes on device.

---

## 7. STOP conditions — current status

| STOP condition | Status |
|---|---|
| Canonical data cannot be built from app model | ✅ **Cleared, but with a substantial new build** — requirement + scene payloads are reusable from the video bridge, **however `manifest.audio` is empty today** (`NextTimelineBridge.swift:200,286` omit `audio:`), so the **app must newly build a populated `AudioManifest`** (§3.1a) **and** a `ResolvedAudioSourceDescriptor` resolver (§3.1b). Both are feasible from the app audio model (`AudioPayload` + timeline items), so this is a build task, not a blocker. |
| App target cannot import/use Realtime symbols cleanly | ✅ **Cleared** — app already imports `AnimiEngineCore`; all needed types are `public`; `AVAudioEnginePreviewSink` ships. |
| Integration requires changing **export** semantics | ✅ **Cleared by design** — preview-only behind a toggle; `AudioCompositionBuilder`/export path untouched. **CONDITION:** must hold through Stage A–D. |
| 6-video-with-music not clean-checkout reproducible | ⛔ **OPEN BLOCKER** — `6_frames_template` fixture still untracked (`??`); must be tracked before the device gate item 6 is runnable from a clean clone. |
| Device evidence would still hit legacy path | ⚠️ **OPEN until Stage C/E** — the toggle must default the canonical path ON for the gate rerun; otherwise the device still runs legacy. Tracked as Stage E precondition. |
| Integration needs production-code change | ⚠️ **Expected** — Stages A–D are production changes; **require separate approval** before any edit. This preflight changed nothing. |

### Open blockers summary
1. **Empty canonical audio manifest (CORRECTED — primary build item).** `manifest.audio == .empty` today, so without an `AppAudioManifestBridge` the evaluator returns a silent plan. Slice 005 **must** build a populated `AudioManifest` (§3.1a) **plus** a `ResolvedAudioSourceDescriptor` resolver (§3.1b). Feasible, but it is the central new domain bridge — not a descriptor resolver alone.
2. **Video-slot transition volume ramps NOT yet resolved.** The canonical graph applies only **static** per-segment gain/mute; AVAudioMix ramps at scene transitions (`AudioCompositionBuilder.swift:374-416`) have **no** canonical representation (`AudioPlaybackPolicy.once`, single `AudioGain` per clip). This blocker stays **OPEN** until one of: (a) the ramp is expressed via canonical segments/gain (e.g. split segments approximating the fade), or (b) it is **explicitly rejected as a documented behaviour delta** for preview. Must not be marked solved before that decision is recorded.
3. **`ResolvedAudioSourceDescriptor` resolver** — each `AudioSourceID` → **exactly one** descriptor with real-asset-probed `sampleRate`/`channelLayout`/`streamIdentity`; **0 or multiple → typed failure** (`ResolvedAudioSourceDescriptor.swift:50`; evaluator contract `AudioEvaluationWindowBuilder.swift:64-72`).
4. **`6_frames_template` fixture untracked** — block the device gate (item 6) until committed / made clean-checkout reproducible. *(Separate approval; not in this preflight.)*

---

## 8. Test / device-gate matrix (target after Stages A–E)

| Check | Where | Gate |
|---|---|---|
| `AudioManifest` populated from app audio tracks (non-empty sources/tracks/clips) | `AppAudioManifestBridgeTests` | unit |
| Empty audio model → `AudioManifest.empty` → silent `AudioPlan` (no clips) | `AppAudioManifestBridgeTests` | unit |
| Global-audio clip round-trips into a non-empty `AudioPlan` | `AppAudioManifestBridgeTests` | unit |
| Mapping: `destination` (outward floor/ceil projection of start+duration, non-aligned µs accepted, widening < 1 tick/boundary), `sourceTrim` (exact rational), `gain` (volume → 0…1_000_000, fail-closed reject of out-of-range/non-finite, no clamp) | `AppAudioManifestBridgeTests` | unit |
| Music never loops (`playbackPolicy == .once`, no `loopToFit`) | `AppAudioManifestBridgeTests` | unit |
| Video-layer original audio mapping when `includeOriginalFromVideoSlots` | `AppAudioManifestBridgeTests` | unit |
| Descriptors: exactly one per source; 0/multiple → typed failure | `AppAudioSourceDescriptorResolverTests` | unit |
| Transition volume-ramp handling — canonical-gain expression **or** documented behaviour-delta decision | `AppAudioManifestBridgeTests` (+ decision in this plan) | unit + decision |
| `AudioPlan` reproducible end-to-end from populated window | `AppAudioEvaluationBridgeTests` | unit |
| Bounded chunk, no whole-project, 48 kHz, hold-last | `AppAudioChunkPreparerTests` | unit |
| Activate-before-query fail-closed | `AppAudioSessionAdapterTests` | unit |
| Start-barrier order; audio only after first frame | `CanonicalPreviewAudioControllerTests` | unit |
| Silent scrub (no schedule on scrub/settle) | `CanonicalPreviewAudioControllerTests` | unit |
| `newDeviceAvailable` → pause-only (no restart) | `RealtimeAudioSessionEventMappingTests` | unit |
| Post-mix output stage (Candidate A) | engine `OutputOverloadStageTests` (existing) | unit |
| Build/install/run (toggle ON) | physical iPhone | device |
| A/V sync from audio-sample master | physical iPhone | device |
| Silent scrub audible check | physical iPhone | device |
| Route/new-device pause-only by ear | physical iPhone (headphones/BT) | device |
| D-213 audible quality (Candidate A) | physical iPhone, overloaded mix | device |
| 6-video-with-music (memory/thermal/underrun) | physical iPhone, tracked fixture | device |

---

## Final readiness statement

**READY WITH CONDITIONS.** No architectural blocker prevents wiring Slice-004 realtime
audio into AnimiApp: the realtime layer is public and ships its AV sink, the canonical
*video* model and the evaluation requirement/scene payloads are already produced in-app,
and the integration is preview-only behind a toggle that leaves export untouched.
**The decisive condition (corrected): the app builds the canonical VIDEO model but NOT a
canonical AUDIO manifest** — `manifest.audio == .empty`, so Slice 005 must build a
populated `AudioManifest` **and** a `ResolvedAudioSourceDescriptor` resolver before any
audible plan exists. Proceed to Stage A **only after explicit approval**. Open conditions
to close: build the `AudioManifest` bridge + descriptor resolver (the new domain work),
**decide** transition-ramp handling (canonical gain vs documented behaviour delta — NOT
yet solved), and track the 6-video fixture.
