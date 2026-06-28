# Slice 005 — Stage 8 latency audit (DEBUG instrumentation, NO fix)

Measured audit of canonical preview-audio start latency after Play. DEBUG-only diagnostics behind
`DebugMemoryDiagnostics`; no behavior change; no tolerance/guard-band/sessionWindowFrames/decoder/
export/visual/legacy/AnimiEngineCore change. Fix is NOT implemented — options listed at the end.

Device: iPhone 13 Pro (`86C5CAA4-23E9-5EDB-BBE1-C11DAE59FF39`), Debug build of commit-code
`499d2fec` + the S6/S7 fixes + S8 probe + these Stage-8 timers. Flags
`-DebugPreviewAudioWithNextEngine YES -DebugMemoryDiagnostics YES`.
Raw log: `Docs/AnimiEngineNext/evidence/slice-005-stage8-latency-probe.log`.

## Changed files (DEBUG-only diagnostics)
- `AnimiApp/Sources/EditorRuntime/Realtime/CanonicalPreviewAudioController.swift` — monotonic
  `DispatchTime`-based timing helper (`s8…`) + `stage8.*` markers across the start path
  (startPlayback.call → plan.eval → setup.end → preroll.begin/end → firstFrameSignal +
  barrierReason → barrier.cross → graph.schedule.end → player.play.end → scheduled.total).
- `AnimiApp/Sources/EditorRuntime/Realtime/CanonicalPCMRenderCache.swift` — `stage8.cache.{hit,
  miss,coalesced,store}` with range + revision/epoch + planId length. No cache behavior change.
- `AnimiApp/Sources/EditorRuntime/Realtime/BackgroundCanonicalPCMRenderer.swift` —
  `stage8.render.{decode,total}` (per-source decode ms, total render ms). No render behavior change.

All gated by `#if DEBUG` + `MemoryDiagnostics.isEnabled`. `git diff --cached` empty; not staged.

## Measured marker table — first Play (music-only, from 0)

| Marker | sinceStart (ms) | phase delta |
|---|---|---|
| startPlayback.call | 0.05 | — |
| plan.eval | 4.98 | **4.36** (plan eval) |
| setup.end (graph+session+output+anchor) | 36.89 | **~31.9** (engine/session/output/anchor config) |
| preroll.begin | 36.96 | — |
| firstFrameSignal | 37.30 | (arrives EARLY — not the late side) |
| preroll.end | 94.77 | **57.80** (preroll render = decode of 1 s) |
| barrier.cross | 94.79 | — |
| graph.schedule.end | 193.63 | **98.81** (scheduleInitialAudioPreroll) |
| player.play.end | 193.73 | **0.07** (engine/player start) |
| **scheduled.total** | **193.76** | **≈194 ms total startPlayback → audible scheduled** |

Requested deltas:
- startPlayback → firstFrame: **37.25 ms** (and firstFrame is NOT the bottleneck — see below)
- startPlayback → preroll.build.end: **94.72 ms**
- preroll.begin → render.end (preroll.end): **57.80 ms**
- render.end → player.play (barrier.cross → player.play.end): **≈98.9 ms** (dominated by graph.schedule)
- player.play → scheduled: **0.07 ms**

Other Plays (from non-zero time, no video first-frame wait): total **146–166 ms**
(`scheduled.total` 166.61 / 149.12 / 146.49). setup is smaller there (~11 ms vs ~32 ms) because
no fresh video runtime warmup; preroll render stays ~80 ms; graph.schedule ~49–71 ms.

## Decode breakdown (the surprise)

`stage8.render.decode` per chunk (first Play):
- chunk `0..<48000` (FIRST, opens a new bounded session): decode **47.54 ms**
- chunk `48000..<96000` (contiguous, same open reader): decode **0.50 ms**
- chunk `96000..<144000` (contiguous): decode **0.50 ms**

→ The decode cost is almost ENTIRELY the FIRST bounded-session OPEN (AVAssetReader seek + priming
+ guard-band margin read). Sequential contiguous reads are ~0.5 ms. `render.total` for the first
chunk is 54.93 ms (decode 47.54 + framing/buffer ~7 ms).

