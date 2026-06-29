# Slice 005 — Stage 9 device regression matrix — FINAL: **PASS (9/9)**

Full canonical preview-audio device regression on iPhone 13 Pro
(`86C5CAA4-23E9-5EDB-BBE1-C11DAE59FF39`), flags
`-DebugPreviewAudioWithNextEngine YES -DebugMemoryDiagnostics YES`. Build = commit `5819848f` +
the Stage-9.2 fixes (AudioEvaluator sourceDuration clamp + mediaLocator URL-parity/real-duration +
warm-up timing). No code changed during this matrix run; no stage/commit/push.

## Matrix: all 9 scenarios PASS

| # | Scenario | Verdict | Raw log | Key markers |
|---|---|---|---|---|
| 1 | music-only | **PASS** | `evidence/slice-005-stage9-01-music-only.log` | render.end 61, schedule.end 59, endOfPlan 2 |
| 2 | video-original (+stretch) | **PASS** | `evidence/slice-005-stage9.2-warmup-timing.log` | plan 20, firstFrameSignal 40, scheduled 19, endOfPlan 10 |
| 3 | music + video | **PASS** | `evidence/slice-005-stage9-03-music-video.log` | plan 10, scheduled 9, endOfPlan 7 |
| 4 | changed scene length | **PASS** | `evidence/slice-005-stage9-04-changed-scene-length.log` | plan 4, scheduled 4, endOfPlan 4, incomingAudioBeforeBoundary 0 |
| 5 | 2+ scenes | **PASS** | `evidence/slice-005-stage9-05-two-scenes.log` | plan segments=3, scheduled 2, endOfPlan 1 |
| 6 | long video | **PASS** | `evidence/slice-005-stage9-06-long-video.log` | schedule.end 102, endOfPlan 4 |
| 7 | scrub | **PASS** | `evidence/slice-005-stage9-07-scrub.log` | play-after-scrub: scheduled 4 / play 8; no audio on scrub |
| 8 | pause/play | **PASS** | `evidence/slice-005-stage9-08-pause-play.log` | startPlayback 9 / stop 9 clean cycles |
| 9 | route change | **PASS** | `evidence/slice-005-stage9-09-route-change.log` | newDeviceAvailable + oldDeviceUnavailable handled, pause-only |

> Note: `slice-005-stage9-02-video-original-only.log` is the PRE-FIX FAIL capture (13 failures) kept
> as evidence of the original S9.2 blocker. The re-run after the Stage-9.2 fix is
> `slice-005-stage9.2-warmup-timing.log` (0 failures) — that is the authoritative S9.2 PASS log.

## Aggregate failure-marker check (every PASS log = 0)
Across all 8 PASS logs (S9.1, S9.2-rerun, S9.3–S9.9): **0** of
`fallbackToLegacy=1`, `errorAlert`, `audioAssetUnresolvable`, `s8.shortReadProbe`, `pcmRenderFailed`,
`nextChunk.failed`, `SIGKILL`, `jetsam`.

Per-scenario acceptance (all met):
- `fallbackToLegacy = 0` ✅ (every scenario)
- `errorAlert = 0` ✅
- `audioAssetUnresolvable = 0` ✅
- `s8.shortReadProbe = 0` ✅
- `pcmRenderFailed = 0` ✅
- `nextChunk.failed = 0` ✅
- `endOfPlan` reached where applicable ✅ (S1,S2,S3,S4,S5,S6)
- canonical plan/preroll/schedule/player markers present for audio-bearing play ✅
- S6 boundary: `incomingAudioBeforeBoundary = 0` ✅ (S9.4)
- S7 coverage: `produced no PreviewMixSource = 0`, `interior gap = 0` ✅ (S9.5)
- route change: pause-only, no auto-resume, no canonical failure ✅ (S9.9)

## Final verdict: **Stage 9 PASS** — canonical preview audio is device-clean across the full matrix
All four committed/in-progress fixes are validated together on device with zero fallback and zero
canonical failures: S6 scene-tick basis, S7 clean endOfPlan, Stage-8 fix-A latency, Stage-8.1 +
Stage-9.2 source-duration clamp / URL-parity / warm-up timing.

## Confirmations
- No code changed during this matrix run (only the Stage-9.2-fix files from the prior task remain
  modified; this task added only evidence logs + this report).
- No tolerance / guard-band / sessionWindowFrames / maxBoundaryShortfallFrames change.
- No export/visual/legacy change; AnimiEngineCore change limited to the `AudioEvaluator` clamp.
- `git diff --cached --name-only` empty; nothing staged/committed/pushed.
