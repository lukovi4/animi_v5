# Slice 005 — Stage 9.2 residual: AudioEvaluator sourceEnd clamp — REGRESSION on device, STOP

The `AudioEvaluator` clamp itself is correct and unit-proven, but combined with the Stage-9.2 app-side
fail-closed descriptor (no `winEnd` fallback) it causes a DEVICE REGRESSION: video-original audio now
fails on EVERY Play because the real-duration probe returns nothing for the resolved URL, so the
fail-closed bridge throws on every attempt. STOP and report (Stage-9 rule); do not paper over.

## Changed files (this attempt)
- `AnimiEngineNext/Sources/AnimiEngineCore/Audio/AudioEvaluator.swift` — ONE-LINE clamp (the requested fix).
- `AnimiEngineNext/Tests/AnimiEngineCoreTests/AudioEvaluatorTests.swift` — 2 regression tests.

## Evaluator clamp formula (implemented, correct, unit-proven)
Was:
```
let audibleSrcHi = minRational(srcAtEnd, trim.end)
```
Now (`AudioEvaluator.swift:76`):
```
let audibleSrcHi = minRational(minRational(srcAtEnd, trim.end), clip.sourceDescriptor.sourceDuration)
```
Because `destHiTick` (`firstProjectTick(sourceAtLeast: audibleSrcHi …)`) and the final
`sourceEnd = map.source(atProjectTick: clippedHi)` are derived from `audibleSrcHi`, this bounds
`segment.sourceEnd ≤ sourceDuration` by construction; a range entirely past `sourceDuration` yields zero
segments (empty audible window → nil, not error). Exact rational; no validation loosened.

## Tests
AnimiEngineCore: `AudioEvaluatorTests` **19** (2 new S9.2), `swift test --filter Audio` **244 tests, 0
failures**. App audio suites **69, 0 failures**. New evaluator tests:
- `test_S92_sourceDurationClampsSourceEndAndDestination` — sourceDuration 3 s < trim 600 s < dest 5 s →
  `sourceEnd == 3 s`, destination clipped to 720_000 ticks, no segment sourceEnd exceeds sourceDuration.
- `test_S92_requestedRangeAfterSourceDurationYieldsZeroSegments` — range after sourceDuration → zero segments.

(The Metal `AnimiEngineMetalRenderTests` SIGSEGV in `swift test` is a pre-existing headless-GPU issue,
unrelated to this audio change.)

## Device gate (iPhone 13 Pro) — `slice-005-stage9.2-evaluator-clamp.log` — REGRESSION

Operator: "now audio fails everywhere."

| Marker | Count |
|---|---|
| `audioAssetUnresolvable("real audio-track duration not probed yet")` | 6 (every Play) |
| `errorAlert` | 6 |
| `canonical.plan` (any plan built) | 0 |
| `canonical.scheduled` (any start) | 0 |
| `s8.shortReadProbe` | 0 |

Every Play (lines 82, 168, 265 …) fails the SAME way: `startFailed audioAssetUnresolvable("real
audio-track duration not probed yet; no winEnd fallback")`. No plan is ever built, nothing schedules.

### Root of the regression (fact from the log)
- The real video file IS present and readable: line 62
  `[VideoFrameProvider] READY: B045FD1B…_block_01_ED8722B9…mp4 | dur=13.70s`.
- Yet the Stage-9.2 duration probe returns NOTHING for the URL the plan source resolves, so the mirror
  never fills, so the fail-closed bridge (no `winEnd` fallback) throws on EVERY Play.
- Mismatch: the real on-disk video is `<assetId>_<blockId>_<uuid>.mp4` (line 62), but the plan source's
  `resolveURL` builds its URL from `registry.storagePath(for:)` — a DIFFERENT path. The probe therefore
  hits a URL with no readable audio track → `nil` → permanent fail-closed.

### Why this is WORSE than before (regression, not just unfixed)
Before this Stage-9.2 attempt, the descriptor used the `winEnd` lower bound and video-original PLAYED
(with the S9.2 short-read at the tail). The Stage-9.2 fail-closed-without-fallback turned "plays with a
tail defect" into "never plays" whenever the probe URL does not resolve to the real audio — which is the
common case here. The evaluator clamp is correct, but it never runs because the build fails earlier.

## Verdict: **REGRESSION — revert candidate / needs a different approach**

The evaluator clamp (AudioEvaluator.swift) is the RIGHT mechanism and is unit-proven. The problem is the
APP-SIDE half from the previous task: the real-duration probe resolves the WRONG URL (it does not match
the real on-disk video filename), and the fail-closed-no-fallback policy then blocks every Play.

Two honest options for the owner (NOT implemented here — Stage-9 rule: report, do not fix in this task):
1. **Fix the probe URL** to the real video file path (the same one VideoFrameProvider opens — keyed by the
   actual `<assetId>_<blockId>_<uuid>.mp4`), so the probe returns the real 13.70 s and the clamp works.
2. **Keep `winEnd` as a SAFE fallback** for the descriptor (play continues) WHILE the evaluator clamp +
   a corrected probe bound the real end — i.e. do not fail-closed-to-silence when the probe is missing;
   fall back to a value that at least plays, and let the evaluator clamp shorten it once the real probe
   lands. (This reverses the "no winEnd fallback" decision, which is what caused the regression.)

The evaluator clamp commit content is safe to keep; the app-side probe/fail-closed from the prior task is
the regressing part. Recommend reverting the prior app-side fail-closed (restore a playing fallback) and
re-probing by the correct URL before re-enabling fail-closed.

## Confirmations
- No decoder tolerance / guard-band / sessionWindowFrames / maxBoundaryShortfallFrames change.
- No renderer/session/cache/prewarm/latency change; no export/visual/legacy change.
- AnimiEngineCore change limited to the single `AudioEvaluator` clamp line + its tests (allowed scope).
- `git diff --cached --name-only` empty; nothing staged/committed/pushed.