## Cache facts (decisive)

`cache.hit = 0`, `cache.miss = 68`, `cache.store = 66`, `cache.coalesced = 0`.

**The PCM cache NEVER hits.** Every chunk is a miss. Proof from the key fields: each Play mints a
NEW `revision`/`epoch` (`ProjectRevision(raw: 1)`, `PlaybackEpoch(raw: 1)` for the first Play; the
next Plays carry new raws), and the cache key includes revision+epoch, so a repeated Play (or even
the next chunk of a new epoch) can never match a previously-stored chunk. **Repeated Play does NOT
reuse PCM — it re-renders/re-decodes every time.** This is gen-C territory (fix option C below).

## firstFrame is NOT the bottleneck (confirmed)

All 12 epochs logged `barrierReason=firstFrameArrivedPrerollNotReady` — i.e. the first frame
always arrived BEFORE the preroll render finished. The barrier is gated by the PREROLL render, not
the first frame. (firstFrameSignal at ~37 ms vs preroll.end at ~95 ms.)

## Confirmed root of latency (measured, not inferred)

Total ≈194 ms (music-only from 0) splits into THREE real costs, none of which is the first-frame wait:

1. **graph.schedule ≈ 99 ms** — `scheduleInitialAudioPreroll` writing the 1 s preroll PCM into the
   AVAudioEngine graph. **Largest single contributor.** (Inference on internal cause: scheduling a
   full 1 s buffer into the engine; the marker proves the elapsed, not the AVFoundation internals.)
2. **preroll render ≈ 58 ms** — dominated by the FIRST bounded AVAssetReader session OPEN (47.5 ms);
   contiguous reads are ~0.5 ms. (Fact: per-chunk decode timing above.)
3. **setup ≈ 32 ms** (first Play) — graph+session+output+anchor configuration (engine create/activate).

The original hypothesis "the 1 s preroll DECODE dominates" is REFUTED by measurement: decode is
~58 ms, while graph.schedule (~99 ms) is larger. The preroll SIZE still matters (it sets how much
is decoded AND scheduled), but schedule, not decode, is the bigger half.

## Proposed minimal fix options (NOT implemented)

- **A. Smaller initial preroll** (e.g. preroll = a fraction of `maxChunkSamples`, keep
  `maxChunkSamples` for continuous chunks). 
  - FACT: a smaller preroll reduces BOTH the first decode AND the first graph.schedule (both scale
    with preroll sample count) → attacks the two biggest costs at once.
  - INFERENCE: ~194 ms could drop substantially if preroll shrinks from 48000 to e.g. 4800–9600.
  - RISK: too-small a first buffer can underrun if the next continuous chunk is not scheduled in
    time; needs device verification of continuity. Must not change `maxChunkSamples` for continuous.

- **B. Prewarm before Play** (render/schedule the first preroll during prepare/prime, before the
  user taps Play). 
  - FACT: production prewarm is not wired (cache shows only on-Play misses).
  - INFERENCE: moving the ~150 ms render+schedule off the Play tap would make Play feel instant.
  - RISK: prewarm must be invalidated on edits/seek (revision/epoch) or it serves stale audio;
    interacts with option C (cache identity).

- **C. Split PCM-sample cache identity from epoch/revision and rewrap buffers.** 
  - FACT: `cache.hit = 0` because the key includes revision+epoch and each Play mints new ones, so
    repeated Play re-renders identical PCM.
  - INFERENCE: keying the SAMPLE cache on (planIdentity, range) — content only — and rewrapping the
    buffers per epoch would let repeated Play reuse decoded PCM (decode ~0 on replay).
  - RISK: must preserve the revision/epoch late-completion/invalidation guarantees (a content-keyed
    cache must still be dropped on a real plan change); careful design needed to not serve stale
    audio. Larger change than A/B.

Recommended sequencing (inference, owner decides): A is the smallest, lowest-risk win and hits both
top costs; B removes the perceived latency entirely; C optimizes repeated Play. They compose.

## S8 short-read — REPRODUCED this run (separate from latency, NOT in scope to fix here)

