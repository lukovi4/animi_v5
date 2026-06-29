# Slice 005 — Stage 9.2: video-original real audio-track duration fix — PARTIAL / BLOCKED

Attempt to fix the S9.2 device failure (video-original short-read after scene stretch) by replacing the
descriptor's `winEnd` lower-bound `sourceDuration` with the REAL probed audio-track duration.

**Result: PARTIAL — the descriptor fix is correct and lands, but it does NOT eliminate the short-read,
because `segment.sourceEnd` (the value the renderer's Stage-8.1 clamp uses) is computed by the
AnimiEngineCore `AudioEvaluator` from the destination→source MAPPING, NOT from `descriptor.sourceDuration`.
Fixing the residual requires an `AudioEvaluator`/window-builder change (AnimiEngineCore), which is OUT OF
SCOPE per the hard rules. STOP and report.**

## Changed files (this attempt)
- `AnimiApp/Sources/EditorRuntime/Realtime/VideoOriginalAudioDurationProbe.swift` (NEW) — app-side actor:
  async probe of the REAL audio-track duration (`AVURLAsset.loadTracks(.audio)` → `track.load(.timeRange)`
  → `CMTimeGetSeconds`), cached by URL, coalesced, off-main. AVFoundation confined app-side.
- `AnimiApp/Sources/EditorRuntime/Realtime/AppVideoOriginalAudioBridge.swift` — `Input` gains
  `realAudioTrackDurationSeconds: Double?`; the descriptor's `sourceDuration` now uses the REAL probed
  duration (checked µs rational), FAIL-CLOSED if absent/invalid (no silent `winEnd` fallback).
- `AnimiApp/Sources/EditorRuntime/Realtime/RuntimeCanonicalAudioPlanSource.swift` — owns the probe + a
  MainActor mirror of probed seconds; feeds it into the bridge; on a cache miss kicks the async probe and
  fail-closes that block this pass (so the NEXT Play has the real duration); added
  `warmUpVideoOriginalDurations()` + a DEBUG test seam.
- Tests updated: `AppVideoOriginalAudioBridgeParityTests` (descriptor-duration test rewritten to the real
  duration + 4 new S9.2 fail-closed/real-duration tests), `VideoOriginalAudioPlanTests` +
  `RuntimeCanonicalAudioPlanSourceTests` (pass a real duration / seed the seam).
- `AnimiApp.xcodeproj/project.pbxproj` — xcodegen re-registered the new probe file (additive).

## Source of real audio duration
`AVURLAsset(url:).loadTracks(withMediaType: .audio).first` → `track.load(.timeRange).duration`
(`CMTimeGetSeconds`). Mirrors the export path's truth source (`ExportMediaSnapshot` uses
`asset.load(.duration)`); here we use the AUDIO track's time range specifically (not whole-asset duration).

## Conversion math
`realDurationUs = Int64((realSeconds * 1_000_000).rounded())` → `RationalSourceTime(numerator: realDurationUs,
denominator: 1_000_000)`. Single rounding of the probe seconds; integer rational thereafter. Fail-closed on
`realSeconds` non-finite/≤0 or `realDurationUs ≤ 0`.

## Tests
`AppVideoOriginalAudioBridgeParityTests` 17, `VideoOriginalAudioPlanTests` 12,
`RuntimeCanonicalAudioPlanSourceTests` 13, `BackgroundCanonicalPCMRendererTests` 20,
`CanonicalContinuousPlaybackTests` 14, `CanonicalAudioArchitectureTests` 5 → **81 tests, 0 failures** (sim).
New S9.2 tests: descriptor uses real probed duration not winEnd; real-track-shorter-than-winEnd uses real;
missing duration fails closed; invalid duration fails closed.

## Device gate (iPhone 13 Pro) — `slice-005-stage9.2-realduration-fix.log`
Operator: opened project, added video, stretched scene, played (incl. a re-Play).

Chronology (decisive):
- line 82: Play #1 → `startFailed audioAssetUnresolvable("real audio-track duration not probed yet")` —
  EXPECTED fail-closed (probe still running; no silent winEnd). ✓
- line 100–127: Play #2 (from 3.6 s) → probe ready → `plan segments=1`, `scheduled=1 started=1` — audio
  started. ✓ (the descriptor real-duration path works)
- **line 221: STILL a short-read** — `s8.shortReadProbe path=serveContiguous reqSourceStart=59/5 (11.8s)
  requestedFrameCount=48000 decodedFrames=3933 → pcmRenderFailed(shortfall 44067 > tolerance 1024)`.
  `requestedFrameCount=48000` ⇒ the renderer's Stage-8.1 clamp did NOT reduce the request even though the
  descriptor now carries the real duration.

| Marker | Stage-9 (before) | Stage-9.2 attempt (after) |
|---|---|---|
| s8.shortReadProbe | 5 | 1 (residual) |
| pcmRenderFailed | 13 | 2 (residual) |
| audioAssetUnresolvable (fail-closed, expected on un-probed Play) | 0 | 4 |
| canonical.scheduled started | — | 1 (Play #2 started) |
| nextChunk.endOfPlan | — | 0 (residual short-read prevented reaching end) |
| fallbackToLegacy=1 / SIGKILL | 0 | 0 |

## Root of the residual (proven from code — NOT a guess)
The renderer's Stage-8.1 clamp bounds `decodeFrameCount` by `segment.sourceEnd`. But `segment.sourceEnd`
is produced by the AnimiEngineCore evaluator, NOT from `descriptor.sourceDuration`:
- `AudioEvaluator.swift:86` `clippedHi = min(destHiTick, activeDest.end.ticks)` — clipped to the
  media-active DOMAIN, not the source's real audio length.
- `AudioEvaluator.swift:98` `let sourceEnd = try map.source(atProjectTick: clippedHi)` — `sourceEnd` is the
  destination tick mapped to source time; it does NOT consult `descriptor.sourceDuration`.
- `grep sourceDuration` in `AnimiEngineCore/Audio/` shows the field is DEFINED
  (`ResolvedAudioSourceDescriptor.swift`) but NEVER used to clamp the evaluated `sourceEnd`/segment.

So after a scene stretch, `clippedHi` (domain end) maps to a `sourceEnd` that exceeds the real audio track,
the renderer asks the full chunk (`requestedFrameCount=48000`), and the decoder short-reads. The
descriptor fix corrects the DECLARED duration but the evaluator that builds `segment.sourceEnd` ignores it.

**The correct fix is to clamp the evaluated `sourceEnd` (or the segment's audible window) to
`descriptor.sourceDuration` inside `AudioEvaluator` / the window builder — AnimiEngineCore.** That is OUT
OF SCOPE for this task (hard rule: no AnimiEngineCore change). Reporting before editing, as required.

## Verdict: **BLOCKED — needs an owner-approved AnimiEngineCore evaluator change**
- The app-side descriptor + probe fix is implemented, tested, and lands the real duration.
- It is INSUFFICIENT alone: `segment.sourceEnd` is evaluator-derived from the mapping and ignores
  `descriptor.sourceDuration`, so the renderer clamp still over-requests → residual short-read on device.
- A complete fix requires the evaluator to bound the segment's source window by `descriptor.sourceDuration`
  (AnimiEngineCore). This was NOT done (out of scope). No tolerance/guard-band change; no silent winEnd.

## Confirmations
- No tolerance / guard-band / sessionWindowFrames / maxBoundaryShortfallFrames change.
- No export / visual / legacy change. **AnimiEngineCore NOT changed** (the required residual fix lives
  there and is deliberately deferred for approval).
- `git diff --cached --name-only` empty; nothing staged/committed/pushed.
