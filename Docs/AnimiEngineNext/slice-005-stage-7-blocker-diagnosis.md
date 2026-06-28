# Slice 005 — Stage 7 blocker diagnosis + S6/S7 fix

> STATUS: §1–6 below are the original READ-ONLY diagnosis (no code changed at that time). The
> "Runtime value confirmation", "Fix implemented (S6 + S7)", and cleanup sections that FOLLOW
> describe the implemented behavior fixes + DEBUG value-capture probes. The diagnosis prose is
> preserved verbatim for provenance; the fix sections are the current state.

Diagnosis of the three Stage-7 device-gate FAILs on commit
`499d2fecc3b90b83f77fa10ee7123afb2b57d060`. The diagnosis phase made no code/architecture/
tolerance/guard-band/export/visual/legacy change. Facts are separated from hypotheses; every
fact carries a `file:line` citation. Where the conclusion needs runtime values not present in
the logs (e.g. concrete `durationUs` of the project's scenes, or the source media's audio track
length), it is labelled a **hypothesis with proven mechanism**, never asserted as fact.

Input report: `Docs/AnimiEngineNext/slice-005-stage-7-device-gate-report.md`
Raw logs:
- `Docs/AnimiEngineNext/evidence/slice-005-stage7-route-change.log` (S6)
- `Docs/AnimiEngineNext/evidence/slice-005-stage7-long-video.log` (S7)
- `Docs/AnimiEngineNext/evidence/slice-005-stage7-stress-multiple-video.log` (S8)

## TL;DR — three DIFFERENT roots

| Fail | Error | Origin (file:line) | Root |
|---|---|---|---|
| S6 | `incomingAudioBeforeBoundary` | `ProjectValidator.swift:291` | **basis mismatch**: `destination.start = floor(Σ durationUs)` vs `domain.start = Σ ceil(durationUs)` — proven mechanism |
| S7 | `audioRenderPipelineUnavailable … produced no PreviewMixSource` | `CanonicalPreviewAudioController.swift:509-510`; zero-sources gate at `BackgroundCanonicalPCMRenderer.swift:51` | **request range past the source's audio end** → no segment overlap → zero sources — hypothesis with proven mechanism |
| S8 | `pcmRenderFailed … shortfall 21653 > tolerance 1024` | `AVFoundationPCMAssetDecoder.swift:164-165` (reconcile), via `openSessionAndServe` | **mapped chunk extends past the source's audio track end** → real short-read — hypothesis with proven mechanism |

**They do NOT share one root.** S6 is a validator boundary-arithmetic mismatch (occurs at
plan build, before any decode). S7 and S8 are both "the request runs past the end of the
source's available audio", but at two different layers and surfacing as two different errors
(zero-sources vs short-read). S6 is independent of S7/S8. S7 and S8 are *siblings* (same
family: source-end vs requested-range), not identical.

---

## 1. S6 — `incomingAudioBeforeBoundary`

### 1.1 Verified facts (log)

- Scene id `8EB9A95F-2088-4724-830C-CBDA736CC86F`, sceneType `polaroid_2`
  (`route-change.log:110`).
- Failing clip id `app.audio.clip.videoLayer.scene-1-8EB9A95F-…:block_01`
  (`route-change.log:218`).
- The SAME project, on a later restart in the same log, builds a plan successfully:
  `preview.audio.canonical.plan | segments=4 fromSeconds=0.0` (`route-change.log:434`) and
  later `… fromSeconds=1.066666` (`route-change.log:541`). So the failure is state-dependent,
  not unconditional. The fractional `fromSeconds=1.066666` is consistent with a scene whose
  duration is not a whole number of canonical ticks.
- `clip` is `scene-1`, i.e. the SECOND scene (index 1) — so its `domain.start` is the sum of
  scene-0's span, i.e. non-zero. (A scene-0 clip would have `domain.start = 0` and could not
  trip a `start < 0` boundary.)

### 1.2 Verified facts (code)

The throw:
```
ProjectValidator.swift:290  guard clip.destination.start >= domain.start else {
ProjectValidator.swift:291      throw ProjectValidationError.incomingAudioBeforeBoundary(clip: clip.id.raw)
```

`domain.start` derivation — `SceneMediaClock.mediaActiveDomain`
(`ProjectValidator.swift:326` → `SceneMediaClock.swift:59`):
```
SceneMediaClock.swift:69-72
  var startTicks: Int64 = 0
  for i in 0..<index {
      startTicks = try CheckedInt64.add(startTicks, scenes[i].timelineSpan.ticks, …)
  }
```
→ **`domain.start = Σ_{k<index} timelineSpan.ticks`** (sum of preceding scenes' span, in
canonical ticks).

`scenes[k].timelineSpan` for the preview path == `nominalDuration` (boundaries are plain
cuts, `RuntimeCanonicalAudioPlanSource.swift:320-322`), and `nominalDuration` is built as:
```
RuntimeCanonicalAudioPlanSource.swift:304  guard let ticks = Slice005TickProjection.ceilTicks(item.durationUs) else { … }
RuntimeCanonicalAudioPlanSource.swift:309  nominalDuration: try TickDuration(ticks: max(1, ticks))
```
→ **each preceding scene contributes `ceilTicks(durationUs_k)`**.