During the video+music Play the operator hit an alert. The armed `s8.shortReadProbe` captured it
(`slice-005-stage8-latency-probe.log:1209`):
```
path=openSessionAndServe source=…videoLayer:scene-0-251894F8…:block_01
reqSourceStart=182933/16000 (=11.433s) readStart=181333/16000 (=11.333s)
marginFrames=4800 sessionReadFrames=480000 requestedFrameCount=48000 firstReadFrames=52800
wideDecoded=26334 bodyDecoded=21534
→ pcmRenderFailed(shortfall 26466 > tolerance 1024)
```
and a second (`:1354`): `reqSourceStart=57/5 (=11.4s)`, `wideDecoded=27933`.

**S8 root — now CONFIRMED (was UNKNOWN):** the request maps a chunk starting at ~11.4 s of the
source, but the AVAssetReader over `[readStart, readStart+10s)` returns only `wideDecoded≈26–28k`
frames (~0.55 s) before end-of-track. So the SOURCE's audio track ends at ≈11.9 s
(`11.333 + 26334/48000 ≈ 11.88 s`), and the plan asked for a 1 s chunk past it. This is §3.3
hypothesis **(a) source-shorter-than-mapped-range**, now proven: the plan maps a destination span
LONGER than the video clip's actual audio track, so the tail chunk runs off the end of the source.

This is NOT a latency issue and is NOT fixed in this Stage-8 pass (S8 was explicitly out of scope).
It is the same blocker family as the S7 coverage gap but at the decode layer; the captured values
above are exactly what a future S8 fix needs (clamp the mapped chunk / destination to the source's
real audio track length, NOT a tolerance change). Recorded for the next pass.

## Acceptance check
- No behavior change (all additions are `#if DEBUG` markers + monotonic timers; no logic altered).
- Device log contains ms enough to decide the fix (full marker chain above).
- Cache miss because revision/epoch changes: STATED explicitly (cache.hit=0, all miss).
- firstFrame wait is NOT the bottleneck: STATED explicitly (all `firstFrameArrivedPrerollNotReady`).
- Targeted tests green: `CanonicalContinuousPlaybackTests` 15, `CanonicalPCMRenderCacheTests` 10,
  `BackgroundCanonicalPCMRendererTests` 16 → 41, 0 failures.
- `git diff --cached --name-only` empty; nothing staged/committed/pushed.

**STOP after report. Fix not implemented.**

---

# Stage 8 fix A — small initial preroll (IMPLEMENTED + device gate)

Implemented ONLY fix A: a smaller INITIAL preroll buffer. Continuous chunks unchanged. No
cache/prewarm/decoder redesign; no tolerance/guard-band/sessionWindowFrames change; no export/
visual/legacy/AnimiEngineCore change. S8 NOT touched.

## Changed files
- `AnimiApp/Sources/EditorRuntime/Realtime/CanonicalPreviewAudioControllerFactory.swift` — new
  production constant `initialPrerollSamples = 9_600` (200 ms @ 48 kHz); passed into the controller.
  `maxChunkSamples = 48_000` (continuous chunk size) UNCHANGED.
