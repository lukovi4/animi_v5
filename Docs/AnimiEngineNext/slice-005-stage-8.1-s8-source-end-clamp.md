# Slice 005 — Stage 8.1: S8 source-end clamp fix

Fix the confirmed S8 short-read by clamping the renderer's decode request to the canonical
`segment.sourceEnd`. NO decoder tolerance / guard-band / sessionWindowFrames / continuous-architecture
change; renderer/planning boundary correctness only. No export/visual/legacy/AnimiEngineCore change.

## Root (confirmed in Stage 8)
`BackgroundCanonicalPCMRenderer.render` intersected the request range with `destinationSamples` and
asked the decoder for `frameCount = iEnd − iStart`, WITHOUT capping by `segment.sourceEnd`. When the
plan maps a destination span LONGER than the clip's actual source audio (e.g. source ends ~11.9 s but
a 1 s chunk starts at ~11.4 s), the decoder ran off the end of the track → short-read →
`pcmRenderFailed`. (Stage 8 probe captured `reqSourceStart≈11.4s`, `wideDecoded≈26k` of 48k.)

## Changed files
- `AnimiApp/Sources/EditorRuntime/Realtime/BackgroundCanonicalPCMRenderer.swift`
  - New static `framesAvailable(from:to:requested:sourceIDRaw:)` — exact integer/rational math.
  - `render` now clamps `decodeFrameCount = framesAvailable(sourceStartForChunk, segment.sourceEnd, frameCount)`;
    skips the segment when 0 (source already ended); frames the available prefix into the chunk and
    leaves the tail (past `sourceEnd`) as silence; keeps `chunk.key.range == request.range`.
- `AnimiApp/Tests/BackgroundCanonicalPCMRendererTests.swift` — S8-clamp tests + the generic fixture
  `segment` now uses a large `sourceEnd` (1000 s) so the clamp only trips where a test intends it.

## Exact math (sourceEnd → maxFrames)
```
available = sourceEnd − sourceStart            // RationalSourceTime.subtracting (reduced, denom > 0)
if sourceStart >= sourceEnd          → 0       // source ended at/before chunk start → silence, skip
availableFrames = floor( available.numerator × 48_000 / available.denominator )
result = min(requested, availableFrames)
```
- No Double, no µs truncation.
- `numerator × 48_000` uses `multipliedReportingOverflow` → typed `pcmRenderFailed` on overflow.
- `availableFrames64 / denominator` is floor for non-negative operands (the rational is > 0 here).
- `Int(exactly:)` guards the final Int conversion → typed `pcmRenderFailed` if non-representable.

## Tests
Targeted suites green (0 failures): `BackgroundCanonicalPCMRendererTests` 20 (6 new S8 tests),
`CanonicalContinuousPlaybackTests` 14, `CanonicalPCMRenderCacheTests` 16,
`AppVideoOriginalAudioBridgeParityTests` 12, `RuntimeCanonicalAudioPlanSourceTests` 13,
`CanonicalAudioArchitectureTests` 16, `AVFoundationPCMAssetDecoderWatchdogTests` 14 →
**110 tests, 0 failures**. New S8 tests:
- `testS8_doesNotRequestBeyondSourceEnd` — chunk 48000 but sourceEnd 0.5 s → decode clamped to 24000,
  prefix present, tail `[24000,48000)` is silence.
- `testS8_sourceAlreadyEndedSkipsDecode` — sourceStart ≥ sourceEnd → decoder NOT called.
- `testS8_otherSourceStillRendersWhenOneEnded` — a co-located live source still renders normally.
- `testS8_framesAvailableOverflowFailsClosed` — numerator overflow → typed `pcmRenderFailed`.
- `testS8_framesAvailableExactMath` — 0.5 s→24000, ended→0, 10 s→clamped to requested.
- Existing continuous/endOfPlan/fail-closed tests remain green.

## Device gate (iPhone 13 Pro)
Flags `-DebugPreviewAudioWithNextEngine YES -DebugMemoryDiagnostics YES`.
Log: `Docs/AnimiEngineNext/evidence/slice-005-stage8.1-s8clamp.log`. Operator reproduced the same
video+music scene-length-change S8 scenario and played to the end.

### Before / after S8 marker table

| Marker | Stage-8 (before, `slice-005-stage8-latency-probe.log`) | Stage-8.1 (after, `slice-005-stage8.1-s8clamp.log`) |
|---|---|---|
| `s8.shortReadProbe` | 2 (fired) | **0** |
| `pcmRenderFailed` | 2 | **0** |
| `nextChunk.failed` | present | **0** |
| `errorAlert` | present | **0** |
| `fallbackToLegacy=1` | 0 | **0** |
| `shortfall` | 2 | **0** |
| `produced no PreviewMixSource` | 0 | **0** |
| `SIGKILL/jetsam` | 0 | **0** |
| `nextChunk.endOfPlan` | — (broke before end) | **6 (reached)** |

### Clamp visible in the device log
`stage8.render.decode … frameCount=10401 intersectionFrames=10402` (and similar): the renderer asks
for FEWER frames than the destination intersection because the source ends inside the chunk. Those
last frame(s) — which previously ran off the track and short-read — are now decoded only up to
`sourceEnd`, and the tail is silence. Audible playback reaches `endOfPlan` through the canonical path.

## Verdict: **PASS**
- `s8.shortReadProbe`, `pcmRenderFailed`, `nextChunk.failed`, `errorAlert`, `fallbackToLegacy` all 0.
- `endOfPlan` reached; audible playback completes via canonical path.
- The source-end-clamp fires (frameCount < intersectionFrames at the source boundary) without error.

## Confirmations
- No tolerance / guard-band / sessionWindowFrames / maxBoundaryShortfallFrames change.
- No reader/session/cache/prewarm redesign; no continuous-architecture change.
- No export / visual / legacy / AnimiEngineCore change.
- `chunk.key.range == request.range` preserved.
- `git diff --cached --name-only` empty; nothing staged/committed/pushed.