`clip.destination.start` derivation — `AppVideoOriginalAudioBridge`:
```
AppVideoOriginalAudioBridge.swift:136  let destStartUs = input.sceneStartUs + input.blockStartUsInScene
AppVideoOriginalAudioBridge.swift (makeDestination):207  let startTicks = Slice005TickProjection.floorTicks(startUs)
```
and the `sceneStartUs` input:
```
RuntimeCanonicalAudioPlanSource.swift:161  let sceneStartUs = timeline.computedStartUs(forSceneAt: i)
CanonicalTimeline.swift:258  return sceneSequenceTrack.items[0..<index].reduce(0) { $0 + $1.durationUs }
```
→ **`destination.start = floorTicks( Σ_{k<index} durationUs_k )`** (floor of the SUM of
preceding scenes' microsecond durations).

For a video-layer scene-filling block, `blockStartUsInScene = 0`
(`RuntimeCanonicalAudioPlanSource.swift` block math; bridge `destStartUs = sceneStartUs + 0`),
so no extra offset hides the mismatch.

The projection policy:
```
Slice005TickProjection.swift:19-23  floorTicks: floor(us·6/25)
Slice005TickProjection.swift:26-33  ceilTicks:  ceil(us·6/25)
```

### 1.3 Root (hypothesis with proven mechanism)

`destination.start` and `domain.start` are computed from the **same microsecond durations**
but with **different rounding compositions**:

- `domain.start = Σ ceilTicks(us_k)` — **sum of per-scene CEILs**
- `destination.start = floorTicks(Σ us_k)` — **FLOOR of the sum**

Algebraically, `Σ ceil(x_k) ≥ floor(Σ x_k)` always, and the gap grows by up to 1 tick per
preceding scene whose `durationUs_k` is not an exact multiple of one canonical tick
(1 tick = 25/6 µs ≈ 4.1667 µs). Therefore whenever at least one preceding scene's duration is
not tick-aligned — which is exactly what happens when the operator changes a scene's length
"by even one second" to a value that is not a whole number of ticks — we get
`destination.start < domain.start` and the validator fails closed with
`incomingAudioBeforeBoundary`.

This matches the operator's reproduction (default-length project passes; change scene length →
alert) and the log evidence (`fromSeconds=1.066666` fractional; second-scene clip; same
project passes on another generation when state differs).

**Why this is a hypothesis, not a bare fact:** the exact `durationUs` of scene-0 in the
failing generation is NOT in the log, so the precise 1-tick gap cannot be arithmetically
re-derived from the evidence alone. The *mechanism* (ceil-sum vs floor-of-sum) IS proven from
code. To convert to fact: capture the project's per-scene `durationUs` for the failing state
and compute `Σ ceil` vs `floor Σ`.

### 1.4 Confidence
**High** on mechanism (pure code-derived). **Pending** on exact reproduction numbers
(needs the manifest durations of the failing generation).

---

## 2. S7 — `audioRenderPipelineUnavailable … produced no PreviewMixSource`

### 2.1 Verified facts (log)

- Plan is `segments=1 fromSeconds=0.0` (`long-video.log:381`) — a SINGLE video-original
  source, started from 0. NOT a stretched multi-scene project like S6.
- Chunks `0 … 2256000` render and schedule cleanly; the break is at
  `2256000..<2304000` = **47.0 s @ 48 kHz** (`long-video.log:718-722`):
  `render.end | sources=0` → `nextChunk.render.end | sourceCount=0` →
  `nextChunk.failed | audioRenderPipelineUnavailable(... produced no PreviewMixSource)`.
- Deterministic: 6 failures clustered around the same point ~`2256000–2259199`
  (`long-video.log:723, 1085, 1369, 1731, 1918, 2064`).
- Memory healthy (`MEM ~111 MB`), `SIGKILL/jetsam=0` — not a resource kill.

### 2.2 Verified facts (code)

The emit site for THIS message:
```
CanonicalPreviewAudioController.swift:509-510
  continuousFailed(AppRealtimeAudioIntegrationError.audioRenderPipelineUnavailable(
      reason: "continuous chunk \(range.start)..<\(range.end) produced no PreviewMixSource"))
```
i.e. the controller asked the renderer for a continuous chunk and got an EMPTY `sources`
array back (not a thrown decode error).

How `sources` becomes empty in the renderer (single-segment plan):
```
BackgroundCanonicalPCMRenderer.swift:49-51
  iStart = max(segment.destinationSamples.start, request.range.start)
  iEnd   = min(segment.destinationSamples.end,   request.range.end)
  guard iEnd > iStart else { continue }      // ← no overlap → segment skipped, nothing appended
```
With a single segment, if that segment's `destinationSamples` does NOT overlap the requested
range, the loop appends nothing and returns `sources: []`. The other empty-paths in this file
THROW instead of returning empty (missing resolved source →
`BackgroundCanonicalPCMRenderer.swift:58-60` `mediaUnavailable`; decoder short →
`:81-85` `pcmRenderFailed`), so they are NOT the S7 signature.