- `AnimiApp/Sources/EditorRuntime/Realtime/CanonicalPreviewAudioController.swift` — `Dependencies`
  gains `initialPrerollSamples: Int64?` (defaults to nil → falls back to `maxChunkSamples`, no-op for
  callers/tests that don't set it). `boundedPrerollRange` caps the INITIAL preroll by
  `effectiveInitialPrerollSamples` (the new value), while continuous scheduling still starts at
  `preroll.range.end` and uses `maxChunkSamples`. The `stage8.preroll.begin` marker now reports
  `initialPrerollSamples` / `maxChunkSamples`.
- `AnimiApp/Tests/CanonicalContinuousPlaybackTests.swift` — fix-A regression tests.

## Old → new
- Initial preroll: **48_000 frames (1 s) → 9_600 frames (200 ms)**.
- Continuous chunk size: **48_000 frames (unchanged)**.

## Tests
Targeted suites green (0 failures): `CanonicalContinuousPlaybackTests` 15 (3 new fix-A tests),
`CanonicalPCMRenderCacheTests` 15, `BackgroundCanonicalPCMRendererTests` 16,
`AppVideoOriginalAudioBridgeParityTests` 12, `RuntimeCanonicalAudioPlanSourceTests` 14,
`CanonicalAudioArchitectureTests` 14 → **84, 0 failures**. New fix-A tests:
`testFixA_smallPrerollThenFullContinuousChunks` (preroll=8 not 20; first continuous starts at
preroll.end; continuous=20), `testFixA_prerollClampsToRemainingWhenPlanShorter`,
`testFixA_defaultUnsetUsesMaxChunkSamples`.

## Device gate
Device: iPhone 13 Pro. Flags `-DebugPreviewAudioWithNextEngine YES -DebugMemoryDiagnostics YES`.
Log: `Docs/AnimiEngineNext/evidence/slice-005-stage8-fixA.log`. On device the preroll is confirmed
`range=0..<9600 sampleCount=9600 initialPrerollSamples=9600 maxChunkSamples=48000`.

### Before / after (apples-to-apples: 1-segment music-only, Play from 0)

| Phase | Baseline (1 s preroll) | Fix A (200 ms preroll) | Δ |
|---|---|---|---|
| plan.eval | ~4 ms | ~1 ms | — |
| setup | ~32 ms | ~13 ms | (cold-start noise) |
| preroll render (decode) | 57.8 ms | **35.9 ms** | −22 ms |
| graph.schedule | 98.8 ms | **82.4 ms** | −16 ms |
| player.play start | 0.07 ms | 0.02 ms | — |
| **scheduled.total** | **193.8 ms** | **132.4 ms** | **−61 ms (−32%)** |

Both the decode and the graph.schedule shrank (both scale with the preroll sample count), so the
total Play→scheduled dropped ~32% on the comparable case.

### Acceptance markers (whole device run, all scenarios)
`errorAlert=0`, `nextChunk.failed=0`, `fallbackToLegacy=0`, `pcmRenderFailed=0`, `shortfall=0`,
`SIGKILL/jetsam=0`, `s8.shortReadProbe=0`. `nextChunk.endOfPlan` reached 8×;
`nextChunk.schedule.end` 121× (continuous chunks scheduled without an underrun stall). Operator:
ran the scenarios, no alert caught, no start dropout reported.

### Honest caveats (not hidden)
- The HEADLINE win (−32%) is on a 1-segment music-only project. On heavier projects in the same run
  (5 segments / video, multiple sources) `scheduled.total` was higher (≈238–282 ms first Play). The
  reason is FACT from the markers: decode is dominated by the per-source AVAssetReader SESSION OPEN
  (≈26–96 ms EACH), which a smaller preroll does NOT reduce — that cost is fixed per source, not per
  sample. Fix A reduces the per-sample decode + the graph.schedule, not the per-source open. The
  remaining win for multi-source projects needs option B (prewarm) and/or C (content-keyed cache);
  fix A composes with both and was the requested smallest-risk step.
- `graph.schedule` (≈82 ms) is still the single largest phase even at 200 ms preroll. It shrank but
  remains the biggest cost — a further reduction would come from an even smaller preroll (higher
  underrun risk) or B/C.

## Verdict: **PASS**
- Play→scheduled.total materially lower than the ≈194 ms baseline (−32% on the comparable case).
- No audible dropout at start (operator); continuous chunks scheduled cleanly (121× schedule.end).
- `nextChunk.failed=0`, `fallbackToLegacy=0`, `errorAlert=0`; canonical reaches `endOfPlan`.
- No underrun stall; the small preroll did not cause a continuity failure.

## Confirmations
- No export / visual / legacy / AnimiEngineCore change.
- No tolerance / guard-band / sessionWindowFrames / maxBoundaryShortfallFrames change;
  `maxChunkSamples` (continuous) unchanged at 48_000.
- S8 not masked and not fixed (it did not reproduce this run; probe armed).
- `git diff --cached --name-only` empty; nothing staged/committed/pushed.
