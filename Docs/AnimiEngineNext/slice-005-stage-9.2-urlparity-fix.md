# Slice 005 — Stage 9.2 URL/parity fix — DATA FIX WORKS, but async start-wrap broke the first-frame barrier

The URL/duration parity fix is CORRECT and lands: the plan builds, the preroll PCM renders `sources=1`
with NO short-read (the S9.2 bug is gone at the data layer). BUT wrapping `controller.startPlayback(...)`
in an async `Task { await warmUp; startPlayback }` broke the first-frame barrier timing → the player
never starts → silence. STOP and report; the start-wrap approach is the regressing part, not the data fix.

## Changed files (this attempt)
- `RuntimeCanonicalAudioPlanSource.swift` — video-original now uses ONLY the mediaLocator-resolved URL
  (`session.mediaLocator.absoluteURL`, the visual path) + real probed duration, mirrored by asset id;
  `currentAudioPlan()` reads only that warm mirror (no `defaultResolveURL` path-guess); fail-closed on miss.
  Injectable `mediaLocatorURL`. `warmUpVideoOriginalDurations()` rewritten to use the locator.
- `EditorRuntimePreviewAudioCoordinator.swift` — retains the canonical plan source and (REGRESSING)
  wraps the canonical start in `Task { await planSource.warmUpVideoOriginalDurations(); startPlayback() }`.
- Tests: `RuntimeCanonicalAudioPlanSourceTests` (+3 URL/parity tests: locator used not defaultResolve;
  resolvedSourcesByID URL == mediaLocator URL == probe URL; missing warm fails closed).
- `AppVideoOriginalAudioBridge.swift` unchanged from the prior real-duration attempt.

## URL source used
`session.mediaLocator.absoluteURL(for: slot.mediaRef, registry:)` — the SAME async resolver the visual
Next preview uses (`EditorRuntime.swift:1611`, `ResolvedMediaMap`, export). Probe + `resolvedSourcesByID`
both use THIS URL (proven by `test_S92_resolvedSourceURL_equalsMediaLocatorURL_sameAsProbeURL`).

## Proof the DATA fix works (device log `slice-005-stage9.2-urlparity-fix.log`)
```
canonical.plan | segments=1                              ← plan built (warm-up gave URL+duration)
preroll.build.begin range=1698..<11298
render.decode source=…videoLayer…block_01 frameCount=9600 intersectionFrames=9600 elapsedMs=124  ← FULL decode, NO clamp shortfall
render.end | sources=1                                   ← preroll rendered OK (no short-read!)
preroll.build.end sourceCount=1
stage8.preroll.end renderElapsedMs=126 sourceCount=1
```
No `s8.shortReadProbe`, no `pcmRenderFailed`, no `errorAlert`. The S9.2 short-read is GONE: the evaluator
clamp + the correct mediaLocator URL + real duration together produced a clean preroll.

## The regression (root, proven from the log)
After `preroll.end` there is NO `firstFrameSignal`, NO `engine.start`, NO `player.play`, NO `scheduled`.
The preroll is ready but the barrier never crosses → silence. Then playback stops and the editor closes.

Cause: the canonical start path now runs `startPlayback` LATER, inside an async `Task` that first awaits
`warmUpVideoOriginalDurations()`. The first-frame signal (`EditorRuntime` →
`canonical.signalFirstFrameReady()`) is gated by `didSignalFirstPreviewAudioFrame` and fires on the first
render frame. With the deferred `startPlayback`, the first frame can arrive BEFORE the pending canonical
session exists (`signalFirstFrameReady` is a no-op when `pendingSession == nil`), so the barrier's
first-frame side is never set for the real epoch → `tryCrossBarrier` never starts the player.

So: the DATA fix (URL parity + real duration + evaluator clamp) is correct and eliminates the short-read;
the async START-WRAP is the regression. The warm-up must complete WITHOUT deferring `startPlayback` past
the first-frame signal.

## Status: BLOCKED on a start-ordering decision (not implemented — reporting first)
Options to land the warm-up without breaking the barrier (need owner pick):
- **A. Warm up earlier (preferred):** kick `warmUpVideoOriginalDurations()` on toggle ON / selection /
  prepare — BEFORE Play — and keep `startPlayback` SYNCHRONOUS on the play tap (as before). First Play
  after warm completes is clean; document a single fail-closed first-Play only if the user plays before
  warm finishes (rare; the warm starts at selection).
- **B. Make the first-frame signal epoch-safe:** have `startPlayback` create the pending session
  synchronously FIRST, then warm/await, so a first frame is never dropped. More invasive (touches barrier
  ordering).
- **C. Keep the synchronous `startPlayback` and let the per-block fail-closed + async warm self-heal on
  the next Play** (revert the start-wrap). Simplest; costs one fail-closed first Play.

The current start-wrap (option-B-shaped but wrong) must be reverted/replaced. The data-layer changes
(URL parity, real duration, evaluator clamp) are correct and should stay.

## Tests
App: `RuntimeCanonicalAudioPlanSourceTests` 17 (+3), `AppVideoOriginalAudioBridgeParityTests` 17,
`VideoOriginalAudioPlanTests` 13, `BackgroundCanonicalPCMRendererTests` 20,
`CanonicalContinuousPlaybackTests` 14 → 72, 0 failures. AnimiEngineCore evaluator clamp tests green
(19, incl. 2 S9.2). The unit tests pass because they call the synchronous build directly; the device
regression is purely the async start-ordering in the coordinator.

## Confirmations
- No decoder tolerance / guard-band / sessionWindowFrames / maxBoundaryShortfallFrames change.
- No renderer/cache/session/prewarm/latency change; no export/visual change.
- AudioEvaluator clamp retained; no `winEnd` fallback restored.
- `git diff --cached --name-only` empty; nothing staged/committed/pushed.