### 2.3 Root (hypothesis with proven mechanism)

The single segment's `destinationSamples` (the span of the project timeline the source's
audio actually covers) **ends before `2256000`**. Once the playhead's requested chunk lies
entirely past the segment's destination end, `iEnd <= iStart`, the segment is skipped, zero
sources are produced, and the controller fails closed. In plain terms: **the source's audio
ran out at ~47 s and the canonical path requested a chunk beyond it.**

**Why hypothesis, not fact:** the segment's `destinationSamples` end (= where the source's
audio coverage ends on the timeline) is not printed in the log. The *mechanism* (no-overlap →
zero sources → this exact error) IS proven from code. To convert to fact: log the segment
`destinationSamples` range, or the source's audio track duration, and confirm its end ≈
`2256000`.

### 2.4 NOT the same root as S6 (proven)
S6 fails at `ProjectValidator.swift:291` BEFORE any plan/render (no `plan`/`render.begin`
markers in that cycle — `route-change.log:217-219`). S7 builds a plan and renders 47 s of
audio successfully, then fails at `CanonicalPreviewAudioController.swift:509`. Different file,
different layer, different stage. Do not treat as one bug.

### 2.5 Confidence
**High** on mechanism. **Pending** on the segment-end value.

---

## 3. S8 — `pcmRenderFailed … decode produced 26347 frames, expected 48000`

### 3.1 Verified facts (log)

- Plan `segments=4 fromSeconds=0.0` (`stress-multiple-video.log:425, 585`) — 4 videos.
- Chunks `0 … 528000` render/schedule cleanly; the break is at `528000..<576000`
  = **11.0 s @ 48 kHz** (`stress-multiple-video.log:680-681`).
- `decode produced 26347 frames, expected 48000 (shortfall 21653 > tolerance 1024)`;
  `pcmRenderFailed=2`, `shortfall=2`; `fallbackToLegacy=0`; `SIGKILL/jetsam=0`; memory grew
  (~430 MB foot) but no crash.
- Operator: **4-video project at default scene length plays fine; change scene length by ≥1 s →
  this alert.**

### 3.2 Verified facts (code)

The throw:
```
AVFoundationPCMAssetDecoder.swift:162-165 (reconcileFrameCount)
  let shortfall = frameCount - samples.count
  guard !samples.isEmpty, shortfall <= maxBoundaryShortfallFrames else {
      throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
          reason: "decode produced \(samples.count) frames, expected \(frameCount) (shortfall \(shortfall) > tolerance \(maxBoundaryShortfallFrames))")
```
`maxBoundaryShortfallFrames = 1024` (`AVFoundationPCMAssetDecoder.swift:152`). Shortfall 21653
is ~21× the tolerance — this is NOT a boundary-priming pad, it is a real partial read.

The read path that produced the partial body: `openSessionAndServe` → `runForward` →
`AVAssetReaderBoundedPCMReader.readForward`:
```
AVFoundationPCMAssetDecoder.swift readForward loop:
  while out.count < frameCount, !ended {
      guard let batch = try readNextChunk() else { if started { ended = true }; break }  // nil = end-of-range
      …
  }
  return out   // may be < frameCount when the reader hit end-of-stream
```
The `timeRange` is built from the bounded window:
```
AVFoundationPCMAssetDecoder.swift:541-548
  readStartTime = CMTime(value: window.readStart.numerator, timescale: window.readStart.denominator)
  duration      = CMTime(value: Int64(sessionReadFrames), timescale: AudioSampleGrid.samplesPerSecond)
  timeRange     = CMTimeRange(start: readStartTime, duration: duration)
```
where `window.readStart` is derived from the exact rational `sourceStart` via
`boundedReadWindow` (read-start = `max(0, sourceStart − margin)`), and `sessionReadFrames =
max(window.readFrameCount, sessionWindowFrames)`. The bounded-session decision logic
(`BoundedSourceSessionPolicy.decide`) governs contiguous-serve vs new-session and is unit-tested
(`BoundedSourceSessionDecoderTests.swift`); nothing in the decision math is shown to be wrong
for this case.

### 3.3 Root (hypothesis with proven mechanism)

The reader reached **end of the source's audio track** inside the requested chunk: the
`AVAssetReader` over `[readStart, readStart + sessionReadFrames)` returned only 26347 body
frames before `readNextChunk()` yielded `nil`. This is the decode-layer manifestation of "the
mapped chunk extends past where the source's audio actually exists" — the same family as S7,
but here the source DID return partial data (so it surfaces as a short-read, not zero-sources).

Because the operator's trigger is again **scene-length change**, the most likely upstream cause
is that changing the scene duration re-maps the video-original clip's destination/trim so the
plan asks for a source range that runs off the end of that clip's audio. Two candidate sub-causes,
both consistent with the code but NOT decidable from the log alone:
- **(a) source-shorter-than-mapped-range**: the clip's audio ends ~11 s in but the plan maps a
  chunk to `528000..<576000`; the decoder reads to end-of-track and returns 26347.
- **(b) wrong mapped sourceStart/trim after stretch**: the stretch produced a `sourceStart`/trim
  window whose end exceeds the track, again hitting end-of-track early.

