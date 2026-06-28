# Slice 005 — Device Smoke Diagnosis (iPhone 13 Pro): No-Audio is a LEGACY render fault, NOT a Slice-005 regression

**Date:** 2026-06-27 · **Device:** iPhone Evgeny, iPhone 13 Pro (`00008110-000C59C20A20401E`) ·
**Build:** Debug, `com.animi.app`, `** BUILD SUCCEEDED **` · **Project under test:** video + music
(scene `full_image`, `block_01` carries a user video with original audio).

## TL;DR

On device, **preview audio is silent with the toggle ON _and_ with the toggle OFF**, on the same
project. Because toggle OFF runs **zero** Slice-005 code (0 canonical markers), the silence is **not** a
Slice-005 regression. The Slice-005 cutover behaves exactly as designed and as unit-proven; it then falls
back to the legacy renderer — **which is itself broken on this project**: the legacy preview-audio render
never reaches `primed` (stays `preparing`) and/or fails `Reader failed: Operation Interrupted`, so no
audio ever starts. The fix cannot make sound audible while the legacy renderer it falls back to is mute.

Evidence: `evidence/slice-005-device-ON.markers.txt`, `evidence/slice-005-device-OFF.markers.txt`.

---

## A/B method

Two launches of the same build on the same project, captured via `devicectl … --console` (markers are
`print("[MEM-EVENT] …")` on the process stdout):

- **ON:**  `-DebugPreviewAudioWithNextEngine YES -DebugMemoryDiagnostics YES`
- **OFF:** `-DebugPreviewAudioWithNextEngine NO  -DebugMemoryDiagnostics YES`

## ON run — Slice-005 cutover works exactly as designed (then falls back)

```
preview.audio.select | toggle=ON controller=Canonical          ← deterministic selection (no lazy trap, R3)
preview.audio.canonical.legacyGateBypassed | seconds=0.0       ← canonical direct branch, legacy gate skipped (R2)
preview.audio.canonical.startPlayback.call | seconds=0.0       ← canonical.startPlayback called directly (R2)
preview.audio.canonical.startFailed | error=videoLayerOriginalAudioUnsupportedInStageA  ← honest blocker (R7)
preview.audio.canonical.fallbackToLegacy | reason=videoLayerOriginalAudioUnsupportedInStageA ← safety fallback (R6)
preview.audio.build.end | result=pipeline tracks=2 mixInputs=2 ← legacy rebuild: music + video-original both in the mix
preview.audio.canonical.firstFrameSkipped | reason=nonCanonicalController ← nil-cast now observable, not silent (R4)
…
preview.audio.engine.render.failed | error=Reader failed: Operation Interrupted   ← LEGACY render fails
preview.audio.engine.failure | reason=renderFailed(... "Reader failed: Operation Interrupted")
```

Every R2/R3/R4/R6 marker and the R7 blocker are confirmed on device. The cutover is correct. But the
fallback target — the legacy renderer — fails.

## OFF run — pure legacy, SAME silence (the control)

```
preview.audio.select | toggle=OFF controller=Legacy           ← canonical code never runs
(canonical markers in OFF run: 0)
preview.audio.build.end | result=pipeline tracks=2 mixInputs=2 ← same correct plan: music + video-original
preview.audio.engine.render.begin | generation=2 tracks=2 duration=5.0
preview.audio.start | dirty=1 hasPipeline=1 readiness=preparing
preview.audio.start.awaitReady | …                            ← STUCK in `preparing` (×3), never `primed`
playback.audio.sessionDeactivate.call → audio.session.deactivate.end | ok=1
```

In the OFF run the legacy controller went to `awaitReady` (`preparing`) **3 times and reached `primed`
0 times** — playback audio never started. Same mute, with none of my code in the path.

## Root cause (independent of Slice 005)

The legacy `EnginePreviewAudioPlaybackController` renders the mixed pipeline (music + video-original;
`tracks=2 mixInputs=2` — the PLAN is correct) to a file via `AVAssetReader`. On this device/project that
render **does not complete**: the controller stays `readiness=preparing` (OFF) or the read aborts with
`Reader failed: Operation Interrupted` (ON). The reader abort coincides with
`playback.audio.sessionDeactivate.call` — the shared `AVAudioSession` is deactivated while the offline
render is mid-flight, interrupting the reader. Net: the preview-audio controller never becomes `primed`,
so `startPlayback` never produces sound.

This reproduces with `DebugPreviewAudioWithNextEngine = OFF`, i.e. it predates and is independent of
Slice 005.

## What this means for the Slice-005 commit

- The Slice-005 no-sound **regression fix is correct and device-verified by markers** (canonical direct
  start, no legacy build gate on the canonical path, safety fallback, observable nil-cast, video-original
  honest blocker). Unit gates: app 89 (1 skipped) / 0 fail; core realtime 83 / 0.
- BUT it must **not** be reported as "no-sound fixed" end-to-end: on a real video+music project the user
  still hears nothing, because the legacy renderer the fallback lands on is itself mute on device.
- **Decision (owner): record diagnosis only — do NOT fix the legacy renderer in this pass.** The legacy
  `AVAssetReader`/session-deactivation render fault is out of Slice-005 scope and owner-deferred.

## Corrected status line

> Slice 005 canonical direct-start + safety fallback is implemented and device-verified by markers;
> video-original canonical audio remains a blocker; **on-device audio is still silent because the legacy
> preview-audio renderer (the fallback target) fails independently of the toggle (reproduced with toggle
> OFF) — a separate, pre-existing legacy render fault, owner-deferred.** Slice 005 canonical cutover is
> NOT complete; the no-sound is NOT a Slice-005 regression.

## Outstanding

- Legacy preview-audio render fault (`preparing` never → `primed`; `Reader failed: Operation Interrupted`
  on `sessionDeactivate` mid-render) — **owner-deferred**, separate work item.
- No stage/commit/push performed. Index empty.
