# Slice 005 — Stage 9.2 warm-up timing fix — S9.2 PASS (closed)

Removes the regressing async `startPlayback` wrapper and adds exactly ONE pre-play warm-up call, so the
canonical controller start stays synchronous relative to the first-frame barrier. With this, the full
Stage-9.2 chain (evaluator clamp + mediaLocator URL-parity + real duration + correct start timing)
plays video-original through a stretched scene to the end with zero failures. **S9.2 PASS.**

## Changed files
- `AnimiApp/Sources/EditorRuntime/EditorRuntimePreviewAudioCoordinator.swift` — reverted the async wrapper:
  canonical `startForTimelinePlayback()` calls `controller.startPlayback(...)` SYNCHRONOUSLY (as before).
  Added `warmUpCanonicalAudioForPlaybackIfNeeded()` (no-op when toggle OFF / not canonical; awaits
  `planSource.warmUpVideoOriginalDurations()`; starts no audio, builds no pipeline, touches no first-frame
  state).
- `AnimiApp/Sources/EditorRuntime/EditorRuntime.swift` — in `startPlayback()`'s `playbackStartTask`, after
  `engine.prepareForPlayback(...)` and BEFORE `playbackTransport.start(...)` / display-link creation /
  video start, one `await self.previewAudio.warmUpCanonicalAudioForPlaybackIfNeeded()`.
- (Data-layer changes from the prior sub-tasks remain: `RuntimeCanonicalAudioPlanSource` mediaLocator
  URL-parity + real-duration mirror, `AppVideoOriginalAudioBridge` real-duration descriptor,
  `VideoOriginalAudioDurationProbe`, `AudioEvaluator` sourceDuration clamp.)

## Order of operations
Before (regressing): canonical branch → `Task { await warmUp; startPlayback }` → first frame could arrive
before `pendingSession` existed → `signalFirstFrameReady` no-op → barrier never crossed → silence.

After (fixed):
```
EditorRuntime.startPlayback() playbackStartTask:
  await engine.prepareForPlayback(...)
  await previewAudio.warmUpCanonicalAudioForPlaybackIfNeeded()   ← NEW: URL + real duration ready
  playbackTransport.start(...)
  displayLink create  (first frame can now fire)
  … previewAudio.startForTimelinePlayback() → controller.startPlayback(...) SYNCHRONOUS
  first-frame signal crosses the barrier normally
```
The warm-up completes before any first frame is possible, and `startPlayback` is synchronous, so the
pending session exists when the first-frame signal arrives.

## Device gate (iPhone 13 Pro) — `slice-005-stage9.2-warmup-timing.log` (3662 lines)
Operator: opened project, added video, stretched scene, played — works.

| Marker | Count | Acceptance |
|---|---|---|
| s8.shortReadProbe | 0 | ✅ |
| pcmRenderFailed | 0 | ✅ |
| nextChunk.failed | 0 | ✅ |
| errorAlert | 0 | ✅ |
| fallbackToLegacy=1 | 0 | ✅ |
| shortfall | 0 | ✅ |
| audioAssetUnresolvable | 0 | ✅ (warm-up landed before play — no fail-closed) |
| SIGKILL / jetsam | 0 | ✅ |
| canonical.plan | 20 | ✅ present |
| preroll.build.end | 19 | ✅ present |
| firstFrameSignal | 40 | ✅ barrier first-frame side set |
| engine.start.end / player.play.end | 19 / 38 | ✅ player starts |
| canonical.scheduled | 19 | ✅ scheduled started |
| nextChunk.schedule.end | 154 | ✅ continuous chunks scheduled |
| nextChunk.endOfPlan | 10 | ✅ reached end |

Marker chain proving the first-frame barrier works: `canonical.plan → preroll.build.end →
firstFrameSignal → engine.start.end → player.play.end → canonical.scheduled → nextChunk.schedule.end …
→ nextChunk.endOfPlan`. The video-original stretched scene is audible through the canonical path to the
end, with no short-read.

## Tests
App: `RuntimeCanonicalAudioPlanSourceTests` 17 (incl. URL-parity: locator used not defaultResolve;
resolvedSourcesByID URL == mediaLocator URL == probe URL; missing-warm fails closed),
`AppVideoOriginalAudioBridgeParityTests` 17, `VideoOriginalAudioPlanTests` 13,
`BackgroundCanonicalPCMRendererTests` 20 (S8.1 clamp), `CanonicalContinuousPlaybackTests` 14
→ **72, 0 failures**. AnimiEngineCore `AudioEvaluatorTests` 19 (incl. 2 sourceDuration-clamp) green;
`swift test --filter Audio` 244, 0 failures.

## Verdict: **S9.2 PASS** — video-original stretched-scene short-read fully closed
The three root causes are all fixed and device-verified together:
1. `AudioEvaluator` clamps `segment.sourceEnd` to `descriptor.sourceDuration`.
2. Canonical video-original uses the mediaLocator URL (visual parity) + the real probed audio-track
   duration — one URL for probe and `resolvedSourcesByID`.
3. Warm-up runs pre-play without deferring `startPlayback`, so the first-frame barrier is preserved.

## Confirmations
- No decoder tolerance / guard-band / sessionWindowFrames / maxBoundaryShortfallFrames change.
- No renderer/cache/session/prewarm/latency change; no export/visual/legacy change.
- AudioEvaluator clamp retained; no `winEnd` fallback restored.
- `git diff --cached --name-only` empty; nothing staged/committed/pushed.

## Remaining Stage-9 matrix (not yet run — S9.2 was the blocker)
S9.1 PASS, S9.2 PASS. S9.3–S9.9 (music+video, changed scene length, 2+ scenes, long video, scrub,
pause/play, route change) still to run for a full Stage-9 verdict.