Distinguishing (a) vs (b) needs the segment's `sourceStart`, `frameCount`, and the source
track's actual audio duration — none are in the log.

**Why hypothesis, not fact:** the partial count proves a short-read happened (fact), but
WHICH of (a)/(b) — i.e. whether the trim window is wrong or the source is simply that short —
is not provable from the captured markers.

### 3.4 NOT identical to S7 (proven)
S7 emits zero sources at `BackgroundCanonicalPCMRenderer.swift:51` and fails at
`CanonicalPreviewAudioController.swift:509` with `audioRenderPipelineUnavailable`. S8 throws a
decode short-read at `AVFoundationPCMAssetDecoder.swift:164-165` (`pcmRenderFailed`) that
propagates through `BackgroundCanonicalPCMRenderer.swift:81`. Different throw sites, different
error cases, different layers. S8 is the same short-read FAMILY that Stage-6 Candidate A
addressed for the un-stretched case, recurring under scene-length change at a new chunk —
Candidate A removed the interior re-seek but did NOT change how the mapped range relates to the
source's audio length.

### 3.5 Confidence
**High** that it is a genuine source-end short-read (not boundary padding). **Pending** on
(a) vs (b) — needs segment `sourceStart`/`frameCount` + source track duration.

---

## 4. Are S6 / S7 / S8 the same root? — explicit answer

**No.** Three different roots, two of which are siblings:

- **S6** — validator arithmetic (ceil-sum vs floor-of-sum boundary mismatch). Fires at PLAN
  BUILD, before decode. Independent.
- **S7** — request range past the source's audio coverage end → no segment overlap →
  zero-sources. RENDER layer.
- **S8** — mapped chunk extends past the source's audio track end → real partial read.
  DECODE layer.

S7 and S8 share an upstream theme ("the canonical path requests audio beyond where the source
has audio, after a scene-length / long-range condition") but manifest at different layers via
different errors. The operator-confirmed common TRIGGER is scene-duration change (S6, S8) and
long-range playback past source end (S7); the common trigger is NOT a common code root.

---

## 5. Minimal fix plan (proposal only — NOT approved, NOT implemented)

Scope rule honoured: no tolerance change, no guard-band change, no architecture change, no
export/visual/legacy change. The fixes below are the MINIMAL, root-targeted changes; each is
gated on first turning its hypothesis into a fact (see §5.4 STOP conditions).

### 5.1 Exact files to change (candidate)

- **S6 (boundary arithmetic):** ONE of —
  - `AnimiApp/Sources/EditorRuntime/Realtime/AppVideoOriginalAudioBridge.swift` — make
    `destination.start` use the SAME basis as `domain.start` (project the *cumulative* scene
    start with the same per-scene ceil composition used for `timelineSpan`, instead of
    `floor(Σ durationUs)`), so `destination.start == domain.start` for a scene-filling block; OR
  - `AnimiApp/Sources/EditorRuntime/Realtime/RuntimeCanonicalAudioPlanSource.swift` — derive the
    clip's `sceneStartUs`→ticks via the same `ceilTicks`-cumulative the manifest uses, so both
    sides share one projection.
  Preferred: align the bridge to the manifest basis (single source of truth), NOT relax the
  validator (relaxing the `>=` guard would re-admit genuinely pre-boundary audio).

- **S7 (zero-sources past source end):** ONE of —
  - `AnimiApp/Sources/EditorRuntime/Realtime/RuntimeCanonicalAudioPlanSource.swift` /
    `AppVideoOriginalAudioBridge.swift` — clamp the plan's audio coverage / segment
    `destinationSamples` to the source's actual audio extent so the controller never requests a
    continuous chunk past the last segment (the path should reach `endOfPlan`, not
    `produced no PreviewMixSource`); OR
  - `AnimiApp/Sources/EditorRuntime/Realtime/CanonicalPreviewAudioController.swift` — treat a
    past-last-segment continuous request as `endOfPlan` rather than a hard failure (only if the
    range is provably beyond plan coverage).

- **S8 (short-read past source track end):** ONE of —
  - `AppVideoOriginalAudioBridge.swift` / `RuntimeCanonicalAudioPlanSource.swift` — clamp the
    mapped chunk / trim window so a request never asks for source frames beyond the track's audio
    duration (pad-with-silence to the clip's destination end is acceptable ONLY inside the
    destination domain, never as a tolerance change); OR
  - `BackgroundCanonicalPCMRenderer.swift` — when a segment legitimately covers fewer source
    frames than the chunk because the source audio ends, render the available frames and
    zero-fill the remainder of the DESTINATION span (NOT a decoder tolerance change — a
    plan-level "source ended, destination continues as silence" semantic).

  Decision (a) vs (b) from §3.3 must be made first; do NOT touch `maxBoundaryShortfallFrames`
  or `interiorSeekMarginFrames`.

### 5.2 Exact tests to add

- **S6:** a `ProjectValidator` / bridge unit test that builds a 2+ scene project whose scene-0
  `durationUs` is deliberately NOT tick-aligned (e.g. `durationUs` such that
  `floor(Σ·6/25) < Σ ceil(·6/25)`), and asserts `destination.start == domain.start` for the
  scene-1 video-layer clip (i.e. validation passes). Add the algebraic boundary case
  (off-by-one tick) explicitly.
- **S7:** a `BackgroundCanonicalPCMRenderer` / controller test where the single segment's
  `destinationSamples` ends before a requested continuous chunk; assert the result is
  `endOfPlan`, NOT `audioRenderPipelineUnavailable`.
- **S8:** an `AVFoundationPCMAssetDecoder` / plan test (using a fixture source whose audio track
  is shorter than the mapped chunk) asserting the request is clamped to the track end and the
  destination tail is silence — with NO change to `maxBoundaryShortfallFrames`.
- Re-run existing `BoundedSourceSessionDecoderTests`, `AVFoundationPCMAssetDecoderWatchdogTests`,
  `CanonicalContinuousPlaybackTests`, and the audio-architecture guard tests to prove no
  regression and no tolerance/guard-band drift.

### 5.3 Device scenarios to re-run (after fix + green tests)

Re-run the full Stage-7 matrix, but specifically:
- S6: 2+ scene project, increase scene-0 length by 1 s, play scene-1 → expect no alert.
- S7: single long video, play past the source's audio end → expect clean `endOfPlan`, no alert.
- S8: 4-video stress project, change scene length by ≥1 s, play through the 11 s point → expect
  no `pcmRenderFailed`.
- Regression: re-run S1–S5 (must stay PASS), confirm `errorAlert=0`, `fallbackToLegacy=0`,
  `nextChunk.failed=0`, `pcmRenderFailed=0`, `shortfall=0`, no SIGKILL.

### 5.4 STOP conditions

- **STOP before implementing** until each hypothesis is upgraded to a FACT by capturing the
  missing runtime values:
  - S6: per-scene `durationUs` of the failing generation → confirm `floor Σ < Σ ceil`.
  - S7: the failing segment's `destinationSamples` end / source audio track duration → confirm
    it ends ≈ `2256000`.
  - S8: the failing segment's `sourceStart` + `frameCount` + source track audio duration →
    decide §3.3 (a) vs (b).
  A one-shot diagnostic marker addition (log the segment ranges / source durations) is the
  cheapest way to capture these; it is itself a code change and must be owner-approved first.
- **STOP and report** (do NOT proceed) if any fix would require: raising
  `maxBoundaryShortfallFrames`, widening `interiorSeekMarginFrames`, a whole-source / whole-
  project render, loss of exact-rational source time, a legacy fallback, or any export / visual /
  AnimiEngineCore-evaluator semantic change.
- **STOP** if the S6 alignment fix would relax the validator `>=` guard (that would re-admit real
  pre-boundary audio) — the fix must make the two BASES agree, not loosen the check.
- **STOP** if device re-run still shows any alert → do not tune tolerance; re-diagnose.

---

## 6. Diagnosis constraints honoured

- No code changed (READ-ONLY): `git status --porcelain` shows no `.swift`/`.pbxproj`
  modifications from this diagnosis; only this document is added.
- No architecture / tolerance / guard-band / export / visual / legacy change.
- No "probably": every claim is either a `file:line`/log fact or an explicitly labelled
  hypothesis-with-proven-mechanism plus the exact value needed to confirm it.
- S6, S7, S8 stated as three different roots (S7/S8 siblings, S6 independent).

---

# Runtime value confirmation (Stage-7 value-capture pass)

DEBUG-only probes were added behind the existing `DebugMemoryDiagnostics` path (markers
`preview.audio.stage7.s6.boundaryProbe`, `…s7.zeroSourceProbe`, `…s8.shortReadProbe`) and the
three failing scenarios re-run on the same physical device (iPhone 13 Pro,
`86C5CAA4-23E9-5EDB-BBE1-C11DAE59FF39`), same commit code + diagnostics only. No behavior
change. Build: device Debug; targeted decoder tests 41/41 pass; sim build green.

Raw probe logs:
- `Docs/AnimiEngineNext/evidence/slice-005-stage7-s6-boundary-probe.log`
- `Docs/AnimiEngineNext/evidence/slice-005-stage7-s7-zero-source-probe.log`
- `Docs/AnimiEngineNext/evidence/slice-005-stage7-s8-shortread-probe.log`

**Operator-confirmed reproduction rule (NEW, decisive):** the failure appears **only with 2 or
more scenes**, and the real authoring workflow is always *open project → make a scene long →
then add video*. A single-scene project (scene index 0) never fails. This is exactly what the
probes show (a scene-0 clip has `precedingDurUs=[]` → delta always 0).

## S6 — `incomingAudioBeforeBoundary` — **CONFIRMED**

Marker (`s6-boundary-probe.log:252`, repeated 636-637):
```
s6.boundaryProbe | clip=…scene-1-13F60C80…:block_01 idx=1 precedingDurUs=[8766667]
  floorSumStart=2104000 ceilSumStart=2104001 destStart=2104000 destEnd=3304001
  domainStart=2104001 delta(domain-dest)=1 wouldFail=1
```
followed by `startFailed | incomingAudioBeforeBoundary(... scene-1-13F60C80…:block_01)`
(`:253`).

Control (passing) case (`s6-boundary-probe.log:172`): `precedingDurUs=[5000000]` (tick-aligned)
→ `floorSumStart == ceilSumStart == 1200000`, `delta=0`, `wouldFail=0`, no alert.

**Computed verification:** scene-0 duration `8766667 µs`. `8766667·6/25 = 2104000.08`.
`floor = 2104000` (destination basis), `ceil = 2104001` (domain basis). `delta = 1` tick →
`destination.start (2104000) < domain.start (2104001)` → fail. EXACTLY the predicted
ceil-sum-vs-floor-of-sum mismatch (§1.3), now with concrete numbers, **not a hypothesis**.

**Verdict: CONFIRMED.** Root = basis mismatch between
`destination.start = floorTicks(Σ durationUs)` (`AppVideoOriginalAudioBridge.swift:136,207`)
and `domain.start = Σ ceilTicks(durationUs)` (`SceneMediaClock.swift:69-72`,
`RuntimeCanonicalAudioPlanSource.swift:304`).

**Minimal fix (confirmed):** make `destination.start` for a scene-filling video-layer clip use
the SAME cumulative `ceilTicks`-per-scene basis the manifest/domain uses, so
`destination.start == domain.start` for index ≥ 1. Do NOT relax the validator `>=` guard.
File: `AppVideoOriginalAudioBridge.swift` (or compute the scene start as
`Σ ceilTicks(precedingDurUs)` in `RuntimeCanonicalAudioPlanSource.swift` and pass ticks, not µs,
to the bridge). Add the off-by-one-tick boundary unit test (§5.2 S6).

## S7 — `produced no PreviewMixSource` — **CONFIRMED**

Reproduced during the 2-scene / 4-video run (`s8-shortread-probe.log:1479-1486`). The probe
fired for the failing chunk `441600..<489600` (≈9.2 s), `segCount=4`, and EVERY segment
reported `emptyOverlap=1`, `reason=no-overlap(request past segment destination end)`:
```
seg[0] clip=…scene-0-5CE8BF7B…:block_01 segDest=0..<424000 iStart=441600 iEnd=424000 emptyOverlap=1 segSourceEnd=53/6
seg[1] …:block_02 segDest=0..<424000 iStart=441600 iEnd=424000 emptyOverlap=1 segSourceEnd=53/6
seg[2] …:block_03 segDest=0..<310960 iStart=441600 iEnd=310960 emptyOverlap=1 segSourceEnd=3887/600
seg[3] …:block_04 segDest=0..<424000 iStart=441600 iEnd=424000 emptyOverlap=1 segSourceEnd=53/6
```
then `render.end sources=0` → `nextChunk.failed | audioRenderPipelineUnavailable(… produced no PreviewMixSource)` → `errorAlert` (`:1485-1486`).

**Computed verification:** ALL four segments belong to **scene-0** (`5CE8BF7B…`), with
destination ends `424000` and `310960` samples. The continuous player requested
`441600..<489600`, which starts at `441600 > 424000` — past the destination end of every
segment. So `iEnd ≤ iStart` for all four (`BackgroundCanonicalPCMRenderer.swift:51`), zero
sources, fail-closed. This is **destination-coverage exhaustion**, NOT decode end-of-source:
the plan's segments only cover scene-0's span, but the player kept requesting chunks into the
region where scene-1's video-original segments are expected and absent/uncovered. Matches the
"2+ scenes only" rule.

**Verdict: CONFIRMED** (now proven from runtime values, upgraded from §2.3 hypothesis). Root =
the continuous request range advances past the destination coverage of all plan segments (the
plan does not cover the requested timeline region for the second scene's video-original audio).

**Note — this is the same FAMILY as the original S7 long-video FAIL but a different shape than
first thought.** The original §2 hypothesis (single source's audio simply ending at ~47 s) is
now refined: the captured case is multi-segment, all scene-0, and the gap is the **plan not
covering the later scene's region**, exposed once the playhead crosses scene-0's destination
end. The original single-scene long-video FAIL could NOT be reproduced in this pass (see below);
the confirmed mechanism here is the coverage gap at a scene boundary.

**Minimal fix (confirmed):** either (a) make the plan cover the full project timeline for
video-original audio across ALL scenes (so a later scene's video-layer audio yields segments,
or the gap is explicit silence to `endOfPlan`), or (b) treat a continuous request that is
provably past the last segment's destination end as `endOfPlan` rather than a hard
`audioRenderPipelineUnavailable`. File:
`RuntimeCanonicalAudioPlanSource.swift` / `BackgroundCanonicalPCMRenderer.swift` /
`CanonicalPreviewAudioController.swift`. Add the past-coverage → endOfPlan test (§5.2 S7).

## S8 — `pcmRenderFailed` short-read — **STILL UNKNOWN (not reproduced this pass)**

The short-read (`pcmRenderFailed … shortfall > tolerance`) did **not** reproduce in any
value-capture run; `s8.shortReadProbe` fired 0 times. In the 2-scene / 4-video run that the
original report attributed to a short-read, the failure that actually occurred was the **S7
zero-source coverage gap** (above), not a decode short-read. Earlier single-scene runs reached
clean `endOfPlan`.

**Verdict: STILL UNKNOWN.** No runtime short-read values were captured because the short-read
condition did not occur. Two honest possibilities (neither asserted as fact):
- the original S8 short-read and this S7 zero-source are the SAME underlying scene-boundary
  coverage problem surfacing differently depending on exact frame alignment (short-read when the
  boundary falls inside a chunk such that the source returns partial frames; zero-source when the
  whole chunk is past coverage); or
- the original S8 short-read depended on a specific source/asset not used in this pass.

The `s8.shortReadProbe` (renderer-side + both decoder paths: `serveContiguous` /
`openSessionAndServe`) remains in place and WILL capture readStart / session cursor /
framesRemainingInWindow / decoded-count / shortfall if the short-read recurs. To convert S8 to
CONFIRMED/REJECTED: re-run until a `pcmRenderFailed` short-read is observed with the probe armed.

## Consolidated verdict

| Fail | Status | Root (confirmed) |
|---|---|---|
| S6 | **CONFIRMED** | floor(Σ durationUs) vs Σ ceil(durationUs) → destination.start 1 tick < domain.start when a preceding scene is not tick-aligned |
| S7 | **CONFIRMED** | continuous request past the destination coverage of all plan segments at a scene boundary (2+ scenes) → zero sources |
| S8 | **STILL UNKNOWN** | short-read not reproduced; probe armed; likely a sibling of S7's coverage gap or asset-specific |

**Updated root relationship:** S6 is independent (validator arithmetic, pre-render). S7 is a
plan-coverage gap at scene boundaries. S8 is unproven this pass but most plausibly the same
coverage family as S7. The operator's "2+ scenes only" rule fits S6 and S7 exactly.

## Probe inventory (DEBUG-only, behind DebugMemoryDiagnostics)

- `RuntimeCanonicalAudioPlanSource.swift` — `emitS6BoundaryProbe(...)` after `videoBuilt` build.
- `BackgroundCanonicalPCMRenderer.swift` — S7 zero-source probe after the segment loop; S8
  decode-failure probe around the decoder call.
- `AVFoundationPCMAssetDecoder.swift` — S8 decoder-internal probe in `serveContiguous` and
  `openSessionAndServe` (readStart / cursor / window / decoded counts).
- `descriptorSourceDuration` is logged as `unavailable(renderer-has-no-descriptor)`: the
  renderer/decoder do not hold the `ResolvedAudioSourceDescriptor` (it lives in the plan-source
  layer); surfacing it here would need threading the descriptor through the render request — a
  refactor, deliberately NOT done per the "no new abstractions" rule.

## Task acceptance check

- Diagnostics compile: device Debug build SUCCEEDED; sim build SUCCEEDED.
- Targeted tests still pass: `BoundedSourceSessionDecoderTests` + `AVFoundationPCMAssetDecoderWatchdogTests` + `CanonicalContinuousPlaybackTests` = 41/41, 0 failures.
- Raw device logs captured (3 files above).
- No behavior fix attempted (only `#if DEBUG` MemoryDiagnostics emits + do/catch-rethrow wrappers that re-throw the original error unchanged).
- `git diff --cached --name-only` empty; nothing staged/committed/pushed.

**STOP after report. Do not implement until approved.**

---

# Fix implemented (S6 + S7) + device rerun

Confirmed fixes implemented (S6, S7 only; S8 NOT touched). No tolerance/guard-band/decoder
short-read/export/visual/legacy/AnimiEngineCore-semantics change.

## Files changed
- `AnimiApp/Sources/EditorRuntime/Realtime/AppVideoOriginalAudioBridge.swift` — S6: optional
  `sceneStartTicks`/`sceneEndTicks` on `Input` + a tick-based `makeDestination(startTicks:endTicks:)`;
  when ticks are supplied the destination is built EXACTLY from them (integer-only).
- `AnimiApp/Sources/EditorRuntime/Realtime/RuntimeCanonicalAudioPlanSource.swift` — S6: compute
  cumulative `Σ ceilTicks(durationUs)` scene starts (same basis as `SceneMediaClock`/manifest) and
  pass `sceneStartTicks`/`sceneEndTicks` into the bridge (no more `floor(Σµs)` for the scene start).
  The accumulation is CHECKED + fail-closed (`cumulativeSceneDestinationTicks`): a non-projectable
  `ceilTicks(durationUs)` or an overflowing cumulative/end add throws `.anchorArithmeticOverflow`
  (matching the sibling `buildMinimalVideoDocument`), NOT a silent `-1`/`0` substitution
  (audit P1 commit-blocker fix). `addingReportingOverflow` only — no unchecked `+`/trap.
- `AnimiApp/Sources/EditorRuntime/Realtime/CanonicalPreviewAudioController.swift` — S7: an empty
  continuous chunk whose `range.start >= max(segment.destinationSamples.end)` is a clean audio end
  → emit `nextChunk.endOfPlan`, stop scheduling, no alert/fallback; an empty chunk BEFORE the last
  segment end still fails closed with a precise "interior gap" diagnostic (real gaps not hidden).
- `AnimiApp/Tests/AppVideoOriginalAudioBridgeParityTests.swift` — S6 regression tests.
- `AnimiApp/Tests/CanonicalContinuousPlaybackTests.swift` — S7 regression tests.

## Tests (sim iPhone 16 Pro)
Targeted suites, all green (0 failures):
`AppVideoOriginalAudioBridgeParityTests` 21, `RuntimeCanonicalAudioPlanSourceTests` 14,
`VideoOriginalAudioPlanTests` 12, `CanonicalContinuousPlaybackTests` 12,
`BoundedSourceSessionDecoderTests` 10, `AVFoundationPCMAssetDecoderWatchdogTests` 10,
`CanonicalAudioArchitectureTests` 5 → **84 tests, 0 failures**. New tests:
`test_S6_destinationStart_equalsDomainStart_forNonTickAlignedPrecedingScene`,
`test_S6_tickAlignedPrecedingScene_unchanged`,
`testChunkPastLastSegmentEndsCleanlyNotUnavailable`, `testInteriorGapStillFailsClosed`.

## Device rerun (iPhone 13 Pro, same commit code + fixes; DebugMemoryDiagnostics ON)

| Scenario | Log | errorAlert | nextChunk.failed | produced-no-MixSource | pcmRenderFailed/shortfall | fallbackToLegacy | SIGKILL/jetsam | Verdict |
|---|---|---|---|---|---|---|---|---|
| S6 | `slice-005-stage7-s6-fixed.log` | 0 | 0 | 0 | 0 | 0 | 0 | **PASS** |
| S7 | `slice-005-stage7-s7-fixed.log` | 0 | 0 | 0 | 0 | 0 | 0 | **PASS (no failure recurred)** |
| S8 | `slice-005-stage7-s8-fixed.log` | 0 | 0 | 0 | 0 | 0 | 0 | **NOT REPRODUCED** |

**S6 — PASS, proven it is the NEW build (not legacy):** the S6 probe in `s6-fixed.log` shows a
NON-tick-aligned preceding scene `precedingDurUs=[9316667]` (`9316667·6/25 = 2236000.08`) with
`floorSumStart=2236000`, `ceilSumStart=2236001`, and **`destStart=2236001` (== domain, == ceil)**,
`delta=0`, `wouldFail=0`. On the OLD build `destStart` always equalled `floorSumStart` (2236000)
and `wouldFail=1` — `destStart` equalling the CEIL value is only possible on the new tick path, so
this is positive proof the fixed architecture ran. 0/12 probes `wouldFail=1`; 0 alerts.

**S7 — PASS but fix-path not exercised on device this session.** All three reruns played to clean
`endOfPlan` with zero alerts/failures, but the S7 fix branch (`s7.zeroSourceProbe` → endOfPlan
instead of unavailable) did NOT fire in any device run (`s7.zeroSourceProbe=0`): the zero-source
condition did not recur. The fix path is therefore proven by UNIT TESTS
(`testChunkPastLastSegmentEndsCleanlyNotUnavailable` + `testInteriorGapStillFailsClosed`), and on
device the symptom is simply absent (no `produced no PreviewMixSource`, no alert). Honest status:
device shows the blocker gone; the exact fix branch was verified in tests, not in this device log.

**S8 — STILL NOT REPRODUCED, NOT TOUCHED.** No `pcmRenderFailed`/short-read occurred;
`s8.shortReadProbe` fired 0 times. No S8 fix implemented (per scope). The probe remains armed.

## Diagnostics status (after cleanup)
- **S6 boundary probe — REMOVED** (`RuntimeCanonicalAudioPlanSource.swift`): one-shot value-capture,
  its job (proving the floor-vs-ceil delta) is done and now pinned by unit tests.
- **S7 zero-source probe — REMOVED** (`BackgroundCanonicalPCMRenderer.swift`): one-shot; the file is
  now byte-identical to HEAD (no Stage-7 change there). The S7 behavior fix lives in the controller.
- **S8 short-read probe — KEPT** (`AVFoundationPCMAssetDecoder.swift`, both `serveContiguous` and
  `openSessionAndServe` paths only): minimal, `#if DEBUG` + `DebugMemoryDiagnostics`-gated, re-throws
  the original error unchanged. Kept to catch the UNKNOWN short-read recurrence (it captures the
  actor-private readStart / cursor / framesRemainingInWindow / decoded count the renderer cannot see).
  The renderer-side S8 do/catch wrapper was removed (it duplicated this and lacked the descriptor).

## Acceptance check
- S6: no `incomingAudioBeforeBoundary`, no `errorAlert` — met.
- S7: no `audioRenderPipelineUnavailable`, no `nextChunk.failed`, clean `endOfPlan` — met (symptom
  absent on device; fix branch proven in unit tests).
- S8: no short-read → **STILL NOT REPRODUCED**; probe armed; decoder short-read behavior unchanged.
- Across rerun: `fallbackToLegacy=0`, `errorAlert=0` (S6/S7/S8), no tolerance/guard-band change,
  no export/visual/legacy change.
- `git diff --cached --name-only` empty; nothing staged/committed/pushed.
